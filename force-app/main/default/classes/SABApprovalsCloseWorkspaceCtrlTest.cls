@IsTest
private class SABApprovalsCloseWorkspaceCtrlTest {

    private static final String WORKSPACE_SET = 'SAB_Approvals_Close_Workspace_User';

    @TestSetup
    static void setupData() {
        SABApprovalCloseTestFixture.createFixture();
    }

    private static void grantWorkspace(List<String> lastNames) {
        List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Id setId = [SELECT Id FROM PermissionSet WHERE Name = :WORKSPACE_SET WITH SYSTEM_MODE LIMIT 1].Id;
            for (String lastName : lastNames) {
                rows.add(new PermissionSetAssignment(AssigneeId = SABApprovalCloseTestFixture.user(lastName).Id, PermissionSetId = setId));
            }
            insert as system rows;
        }
    }

    @IsTest
    static void inboxAndSubmittedRequestsFollowTheUser() {
        grantWorkspace(new List<String>{ SABApprovalCloseTestFixture.REQUESTER, SABApprovalCloseTestFixture.APPROVER_A });
        Id companyId = SABApprovalCloseTestFixture.companyId();
        SABApprovalsCloseWorkspaceController.WorkspaceData approverView;
        SABApprovalsCloseWorkspaceController.WorkspaceData requesterView;
        SABTestGovernor.startTest();
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.REQUESTER)) {
            SABApprovalService.submit(SABApprovalCloseTestFixture.submission(new List<String>{
                SABApprovalCloseTestFixture.APPROVER_A, SABApprovalCloseTestFixture.APPROVER_B }, 1), 'G22E-SUBMIT');
            requesterView = SABApprovalsCloseWorkspaceController.getWorkspace(companyId);
        }
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.APPROVER_A)) {
            approverView = SABApprovalsCloseWorkspaceController.getWorkspace(companyId);
        }
        SABTestGovernor.stopTest();
        System.assert(approverView.canDecide, 'Approver A can decide.');
        System.assertEquals(1, approverView.inbox.size(), 'Approver A holds the first step.');
        System.assertEquals('A19-4000', approverView.inbox[0].sourceBusinessKey, 'Source key.');
        System.assertEquals('GL Account', approverView.inbox[0].sourceLabel, 'Source type label.');
        System.assertEquals(0, approverView.myRequests.size(), 'Approver A submitted nothing.');
        System.assert(requesterView.canRequest && !requesterView.canDecide, 'Requester can request only.');
        System.assertEquals(0, requesterView.inbox.size(), 'Nothing waits on the requester.');
        System.assertEquals(1, requesterView.myRequests.size(), 'The pending request is listed.');
        System.assertEquals('Pending', requesterView.myRequests[0].status, 'Pending.');
        System.assertNotEquals(null, requesterView.myRequests[0].nextApprover, 'Next approver is named.');
        System.assertEquals(2, requesterView.periods.size(), 'January and February periods.');
        System.assertNotEquals(null, requesterView.currentPeriodId, 'A default period is chosen.');
    }

    @IsTest
    static void checklistShowsTasksAssigneesAndReadiness() {
        grantWorkspace(new List<String>{ SABApprovalCloseTestFixture.MANAGER });
        Id companyId = SABApprovalCloseTestFixture.companyId();
        Id periodId = SABApprovalCloseTestFixture.periodId(1);
        SABApprovalsCloseWorkspaceController.ChecklistData empty;
        SABApprovalsCloseWorkspaceController.ChecklistData generated;
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.MANAGER)) {
            Test.startTest();
            empty = SABApprovalsCloseWorkspaceController.getChecklist(companyId, periodId);
            SABCloseTaskService.generateChecklist(periodId);
            generated = SABApprovalsCloseWorkspaceController.getChecklist(companyId, periodId);
            Test.stopTest();
        }
        System.assertEquals(0, empty.total, 'No checklist yet.');
        System.assert(empty.readyToClose, 'No checklist means no gate.');
        System.assert(generated.total > 0, 'Tasks were generated.');
        System.assertEquals(generated.total, generated.tasks.size(), 'Every task is listed.');
        System.assert(!generated.readyToClose, 'Open tasks block the close.');
        System.assertEquals('A19-2026-01', generated.periodKey.right(11), 'Period key.');
        System.assert(!generated.assignees.isEmpty(), 'Grant holders can be assigned.');
    }

    @IsTest
    static void accessRulesAreEnforced() {
        grantWorkspace(new List<String>{ SABApprovalCloseTestFixture.OUTSIDER, SABApprovalCloseTestFixture.MANAGER });
        Id companyId = SABApprovalCloseTestFixture.companyId();
        Map<String, String> messages = new Map<String, String>();
        Test.startTest();
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.OUTSIDER)) {
            try {
                SABApprovalsCloseWorkspaceController.getWorkspace(companyId);
            } catch (AuraHandledException ex) {
                messages.put('grant', ex.getMessage());
            }
        }
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.APPROVER_B)) {
            try {
                SABApprovalsCloseWorkspaceController.getWorkspace(companyId);
            } catch (AuraHandledException ex) {
                messages.put('view', ex.getMessage());
            }
        }
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.MANAGER)) {
            try {
                SABApprovalsCloseWorkspaceController.getChecklist(companyId, null);
            } catch (AuraHandledException ex) {
                messages.put('period', ex.getMessage());
            }
            try {
                SABApprovalsCloseWorkspaceController.getWorkspace(null);
            } catch (AuraHandledException ex) {
                messages.put('company', ex.getMessage());
            }
        }
        Test.stopTest();
        System.assertEquals('You do not have active access to this Accounting Company.', messages.get('grant'), 'A grant is required.');
        System.assertEquals('You do not have permission to view Approvals and close.', messages.get('view'), 'The view permission is required.');
        System.assertEquals('Accounting period is required.', messages.get('period'), 'A period is required.');
        System.assertEquals('Accounting Company is required.', messages.get('company'), 'A company is required.');
    }

    @IsTest
    static void sourceLabelsFallBackToTheTypeName() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            String label = SABApprovalsCloseWorkspaceController.sourceLabel('Invoice__c');
            String unknown = SABApprovalsCloseWorkspaceController.sourceLabel('Not_An_Object__c');
            String blank = SABApprovalsCloseWorkspaceController.sourceLabel(null);
            Test.stopTest();
            System.assertNotEquals(null, label, 'Known objects get their label.');
            System.assertEquals('Not_An_Object__c', unknown, 'Unknown types keep their name.');
            System.assertEquals(null, blank, 'Blank stays blank.');
        }
    }
}
