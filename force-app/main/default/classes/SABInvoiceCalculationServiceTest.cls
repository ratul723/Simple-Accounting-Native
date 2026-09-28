@IsTest
private class SABInvoiceCalculationServiceTest {
    private static Invoice__c invoice() {
        return new Invoice__c(
            Document_Type__c = 'Invoice',
            Status__c = 'Draft',
            Transaction_Currency__c = 'USD',
            Functional_Currency__c = 'USD'
        );
    }

    @IsTest static void calculatesSubtotalTaxAndTotal() {
        Invoice_Line__c l1 = new Invoice_Line__c(
            Quantity__c = 2,
            Unit_Price__c = 100,
            Discount_Amount__c = 10
        );
        Invoice_Line__c l2 = new Invoice_Line__c(
            Quantity__c = 1,
            Unit_Price__c = 50,
            Discount_Amount__c = 0
        );

        Document_Tax_Line__c tax = new Document_Tax_Line__c(
            Tax_Amount__c = 14
        );

        SABInvoiceCalculationService.CalculationResult result =
            SABInvoiceCalculationService.calculate(
                invoice(),
                new List<Invoice_Line__c>{l1, l2},
                new List<Document_Tax_Line__c>{tax}
            );

        System.assertEquals(240, result.subtotal);
        System.assertEquals(14, result.taxTotal);
        System.assertEquals(254, result.total);
    }

    @IsTest static void negativeCalculatedLineIsRejected() {
        Invoice_Line__c line = new Invoice_Line__c(
            Quantity__c = 1,
            Unit_Price__c = 10,
            Discount_Amount__c = 11
        );

        try {
            SABInvoiceCalculationService.calculate(
                invoice(),
                new List<Invoice_Line__c>{line},
                new List<Document_Tax_Line__c>()
            );
            System.assert(false, 'Expected validation failure.');
        } catch (SABInvoiceValidationService.ValidationException e) {
            System.assert(e.getMessage().contains('net amount'));
        }
    }
}
