/**
 * G3C - Supplier Payment / AP Disbursement posting.
 *
 * This service is called only after a payment instruction has genuinely
 * succeeded at the bank/provider. It then posts:
 *
 *   Dr Accounts Payable control account
 *   Cr Bank GL account
 *
 * No Expense/Asset account is touched; the Supplier Bill already recognized
 * the expense/asset in G3B.
 *
 * G3C is intentionally same-currency only. Foreign-currency settlement needs
 * allocation carrying values and the later realized-FX policy.
 */
public without sharing class SABSupplierPaymentPostingService {

    public class SupplierPaymentPostingException extends Exception {}

    private static final String POST_PERMISSION =
        'SAB_Post_Journal';

    private static final String STATE_SUBMITTED =
        'Submitted';

    private static final String STATE_SUCCEEDED =
        'Succeeded';

    private static final String DIRECTION_DISBURSEMENT =
        'Disbursement';

    private static final String ENTRY_TYPE_SUBLEDGER =
        'Subledger';

    private static final String SOURCE_TYPE =
        'Accounting_Payment__c';

    private static final String ADAPTER_KEY =
        'SUPPLIER_PAYMENT';

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    public class PostingRequest {
        @AuraEnabled public Id paymentId {
            get;
            set;
        }

        /**
         * Stable accounting request key for this successful execution notice.
         */
        @AuraEnabled public String requestKey {
            get;
            set;
        }
    }

    public class PostingResult {
        @AuraEnabled public Id paymentId {
            get;
            private set;
        }

        @AuraEnabled public Id journalEntryId {
            get;
            private set;
        }

        @AuraEnabled public Id accountingEventId {
            get;
            private set;
        }

        @AuraEnabled public String postingKey {
            get;
            private set;
        }

        @AuraEnabled public Datetime postedAt {
            get;
            private set;
        }

        @AuraEnabled public Boolean replay {
            get;
            private set;
        }

        private PostingResult() {}
    }

    /**
     * Record a confirmed provider/bank success and post the cash settlement.
     *
     * This method must NOT be used merely because a provider request was
     * submitted. Submitted and Failed states intentionally have no ledger
     * effect.
     */
    @AuraEnabled
    public static PostingResult recordSucceededAndPost(
        PostingRequest request
    ) {
        validateRequest(request);

        SABPermissionService.assertPermission(
            POST_PERMISSION,
            'You do not have permission to post accounting transactions.'
        );

        Accounting_Payment__c initialPayment = [
            SELECT Id, Company__c,
                   Direction__c,
                   Processing_State__c,
                   Accounting_Event__c
            FROM Accounting_Payment__c
            WHERE Id = :request.paymentId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(
            initialPayment.Company__c
        );

        if (
            initialPayment.Processing_State__c
            == STATE_SUCCEEDED
        ) {
            return resolveSucceededReplay(
                initialPayment
            );
        }

        if (
            initialPayment.Processing_State__c
            != STATE_SUBMITTED
        ) {
            throw new SupplierPaymentPostingException(
                'Supplier Payment must be Submitted before a successful execution can be posted.'
            );
        }

        if (
            initialPayment.Direction__c
            != DIRECTION_DISBURSEMENT
        ) {
            throw new SupplierPaymentPostingException(
                'G3C Supplier Payment posting supports Disbursement direction only.'
            );
        }

        Savepoint outerSavepoint =
            Database.setSavepoint();

        try {
            SABSupplierPaymentService.assertSubmittedForPosting(
                request.paymentId
            );

            Accounting_Payment__c payment = [
                SELECT Id, Name, Company__c,
                       Company__r.Functional_Currency__c,
                       Party_Profile__c,
                       Party_Profile__r.AP_Control_Account__c,
                       Party_Profile__r.AP_Control_Account__r.Company__c,
                       Party_Profile__r.AP_Control_Account__r.Is_Active__c,
                       Party_Profile__r.AP_Control_Account__r.Account_Type__c,
                       Party_Profile__r.AP_Control_Account__r.Is_Control_Account__c,
                       Party_Profile__r.AP_Control_Account__r.Control_Type__c,
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
                       Functional_Currency__c,
                       Exchange_Rate__c,
                       Effective_Date__c,
                       Processing_State__c,
                       Provider_Request_Key__c,
                       Accounting_Event__c
                FROM Accounting_Payment__c
                WHERE Id = :request.paymentId
                LIMIT 1
                FOR UPDATE
            ];

            if (
                payment.Processing_State__c
                == STATE_SUCCEEDED
            ) {
                return resolveSucceededReplay(
                    payment
                );
            }

            if (
                payment.Processing_State__c
                != STATE_SUBMITTED
            ) {
                throw new SupplierPaymentPostingException(
                    'Supplier Payment changed while posting. Retry the successful-execution request.'
                );
            }

            if (
                payment.Accounting_Event__c
                != null
            ) {
                throw new SupplierPaymentPostingException(
                    'Submitted Supplier Payment already contains an Accounting Event link.'
                );
            }

            validatePostingConfiguration(
                payment
            );

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
                throw new SupplierPaymentPostingException(
                    'Supplier Payment amount must be greater than zero.'
                );
            }

            Journal_Entry__c journal =
                new Journal_Entry__c(
                    Company__c =
                        payment.Company__c,
                    Accounting_Period__c =
                        period.Id,
                    Accounting_Date__c =
                        payment.Effective_Date__c,
                    Entry_Type__c =
                        ENTRY_TYPE_SUBLEDGER,
                    Status__c =
                        'Draft',
                    Description__c =
                        truncateText(
                            buildJournalDescription(
                                payment
                            ),
                            Journal_Entry__c.Description__c.getDescribe().getLength()
                        ),
                    Version__c = 1
                );

            insert journal;

            String transactionCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    payment.Transaction_Currency__c
                );

            List<Journal_Entry_Line__c> journalLines =
                new List<Journal_Entry_Line__c>{
                    new Journal_Entry_Line__c(
                        Journal_Entry__c =
                            journal.Id,
                        GL_Account__c =
                            payment.Party_Profile__r.AP_Control_Account__c,
                        Line_Number__c = 1,
                        Debit_Base__c =
                            amount,
                        Credit_Base__c =
                            ZERO,
                        Explanation__c =
                            truncateText(
                                'Supplier payment - AP settlement',
                                Journal_Entry_Line__c.Explanation__c.getDescribe().getLength()
                            ),
                        Transaction_Amount__c =
                            amount,
                        Transaction_Currency__c =
                            transactionCurrency,
                        Functional_Currency__c =
                            transactionCurrency,
                        Applied_Exchange_Rate__c =
                            Decimal.valueOf('1'),
                        Rate_Date__c =
                            payment.Effective_Date__c,
                        Rate_Source__c =
                            'Supplier Payment Snapshot',
                        Source_Line_Key__c =
                            'PAY|'
                            + String.valueOf(
                                payment.Id
                            )
                            + '|AP'
                    ),
                    new Journal_Entry_Line__c(
                        Journal_Entry__c =
                            journal.Id,
                        GL_Account__c =
                            payment.Bank_Account__r.GL_Account__c,
                        Line_Number__c = 2,
                        Debit_Base__c =
                            ZERO,
                        Credit_Base__c =
                            amount,
                        Explanation__c =
                            truncateText(
                                'Supplier payment - bank settlement',
                                Journal_Entry_Line__c.Explanation__c.getDescribe().getLength()
                            ),
                        Transaction_Amount__c =
                            amount,
                        Transaction_Currency__c =
                             transactionCurrency,
                        Functional_Currency__c =
                             transactionCurrency,
                        Applied_Exchange_Rate__c =
                            Decimal.valueOf('1'),
                        Rate_Date__c =
                            payment.Effective_Date__c,
                        Rate_Source__c =
                            'Supplier Payment Snapshot',
                        Source_Line_Key__c =
                            'PAY|'
                            + String.valueOf(
                                payment.Id
                            )
                            + '|BANK'
                    )
                };

            insert journalLines;

            SABAccountingEventService.ReservationRequest eventRequest =
                new SABAccountingEventService.ReservationRequest();

            eventRequest.companyId =
                payment.Company__c;
            eventRequest.adapterKey =
                ADAPTER_KEY;
            eventRequest.requestKey =
                request.requestKey.trim();
            eventRequest.eventKey =
                buildEventKey(
                    payment.Id
                );
            eventRequest.eventType =
                'Payment Disbursement';
            eventRequest.sourceBusinessKey =
                buildSourceBusinessKey(
                    payment
                );
            eventRequest.sourceRecordId =
                String.valueOf(
                    payment.Id
                );
            eventRequest.sourceType =
                SOURCE_TYPE;
            eventRequest.sourceVersion =
                1;

            SABPostingService.PostingRequest postingRequest =
                new SABPostingService.PostingRequest();

            postingRequest.journalEntryId =
                journal.Id;
            postingRequest.postingKey =
                buildPostingKey(
                    payment.Id
                );
            postingRequest.eventRequest =
                eventRequest;

            SABPostingService.PostingResult postedJournal =
                SABPostingService.postDraftJournal(
                    postingRequest
                );

            SABSupplierPaymentService.TransitionResult completion =
                SABSupplierPaymentService.completeSucceededPosting(
                    payment.Id,
                    postedJournal.accountingEventId,
                    postedJournal.journalEntryId,
                    buildAuditRequestKey(
                        payment.Id
                    )
                );

            PostingResult result =
                new PostingResult();

            result.paymentId =
                payment.Id;
            result.journalEntryId =
                postedJournal.journalEntryId;
            result.accountingEventId =
                postedJournal.accountingEventId;
            result.postingKey =
                postedJournal.postingKey;
            result.postedAt =
                postedJournal.postedAt;
            result.replay =
                postedJournal.replay
                || completion.idempotentReplay;

            return result;
        } catch (Exception ex) {
            Database.rollback(
                outerSavepoint
            );
            throw ex;
        }
    }

    private static PostingResult resolveSucceededReplay(
        Accounting_Payment__c payment
    ) {
        if (
            payment.Accounting_Event__c
            == null
        ) {
            throw new SupplierPaymentPostingException(
                'Succeeded Supplier Payment is missing its Accounting Event link.'
            );
        }

        Accounting_Event__c eventRecord = [
            SELECT Id, Company__c,
                   Event_Key__c, Event_Type__c,
                   Source_Type__c,
                   Source_Record_Id__c,
                   State__c,
                   Journal_Entry__c,
                   Journal_Entry__r.Status__c,
                   Journal_Entry__r.Entry_Type__c,
                   Journal_Entry__r.Posting_Key__c,
                   Journal_Entry__r.Posted_At__c
            FROM Accounting_Event__c
            WHERE Id =
                :payment.Accounting_Event__c
            LIMIT 1
        ];

        if (
            eventRecord.Company__c
                != payment.Company__c
            || eventRecord.Event_Key__c
                != buildEventKey(
                    payment.Id
                )
            || eventRecord.Event_Type__c
                != 'Payment Disbursement'
            || eventRecord.Source_Type__c
                != SOURCE_TYPE
            || eventRecord.Source_Record_Id__c
                != String.valueOf(
                    payment.Id
                )
            || eventRecord.State__c
                != 'Posted'
            || eventRecord.Journal_Entry__c
                == null
            || eventRecord.Journal_Entry__r.Status__c
                != 'Posted'
            || eventRecord.Journal_Entry__r.Entry_Type__c
                != ENTRY_TYPE_SUBLEDGER
            || eventRecord.Journal_Entry__r.Posting_Key__c
                != buildPostingKey(
                    payment.Id
                )
        ) {
            throw new SupplierPaymentPostingException(
                'Succeeded Supplier Payment does not have a consistent AP disbursement posting chain.'
            );
        }

        PostingResult result =
            new PostingResult();

        result.paymentId =
            payment.Id;
        result.journalEntryId =
            eventRecord.Journal_Entry__c;
        result.accountingEventId =
            eventRecord.Id;
        result.postingKey =
            eventRecord.Journal_Entry__r.Posting_Key__c;
        result.postedAt =
            eventRecord.Journal_Entry__r.Posted_At__c;
        result.replay =
            true;

        return result;
    }

    private static void validatePostingConfiguration(
        Accounting_Payment__c payment
    ) {
        if (
            payment.Direction__c
            != DIRECTION_DISBURSEMENT
        ) {
            throw new SupplierPaymentPostingException(
                'Supplier Payment must be a Disbursement.'
            );
        }

        if (
            String.isBlank(
                payment.Provider_Request_Key__c
            )
        ) {
            throw new SupplierPaymentPostingException(
                'Submitted Supplier Payment requires a Provider Request Key.'
            );
        }

        if (
            payment.Party_Profile__r == null
            || payment.Party_Profile__r.AP_Control_Account__c
                == null
        ) {
            throw new SupplierPaymentPostingException(
                'Supplier Payment requires an AP Control Account.'
            );
        }

        GL_Account__c apAccount =
            payment.Party_Profile__r.AP_Control_Account__r;

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
            throw new SupplierPaymentPostingException(
                'Supplier AP Control Account configuration is invalid.'
            );
        }

        if (
            payment.Bank_Account__r == null
            || payment.Bank_Account__r.Company__c
                != payment.Company__c
            || payment.Bank_Account__r.Is_Active__c
                != true
            || payment.Bank_Account__r.GL_Account__c
                == null
        ) {
            throw new SupplierPaymentPostingException(
                'Supplier Payment Bank Account configuration is invalid.'
            );
        }

        GL_Account__c bankGL =
            payment.Bank_Account__r.GL_Account__r;

        if (
            bankGL == null
            || bankGL.Company__c
                != payment.Company__c
            || bankGL.Is_Active__c
                != true
            || bankGL.Account_Type__c
                != 'Asset'
        ) {
            throw new SupplierPaymentPostingException(
                'Bank Account GL mapping must be an active Asset account in the same Accounting Company.'
            );
        }

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
            paymentCurrency
                != companyCurrency
            || bankCurrency
                != companyCurrency
            || payment.Functional_Currency__c
                != companyCurrency
            || payment.Exchange_Rate__c
                != Decimal.valueOf('1')
        ) {
            throw new SupplierPaymentPostingException(
                'G3C supplier disbursement posting is same-currency only. Foreign-currency settlement is deferred to the allocation/realized-FX implementation.'
            );
        }
    }

    private static Accounting_Period__c
        resolveAndLockOpenPeriod(
            Id companyId,
            Date effectiveDate
        ) {
        List<Accounting_Period__c> periods = [
            SELECT Id, Company__c,
                   Status__c,
                   Start_Date__c,
                   End_Date__c
            FROM Accounting_Period__c
            WHERE Company__c =
                :companyId
              AND Start_Date__c
                <= :effectiveDate
              AND End_Date__c
                >= :effectiveDate
            LIMIT 2
            FOR UPDATE
        ];

        if (periods.isEmpty()) {
            throw new SupplierPaymentPostingException(
                'No Accounting Period contains the Payment Effective Date.'
            );
        }

        if (periods.size() > 1) {
            throw new SupplierPaymentPostingException(
                'More than one Accounting Period contains the Payment Effective Date.'
            );
        }

        if (
            periods[0].Status__c
            != 'Open'
        ) {
            throw new SupplierPaymentPostingException(
                'Payment Accounting Period must be Open.'
            );
        }

        return periods[0];
    }

    private static String buildPostingKey(
        Id paymentId
    ) {
        return
            'PAY|'
            + String.valueOf(
                paymentId
            )
            + '|V1';
    }

    private static String buildEventKey(
        Id paymentId
    ) {
        return
            'PAYMENT_DISBURSEMENT|'
            + String.valueOf(
                paymentId
            )
            + '|V1';
    }

    private static String buildAuditRequestKey(
        Id paymentId
    ) {
        return
            'PAYPOST|'
            + String.valueOf(
                paymentId
            );
    }

    private static String buildSourceBusinessKey(
        Accounting_Payment__c payment
    ) {
        if (
            !String.isBlank(
                payment.Provider_Request_Key__c
            )
        ) {
            return payment.Provider_Request_Key__c.trim();
        }

        if (
            !String.isBlank(
                payment.Reference__c
            )
        ) {
            return payment.Reference__c.trim();
        }

        return String.valueOf(
            payment.Id
        );
    }

    private static String buildJournalDescription(
        Accounting_Payment__c payment
    ) {
        String sourceLabel =
            !String.isBlank(
                payment.Reference__c
            )
                ? payment.Reference__c.trim()
                : payment.Name;

        return
            'Supplier Payment - '
            + sourceLabel;
    }

    private static void validateRequest(
        PostingRequest request
    ) {
        if (
            request == null
            || request.paymentId == null
        ) {
            throw new SupplierPaymentPostingException(
                'Supplier Payment Id is required.'
            );
        }

        if (
            String.isBlank(
                request.requestKey
            )
        ) {
            throw new SupplierPaymentPostingException(
                'Request Key is required.'
            );
        }

        if (
            request.requestKey.length()
            > 160
        ) {
            throw new SupplierPaymentPostingException(
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

        return value.substring(
            0,
            maxLength
        );
    }
}
