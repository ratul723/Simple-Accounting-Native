@IsTest
private class SABGoodsReceiptServiceTest {

    @TestSetup
    static void setupData() {
        SABPurchasingTestFixture.createFixture();
    }

    private static SABGoodsReceiptService.ReceiptRequest receipt(Id orderId, Map<Id, Decimal> quantities) {
        SABGoodsReceiptService.ReceiptRequest r = new SABGoodsReceiptService.ReceiptRequest();
        r.purchaseOrderId = orderId;
        r.receiptDate = SABPurchasingTestFixture.ORDER_DATE.addDays(3);
        r.lines = new List<SABGoodsReceiptService.ReceiptLineRequest>();
        for (Id lineId : quantities.keySet()) {
            SABGoodsReceiptService.ReceiptLineRequest l = new SABGoodsReceiptService.ReceiptLineRequest();
            l.purchaseOrderLineId = lineId;
            l.acceptedQuantity = quantities.get(lineId);
            l.serviceAccepted = false;
            l.comment = 'Checked';
            r.lines.add(l);
        }
        return r;
    }

    private static void expect(String message, String fragment) {
        System.assert(message != null && message.contains(fragment), 'Expected "' + fragment + '" but got: ' + message);
    }

    @IsTest
    static void partialThenFullReceiptMovesOrderStatus() {
        Id orderId = SABPurchasingTestFixture.approvedOrder().Id;
        Map<Integer, Purchase_Order_Line__c> lines = SABPurchasingTestFixture.lines(orderId);
        SABGoodsReceiptService.ActionResult first;
        SABGoodsReceiptService.ActionResult replay;
        SABGoodsReceiptService.ActionResult second;
        SABTestGovernor.startTest();
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER)) {
            Id partial = SABGoodsReceiptService.createReceipt(receipt(orderId, new Map<Id, Decimal>{lines.get(1).Id => 4}));
            first = SABGoodsReceiptService.acceptReceipt(partial, 'P12-GR-1');
            replay = SABGoodsReceiptService.acceptReceipt(partial, 'P12-GR-1');
            Id rest = SABGoodsReceiptService.createReceipt(receipt(orderId, new Map<Id, Decimal>{lines.get(1).Id => 6, lines.get(2).Id => 5}));
            second = SABGoodsReceiptService.acceptReceipt(rest, 'P12-GR-2');
        }
        SABTestGovernor.stopTest();
        System.assertEquals('Accepted', first.status, 'Receipt accepted.');
        System.assertEquals('Part Received', first.purchaseOrderStatus, 'Order is part received.');
        System.assertEquals(true, replay.replay, 'Same key replays.');
        System.assertEquals('Received', second.purchaseOrderStatus, 'Order is fully received.');
        Map<Integer, Purchase_Order_Line__c> after = SABPurchasingTestFixture.lines(orderId);
        System.assertEquals(10, after.get(1).Received_Quantity__c, 'Line 1 fully received.');
        System.assertEquals(0, after.get(1).Remaining_Quantity__c, 'Nothing remaining on line 1.');
        System.assertEquals(5, after.get(2).Received_Quantity__c, 'Service line accepted.');
        Goods_Receipt__c accepted = [SELECT Accepted_By__c, Accepted_At__c FROM Goods_Receipt__c WHERE Id = :first.goodsReceiptId WITH SYSTEM_MODE];
        System.assertEquals(SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER).Id, accepted.Accepted_By__c, 'Acceptor recorded.');
    }

    @IsTest
    static void blocksOverReceiptUnlessPolicyAllowsIt() {
        Id orderId = SABPurchasingTestFixture.approvedOrder().Id;
        Id firstLine = SABPurchasingTestFixture.lines(orderId).get(1).Id;
        String overReceipt;
        SABGoodsReceiptService.ActionResult tolerated;
        SABTestGovernor.startTest();
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER)) {
            Id tooMany = SABGoodsReceiptService.createReceipt(receipt(orderId, new Map<Id, Decimal>{firstLine => 11}));
            try {
                SABGoodsReceiptService.acceptReceipt(tooMany, 'P12-GR-OVER');
            } catch (SABGoodsReceiptService.GoodsReceiptException ex) {
                overReceipt = ex.getMessage();
            }
            SABPurchaseMatchingService.policyOverride = new List<SAB_Purchase_Match_Policy__mdt>{SABPurchasingTestFixture.policy(
                '{"Company_Key__c":"P12","Quantity_Tolerance_Percent__c":10,"Price_Tolerance_Percent__c":0,"Require_Goods_Receipt__c":true,'
                + '"Is_Active__c":true}')};
            tolerated = SABGoodsReceiptService.acceptReceipt(tooMany, 'P12-GR-TOLERATED');
        }
        SABTestGovernor.stopTest();
        expect(overReceipt, 'beyond the quantity tolerance');
        System.assertEquals('Accepted', tolerated.status, 'Over-receipt within the 10% policy tolerance is accepted.');
        System.assertEquals('Part Received', tolerated.purchaseOrderStatus, 'Line 2 is still open.');
        System.assertEquals(11, SABPurchasingTestFixture.lines(orderId).get(1).Received_Quantity__c, 'Line 1 received 11 of 10.');
    }

    @IsTest
    static void cancelReversesAcceptedReceiptUntilBilled() {
        Id orderId = SABPurchasingTestFixture.approvedOrder().Id;
        Map<Integer, Purchase_Order_Line__c> lines = SABPurchasingTestFixture.lines(orderId);
        SABGoodsReceiptService.ActionResult cancelled;
        String billed;
        String invalid;
        SABTestGovernor.startTest();
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER)) {
            Id receiptId = SABGoodsReceiptService.createReceipt(receipt(orderId, new Map<Id, Decimal>{lines.get(1).Id => 3}));
            SABGoodsReceiptService.acceptReceipt(receiptId, 'P12-GR-C1');
            cancelled = SABGoodsReceiptService.cancelReceipt(receiptId, 'Damaged on arrival', 'P12-GR-C2');
            Id billedReceipt = SABGoodsReceiptService.createReceipt(receipt(orderId, new Map<Id, Decimal>{lines.get(1).Id => 2}));
            SABGoodsReceiptService.acceptReceipt(billedReceipt, 'P12-GR-C3');
            Id receiptLine = [SELECT Id FROM Goods_Receipt_Line__c WHERE Goods_Receipt__c = :billedReceipt WITH SYSTEM_MODE].Id;
            SABPurchasingTestFixture.draftBill('Bill', 'P12-BILL-C', new List<List<Object>>{
                new List<Object>{lines.get(1).Id, receiptLine, (Decimal) 2, (Decimal) 100}});
            try {
                SABGoodsReceiptService.cancelReceipt(billedReceipt, 'Wrong', 'P12-GR-C4');
            } catch (SABGoodsReceiptService.GoodsReceiptException ex) {
                billed = ex.getMessage();
            }
            try {
                SABGoodsReceiptService.createReceipt(receipt(orderId, new Map<Id, Decimal>{SABPurchasingTestFixture.expenseAccountId() => 1}));
            } catch (SABGoodsReceiptService.GoodsReceiptException ex) {
                invalid = ex.getMessage();
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals('Cancelled', cancelled.status, 'Accepted receipt cancelled.');
        expect(billed, 'matched to a supplier bill');
        expect(invalid, 'reference a line of the purchase order');
        Map<Integer, Purchase_Order_Line__c> after = SABPurchasingTestFixture.lines(orderId);
        System.assertEquals(2, after.get(1).Received_Quantity__c, 'Cancelled receipt was reversed; the billed one stays.');
        System.assertEquals(8, after.get(1).Remaining_Quantity__c, 'Remaining recalculated.');
    }

    @IsTest
    static void guardsBlockDirectReceiptChanges() {
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER)) {
            Id orderId = SABPurchasingTestFixture.approvedOrder().Id;
            Map<Integer, Id> receiptLines = SABPurchasingTestFixture.seedAcceptedReceipt(orderId, new Map<Integer, Decimal>{1 => 1});
            Goods_Receipt_Line__c acceptedLine = [SELECT Id, Goods_Receipt__c FROM Goods_Receipt_Line__c WHERE Id = :receiptLines.get(1)
                WITH SYSTEM_MODE];
            SABTestGovernor.startTest();
            Goods_Receipt__c draft = new Goods_Receipt__c(Company__c = SABPurchasingTestFixture.companyId(), Purchase_Order__c = orderId,
                Receipt_Date__c = SABPurchasingTestFixture.ORDER_DATE.addDays(2));
            System.assert(Database.insert(draft, false).isSuccess(), 'Draft receipts may be inserted directly.');
            List<Database.SaveResult> blocked = new List<Database.SaveResult>{
                Database.update(new Goods_Receipt__c(Id = draft.Id, Status__c = 'Accepted'), false),
                Database.update(new Goods_Receipt__c(Id = acceptedLine.Goods_Receipt__c, Receipt_Date__c = SABPurchasingTestFixture.ORDER_DATE), false),
                Database.update(new Goods_Receipt_Line__c(Id = acceptedLine.Id, Accepted_Quantity__c = 9), false),
                Database.insert(new Goods_Receipt__c(Company__c = SABPurchasingTestFixture.companyId(), Purchase_Order__c = orderId,
                    Receipt_Date__c = SABPurchasingTestFixture.ORDER_DATE, Status__c = 'Accepted'), false)};
            Database.DeleteResult acceptedDelete = Database.delete(acceptedLine.Goods_Receipt__c, false);
            SABTestGovernor.stopTest();
            for (Integer i = 0; i < blocked.size(); i++) {
                System.assertEquals(false, blocked[i].isSuccess(), 'Direct receipt change ' + i + ' must be blocked.');
            }
            System.assertEquals(false, acceptedDelete.isSuccess(), 'Accepted receipts cannot be deleted.');
        }
    }
}
