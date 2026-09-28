@IsTest
private class SABPaymentAllocValidationTest {
    @IsTest
    static void missingTargetIsRejected() {
        SABPaymentAllocationService.PaymentAllocationRequest request =
            new SABPaymentAllocationService.PaymentAllocationRequest();
        request.allocatedAmount = 100;

        SABPaymentAllocationValidationService.ValidationResult result =
            SABPaymentAllocationValidationService.validateRequest(request);

        System.assertEquals(false, result.valid);
        System.assertEquals(
            'Exactly one target, Supplier Bill or Invoice, is required.',
            result.message
        );
    }

    @IsTest
    static void zeroAmountIsRejected() {
        SABPaymentAllocationService.PaymentAllocationRequest request =
            new SABPaymentAllocationService.PaymentAllocationRequest();
        request.supplierBillId = UserInfo.getUserId();
        request.allocatedAmount = 0;

        SABPaymentAllocationValidationService.ValidationResult result =
            SABPaymentAllocationValidationService.validateRequest(request);

        System.assertEquals(false, result.valid);
        System.assertEquals('Allocated amount must be greater than zero.', result.message);
    }

    @IsTest
    static void bothTargetsAreRejected() {
        SABPaymentAllocationService.PaymentAllocationRequest request =
            new SABPaymentAllocationService.PaymentAllocationRequest();
        request.supplierBillId = UserInfo.getUserId();
        request.invoiceId = UserInfo.getUserId();
        request.allocatedAmount = 100;

        SABPaymentAllocationValidationService.ValidationResult result =
            SABPaymentAllocationValidationService.validateRequest(request);

        System.assertEquals(false, result.valid);
        System.assertEquals(
            'Exactly one target, Supplier Bill or Invoice, is required.',
            result.message
        );
    }

    @IsTest
    static void validRequestIsAccepted() {
        SABPaymentAllocationService.PaymentAllocationRequest request =
            new SABPaymentAllocationService.PaymentAllocationRequest();
        request.supplierBillId = UserInfo.getUserId();
        request.allocatedAmount = 100;
        request.exchangeRate = 1;

        SABPaymentAllocationValidationService.ValidationResult result =
            SABPaymentAllocationValidationService.validateRequest(request);

        System.assertEquals(true, result.valid);
        System.assertEquals('Allocation request is valid.', result.message);
    }
}
