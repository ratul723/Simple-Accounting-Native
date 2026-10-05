/**
 * G8C - Employee Expense Reimbursement Payment lifecycle and posting.
 *
 * Functional-currency scope:
 * Draft -> Authorized -> Submitted -> Succeeded
 *
 * Successful reimbursement posting:
 *   Dr Employee Reimbursement Liability
 *   Cr Bank / Cash
 *
 * Claim allocation is intentionally separated into
 * SABExpenseClaimSettlementService so one payment can settle one or more
 * posted Expense Claims and one claim can be reimbursed in parts.
 */
public without sharing class SABExpenseReimbursementPaymentService {

    public class ExpenseReimbursementException extends Exception {}

    private static final String PERMISSION =
        'SAB_Process_Expense_Reimbursement';
    private static final String STATE_DRAFT = 'Draft';
    private static final String STATE_AUTHORIZED = 'Authorized';
    private static final String STATE_SUBMITTED = 'Submitted';
    private static final String STATE_SUCCEEDED = 'Succeeded';
    private static final String DIRECTION = 'Disbursement';
    private static final String SOURCE_TYPE = 'Accounting_Payment__c';
    private static final String ADAPTER_KEY = 'EXPENSE_REIMBURSEMENT';
    private static final Decimal ZERO = Decimal.valueOf('0');

    public class PaymentResult {
        @AuraEnabled public Id paymentId { get; private set; }
        @AuraEnabled public String state { get; private set; }
        @AuraEnabled public Id journalEntryId { get; private set; }
        @AuraEnabled public Id accountingEventId { get; private set; }
        @AuraEnabled public String postingKey { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private PaymentResult() {}
    }

    @AuraEnabled
    public static PaymentResult authorizePayment(
        Id paymentId,
        String requestKey
    ) {
        assertPermission();
        validateRequestKey(requestKey);

        Business_Action__c prior =
            findPriorAction(requestKey);

        if (prior != null) {
            return replayLifecycleAction(
                paymentId,
                prior,
                'EXPENSE_REIMBURSEMENT_AUTHORIZED',
                STATE_AUTHORIZED
            );
        }

        Accounting_Payment__c payment =
            loadPayment(paymentId, true);

        SABCompanyAccessService.assertCompanyAccess(
            payment.Company__c
        );

        if (payment.Processing_State__c != STATE_DRAFT) {
            throw new ExpenseReimbursementException(
                'Expense Reimbursement Payment must be Draft before authorization.'
            );
        }

        validatePaymentConfiguration(payment);

        payment.Functional_Currency__c =
            SABMoneyService.normalizeCurrencyCode(
                payment.Company__r.Functional_Currency__c
            );
        payment.Exchange_Rate__c =
            Decimal.valueOf('1');
        payment.Processing_State__c =
            STATE_AUTHORIZED;

        controlledPaymentUpdate(payment);

        createAction(
            payment.Company__c,
            payment.Id,
            'EXPENSE_REIMBURSEMENT_AUTHORIZED',
            requestKey,
            'Employee expense reimbursement payment authorized.'
        );

        return buildPaymentResult(
            payment.Id,
            STATE_AUTHORIZED,
            null,
            null,
            null,
            false
        );
    }

    @AuraEnabled
    public static PaymentResult submitPayment(
        Id paymentId,
        String providerRequestKey,
        String requestKey
    ) {
        assertPermission();
        validateRequestKey(requestKey);

        if (String.isBlank(providerRequestKey)) {
            throw new ExpenseReimbursementException(
                'Provider Request Key is required.'
            );
        }

        Integer providerMax =
            Accounting_Payment__c.Provider_Request_Key__c.getDescribe().getLength();

        if (
            providerMax > 0
            && providerRequestKey.trim().length() > providerMax
        ) {
            throw new ExpenseReimbursementException(
                'Provider Request Key is too long.'
            );
        }

        Business_Action__c prior =
            findPriorAction(requestKey);

        if (prior != null) {
            return replayLifecycleAction(
                paymentId,
                prior,
                'EXPENSE_REIMBURSEMENT_SUBMITTED',
                STATE_SUBMITTED
            );
        }

        Accounting_Payment__c payment =
            loadPayment(paymentId, true);

        SABCompanyAccessService.assertCompanyAccess(
            payment.Company__c
        );

        if (payment.Processing_State__c != STATE_AUTHORIZED) {
            throw new ExpenseReimbursementException(
                'Expense Reimbursement Payment must be Authorized before submission.'
            );
        }

        validatePaymentConfiguration(payment);
        assertProviderRequestKeyAvailable(
            payment,
            providerRequestKey.trim()
        );

        payment.Provider_Request_Key__c =
            providerRequestKey.trim();
        payment.Processing_State__c =
            STATE_SUBMITTED;

        controlledPaymentUpdate(payment);

        createAction(
            payment.Company__c,
            payment.Id,
            'EXPENSE_REIMBURSEMENT_SUBMITTED',
            requestKey,
            'Employee expense reimbursement payment submitted for execution.'
        );

        return buildPaymentResult(
            payment.Id,
            STATE_SUBMITTED,
            null,
            null,
            null,
            false
        );
    }

    /**
     * Call only after the bank/provider has confirmed success.
     */
    @AuraEnabled
    public static PaymentResult recordSucceededAndPost(
        Id paymentId,
        String requestKey
    ) {
        assertPermission();
        validateRequestKey(requestKey);

        Accounting_Payment__c initial =
            loadPayment(paymentId, false);

        SABCompanyAccessService.assertCompanyAccess(
            initial.Company__c
        );

        if (initial.Processing_State__c == STATE_SUCCEEDED) {
            return resolveSucceededReplay(initial);
        }

        if (initial.Processing_State__c != STATE_SUBMITTED) {
            throw new ExpenseReimbursementException(
                'Expense Reimbursement Payment must be Submitted before successful posting.'
            );
        }

        Savepoint sp = Database.setSavepoint();

        try {
            Accounting_Payment__c payment =
                loadPayment(paymentId, true);

            if (payment.Processing_State__c == STATE_SUCCEEDED) {
                return resolveSucceededReplay(payment);
            }

            if (payment.Processing_State__c != STATE_SUBMITTED) {
                throw new ExpenseReimbursementException(
                    'Expense Reimbursement Payment changed while posting. Retry the request.'
                );
            }

            if (String.isBlank(payment.Provider_Request_Key__c)) {
                throw new ExpenseReimbursementException(
                    'Submitted Expense Reimbursement Payment requires a Provider Request Key.'
                );
            }

            if (payment.Accounting_Event__c != null) {
                throw new ExpenseReimbursementException(
                    'Submitted Expense Reimbursement Payment already contains an Accounting Event.'
                );
            }

            validatePaymentConfiguration(payment);

            Accounting_Period__c period =
                resolveAndLockOpenPeriod(
                    payment.Company__c,
                    payment.Effective_Date__c
                );

            Decimal amount =
                SABMoneyService.normalizeLedgerAmount(
                    payment.Amount__c,
                    RoundingMode.HALF_UP
                );

            if (amount <= ZERO) {
                throw new ExpenseReimbursementException(
                    'Expense Reimbursement Payment amount must be greater than zero.'
                );
            }

            Id liabilityAccountId =
                payment.Company__r.Employee_Reimbursement_Liability_Account__c;

            Id bankGLAccountId =
                payment.Bank_Account__r.GL_Account__c;

            Journal_Entry__c journal =
                new Journal_Entry__c(
                    Company__c = payment.Company__c,
                    Accounting_Period__c = period.Id,
                    Accounting_Date__c = payment.Effective_Date__c,
                    Entry_Type__c = 'Subledger',
                    Status__c = 'Draft',
                    Description__c = truncateText(
                        'Employee Expense Reimbursement - '
                            + payment.Name,
                        Journal_Entry__c.Description__c.getDescribe().getLength()
                    ),
                    Version__c = 1
                );
            insert journal;

            String currencyCode =
                SABMoneyService.normalizeCurrencyCode(
                    payment.Transaction_Currency__c
                );

            insert new List<Journal_Entry_Line__c>{
                new Journal_Entry_Line__c(
                    Journal_Entry__c = journal.Id,
                    GL_Account__c = liabilityAccountId,
                    Line_Number__c = 1,
                    Debit_Base__c = amount,
                    Credit_Base__c = ZERO,
                    Explanation__c =
                        'Employee reimbursement liability settlement',
                    Transaction_Amount__c = amount,
                    Transaction_Currency__c = currencyCode,
                    Functional_Currency__c = currencyCode,
                    Applied_Exchange_Rate__c =
                        Decimal.valueOf('1'),
                    Rate_Date__c = payment.Effective_Date__c,
                    Rate_Source__c =
                        'Expense Reimbursement Functional Currency',
                    Source_Line_Key__c =
                        'ER|' + String.valueOf(payment.Id) + '|LIABILITY'
                ),
                new Journal_Entry_Line__c(
                    Journal_Entry__c = journal.Id,
                    GL_Account__c = bankGLAccountId,
                    Line_Number__c = 2,
                    Debit_Base__c = ZERO,
                    Credit_Base__c = amount,
                    Explanation__c =
                        'Employee reimbursement bank settlement',
                    Transaction_Amount__c = amount,
                    Transaction_Currency__c = currencyCode,
                    Functional_Currency__c = currencyCode,
                    Applied_Exchange_Rate__c =
                        Decimal.valueOf('1'),
                    Rate_Date__c = payment.Effective_Date__c,
                    Rate_Source__c =
                        'Expense Reimbursement Functional Currency',
                    Source_Line_Key__c =
                        'ER|' + String.valueOf(payment.Id) + '|BANK'
                )
            };

            SABAccountingEventService.ReservationRequest eventRequest =
                new SABAccountingEventService.ReservationRequest();

            eventRequest.companyId = payment.Company__c;
            eventRequest.adapterKey = ADAPTER_KEY;
            eventRequest.requestKey = requestKey.trim();
            eventRequest.eventKey =
                buildEventKey(payment.Id);
            eventRequest.eventType =
                'Payment Disbursement';
            eventRequest.sourceBusinessKey =
                String.isBlank(payment.Reference__c)
                    ? payment.Name
                    : payment.Reference__c.trim();
            eventRequest.sourceRecordId =
                String.valueOf(payment.Id);
            eventRequest.sourceType = SOURCE_TYPE;
            eventRequest.sourceVersion = 1;

            SABPostingService.PostingRequest postingRequest =
                new SABPostingService.PostingRequest();
            postingRequest.journalEntryId = journal.Id;
            postingRequest.postingKey =
                buildPostingKey(payment.Id);
            postingRequest.eventRequest =
                eventRequest;

            SABPostingService.PostingResult posted =
                SABPostingService.postDraftJournal(
                    postingRequest
                );

            payment.Accounting_Event__c =
                posted.accountingEventId;
            payment.Processing_State__c =
                STATE_SUCCEEDED;

            controlledPaymentUpdate(payment);

            createAction(
                payment.Company__c,
                payment.Id,
                'EXPENSE_REIMBURSEMENT_SUCCEEDED',
                buildAuditRequestKey(payment.Id),
                'Employee expense reimbursement payment succeeded and cleared the employee reimbursement liability.'
            );

            return buildPaymentResult(
                payment.Id,
                STATE_SUCCEEDED,
                posted.journalEntryId,
                posted.accountingEventId,
                posted.postingKey,
                posted.replay
            );
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
    }

    private static Accounting_Payment__c loadPayment(
        Id paymentId,
        Boolean lockRow
    ) {
        if (paymentId == null) {
            throw new ExpenseReimbursementException(
                'Payment Id is required.'
            );
        }

        String queryText =
            'SELECT Id, Name, Company__c, '
            + 'Company__r.Functional_Currency__c, '
            + 'Company__r.Is_Active__c, '
            + 'Company__r.Employee_Reimbursement_Liability_Account__c, '
            + 'Company__r.Employee_Reimbursement_Liability_Account__r.Company__c, '
            + 'Company__r.Employee_Reimbursement_Liability_Account__r.Is_Active__c, '
            + 'Company__r.Employee_Reimbursement_Liability_Account__r.Is_Control_Account__c, '
            + 'Company__r.Employee_Reimbursement_Liability_Account__r.Control_Type__c, '
            + 'Company__r.Employee_Reimbursement_Liability_Account__r.Account_Type__c, '
            + 'Party_Profile__c, '
            + 'Bank_Account__c, '
            + 'Bank_Account__r.Company__c, '
            + 'Bank_Account__r.Currency__c, '
            + 'Bank_Account__r.Is_Active__c, '
            + 'Bank_Account__r.GL_Account__c, '
            + 'Bank_Account__r.GL_Account__r.Company__c, '
            + 'Bank_Account__r.GL_Account__r.Is_Active__c, '
            + 'Bank_Account__r.GL_Account__r.Account_Type__c, '
            + 'Direction__c, Method__c, Reference__c, '
            + 'Amount__c, Transaction_Currency__c, '
            + 'Functional_Currency__c, Exchange_Rate__c, '
            + 'Effective_Date__c, Processing_State__c, '
            + 'Provider_Request_Key__c, Accounting_Event__c, Payroll_Run__c '
            + 'FROM Accounting_Payment__c '
            + 'WHERE Id = \'' 
            + String.escapeSingleQuotes(String.valueOf(paymentId))
            + '\' LIMIT 1';

        if (lockRow) {
            queryText += ' FOR UPDATE';
        }

        List<Accounting_Payment__c> rows =
            Database.query(queryText);

        if (rows.isEmpty()) {
            throw new ExpenseReimbursementException(
                'Expense Reimbursement Payment was not found.'
            );
        }

        return rows[0];
    }

    private static void validatePaymentConfiguration(
        Accounting_Payment__c payment
    ) {
        // G10H: closes the G10E gap; reimbursement users cannot process payroll net-pay payments.
        if (payment.Payroll_Run__c != null) {
            throw new ExpenseReimbursementException(
                'Payroll payments are processed only through payroll settlement.'
            );
        }

        if (
            payment.Company__c == null
            || payment.Company__r == null
            || payment.Company__r.Is_Active__c != true
        ) {
            throw new ExpenseReimbursementException(
                'Accounting Company must be active.'
            );
        }

        if (payment.Direction__c != DIRECTION) {
            throw new ExpenseReimbursementException(
                'Expense Reimbursement Payment must use Direction = Disbursement.'
            );
        }

        if (payment.Party_Profile__c != null) {
            throw new ExpenseReimbursementException(
                'Employee Expense Reimbursement Payment must not use a Customer/Supplier Party Profile.'
            );
        }

        if (String.isBlank(payment.Method__c)) {
            throw new ExpenseReimbursementException(
                'Payment Method is required.'
            );
        }

        if (
            payment.Amount__c == null
            || payment.Amount__c <= ZERO
        ) {
            throw new ExpenseReimbursementException(
                'Payment Amount must be greater than zero.'
            );
        }

        if (payment.Effective_Date__c == null) {
            throw new ExpenseReimbursementException(
                'Payment Effective Date is required.'
            );
        }

        validateLiabilityAccount(payment);
        validateBankAccount(payment);
        validateCurrency(payment);
        assertOpenPeriod(
            payment.Company__c,
            payment.Effective_Date__c
        );
    }

    private static void validateLiabilityAccount(
        Accounting_Payment__c payment
    ) {
        if (
            payment.Company__r.Employee_Reimbursement_Liability_Account__c == null
            || payment.Company__r.Employee_Reimbursement_Liability_Account__r == null
        ) {
            throw new ExpenseReimbursementException(
                'Accounting Company requires an Employee Reimbursement Liability Account.'
            );
        }

        GL_Account__c account =
            payment.Company__r.Employee_Reimbursement_Liability_Account__r;

        if (
            account.Company__c != payment.Company__c
            || account.Is_Active__c != true
            || account.Account_Type__c != 'Liability'
            || account.Is_Control_Account__c != true
            || account.Control_Type__c != 'Other'
        ) {
            throw new ExpenseReimbursementException(
                'Employee Reimbursement Liability Account must be an active Liability control account with Control Type Other in the same Accounting Company.'
            );
        }
    }

    private static void validateBankAccount(
        Accounting_Payment__c payment
    ) {
        if (
            payment.Bank_Account__c == null
            || payment.Bank_Account__r == null
        ) {
            throw new ExpenseReimbursementException(
                'Bank Account is required.'
            );
        }

        Bank_Account__c bank =
            payment.Bank_Account__r;

        if (
            bank.Company__c != payment.Company__c
            || bank.Is_Active__c != true
            || bank.GL_Account__c == null
            || bank.GL_Account__r == null
            || bank.GL_Account__r.Company__c
                != payment.Company__c
            || bank.GL_Account__r.Is_Active__c
                != true
            || bank.GL_Account__r.Account_Type__c
                != 'Asset'
        ) {
            throw new ExpenseReimbursementException(
                'Bank Account and its GL mapping must be active and belong to the same Accounting Company; the Bank GL must be an Asset account.'
            );
        }
    }

    private static void validateCurrency(
        Accounting_Payment__c payment
    ) {
        String companyCurrency =
            SABMoneyService.normalizeCurrencyCode(
                payment.Company__r.Functional_Currency__c
            );
        String paymentCurrency =
            SABMoneyService.normalizeCurrencyCode(
                payment.Transaction_Currency__c
            );
        String bankCurrency =
            SABMoneyService.normalizeCurrencyCode(
                payment.Bank_Account__r.Currency__c
            );

        if (
            payment.Transaction_Currency__c != paymentCurrency
            || payment.Bank_Account__r.Currency__c != bankCurrency
        ) {
            throw new ExpenseReimbursementException(
                'Payment and Bank Account currencies must be normalized 3-letter uppercase currencyCode codes.'
            );
        }

        if (
            paymentCurrency != companyCurrency
            || bankCurrency != companyCurrency
        ) {
            throw new ExpenseReimbursementException(
                'G8C supports functional-currency employee reimbursements only.'
            );
        }

        if (
            !String.isBlank(payment.Functional_Currency__c)
            && SABMoneyService.normalizeCurrencyCode(
                payment.Functional_Currency__c
            ) != companyCurrency
        ) {
            throw new ExpenseReimbursementException(
                'Payment Functional Currency must match the Accounting Company Functional Currency.'
            );
        }

        if (
            payment.Exchange_Rate__c != null
            && payment.Exchange_Rate__c != Decimal.valueOf('1')
        ) {
            throw new ExpenseReimbursementException(
                'Functional-currency employee reimbursements must use Exchange Rate 1.'
            );
        }
    }

    private static void assertOpenPeriod(
        Id companyId,
        Date effectiveDate
    ) {
        List<Accounting_Period__c> periods = [
            SELECT Id, Status__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
              AND Start_Date__c <= :effectiveDate
              AND End_Date__c >= :effectiveDate
            LIMIT 2
        ];

        if (periods.isEmpty()) {
            throw new ExpenseReimbursementException(
                'No Accounting Period contains the Payment Effective Date.'
            );
        }

        if (periods.size() > 1) {
            throw new ExpenseReimbursementException(
                'More than one Accounting Period contains the Payment Effective Date.'
            );
        }

        if (periods[0].Status__c != 'Open') {
            throw new ExpenseReimbursementException(
                'Payment Effective Date must be in an Open Accounting Period.'
            );
        }
    }

    private static Accounting_Period__c resolveAndLockOpenPeriod(
        Id companyId,
        Date effectiveDate
    ) {
        List<Accounting_Period__c> periods = [
            SELECT Id, Status__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
              AND Start_Date__c <= :effectiveDate
              AND End_Date__c >= :effectiveDate
            LIMIT 2
            FOR UPDATE
        ];

        if (
            periods.size() != 1
            || periods[0].Status__c != 'Open'
        ) {
            throw new ExpenseReimbursementException(
                'Expense Reimbursement Payment requires exactly one Open Accounting Period.'
            );
        }

        return periods[0];
    }

    private static void controlledPaymentUpdate(
        Accounting_Payment__c payment
    ) {
        SABAccountingPaymentMutationContext.beginMutation();
        try {
            update payment;
        } finally {
            SABAccountingPaymentMutationContext.endMutation();
        }
    }

    private static void assertProviderRequestKeyAvailable(
        Accounting_Payment__c payment,
        String providerRequestKey
    ) {
        if ([
            SELECT COUNT()
            FROM Accounting_Payment__c
            WHERE Company__c = :payment.Company__c
              AND Provider_Request_Key__c = :providerRequestKey
              AND Id != :payment.Id
        ] > 0) {
            throw new ExpenseReimbursementException(
                'Provider Request Key is already assigned to another Payment in this Accounting Company.'
            );
        }
    }

    private static Business_Action__c findPriorAction(
        String requestKey
    ) {
        List<Business_Action__c> actions = [
            SELECT Id, Action__c,
                   Source_Type__c,
                   Source_Record_Id__c
            FROM Business_Action__c
            WHERE Request_Key__c = :requestKey
            LIMIT 1
        ];
        return actions.isEmpty() ? null : actions[0];
    }

    private static PaymentResult replayLifecycleAction(
        Id paymentId,
        Business_Action__c action,
        String expectedAction,
        String expectedState
    ) {
        if (
            action.Source_Type__c != SOURCE_TYPE
            || action.Source_Record_Id__c
                != String.valueOf(paymentId)
            || action.Action__c != expectedAction
        ) {
            throw new ExpenseReimbursementException(
                'Request Key has already been used for a different financial action.'
            );
        }

        Accounting_Payment__c payment = [
            SELECT Id, Processing_State__c
            FROM Accounting_Payment__c
            WHERE Id = :paymentId
            LIMIT 1
        ];

        if (
            payment.Processing_State__c != expectedState
            && payment.Processing_State__c != STATE_SUBMITTED
            && payment.Processing_State__c != STATE_SUCCEEDED
        ) {
            throw new ExpenseReimbursementException(
                'Payment state is not compatible with the replayed action.'
            );
        }

        return buildPaymentResult(
            payment.Id,
            payment.Processing_State__c,
            null,
            null,
            null,
            true
        );
    }

    private static PaymentResult resolveSucceededReplay(
        Accounting_Payment__c payment
    ) {
        if (payment.Accounting_Event__c == null) {
            throw new ExpenseReimbursementException(
                'Succeeded Expense Reimbursement Payment is missing its Accounting Event.'
            );
        }

        Accounting_Event__c eventRecord = [
            SELECT Id, Company__c, Event_Key__c,
                   Source_Type__c, Source_Record_Id__c,
                   State__c, Journal_Entry__c,
                   Journal_Entry__r.Status__c,
                   Journal_Entry__r.Posting_Key__c
            FROM Accounting_Event__c
            WHERE Id = :payment.Accounting_Event__c
            LIMIT 1
        ];

        if (
            eventRecord.Company__c != payment.Company__c
            || eventRecord.Event_Key__c
                != buildEventKey(payment.Id)
            || eventRecord.Source_Type__c != SOURCE_TYPE
            || eventRecord.Source_Record_Id__c
                != String.valueOf(payment.Id)
            || eventRecord.State__c != 'Posted'
            || eventRecord.Journal_Entry__c == null
            || eventRecord.Journal_Entry__r.Status__c
                != 'Posted'
            || eventRecord.Journal_Entry__r.Posting_Key__c
                != buildPostingKey(payment.Id)
        ) {
            throw new ExpenseReimbursementException(
                'Succeeded Expense Reimbursement Payment does not have a consistent posting chain.'
            );
        }

        return buildPaymentResult(
            payment.Id,
            STATE_SUCCEEDED,
            eventRecord.Journal_Entry__c,
            eventRecord.Id,
            eventRecord.Journal_Entry__r.Posting_Key__c,
            true
        );
    }

    private static void createAction(
        Id companyId,
        Id paymentId,
        String actionName,
        String requestKey,
        String reason
    ) {
        insert new Business_Action__c(
            Company__c = companyId,
            Action__c = actionName,
            Actor__c = UserInfo.getUserId(),
            Action_At__c = System.now(),
            Reason__c = reason,
            Request_Key__c = requestKey,
            Source_Type__c = SOURCE_TYPE,
            Source_Record_Id__c =
                String.valueOf(paymentId),
            Source_Version__c = 1
        );
    }

    private static PaymentResult buildPaymentResult(
        Id paymentId,
        String state,
        Id journalId,
        Id eventId,
        String postingKey,
        Boolean replay
    ) {
        PaymentResult result = new PaymentResult();
        result.paymentId = paymentId;
        result.state = state;
        result.journalEntryId = journalId;
        result.accountingEventId = eventId;
        result.postingKey = postingKey;
        result.replay = replay;
        return result;
    }

    private static void assertPermission() {
        SABPermissionService.assertPermission(
            PERMISSION,
            'You do not have permission to process employee expense reimbursements.'
        );
    }

    private static void validateRequestKey(
        String requestKey
    ) {
        if (String.isBlank(requestKey)) {
            throw new ExpenseReimbursementException(
                'Request Key is required.'
            );
        }

        Integer maxLength =
            Business_Action__c.Request_Key__c.getDescribe().getLength();

        if (
            maxLength > 0
            && requestKey.trim().length() > maxLength
        ) {
            throw new ExpenseReimbursementException(
                'Request Key cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static String buildPostingKey(
        Id paymentId
    ) {
        return 'ERPAY|'
            + String.valueOf(paymentId)
            + '|V1';
    }

    private static String buildEventKey(
        Id paymentId
    ) {
        return 'EXPENSE_REIMBURSEMENT|'
            + String.valueOf(paymentId)
            + '|V1';
    }

    private static String buildAuditRequestKey(
        Id paymentId
    ) {
        return 'ERPOST|'
            + String.valueOf(paymentId);
    }

    private static String truncateText(
        String value,
        Integer maxLength
    ) {
        if (
            String.isBlank(value)
            || maxLength == null
            || maxLength <= 0
            || value.length() <= maxLength
        ) {
            return value;
        }
        return value.substring(0, maxLength);
    }
}
