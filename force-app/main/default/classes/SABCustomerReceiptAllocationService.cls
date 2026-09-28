/**
 * G4C - Customer Receipt allocation to posted customer invoices.
 *
 * Accounting contract:
 * - G4B already posted the receipt: Dr Bank / Cr Accounts Receivable.
 * - G4C DOES NOT create another Journal Entry or Accounting Event.
 * - G4C only applies a Succeeded Receipt to one or more Posted Invoices.
 * - Invoice outstanding is derived from active Payment_Allocation__c records.
 *
 * Current G4 scope is same-currency because G4B customer receipt posting is
 * same-currency only. Realized-FX settlement remains a later concern.
 */
public with sharing class SABCustomerReceiptAllocationService {

    public class ReceiptAllocationException extends Exception {}

    private static final String DIRECTION_RECEIPT = 'Receipt';
    private static final String PAYMENT_STATE_SUCCEEDED = 'Succeeded';
    private static final String ALLOCATION_STATUS = 'Allocated';
    private static final String REVERSED_STATUS = 'Reversed';
    private static final String INVOICE_STATUS_POSTED = 'Posted';
    private static final String INVOICE_DOCUMENT_TYPE = 'Invoice';
    private static final String RECEIPT_EVENT_TYPE = 'Payment Receipt';
    private static final String EVENT_STATE_POSTED = 'Posted';
    private static final Decimal ZERO = Decimal.valueOf('0');

    public class ReceiptAllocationRequest {
        @AuraEnabled public Id invoiceId { get; set; }
        @AuraEnabled public Decimal allocatedAmount { get; set; }
        @AuraEnabled public Date allocationDate { get; set; }
        @AuraEnabled public Date effectiveDate { get; set; }
        @AuraEnabled public String notes { get; set; }
    }

    public class ReceiptAllocationResult {
        @AuraEnabled public Id allocationId { get; private set; }
        @AuraEnabled public Id receiptId { get; private set; }
        @AuraEnabled public Id invoiceId { get; private set; }
        @AuraEnabled public Decimal allocatedAmount { get; private set; }
        @AuraEnabled public Decimal invoiceOutstandingAfter { get; private set; }
        @AuraEnabled public Decimal receiptUnallocatedAfter { get; private set; }
        @AuraEnabled public String status { get; private set; }
    }

    @AuraEnabled
    public static List<ReceiptAllocationResult> allocateToInvoices(
        Id receiptId,
        List<ReceiptAllocationRequest> requests
    ) {
        if (receiptId == null) {
            throw new ReceiptAllocationException(
                'Customer Receipt Id is required.'
            );
        }

        if (requests == null || requests.isEmpty()) {
            throw new ReceiptAllocationException(
                'At least one Invoice allocation is required.'
            );
        }

        assertReadAccess();
        assertAllocationCreateAccess();

        Accounting_Payment__c receipt = [
            SELECT Id, Company__c, Party_Profile__c,
                   Direction__c, Processing_State__c,
                   Amount__c, Transaction_Currency__c,
                   Functional_Currency__c, Exchange_Rate__c,
                   Effective_Date__c, Accounting_Event__c,
                   Accounting_Event__r.Event_Type__c,
                   Accounting_Event__r.State__c,
                   Accounting_Event__r.Source_Type__c,
                   Accounting_Event__r.Source_Record_Id__c
            FROM Accounting_Payment__c
            WHERE Id = :receiptId
            LIMIT 1
            FOR UPDATE
        ];

        SABCompanyAccessService.assertCompanyAccess(
            receipt.Company__c
        );

        SABAccessControlService.assertRecordReadAccess(
            receipt.Id
        );

        validateReceiptForAllocation(receipt);

        Set<Id> invoiceIds = new Set<Id>();
        Map<Id, Decimal> requestedByInvoice =
            new Map<Id, Decimal>();
        Decimal requestedTotal = ZERO;

        for (ReceiptAllocationRequest request : requests) {
            validateRequest(request);

            if (invoiceIds.contains(request.invoiceId)) {
                throw new ReceiptAllocationException(
                    'The same Invoice cannot appear more than once in one allocation request.'
                );
            }

            Decimal amount = normalizePositiveAmount(
                request.allocatedAmount
            );

            invoiceIds.add(request.invoiceId);
            requestedByInvoice.put(
                request.invoiceId,
                amount
            );
            requestedTotal += amount;
        }

        requestedTotal =
            SABMoneyService.normalizeTransactionAmount(
                requestedTotal,
                RoundingMode.HALF_UP
            );

        List<Payment_Allocation__c> existingReceiptAllocations = [
            SELECT Id, Invoice__c, Supplier_Bill__c,
                   Payment_Amount__c, Allocated_Amount__c,
                   Status__c
            FROM Payment_Allocation__c
            WHERE Payment__c = :receipt.Id
              AND Status__c = :ALLOCATION_STATUS
            FOR UPDATE
        ];

        Decimal alreadyAppliedFromReceipt = ZERO;
        Set<Id> alreadyTargetedInvoices = new Set<Id>();

        for (
            Payment_Allocation__c allocation :
            existingReceiptAllocations
        ) {
            alreadyAppliedFromReceipt +=
                effectivePaymentAmount(allocation);

            if (allocation.Invoice__c != null) {
                alreadyTargetedInvoices.add(
                    allocation.Invoice__c
                );
            }

            if (allocation.Supplier_Bill__c != null) {
                throw new ReceiptAllocationException(
                    'Customer Receipt contains an active Supplier Bill allocation. Receipt allocations may target Invoices only.'
                );
            }
        }

        Decimal normalizedReceiptAmount =
            SABMoneyService.normalizeTransactionAmount(
                receipt.Amount__c,
                RoundingMode.HALF_UP
            );

        if (
            alreadyAppliedFromReceipt
            + requestedTotal
            > normalizedReceiptAmount
        ) {
            throw new ReceiptAllocationException(
                'Allocation exceeds the remaining Customer Receipt amount.'
            );
        }

        for (Id invoiceId : invoiceIds) {
            if (alreadyTargetedInvoices.contains(invoiceId)) {
                throw new ReceiptAllocationException(
                    'This Customer Receipt already has an active allocation to the selected Invoice.'
                );
            }
        }

        Map<Id, Invoice__c> invoices =
            new Map<Id, Invoice__c>([
                SELECT Id, Company__c, Party_Profile__c,
                       Document_Type__c, Status__c,
                       Total__c, Transaction_Currency__c,
                       Functional_Currency__c, Exchange_Rate__c,
                       Accounting_Event__c
                FROM Invoice__c
                WHERE Id IN :invoiceIds
                FOR UPDATE
            ]);

        if (invoices.size() != invoiceIds.size()) {
            throw new ReceiptAllocationException(
                'One or more selected Invoices were not found or are not accessible.'
            );
        }

        Map<Id, Decimal> existingByInvoice =
            new Map<Id, Decimal>();

        for (Payment_Allocation__c allocation : [
            SELECT Id, Invoice__c,
                   Document_Amount__c,
                   Allocated_Amount__c,
                   Status__c
            FROM Payment_Allocation__c
            WHERE Invoice__c IN :invoiceIds
              AND Status__c = :ALLOCATION_STATUS
            FOR UPDATE
        ]) {
            Decimal current =
                existingByInvoice.containsKey(
                    allocation.Invoice__c
                )
                    ? existingByInvoice.get(
                        allocation.Invoice__c
                    )
                    : ZERO;

            current +=
                effectiveDocumentAmount(allocation);

            existingByInvoice.put(
                allocation.Invoice__c,
                current
            );
        }

        String receiptTransactionCurrency =
            SABMoneyService.normalizeCurrencyCode(
                receipt.Transaction_Currency__c
            );

        String receiptFunctionalCurrency =
            SABMoneyService.normalizeCurrencyCode(
                receipt.Functional_Currency__c
            );

        if (
            receiptTransactionCurrency
            != receiptFunctionalCurrency
            || receipt.Exchange_Rate__c
                != Decimal.valueOf('1')
        ) {
            throw new ReceiptAllocationException(
                'G4C Customer Receipt allocation currently supports same-currency receipts only.'
            );
        }

        Map<Id, Decimal> invoiceOutstandingBefore =
            new Map<Id, Decimal>();

        for (Id invoiceId : invoiceIds) {
            Invoice__c invoice = invoices.get(invoiceId);

            validateInvoiceForReceipt(
                receipt,
                invoice,
                receiptTransactionCurrency,
                receiptFunctionalCurrency
            );

            Decimal invoiceTotal =
                SABMoneyService.normalizeTransactionAmount(
                    invoice.Total__c,
                    RoundingMode.HALF_UP
                );

            Decimal existingAmount =
                existingByInvoice.containsKey(invoiceId)
                    ? SABMoneyService.normalizeTransactionAmount(
                        existingByInvoice.get(invoiceId),
                        RoundingMode.HALF_UP
                    )
                    : ZERO;

            Decimal outstanding =
                SABMoneyService.normalizeTransactionAmount(
                    invoiceTotal - existingAmount,
                    RoundingMode.HALF_UP
                );

            if (outstanding < ZERO) {
                outstanding = ZERO;
            }

            invoiceOutstandingBefore.put(
                invoiceId,
                outstanding
            );

            if (
                requestedByInvoice.get(invoiceId)
                > outstanding
            ) {
                throw new ReceiptAllocationException(
                    'Allocation exceeds the remaining Invoice amount.'
                );
            }
        }

        List<Payment_Allocation__c> rows =
            new List<Payment_Allocation__c>();

        for (ReceiptAllocationRequest request : requests) {
            Decimal amount =
                requestedByInvoice.get(
                    request.invoiceId
                );

            SABMoneyService.ConversionResult conversion =
                SABMoneyService.convertToFunctional(
                    amount,
                    receiptTransactionCurrency,
                    receiptFunctionalCurrency,
                    Decimal.valueOf('1'),
                    RoundingMode.HALF_UP
                );

            Payment_Allocation__c row =
                new Payment_Allocation__c(
                    Payment__c =
                        receipt.Id,
                    Company__c =
                        receipt.Company__c,
                    Invoice__c =
                        request.invoiceId,
                    Supplier_Bill__c =
                        null,
                    Allocated_Amount__c =
                        conversion.transactionAmount,
                    Payment_Amount__c =
                        conversion.transactionAmount,
                    Document_Amount__c =
                        conversion.transactionAmount,
                    Base_Amount__c =
                        conversion.functionalAmount,
                    Transaction_Currency__c =
                        conversion.transactionCurrency,
                    Exchange_Rate__c =
                        conversion.appliedExchangeRate,
                    Allocation_Date__c =
                        request.allocationDate == null
                            ? Date.today()
                            : request.allocationDate,
                    Effective_Date__c =
                        request.effectiveDate == null
                            ? receipt.Effective_Date__c
                            : request.effectiveDate,
                    Status__c =
                        ALLOCATION_STATUS,
                    Notes__c =
                        trimToLength(
                            request.notes,
                            Payment_Allocation__c.Notes__c
                                .getDescribe()
                                .getLength()
                        )
                );

            if (
                row.Effective_Date__c
                < receipt.Effective_Date__c
            ) {
                throw new ReceiptAllocationException(
                    'Allocation Effective Date cannot be before the Customer Receipt Effective Date.'
                );
            }

            rows.add(row);
        }

        insert rows;

        Decimal receiptRemaining =
            SABMoneyService.normalizeTransactionAmount(
                normalizedReceiptAmount
                - alreadyAppliedFromReceipt
                - requestedTotal,
                RoundingMode.HALF_UP
            );

        List<ReceiptAllocationResult> results =
            new List<ReceiptAllocationResult>();

        for (Payment_Allocation__c row : rows) {
            ReceiptAllocationResult result =
                new ReceiptAllocationResult();

            result.allocationId =
                row.Id;
            result.receiptId =
                receipt.Id;
            result.invoiceId =
                row.Invoice__c;
            result.allocatedAmount =
                row.Payment_Amount__c;
            result.invoiceOutstandingAfter =
                SABMoneyService.normalizeTransactionAmount(
                    invoiceOutstandingBefore.get(
                        row.Invoice__c
                    )
                    - row.Document_Amount__c,
                    RoundingMode.HALF_UP
                );
            result.receiptUnallocatedAfter =
                receiptRemaining;
            result.status =
                row.Status__c;

            results.add(result);
        }

        return results;
    }

    @AuraEnabled
    public static Payment_Allocation__c reverseAllocation(
        Id allocationId,
        String reason
    ) {
        if (allocationId == null) {
            throw new ReceiptAllocationException(
                'Payment Allocation Id is required.'
            );
        }

        if (String.isBlank(reason)) {
            throw new ReceiptAllocationException(
                'A reversal reason is required.'
            );
        }

        assertReadAccess();
        assertAllocationCreateAccess();
        assertAllocationUpdateAccess();

        Payment_Allocation__c original = [
            SELECT Id, Payment__c,
                   Payment__r.Company__c,
                   Payment__r.Direction__c,
                   Company__c, Invoice__c,
                   Supplier_Bill__c,
                   Allocated_Amount__c,
                   Payment_Amount__c,
                   Document_Amount__c,
                   Base_Amount__c,
                   Transaction_Currency__c,
                   Exchange_Rate__c,
                   Allocation_Date__c,
                   Effective_Date__c,
                   Status__c,
                   Allocation_Key__c
            FROM Payment_Allocation__c
            WHERE Id = :allocationId
            LIMIT 1
            FOR UPDATE
        ];

        if (original.Status__c != ALLOCATION_STATUS) {
            throw new ReceiptAllocationException(
                'Only an active Allocated Customer Receipt allocation can be reversed.'
            );
        }

        if (
            original.Invoice__c == null
            || original.Supplier_Bill__c != null
        ) {
            throw new ReceiptAllocationException(
                'G4C reversal supports Customer Receipt to Invoice allocations only.'
            );
        }

        if (
            original.Payment__r == null
            || original.Payment__r.Direction__c
                != DIRECTION_RECEIPT
        ) {
            throw new ReceiptAllocationException(
                'The allocation does not belong to a Customer Receipt.'
            );
        }

        Id companyId =
            original.Company__c == null
                ? original.Payment__r.Company__c
                : original.Company__c;

        SABCompanyAccessService.assertCompanyAccess(
            companyId
        );

        SABAccessControlService.assertRecordEditAccess(
            original.Id
        );

        original.Status__c =
            REVERSED_STATUS;

        update original;

        Payment_Allocation__c reversal =
            new Payment_Allocation__c(
                Payment__c =
                    original.Payment__c,
                Company__c =
                    companyId,
                Invoice__c =
                    original.Invoice__c,
                Supplier_Bill__c =
                    null,
                Allocated_Amount__c =
                    -safeAmount(
                        original.Allocated_Amount__c
                    ),
                Payment_Amount__c =
                    -safeAmount(
                        original.Payment_Amount__c
                    ),
                Document_Amount__c =
                    -safeAmount(
                        original.Document_Amount__c
                    ),
                Base_Amount__c =
                    -safeAmount(
                        original.Base_Amount__c
                    ),
                Transaction_Currency__c =
                    original.Transaction_Currency__c,
                Exchange_Rate__c =
                    original.Exchange_Rate__c,
                Allocation_Date__c =
                    Date.today(),
                Effective_Date__c =
                    Date.today(),
                Status__c =
                    REVERSED_STATUS,
                Reversal_Of__c =
                    original.Id,
                Notes__c =
                    trimToLength(
                        reason.trim(),
                        Payment_Allocation__c.Notes__c
                            .getDescribe()
                            .getLength()
                    )
            );

        insert reversal;

        return reversal;
    }

    @AuraEnabled(cacheable=true)
    public static Decimal getInvoiceOutstanding(
        Id invoiceId
    ) {
        if (invoiceId == null) {
            throw new ReceiptAllocationException(
                'Invoice Id is required.'
            );
        }

        Invoice__c invoice = [
            SELECT Id, Company__c,
                   Document_Type__c,
                   Status__c,
                   Total__c
            FROM Invoice__c
            WHERE Id = :invoiceId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(
            invoice.Company__c
        );

        Decimal allocated = ZERO;

        for (AggregateResult aggregateRow : [
            SELECT SUM(Document_Amount__c) amount
            FROM Payment_Allocation__c
            WHERE Invoice__c = :invoiceId
              AND Status__c = :ALLOCATION_STATUS
        ]) {
            Decimal value =
                (Decimal) aggregateRow.get('amount');

            allocated =
                value == null
                    ? ZERO
                    : value;
        }

        Decimal total =
            invoice.Total__c == null
                ? ZERO
                : SABMoneyService.normalizeTransactionAmount(
                    invoice.Total__c,
                    RoundingMode.HALF_UP
                );

        Decimal outstanding =
            SABMoneyService.normalizeTransactionAmount(
                total - allocated,
                RoundingMode.HALF_UP
            );

        return outstanding < ZERO
            ? ZERO
            : outstanding;
    }

    @AuraEnabled(cacheable=true)
    public static Decimal getReceiptUnallocatedAmount(
        Id receiptId
    ) {
        if (receiptId == null) {
            throw new ReceiptAllocationException(
                'Customer Receipt Id is required.'
            );
        }

        Accounting_Payment__c receipt = [
            SELECT Id, Company__c,
                   Direction__c,
                   Amount__c
            FROM Accounting_Payment__c
            WHERE Id = :receiptId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(
            receipt.Company__c
        );

        if (receipt.Direction__c != DIRECTION_RECEIPT) {
            throw new ReceiptAllocationException(
                'Payment must be a Customer Receipt.'
            );
        }

        Decimal allocated = ZERO;

        for (AggregateResult aggregateRow : [
            SELECT SUM(Payment_Amount__c) amount
            FROM Payment_Allocation__c
            WHERE Payment__c = :receiptId
              AND Status__c = :ALLOCATION_STATUS
        ]) {
            Decimal value =
                (Decimal) aggregateRow.get('amount');

            allocated =
                value == null
                    ? ZERO
                    : value;
        }

        Decimal total =
            SABMoneyService.normalizeTransactionAmount(
                receipt.Amount__c,
                RoundingMode.HALF_UP
            );

        Decimal remaining =
            SABMoneyService.normalizeTransactionAmount(
                total - allocated,
                RoundingMode.HALF_UP
            );

        return remaining < ZERO
            ? ZERO
            : remaining;
    }

    private static void validateReceiptForAllocation(
        Accounting_Payment__c receipt
    ) {
        if (
            receipt.Processing_State__c
            != PAYMENT_STATE_SUCCEEDED
        ) {
            throw new ReceiptAllocationException(
                'Only a Succeeded Customer Receipt can be allocated.'
            );
        }

        if (
            receipt.Direction__c
            != DIRECTION_RECEIPT
        ) {
            throw new ReceiptAllocationException(
                'G4C supports Receipt direction only.'
            );
        }

        if (receipt.Party_Profile__c == null) {
            throw new ReceiptAllocationException(
                'Customer Receipt must have a Party Accounting Profile.'
            );
        }

        if (
            receipt.Amount__c == null
            || receipt.Amount__c <= ZERO
        ) {
            throw new ReceiptAllocationException(
                'Customer Receipt amount must be greater than zero.'
            );
        }

        if (receipt.Accounting_Event__c == null) {
            throw new ReceiptAllocationException(
                'Succeeded Customer Receipt must be linked to its posted Accounting Event before allocation.'
            );
        }

        if (
            receipt.Accounting_Event__r == null
            || receipt.Accounting_Event__r.Event_Type__c
                != RECEIPT_EVENT_TYPE
            || receipt.Accounting_Event__r.State__c
                != EVENT_STATE_POSTED
            || receipt.Accounting_Event__r.Source_Type__c
                != 'Accounting_Payment__c'
            || receipt.Accounting_Event__r.Source_Record_Id__c
                != String.valueOf(receipt.Id)
        ) {
            throw new ReceiptAllocationException(
                'Customer Receipt Accounting Event is not a valid posted Payment Receipt event.'
            );
        }

        if (receipt.Effective_Date__c == null) {
            throw new ReceiptAllocationException(
                'Customer Receipt Effective Date is required.'
            );
        }
    }

    private static void validateInvoiceForReceipt(
        Accounting_Payment__c receipt,
        Invoice__c invoice,
        String receiptTransactionCurrency,
        String receiptFunctionalCurrency
    ) {
        if (invoice == null) {
            throw new ReceiptAllocationException(
                'Invoice was not found.'
            );
        }

        if (
            invoice.Company__c
            != receipt.Company__c
        ) {
            throw new ReceiptAllocationException(
                'Cross-company Customer Receipt allocation is not allowed.'
            );
        }

        if (
            invoice.Party_Profile__c
            != receipt.Party_Profile__c
        ) {
            throw new ReceiptAllocationException(
                'Customer Receipt and Invoice must belong to the same customer Party Accounting Profile.'
            );
        }

        if (
            invoice.Document_Type__c
            != INVOICE_DOCUMENT_TYPE
        ) {
            throw new ReceiptAllocationException(
                'Customer Receipt can be allocated only to an Invoice, not a Credit Note.'
            );
        }

        if (
            invoice.Status__c
            != INVOICE_STATUS_POSTED
        ) {
            throw new ReceiptAllocationException(
                'Invoice must be Posted before a Customer Receipt can be allocated.'
            );
        }

        if (
            invoice.Total__c == null
            || invoice.Total__c <= ZERO
        ) {
            throw new ReceiptAllocationException(
                'Posted Invoice must have a positive Total amount.'
            );
        }

        String invoiceTransactionCurrency =
            SABMoneyService.normalizeCurrencyCode(
                invoice.Transaction_Currency__c
            );

        String invoiceFunctionalCurrency =
            SABMoneyService.normalizeCurrencyCode(
                invoice.Functional_Currency__c
            );

        if (
            invoiceTransactionCurrency
                != receiptTransactionCurrency
            || invoiceFunctionalCurrency
                != receiptFunctionalCurrency
        ) {
            throw new ReceiptAllocationException(
                'G4C Customer Receipt and Invoice currencies must match.'
            );
        }
    }

    private static void validateRequest(
        ReceiptAllocationRequest request
    ) {
        if (request == null) {
            throw new ReceiptAllocationException(
                'Receipt allocation request is required.'
            );
        }

        if (request.invoiceId == null) {
            throw new ReceiptAllocationException(
                'Invoice is required for a Customer Receipt allocation.'
            );
        }

        normalizePositiveAmount(
            request.allocatedAmount
        );
    }

    private static Decimal normalizePositiveAmount(
        Decimal value
    ) {
        if (value == null || value <= ZERO) {
            throw new ReceiptAllocationException(
                'Allocated amount must be greater than zero.'
            );
        }

        Decimal normalized =
            SABMoneyService.normalizeTransactionAmount(
                value,
                RoundingMode.HALF_UP
            );

        if (normalized <= ZERO) {
            throw new ReceiptAllocationException(
                'Allocated amount rounds to zero and cannot be applied.'
            );
        }

        return normalized;
    }

    private static Decimal effectivePaymentAmount(
        Payment_Allocation__c allocation
    ) {
        Decimal value =
            allocation.Payment_Amount__c != null
                ? allocation.Payment_Amount__c
                : allocation.Allocated_Amount__c;

        return safeAmount(value);
    }

    private static Decimal effectiveDocumentAmount(
        Payment_Allocation__c allocation
    ) {
        Decimal value =
            allocation.Document_Amount__c != null
                ? allocation.Document_Amount__c
                : allocation.Allocated_Amount__c;

        return safeAmount(value);
    }

    private static Decimal safeAmount(
        Decimal value
    ) {
        return value == null
            ? ZERO
            : value;
    }

    private static void assertReadAccess() {
        SABAccessControlService.assertReadable(
            Accounting_Payment__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Payment__c.Company__c,
                Accounting_Payment__c.Party_Profile__c,
                Accounting_Payment__c.Direction__c,
                Accounting_Payment__c.Processing_State__c,
                Accounting_Payment__c.Amount__c,
                Accounting_Payment__c.Transaction_Currency__c,
                Accounting_Payment__c.Functional_Currency__c,
                Accounting_Payment__c.Exchange_Rate__c,
                Accounting_Payment__c.Effective_Date__c,
                Accounting_Payment__c.Accounting_Event__c
            }
        );

        SABAccessControlService.assertReadable(
            Invoice__c.SObjectType,
            new List<Schema.SObjectField>{
                Invoice__c.Company__c,
                Invoice__c.Party_Profile__c,
                Invoice__c.Document_Type__c,
                Invoice__c.Status__c,
                Invoice__c.Total__c,
                Invoice__c.Transaction_Currency__c,
                Invoice__c.Functional_Currency__c,
                Invoice__c.Exchange_Rate__c,
                Invoice__c.Accounting_Event__c
            }
        );

        SABAccessControlService.assertReadable(
            Payment_Allocation__c.SObjectType,
            new List<Schema.SObjectField>{
                Payment_Allocation__c.Payment__c,
                Payment_Allocation__c.Company__c,
                Payment_Allocation__c.Invoice__c,
                Payment_Allocation__c.Supplier_Bill__c,
                Payment_Allocation__c.Allocated_Amount__c,
                Payment_Allocation__c.Payment_Amount__c,
                Payment_Allocation__c.Document_Amount__c,
                Payment_Allocation__c.Base_Amount__c,
                Payment_Allocation__c.Transaction_Currency__c,
                Payment_Allocation__c.Exchange_Rate__c,
                Payment_Allocation__c.Allocation_Date__c,
                Payment_Allocation__c.Effective_Date__c,
                Payment_Allocation__c.Status__c,
                Payment_Allocation__c.Reversal_Of__c,
                Payment_Allocation__c.Notes__c
            }
        );
    }

    private static void assertAllocationCreateAccess() {
        SABAccessControlService.assertCreateable(
            Payment_Allocation__c.SObjectType,
            new List<Schema.SObjectField>{
                Payment_Allocation__c.Payment__c,
                Payment_Allocation__c.Company__c,
                Payment_Allocation__c.Invoice__c,
                Payment_Allocation__c.Supplier_Bill__c,
                Payment_Allocation__c.Allocated_Amount__c,
                Payment_Allocation__c.Payment_Amount__c,
                Payment_Allocation__c.Document_Amount__c,
                Payment_Allocation__c.Base_Amount__c,
                Payment_Allocation__c.Transaction_Currency__c,
                Payment_Allocation__c.Exchange_Rate__c,
                Payment_Allocation__c.Allocation_Date__c,
                Payment_Allocation__c.Effective_Date__c,
                Payment_Allocation__c.Status__c,
                Payment_Allocation__c.Reversal_Of__c,
                Payment_Allocation__c.Notes__c
            }
        );
    }

    private static void assertAllocationUpdateAccess() {
        SABAccessControlService.assertUpdateable(
            Payment_Allocation__c.SObjectType,
            new List<Schema.SObjectField>{
                Payment_Allocation__c.Status__c
            }
        );
    }

    private static String trimToLength(
        String value,
        Integer maxLength
    ) {
        if (String.isBlank(value)) {
            return null;
        }

        String trimmed =
            value.trim();

        if (
            maxLength != null
            && maxLength > 0
            && trimmed.length() > maxLength
        ) {
            return trimmed.substring(
                0,
                maxLength
            );
        }

        return trimmed;
    }
}
