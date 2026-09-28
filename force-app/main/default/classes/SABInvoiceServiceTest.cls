@IsTest
private class SABInvoiceServiceTest {
    @IsTest static void serviceClassesExist() {
        System.assertNotEquals(null, Type.forName('SABInvoiceService'));
        System.assertNotEquals(null, Type.forName('SABInvoiceValidationService'));
        System.assertNotEquals(null, Type.forName('SABInvoiceCalculationService'));
    }
}
