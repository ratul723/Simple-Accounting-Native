@IsTest
private class SABAllocationWorkspaceControllerTest {

    @TestSetup
    static void setupData() {
        SABAllocationTestFixture.createFixture();
        // Preparer and outsider open the workspace; the approver deliberately does not have the view permission.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Id workspaceSet = [SELECT Id FROM PermissionSet WHERE Name = 'SAB_Allocation_Workspace_User' WITH SYSTEM_MODE].Id;
            insert as system new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER).Id,
                    PermissionSetId = workspaceSet),
                new PermissionSetAssignment(AssigneeId = SABAllocationTestFixture.user(SABAllocationTestFixture.OUTSIDER).Id,
                    PermissionSetId = workspaceSet)};
        }
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.APPROVER)) {
            SABAllocationTestFixture.seedRule('RENT-SPLIT', 'Approved', 'Percent', 'Largest Remainder', new List<String>{'6100', '6200'},
                new List<List<Object>>{new List<Object>{'SAL', (Decimal) 60}, new List<Object>{'OPS', (Decimal) 40}});
        }
    }

    private static Id ruleId() {
        return [SELECT Id FROM Allocation_Rule__c WHERE Rule_Key__c = 'RENT-SPLIT' WITH SYSTEM_MODE LIMIT 1].Id;
    }

    @IsTest
    static void workspaceListsRulesRunsAndOptions() {
        SABAllocationWorkspaceController.WorkspaceDTO ws;
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            SABTestGovernor.startTest();
            SABAllocationRunService.preview(ruleId(), SABAllocationTestFixture.periodId('A14-2026-10'), 'G14B-PREVIEW');
            ws = SABAllocationWorkspaceController.getWorkspace(SABAllocationTestFixture.companyId());
            SABTestGovernor.stopTest();
        }
        System.assertEquals('A14 Company', ws.companyName, 'Company name.');
        System.assertEquals(true, ws.hasRoundingAccount, 'Default rounding account is reported.');
        System.assertEquals(1, ws.rules.size(), 'One rule.');
        System.assertEquals(2, ws.rules[0].targetCount, 'Target count from the child lines.');
        System.assertEquals(1, ws.runs.size(), 'One run.');
        System.assertEquals('A14-2026-10', ws.runs[0].periodName, 'Run period name.');
        System.assertEquals(1100.01, ws.runs[0].sourceAmount, 'Run source amount.');
        System.assertEquals(3, ws.accounts.size(), 'Only active non-control accounts are offered (6100, 6200, 7990).');
        System.assertEquals(2, ws.departments.size(), 'Departments.');
        System.assertEquals(1, ws.costCenters.size(), 'Cost centers.');
        System.assertEquals(1, ws.openPeriods.size(), 'Only Open periods (November is Closed).');
        Map<String, Integer> runCounts = new Map<String, Integer>();
        for (SABAllocationWorkspaceController.StateCount c : ws.runCounts) {
            runCounts.put(c.state, c.count);
        }
        System.assertEquals(1, runCounts.get('Preview'), 'Run counts by status.');
        System.assertEquals(true, ws.capabilities.manage, 'Preparer manages.');
        System.assertEquals(false, ws.capabilities.approve, 'Preparer cannot approve.');
        System.assertEquals(true, ws.capabilities.postJournal, 'Preparer can post journals.');
    }

    @IsTest
    static void ruleAndRunDetailResolveNames() {
        SABAllocationWorkspaceController.RuleDetailDTO rule;
        SABAllocationWorkspaceController.RunDetailDTO run;
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            SABTestGovernor.startTest();
            Id runId = SABAllocationRunService.preview(ruleId(), SABAllocationTestFixture.periodId('A14-2026-10'), 'G14B-DETAIL').runId;
            rule = SABAllocationWorkspaceController.getRuleDetail(ruleId());
            run = SABAllocationWorkspaceController.getRunDetail(runId);
            SABTestGovernor.stopTest();
        }
        System.assertEquals('Approved', rule.rule.status, 'Rule status.');
        System.assertEquals('6100 Rent', rule.sourceAccounts[0].label, 'Source account names are resolved.');
        System.assertEquals(2, rule.targets.size(), 'Two targets.');
        System.assertEquals('Same as source', rule.targets[0].targetAccountName, 'Blank target account means the source account.');
        System.assertEquals('Sales', rule.targets[0].targetDepartmentName, 'Target department name.');
        System.assertEquals(60, rule.targets[0].percentage, 'Target weight.');
        System.assertEquals('Preview', run.run.status, 'Run status.');
        System.assertEquals(4, run.lines.size(), 'Two targets for each of two source accounts.');
        Map<String, Decimal> amounts = new Map<String, Decimal>();
        for (SABAllocationWorkspaceController.AllocationLineDTO l : run.lines) {
            amounts.put(l.targetAccountName + '|' + l.targetDepartmentName, l.amount);
        }
        System.assertEquals(600, amounts.get('6100 Rent|Sales'), 'Rent to Sales.');
        System.assertEquals(60.01, amounts.get('6200 Utilities|Sales'), 'Utilities to Sales with the leftover cent.');
        System.assertEquals(40.00, amounts.get('6200 Utilities|Ops'), 'Utilities to Ops.');
    }

    @IsTest
    static void enforcesViewPermissionCompanyAccessAndInputs() {
        List<String> refused = new List<String>();
        Id companyId = SABAllocationTestFixture.companyId();
        SABTestGovernor.startTest();
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.APPROVER)) {
            try {
                SABAllocationWorkspaceController.getWorkspace(companyId);
            } catch (SABPermissionService.PermissionDeniedException ex) {
                refused.add('no-view-permission');
            }
        }
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.OUTSIDER)) {
            try {
                SABAllocationWorkspaceController.getWorkspace(companyId);
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                refused.add('no-company-grant');
            }
        }
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            for (Integer i = 0; i < 3; i++) {
                try {
                    if (i == 0) {
                        SABAllocationWorkspaceController.getWorkspace(null);
                    } else if (i == 1) {
                        SABAllocationWorkspaceController.getRuleDetail(null);
                    } else {
                        SABAllocationWorkspaceController.getRunDetail(null);
                    }
                } catch (SABAllocationWorkspaceController.AllocationWorkspaceException ex) {
                    refused.add('required-' + i);
                }
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals(new List<String>{'no-view-permission', 'no-company-grant', 'required-0', 'required-1', 'required-2'}, refused,
            'Unauthorized and incomplete requests are refused.');
        System.assertNotEquals(null, SABAllocationWorkspaceController.capabilities().manage, 'Capability flags are populated.');
    }
}
