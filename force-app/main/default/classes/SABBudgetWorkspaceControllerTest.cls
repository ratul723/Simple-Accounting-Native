@IsTest
private class SABBudgetWorkspaceControllerTest {

    @TestSetup
    static void setupData() {
        SABBudgetTestFixture.createFixture();
        // Planner and outsider open the workspace; the approver deliberately does not have the view permission.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Id workspaceSet = [SELECT Id FROM PermissionSet WHERE Name = 'SAB_Budget_Workspace_User' WITH SYSTEM_MODE].Id;
            insert as system new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = SABBudgetTestFixture.user(SABBudgetTestFixture.PLANNER).Id, PermissionSetId = workspaceSet),
                new PermissionSetAssignment(AssigneeId = SABBudgetTestFixture.user(SABBudgetTestFixture.OUTSIDER).Id, PermissionSetId = workspaceSet)};
        }
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.APPROVER)) {
            SABBudgetTestFixture.seedBudget('Approved', 1, new List<List<Object>>{
                new List<Object>{'B13-2026-10', '4000', null, (Decimal) 1200},
                new List<Object>{'B13-2026-10', '6000', 'SAL', (Decimal) 250},
                new List<Object>{'B13-2026-11', '6000', null, (Decimal) 100}});
        }
    }

    private static Id budgetId() {
        return [SELECT Id FROM Budget__c WHERE Company__c = :SABBudgetTestFixture.companyId() WITH SYSTEM_MODE LIMIT 1].Id;
    }

    @IsTest
    static void workspaceListsBudgetsYearsAndOptions() {
        SABBudgetWorkspaceController.WorkspaceDTO ws;
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.PLANNER)) {
            SABTestGovernor.startTest();
            ws = SABBudgetWorkspaceController.getWorkspace(SABBudgetTestFixture.companyId());
            SABTestGovernor.stopTest();
        }
        System.assertEquals(1, ws.budgets.size(), 'One budget version.');
        System.assertEquals(3, ws.budgets[0].lineCount, 'Line count from the child lines.');
        System.assertEquals(2026, ws.budgets[0].fiscalYear, 'Fiscal year.');
        System.assertEquals(new List<Integer>{2025, 2026}, ws.fiscalYears, 'Fiscal years from the periods, ascending.');
        System.assertEquals(3, ws.periods.size(), 'Every period with its fiscal year.');
        System.assertEquals(3, ws.accounts.size(), 'Only active GL accounts (6100 is inactive).');
        System.assertEquals(2, ws.departments.size(), 'Departments.');
        System.assertEquals(1, ws.costCenters.size(), 'Cost centers.');
        Map<String, Integer> counts = new Map<String, Integer>();
        for (SABBudgetWorkspaceController.StateCount c : ws.stateCounts) {
            counts.put(c.state, c.count);
        }
        System.assertEquals(1, counts.get('Approved'), 'Counts by status.');
        System.assertEquals(true, ws.capabilities.manage, 'Planner manages budgets.');
        System.assertEquals(false, ws.capabilities.approve, 'Planner cannot approve.');
    }

    @IsTest
    static void detailResolvesNamesAndTotal() {
        SABBudgetWorkspaceController.BudgetDetailDTO detail;
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.PLANNER)) {
            SABTestGovernor.startTest();
            detail = SABBudgetWorkspaceController.getBudgetDetail(budgetId());
            SABTestGovernor.stopTest();
        }
        System.assertEquals('Approved', detail.budget.status, 'Budget status.');
        System.assertEquals(3, detail.lines.size(), 'Three lines.');
        System.assertEquals(1550, detail.total, 'Total of the lines.');
        Map<String, Decimal> byKey = new Map<String, Decimal>();
        for (SABBudgetWorkspaceController.LineDTO l : detail.lines) {
            byKey.put(l.periodName + '|' + l.accountName + '|' + l.departmentName, l.amount);
        }
        System.assertEquals(1200, byKey.get('B13-2026-10|4000 Sales|null'), 'Account and period names are resolved.');
        System.assertEquals(250, byKey.get('B13-2026-10|6000 Supplies|Sales'), 'Department name is resolved.');
    }

    @IsTest
    static void enforcesViewPermissionCompanyAccessAndInputs() {
        List<String> refused = new List<String>();
        Id companyId = SABBudgetTestFixture.companyId();
        SABTestGovernor.startTest();
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.APPROVER)) {
            try {
                SABBudgetWorkspaceController.getWorkspace(companyId);
            } catch (SABPermissionService.PermissionDeniedException ex) {
                refused.add('no-view-permission');
            }
        }
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.OUTSIDER)) {
            try {
                SABBudgetWorkspaceController.getWorkspace(companyId);
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                refused.add('no-company-grant');
            }
        }
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.PLANNER)) {
            for (Integer i = 0; i < 2; i++) {
                try {
                    if (i == 0) {
                        SABBudgetWorkspaceController.getWorkspace(null);
                    } else {
                        SABBudgetWorkspaceController.getBudgetDetail(null);
                    }
                } catch (SABBudgetWorkspaceController.BudgetWorkspaceException ex) {
                    refused.add('required-' + i);
                }
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals(new List<String>{'no-view-permission', 'no-company-grant', 'required-0', 'required-1'}, refused, 'Refused requests.');
        System.assertNotEquals(null, SABBudgetWorkspaceController.capabilities().manage, 'Capability flags are populated.');
    }
}
