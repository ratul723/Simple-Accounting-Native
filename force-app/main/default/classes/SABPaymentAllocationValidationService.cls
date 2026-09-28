public with sharing class SABPaymentAllocationValidationService {
    public class ValidationResult {
        @AuraEnabled public Boolean valid;
        @AuraEnabled public String message;

        public ValidationResult(Boolean validValue, String messageValue) {
            valid = validValue;
            message = messageValue;
        }
    }

    public static ValidationResult validateRequest(
        SABPaymentAllocationService.PaymentAllocationRequest request
    ) {
        if (request == null) {
            return new ValidationResult(false, 'Allocation request is required.');
        }
        if ((request.supplierBillId == null) == (request.invoiceId == null)) {
            return new ValidationResult(false, 'Exactly one target, Supplier Bill or Invoice, is required.');
        }
        if (request.allocatedAmount == null || request.allocatedAmount <= 0) {
            return new ValidationResult(false, 'Allocated amount must be greater than zero.');
        }
        if (request.exchangeRate != null && request.exchangeRate <= 0) {
            return new ValidationResult(false, 'Exchange rate must be greater than zero.');
        }
        return new ValidationResult(true, 'Allocation request is valid.');
    }

    public static void assertPaymentCanBeAllocated(Accounting_Payment__c payment) {
        if (payment == null) {
            throw new SABPaymentAllocationService.PaymentAllocationException('Payment is required.');
        }
        if (payment.Processing_State__c != 'Succeeded') {
            throw new SABPaymentAllocationService.PaymentAllocationException(
                'Only a succeeded payment can be allocated.'
            );
        }
    }
}
