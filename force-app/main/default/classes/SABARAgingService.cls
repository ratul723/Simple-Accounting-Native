/**
 * G4D - Accounts Receivable Aging / Outstanding Receivables.
 *
 * Source model:
 * - Posted Invoice__c documents create receivables.
 * - Payment_Allocation__c reduces receivables by effective date.
 * - Posted Credit Note Invoice__c records reduce their Original_Invoice__c by
 *   Accounting_Date__c.
 *
 * No editable Paid / Partially Paid state is used. Outstanding is derived.
 *
 * Historical-as-of rule for allocations:
 * - include Allocated and Reversed rows whose effective date is <= asOfDate;
 * - exclude Cancelled rows;
 * - reversal rows are negative, so an original positive allocation remains
 *   visible before the reversal effective date and nets to zero afterwards.
 *
 * Current G4B/G4C customer-receipt scope is same-currency. This service still
 * keeps transaction and functional/base values separate so later FX settlement
 * work can extend the contract without replacing this report.
 */
public with sharing class SABARAgingService {

    public class ARAgingException extends Exception {}

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    private static final Integer MAX_INVOICES =
        2000;

    public class ARAgingRequest {
        public Id companyId;
        public Date asOfDate;
        public Id partyProfileId;
        public Boolean includeSettled;
    }

    public class ARAgingRow {
        public Id invoiceId;
        public String legalNumber;
        public Id partyProfileId;
        public Id accountId;
        public String customerName;

        public Date documentDate;
        public Date accountingDate;
        public Date dueDate;
        public Integer daysPastDue;
        public String agingBucket;

        public String transactionCurrency;
        public String functionalCurrency;
        public Decimal exchangeRate;

        public Decimal originalDocumentAmount;
        public Decimal allocatedDocumentAmount;
        public Decimal creditedDocumentAmount;
        public Decimal outstandingDocumentAmount;

        public Decimal originalBaseAmount;
        public Decimal allocatedBaseAmount;
        public Decimal creditedBaseAmount;
        public Decimal outstandingBaseAmount;
    }

    public class CustomerSummary {
        public Id partyProfileId;
        public Id accountId;
        public String customerName;

        public Decimal currentAmount;
        public Decimal days1To30Amount;
        public Decimal days31To60Amount;
        public Decimal days61To90Amount;
        public Decimal days91PlusAmount;
        public Decimal totalOutstanding;

        public Integer openInvoiceCount;
    }

    public class ARAgingResult {
        public Id companyId;
        public String companyName;
        public String functionalCurrency;
        public Date asOfDate;
        public Datetime generatedAt;
        public Boolean truncated;

        public Decimal currentAmount;
        public Decimal days1To30Amount;
        public Decimal days31To60Amount;
        public Decimal days61To90Amount;
        public Decimal days91PlusAmount;
        public Decimal totalOutstanding;

        public Integer openInvoiceCount;

        public List<ARAgingRow> rows;
        public List<CustomerSummary> customers;
    }

    public static ARAgingResult getAging(
        ARAgingRequest request
    ) {
        validateRequest(request);

        SABCompanyAccessService.assertCompanyAccess(
            request.companyId
        );

        assertReadAccess();

        Accounting_Company__c company = [
            SELECT Id,
                   Name__c,
                   Functional_Currency__c
            FROM Accounting_Company__c
            WHERE Id = :request.companyId
            LIMIT 1
        ];

        if (request.partyProfileId != null) {
            validateCustomerFilter(
                request.companyId,
                request.partyProfileId
            );
        }

        List<Invoice__c> invoices;

        if (request.partyProfileId == null) {
            invoices = [
                SELECT Id,
                       Legal_Number__c,
                       Company__c,
                       Party_Profile__c,
                       Party_Profile__r.Account__c,
                       Party_Profile__r.Account__r.Name,
                       Document_Date__c,
                       Accounting_Date__c,
                       Due_Date__c,
                       Total__c,
                       Transaction_Currency__c,
                       Functional_Currency__c,
                       Exchange_Rate__c
                FROM Invoice__c
                WHERE Company__c = :request.companyId
                  AND Document_Type__c = 'Invoice'
                  AND Status__c = 'Posted'
                  AND Accounting_Date__c <= :request.asOfDate
                ORDER BY Due_Date__c ASC,
                         Legal_Number__c ASC,
                         CreatedDate ASC
                LIMIT 2001
            ];
        } else {
            invoices = [
                SELECT Id,
                       Legal_Number__c,
                       Company__c,
                       Party_Profile__c,
                       Party_Profile__r.Account__c,
                       Party_Profile__r.Account__r.Name,
                       Document_Date__c,
                       Accounting_Date__c,
                       Due_Date__c,
                       Total__c,
                       Transaction_Currency__c,
                       Functional_Currency__c,
                       Exchange_Rate__c
                FROM Invoice__c
                WHERE Company__c = :request.companyId
                  AND Party_Profile__c = :request.partyProfileId
                  AND Document_Type__c = 'Invoice'
                  AND Status__c = 'Posted'
                  AND Accounting_Date__c <= :request.asOfDate
                ORDER BY Due_Date__c ASC,
                         Legal_Number__c ASC,
                         CreatedDate ASC
                LIMIT 2001
            ];
        }

        Boolean truncated =
            invoices.size() > MAX_INVOICES;

        if (truncated) {
            invoices.remove(
                invoices.size() - 1
            );
        }

        Set<Id> invoiceIds =
            new Set<Id>();

        for (Invoice__c invoice : invoices) {
            invoiceIds.add(
                invoice.Id
            );
        }

        Map<Id, AmountBucket> allocationsByInvoice =
            loadAllocationAmounts(
                invoiceIds,
                request.asOfDate
            );

        Map<Id, AmountBucket> creditsByInvoice =
            loadCreditAmounts(
                invoiceIds,
                request.asOfDate
            );

        ARAgingResult result =
            initializeResult(
                company,
                request.asOfDate,
                truncated
            );

        Map<Id, CustomerSummary> summaryByParty =
            new Map<Id, CustomerSummary>();

        Boolean includeSettled =
            request.includeSettled == true;

        for (Invoice__c invoice : invoices) {
            validateInvoiceSnapshot(
                invoice,
                company.Functional_Currency__c
            );

            SABMoneyService.ConversionResult invoiceConversion =
                SABMoneyService.convertToFunctional(
                    invoice.Total__c,
                    invoice.Transaction_Currency__c,
                    invoice.Functional_Currency__c,
                    invoice.Exchange_Rate__c,
                    RoundingMode.HALF_UP
                );

            AmountBucket allocations =
                allocationsByInvoice.containsKey(
                    invoice.Id
                )
                    ? allocationsByInvoice.get(
                        invoice.Id
                    )
                    : new AmountBucket();

            AmountBucket credits =
                creditsByInvoice.containsKey(
                    invoice.Id
                )
                    ? creditsByInvoice.get(
                        invoice.Id
                    )
                    : new AmountBucket();

            Decimal outstandingDocument =
                SABMoneyService.normalizeTransactionAmount(
                    invoiceConversion.transactionAmount
                    - allocations.documentAmount
                    - credits.documentAmount,
                    RoundingMode.HALF_UP
                );

            Decimal outstandingBase =
                SABMoneyService.normalizeLedgerAmount(
                    invoiceConversion.functionalAmount
                    - allocations.baseAmount
                    - credits.baseAmount,
                    RoundingMode.HALF_UP
                );

            if (outstandingDocument < ZERO) {
                outstandingDocument = ZERO;
            }

            if (outstandingBase < ZERO) {
                outstandingBase = ZERO;
            }

            if (
                !includeSettled
                && outstandingBase == ZERO
            ) {
                continue;
            }

            ARAgingRow row =
                new ARAgingRow();

            row.invoiceId =
                invoice.Id;
            row.legalNumber =
                invoice.Legal_Number__c;
            row.partyProfileId =
                invoice.Party_Profile__c;
            row.accountId =
                invoice.Party_Profile__r == null
                    ? null
                    : invoice.Party_Profile__r.Account__c;
            row.customerName =
                invoice.Party_Profile__r == null
                || invoice.Party_Profile__r.Account__r == null
                    ? null
                    : invoice.Party_Profile__r.Account__r.Name;

            row.documentDate =
                invoice.Document_Date__c;
            row.accountingDate =
                invoice.Accounting_Date__c;
            row.dueDate =
                invoice.Due_Date__c;
            row.daysPastDue =
                calculateDaysPastDue(
                    invoice.Due_Date__c,
                    request.asOfDate
                );
            row.agingBucket =
                agingBucket(
                    row.daysPastDue
                );

            row.transactionCurrency =
                invoiceConversion.transactionCurrency;
            row.functionalCurrency =
                invoiceConversion.functionalCurrency;
            row.exchangeRate =
                invoiceConversion.appliedExchangeRate;

            row.originalDocumentAmount =
                invoiceConversion.transactionAmount;
            row.allocatedDocumentAmount =
                allocations.documentAmount;
            row.creditedDocumentAmount =
                credits.documentAmount;
            row.outstandingDocumentAmount =
                outstandingDocument;

            row.originalBaseAmount =
                invoiceConversion.functionalAmount;
            row.allocatedBaseAmount =
                allocations.baseAmount;
            row.creditedBaseAmount =
                credits.baseAmount;
            row.outstandingBaseAmount =
                outstandingBase;

            result.rows.add(
                row
            );

            if (outstandingBase > ZERO) {
                result.openInvoiceCount++;

                addToReportBucket(
                    result,
                    row.agingBucket,
                    outstandingBase
                );

                result.totalOutstanding +=
                    outstandingBase;

                CustomerSummary summary =
                    getOrCreateCustomerSummary(
                        summaryByParty,
                        row
                    );

                summary.openInvoiceCount++;

                addToCustomerBucket(
                    summary,
                    row.agingBucket,
                    outstandingBase
                );

                summary.totalOutstanding +=
                    outstandingBase;
            }
        }

        result.customers.addAll(
            summaryByParty.values()
        );

        return result;
    }

    private static Map<Id, AmountBucket>
        loadAllocationAmounts(
            Set<Id> invoiceIds,
            Date asOfDate
        )
    {
        Map<Id, AmountBucket> result =
            new Map<Id, AmountBucket>();

        if (invoiceIds.isEmpty()) {
            return result;
        }

        for (Payment_Allocation__c allocation : [
            SELECT Invoice__c,
                   Document_Amount__c,
                   Base_Amount__c,
                   Effective_Date__c,
                   Allocation_Date__c,
                   Status__c
            FROM Payment_Allocation__c
            WHERE Invoice__c IN :invoiceIds
              AND Status__c IN (
                  'Allocated',
                  'Reversed'
              )
              AND (
                    Effective_Date__c <= :asOfDate
                    OR (
                        Effective_Date__c = null
                        AND Allocation_Date__c <= :asOfDate
                    )
              )
        ]) {
            AmountBucket bucket =
                result.containsKey(
                    allocation.Invoice__c
                )
                    ? result.get(
                        allocation.Invoice__c
                    )
                    : new AmountBucket();

            Decimal documentAmount =
                allocation.Document_Amount__c == null
                    ? ZERO
                    : allocation.Document_Amount__c;

            Decimal baseAmount =
                allocation.Base_Amount__c == null
                    ? ZERO
                    : allocation.Base_Amount__c;

            bucket.documentAmount +=
                documentAmount;

            bucket.baseAmount +=
                baseAmount;

            result.put(
                allocation.Invoice__c,
                bucket
            );
        }

        return result;
    }

    private static Map<Id, AmountBucket>
        loadCreditAmounts(
            Set<Id> invoiceIds,
            Date asOfDate
        )
    {
        Map<Id, AmountBucket> result =
            new Map<Id, AmountBucket>();

        if (invoiceIds.isEmpty()) {
            return result;
        }

        for (Invoice__c creditNote : [
            SELECT Id,
                   Original_Invoice__c,
                   Total__c,
                   Transaction_Currency__c,
                   Functional_Currency__c,
                   Exchange_Rate__c
            FROM Invoice__c
            WHERE Original_Invoice__c IN :invoiceIds
              AND Document_Type__c = 'Credit Note'
              AND Status__c = 'Posted'
              AND Accounting_Date__c <= :asOfDate
        ]) {
            if (creditNote.Total__c == null) {
                continue;
            }

            SABMoneyService.ConversionResult conversion =
                SABMoneyService.convertToFunctional(
                    creditNote.Total__c,
                    creditNote.Transaction_Currency__c,
                    creditNote.Functional_Currency__c,
                    creditNote.Exchange_Rate__c,
                    RoundingMode.HALF_UP
                );

            AmountBucket bucket =
                result.containsKey(
                    creditNote.Original_Invoice__c
                )
                    ? result.get(
                        creditNote.Original_Invoice__c
                    )
                    : new AmountBucket();

            bucket.documentAmount +=
                conversion.transactionAmount;
            bucket.baseAmount +=
                conversion.functionalAmount;

            result.put(
                creditNote.Original_Invoice__c,
                bucket
            );
        }

        return result;
    }

    private static void validateRequest(
        ARAgingRequest request
    ) {
        if (request == null) {
            throw new ARAgingException(
                'AR Aging request is required.'
            );
        }

        if (request.companyId == null) {
            throw new ARAgingException(
                'Accounting Company is required.'
            );
        }

        if (request.asOfDate == null) {
            throw new ARAgingException(
                'As Of Date is required.'
            );
        }
    }

    private static void validateCustomerFilter(
        Id companyId,
        Id partyProfileId
    ) {
        List<Party_Accounting_Profile__c> profiles = [
            SELECT Id,
                   Company__c,
                   Is_Customer__c
            FROM Party_Accounting_Profile__c
            WHERE Id = :partyProfileId
            LIMIT 1
        ];

        if (
            profiles.isEmpty()
            || profiles[0].Company__c
                != companyId
            || profiles[0].Is_Customer__c
                != true
        ) {
            throw new ARAgingException(
                'Selected Customer must be a customer Party Accounting Profile in the selected Accounting Company.'
            );
        }
    }

    private static void validateInvoiceSnapshot(
        Invoice__c invoice,
        String companyFunctionalCurrency
    ) {
        if (
            invoice.Total__c == null
            || invoice.Total__c < ZERO
        ) {
            throw new ARAgingException(
                'Posted Invoice contains an invalid Total amount.'
            );
        }

        if (invoice.Due_Date__c == null) {
            throw new ARAgingException(
                'Posted Invoice requires a Due Date for AR Aging.'
            );
        }

        String invoiceFunctionalCurrency =
            SABMoneyService.normalizeCurrencyCode(
                invoice.Functional_Currency__c
            );

        String companyCurrency =
            SABMoneyService.normalizeCurrencyCode(
                companyFunctionalCurrency
            );

        if (
            invoiceFunctionalCurrency
            != companyCurrency
        ) {
            throw new ARAgingException(
                'Posted Invoice Functional Currency does not match the Accounting Company Functional Currency.'
            );
        }
    }

    private static Integer calculateDaysPastDue(
        Date dueDate,
        Date asOfDate
    ) {
        Integer days =
            dueDate.daysBetween(
                asOfDate
            );

        return days < 0
            ? 0
            : days;
    }

    private static String agingBucket(
        Integer daysPastDue
    ) {
        if (
            daysPastDue == null
            || daysPastDue <= 0
        ) {
            return 'Current';
        }

        if (daysPastDue <= 30) {
            return '1-30';
        }

        if (daysPastDue <= 60) {
            return '31-60';
        }

        if (daysPastDue <= 90) {
            return '61-90';
        }

        return '91+';
    }

    private static ARAgingResult initializeResult(
        Accounting_Company__c company,
        Date asOfDate,
        Boolean truncated
    ) {
        ARAgingResult result =
            new ARAgingResult();

        result.companyId =
            company.Id;
        result.companyName =
            company.Name__c;
        result.functionalCurrency =
            company.Functional_Currency__c;
        result.asOfDate =
            asOfDate;
        result.generatedAt =
            System.now();
        result.truncated =
            truncated;

        result.currentAmount =
            ZERO;
        result.days1To30Amount =
            ZERO;
        result.days31To60Amount =
            ZERO;
        result.days61To90Amount =
            ZERO;
        result.days91PlusAmount =
            ZERO;
        result.totalOutstanding =
            ZERO;
        result.openInvoiceCount =
            0;

        result.rows =
            new List<ARAgingRow>();
        result.customers =
            new List<CustomerSummary>();

        return result;
    }

    private static CustomerSummary
        getOrCreateCustomerSummary(
            Map<Id, CustomerSummary> summaries,
            ARAgingRow row
        )
    {
        if (
            summaries.containsKey(
                row.partyProfileId
            )
        ) {
            return summaries.get(
                row.partyProfileId
            );
        }

        CustomerSummary summary =
            new CustomerSummary();

        summary.partyProfileId =
            row.partyProfileId;
        summary.accountId =
            row.accountId;
        summary.customerName =
            row.customerName;

        summary.currentAmount =
            ZERO;
        summary.days1To30Amount =
            ZERO;
        summary.days31To60Amount =
            ZERO;
        summary.days61To90Amount =
            ZERO;
        summary.days91PlusAmount =
            ZERO;
        summary.totalOutstanding =
            ZERO;
        summary.openInvoiceCount =
            0;

        summaries.put(
            row.partyProfileId,
            summary
        );

        return summary;
    }

    private static void addToReportBucket(
        ARAgingResult result,
        String bucket,
        Decimal amount
    ) {
        if (bucket == 'Current') {
            result.currentAmount += amount;
        } else if (bucket == '1-30') {
            result.days1To30Amount += amount;
        } else if (bucket == '31-60') {
            result.days31To60Amount += amount;
        } else if (bucket == '61-90') {
            result.days61To90Amount += amount;
        } else {
            result.days91PlusAmount += amount;
        }
    }

    private static void addToCustomerBucket(
        CustomerSummary summary,
        String bucket,
        Decimal amount
    ) {
        if (bucket == 'Current') {
            summary.currentAmount += amount;
        } else if (bucket == '1-30') {
            summary.days1To30Amount += amount;
        } else if (bucket == '31-60') {
            summary.days31To60Amount += amount;
        } else if (bucket == '61-90') {
            summary.days61To90Amount += amount;
        } else {
            summary.days91PlusAmount += amount;
        }
    }

    private static void assertReadAccess() {
        SABAccessControlService.assertReadable(
            Invoice__c.SObjectType,
            new List<Schema.SObjectField>{
                Invoice__c.Legal_Number__c,
                Invoice__c.Company__c,
                Invoice__c.Party_Profile__c,
                Invoice__c.Document_Type__c,
                Invoice__c.Status__c,
                Invoice__c.Document_Date__c,
                Invoice__c.Accounting_Date__c,
                Invoice__c.Due_Date__c,
                Invoice__c.Total__c,
                Invoice__c.Transaction_Currency__c,
                Invoice__c.Functional_Currency__c,
                Invoice__c.Exchange_Rate__c,
                Invoice__c.Original_Invoice__c
            }
        );

        SABAccessControlService.assertReadable(
            Party_Accounting_Profile__c.SObjectType,
            new List<Schema.SObjectField>{
                Party_Accounting_Profile__c.Company__c,
                Party_Accounting_Profile__c.Account__c,
                Party_Accounting_Profile__c.Is_Customer__c,
                Party_Accounting_Profile__c.Is_Active__c
            }
        );

        SABAccessControlService.assertReadable(
            Account.SObjectType,
            new List<Schema.SObjectField>{
                Account.Name
            }
        );

        SABAccessControlService.assertReadable(
            Payment_Allocation__c.SObjectType,
            new List<Schema.SObjectField>{
                Payment_Allocation__c.Invoice__c,
                Payment_Allocation__c.Document_Amount__c,
                Payment_Allocation__c.Base_Amount__c,
                Payment_Allocation__c.Effective_Date__c,
                Payment_Allocation__c.Allocation_Date__c,
                Payment_Allocation__c.Status__c
            }
        );
    }

    private class AmountBucket {
        Decimal documentAmount = ZERO;
        Decimal baseAmount = ZERO;
    }
}
