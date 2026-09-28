@IsTest
private class SABPaymentAllocationServiceTest {
    @IsTest
    static void nullPaymentIsRejected() {
        Test.startTest();
        try {
            SABPaymentAllocationService.allocatePayment(null, new List<SABPaymentAllocationService.PaymentAllocationRequest>());
            System.assert(false, 'Expected payment validation to fail.');
        } catch (SABPaymentAllocationService.PaymentAllocationException ex) {
            System.assertEquals('Payment is required.', ex.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void emptyAllocationListIsRejected() {
        Test.startTest();
        try {
            SABPaymentAllocationService.allocatePayment(
                UserInfo.getUserId(),
                new List<SABPaymentAllocationService.PaymentAllocationRequest>()
            );
            System.assert(false, 'Expected allocation validation to fail.');
        } catch (Exception ex) {
            System.assert(
                ex.getMessage().contains('At least one allocation')
                || ex.getMessage().contains('Payment is required')
            );
        }
        Test.stopTest();
    }
}
