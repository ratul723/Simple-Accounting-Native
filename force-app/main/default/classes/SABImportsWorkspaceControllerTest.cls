@IsTest
private class SABImportsWorkspaceControllerTest {

    private static final String WORKSPACE_SET = 'SAB_Imports_Workspace_User';

    @TestSetup
    static void setupData() {
        SABImportTestFixture.createFixture();
    }

    private static void grantWorkspace(List<String> lastNames) {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Id setId = [SELECT Id FROM PermissionSet WHERE Name = :WORKSPACE_SET WITH SYSTEM_MODE LIMIT 1].Id;
            List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
            for (String lastName : lastNames) {
                rows.add(new PermissionSetAssignment(AssigneeId = SABImportTestFixture.user(lastName).Id, PermissionSetId = setId));
            }
            insert as system rows;
        }
    }

    @IsTest
    static void workspaceListsJobsRowsAndRequests() {
        grantWorkspace(new List<String>{ SABImportTestFixture.IMPORTER });
        Id companyId = SABImportTestFixture.companyId();
        String csv = 'Account_Code,Name,Account_Type\n5000,Rent,Expense\n6000,Mystery,Income\n';
        SABImportsWorkspaceController.WorkspaceData data;
        List<SABImportsWorkspaceController.RowView> rows;
        System.runAs(SABImportTestFixture.user(SABImportTestFixture.IMPORTER)) {
            SABTestGovernor.startTest();
            SABImportService.ActionResult staged = SABImportService.stage(companyId, 'Chart of Accounts', csv);
            SABImportService.validate(staged.importJobId);
            SABIntegrationLogService.RequestLog log = new SABIntegrationLogService.RequestLog();
            log.companyId = companyId;
            log.provider = 'Bank feed';
            log.operation = 'Send payment file';
            log.requestKey = 'G22F-LOG-1';
            log.payload = '{"amount":100}';
            SABIntegrationLogService.record(log);
            data = SABImportsWorkspaceController.getWorkspace(companyId);
            rows = SABImportsWorkspaceController.getRows(companyId, staged.importJobId);
            SABTestGovernor.stopTest();
        }
        System.assert(data.canManage && data.canCommit && data.canViewLog, 'The importer holds every G20 permission.');
        System.assertEquals(6, data.importTypes.size(), 'Six supported import types.');
        System.assertEquals(1, data.jobs.size(), 'One import job.');
        System.assertEquals(2, data.jobs[0].rowCount, 'Two rows.');
        System.assertEquals(1, data.jobs[0].errorCount, 'One row has an invalid account type.');
        System.assertEquals('Chart of Accounts', data.jobs[0].importType, 'Import type.');
        System.assertEquals(1, data.requests.size(), 'One integration request.');
        System.assertEquals('Pending', data.requests[0].state, 'New requests are Pending.');
        System.assertEquals(2, rows.size(), 'Both rows are returned.');
        System.assertEquals('Error', rows[0].status, 'Errors come first.');
        System.assertNotEquals(null, rows[0].message, 'Errors explain themselves.');
    }

    @IsTest
    static void accessRulesAreEnforced() {
        grantWorkspace(new List<String>{ SABImportTestFixture.OUTSIDER, SABImportTestFixture.IMPORTER });
        Id companyId = SABImportTestFixture.companyId();
        Map<String, String> messages = new Map<String, String>();
        User viewer;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            viewer = SABAppShellTestFixture.createUser('i20nov', 'SAB I20 No View', new List<String>{ 'SAB_App_User' });
        }
        Test.startTest();
        System.runAs(SABImportTestFixture.user(SABImportTestFixture.OUTSIDER)) {
            try {
                SABImportsWorkspaceController.getWorkspace(companyId);
            } catch (AuraHandledException ex) {
                messages.put('grant', ex.getMessage());
            }
        }
        System.runAs(SABImportTestFixture.user(SABImportTestFixture.IMPORTER)) {
            try {
                SABImportsWorkspaceController.getRows(companyId, null);
            } catch (AuraHandledException ex) {
                messages.put('job', ex.getMessage());
            }
            try {
                SABImportsWorkspaceController.getRows(companyId, companyId);
            } catch (AuraHandledException ex) {
                messages.put('owner', ex.getMessage());
            }
            try {
                SABImportsWorkspaceController.getWorkspace(null);
            } catch (AuraHandledException ex) {
                messages.put('company', ex.getMessage());
            }
        }
        // A user without SAB_View_Imports; the running admin may hold it, so it cannot stand in for this check.
        System.runAs(viewer) {
            try {
                SABImportsWorkspaceController.getWorkspace(companyId);
            } catch (AuraHandledException ex) {
                messages.put('view', ex.getMessage());
            }
        }
        Test.stopTest();
        System.assertEquals('You do not have active access to this Accounting Company.', messages.get('grant'), 'A grant is required.');
        System.assertEquals('Import job is required.', messages.get('job'), 'A job is required.');
        System.assertNotEquals(null, messages.get('owner'), 'A job of another company or a wrong id is refused.');
        System.assertEquals('Accounting Company is required.', messages.get('company'), 'A company is required.');
        System.assertEquals('You do not have permission to view the Import and integration center.', messages.get('view'),
            'SAB_View_Imports is required.');
    }
}