@IsTest
private class SABGroupAccountingWorkspaceCtrlTest {

    private static final String WORKSPACE_SET = 'SAB_Group_Accounting_Workspace_User';

    @TestSetup
    static void setupData() {
        SABGroupAccountingTestFixture.createFixture();
    }

    private static User workspaceUser(String lastName) {
        User user = SABGroupAccountingTestFixture.user(lastName);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Id setId = [SELECT Id FROM PermissionSet WHERE Name = :WORKSPACE_SET WITH SYSTEM_MODE LIMIT 1].Id;
            insert as system new PermissionSetAssignment(AssigneeId = user.Id, PermissionSetId = setId);
        }
        return user;
    }

    @IsTest
    static void workspaceShowsIntercompanyGroupsMembersAndRuns() {
        User manager = workspaceUser(SABGroupAccountingTestFixture.MANAGER);
        Id parentId = SABGroupAccountingTestFixture.companyId('P');
        Id subsidiaryId = SABGroupAccountingTestFixture.companyId('S');
        SABGroupAccountingWorkspaceController.WorkspaceData parentView;
        SABGroupAccountingWorkspaceController.WorkspaceData subsidiaryView;
        System.runAs(manager) {
            SABGroupAccountingTestFixture.seedIntercompany();
            Consolidation_Run__c run = new Consolidation_Run__c(Consolidation_Group__c = SABGroupAccountingTestFixture.groupId(),
                As_Of_Date__c = Date.newInstance(2026, 1, 31), Policy_Version__c = 'v1', Status__c = 'Calculated', Run_Key__c = 'G22D-RUN-1');
            SABGroupAccountingGuard.beginWrite();
            try {
                insert as system run;
            } finally {
                SABGroupAccountingGuard.endWrite();
            }
            Test.startTest();
            parentView = SABGroupAccountingWorkspaceController.getWorkspace(parentId);
            subsidiaryView = SABGroupAccountingWorkspaceController.getWorkspace(subsidiaryId);
            Test.stopTest();
        }
        System.assertEquals('USD', parentView.currencyCode, 'Functional currency.');
        System.assert(parentView.canManageIntercompany && parentView.canManageConsolidation, 'Manager manages both.');
        System.assert(!parentView.canApproveConsolidation, 'Manager cannot approve.');
        System.assertEquals(1, parentView.transactions.size(), 'One intercompany transaction.');
        System.assertEquals('Receivable', parentView.transactions[0].direction, 'The parent charged the subsidiary.');
        System.assertEquals(1000, parentView.receivableTotal, 'Charged to others.');
        System.assertEquals(0, parentView.unmatchedCount, 'The seeded transaction is matched.');
        System.assertEquals('Payable', subsidiaryView.transactions[0].direction, 'The subsidiary was charged.');
        System.assertEquals(1000, subsidiaryView.payableTotal, 'Charged by others.');
        System.assert(parentView.consolidationAvailable, 'Consolidation is readable.');
        System.assertEquals(1, parentView.groups.size(), 'The parent belongs to one group.');
        System.assertEquals(3, parentView.groups[0].members.size(), 'P, S and J are members.');
        System.assertEquals(1, parentView.groups[0].runs.size(), 'One run.');
        System.assert(parentView.groups[0].runs[0].calculatedByMe, 'The manager calculated the run.');
        System.assertEquals(0, parentView.groups[0].runs[0].eliminationCount, 'No eliminations seeded.');
    }

    @IsTest
    static void optionsListCompaniesAndAccounts() {
        User manager = workspaceUser(SABGroupAccountingTestFixture.MANAGER);
        Id parentId = SABGroupAccountingTestFixture.companyId('P');
        Id subsidiaryId = SABGroupAccountingTestFixture.companyId('S');
        List<SABGroupAccountingWorkspaceController.Option> companies;
        List<SABGroupAccountingWorkspaceController.Option> accounts;
        System.runAs(manager) {
            Test.startTest();
            companies = SABGroupAccountingWorkspaceController.getCompanyOptions(parentId);
            accounts = SABGroupAccountingWorkspaceController.getAccountOptions(parentId, subsidiaryId);
            Test.stopTest();
        }
        System.assertEquals(4, companies.size(), 'The manager holds grants to P, S, J and E.');
        System.assertEquals(6, accounts.size(), 'Six accounts in the subsidiary.');
        System.assertEquals('1100', accounts[0].label.left(4), 'Ordered by code.');
    }

    @IsTest
    static void accessRulesAreEnforced() {
        User outsider = workspaceUser(SABGroupAccountingTestFixture.OUTSIDER);
        User approver = SABGroupAccountingTestFixture.user(SABGroupAccountingTestFixture.APPROVER);
        Id parentId = SABGroupAccountingTestFixture.companyId('P');
        Id subsidiaryId = SABGroupAccountingTestFixture.companyId('S');
        String accountMessage;
        String grantMessage;
        String viewMessage;
        String missingMessage;
        Test.startTest();
        System.runAs(outsider) {
            try {
                SABGroupAccountingWorkspaceController.getAccountOptions(parentId, subsidiaryId);
            } catch (AuraHandledException ex) {
                accountMessage = ex.getMessage();
            }
            try {
                SABGroupAccountingWorkspaceController.getWorkspace(subsidiaryId);
            } catch (AuraHandledException ex) {
                grantMessage = ex.getMessage();
            }
            try {
                SABGroupAccountingWorkspaceController.getWorkspace(null);
            } catch (AuraHandledException ex) {
                missingMessage = ex.getMessage();
            }
        }
        System.runAs(approver) {
            try {
                SABGroupAccountingWorkspaceController.getCompanyOptions(parentId);
            } catch (AuraHandledException ex) {
                viewMessage = ex.getMessage();
            }
        }
        Test.stopTest();
        System.assertEquals('You do not have active access to that Accounting Company.', accountMessage, 'Account options need a grant.');
        System.assertEquals('You do not have active access to this Accounting Company.', grantMessage, 'The workspace needs a grant.');
        System.assertEquals('Accounting Company is required.', missingMessage, 'A company is required.');
        System.assertEquals('You do not have permission to view Group accounting.', viewMessage, 'SAB_View_Group_Accounting is required.');
    }

    @IsTest
    static void fiscalYearStartSpansCalendarYears() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            Date julyStart = SABGroupAccountingWorkspaceController.fiscalYearStart(Date.newInstance(2026, 3, 1), 7);
            Date januaryStart = SABGroupAccountingWorkspaceController.fiscalYearStart(Date.newInstance(2026, 3, 1), null);
            Test.stopTest();
            System.assertEquals(Date.newInstance(2025, 7, 1), julyStart, 'Previous calendar year.');
            System.assertEquals(Date.newInstance(2026, 1, 1), januaryStart, 'Defaults to January.');
        }
    }
}
