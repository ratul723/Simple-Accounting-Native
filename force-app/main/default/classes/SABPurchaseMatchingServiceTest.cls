@IsTest
private class SABPurchaseMatchingServiceTest {

    @TestSetup
    static void setupData() {
        SABPurchasingTestFixture.createFixture();
    }

    private static List<Object> spec(Id orderLineId, Id receiptLineId, Decimal quantity, Decimal price) {
        return new List<Object>{orderLineId, receiptLineId, quantity, price};
    }

    private static String errorsFor(Id billId) {
        return String.join(SABSupplierBillService.validateForSubmission(billId).errors, ' | ');
    }

    private static User ap() {
        return SABPurchasingTestFixture.user(SABPurchasingTestFixture.AP);
    }

    private static void expect(String message, String fragment) {
        System.assert(message != null && message.contains(fragment), 'Expected "' + fragment + '" but got: ' + message);
    }

    @IsTest
    static void threeWayMatchedBillIsSubmittedAndApproved() {
        Id orderId = SABPurchasingTestFixture.approvedOrder().Id;
        Map<Integer, Purchase_Order_Line__c> lines = SABPurchasingTestFixture.lines(orderId);
        Map<Integer, Id> receiptLines = SABPurchasingTestFixture.seedAcceptedReceipt(orderId, new Map<Integer, Decimal>{1 => 4, 2 => 5});
        SABSupplierBillService.TransitionResult approved;
        System.runAs(ap()) {
            SABTestGovernor.startTest();
            Id billId = SABPurchasingTestFixture.draftBill('Bill', 'P12-MATCH-OK', new List<List<Object>>{
                spec(lines.get(1).Id, receiptLines.get(1), 4, 100), spec(lines.get(2).Id, null, 5, 40)});
            SABSupplierBillService.submit(billId, 'P12-BILL-SUBMIT');
            approved = SABSupplierBillService.approve(billId, 'P12-BILL-APPROVE', 'Matched to PO and receipt');
            SABTestGovernor.stopTest();
        }
        System.assertEquals('Approved', approved.newStatus, 'A fully matched bill is approved.');
    }

    @IsTest
    static void rejectsPriceReceiptAndQuantityMismatches() {
        Id orderId = SABPurchasingTestFixture.approvedOrder().Id;
        Map<Integer, Purchase_Order_Line__c> lines = SABPurchasingTestFixture.lines(orderId);
        SABPurchasingTestFixture.seedAcceptedReceipt(orderId, new Map<Integer, Decimal>{1 => 4});
        List<String> errors = new List<String>();
        System.runAs(ap()) {
            SABTestGovernor.startTest();
            errors.add(errorsFor(SABPurchasingTestFixture.draftBill('Bill', 'P12-PRICE', new List<List<Object>>{spec(lines.get(1).Id, null, 4, 110)})));
            errors.add(errorsFor(SABPurchasingTestFixture.draftBill('Bill', 'P12-RECEIVED', new List<List<Object>>{spec(lines.get(1).Id, null, 5, 100)})));
            Id noQuantity = SABPurchasingTestFixture.draftBill('Bill', 'P12-NOQTY', new List<List<Object>>{spec(lines.get(1).Id, null, 1, 100)});
            update as system new Bill_Line__c(Id = [SELECT Id FROM Bill_Line__c WHERE Supplier_Bill__c = :noQuantity WITH SYSTEM_MODE].Id,
                Quantity__c = null);
            errors.add(errorsFor(noQuantity));
            SABTestGovernor.stopTest();
        }
        System.assertEquals(3, errors.size(), 'Three mismatched bills were validated.');
        expect(errors[0], 'beyond the price tolerance');
        expect(errors[1], 'exceeds the received quantity 4');
        expect(errors[2], 'needs a positive quantity');
    }

    @IsTest
    static void rejectsReceiptLinkProblemsClosedOrdersAndOverOrdering() {
        Id orderId = SABPurchasingTestFixture.approvedOrder().Id;
        Map<Integer, Purchase_Order_Line__c> lines = SABPurchasingTestFixture.lines(orderId);
        Map<Integer, Id> receiptLines = SABPurchasingTestFixture.seedAcceptedReceipt(orderId, new Map<Integer, Decimal>{1 => 10, 2 => 5});
        List<String> errors = new List<String>();
        System.runAs(ap()) {
            SABTestGovernor.startTest();
            errors.add(errorsFor(SABPurchasingTestFixture.draftBill('Bill', 'P12-NOPO', new List<List<Object>>{spec(null, receiptLines.get(1), 1, 100)})));
            errors.add(errorsFor(SABPurchasingTestFixture.draftBill('Bill', 'P12-WRONGGR', new List<List<Object>>{
                spec(lines.get(1).Id, receiptLines.get(2), 1, 100)})));
            SABPurchaseMatchingService.policyOverride = new List<SAB_Purchase_Match_Policy__mdt>{SABPurchasingTestFixture.policy(
                '{"Company_Key__c":"","Require_Goods_Receipt__c":false,"Is_Active__c":true}')};
            errors.add(errorsFor(SABPurchasingTestFixture.draftBill('Bill', 'P12-OVERORDER', new List<List<Object>>{
                spec(lines.get(1).Id, null, 11, 100)})));
            SABPurchasingGuard.beginWrite();
            try {
                update as system new Purchase_Order__c(Id = orderId, Status__c = 'Closed');
            } finally {
                SABPurchasingGuard.endWrite();
            }
            errors.add(errorsFor(SABPurchasingTestFixture.draftBill('Bill', 'P12-CLOSED', new List<List<Object>>{spec(lines.get(1).Id, null, 1, 100)})));
            SABTestGovernor.stopTest();
        }
        System.assertEquals(4, errors.size(), 'Four mismatched bills were validated.');
        expect(errors[0], 'requires the matching purchase order line');
        expect(errors[1], 'must be Accepted and belong to the same purchase order line');
        expect(errors[2], 'exceeds the ordered quantity 10');
        expect(errors[3], 'is Closed and cannot be billed');
    }

    @IsTest
    static void cumulativeBillingAndSupplierCredits() {
        Id orderId = SABPurchasingTestFixture.approvedOrder().Id;
        Id firstLine = SABPurchasingTestFixture.lines(orderId).get(1).Id;
        SABPurchasingTestFixture.seedAcceptedReceipt(orderId, new Map<Integer, Decimal>{1 => 4});
        String overBilled;
        String afterCredit;
        System.runAs(ap()) {
            SABTestGovernor.startTest();
            SABSupplierBillService.submit(SABPurchasingTestFixture.draftBill('Bill', 'P12-CUM-1',
                new List<List<Object>>{spec(firstLine, null, 4, 100)}), 'P12-CUM-SUBMIT-1');
            Id second = SABPurchasingTestFixture.draftBill('Bill', 'P12-CUM-2', new List<List<Object>>{spec(firstLine, null, 1, 100)});
            overBilled = errorsFor(second);
            SABSupplierBillService.submit(SABPurchasingTestFixture.draftBill('Supplier Credit', 'P12-CUM-CREDIT',
                new List<List<Object>>{spec(firstLine, null, 1, 100)}), 'P12-CUM-SUBMIT-CREDIT');
            afterCredit = errorsFor(second);
            SABTestGovernor.stopTest();
        }
        expect(overBilled, 'billed quantity 5 exceeds the received quantity 4');
        System.assertEquals('', afterCredit, 'A submitted supplier credit frees the quantity for the second bill.');
    }

    @IsTest
    static void selectsTheMatchPolicy() {
        System.runAs(ap()) {
            SABPurchaseMatchingService.MatchPolicy strict = SABPurchaseMatchingService.policyFor('P12');
            System.assertEquals(0, strict.priceTolerancePercent, 'No records: strict price matching.');
            System.assertEquals(true, strict.requireGoodsReceipt, 'No records: receipt required.');
            SABPurchaseMatchingService.policyOverride = new List<SAB_Purchase_Match_Policy__mdt>{
                SABPurchasingTestFixture.policy('{"Price_Tolerance_Percent__c":2,"Is_Active__c":true}'),
                SABPurchasingTestFixture.policy('{"Company_Key__c":"P12","Price_Tolerance_Percent__c":5,"Require_Goods_Receipt__c":false,"Is_Active__c":true}'),
                SABPurchasingTestFixture.policy('{"Company_Key__c":"P12","Price_Tolerance_Percent__c":9,"Is_Active__c":false}')};
            System.assertEquals(5, SABPurchaseMatchingService.policyFor('P12').priceTolerancePercent, 'Company policy wins.');
            System.assertEquals(false, SABPurchaseMatchingService.policyFor('P12').requireGoodsReceipt, 'Company policy can drop the receipt.');
            System.assertEquals(2, SABPurchaseMatchingService.policyFor('OTHER').priceTolerancePercent, 'Default applies elsewhere.');
            List<String> invalid = new List<String>();
            for (String body : new List<String>{'{"Company_Key__c":"X","Price_Tolerance_Percent__c":101,"Is_Active__c":true}',
                    '{"Company_Key__c":"X","Is_Active__c":true}'}) {
                SABPurchaseMatchingService.policyOverride.add(SABPurchasingTestFixture.policy(body));
                try {
                    SABPurchaseMatchingService.policyFor('X');
                } catch (SABPurchaseMatchingService.MatchingException ex) {
                    invalid.add(ex.getMessage());
                }
            }
            expect(invalid[0], 'between 0 and 100');
            expect(invalid[1], 'More than one active purchase match policy');
        }
    }
}
