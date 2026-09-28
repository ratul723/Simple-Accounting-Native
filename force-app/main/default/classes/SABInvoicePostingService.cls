/**
 * G6B - Invoice / Credit Note -> Accounts Receivable posting.
 *
 * Trusted subledger path:
 * Approved/Issued Invoice -> Accounting Event -> balanced Subledger Journal
 * -> Posted Invoice.
 *
 * Tax contract:
 * - Invoice revenue lines post Net_Amount__c.
 * - Materialized Document_Tax_Line__c snapshots supply Output Tax posting.
 * - Gross Invoice/Credit Note amount posts to the configured AR control account.
 * - Tax snapshots are validated by SABTaxPostingIntegrationService.
 */
public without sharing class SABInvoicePostingService {

    public class InvoicePostingException extends Exception {}

    private static final String POST_PERMISSION =
        'SAB_Post_Journal';

    private static final String STATUS_APPROVED =
        'Approved';

    private static final String STATUS_ISSUED =
        'Issued';

    private static final String STATUS_POSTED =
        'Posted';

    private static final String DOCUMENT_INVOICE =
        'Invoice';

    private static final String DOCUMENT_CREDIT =
        'Credit Note';

    private static final String ENTRY_TYPE_SUBLEDGER =
        'Subledger';

    private static final String SOURCE_TYPE =
        'Invoice__c';

    private static final String ADAPTER_KEY =
        'INVOICE';

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    public class PostingRequest {
        @AuraEnabled public Id invoiceId { get; set; }
        @AuraEnabled public String requestKey { get; set; }
    }

    public class PostingResult {
        @AuraEnabled public Id invoiceId { get; private set; }
        @AuraEnabled public Id journalEntryId { get; private set; }
        @AuraEnabled public Id accountingEventId { get; private set; }
        @AuraEnabled public String postingKey { get; private set; }
        @AuraEnabled public Datetime postedAt { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private PostingResult() {}
    }

    @AuraEnabled
    public static PostingResult postApprovedInvoice(
        PostingRequest request
    ) {
        validateRequest(
            request
        );

        SABPermissionService.assertPermission(
            POST_PERMISSION,
            'You do not have permission to post accounting transactions.'
        );

        Invoice__c initialInvoice = [
            SELECT Id,
                   Company__c,
                   Status__c,
                   Accounting_Event__c
            FROM Invoice__c
            WHERE Id = :request.invoiceId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(
            initialInvoice.Company__c
        );

        if (
            initialInvoice.Status__c
            == STATUS_POSTED
        ) {
            return resolvePostedReplay(
                initialInvoice
            );
        }

        assertPostableStatus(
            initialInvoice.Status__c
        );

        Savepoint outerSavepoint =
            Database.setSavepoint();

        try {
            Invoice__c invoice = [
                SELECT Id,
                       Name,
                       Legal_Number__c,
                       Company__c,
                       Company__r.Functional_Currency__c,
                       Company__r.Default_Rounding_Account__c,
                       Company__r.Default_Rounding_Account__r.Company__c,
                       Company__r.Default_Rounding_Account__r.Is_Active__c,
                       Company__r.Default_Rounding_Account__r.Is_Control_Account__c,
                       Party_Profile__c,
                       Party_Profile__r.AR_Control_Account__c,
                       Party_Profile__r.AR_Control_Account__r.Company__c,
                       Party_Profile__r.AR_Control_Account__r.Is_Active__c,
                       Party_Profile__r.AR_Control_Account__r.Is_Control_Account__c,
                       Party_Profile__r.AR_Control_Account__r.Control_Type__c,
                       Document_Type__c,
                       Document_Date__c,
                       Accounting_Date__c,
                       Due_Date__c,
                       Original_Invoice__c,
                       Transaction_Currency__c,
                       Functional_Currency__c,
                       Exchange_Rate__c,
                       Exchange_Rate_Date__c,
                       Status__c,
                       Subtotal__c,
                       Tax_Total__c,
                       Total__c,
                       Accounting_Event__c
                FROM Invoice__c
                WHERE Id = :request.invoiceId
                LIMIT 1
                FOR UPDATE
            ];

            if (
                invoice.Status__c
                == STATUS_POSTED
            ) {
                return resolvePostedReplay(
                    invoice
                );
            }

            assertPostableStatus(
                invoice.Status__c
            );

            if (
                invoice.Accounting_Event__c
                != null
            ) {
                throw new InvoicePostingException(
                    'Postable Invoice already contains an Accounting Event link.'
                );
            }

            List<Invoice_Line__c> invoiceLines = [
                SELECT Id,
                       Invoice__c,
                       Line_Number__c,
                       Description__c,
                       Quantity__c,
                       Unit_Price__c,
                       Discount_Amount__c,
                       Net_Amount__c,
                       Revenue_Account__c,
                       Tax_Code__c,
                       Department__c,
                       Cost_Center__c,
                       Project__c,
                       Tax_Treatment_Snapshot__c
                FROM Invoice_Line__c
                WHERE Invoice__c = :invoice.Id
                ORDER BY Line_Number__c ASC,
                         Id ASC
            ];

            SABInvoiceValidationService.validateForPosting(
                    invoice,
                    invoiceLines
                );

            validateARControlAccount(
                invoice
            );

            Accounting_Period__c period =
                resolveAndLockOpenPeriod(
                    invoice.Company__c,
                    invoice.Accounting_Date__c
                );

            Journal_Entry__c journal =
                new Journal_Entry__c(
                    Company__c =
                        invoice.Company__c,
                    Accounting_Period__c =
                        period.Id,
                    Accounting_Date__c =
                        invoice.Accounting_Date__c,
                    Entry_Type__c =
                        ENTRY_TYPE_SUBLEDGER,
                    Status__c =
                        'Draft',
                    Description__c =
                        truncateText(
                            buildJournalDescription(
                                invoice
                            ),
                            Journal_Entry__c.Description__c.getDescribe().getLength()
                        ),
                    Version__c =
                        1
                );

            insert journal;

            String transactionCurrency =
                SABMoneyService.normalizeCurrencyCode(
                        invoice.Transaction_Currency__c
                    );

            String functionalCurrency =
                SABMoneyService.normalizeCurrencyCode(
                        invoice.Company__r.Functional_Currency__c
                    );

            Decimal effectiveRate =
                transactionCurrency
                    == functionalCurrency
                        ? Decimal.valueOf('1')
                        : invoice.Exchange_Rate__c;

            List<Journal_Entry_Line__c> journalLines =
                new List<Journal_Entry_Line__c>();

            Decimal functionalSourceTotal =
                ZERO;

            Decimal nextLineNumber =
                1;

            for (
                Invoice_Line__c invoiceLine :
                invoiceLines
            ) {
                Decimal transactionAmount =
                    SABMoneyService.normalizeTransactionAmount(
                            nullToZero(
                                invoiceLine.Net_Amount__c
                            ),
                            RoundingMode.HALF_UP
                        );

                if (transactionAmount == ZERO) {
                    continue;
                }

                SABMoneyService.ConversionResult conversion =
                    SABMoneyService.convertToFunctional(
                            transactionAmount,
                            transactionCurrency,
                            functionalCurrency,
                            effectiveRate,
                            RoundingMode.HALF_UP
                        );

                functionalSourceTotal +=
                    conversion.functionalAmount;

                journalLines.add(
                    new Journal_Entry_Line__c(
                        Journal_Entry__c =
                            journal.Id,
                        GL_Account__c =
                            invoiceLine.Revenue_Account__c,
                        Line_Number__c =
                            nextLineNumber,
                        Debit_Base__c =
                            invoice.Document_Type__c
                                == DOCUMENT_CREDIT
                                    ? conversion.functionalAmount
                                    : ZERO,
                        Credit_Base__c =
                            invoice.Document_Type__c
                                == DOCUMENT_INVOICE
                                    ? conversion.functionalAmount
                                    : ZERO,
                        Explanation__c =
                            truncateText(
                                invoiceLine.Description__c,
                                Journal_Entry_Line__c.Explanation__c.getDescribe().getLength()
                            ),
                        Transaction_Amount__c =
                            conversion.transactionAmount,
                        Transaction_Currency__c =
                            conversion.transactionCurrency,
                        Functional_Currency__c =
                            conversion.functionalCurrency,
                        Applied_Exchange_Rate__c =
                            conversion.appliedExchangeRate,
                        Rate_Date__c =
                            invoice.Accounting_Date__c,
                        Rate_Source__c =
                            'Invoice Snapshot',
                        Source_Line_Key__c =
                            'INV|'
                            + String.valueOf(
                                invoice.Id
                            )
                            + '|LINE|'
                            + String.valueOf(
                                invoiceLine.Id
                            ),
                        Department__c =
                            invoiceLine.Department__c,
                        Cost_Center__c =
                            invoiceLine.Cost_Center__c,
                        Project__c =
                            invoiceLine.Project__c
                    )
                );

                nextLineNumber++;
            }

            SABTaxPostingIntegrationService.JournalTaxBundle
                taxBundle;

            try {
                taxBundle =
                    SABTaxPostingIntegrationService.buildInvoiceJournalTaxLines(
                            invoice.Id,
                            journal.Id,
                            nextLineNumber,
                            transactionCurrency,
                            functionalCurrency,
                            effectiveRate,
                            invoice.Accounting_Date__c
                        );
            } catch (
                SABTaxPostingIntegrationService.TaxPostingException ex
            ) {
                throw new InvoicePostingException(
                    ex.getMessage()
                );
            }

            journalLines.addAll(
                taxBundle.lines
            );

            functionalSourceTotal +=
                taxBundle.functionalMagnitude;

            nextLineNumber =
                taxBundle.nextLineNumber;

            if (journalLines.isEmpty()) {
                throw new InvoicePostingException(
                    'Invoice has no non-zero amount to post.'
                );
            }

            SABMoneyService.ConversionResult
                headerConversion =
                    SABMoneyService.convertToFunctional(
                            invoice.Total__c,
                            transactionCurrency,
                            functionalCurrency,
                            effectiveRate,
                            RoundingMode.HALF_UP
                        );

            Decimal roundingDifference =
                SABMoneyService.roundingDifference(
                        headerConversion.functionalAmount,
                        functionalSourceTotal,
                        RoundingMode.HALF_UP
                    );

            if (roundingDifference != ZERO) {
                journalLines.add(
                    buildRoundingLine(
                        invoice,
                        journal.Id,
                        nextLineNumber,
                        roundingDifference,
                        functionalCurrency
                    )
                );

                nextLineNumber++;
            }

            journalLines.add(
                new Journal_Entry_Line__c(
                    Journal_Entry__c =
                        journal.Id,
                    GL_Account__c =
                        invoice.Party_Profile__r.AR_Control_Account__c,
                    Line_Number__c =
                        nextLineNumber,
                    Debit_Base__c =
                        invoice.Document_Type__c
                            == DOCUMENT_INVOICE
                                ? headerConversion.functionalAmount
                                : ZERO,
                    Credit_Base__c =
                        invoice.Document_Type__c
                            == DOCUMENT_CREDIT
                                ? headerConversion.functionalAmount
                                : ZERO,
                    Explanation__c =
                        truncateText(
                            'Accounts Receivable - '
                            + buildSourceLabel(
                                invoice
                            ),
                            Journal_Entry_Line__c.Explanation__c.getDescribe().getLength()
                        ),
                    Transaction_Amount__c =
                        headerConversion.transactionAmount,
                    Transaction_Currency__c =
                        headerConversion.transactionCurrency,
                    Functional_Currency__c =
                        headerConversion.functionalCurrency,
                    Applied_Exchange_Rate__c =
                        headerConversion.appliedExchangeRate,
                    Rate_Date__c =
                        invoice.Accounting_Date__c,
                    Rate_Source__c =
                        'Invoice Snapshot',
                    Source_Line_Key__c =
                        'INV|'
                        + String.valueOf(
                            invoice.Id
                        )
                        + '|AR'
                )
            );

            insert journalLines;

            SABAccountingEventService.ReservationRequest
                eventRequest =
                    new SABAccountingEventService.ReservationRequest();

            eventRequest.companyId =
                invoice.Company__c;
            eventRequest.adapterKey =
                ADAPTER_KEY;
            eventRequest.requestKey =
                request.requestKey.trim();
            eventRequest.eventKey =
                buildEventKey(
                    invoice.Id
                );
            eventRequest.eventType =
                invoice.Document_Type__c;
            eventRequest.sourceBusinessKey =
                buildSourceBusinessKey(
                    invoice
                );
            eventRequest.sourceRecordId =
                String.valueOf(
                    invoice.Id
                );
            eventRequest.sourceType =
                SOURCE_TYPE;
            eventRequest.sourceVersion =
                1;

            SABPostingService.PostingRequest
                postingRequest =
                    new SABPostingService.PostingRequest();

            postingRequest.journalEntryId =
                journal.Id;
            postingRequest.postingKey =
                buildPostingKey(
                    invoice.Id
                );
            postingRequest.eventRequest =
                eventRequest;

            SABPostingService.PostingResult
                postedJournal =
                    SABPostingService.postDraftJournal(
                            postingRequest
                        );

            completeInvoicePosting(
                invoice.Id,
                postedJournal.accountingEventId,
                postedJournal.journalEntryId
            );

            PostingResult result =
                new PostingResult();

            result.invoiceId =
                invoice.Id;
            result.journalEntryId =
                postedJournal.journalEntryId;
            result.accountingEventId =
                postedJournal.accountingEventId;
            result.postingKey =
                postedJournal.postingKey;
            result.postedAt =
                postedJournal.postedAt;
            result.replay =
                postedJournal.replay;

            return result;
        } catch (Exception ex) {
            Database.rollback(
                outerSavepoint
            );
            throw ex;
        }
    }

    private static void completeInvoicePosting(
        Id invoiceId,
        Id accountingEventId,
        Id journalEntryId
    ) {
        Invoice__c invoice = [
            SELECT Id,
                   Company__c,
                   Status__c,
                   Accounting_Event__c
            FROM Invoice__c
            WHERE Id = :invoiceId
            LIMIT 1
            FOR UPDATE
        ];

        if (
            invoice.Status__c == STATUS_POSTED
        ) {
            if (
                invoice.Accounting_Event__c
                != accountingEventId
            ) {
                throw new InvoicePostingException(
                    'Posted Invoice is linked to a different Accounting Event.'
                );
            }

            return;
        }

        assertPostableStatus(
            invoice.Status__c
        );

        Accounting_Event__c eventRecord = [
            SELECT Id,
                   Company__c,
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
                != invoice.Company__c
            || eventRecord.Source_Type__c
                != SOURCE_TYPE
            || eventRecord.Source_Record_Id__c
                != String.valueOf(
                    invoice.Id
                )
            || eventRecord.State__c
                != 'Posted'
            || eventRecord.Journal_Entry__c
                != journalEntryId
        ) {
            throw new InvoicePostingException(
                'Accounting Event does not represent this posted Invoice.'
            );
        }

        Journal_Entry__c journal = [
            SELECT Id,
                   Company__c,
                   Entry_Type__c,
                   Status__c,
                   Accounting_Event__c
            FROM Journal_Entry__c
            WHERE Id = :journalEntryId
            LIMIT 1
        ];

        if (
            journal.Company__c
                != invoice.Company__c
            || journal.Entry_Type__c
                != ENTRY_TYPE_SUBLEDGER
            || journal.Status__c
                != 'Posted'
            || journal.Accounting_Event__c
                != accountingEventId
        ) {
            throw new InvoicePostingException(
                'Journal Entry does not represent a completed Invoice subledger posting.'
            );
        }

        invoice.Accounting_Event__c =
            accountingEventId;
        invoice.Status__c =
            STATUS_POSTED;

        update invoice;
    }

    private static PostingResult resolvePostedReplay(
        Invoice__c invoice
    ) {
        if (
            invoice.Accounting_Event__c == null
        ) {
            throw new InvoicePostingException(
                'Posted Invoice is missing its Accounting Event link.'
            );
        }

        Accounting_Event__c eventRecord = [
            SELECT Id,
                   Company__c,
                   Event_Key__c,
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
                    :invoice.Accounting_Event__c
            LIMIT 1
        ];

        if (
            eventRecord.Company__c
                != invoice.Company__c
            || eventRecord.Event_Key__c
                != buildEventKey(
                    invoice.Id
                )
            || eventRecord.Source_Type__c
                != SOURCE_TYPE
            || eventRecord.Source_Record_Id__c
                != String.valueOf(
                    invoice.Id
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
                    invoice.Id
                )
        ) {
            throw new InvoicePostingException(
                'Posted Invoice does not have a consistent AR posting chain.'
            );
        }

        PostingResult result =
            new PostingResult();

        result.invoiceId =
            invoice.Id;
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

    private static Accounting_Period__c
        resolveAndLockOpenPeriod(
            Id companyId,
            Date accountingDate
        )
    {
        List<Accounting_Period__c> periods = [
            SELECT Id,
                   Company__c,
                   Status__c,
                   Start_Date__c,
                   End_Date__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
              AND Start_Date__c
                    <= :accountingDate
              AND End_Date__c
                    >= :accountingDate
            LIMIT 2
            FOR UPDATE
        ];

        if (periods.isEmpty()) {
            throw new InvoicePostingException(
                'No Accounting Period contains the Invoice Accounting Date.'
            );
        }

        if (periods.size() > 1) {
            throw new InvoicePostingException(
                'More than one Accounting Period contains the Invoice Accounting Date.'
            );
        }

        if (
            periods[0].Status__c != 'Open'
        ) {
            throw new InvoicePostingException(
                'Invoice Accounting Period must be Open.'
            );
        }

        return periods[0];
    }

    private static void validateARControlAccount(
        Invoice__c invoice
    ) {
        if (
            invoice.Party_Profile__r == null
            || invoice.Party_Profile__r.AR_Control_Account__c
                == null
        ) {
            throw new InvoicePostingException(
                'Customer Accounting Profile requires an AR Control Account.'
            );
        }

        GL_Account__c arAccount =
            invoice.Party_Profile__r.AR_Control_Account__r;

        if (
            arAccount == null
            || arAccount.Company__c
                != invoice.Company__c
            || arAccount.Is_Active__c
                != true
            || arAccount.Is_Control_Account__c
                != true
            || arAccount.Control_Type__c
                != 'AR'
        ) {
            throw new InvoicePostingException(
                'Customer AR Control Account configuration is invalid.'
            );
        }
    }

    private static Journal_Entry_Line__c buildRoundingLine(
        Invoice__c invoice,
        Id journalId,
        Decimal lineNumber,
        Decimal difference,
        String functionalCurrency
    ) {
        Id roundingAccountId =
            invoice.Company__r.Default_Rounding_Account__c;

        if (roundingAccountId == null) {
            throw new InvoicePostingException(
                'Invoice conversion requires a rounding adjustment, but the Accounting Company has no Default Rounding Account.'
            );
        }

        if (
            invoice.Company__r.Default_Rounding_Account__r
                == null
            || invoice.Company__r.Default_Rounding_Account__r.Company__c
                != invoice.Company__c
            || invoice.Company__r.Default_Rounding_Account__r.Is_Active__c
                != true
            || invoice.Company__r.Default_Rounding_Account__r.Is_Control_Account__c
                == true
        ) {
            throw new InvoicePostingException(
                'Default Rounding Account must be an active, non-control GL Account in the same Accounting Company.'
            );
        }

        Decimal absoluteDifference =
            difference.abs();

        Boolean positiveDifference =
            difference > ZERO;

        Boolean debitRounding;

        if (
            invoice.Document_Type__c
                == DOCUMENT_INVOICE
        ) {
            debitRounding =
                !positiveDifference;
        } else {
            debitRounding =
                positiveDifference;
        }

        return new Journal_Entry_Line__c(
            Journal_Entry__c =
                journalId,
            GL_Account__c =
                roundingAccountId,
            Line_Number__c =
                lineNumber,
            Debit_Base__c =
                debitRounding
                    ? absoluteDifference
                    : ZERO,
            Credit_Base__c =
                debitRounding
                    ? ZERO
                    : absoluteDifference,
            Explanation__c =
                'Invoice FX/rounding adjustment',
            Transaction_Amount__c =
                absoluteDifference,
            Transaction_Currency__c =
                functionalCurrency,
            Functional_Currency__c =
                functionalCurrency,
            Applied_Exchange_Rate__c =
                Decimal.valueOf('1'),
            Rate_Date__c =
                invoice.Accounting_Date__c,
            Rate_Source__c =
                'Rounding',
            Source_Line_Key__c =
                'INV|'
                + String.valueOf(
                    invoice.Id
                )
                + '|ROUND'
        );
    }

    private static void assertPostableStatus(
        String statusValue
    ) {
        if (
            statusValue != STATUS_APPROVED
            && statusValue != STATUS_ISSUED
        ) {
            throw new InvoicePostingException(
                'Invoice must be Approved or Issued before AR posting.'
            );
        }
    }

    private static String buildPostingKey(
        Id invoiceId
    ) {
        return 'INV|'
            + String.valueOf(
                invoiceId
            )
            + '|V1';
    }

    private static String buildEventKey(
        Id invoiceId
    ) {
        return 'INVOICE|'
            + String.valueOf(
                invoiceId
            )
            + '|V1';
    }

    private static String buildSourceBusinessKey(
        Invoice__c invoice
    ) {
        if (
            !String.isBlank(
                invoice.Legal_Number__c
            )
        ) {
            return invoice.Legal_Number__c.trim();
        }

        if (
            !String.isBlank(
                invoice.Name
            )
        ) {
            return invoice.Name;
        }

        return String.valueOf(
            invoice.Id
        );
    }

    private static String buildJournalDescription(
        Invoice__c invoice
    ) {
        String labelValue =
            invoice.Document_Type__c
                == DOCUMENT_CREDIT
                    ? 'Credit Note'
                    : 'Invoice';

        return labelValue
            + ' - '
            + buildSourceLabel(
                invoice
            );
    }

    private static String buildSourceLabel(
        Invoice__c invoice
    ) {
        if (
            !String.isBlank(
                invoice.Legal_Number__c
            )
        ) {
            return invoice.Legal_Number__c.trim();
        }

        if (
            !String.isBlank(
                invoice.Name
            )
        ) {
            return invoice.Name;
        }

        return String.valueOf(
            invoice.Id
        );
    }

    private static String truncateText(
        String value,
        Integer maxLength
    ) {
        if (String.isBlank(value)) {
            return value;
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

    private static Decimal nullToZero(
        Decimal value
    ) {
        return value == null
            ? ZERO
            : value;
    }

    private static void validateRequest(
        PostingRequest request
    ) {
        if (request == null) {
            throw new InvoicePostingException(
                'Invoice posting request is required.'
            );
        }

        if (request.invoiceId == null) {
            throw new InvoicePostingException(
                'Invoice Id is required.'
            );
        }

        if (
            String.isBlank(
                request.requestKey
            )
        ) {
            throw new InvoicePostingException(
                'Request Key is required.'
            );
        }

        Integer requestMaxLength =
            Accounting_Event__c.Created_Request_Key__c.getDescribe().getLength();

        if (
            requestMaxLength > 0
            && request.requestKey.trim().length()
                > requestMaxLength
        ) {
            throw new InvoicePostingException(
                'Request Key cannot exceed '
                + requestMaxLength
                + ' characters.'
            );
        }
    }
}
