/**
 * G4B - Customer Receipt / AR Receipt posting.
 *
 * Called only after the receipt has genuinely succeeded at the bank/provider.
 * It posts:
 *
 *   Dr Bank / Cash GL account
 *   Cr Accounts Receivable control account
 *
 * Allocation to one or more invoices is intentionally separate and belongs
 * to G4C. This service therefore never inserts Payment_Allocation__c records.
 *
 * G4B is intentionally same-currency only until realized-FX settlement is
 * implemented for receipt allocation.
 */
public without sharing class SABCustomerReceiptPostingService {

    public class CustomerReceiptPostingException extends Exception {}

    private static final String POST_PERMISSION = 'SAB_Post_Journal';
    private static final String STATE_SUBMITTED = 'Submitted';
    private static final String STATE_SUCCEEDED = 'Succeeded';
    private static final String DIRECTION_RECEIPT = 'Receipt';
    private static final String ENTRY_TYPE_SUBLEDGER = 'Subledger';
    private static final String SOURCE_TYPE = 'Accounting_Payment__c';
    private static final String ADAPTER_KEY = 'CUSTOMER_RECEIPT';
    private static final Decimal ZERO = Decimal.valueOf('0');

    public class PostingRequest {
        @AuraEnabled public Id paymentId { get; set; }
        @AuraEnabled public String requestKey { get; set; }
    }

    public class PostingResult {
        @AuraEnabled public Id paymentId { get; private set; }
        @AuraEnabled public Id journalEntryId { get; private set; }
        @AuraEnabled public Id accountingEventId { get; private set; }
        @AuraEnabled public String postingKey { get; private set; }
        @AuraEnabled public Datetime postedAt { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private PostingResult() {}
    }

    @AuraEnabled
    public static PostingResult recordSucceededAndPost(
        PostingRequest request
    ) {
        validateRequest(request);

        SABPermissionService.assertPermission(
            POST_PERMISSION,
            'You do not have permission to post accounting transactions.'
        );

        Accounting_Payment__c initialReceipt = [
            SELECT Id, Company__c, Direction__c,
                   Processing_State__c, Accounting_Event__c
            FROM Accounting_Payment__c
            WHERE Id = :request.paymentId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(
            initialReceipt.Company__c
        );

        if (initialReceipt.Processing_State__c == STATE_SUCCEEDED) {
            return resolveSucceededReplay(initialReceipt);
        }

        if (initialReceipt.Processing_State__c != STATE_SUBMITTED) {
            throw new CustomerReceiptPostingException(
                'Customer Receipt must be Submitted before successful receipt posting.'
            );
        }

        if (initialReceipt.Direction__c != DIRECTION_RECEIPT) {
            throw new CustomerReceiptPostingException(
                'G4B Customer Receipt posting supports Receipt direction only.'
            );
        }

        Savepoint outerSavepoint = Database.setSavepoint();

        try {
            SABCustomerReceiptService.assertSubmittedForPosting(
                request.paymentId
            );

            Accounting_Payment__c receipt = [
                SELECT Id, Name, Company__c,
                       Company__r.Functional_Currency__c,
                       Party_Profile__c,
                       Party_Profile__r.Company__c,
                       Party_Profile__r.Is_Active__c,
                       Party_Profile__r.Is_Customer__c,
                       Party_Profile__r.AR_Control_Account__c,
                       Party_Profile__r.AR_Control_Account__r.Company__c,
                       Party_Profile__r.AR_Control_Account__r.Is_Active__c,
                       Party_Profile__r.AR_Control_Account__r.Account_Type__c,
                       Party_Profile__r.AR_Control_Account__r.Is_Control_Account__c,
                       Party_Profile__r.AR_Control_Account__r.Control_Type__c,
                       Bank_Account__c,
                       Bank_Account__r.Company__c,
                       Bank_Account__r.Currency__c,
                       Bank_Account__r.Is_Active__c,
                       Bank_Account__r.GL_Account__c,
                       Bank_Account__r.GL_Account__r.Company__c,
                       Bank_Account__r.GL_Account__r.Is_Active__c,
                       Bank_Account__r.GL_Account__r.Account_Type__c,
                       Direction__c, Method__c, Reference__c,
                       Amount__c, Transaction_Currency__c,
                       Functional_Currency__c, Exchange_Rate__c,
                       Effective_Date__c, Processing_State__c,
                       Provider_Request_Key__c, Accounting_Event__c
                FROM Accounting_Payment__c
                WHERE Id = :request.paymentId
                LIMIT 1
                FOR UPDATE
            ];

            if (receipt.Processing_State__c == STATE_SUCCEEDED) {
                return resolveSucceededReplay(receipt);
            }

            if (receipt.Processing_State__c != STATE_SUBMITTED) {
                throw new CustomerReceiptPostingException(
                    'Customer Receipt changed while posting. Retry the successful-receipt request.'
                );
            }

            if (receipt.Accounting_Event__c != null) {
                throw new CustomerReceiptPostingException(
                    'Submitted Customer Receipt already contains an Accounting Event link.'
                );
            }

            validatePostingConfiguration(receipt);

            Accounting_Period__c period = resolveAndLockOpenPeriod(
                receipt.Company__c,
                receipt.Effective_Date__c
            );

            Decimal amount = SABMoneyService.normalizeLedgerAmount(
                receipt.Amount__c,
                RoundingMode.HALF_UP
            );

            if (amount <= ZERO) {
                throw new CustomerReceiptPostingException(
                    'Customer Receipt amount must be greater than zero.'
                );
            }

            Journal_Entry__c journal = new Journal_Entry__c(
                Company__c = receipt.Company__c,
                Accounting_Period__c = period.Id,
                Accounting_Date__c = receipt.Effective_Date__c,
                Entry_Type__c = ENTRY_TYPE_SUBLEDGER,
                Status__c = 'Draft',
                Description__c = truncateText(
                    buildJournalDescription(receipt),
                    Journal_Entry__c.Description__c.getDescribe().getLength()
                ),
                Version__c = 1
            );

            insert journal;

            String transactionCurrency = SABMoneyService.normalizeCurrencyCode(
                receipt.Transaction_Currency__c
            );

            List<Journal_Entry_Line__c> journalLines =
                new List<Journal_Entry_Line__c>{
                    new Journal_Entry_Line__c(
                        Journal_Entry__c = journal.Id,
                        GL_Account__c = receipt.Bank_Account__r.GL_Account__c,
                        Line_Number__c = 1,
                        Debit_Base__c = amount,
                        Credit_Base__c = ZERO,
                        Explanation__c = truncateText(
                            'Customer receipt - bank/cash settlement',
                            Journal_Entry_Line__c.Explanation__c.getDescribe().getLength()
                        ),
                        Transaction_Amount__c = amount,
                        Transaction_Currency__c = transactionCurrency,
                        Functional_Currency__c = transactionCurrency,
                        Applied_Exchange_Rate__c = Decimal.valueOf('1'),
                        Rate_Date__c = receipt.Effective_Date__c,
                        Rate_Source__c = 'Customer Receipt Snapshot',
                        Source_Line_Key__c =
                            'RCPT|'
                            + String.valueOf(receipt.Id)
                            + '|BANK'
                    ),
                    new Journal_Entry_Line__c(
                        Journal_Entry__c = journal.Id,
                        GL_Account__c = receipt.Party_Profile__r.AR_Control_Account__c,
                        Line_Number__c = 2,
                        Debit_Base__c = ZERO,
                        Credit_Base__c = amount,
                        Explanation__c = truncateText(
                            'Customer receipt - AR settlement',
                            Journal_Entry_Line__c.Explanation__c.getDescribe().getLength()
                        ),
                        Transaction_Amount__c = amount,
                        Transaction_Currency__c = transactionCurrency,
                        Functional_Currency__c = transactionCurrency,
                        Applied_Exchange_Rate__c = Decimal.valueOf('1'),
                        Rate_Date__c = receipt.Effective_Date__c,
                        Rate_Source__c = 'Customer Receipt Snapshot',
                        Source_Line_Key__c =
                            'RCPT|'
                            + String.valueOf(receipt.Id)
                            + '|AR'
                    )
                };

            insert journalLines;

            SABAccountingEventService.ReservationRequest eventRequest =
                new SABAccountingEventService.ReservationRequest();

            eventRequest.companyId = receipt.Company__c;
            eventRequest.adapterKey = ADAPTER_KEY;
            eventRequest.requestKey = request.requestKey.trim();
            eventRequest.eventKey = buildEventKey(receipt.Id);
            eventRequest.eventType = 'Payment Receipt';
            eventRequest.sourceBusinessKey = buildSourceBusinessKey(receipt);
            eventRequest.sourceRecordId = String.valueOf(receipt.Id);
            eventRequest.sourceType = SOURCE_TYPE;
            eventRequest.sourceVersion = 1;

            SABPostingService.PostingRequest postingRequest =
                new SABPostingService.PostingRequest();

            postingRequest.journalEntryId = journal.Id;
            postingRequest.postingKey = buildPostingKey(receipt.Id);
            postingRequest.eventRequest = eventRequest;

            SABPostingService.PostingResult postedJournal =
                SABPostingService.postDraftJournal(postingRequest);

            SABCustomerReceiptService.TransitionResult completion =
                SABCustomerReceiptService.completeSucceededPosting(
                    receipt.Id,
                    postedJournal.accountingEventId,
                    postedJournal.journalEntryId,
                    buildAuditRequestKey(receipt.Id)
                );

            PostingResult result = new PostingResult();
            result.paymentId = receipt.Id;
            result.journalEntryId = postedJournal.journalEntryId;
            result.accountingEventId = postedJournal.accountingEventId;
            result.postingKey = postedJournal.postingKey;
            result.postedAt = postedJournal.postedAt;
            result.replay =
                postedJournal.replay
                || completion.idempotentReplay;

            return result;
        } catch (Exception ex) {
            Database.rollback(outerSavepoint);
            throw ex;
        }
    }

    private static PostingResult resolveSucceededReplay(
        Accounting_Payment__c receipt
    ) {
        if (receipt.Accounting_Event__c == null) {
            throw new CustomerReceiptPostingException(
                'Succeeded Customer Receipt is missing its Accounting Event link.'
            );
        }

        Accounting_Event__c eventRecord = [
            SELECT Id, Company__c, Event_Key__c, Event_Type__c,
                   Source_Type__c, Source_Record_Id__c,
                   State__c, Journal_Entry__c,
                   Journal_Entry__r.Status__c,
                   Journal_Entry__r.Entry_Type__c,
                   Journal_Entry__r.Posting_Key__c,
                   Journal_Entry__r.Posted_At__c
            FROM Accounting_Event__c
            WHERE Id = :receipt.Accounting_Event__c
            LIMIT 1
        ];

        if (
            eventRecord.Company__c != receipt.Company__c
            || eventRecord.Event_Key__c != buildEventKey(receipt.Id)
            || eventRecord.Event_Type__c != 'Payment Receipt'
            || eventRecord.Source_Type__c != SOURCE_TYPE
            || eventRecord.Source_Record_Id__c != String.valueOf(receipt.Id)
            || eventRecord.State__c != 'Posted'
            || eventRecord.Journal_Entry__c == null
            || eventRecord.Journal_Entry__r.Status__c != 'Posted'
            || eventRecord.Journal_Entry__r.Entry_Type__c != ENTRY_TYPE_SUBLEDGER
            || eventRecord.Journal_Entry__r.Posting_Key__c
                != buildPostingKey(receipt.Id)
        ) {
            throw new CustomerReceiptPostingException(
                'Succeeded Customer Receipt does not have a consistent AR receipt posting chain.'
            );
        }

        PostingResult result = new PostingResult();
        result.paymentId = receipt.Id;
        result.journalEntryId = eventRecord.Journal_Entry__c;
        result.accountingEventId = eventRecord.Id;
        result.postingKey = eventRecord.Journal_Entry__r.Posting_Key__c;
        result.postedAt = eventRecord.Journal_Entry__r.Posted_At__c;
        result.replay = true;
        return result;
    }

    private static void validatePostingConfiguration(
        Accounting_Payment__c receipt
    ) {
        if (receipt.Direction__c != DIRECTION_RECEIPT) {
            throw new CustomerReceiptPostingException(
                'Customer Receipt must use Direction = Receipt.'
            );
        }

        if (String.isBlank(receipt.Provider_Request_Key__c)) {
            throw new CustomerReceiptPostingException(
                'Submitted Customer Receipt requires a Provider Request Key.'
            );
        }

        if (
            receipt.Party_Profile__r == null
            || receipt.Party_Profile__r.Company__c != receipt.Company__c
            || receipt.Party_Profile__r.Is_Active__c != true
            || receipt.Party_Profile__r.Is_Customer__c != true
            || receipt.Party_Profile__r.AR_Control_Account__c == null
        ) {
            throw new CustomerReceiptPostingException(
                'Customer Receipt Party Profile configuration is invalid.'
            );
        }

        GL_Account__c arAccount =
            receipt.Party_Profile__r.AR_Control_Account__r;

        if (
            arAccount == null
            || arAccount.Company__c != receipt.Company__c
            || arAccount.Is_Active__c != true
            || arAccount.Account_Type__c != 'Asset'
            || arAccount.Is_Control_Account__c != true
            || arAccount.Control_Type__c != 'AR'
        ) {
            throw new CustomerReceiptPostingException(
                'Customer AR Control Account configuration is invalid.'
            );
        }

        if (
            receipt.Bank_Account__r == null
            || receipt.Bank_Account__r.Company__c != receipt.Company__c
            || receipt.Bank_Account__r.Is_Active__c != true
            || receipt.Bank_Account__r.GL_Account__c == null
        ) {
            throw new CustomerReceiptPostingException(
                'Customer Receipt Bank Account configuration is invalid.'
            );
        }

        GL_Account__c bankGL = receipt.Bank_Account__r.GL_Account__r;

        if (
            bankGL == null
            || bankGL.Company__c != receipt.Company__c
            || bankGL.Is_Active__c != true
            || bankGL.Account_Type__c != 'Asset'
        ) {
            throw new CustomerReceiptPostingException(
                'Bank Account GL mapping must be an active Asset account in the same Accounting Company.'
            );
        }

        String companyCurrency = SABMoneyService.normalizeCurrencyCode(
            receipt.Company__r.Functional_Currency__c
        );

        String receiptCurrency = SABMoneyService.normalizeCurrencyCode(
            receipt.Transaction_Currency__c
        );

        String bankCurrency = SABMoneyService.normalizeCurrencyCode(
            receipt.Bank_Account__r.Currency__c
        );

        if (
            receiptCurrency != companyCurrency
            || bankCurrency != companyCurrency
            || receipt.Functional_Currency__c != companyCurrency
            || receipt.Exchange_Rate__c != Decimal.valueOf('1')
        ) {
            throw new CustomerReceiptPostingException(
                'G4B customer receipt posting is same-currency only. Foreign-currency settlement is deferred until allocation/realized-FX implementation.'
            );
        }
    }

    private static Accounting_Period__c resolveAndLockOpenPeriod(
        Id companyId,
        Date effectiveDate
    ) {
        List<Accounting_Period__c> periods = [
            SELECT Id, Company__c, Status__c,
                   Start_Date__c, End_Date__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
              AND Start_Date__c <= :effectiveDate
              AND End_Date__c >= :effectiveDate
            LIMIT 2
            FOR UPDATE
        ];

        if (periods.isEmpty()) {
            throw new CustomerReceiptPostingException(
                'No Accounting Period contains the Receipt Effective Date.'
            );
        }

        if (periods.size() > 1) {
            throw new CustomerReceiptPostingException(
                'More than one Accounting Period contains the Receipt Effective Date.'
            );
        }

        if (periods[0].Status__c != 'Open') {
            throw new CustomerReceiptPostingException(
                'Receipt Accounting Period must be Open.'
            );
        }

        return periods[0];
    }

    private static String buildPostingKey(Id paymentId) {
        return 'RCPT|' + String.valueOf(paymentId) + '|V1';
    }

    private static String buildEventKey(Id paymentId) {
        return 'CUSTOMER_RECEIPT|' + String.valueOf(paymentId) + '|V1';
    }

    private static String buildAuditRequestKey(Id paymentId) {
        return 'RCPTPOST|' + String.valueOf(paymentId);
    }

    private static String buildSourceBusinessKey(
        Accounting_Payment__c receipt
    ) {
        if (!String.isBlank(receipt.Provider_Request_Key__c)) {
            return receipt.Provider_Request_Key__c.trim();
        }

        if (!String.isBlank(receipt.Reference__c)) {
            return receipt.Reference__c.trim();
        }

        return String.valueOf(receipt.Id);
    }

    private static String buildJournalDescription(
        Accounting_Payment__c receipt
    ) {
        String sourceLabel =
            !String.isBlank(receipt.Reference__c)
                ? receipt.Reference__c.trim()
                : receipt.Name;

        return 'Customer Receipt - ' + sourceLabel;
    }

    private static void validateRequest(PostingRequest request) {
        if (request == null || request.paymentId == null) {
            throw new CustomerReceiptPostingException(
                'Customer Receipt Id is required.'
            );
        }

        if (String.isBlank(request.requestKey)) {
            throw new CustomerReceiptPostingException(
                'Request Key is required.'
            );
        }

        if (request.requestKey.trim().length() > 160) {
            throw new CustomerReceiptPostingException(
                'Request Key cannot exceed 160 characters.'
            );
        }
    }

    private static String truncateText(
        String value,
        Integer maxLength
    ) {
        if (value == null) {
            return null;
        }

        if (
            maxLength == null
            || maxLength <= 0
            || value.length() <= maxLength
        ) {
            return value;
        }

        return value.substring(0, maxLength);
    }
}
