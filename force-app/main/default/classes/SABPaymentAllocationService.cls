public with sharing class SABPaymentAllocationService {
    public class PaymentAllocationException extends Exception {}

    public class PaymentAllocationRequest {
        @AuraEnabled public Id supplierBillId;
        @AuraEnabled public Id invoiceId;
        @AuraEnabled public Decimal allocatedAmount;
        @AuraEnabled public Date effectiveDate;
        @AuraEnabled public Date allocationDate;
        @AuraEnabled public String transactionCurrency;
        @AuraEnabled public Decimal exchangeRate;
        @AuraEnabled public String notes;
    }

    public class PaymentAllocationResult {
        @AuraEnabled public Id allocationId;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal allocatedAmount;
        @AuraEnabled public String message;
    }

    public static List<PaymentAllocationResult> allocatePayment(
        Id paymentId,
        List<PaymentAllocationRequest> requests
    ) {
        if (paymentId == null) {
            throw new PaymentAllocationException('Payment is required.');
        }
        if (requests == null || requests.isEmpty()) {
            throw new PaymentAllocationException('At least one allocation is required.');
        }

        Accounting_Payment__c payment = [
            SELECT Id, Company__c, Amount__c, Transaction_Currency__c,
                   Functional_Currency__c, Exchange_Rate__c, Effective_Date__c,
                   Processing_State__c
            FROM Accounting_Payment__c
            WHERE Id = :paymentId
            FOR UPDATE
        ];

        if (payment.Processing_State__c != 'Succeeded') {
            throw new PaymentAllocationException('Only a succeeded payment can be allocated.');
        }

        Set<Id> billIds = new Set<Id>();
        Set<Id> invoiceIds = new Set<Id>();
        Decimal requestedTotal = 0;

        for (PaymentAllocationRequest request : requests) {
            validateRequest(request);
            requestedTotal += request.allocatedAmount;
            if (request.supplierBillId != null) billIds.add(request.supplierBillId);
            if (request.invoiceId != null) invoiceIds.add(request.invoiceId);
        }

        List<Payment_Allocation__c> existing = [
            SELECT Id, Supplier_Bill__c, Invoice__c, Allocated_Amount__c, Status__c
            FROM Payment_Allocation__c
            WHERE Payment__c = :paymentId
              AND Status__c = 'Allocated'
            FOR UPDATE
        ];

        Decimal alreadyAllocated = 0;
        Set<String> existingTargets = new Set<String>();
        for (Payment_Allocation__c row : existing) {
            alreadyAllocated += row.Allocated_Amount__c == null ? 0 : row.Allocated_Amount__c;
            if (row.Supplier_Bill__c != null) existingTargets.add('B:' + row.Supplier_Bill__c);
            if (row.Invoice__c != null) existingTargets.add('I:' + row.Invoice__c);
        }

        if (alreadyAllocated + requestedTotal > payment.Amount__c) {
            throw new PaymentAllocationException('Allocation exceeds the remaining payment amount.');
        }

        if (!billIds.isEmpty()) {
            Map<Id, Supplier_Bill__c> bills = new Map<Id, Supplier_Bill__c>([
                SELECT Id, Company__c, Status__c, Total__c,
                       Functional_Currency__c, Transaction_Currency__c,
                       Exchange_Rate__c, Accounting_Event__c
                FROM Supplier_Bill__c
                WHERE Id IN :billIds
                FOR UPDATE
            ]);

            for (Id billId : billIds) {
                Supplier_Bill__c bill = bills.get(billId);
                if (bill == null) throw new PaymentAllocationException('Supplier Bill was not found.');
                if (bill.Company__c != payment.Company__c) {
                    throw new PaymentAllocationException('Cross-company allocation is not allowed.');
                }
                if (bill.Status__c != 'Posted') {
                    throw new PaymentAllocationException('Supplier Bill must be Posted before allocation.');
                }
                if (existingTargets.contains('B:' + bill.Id)) {
                    throw new PaymentAllocationException('Duplicate allocation for the Supplier Bill is not allowed.');
                }
            }
        }

        if (!invoiceIds.isEmpty()) {
            Map<Id, Invoice__c> invoices = new Map<Id, Invoice__c>([
                SELECT Id, Company__c, Status__c, Total__c,
                       Functional_Currency__c, Transaction_Currency__c,
                       Exchange_Rate__c, Accounting_Event__c
                FROM Invoice__c
                WHERE Id IN :invoiceIds
                FOR UPDATE
            ]);

            for (Id invoiceId : invoiceIds) {
                Invoice__c invoice = invoices.get(invoiceId);
                if (invoice == null) throw new PaymentAllocationException('Invoice was not found.');
                if (invoice.Company__c != payment.Company__c) {
                    throw new PaymentAllocationException('Cross-company allocation is not allowed.');
                }
                if (invoice.Status__c != 'Posted') {
                    throw new PaymentAllocationException('Invoice must be Posted before allocation.');
                }
                if (existingTargets.contains('I:' + invoice.Id)) {
                    throw new PaymentAllocationException('Duplicate allocation for the Invoice is not allowed.');
                }
            }
        }

        List<Payment_Allocation__c> rows = new List<Payment_Allocation__c>();

        for (PaymentAllocationRequest request : requests) {
            rows.add(new Payment_Allocation__c(
                Payment__c = payment.Id,
                Company__c = payment.Company__c,
                Supplier_Bill__c = request.supplierBillId,
                Invoice__c = request.invoiceId,
                Allocated_Amount__c = request.allocatedAmount,
                Transaction_Currency__c = request.transactionCurrency != null
                    ? request.transactionCurrency : payment.Transaction_Currency__c,
                Exchange_Rate__c = request.exchangeRate != null
                    ? request.exchangeRate : payment.Exchange_Rate__c,
                Allocation_Date__c = request.allocationDate != null
                    ? request.allocationDate : Date.today(),
                Effective_Date__c = request.effectiveDate != null
                    ? request.effectiveDate : payment.Effective_Date__c,
                Status__c = 'Allocated',
                Notes__c = request.notes
            ));
        }

        insert rows;

        List<PaymentAllocationResult> results = new List<PaymentAllocationResult>();
        for (Payment_Allocation__c row : rows) {
            PaymentAllocationResult result = new PaymentAllocationResult();
            result.allocationId = row.Id;
            result.status = row.Status__c;
            result.allocatedAmount = row.Allocated_Amount__c;
            result.message = 'Payment allocation created.';
            results.add(result);
        }
        return results;
    }

    public static Payment_Allocation__c reverseAllocation(Id allocationId, String reason) {
        if (allocationId == null) {
            throw new PaymentAllocationException('Allocation is required.');
        }

        Payment_Allocation__c original = [
            SELECT Id, Payment__c, Company__c, Supplier_Bill__c, Invoice__c,
                   Allocated_Amount__c, Transaction_Currency__c, Exchange_Rate__c,
                   Allocation_Date__c, Effective_Date__c, Status__c
            FROM Payment_Allocation__c
            WHERE Id = :allocationId
            FOR UPDATE
        ];

        if (original.Status__c != 'Allocated') {
            throw new PaymentAllocationException('Only an allocated record can be reversed.');
        }

        original.Status__c = 'Reversed';
        update original;

        Payment_Allocation__c reversal = original.clone(false, true, false, false);
        reversal.Status__c = 'Reversed';
        reversal.Reversal_Of__c = original.Id;
        reversal.Allocated_Amount__c = -original.Allocated_Amount__c;
        reversal.Notes__c = reason;
        insert reversal;

        return reversal;
    }

    private static void validateRequest(PaymentAllocationRequest request) {
        if (request == null) {
            throw new PaymentAllocationException('Allocation request is required.');
        }
        if ((request.supplierBillId == null) == (request.invoiceId == null)) {
            throw new PaymentAllocationException('Exactly one target, Supplier Bill or Invoice, is required.');
        }
        if (request.allocatedAmount == null || request.allocatedAmount <= 0) {
            throw new PaymentAllocationException('Allocated amount must be greater than zero.');
        }
        if (request.exchangeRate != null && request.exchangeRate <= 0) {
            throw new PaymentAllocationException('Exchange rate must be greater than zero.');
        }
    }
}
