/**
 * G4B - Customer Receipt / AR Receipt lifecycle.
 *
 * Processing-state contract:
 *
 * Draft
 *   -> Authorized
 *   -> Submitted
 *   -> Succeeded   (only through SABCustomerReceiptPostingService)
 *
 * Submitted
 *   -> Failed
 *
 * Failed
 *   -> Submitted   (retry preserves Provider_Request_Key__c)
 *
 * Reversed is reserved for the later receipt reversal/refund implementation.
 *
 * Financial contract:
 * - Draft/Authorized/Submitted/Failed do not imply cash settlement.
 * - Only Succeeded may hold Accounting_Event__c.
 * - G4B supports same-currency customer receipts.
 * - Allocation to invoices is intentionally separate and belongs to G4C.
 */
public with sharing class SABCustomerReceiptService {

    public class CustomerReceiptException extends Exception {}

    private static final String STATE_DRAFT = 'Draft';
    private static final String STATE_AUTHORIZED = 'Authorized';
    private static final String STATE_SUBMITTED = 'Submitted';
    private static final String STATE_SUCCEEDED = 'Succeeded';
    private static final String STATE_FAILED = 'Failed';
    private static final String STATE_REVERSED = 'Reversed';

    private static final String DIRECTION_RECEIPT = 'Receipt';

    private static final String APPROVE_PERMISSION =
        'SAB_Approve_Financial_Document';

    private static final String POST_PERMISSION =
        'SAB_Post_Journal';

    private static final Decimal ZERO = Decimal.valueOf('0');

    public class ValidationResult {
        @AuraEnabled public Boolean isValid { get; private set; }
        @AuraEnabled public List<String> errors { get; private set; }
        @AuraEnabled public String functionalCurrency { get; private set; }
        @AuraEnabled public Decimal normalizedAmount { get; private set; }

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
        @AuraEnabled public Id paymentId { get; private set; }
        @AuraEnabled public String previousState { get; private set; }
        @AuraEnabled public String newState { get; private set; }
        @AuraEnabled public Id businessActionId { get; private set; }
        @AuraEnabled public Boolean idempotentReplay { get; private set; }
    }

    @AuraEnabled
    public static ValidationResult validateForAuthorization(Id paymentId) {
        Accounting_Payment__c receipt = loadReceipt(paymentId, false);
        assertCanReadReceipt(receipt);
        return validateReceipt(receipt);
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

        Business_Action__c priorAction = findPriorAction(requestKey);
        if (priorAction != null) {
            return replayTransition(
                paymentId,
                'CUSTOMER_RECEIPT_AUTHORIZED',
                STATE_AUTHORIZED,
                priorAction
            );
        }

        Accounting_Payment__c receipt = loadReceipt(paymentId, true);
        assertCanEditReceipt(receipt);

        if (receipt.Processing_State__c != STATE_DRAFT) {
            throw new CustomerReceiptException(
                'Customer Receipt must be Draft before authorization. Current state: '
                + receipt.Processing_State__c
                + '.'
            );
        }

        ValidationResult validation = validateReceipt(receipt);
        throwIfInvalid(validation);

        String previousState = receipt.Processing_State__c;

        receipt.Functional_Currency__c = validation.functionalCurrency;
        receipt.Exchange_Rate__c = Decimal.valueOf('1');
        receipt.Processing_State__c = STATE_AUTHORIZED;

        controlledUpdate(receipt);

        Business_Action__c action = createBusinessAction(
            receipt,
            'CUSTOMER_RECEIPT_AUTHORIZED',
            requestKey,
            'Customer Receipt authorized.'
        );

        return buildTransitionResult(
            receipt.Id,
            previousState,
            STATE_AUTHORIZED,
            action.Id,
            false
        );
    }

    /**
     * Records that the receipt was submitted to/recognized by the payment
     * channel or bank process. This does not create accounting yet.
     */
    @AuraEnabled
    public static TransitionResult submitForProcessing(
        Id paymentId,
        String providerRequestKey,
        String requestKey
    ) {
        requireRequestKey(requestKey);
        requireProviderRequestKey(providerRequestKey);

        Business_Action__c priorAction = findPriorAction(requestKey);
        if (priorAction != null) {
            return replayTransition(
                paymentId,
                'CUSTOMER_RECEIPT_SUBMITTED',
                STATE_SUBMITTED,
                priorAction
            );
        }

        Accounting_Payment__c receipt = loadReceipt(paymentId, true);
        assertCanEditReceipt(receipt);

        if (receipt.Processing_State__c != STATE_AUTHORIZED) {
            throw new CustomerReceiptException(
                'Customer Receipt must be Authorized before submission. Current state: '
                + receipt.Processing_State__c
                + '.'
            );
        }

        ValidationResult validation = validateReceipt(receipt);
        throwIfInvalid(validation);

        assertProviderRequestKeyAvailable(
            receipt,
            providerRequestKey.trim()
        );

        String previousState = receipt.Processing_State__c;

        receipt.Provider_Request_Key__c = providerRequestKey.trim();
        receipt.Processing_State__c = STATE_SUBMITTED;

        controlledUpdate(receipt);

        Business_Action__c action = createBusinessAction(
            receipt,
            'CUSTOMER_RECEIPT_SUBMITTED',
            requestKey,
            'Customer Receipt submitted for processing. Provider request key: '
                + receipt.Provider_Request_Key__c
        );

        return buildTransitionResult(
            receipt.Id,
            previousState,
            STATE_SUBMITTED,
            action.Id,
            false
        );
    }

    @AuraEnabled
    public static TransitionResult markFailed(
        Id paymentId,
        String requestKey,
        String reason
    ) {
        requireRequestKey(requestKey);
        requireReason(reason, 'A failure reason is required.');

        Business_Action__c priorAction = findPriorAction(requestKey);
        if (priorAction != null) {
            return replayTransition(
                paymentId,
                'CUSTOMER_RECEIPT_FAILED',
                STATE_FAILED,
                priorAction
            );
        }

        Accounting_Payment__c receipt = loadReceipt(paymentId, true);
        assertCanEditReceipt(receipt);

        if (receipt.Processing_State__c != STATE_SUBMITTED) {
            throw new CustomerReceiptException(
                'Only a Submitted Customer Receipt can be marked Failed.'
            );
        }

        if (receipt.Accounting_Event__c != null) {
            throw new CustomerReceiptException(
                'A Customer Receipt linked to an Accounting Event cannot be marked Failed.'
            );
        }

        String previousState = receipt.Processing_State__c;
        receipt.Processing_State__c = STATE_FAILED;
        controlledUpdate(receipt);

        Business_Action__c action = createBusinessAction(
            receipt,
            'CUSTOMER_RECEIPT_FAILED',
            requestKey,
            reason.trim()
        );

        return buildTransitionResult(
            receipt.Id,
            previousState,
            STATE_FAILED,
            action.Id,
            false
        );
    }

    @AuraEnabled
    public static TransitionResult retryFailed(
        Id paymentId,
        String requestKey
    ) {
        requireRequestKey(requestKey);

        Business_Action__c priorAction = findPriorAction(requestKey);
        if (priorAction != null) {
            return replayTransition(
                paymentId,
                'CUSTOMER_RECEIPT_RETRIED',
                STATE_SUBMITTED,
                priorAction
            );
        }

        Accounting_Payment__c receipt = loadReceipt(paymentId, true);
        assertCanEditReceipt(receipt);

        if (receipt.Processing_State__c != STATE_FAILED) {
            throw new CustomerReceiptException(
                'Only a Failed Customer Receipt can be retried.'
            );
        }

        if (String.isBlank(receipt.Provider_Request_Key__c)) {
            throw new CustomerReceiptException(
                'Failed Customer Receipt is missing its stable Provider Request Key.'
            );
        }

        if (receipt.Accounting_Event__c != null) {
            throw new CustomerReceiptException(
                'A Customer Receipt linked to an Accounting Event cannot be retried.'
            );
        }

        ValidationResult validation = validateReceipt(receipt);
        throwIfInvalid(validation);

        String previousState = receipt.Processing_State__c;
        receipt.Processing_State__c = STATE_SUBMITTED;
        controlledUpdate(receipt);

        Business_Action__c action = createBusinessAction(
            receipt,
            'CUSTOMER_RECEIPT_RETRIED',
            requestKey,
            'Customer Receipt processing retried using the existing Provider Request Key.'
        );

        return buildTransitionResult(
            receipt.Id,
            previousState,
            STATE_SUBMITTED,
            action.Id,
            false
        );
    }

    /**
     * Called immediately before G4B financial posting.
     */
    public static void assertSubmittedForPosting(Id paymentId) {
        Accounting_Payment__c receipt = loadReceipt(paymentId, true);
        assertCanEditReceipt(receipt);

        if (receipt.Processing_State__c != STATE_SUBMITTED) {
            throw new CustomerReceiptException(
                'Customer Receipt must be Submitted before successful settlement can be posted.'
            );
        }

        if (String.isBlank(receipt.Provider_Request_Key__c)) {
            throw new CustomerReceiptException(
                'Submitted Customer Receipt requires a Provider Request Key.'
            );
        }

        if (receipt.Accounting_Event__c != null) {
            throw new CustomerReceiptException(
                'Submitted Customer Receipt must not already contain an Accounting Event.'
            );
        }

        ValidationResult validation = validateReceipt(receipt);
        throwIfInvalid(validation);
    }

    /**
     * Completes the receipt only after SABPostingService has created a Posted
     * Subledger Journal and Posted Accounting Event for this receipt.
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
            throw new CustomerReceiptException(
                'Accounting Event Id is required to complete Customer Receipt posting.'
            );
        }

        if (journalEntryId == null) {
            throw new CustomerReceiptException(
                'Journal Entry Id is required to complete Customer Receipt posting.'
            );
        }

        Accounting_Payment__c receipt = [
            SELECT Id, Company__c, Direction__c,
                   Processing_State__c, Accounting_Event__c,
                   Provider_Request_Key__c
            FROM Accounting_Payment__c
            WHERE Id = :paymentId
            LIMIT 1
            FOR UPDATE
        ];

        if (receipt.Processing_State__c == STATE_SUCCEEDED) {
            assertCanReadReceipt(receipt);

            if (receipt.Accounting_Event__c != accountingEventId) {
                throw new CustomerReceiptException(
                    'Succeeded Customer Receipt is linked to a different Accounting Event.'
                );
            }

            Business_Action__c priorAction = findPriorAction(requestKey);

            return buildTransitionResult(
                receipt.Id,
                null,
                STATE_SUCCEEDED,
                priorAction == null ? null : priorAction.Id,
                true
            );
        }

        assertCanEditReceipt(receipt);

        if (receipt.Processing_State__c != STATE_SUBMITTED) {
            throw new CustomerReceiptException(
                'Customer Receipt must be Submitted before successful posting can be completed.'
            );
        }

        if (receipt.Direction__c != DIRECTION_RECEIPT) {
            throw new CustomerReceiptException(
                'G4B Customer Receipt posting supports Receipt direction only.'
            );
        }

        Accounting_Event__c eventRecord = [
            SELECT Id, Company__c, Event_Type__c,
                   Source_Type__c, Source_Record_Id__c,
                   State__c, Journal_Entry__c
            FROM Accounting_Event__c
            WHERE Id = :accountingEventId
            LIMIT 1
        ];

        if (
            eventRecord.Company__c != receipt.Company__c
            || eventRecord.Event_Type__c != 'Payment Receipt'
            || eventRecord.Source_Type__c != 'Accounting_Payment__c'
            || eventRecord.Source_Record_Id__c != String.valueOf(receipt.Id)
            || eventRecord.State__c != 'Posted'
            || eventRecord.Journal_Entry__c != journalEntryId
        ) {
            throw new CustomerReceiptException(
                'Accounting Event does not represent this completed Customer Receipt.'
            );
        }

        Journal_Entry__c journal = [
            SELECT Id, Company__c, Entry_Type__c,
                   Status__c, Accounting_Event__c
            FROM Journal_Entry__c
            WHERE Id = :journalEntryId
            LIMIT 1
        ];

        if (
            journal.Company__c != receipt.Company__c
            || journal.Entry_Type__c != 'Subledger'
            || journal.Status__c != 'Posted'
            || journal.Accounting_Event__c != accountingEventId
        ) {
            throw new CustomerReceiptException(
                'Journal Entry does not represent a completed Customer Receipt subledger posting.'
            );
        }

        receipt.Accounting_Event__c = accountingEventId;
        receipt.Processing_State__c = STATE_SUCCEEDED;
        controlledUpdate(receipt);

        Business_Action__c action = createBusinessAction(
            receipt,
            'CUSTOMER_RECEIPT_SUCCEEDED',
            requestKey,
            'Customer Receipt succeeded and was posted to Bank and Accounts Receivable.'
        );

        return buildTransitionResult(
            receipt.Id,
            STATE_SUBMITTED,
            STATE_SUCCEEDED,
            action.Id,
            false
        );
    }

    private static Accounting_Payment__c loadReceipt(
        Id paymentId,
        Boolean lockRecord
    ) {
        if (paymentId == null) {
            throw new CustomerReceiptException(
                'Customer Receipt Id is required.'
            );
        }

        List<Accounting_Payment__c> receipts;

        if (lockRecord) {
            receipts = [
                SELECT Id, Name, Company__c,
                       Company__r.Functional_Currency__c,
                       Company__r.Is_Active__c,
                       Party_Profile__c,
                       Party_Profile__r.Company__c,
                       Party_Profile__r.Is_Active__c,
                       Party_Profile__r.Is_Customer__c,
                       Party_Profile__r.AR_Control_Account__c,
                       Party_Profile__r.AR_Control_Account__r.Company__c,
                       Party_Profile__r.AR_Control_Account__r.Account_Type__c,
                       Party_Profile__r.AR_Control_Account__r.Is_Active__c,
                       Party_Profile__r.AR_Control_Account__r.Is_Control_Account__c,
                       Party_Profile__r.AR_Control_Account__r.Control_Type__c,
                       Bank_Account__c,
                       Bank_Account__r.Company__c,
                       Bank_Account__r.Currency__c,
                       Bank_Account__r.Is_Active__c,
                       Bank_Account__r.GL_Account__c,
                       Bank_Account__r.GL_Account__r.Company__c,
                       Bank_Account__r.GL_Account__r.Account_Type__c,
                       Bank_Account__r.GL_Account__r.Is_Active__c,
                       Direction__c, Method__c, Reference__c,
                       Amount__c, Transaction_Currency__c,
                       Functional_Currency__c, Exchange_Rate__c,
                       Effective_Date__c, Processing_State__c,
                       Provider_Request_Key__c, Accounting_Event__c
                FROM Accounting_Payment__c
                WHERE Id = :paymentId
                LIMIT 1
                FOR UPDATE
            ];
        } else {
            receipts = [
                SELECT Id, Name, Company__c,
                       Company__r.Functional_Currency__c,
                       Company__r.Is_Active__c,
                       Party_Profile__c,
                       Party_Profile__r.Company__c,
                       Party_Profile__r.Is_Active__c,
                       Party_Profile__r.Is_Customer__c,
                       Party_Profile__r.AR_Control_Account__c,
                       Party_Profile__r.AR_Control_Account__r.Company__c,
                       Party_Profile__r.AR_Control_Account__r.Account_Type__c,
                       Party_Profile__r.AR_Control_Account__r.Is_Active__c,
                       Party_Profile__r.AR_Control_Account__r.Is_Control_Account__c,
                       Party_Profile__r.AR_Control_Account__r.Control_Type__c,
                       Bank_Account__c,
                       Bank_Account__r.Company__c,
                       Bank_Account__r.Currency__c,
                       Bank_Account__r.Is_Active__c,
                       Bank_Account__r.GL_Account__c,
                       Bank_Account__r.GL_Account__r.Company__c,
                       Bank_Account__r.GL_Account__r.Account_Type__c,
                       Bank_Account__r.GL_Account__r.Is_Active__c,
                       Direction__c, Method__c, Reference__c,
                       Amount__c, Transaction_Currency__c,
                       Functional_Currency__c, Exchange_Rate__c,
                       Effective_Date__c, Processing_State__c,
                       Provider_Request_Key__c, Accounting_Event__c
                FROM Accounting_Payment__c
                WHERE Id = :paymentId
                LIMIT 1
            ];
        }

        if (receipts.isEmpty()) {
            throw new CustomerReceiptException(
                'Customer Receipt was not found or is not accessible.'
            );
        }

        return receipts[0];
    }

    private static ValidationResult validateReceipt(
        Accounting_Payment__c receipt
    ) {
        ValidationResult result = new ValidationResult();

        if (receipt.Company__c == null) {
            result.addError('Accounting Company is required.');
            return result;
        }

        try {
            SABCompanyAccessService.assertCompanyAccess(receipt.Company__c);
        } catch (Exception ex) {
            result.addError(
                'You do not have active access to the Receipt Accounting Company.'
            );
        }

        if (
            receipt.Company__r == null
            || receipt.Company__r.Is_Active__c != true
        ) {
            result.addError('Accounting Company must be active.');
        }

        if (receipt.Direction__c != DIRECTION_RECEIPT) {
            result.addError(
                'G4B Customer Receipt supports Direction = Receipt only.'
            );
        }

        if (String.isBlank(receipt.Method__c)) {
            result.addError('Payment Method is required.');
        }

        if (receipt.Amount__c == null || receipt.Amount__c <= ZERO) {
            result.addError('Receipt Amount must be greater than zero.');
        } else {
            result.normalizedAmount =
                SABMoneyService.normalizeTransactionAmount(
                    receipt.Amount__c,
                    RoundingMode.HALF_UP
                );

            if (result.normalizedAmount <= ZERO) {
                result.addError(
                    'Receipt Amount rounds to zero and cannot be processed.'
                );
            }
        }

        if (receipt.Effective_Date__c == null) {
            result.addError('Receipt Effective Date is required.');
        } else {
            validateOpenAccountingPeriod(receipt, result);
        }

        validateCustomerProfile(receipt, result);
        validateBankAccount(receipt, result);
        validateCurrency(receipt, result);

        if (
            receipt.Processing_State__c != STATE_DRAFT
            && receipt.Accounting_Event__c != null
            && receipt.Processing_State__c != STATE_SUCCEEDED
            && receipt.Processing_State__c != STATE_REVERSED
        ) {
            result.addError(
                'Only Succeeded or Reversed Receipts may contain an Accounting Event.'
            );
        }

        return result;
    }

    private static void validateCustomerProfile(
        Accounting_Payment__c receipt,
        ValidationResult result
    ) {
        if (receipt.Party_Profile__c == null) {
            result.addError(
                'Customer Party Accounting Profile is required.'
            );
            return;
        }

        Party_Accounting_Profile__c profile = receipt.Party_Profile__r;

        if (profile == null) {
            result.addError(
                'Customer Party Accounting Profile is not accessible.'
            );
            return;
        }

        if (profile.Company__c != receipt.Company__c) {
            result.addError(
                'Customer Party Accounting Profile must belong to the Receipt Accounting Company.'
            );
        }

        if (profile.Is_Active__c != true) {
            result.addError(
                'Customer Party Accounting Profile must be active.'
            );
        }

        if (profile.Is_Customer__c != true) {
            result.addError(
                'Party Accounting Profile must be enabled as a customer.'
            );
        }

        if (profile.AR_Control_Account__c == null) {
            result.addError(
                'Customer Party Accounting Profile requires an AR Control Account.'
            );
            return;
        }

        GL_Account__c arAccount = profile.AR_Control_Account__r;

        if (
            arAccount == null
            || arAccount.Company__c != receipt.Company__c
            || arAccount.Is_Active__c != true
            || arAccount.Account_Type__c != 'Asset'
            || arAccount.Is_Control_Account__c != true
            || arAccount.Control_Type__c != 'AR'
        ) {
            result.addError(
                'Customer AR Control Account must be an active AR Asset control account in the same Accounting Company.'
            );
        }
    }

    private static void validateBankAccount(
        Accounting_Payment__c receipt,
        ValidationResult result
    ) {
        if (receipt.Bank_Account__c == null) {
            result.addError('Bank Account is required.');
            return;
        }

        Bank_Account__c bankAccount = receipt.Bank_Account__r;

        if (bankAccount == null) {
            result.addError('Bank Account is not accessible.');
            return;
        }

        if (bankAccount.Company__c != receipt.Company__c) {
            result.addError(
                'Bank Account must belong to the Receipt Accounting Company.'
            );
        }

        if (bankAccount.Is_Active__c != true) {
            result.addError('Bank Account must be active.');
        }

        if (bankAccount.GL_Account__c == null) {
            result.addError('Bank Account requires a mapped GL Account.');
            return;
        }

        GL_Account__c bankGL = bankAccount.GL_Account__r;

        if (
            bankGL == null
            || bankGL.Company__c != receipt.Company__c
            || bankGL.Is_Active__c != true
            || bankGL.Account_Type__c != 'Asset'
        ) {
            result.addError(
                'Bank Account GL mapping must be an active Asset account in the same Accounting Company.'
            );
        }
    }

    private static void validateCurrency(
        Accounting_Payment__c receipt,
        ValidationResult result
    ) {
        if (receipt.Company__r == null || receipt.Bank_Account__r == null) {
            return;
        }

        String companyCurrency;
        String receiptCurrency;
        String bankCurrency;

        try {
            companyCurrency = SABMoneyService.normalizeCurrencyCode(
                receipt.Company__r.Functional_Currency__c
            );
        } catch (Exception ex) {
            result.addError(
                'Accounting Company Functional Currency is invalid.'
            );
            return;
        }

        try {
            receiptCurrency = SABMoneyService.normalizeCurrencyCode(
                receipt.Transaction_Currency__c
            );
        } catch (Exception ex) {
            result.addError(
                'Receipt Transaction Currency must be a valid 3-letter currency code.'
            );
            return;
        }

        try {
            bankCurrency = SABMoneyService.normalizeCurrencyCode(
                receipt.Bank_Account__r.Currency__c
            );
        } catch (Exception ex) {
            result.addError(
                'Bank Account Currency must be a valid 3-letter currency code.'
            );
            return;
        }

        if (receipt.Transaction_Currency__c != receiptCurrency) {
            result.addError(
                'Receipt Transaction Currency must be stored as a 3-letter uppercase code.'
            );
        }

        if (receipt.Bank_Account__r.Currency__c != bankCurrency) {
            result.addError(
                'Bank Account Currency must be stored as a 3-letter uppercase code.'
            );
        }

        if (receiptCurrency != bankCurrency) {
            result.addError(
                'Receipt Transaction Currency must match the selected Bank Account Currency.'
            );
        }

        if (receiptCurrency != companyCurrency) {
            result.addError(
                'G4B currently supports same-currency customer receipts only. Foreign-currency settlement is deferred until allocation carrying values and realized-FX policy are implemented.'
            );
        }

        if (!String.isBlank(receipt.Functional_Currency__c)) {
            String storedFunctional;

            try {
                storedFunctional = SABMoneyService.normalizeCurrencyCode(
                    receipt.Functional_Currency__c
                );
            } catch (Exception ex) {
                result.addError(
                    'Receipt Functional Currency must be a valid 3-letter currency code.'
                );
                return;
            }

            if (storedFunctional != companyCurrency) {
                result.addError(
                    'Receipt Functional Currency must match the Accounting Company Functional Currency.'
                );
            }
        }

        if (
            receipt.Exchange_Rate__c != null
            && receipt.Exchange_Rate__c != Decimal.valueOf('1')
        ) {
            result.addError(
                'Same-currency Customer Receipts must use an Exchange Rate of 1 when a rate is stored.'
            );
        }

        result.functionalCurrency = companyCurrency;
    }

    private static void validateOpenAccountingPeriod(
        Accounting_Payment__c receipt,
        ValidationResult result
    ) {
        List<Accounting_Period__c> periods = [
            SELECT Id, Status__c
            FROM Accounting_Period__c
            WHERE Company__c = :receipt.Company__c
              AND Start_Date__c <= :receipt.Effective_Date__c
              AND End_Date__c >= :receipt.Effective_Date__c
            LIMIT 2
        ];

        if (periods.isEmpty()) {
            result.addError(
                'No Accounting Period contains the Receipt Effective Date.'
            );
            return;
        }

        if (periods.size() > 1) {
            result.addError(
                'More than one Accounting Period contains the Receipt Effective Date.'
            );
            return;
        }

        if (periods[0].Status__c != 'Open') {
            result.addError(
                'Receipt Effective Date must be in an Open Accounting Period.'
            );
        }
    }

    private static void assertProviderRequestKeyAvailable(
        Accounting_Payment__c receipt,
        String providerRequestKey
    ) {
        List<Accounting_Payment__c> duplicates = [
            SELECT Id
            FROM Accounting_Payment__c
            WHERE Company__c = :receipt.Company__c
              AND Provider_Request_Key__c = :providerRequestKey
              AND Id != :receipt.Id
            LIMIT 1
        ];

        if (!duplicates.isEmpty()) {
            throw new CustomerReceiptException(
                'Provider Request Key is already assigned to another Payment in this Accounting Company.'
            );
        }
    }

    private static void assertCanReadReceipt(Accounting_Payment__c receipt) {
        SABAccessControlService.assertReadable(
            Accounting_Payment__c.SObjectType,
            receiptReadFields()
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
                Party_Accounting_Profile__c.Is_Customer__c,
                Party_Accounting_Profile__c.AR_Control_Account__c
            }
        );

        SABCompanyAccessService.assertCompanyAccess(receipt.Company__c);
        SABAccessControlService.assertRecordReadAccess(receipt.Id);
    }

    private static void assertCanEditReceipt(Accounting_Payment__c receipt) {
        assertCanReadReceipt(receipt);

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

        SABAccessControlService.assertRecordEditAccess(receipt.Id);
    }

    private static List<Schema.SObjectField> receiptReadFields() {
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

    private static void controlledUpdate(Accounting_Payment__c receipt) {
        SABAccountingPaymentMutationContext.beginMutation();
        try {
            update receipt;
        } finally {
            SABAccountingPaymentMutationContext.endMutation();
        }
    }

    private static Business_Action__c findPriorAction(String requestKey) {
        List<Business_Action__c> actions = [
            SELECT Id, Action__c, Source_Type__c,
                   Source_Record_Id__c, Request_Key__c
            FROM Business_Action__c
            WHERE Request_Key__c = :requestKey
            LIMIT 1
        ];

        return actions.isEmpty() ? null : actions[0];
    }

    private static TransitionResult replayTransition(
        Id paymentId,
        String expectedAction,
        String expectedState,
        Business_Action__c priorAction
    ) {
        if (
            priorAction.Source_Type__c != 'Accounting_Payment__c'
            || priorAction.Source_Record_Id__c != String.valueOf(paymentId)
            || priorAction.Action__c != expectedAction
        ) {
            throw new CustomerReceiptException(
                'The request key has already been used for a different financial action.'
            );
        }

        Accounting_Payment__c receipt = [
            SELECT Id, Direction__c, Processing_State__c
            FROM Accounting_Payment__c
            WHERE Id = :paymentId
            LIMIT 1
        ];

        if (
            receipt.Direction__c != DIRECTION_RECEIPT
            || receipt.Processing_State__c != expectedState
        ) {
            throw new CustomerReceiptException(
                'The request key was already processed, but the Customer Receipt is no longer in the expected state.'
            );
        }

        return buildTransitionResult(
            receipt.Id,
            null,
            expectedState,
            priorAction.Id,
            true
        );
    }

    private static Business_Action__c createBusinessAction(
        Accounting_Payment__c receipt,
        String actionName,
        String requestKey,
        String reason
    ) {
        Business_Action__c action = new Business_Action__c(
            Company__c = receipt.Company__c,
            Source_Type__c = 'Accounting_Payment__c',
            Source_Record_Id__c = String.valueOf(receipt.Id),
            Action__c = actionName,
            Actor__c = UserInfo.getUserId(),
            Action_At__c = System.now(),
            Reason__c = reason,
            Request_Key__c = requestKey
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
        TransitionResult result = new TransitionResult();
        result.paymentId = paymentId;
        result.previousState = previousState;
        result.newState = newState;
        result.businessActionId = businessActionId;
        result.idempotentReplay = replay;
        return result;
    }

    private static void throwIfInvalid(ValidationResult validation) {
        if (validation != null && validation.isValid != true) {
            throw new CustomerReceiptException(
                String.join(validation.errors, ' | ')
            );
        }
    }

    private static void requireRequestKey(String requestKey) {
        if (String.isBlank(requestKey)) {
            throw new CustomerReceiptException(
                'Request Key is required for a Customer Receipt lifecycle action.'
            );
        }

        if (requestKey.trim().length() > 160) {
            throw new CustomerReceiptException(
                'Request Key cannot exceed 160 characters.'
            );
        }
    }

    private static void requireProviderRequestKey(String providerRequestKey) {
        if (String.isBlank(providerRequestKey)) {
            throw new CustomerReceiptException(
                'Provider Request Key is required when submitting a Customer Receipt for processing.'
            );
        }

        if (providerRequestKey.trim().length() > 160) {
            throw new CustomerReceiptException(
                'Provider Request Key cannot exceed 160 characters.'
            );
        }
    }

    private static void requireReason(String reason, String message) {
        if (String.isBlank(reason)) {
            throw new CustomerReceiptException(message);
        }
    }
}
