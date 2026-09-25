/**
 * G3C - Supplier Payment / AP Disbursement lifecycle.
 *
 * Processing-state contract:
 *
 * Draft
 *   -> Authorized
 *   -> Submitted
 *   -> Succeeded   (only through SABSupplierPaymentPostingService)
 *
 * Submitted
 *   -> Failed
 *
 * Failed
 *   -> Submitted   (retry preserves Provider_Request_Key__c)
 *
 * Reversed is reserved for the later refund/reversal implementation.
 *
 * Financial contract:
 * - Draft/Authorized/Submitted/Failed never imply cash settlement.
 * - Only Succeeded may hold Accounting_Event__c.
 * - G3C supports same-currency supplier disbursement posting.
 * - Foreign-currency settlement remains blocked until allocation carrying
 *   values + approved realized-FX policy are implemented.
 */
public with sharing class SABSupplierPaymentService {

    public class SupplierPaymentException extends Exception {}

    private static final String STATE_DRAFT = 'Draft';
    private static final String STATE_AUTHORIZED = 'Authorized';
    private static final String STATE_SUBMITTED = 'Submitted';
    private static final String STATE_SUCCEEDED = 'Succeeded';
    private static final String STATE_FAILED = 'Failed';
    private static final String STATE_REVERSED = 'Reversed';

    private static final String DIRECTION_DISBURSEMENT =
        'Disbursement';

    private static final String APPROVE_PERMISSION =
        'SAB_Approve_Financial_Document';

    private static final String POST_PERMISSION =
        'SAB_Post_Journal';

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    @TestVisible
    private static Boolean lifecycleMutationInProgress =
        false;

    public class ValidationResult {
        @AuraEnabled public Boolean isValid {
            get;
            private set;
        }

        @AuraEnabled public List<String> errors {
            get;
            private set;
        }

        @AuraEnabled public String functionalCurrency {
            get;
            private set;
        }

        @AuraEnabled public Decimal normalizedAmount {
            get;
            private set;
        }

        private ValidationResult() {
            isValid = true;
            errors = new List<String>();
            normalizedAmount = ZERO;
        }

        private void addError(String message) {
            isValid = false;
            errors.add(message);
        }
    }

    public class TransitionResult {
        @AuraEnabled public Id paymentId {
            get;
            private set;
        }

        @AuraEnabled public String previousState {
            get;
            private set;
        }

        @AuraEnabled public String newState {
            get;
            private set;
        }

        @AuraEnabled public Id businessActionId {
            get;
            private set;
        }

        @AuraEnabled public Boolean idempotentReplay {
            get;
            private set;
        }
    }

    @AuraEnabled
    public static ValidationResult validateForAuthorization(
        Id paymentId
    ) {
        Accounting_Payment__c payment =
            loadPayment(
                paymentId,
                false
            );

        assertCanReadPayment(payment);

        return validatePayment(
            payment
        );
    }

    @AuraEnabled
    public static TransitionResult authorize(
        Id paymentId,
        String requestKey
    ) {
        requireRequestKey(requestKey);

        SABPermissionService.assertPermission(
            APPROVE_PERMISSION,
            'You do not have permission to authorize financial documents.'
        );

        Business_Action__c priorAction =
            findPriorAction(
                requestKey
            );

        if (priorAction != null) {
            return replayTransition(
                paymentId,
                'SUPPLIER_PAYMENT_AUTHORIZED',
                STATE_AUTHORIZED,
                priorAction
            );
        }

        Accounting_Payment__c payment =
            loadPayment(
                paymentId,
                true
            );

        assertCanEditPayment(payment);

        if (
            payment.Processing_State__c
            != STATE_DRAFT
        ) {
            throw new SupplierPaymentException(
                'Supplier Payment must be Draft before authorization. Current state: '
                + payment.Processing_State__c
                + '.'
            );
        }

        ValidationResult validation =
            validatePayment(
                payment
            );

        throwIfInvalid(validation);

        String previousState =
            payment.Processing_State__c;

        payment.Functional_Currency__c =
            validation.functionalCurrency;
        payment.Exchange_Rate__c =
            Decimal.valueOf('1');
        payment.Processing_State__c =
            STATE_AUTHORIZED;

        controlledUpdate(payment);

        Business_Action__c action =
            createBusinessAction(
                payment,
                'SUPPLIER_PAYMENT_AUTHORIZED',
                requestKey,
                'Supplier Payment authorized.'
            );

        return buildTransitionResult(
            payment.Id,
            previousState,
            STATE_AUTHORIZED,
            action.Id,
            false
        );
    }

    /**
     * Records that the payment instruction was handed to the bank/provider.
     * No journal is created and cash is NOT treated as settled.
     */
    @AuraEnabled
    public static TransitionResult submitForExecution(
        Id paymentId,
        String providerRequestKey,
        String requestKey
    ) {
        requireRequestKey(requestKey);
        requireProviderRequestKey(
            providerRequestKey
        );

        Business_Action__c priorAction =
            findPriorAction(
                requestKey
            );

        if (priorAction != null) {
            return replayTransition(
                paymentId,
                'SUPPLIER_PAYMENT_SUBMITTED',
                STATE_SUBMITTED,
                priorAction
            );
        }

        Accounting_Payment__c payment =
            loadPayment(
                paymentId,
                true
            );

        assertCanEditPayment(payment);

        if (
            payment.Processing_State__c
            != STATE_AUTHORIZED
        ) {
            throw new SupplierPaymentException(
                'Supplier Payment must be Authorized before submission. Current state: '
                + payment.Processing_State__c
                + '.'
            );
        }

        ValidationResult validation =
            validatePayment(
                payment
            );

        throwIfInvalid(validation);

        assertProviderRequestKeyAvailable(
            payment,
            providerRequestKey.trim()
        );

        String previousState =
            payment.Processing_State__c;

        payment.Provider_Request_Key__c =
            providerRequestKey.trim();
        payment.Processing_State__c =
            STATE_SUBMITTED;

        controlledUpdate(payment);

        Business_Action__c action =
            createBusinessAction(
                payment,
                'SUPPLIER_PAYMENT_SUBMITTED',
                requestKey,
                'Supplier Payment submitted for execution. Provider request key: '
                + payment.Provider_Request_Key__c
            );

        return buildTransitionResult(
            payment.Id,
            previousState,
            STATE_SUBMITTED,
            action.Id,
            false
        );
    }

    /**
     * Provider/bank execution failed. This never posts cash.
     */
    @AuraEnabled
    public static TransitionResult markFailed(
        Id paymentId,
        String requestKey,
        String reason
    ) {
        requireRequestKey(requestKey);
        requireReason(
            reason,
            'A failure reason is required.'
        );

        Business_Action__c priorAction =
            findPriorAction(
                requestKey
            );

        if (priorAction != null) {
            return replayTransition(
                paymentId,
                'SUPPLIER_PAYMENT_FAILED',
                STATE_FAILED,
                priorAction
            );
        }

        Accounting_Payment__c payment =
            loadPayment(
                paymentId,
                true
            );

        assertCanEditPayment(payment);

        if (
            payment.Processing_State__c
            != STATE_SUBMITTED
        ) {
            throw new SupplierPaymentException(
                'Only a Submitted Supplier Payment can be marked Failed.'
            );
        }

        if (payment.Accounting_Event__c != null) {
            throw new SupplierPaymentException(
                'A Supplier Payment linked to an Accounting Event cannot be marked Failed.'
            );
        }

        String previousState =
            payment.Processing_State__c;

        payment.Processing_State__c =
            STATE_FAILED;

        controlledUpdate(payment);

        Business_Action__c action =
            createBusinessAction(
                payment,
                'SUPPLIER_PAYMENT_FAILED',
                requestKey,
                reason.trim()
            );

        return buildTransitionResult(
            payment.Id,
            previousState,
            STATE_FAILED,
            action.Id,
            false
        );
    }

    /**
     * A failed provider call may be retried, but the same stable provider key
     * is preserved. Retrying does not imply cash settlement.
     */
    @AuraEnabled
    public static TransitionResult retryFailed(
        Id paymentId,
        String requestKey
    ) {
        requireRequestKey(requestKey);

        Business_Action__c priorAction =
            findPriorAction(
                requestKey
            );

        if (priorAction != null) {
            return replayTransition(
                paymentId,
                'SUPPLIER_PAYMENT_RETRIED',
                STATE_SUBMITTED,
                priorAction
            );
        }

        Accounting_Payment__c payment =
            loadPayment(
                paymentId,
                true
            );

        assertCanEditPayment(payment);

        if (
            payment.Processing_State__c
            != STATE_FAILED
        ) {
            throw new SupplierPaymentException(
                'Only a Failed Supplier Payment can be retried.'
            );
        }

        if (
            String.isBlank(
                payment.Provider_Request_Key__c
            )
        ) {
            throw new SupplierPaymentException(
                'Failed Supplier Payment is missing its stable Provider Request Key.'
            );
        }

        if (payment.Accounting_Event__c != null) {
            throw new SupplierPaymentException(
                'A Supplier Payment linked to an Accounting Event cannot be retried.'
            );
        }

        ValidationResult validation =
            validatePayment(
                payment
            );

        throwIfInvalid(validation);

        String previousState =
            payment.Processing_State__c;

        payment.Processing_State__c =
            STATE_SUBMITTED;

        controlledUpdate(payment);

        Business_Action__c action =
            createBusinessAction(
                payment,
                'SUPPLIER_PAYMENT_RETRIED',
                requestKey,
                'Supplier Payment execution retried using the existing Provider Request Key.'
            );

        return buildTransitionResult(
            payment.Id,
            previousState,
            STATE_SUBMITTED,
            action.Id,
            false
        );
    }

    /**
     * Called by G3C posting service immediately before financial posting.
     */
    public static void assertSubmittedForPosting(
        Id paymentId
    ) {
        Accounting_Payment__c payment =
            loadPayment(
                paymentId,
                true
            );

        assertCanEditPayment(payment);

        if (
            payment.Processing_State__c
            != STATE_SUBMITTED
        ) {
            throw new SupplierPaymentException(
                'Supplier Payment must be Submitted before successful settlement can be posted.'
            );
        }

        if (
            String.isBlank(
                payment.Provider_Request_Key__c
            )
        ) {
            throw new SupplierPaymentException(
                'Submitted Supplier Payment requires a Provider Request Key.'
            );
        }

        if (payment.Accounting_Event__c != null) {
            throw new SupplierPaymentException(
                'Submitted Supplier Payment must not already contain an Accounting Event.'
            );
        }

        ValidationResult validation =
            validatePayment(
                payment
            );

        throwIfInvalid(validation);
    }

    /**
     * G3C completion hook. The payment can become Succeeded only after
     * SABPostingService has produced a completed Payment Disbursement event
     * and Posted Subledger journal.
     */
    public static TransitionResult completeSucceededPosting(
        Id paymentId,
        Id accountingEventId,
        Id journalEntryId,
        String requestKey
    ) {
        requireRequestKey(requestKey);

        SABPermissionService.assertPermission(
            POST_PERMISSION,
            'You do not have permission to post accounting transactions.'
        );

        if (accountingEventId == null) {
            throw new SupplierPaymentException(
                'Accounting Event Id is required to complete Supplier Payment posting.'
            );
        }

        if (journalEntryId == null) {
            throw new SupplierPaymentException(
                'Journal Entry Id is required to complete Supplier Payment posting.'
            );
        }

        Accounting_Payment__c payment = [
            SELECT Id, Company__c,
                   Direction__c,
                   Processing_State__c,
                   Accounting_Event__c,
                   Provider_Request_Key__c
            FROM Accounting_Payment__c
            WHERE Id = :paymentId
            LIMIT 1
            FOR UPDATE
        ];

        if (
            payment.Processing_State__c
            == STATE_SUCCEEDED
        ) {
            assertCanReadPayment(payment);

            if (
                payment.Accounting_Event__c
                != accountingEventId
            ) {
                throw new SupplierPaymentException(
                    'Succeeded Supplier Payment is linked to a different Accounting Event.'
                );
            }

            Business_Action__c priorAction =
                findPriorAction(
                    requestKey
                );

            return buildTransitionResult(
                payment.Id,
                null,
                STATE_SUCCEEDED,
                priorAction == null
                    ? null
                    : priorAction.Id,
                true
            );
        }

        assertCanEditPayment(payment);

        if (
            payment.Processing_State__c
            != STATE_SUBMITTED
        ) {
            throw new SupplierPaymentException(
                'Supplier Payment must be Submitted before successful posting can be completed.'
            );
        }

        if (
            payment.Direction__c
            != DIRECTION_DISBURSEMENT
        ) {
            throw new SupplierPaymentException(
                'G3C Supplier Payment posting supports Disbursement direction only.'
            );
        }

        Accounting_Event__c eventRecord = [
            SELECT Id, Company__c,
                   Event_Type__c,
                   Source_Type__c,
                   Source_Record_Id__c,
                   State__c,
                   Journal_Entry__c
            FROM Accounting_Event__c
            WHERE Id = :accountingEventId
            LIMIT 1
        ];

        if (
            eventRecord.Company__c
                != payment.Company__c
            || eventRecord.Event_Type__c
                != 'Payment Disbursement'
            || eventRecord.Source_Type__c
                != 'Accounting_Payment__c'
            || eventRecord.Source_Record_Id__c
                != String.valueOf(
                    payment.Id
                )
            || eventRecord.State__c
                != 'Posted'
            || eventRecord.Journal_Entry__c
                != journalEntryId
        ) {
            throw new SupplierPaymentException(
                'Accounting Event does not represent this completed Supplier Payment.'
            );
        }

        Journal_Entry__c journal = [
            SELECT Id, Company__c,
                   Entry_Type__c,
                   Status__c,
                   Accounting_Event__c
            FROM Journal_Entry__c
            WHERE Id = :journalEntryId
            LIMIT 1
        ];

        if (
            journal.Company__c
                != payment.Company__c
            || journal.Entry_Type__c
                != 'Subledger'
            || journal.Status__c
                != 'Posted'
            || journal.Accounting_Event__c
                != accountingEventId
        ) {
            throw new SupplierPaymentException(
                'Journal Entry does not represent a completed Supplier Payment subledger posting.'
            );
        }

        payment.Accounting_Event__c =
            accountingEventId;
        payment.Processing_State__c =
            STATE_SUCCEEDED;

        controlledUpdate(payment);

        Business_Action__c action =
            createBusinessAction(
                payment,
                'SUPPLIER_PAYMENT_SUCCEEDED',
                requestKey,
                'Supplier Payment execution succeeded and was posted to Accounts Payable and Bank.'
            );

        return buildTransitionResult(
            payment.Id,
            STATE_SUBMITTED,
            STATE_SUCCEEDED,
            action.Id,
            false
        );
    }

    public static void guardBeforeInsert(
        List<Accounting_Payment__c> newRecords
    ) {
        if (newRecords == null) {
            return;
        }

        for (
            Accounting_Payment__c payment
            : newRecords
        ) {
            if (
                String.isBlank(
                    payment.Processing_State__c
                )
            ) {
                payment.Processing_State__c =
                    STATE_DRAFT;
            } else if (
                payment.Processing_State__c
                != STATE_DRAFT
            ) {
                payment.addError(
                    'New Payments must start in Draft state.'
                );
            }

            if (
                payment.Accounting_Event__c
                != null
            ) {
                payment.addError(
                    'Accounting Event is system-managed and cannot be assigned when creating a Payment.'
                );
            }

            if (
                !String.isBlank(
                    payment.Provider_Request_Key__c
                )
            ) {
                payment.addError(
                    'Provider Request Key is system-managed and is assigned when the Payment is submitted for execution.'
                );
            }
        }
    }

    public static void guardBeforeUpdate(
        Map<Id, Accounting_Payment__c> oldMap,
        List<Accounting_Payment__c> newRecords
    ) {
        if (
            oldMap == null
            || newRecords == null
        ) {
            return;
        }

        for (
            Accounting_Payment__c newRecord
            : newRecords
        ) {
            Accounting_Payment__c oldRecord =
                oldMap.get(
                    newRecord.Id
                );

            if (oldRecord == null) {
                continue;
            }

            if (lifecycleMutationInProgress) {
                continue;
            }

            if (
                oldRecord.Processing_State__c
                != newRecord.Processing_State__c
            ) {
                newRecord.addError(
                    'Payment Processing State must be changed through the controlled Supplier Payment service.'
                );
                continue;
            }

            if (
                oldRecord.Accounting_Event__c
                != newRecord.Accounting_Event__c
            ) {
                newRecord.addError(
                    'Accounting Event is system-managed and can only be assigned by the Supplier Payment posting service.'
                );
                continue;
            }

            if (
                oldRecord.Provider_Request_Key__c
                != newRecord.Provider_Request_Key__c
            ) {
                newRecord.addError(
                    'Provider Request Key is system-managed. Retry must reuse the original key.'
                );
                continue;
            }

            if (
                oldRecord.Processing_State__c
                != STATE_DRAFT
                && hasMaterialPaymentChange(
                    oldRecord,
                    newRecord
                )
            ) {
                newRecord.addError(
                    'Supplier Payment financial fields are locked after authorization.'
                );
            }
        }
    }

    public static void guardBeforeDelete(
        List<Accounting_Payment__c> oldRecords
    ) {
        if (oldRecords == null) {
            return;
        }

        for (
            Accounting_Payment__c payment
            : oldRecords
        ) {
            if (
                payment.Processing_State__c
                != STATE_DRAFT
            ) {
                payment.addError(
                    'Only Draft Payments can be deleted.'
                );
            }
        }
    }

    private static Accounting_Payment__c loadPayment(
        Id paymentId,
        Boolean lockRecord
    ) {
        if (paymentId == null) {
            throw new SupplierPaymentException(
                'Supplier Payment Id is required.'
            );
        }

        String queryText =
            'SELECT Id, Name, Company__c, '
            + 'Company__r.Functional_Currency__c, '
            + 'Company__r.Is_Active__c, '
            + 'Party_Profile__c, '
            + 'Party_Profile__r.Company__c, '
            + 'Party_Profile__r.Is_Active__c, '
            + 'Party_Profile__r.Is_Supplier__c, '
            + 'Party_Profile__r.AP_Control_Account__c, '
            + 'Party_Profile__r.AP_Control_Account__r.Company__c, '
            + 'Party_Profile__r.AP_Control_Account__r.Account_Type__c, '
            + 'Party_Profile__r.AP_Control_Account__r.Is_Active__c, '
            + 'Party_Profile__r.AP_Control_Account__r.Is_Control_Account__c, '
            + 'Party_Profile__r.AP_Control_Account__r.Control_Type__c, '
            + 'Bank_Account__c, '
            + 'Bank_Account__r.Company__c, '
            + 'Bank_Account__r.Currency__c, '
            + 'Bank_Account__r.Is_Active__c, '
            + 'Bank_Account__r.GL_Account__c, '
            + 'Bank_Account__r.GL_Account__r.Company__c, '
            + 'Bank_Account__r.GL_Account__r.Account_Type__c, '
            + 'Bank_Account__r.GL_Account__r.Is_Active__c, '
            + 'Direction__c, Method__c, Reference__c, '
            + 'Amount__c, Transaction_Currency__c, '
            + 'Functional_Currency__c, Exchange_Rate__c, '
            + 'Effective_Date__c, Processing_State__c, '
            + 'Provider_Request_Key__c, Accounting_Event__c '
            + 'FROM Accounting_Payment__c '
            + 'WHERE Id = \''
            + String.escapeSingleQuotes(
                String.valueOf(
                    paymentId
                )
            )
            + '\' LIMIT 1';

        if (lockRecord) {
            queryText += ' FOR UPDATE';
        }

        List<Accounting_Payment__c> payments =
            Database.query(
                queryText
            );

        if (payments.isEmpty()) {
            throw new SupplierPaymentException(
                'Supplier Payment was not found or is not accessible.'
            );
        }

        return payments[0];
    }

    private static ValidationResult validatePayment(
        Accounting_Payment__c payment
    ) {
        ValidationResult result =
            new ValidationResult();

        if (payment.Company__c == null) {
            result.addError(
                'Accounting Company is required.'
            );
            return result;
        }

        try {
            SABCompanyAccessService.assertCompanyAccess(
                payment.Company__c
            );
        } catch (Exception ex) {
            result.addError(
                'You do not have active access to the Payment Accounting Company.'
            );
        }

        if (
            payment.Company__r == null
            || payment.Company__r.Is_Active__c
                != true
        ) {
            result.addError(
                'Accounting Company must be active.'
            );
        }

        if (
            payment.Direction__c
            != DIRECTION_DISBURSEMENT
        ) {
            result.addError(
                'G3C Supplier Payment supports Direction = Disbursement only.'
            );
        }

        if (
            String.isBlank(
                payment.Method__c
            )
        ) {
            result.addError(
                'Payment Method is required.'
            );
        }

        if (
            payment.Amount__c == null
            || payment.Amount__c <= ZERO
        ) {
            result.addError(
                'Payment Amount must be greater than zero.'
            );
        } else {
            result.normalizedAmount =
                SABMoneyService.normalizeTransactionAmount(
                    payment.Amount__c,
                    RoundingMode.HALF_UP
                );

            if (
                result.normalizedAmount
                <= ZERO
            ) {
                result.addError(
                    'Payment Amount rounds to zero and cannot be processed.'
                );
            }
        }

        if (
            payment.Effective_Date__c
            == null
        ) {
            result.addError(
                'Payment Effective Date is required.'
            );
        } else {
            validateOpenAccountingPeriod(
                payment,
                result
            );
        }

        validateSupplierProfile(
            payment,
            result
        );

        validateBankAccount(
            payment,
            result
        );

        validateCurrency(
            payment,
            result
        );

        if (
            payment.Processing_State__c
                != STATE_DRAFT
            && payment.Accounting_Event__c
                != null
            && payment.Processing_State__c
                != STATE_SUCCEEDED
            && payment.Processing_State__c
                != STATE_REVERSED
        ) {
            result.addError(
                'Only Succeeded or Reversed Payments may contain an Accounting Event.'
            );
        }

        return result;
    }

    private static void validateSupplierProfile(
        Accounting_Payment__c payment,
        ValidationResult result
    ) {
        if (
            payment.Party_Profile__c
            == null
        ) {
            result.addError(
                'Supplier Party Accounting Profile is required.'
            );
            return;
        }

        Party_Accounting_Profile__c profile =
            payment.Party_Profile__r;

        if (profile == null) {
            result.addError(
                'Supplier Party Accounting Profile is not accessible.'
            );
            return;
        }

        if (
            profile.Company__c
            != payment.Company__c
        ) {
            result.addError(
                'Supplier Party Accounting Profile must belong to the Payment Accounting Company.'
            );
        }

        if (
            profile.Is_Active__c
            != true
        ) {
            result.addError(
                'Supplier Party Accounting Profile must be active.'
            );
        }

        if (
            profile.Is_Supplier__c
            != true
        ) {
            result.addError(
                'Party Accounting Profile must be enabled as a supplier.'
            );
        }

        if (
            profile.AP_Control_Account__c
            == null
        ) {
            result.addError(
                'Supplier Party Accounting Profile requires an AP Control Account.'
            );
            return;
        }

        GL_Account__c apAccount =
            profile.AP_Control_Account__r;

        if (
            apAccount == null
            || apAccount.Company__c
                != payment.Company__c
            || apAccount.Is_Active__c
                != true
            || apAccount.Account_Type__c
                != 'Liability'
            || apAccount.Is_Control_Account__c
                != true
            || apAccount.Control_Type__c
                != 'AP'
        ) {
            result.addError(
                'Supplier AP Control Account must be an active AP Liability control account in the same Accounting Company.'
            );
        }
    }

    private static void validateBankAccount(
        Accounting_Payment__c payment,
        ValidationResult result
    ) {
        if (
            payment.Bank_Account__c
            == null
        ) {
            result.addError(
                'Bank Account is required.'
            );
            return;
        }

        Bank_Account__c bankAccount =
            payment.Bank_Account__r;

        if (bankAccount == null) {
            result.addError(
                'Bank Account is not accessible.'
            );
            return;
        }

        if (
            bankAccount.Company__c
            != payment.Company__c
        ) {
            result.addError(
                'Bank Account must belong to the Payment Accounting Company.'
            );
        }

        if (
            bankAccount.Is_Active__c
            != true
        ) {
            result.addError(
                'Bank Account must be active.'
            );
        }

        if (
            bankAccount.GL_Account__c
            == null
        ) {
            result.addError(
                'Bank Account requires a mapped GL Account.'
            );
            return;
        }

        GL_Account__c bankGL =
            bankAccount.GL_Account__r;

        if (
            bankGL == null
            || bankGL.Company__c
                != payment.Company__c
            || bankGL.Is_Active__c
                != true
            || bankGL.Account_Type__c
                != 'Asset'
        ) {
            result.addError(
                'Bank Account GL mapping must be an active Asset account in the same Accounting Company.'
            );
        }
    }

    private static void validateCurrency(
        Accounting_Payment__c payment,
        ValidationResult result
    ) {
        if (payment.Bank_Account__r == null) {
            return;
        }

        String companyCurrency;
        String paymentCurrency;
        String bankCurrency;

        try {
            companyCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    payment.Company__r.Functional_Currency__c
                );
        } catch (Exception ex) {
            result.addError(
                'Accounting Company Functional Currency is invalid.'
            );
            return;
        }

        try {
            paymentCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    payment.Transaction_Currency__c
                );
        } catch (Exception ex) {
            result.addError(
                'Payment Transaction Currency must be a valid 3-letter currency code.'
            );
            return;
        }

        try {
            bankCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    payment.Bank_Account__r.Currency__c
                );
        } catch (Exception ex) {
            result.addError(
                'Bank Account Currency must be a valid 3-letter currency code.'
            );
            return;
        }

        if (
            payment.Transaction_Currency__c
            != paymentCurrency
        ) {
            result.addError(
                'Payment Transaction Currency must be stored as a 3-letter uppercase code.'
            );
        }

        if (
            payment.Bank_Account__r.Currency__c
            != bankCurrency
        ) {
            result.addError(
                'Bank Account Currency must be stored as a 3-letter uppercase code.'
            );
        }

        if (
            paymentCurrency
            != bankCurrency
        ) {
            result.addError(
                'Payment Transaction Currency must match the selected Bank Account Currency.'
            );
        }

        if (
            paymentCurrency
            != companyCurrency
        ) {
            result.addError(
                'G3C currently supports same-currency supplier disbursements only. Foreign-currency settlement requires G3D allocation carrying values and the G4 realized-FX settlement policy.'
            );
        }

        if (
            !String.isBlank(
                payment.Functional_Currency__c
            )
        ) {
            String storedFunctional;

            try {
                storedFunctional =
                    SABMoneyService.normalizeCurrencyCode(
                        payment.Functional_Currency__c
                    );
            } catch (Exception ex) {
                result.addError(
                    'Payment Functional Currency must be a valid 3-letter currency code.'
                );
                return;
            }

            if (
                storedFunctional
                != companyCurrency
            ) {
                result.addError(
                    'Payment Functional Currency must match the Accounting Company Functional Currency.'
                );
            }
        }

        if (
            payment.Exchange_Rate__c != null
            && payment.Exchange_Rate__c
                != Decimal.valueOf('1')
        ) {
            result.addError(
                'Same-currency Supplier Payments must use an Exchange Rate of 1 when a rate is stored.'
            );
        }

        result.functionalCurrency =
            companyCurrency;
    }

    private static void validateOpenAccountingPeriod(
        Accounting_Payment__c payment,
        ValidationResult result
    ) {
        List<Accounting_Period__c> periods = [
            SELECT Id, Status__c
            FROM Accounting_Period__c
            WHERE Company__c =
                :payment.Company__c
              AND Start_Date__c
                <= :payment.Effective_Date__c
              AND End_Date__c
                >= :payment.Effective_Date__c
            LIMIT 2
        ];

        if (periods.isEmpty()) {
            result.addError(
                'No Accounting Period contains the Payment Effective Date.'
            );
            return;
        }

        if (periods.size() > 1) {
            result.addError(
                'More than one Accounting Period contains the Payment Effective Date.'
            );
            return;
        }

        if (
            periods[0].Status__c
            != 'Open'
        ) {
            result.addError(
                'Payment Effective Date must be in an Open Accounting Period.'
            );
        }
    }

    private static void assertProviderRequestKeyAvailable(
        Accounting_Payment__c payment,
        String providerRequestKey
    ) {
        List<Accounting_Payment__c> duplicates = [
            SELECT Id
            FROM Accounting_Payment__c
            WHERE Company__c =
                :payment.Company__c
              AND Provider_Request_Key__c =
                :providerRequestKey
              AND Id !=
                :payment.Id
            LIMIT 1
        ];

        if (!duplicates.isEmpty()) {
            throw new SupplierPaymentException(
                'Provider Request Key is already assigned to another Payment in this Accounting Company.'
            );
        }
    }

    private static void assertCanReadPayment(
        Accounting_Payment__c payment
    ) {
        SABAccessControlService.assertReadable(
            Accounting_Payment__c.SObjectType,
            paymentReadFields()
        );

        SABAccessControlService.assertReadable(
            Bank_Account__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Account__c.Company__c,
                Bank_Account__c.Currency__c,
                Bank_Account__c.GL_Account__c,
                Bank_Account__c.Is_Active__c
            }
        );

        SABAccessControlService.assertReadable(
            Party_Accounting_Profile__c.SObjectType,
            new List<Schema.SObjectField>{
                Party_Accounting_Profile__c.Company__c,
                Party_Accounting_Profile__c.Is_Active__c,
                Party_Accounting_Profile__c.Is_Supplier__c,
                Party_Accounting_Profile__c.AP_Control_Account__c
            }
        );

        SABCompanyAccessService.assertCompanyAccess(
            payment.Company__c
        );

        SABAccessControlService.assertRecordReadAccess(
            payment.Id
        );
    }

    private static void assertCanEditPayment(
        Accounting_Payment__c payment
    ) {
        assertCanReadPayment(payment);

        SABAccessControlService.assertUpdateable(
            Accounting_Payment__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Payment__c.Processing_State__c,
                Accounting_Payment__c.Provider_Request_Key__c,
                Accounting_Payment__c.Functional_Currency__c,
                Accounting_Payment__c.Exchange_Rate__c,
                Accounting_Payment__c.Accounting_Event__c
            }
        );

        SABAccessControlService.assertRecordEditAccess(
            payment.Id
        );
    }

    private static List<Schema.SObjectField>
        paymentReadFields()
    {
        return new List<Schema.SObjectField>{
            Accounting_Payment__c.Company__c,
            Accounting_Payment__c.Party_Profile__c,
            Accounting_Payment__c.Bank_Account__c,
            Accounting_Payment__c.Direction__c,
            Accounting_Payment__c.Method__c,
            Accounting_Payment__c.Reference__c,
            Accounting_Payment__c.Amount__c,
            Accounting_Payment__c.Transaction_Currency__c,
            Accounting_Payment__c.Functional_Currency__c,
            Accounting_Payment__c.Exchange_Rate__c,
            Accounting_Payment__c.Effective_Date__c,
            Accounting_Payment__c.Processing_State__c,
            Accounting_Payment__c.Provider_Request_Key__c,
            Accounting_Payment__c.Accounting_Event__c
        };
    }

    private static void controlledUpdate(
        Accounting_Payment__c payment
    ) {
        lifecycleMutationInProgress =
            true;

        try {
            update payment;
        } finally {
            lifecycleMutationInProgress =
                false;
        }
    }

    private static Boolean hasMaterialPaymentChange(
        Accounting_Payment__c oldRecord,
        Accounting_Payment__c newRecord
    ) {
        return
            oldRecord.Company__c
                != newRecord.Company__c
            || oldRecord.Party_Profile__c
                != newRecord.Party_Profile__c
            || oldRecord.Bank_Account__c
                != newRecord.Bank_Account__c
            || oldRecord.Direction__c
                != newRecord.Direction__c
            || oldRecord.Method__c
                != newRecord.Method__c
            || oldRecord.Reference__c
                != newRecord.Reference__c
            || oldRecord.Amount__c
                != newRecord.Amount__c
            || oldRecord.Transaction_Currency__c
                != newRecord.Transaction_Currency__c
            || oldRecord.Functional_Currency__c
                != newRecord.Functional_Currency__c
            || oldRecord.Exchange_Rate__c
                != newRecord.Exchange_Rate__c
            || oldRecord.Effective_Date__c
                != newRecord.Effective_Date__c;
    }

    private static Business_Action__c findPriorAction(
        String requestKey
    ) {
        List<Business_Action__c> actions = [
            SELECT Id, Action__c,
                   Source_Type__c,
                   Source_Record_Id__c,
                   Request_Key__c
            FROM Business_Action__c
            WHERE Request_Key__c =
                :requestKey
            LIMIT 1
        ];

        return actions.isEmpty()
            ? null
            : actions[0];
    }

    private static TransitionResult replayTransition(
        Id paymentId,
        String expectedAction,
        String expectedState,
        Business_Action__c priorAction
    ) {
        if (
            priorAction.Source_Type__c
                != 'Accounting_Payment__c'
            || priorAction.Source_Record_Id__c
                != String.valueOf(
                    paymentId
                )
            || priorAction.Action__c
                != expectedAction
        ) {
            throw new SupplierPaymentException(
                'The request key has already been used for a different financial action.'
            );
        }

        Accounting_Payment__c payment = [
            SELECT Id, Processing_State__c
            FROM Accounting_Payment__c
            WHERE Id = :paymentId
            LIMIT 1
        ];

        if (
            payment.Processing_State__c
            != expectedState
        ) {
            throw new SupplierPaymentException(
                'The request key was already processed, but the Payment is no longer in the expected state.'
            );
        }

        return buildTransitionResult(
            payment.Id,
            null,
            expectedState,
            priorAction.Id,
            true
        );
    }

    private static Business_Action__c createBusinessAction(
        Accounting_Payment__c payment,
        String actionName,
        String requestKey,
        String reason
    ) {
        Business_Action__c action =
            new Business_Action__c(
                Company__c =
                    payment.Company__c,
                Source_Type__c =
                    'Accounting_Payment__c',
                Source_Record_Id__c =
                    String.valueOf(
                        payment.Id
                    ),
                Action__c =
                    actionName,
                Actor__c =
                    UserInfo.getUserId(),
                Action_At__c =
                    System.now(),
                Reason__c =
                    reason,
                Request_Key__c =
                    requestKey
            );

        insert action;
        return action;
    }

    private static TransitionResult buildTransitionResult(
        Id paymentId,
        String previousState,
        String newState,
        Id businessActionId,
        Boolean replay
    ) {
        TransitionResult result =
            new TransitionResult();

        result.paymentId =
            paymentId;
        result.previousState =
            previousState;
        result.newState =
            newState;
        result.businessActionId =
            businessActionId;
        result.idempotentReplay =
            replay;

        return result;
    }

    private static void throwIfInvalid(
        ValidationResult validation
    ) {
        if (
            validation != null
            && validation.isValid != true
        ) {
            throw new SupplierPaymentException(
                String.join(
                    validation.errors,
                    ' | '
                )
            );
        }
    }

    private static void requireRequestKey(
        String requestKey
    ) {
        if (String.isBlank(requestKey)) {
            throw new SupplierPaymentException(
                'Request Key is required for a Supplier Payment lifecycle action.'
            );
        }

        if (requestKey.length() > 160) {
            throw new SupplierPaymentException(
                'Request Key cannot exceed 160 characters.'
            );
        }
    }

    private static void requireProviderRequestKey(
        String providerRequestKey
    ) {
        if (
            String.isBlank(
                providerRequestKey
            )
        ) {
            throw new SupplierPaymentException(
                'Provider Request Key is required when submitting a Payment for execution.'
            );
        }

        if (
            providerRequestKey.length()
            > 160
        ) {
            throw new SupplierPaymentException(
                'Provider Request Key cannot exceed 160 characters.'
            );
        }
    }

    private static void requireReason(
        String reason,
        String message
    ) {
        if (String.isBlank(reason)) {
            throw new SupplierPaymentException(
                message
            );
        }
    }
}
