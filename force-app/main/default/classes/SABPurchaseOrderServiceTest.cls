@IsTest
private class SABPurchaseOrderServiceTest {

    @TestSetup
    static void setupData() {
        SABPurchasingTestFixture.createFixture();
    }

    private static SABPurchaseOrderService.PurchaseOrderRequest request(Id purchaseOrderId) {
        SABPurchaseOrderService.PurchaseOrderRequest r = new SABPurchaseOrderService.PurchaseOrderRequest();
        r.purchaseOrderId = purchaseOrderId;
        r.companyId = SABPurchasingTestFixture.companyId();
        r.supplierProfileId = SABPurchasingTestFixture.supplierId();
        r.orderDate = SABPurchasingTestFixture.ORDER_DATE;
        r.currencyCode = 'bdt';
        r.lines = new List<SABPurchaseOrderService.LineRequest>{line(1, 'Paper', 20, 2.5), line(2, 'Toner', 3, 45)};
        return r;
    }

    private static SABPurchaseOrderService.LineRequest line(Decimal n, String description, Decimal quantity, Decimal price) {
        SABPurchaseOrderService.LineRequest l = new SABPurchaseOrderService.LineRequest();
        l.lineNumber = n;
        l.description = description;
        l.quantity = quantity;
        l.unitPrice = price;
        return l;
    }

    private static String failure(SABPurchaseOrderService.PurchaseOrderRequest r) {
        try {
            SABPurchaseOrderService.saveDraft(r);
        } catch (Exception ex) {
            return ex.getMessage();
        }
        return null;
    }

    private static void expect(String message, String fragment) {
        System.assert(message != null && message.contains(fragment), 'Expected "' + fragment + '" but got: ' + message);
    }

    @IsTest
    static void savesDraftAndRunsTheApprovalLifecycle() {
        Id orderId;
        SABPurchaseOrderService.ActionResult submitted;
        SABPurchaseOrderService.ActionResult replay;
        SABPurchaseOrderService.ActionResult approved;
        SABTestGovernor.startTest();
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER)) {
            orderId = SABPurchaseOrderService.saveDraft(request(null));
            SABPurchaseOrderService.PurchaseOrderRequest edit = request(orderId);
            edit.lines.add(line(3, 'Staples', 10, 1));
            SABPurchaseOrderService.saveDraft(edit);
            submitted = SABPurchaseOrderService.submit(orderId, 'P12-SUBMIT');
            replay = SABPurchaseOrderService.submit(orderId, 'P12-SUBMIT');
        }
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.APPROVER)) {
            approved = SABPurchaseOrderService.approve(orderId, 'P12-APPROVE');
        }
        SABTestGovernor.stopTest();
        System.assertEquals('Submitted', submitted.status, 'Draft is submitted.');
        System.assertEquals(195, submitted.total, 'Total = 20 x 2.5 + 3 x 45 + 10 x 1.');
        System.assertEquals(true, replay.replay, 'Same key replays.');
        System.assertEquals('Approved', approved.status, 'Approver approves.');
        Purchase_Order__c order = [SELECT Status__c, Currency__c, Submitted_By__c, Approved_By__c, Approved_At__c FROM Purchase_Order__c
            WHERE Id = :orderId WITH SYSTEM_MODE];
        System.assertEquals('BDT', order.Currency__c, 'Currency is normalised.');
        System.assertEquals(SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER).Id, order.Submitted_By__c, 'Submitter recorded.');
        System.assertEquals(SABPurchasingTestFixture.user(SABPurchasingTestFixture.APPROVER).Id, order.Approved_By__c, 'Approver recorded.');
        Map<Integer, Purchase_Order_Line__c> lines = SABPurchasingTestFixture.lines(orderId);
        System.assertEquals(3, lines.size(), 'Draft edit replaced the lines.');
        System.assertEquals(20, lines.get(1).Remaining_Quantity__c, 'Remaining starts at ordered quantity.');
        System.assertEquals(2, [SELECT COUNT() FROM Business_Action__c WHERE Source_Record_Id__c = :String.valueOf(orderId) WITH SYSTEM_MODE],
            'Submit and approve are audited once each.');
    }

    @IsTest
    static void enforcesSeparationOfDutiesAndPermissions() {
        Id orderId;
        List<String> refused = new List<String>();
        SABTestGovernor.startTest();
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER)) {
            orderId = SABPurchaseOrderService.saveDraft(request(null));
            SABPurchaseOrderService.submit(orderId, 'P12-SOD-SUBMIT');
            try {
                SABPurchaseOrderService.approve(orderId, 'P12-SOD-SELF');
            } catch (SABPermissionService.PermissionDeniedException ex) {
                refused.add('buyer-cannot-approve');
            }
        }
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.APPROVER)) {
            try {
                SABPurchaseOrderService.saveDraft(request(null));
            } catch (SABPermissionService.PermissionDeniedException ex) {
                refused.add('approver-cannot-create');
            }
            try {
                SABPurchaseOrderService.submit(orderId, 'P12-SOD-MISUSE');
            } catch (SABPermissionService.PermissionDeniedException ex) {
                refused.add('approver-cannot-submit');
            }
            SABPurchaseOrderService.returnToDraft(orderId, 'Wrong supplier quote', 'P12-SOD-RETURN');
        }
        // An approver who also created the order cannot approve it.
        Purchase_Order__c own;
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.APPROVER)) {
            own = new Purchase_Order__c(Company__c = SABPurchasingTestFixture.companyId(), Supplier_Profile__c = SABPurchasingTestFixture.supplierId(),
                Order_Date__c = SABPurchasingTestFixture.ORDER_DATE, Currency__c = 'BDT', Status__c = 'Draft');
            SABPurchasingGuard.beginWrite();
            try {
                insert as system own;
                insert as system new Purchase_Order_Line__c(Purchase_Order__c = own.Id, Line_Number__c = 1, Description__c = 'Chairs',
                    Quantity__c = 2, Unit_Price__c = 50);
                update as system new Purchase_Order__c(Id = own.Id, Status__c = 'Submitted', Submitted_By__c = SABPurchasingTestFixture.user(
                    SABPurchasingTestFixture.BUYER).Id);
            } finally {
                SABPurchasingGuard.endWrite();
            }
            try {
                SABPurchaseOrderService.approve(own.Id, 'P12-SOD-OWN');
            } catch (SABPurchaseOrderService.PurchaseOrderException ex) {
                expect(ex.getMessage(), 'cannot approve it');
                refused.add('creator-cannot-approve');
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals(new List<String>{'buyer-cannot-approve', 'approver-cannot-create', 'approver-cannot-submit',
            'creator-cannot-approve'}, refused, 'Permissions and separation of duties are enforced.');
        System.assertEquals('Draft', [SELECT Status__c FROM Purchase_Order__c WHERE Id = :orderId WITH SYSTEM_MODE].Status__c,
            'Returned order is Draft again.');
    }

    @IsTest
    static void validatesDraftContent() {
        List<String> messages = new List<String>();
        SABTestGovernor.startTest();
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER)) {
            SABPurchaseOrderService.PurchaseOrderRequest noLines = request(null);
            noLines.lines = new List<SABPurchaseOrderService.LineRequest>();
            messages.add(failure(noLines));
            SABPurchaseOrderService.PurchaseOrderRequest duplicate = request(null);
            duplicate.lines[1].lineNumber = 1;
            messages.add(failure(duplicate));
            SABPurchaseOrderService.PurchaseOrderRequest zeroQuantity = request(null);
            zeroQuantity.lines[0].quantity = 0;
            messages.add(failure(zeroQuantity));
            SABPurchaseOrderService.PurchaseOrderRequest negativePrice = request(null);
            negativePrice.lines[0].unitPrice = -1;
            messages.add(failure(negativePrice));
            SABPurchaseOrderService.PurchaseOrderRequest noDescription = request(null);
            noDescription.lines[0].description = ' ';
            messages.add(failure(noDescription));
            SABPurchaseOrderService.PurchaseOrderRequest missingHeader = request(null);
            missingHeader.supplierProfileId = null;
            messages.add(failure(missingHeader));
            SABPurchaseOrderService.PurchaseOrderRequest wrongSupplier = request(null);
            wrongSupplier.supplierProfileId = SABPurchasingTestFixture.expenseAccountId();
            messages.add(failure(wrongSupplier));
            messages.add(failure(request(SABPurchasingTestFixture.approvedOrder().Id)));
        }
        SABTestGovernor.stopTest();
        List<String> fragments = new List<String>{'between 1 and', 'positive and unique', 'greater than zero', 'cannot be negative',
            'needs a description', 'are required', 'active supplier profile', 'Only Draft'};
        System.assertEquals(fragments.size(), messages.size(), 'Every invalid draft was refused.');
        for (Integer i = 0; i < fragments.size(); i++) {
            expect(messages[i], fragments[i]);
        }
    }

    @IsTest
    static void cancelAndCloseFollowReceiptRules() {
        Purchase_Order__c approved = SABPurchasingTestFixture.approvedOrder();
        String cancelReceived;
        SABPurchaseOrderService.ActionResult closed;
        SABPurchaseOrderService.ActionResult cancelled;
        Id draftId;
        SABPurchasingTestFixture.seedAcceptedReceipt(approved.Id, new Map<Integer, Decimal>{1 => 4});
        SABTestGovernor.startTest();
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER)) {
            try {
                SABPurchaseOrderService.cancel(approved.Id, 'No longer needed', 'P12-CANCEL-RECEIVED');
            } catch (SABPurchaseOrderService.PurchaseOrderException ex) {
                cancelReceived = ex.getMessage();
            }
            closed = SABPurchaseOrderService.close(approved.Id, 'Supplier cannot deliver the rest', 'P12-CLOSE');
            draftId = SABPurchaseOrderService.saveDraft(request(null));
            cancelled = SABPurchaseOrderService.cancel(draftId, 'Duplicate request', 'P12-CANCEL-DRAFT');
        }
        SABTestGovernor.stopTest();
        expect(cancelReceived, 'cannot be cancelled');
        System.assertEquals('Closed', closed.status, 'Partly received order is closed.');
        System.assertEquals('Cancelled', cancelled.status, 'Unreceived draft is cancelled.');
        String misuse;
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER)) {
            try {
                SABPurchaseOrderService.submit(draftId, 'P12-CLOSE');
            } catch (SABPurchaseOrderService.PurchaseOrderException ex) {
                misuse = ex.getMessage();
            }
        }
        expect(misuse, 'different purchasing action');
    }

    @IsTest
    static void guardsBlockDirectLifecycleAndQuantityEdits() {
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER)) {
            Purchase_Order__c approved = SABPurchasingTestFixture.approvedOrder();
            Purchase_Order_Line__c firstLine = SABPurchasingTestFixture.lines(approved.Id).get(1);
            Purchase_Order__c draft = new Purchase_Order__c(Company__c = SABPurchasingTestFixture.companyId(),
                Supplier_Profile__c = SABPurchasingTestFixture.supplierId(), Order_Date__c = SABPurchasingTestFixture.ORDER_DATE, Currency__c = 'BDT');
            SABTestGovernor.startTest();
            System.assert(Database.insert(draft, false).isSuccess(), 'A Draft order may be inserted directly.');
            Purchase_Order_Line__c draftLine = new Purchase_Order_Line__c(Purchase_Order__c = draft.Id, Line_Number__c = 1, Description__c = 'Pens',
                Quantity__c = 5, Unit_Price__c = 1);
            System.assert(Database.insert(draftLine, false).isSuccess(), 'Draft lines may be added directly.');
            List<Database.SaveResult> blocked = new List<Database.SaveResult>{
                Database.insert(new Purchase_Order__c(Company__c = SABPurchasingTestFixture.companyId(), Supplier_Profile__c = SABPurchasingTestFixture.supplierId(),
                    Order_Date__c = SABPurchasingTestFixture.ORDER_DATE, Currency__c = 'BDT', Status__c = 'Approved'), false),
                Database.update(new Purchase_Order__c(Id = draft.Id, Status__c = 'Approved'), false),
                Database.update(new Purchase_Order__c(Id = approved.Id, Currency__c = 'USD'), false),
                Database.update(new Purchase_Order_Line__c(Id = firstLine.Id, Quantity__c = 99), false),
                Database.update(new Purchase_Order_Line__c(Id = draftLine.Id, Received_Quantity__c = 5), false)};
            Database.DeleteResult approvedDelete = Database.delete(approved.Id, false);
            SABTestGovernor.stopTest();
            for (Integer i = 0; i < blocked.size(); i++) {
                System.assertEquals(false, blocked[i].isSuccess(), 'Direct change ' + i + ' must be blocked.');
            }
            System.assertEquals(false, approvedDelete.isSuccess(), 'Approved orders cannot be deleted.');
            System.assert(Database.delete(draft.Id, false).isSuccess(), 'Draft orders can be deleted.');
        }
    }
}
