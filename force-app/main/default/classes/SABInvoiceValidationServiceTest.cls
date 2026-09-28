@IsTest
private class SABInvoiceValidationServiceTest {
    private static Invoice__c baseInvoice() {
        return new Invoice__c(
            Company__c = '001000000000001AAA',
            Party_Profile__c = '001000000000002AAA',
            Document_Type__c = 'Invoice',
            Document_Date__c = Date.newInstance(2026, 9, 28),
            Accounting_Date__c = Date.newInstance(2026, 9, 28),
            Due_Date__c = Date.newInstance(2026, 10, 28),
            Transaction_Currency__c = 'USD',
            Functional_Currency__c = 'USD',
            Status__c = 'Draft'
        );
    }

    private static Invoice_Line__c line() {
        return new Invoice_Line__c(
            Quantity__c = 2,
            Unit_Price__c = 100,
            Discount_Amount__c = 10,
            Revenue_Account__c = '001000000000003AAA',
            Line_Number__c = 1
        );
    }

    @IsTest static void validDraftIsAccepted() {
        Test.startTest();
        SABInvoiceValidationService.validateForSubmit(baseInvoice(), new List<Invoice_Line__c>{line()});
        Test.stopTest();
    }

    @IsTest static void invoiceWithoutLinesIsRejected() {
        try {
            SABInvoiceValidationService.validateForSubmit(baseInvoice(), new List<Invoice_Line__c>());
            System.assert(false, 'Expected validation failure.');
        } catch (SABInvoiceValidationService.ValidationException e) {
            System.assert(e.getMessage().contains('at least one invoice line'));
        }
    }

    @IsTest static void missingRevenueAccountIsRejected() {
        Invoice_Line__c l = line();
        l.Revenue_Account__c = null;
        try {
            SABInvoiceValidationService.validateForSubmit(baseInvoice(), new List<Invoice_Line__c>{l});
            System.assert(false, 'Expected validation failure.');
        } catch (SABInvoiceValidationService.ValidationException e) {
            System.assert(e.getMessage().contains('Revenue account'));
        }
    }

    @IsTest static void creditNoteRequiresOriginal() {
        Invoice__c inv = baseInvoice();
        inv.Document_Type__c = 'Credit Note';
        try {
            SABInvoiceValidationService.validateForSubmit(inv, new List<Invoice_Line__c>{line()});
            System.assert(false, 'Expected validation failure.');
        } catch (SABInvoiceValidationService.ValidationException e) {
            System.assert(e.getMessage().contains('original invoice'));
        }
    }
}
