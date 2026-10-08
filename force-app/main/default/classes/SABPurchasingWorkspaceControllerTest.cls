@IsTest
private class SABPurchasingWorkspaceControllerTest {

    @TestSetup
    static void setupData() {
        SABPurchasingTestFixture.createFixture();
        // The buyer opens the workspace; the approver deliberately does not have the view permission.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert as system new PermissionSetAssignment(AssigneeId = SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER).Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'SAB_Purchasing_Workspace_User' WITH SYSTEM_MODE].Id);
        }
        Purchase_Order__c order = SABPurchasingTestFixture.approvedOrder();
        Map<Integer, Id> receiptLines = SABPurchasingTestFixture.seedAcceptedReceipt(order.Id, new Map<Integer, Decimal>{1 => 4});
        Map<Integer, Purchase_Order_Line__c> lines = SABPurchasingTestFixture.lines(order.Id);
        SABPurchasingTestFixture.draftBill('Bill', 'G12B-DRAFT', new List<List<Object>>{
            new List<Object>{lines.get(1).Id, receiptLines.get(1), (Decimal) 4, (Decimal) 100}});
    }

    @IsTest
    static void workspaceListsOrdersCommitmentAndOptions() {
        SABPurchasingWorkspaceController.WorkspaceDTO ws;
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER)) {
            SABTestGovernor.startTest();
            ws = SABPurchasingWorkspaceController.getWorkspace(SABPurchasingTestFixture.companyId());
            SABTestGovernor.stopTest();
        }
        System.assertEquals(1, ws.orders.size(), 'One purchase order.');
        System.assertEquals('Part Received', ws.orders[0].status, 'The seeded receipt part-received the order.');
        System.assertEquals(1200, ws.openCommitment, 'Part Received orders count as open commitment.');
        System.assertEquals(1, ws.suppliers.size(), 'Active suppliers are offered.');
        Map<String, Integer> counts = new Map<String, Integer>();
        for (SABPurchasingWorkspaceController.StateCount c : ws.stateCounts) {
            counts.put(c.state, c.count);
        }
        System.assertEquals(1, counts.get('Part Received'), 'Counts by status.');
        System.assertEquals(0, counts.get('Draft'), 'Every status is reported.');
        System.assertEquals(true, ws.capabilities.manage, 'Buyer manages orders.');
        System.assertEquals(false, ws.capabilities.approve, 'Buyer cannot approve.');
        System.assertEquals(true, ws.capabilities.receive, 'Buyer receives goods.');
    }

    @IsTest
    static void detailShowsReceiptsBillsAndMatchStatus() {
        SABPurchasingWorkspaceController.OrderDetailDTO detail;
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER)) {
            SABTestGovernor.startTest();
            detail = SABPurchasingWorkspaceController.getPurchaseOrderDetail(SABPurchasingTestFixture.approvedOrder().Id);
            SABTestGovernor.stopTest();
        }
        System.assertEquals(2, detail.lines.size(), 'Two order lines.');
        System.assertEquals(4, detail.lines[0].receivedQuantity, 'Line 1 received 4.');
        System.assertEquals(6, detail.lines[0].remainingQuantity, 'Line 1 has 6 outstanding.');
        System.assertEquals(0, detail.lines[0].billedQuantity, 'A Draft bill is not billed yet.');
        System.assertEquals('Awaiting bill', detail.lines[0].matchStatus, 'Received but not billed.');
        System.assertEquals('Not received', detail.lines[1].matchStatus, 'Line 2 is untouched.');
        System.assertEquals(1000, detail.lines[0].lineAmount, 'Line amount.');
        System.assertEquals(1, detail.receipts.size(), 'One receipt.');
        System.assertEquals(4, detail.receipts[0].totalQuantity, 'Receipt quantity from its lines.');
        System.assertEquals(1, detail.bills.size(), 'The Draft bill is listed against the order.');
        System.assertEquals('Draft', detail.bills[0].status, 'Bill status.');
    }

    @IsTest
    static void matchStatusCoversEveryState() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            System.assertEquals('Not received', SABPurchasingWorkspaceController.matchStatus(10, 0, 0), 'Nothing yet.');
            System.assertEquals('Billed beyond receipt', SABPurchasingWorkspaceController.matchStatus(10, 0, 2), 'Billed with no receipt.');
            System.assertEquals('Awaiting bill', SABPurchasingWorkspaceController.matchStatus(10, 4, 0), 'Received, not billed.');
            System.assertEquals('Part billed', SABPurchasingWorkspaceController.matchStatus(10, 4, 2), 'Partly billed.');
            System.assertEquals('Billed to receipt', SABPurchasingWorkspaceController.matchStatus(10, 4, 4), 'Billed what arrived.');
            System.assertEquals('Fully billed', SABPurchasingWorkspaceController.matchStatus(10, 10, 10), 'Complete.');
            System.assertEquals('Billed beyond receipt', SABPurchasingWorkspaceController.matchStatus(10, 4, 5), 'Over-billed.');
        }
    }

    @IsTest
    static void enforcesViewPermissionAndInputs() {
        List<String> refused = new List<String>();
        SABTestGovernor.startTest();
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.APPROVER)) {
            try {
                SABPurchasingWorkspaceController.getWorkspace(SABPurchasingTestFixture.companyId());
            } catch (SABPermissionService.PermissionDeniedException ex) {
                refused.add('no-view-permission');
            }
        }
        System.runAs(SABPurchasingTestFixture.user(SABPurchasingTestFixture.BUYER)) {
            for (Integer i = 0; i < 2; i++) {
                try {
                    if (i == 0) {
                        SABPurchasingWorkspaceController.getWorkspace(null);
                    } else {
                        SABPurchasingWorkspaceController.getPurchaseOrderDetail(null);
                    }
                } catch (SABPurchasingWorkspaceController.PurchasingWorkspaceException ex) {
                    refused.add('required-' + i);
                }
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals(new List<String>{'no-view-permission', 'required-0', 'required-1'}, refused, 'Refused requests.');
        System.assertNotEquals(null, SABPurchasingWorkspaceController.capabilities().receive, 'Capability flags are populated.');
    }
}
