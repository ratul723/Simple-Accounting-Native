/**
 * G3B - Supplier Bill -> Accounts Payable posting.
 *
 * Trusted subledger path:
 * Approved Supplier Bill -> Accounting Event -> balanced Subledger Journal -> Posted Supplier Bill.
 *
 * Current G3B tax boundary:
 * - Nonrecoverable tax is included in the expense/asset cost.
 * - Recoverable tax is blocked until G4 supplies validated tax-account mapping.
 *
 * The existing manual/opening control-account restriction remains intact.
 */
public without sharing class SABSupplierBillPostingService {

    public class SupplierBillPostingException extends Exception {}

    private static final String POST_PERMISSION = 'SAB_Post_Journal';
    private static final String STATUS_APPROVED = 'Approved';
    private static final String STATUS_POSTED = 'Posted';
    private static final String DOCUMENT_BILL = 'Bill';
    private static final String DOCUMENT_CREDIT = 'Supplier Credit';
    private static final String ENTRY_TYPE_SUBLEDGER = 'Subledger';
    private static final String SOURCE_TYPE = 'Supplier_Bill__c';
    private static final String ADAPTER_KEY = 'SUPPLIER_BILL';
    private static final Decimal ZERO = Decimal.valueOf('0');

    public class PostingRequest {
        @AuraEnabled public Id supplierBillId { get; set; }
        @AuraEnabled public String requestKey { get; set; }
    }

    public class PostingResult {
        @AuraEnabled public Id supplierBillId { get; private set; }
        @AuraEnabled public Id journalEntryId { get; private set; }
        @AuraEnabled public Id accountingEventId { get; private set; }
        @AuraEnabled public String postingKey { get; private set; }
        @AuraEnabled public Datetime postedAt { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private PostingResult() {}
    }

    @AuraEnabled
    public static PostingResult postApprovedBill(
        PostingRequest request
    ) {
        validateRequest(request);

        SABPermissionService.assertPermission(
            POST_PERMISSION,
            'You do not have permission to post accounting transactions.'
        );

        Supplier_Bill__c initialBill = [
            SELECT Id, Company__c, Status__c, Accounting_Event__c
            FROM Supplier_Bill__c
            WHERE Id = :request.supplierBillId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(
            initialBill.Company__c
        );

        if (initialBill.Status__c == STATUS_POSTED) {
            return resolvePostedReplay(initialBill);
        }

        if (initialBill.Status__c != STATUS_APPROVED) {
            throw new SupplierBillPostingException(
                'Supplier Bill must be Approved before AP posting.'
            );
        }

        Savepoint outerSavepoint = Database.setSavepoint();

        try {
            // G3A revalidates and locks the source bill before any financial write.
            SABSupplierBillService.assertApprovedForPosting(
                request.supplierBillId
            );

            Supplier_Bill__c bill = [
                SELECT Id, Name, Company__c,
                       Company__r.Functional_Currency__c,
                       Company__r.Default_Rounding_Account__c,
                       Company__r.Default_Rounding_Account__r.Company__c,
                       Company__r.Default_Rounding_Account__r.Is_Active__c,
                       Company__r.Default_Rounding_Account__r.Is_Control_Account__c,
                       Supplier_Profile__c,
                       Supplier_Profile__r.AP_Control_Account__c,
                       Supplier_Profile__r.AP_Control_Account__r.Company__c,
                       Supplier_Profile__r.AP_Control_Account__r.Is_Active__c,
                       Supplier_Profile__r.AP_Control_Account__r.Is_Control_Account__c,
                       Supplier_Profile__r.AP_Control_Account__r.Control_Type__c,
                       Document_Type__c, Document_Date__c,
                       Accounting_Date__c, Due_Date__c,
                       Vendor_Reference__c,
                       Transaction_Currency__c,
                       Functional_Currency__c,
                       Exchange_Rate__c,
                       Status__c, Total__c,
                       Accounting_Event__c
                FROM Supplier_Bill__c
                WHERE Id = :request.supplierBillId
                LIMIT 1
                FOR UPDATE
            ];

            if (bill.Status__c == STATUS_POSTED) {
                return resolvePostedReplay(bill);
            }

            if (bill.Status__c != STATUS_APPROVED) {
                throw new SupplierBillPostingException(
                    'Supplier Bill changed while posting. Retry the posting request.'
                );
            }

            if (bill.Accounting_Event__c != null) {
                throw new SupplierBillPostingException(
                    'Approved Supplier Bill already contains an Accounting Event link.'
                );
            }

            List<Bill_Line__c> billLines = [
                SELECT Id, Line_Number__c, Description__c,
                       Net_Amount__c,
                       Recoverable_Tax_Amount__c,
                       Nonrecoverable_Tax_Amount__c,
                       Expense_or_Asset_Account__c,
                       Department__c, Cost_Center__c, Project__c
                FROM Bill_Line__c
                WHERE Supplier_Bill__c = :bill.Id
                ORDER BY Line_Number__c ASC, Id ASC
            ];

            if (billLines.isEmpty()) {
                throw new SupplierBillPostingException(
                    'Supplier Bill must contain at least one Bill Line.'
                );
            }

            for (Bill_Line__c billLine : billLines) {
                if (
                    nullToZero(billLine.Recoverable_Tax_Amount__c)
                    != ZERO
                ) {
                    throw new SupplierBillPostingException(
                        'G3B does not post recoverable tax yet. Complete the G4 tax-account mapping before posting Supplier Bills with Recoverable Tax Amount.'
                    );
                }
            }

            Accounting_Period__c period =
                resolveAndLockOpenPeriod(
                    bill.Company__c,
                    bill.Accounting_Date__c
                );

            validateAPControlAccount(bill);

            String postingKey = buildPostingKey(bill.Id);

            Journal_Entry__c journal = new Journal_Entry__c(
                Company__c = bill.Company__c,
                Accounting_Period__c = period.Id,
                Accounting_Date__c = bill.Accounting_Date__c,
                Entry_Type__c = ENTRY_TYPE_SUBLEDGER,
                Status__c = 'Draft',
                Description__c = truncateText(
                    buildJournalDescription(bill),
                    Journal_Entry__c.Description__c.getDescribe().getLength()
                ),
                Version__c = 1
            );

            insert journal;

            String transactionCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    bill.Transaction_Currency__c
                );

            String functionalCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    bill.Company__r.Functional_Currency__c
                );

            Decimal effectiveRate =
                transactionCurrency == functionalCurrency
                    ? Decimal.valueOf('1')
                    : bill.Exchange_Rate__c;

            List<Journal_Entry_Line__c> journalLines =
                new List<Journal_Entry_Line__c>();

            Decimal functionalSourceTotal = ZERO;
            Decimal nextLineNumber = 1;

            for (Bill_Line__c billLine : billLines) {
                Decimal transactionAmount =
                    SABMoneyService.normalizeTransactionAmount(
                        nullToZero(billLine.Net_Amount__c)
                        + nullToZero(
                            billLine.Nonrecoverable_Tax_Amount__c
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

                Journal_Entry_Line__c journalLine =
                    new Journal_Entry_Line__c(
                        Journal_Entry__c = journal.Id,
                        GL_Account__c =
                            billLine.Expense_or_Asset_Account__c,
                        Line_Number__c = nextLineNumber,
                        Debit_Base__c =
                            bill.Document_Type__c == DOCUMENT_BILL
                                ? conversion.functionalAmount
                                : ZERO,
                        Credit_Base__c =
                            bill.Document_Type__c == DOCUMENT_CREDIT
                                ? conversion.functionalAmount
                                : ZERO,
                        Explanation__c = truncateText(
                            billLine.Description__c,
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
                        Rate_Date__c = bill.Accounting_Date__c,
                        Rate_Source__c = 'Supplier Bill Snapshot',
                        Source_Line_Key__c =
                            'SB|' + String.valueOf(bill.Id)
                            + '|LINE|' + String.valueOf(billLine.Id),
                        Department__c = billLine.Department__c,
                        Cost_Center__c = billLine.Cost_Center__c,
                        Project__c = billLine.Project__c
                    );

                journalLines.add(journalLine);
                nextLineNumber++;
            }

            if (journalLines.isEmpty()) {
                throw new SupplierBillPostingException(
                    'Supplier Bill has no non-zero amount to post.'
                );
            }

            SABMoneyService.ConversionResult headerConversion =
                SABMoneyService.convertToFunctional(
                    bill.Total__c,
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
                Journal_Entry_Line__c roundingLine =
                    buildRoundingLine(
                        bill,
                        journal.Id,
                        nextLineNumber,
                        roundingDifference,
                        functionalCurrency
                    );

                journalLines.add(roundingLine);
                nextLineNumber++;
            }

            Journal_Entry_Line__c apLine =
                new Journal_Entry_Line__c(
                    Journal_Entry__c = journal.Id,
                    GL_Account__c =
                        bill.Supplier_Profile__r.AP_Control_Account__c,
                    Line_Number__c = nextLineNumber,
                    Debit_Base__c =
                        bill.Document_Type__c == DOCUMENT_CREDIT
                            ? headerConversion.functionalAmount
                            : ZERO,
                    Credit_Base__c =
                        bill.Document_Type__c == DOCUMENT_BILL
                            ? headerConversion.functionalAmount
                            : ZERO,
                    Explanation__c = truncateText(
                        'Accounts Payable - ' + buildSourceLabel(bill),
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
                    Rate_Date__c = bill.Accounting_Date__c,
                    Rate_Source__c = 'Supplier Bill Snapshot',
                    Source_Line_Key__c =
                        'SB|' + String.valueOf(bill.Id) + '|AP'
                );

            journalLines.add(apLine);
            insert journalLines;

            SABAccountingEventService.ReservationRequest eventRequest =
                new SABAccountingEventService.ReservationRequest();

            eventRequest.companyId = bill.Company__c;
            eventRequest.adapterKey = ADAPTER_KEY;
            eventRequest.requestKey = request.requestKey.trim();
            eventRequest.eventKey = buildEventKey(bill.Id);
            eventRequest.eventType =
                bill.Document_Type__c == DOCUMENT_CREDIT
                    ? 'Supplier Credit'
                    : 'Supplier Bill';
            eventRequest.sourceBusinessKey =
                buildSourceBusinessKey(bill);
            eventRequest.sourceRecordId =
                String.valueOf(bill.Id);
            eventRequest.sourceType = SOURCE_TYPE;
            eventRequest.sourceVersion = 1;

            SABPostingService.PostingRequest postingRequest =
                new SABPostingService.PostingRequest();

            postingRequest.journalEntryId = journal.Id;
            postingRequest.postingKey = postingKey;
            postingRequest.eventRequest = eventRequest;

            SABPostingService.PostingResult postedJournal =
                SABPostingService.postDraftJournal(
                    postingRequest
                );

            SABSupplierBillService.TransitionResult billCompletion =
                SABSupplierBillService.completePosting(
                    bill.Id,
                    postedJournal.accountingEventId,
                    postedJournal.journalEntryId,
                    buildAuditRequestKey(bill.Id)
                );

            PostingResult result = new PostingResult();
            result.supplierBillId = bill.Id;
            result.journalEntryId =
                postedJournal.journalEntryId;
            result.accountingEventId =
                postedJournal.accountingEventId;
            result.postingKey = postedJournal.postingKey;
            result.postedAt = postedJournal.postedAt;
            result.replay =
                postedJournal.replay
                || billCompletion.idempotentReplay;

            return result;
        } catch (Exception ex) {
            Database.rollback(outerSavepoint);
            throw ex;
        }
    }

    private static PostingResult resolvePostedReplay(
        Supplier_Bill__c bill
    ) {
        if (bill.Accounting_Event__c == null) {
            throw new SupplierBillPostingException(
                'Posted Supplier Bill is missing its Accounting Event link.'
            );
        }

        Accounting_Event__c eventRecord = [
            SELECT Id, Company__c, Event_Key__c,
                   Source_Type__c, Source_Record_Id__c,
                   State__c, Journal_Entry__c,
                   Journal_Entry__r.Status__c,
                   Journal_Entry__r.Entry_Type__c,
                   Journal_Entry__r.Posting_Key__c,
                   Journal_Entry__r.Posted_At__c
            FROM Accounting_Event__c
            WHERE Id = :bill.Accounting_Event__c
            LIMIT 1
        ];

        if (
            eventRecord.Company__c != bill.Company__c
            || eventRecord.Event_Key__c != buildEventKey(bill.Id)
            || eventRecord.Source_Type__c != SOURCE_TYPE
            || eventRecord.Source_Record_Id__c
                != String.valueOf(bill.Id)
            || eventRecord.State__c != 'Posted'
            || eventRecord.Journal_Entry__c == null
            || eventRecord.Journal_Entry__r.Status__c != 'Posted'
            || eventRecord.Journal_Entry__r.Entry_Type__c
                != ENTRY_TYPE_SUBLEDGER
            || eventRecord.Journal_Entry__r.Posting_Key__c
                != buildPostingKey(bill.Id)
        ) {
            throw new SupplierBillPostingException(
                'Posted Supplier Bill does not have a consistent AP posting chain.'
            );
        }

        PostingResult result = new PostingResult();
        result.supplierBillId = bill.Id;
        result.journalEntryId = eventRecord.Journal_Entry__c;
        result.accountingEventId = eventRecord.Id;
        result.postingKey =
            eventRecord.Journal_Entry__r.Posting_Key__c;
        result.postedAt =
            eventRecord.Journal_Entry__r.Posted_At__c;
        result.replay = true;

        return result;
    }

    private static Accounting_Period__c resolveAndLockOpenPeriod(
        Id companyId,
        Date accountingDate
    ) {
        List<Accounting_Period__c> periods = [
            SELECT Id, Company__c, Status__c,
                   Start_Date__c, End_Date__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
              AND Start_Date__c <= :accountingDate
              AND End_Date__c >= :accountingDate
            LIMIT 2
            FOR UPDATE
        ];

        if (periods.isEmpty()) {
            throw new SupplierBillPostingException(
                'No Accounting Period contains the Supplier Bill Accounting Date.'
            );
        }

        if (periods.size() > 1) {
            throw new SupplierBillPostingException(
                'More than one Accounting Period contains the Supplier Bill Accounting Date.'
            );
        }

        if (periods[0].Status__c != 'Open') {
            throw new SupplierBillPostingException(
                'Supplier Bill Accounting Period must be Open.'
            );
        }

        return periods[0];
    }

    private static void validateAPControlAccount(
        Supplier_Bill__c bill
    ) {
        if (
            bill.Supplier_Profile__r == null
            || bill.Supplier_Profile__r.AP_Control_Account__c == null
        ) {
            throw new SupplierBillPostingException(
                'Supplier Accounting Profile requires an AP Control Account.'
            );
        }

        GL_Account__c apAccount =
            bill.Supplier_Profile__r.AP_Control_Account__r;

        if (
            apAccount == null
            || apAccount.Company__c != bill.Company__c
            || apAccount.Is_Active__c != true
            || apAccount.Is_Control_Account__c != true
            || apAccount.Control_Type__c != 'AP'
        ) {
            throw new SupplierBillPostingException(
                'Supplier AP Control Account configuration is invalid.'
            );
        }
    }

    private static Journal_Entry_Line__c buildRoundingLine(
        Supplier_Bill__c bill,
        Id journalId,
        Decimal lineNumber,
        Decimal difference,
        String functionalCurrency
    ) {
        Id roundingAccountId =
            bill.Company__r.Default_Rounding_Account__c;

        if (roundingAccountId == null) {
            throw new SupplierBillPostingException(
                'Supplier Bill conversion requires a rounding adjustment, but the Accounting Company has no Default Rounding Account.'
            );
        }

        if (
            bill.Company__r.Default_Rounding_Account__r == null
            || bill.Company__r.Default_Rounding_Account__r.Company__c
                != bill.Company__c
            || bill.Company__r.Default_Rounding_Account__r.Is_Active__c
                != true
            || bill.Company__r.Default_Rounding_Account__r.Is_Control_Account__c
                == true
        ) {
            throw new SupplierBillPostingException(
                'Default Rounding Account must be an active, non-control GL Account in the same Accounting Company.'
            );
        }

        Decimal absoluteDifference = difference.abs();
        Boolean positiveDifference = difference > ZERO;
        Boolean debitRounding;

        if (bill.Document_Type__c == DOCUMENT_BILL) {
            debitRounding = positiveDifference;
        } else {
            debitRounding = !positiveDifference;
        }

        return new Journal_Entry_Line__c(
            Journal_Entry__c = journalId,
            GL_Account__c = roundingAccountId,
            Line_Number__c = lineNumber,
            Debit_Base__c =
                debitRounding
                    ? absoluteDifference
                    : ZERO,
            Credit_Base__c =
                debitRounding
                    ? ZERO
                    : absoluteDifference,
            Explanation__c = 'Supplier Bill FX/rounding adjustment',
            Transaction_Amount__c = absoluteDifference,
            Transaction_Currency__c = functionalCurrency,
            Functional_Currency__c = functionalCurrency,
            Applied_Exchange_Rate__c = Decimal.valueOf('1'),
            Rate_Date__c = bill.Accounting_Date__c,
            Rate_Source__c = 'Rounding',
            Source_Line_Key__c =
                'SB|' + String.valueOf(bill.Id) + '|ROUND'
        );
    }

    private static String buildPostingKey(Id billId) {
        return 'SB|' + String.valueOf(billId) + '|V1';
    }

    private static String buildEventKey(Id billId) {
        return 'SUPPLIER_BILL|' + String.valueOf(billId) + '|V1';
    }

    private static String buildAuditRequestKey(Id billId) {
        return 'SBPOST|' + String.valueOf(billId);
    }

    private static String buildSourceBusinessKey(
        Supplier_Bill__c bill
    ) {
        if (!String.isBlank(bill.Vendor_Reference__c)) {
            return String.valueOf(bill.Supplier_Profile__c)
                + '|'
                + bill.Vendor_Reference__c.trim();
        }

        return String.valueOf(bill.Id);
    }

    private static String buildJournalDescription(
        Supplier_Bill__c bill
    ) {
        String labelValue =
            bill.Document_Type__c == DOCUMENT_CREDIT
                ? 'Supplier Credit'
                : 'Supplier Bill';

        return labelValue + ' - ' + buildSourceLabel(bill);
    }

    private static String buildSourceLabel(
        Supplier_Bill__c bill
    ) {
        if (!String.isBlank(bill.Vendor_Reference__c)) {
            return bill.Vendor_Reference__c.trim();
        }

        if (!String.isBlank(bill.Name)) {
            return bill.Name;
        }

        return String.valueOf(bill.Id);
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

        return value.substring(0, maxLength);
    }

    private static Decimal nullToZero(Decimal value) {
        return value == null ? ZERO : value;
    }

    private static void validateRequest(PostingRequest request) {
        if (request == null) {
            throw new SupplierBillPostingException(
                'Supplier Bill posting request is required.'
            );
        }

        if (request.supplierBillId == null) {
            throw new SupplierBillPostingException(
                'Supplier Bill Id is required.'
            );
        }

        if (String.isBlank(request.requestKey)) {
            throw new SupplierBillPostingException(
                'Request Key is required.'
            );
        }

        Integer requestMaxLength =
            Accounting_Event__c.Created_Request_Key__c.getDescribe().getLength();

        if (
            requestMaxLength > 0
            && request.requestKey.trim().length() > requestMaxLength
        ) {
            throw new SupplierBillPostingException(
                'Request Key cannot exceed '
                + requestMaxLength
                + ' characters.'
            );
        }
    }
}
