@IsTest
private class SABAdminWorkspaceControllerTest {

    private static final String OTHER = 'SAB G22H0 Other';

    @TestSetup
    static void setupData() {
        SABAppShellTestFixture.seed();
        // The fixture user doubles as the administrator, so setup stays inside the 50-query cap.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            Id userId = SABAppShellTestFixture.fixtureUser().Id;
            for (PermissionSet p : [SELECT Id FROM PermissionSet WHERE Name IN ('SAB_Manage_Company_Setup_Action', 'SAB_Project_Manager', 'SAB_Project_Financials_User',
                    'SAB_Manage_Company_Access_Action') WITH SYSTEM_MODE]) {
                assignments.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = p.Id));
            }
            insert as system assignments;
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    /** A second user without company access, created outside the test window by the tests that need one. */
    private static User otherUser() {
        User created;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            created = SABAppShellTestFixture.createUser('g22h0ot', OTHER, new List<String>{ 'SAB_App_User' });
        }
        return created;
    }

    private static User admin() {
        return SABAppShellTestFixture.fixtureUser();
    }

    private static Id companyId() {
        return SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
    }

    @IsTest
    static void chartShowsAccountsDimensionsAndBalances() {
        Id companyId = companyId();
        SABAdminWorkspaceController.ChartData chart;
        System.runAs(admin()) {
            Test.startTest();
            SABAdminWorkspaceService.DimensionRequest dept = new SABAdminWorkspaceService.DimensionRequest();
            dept.companyId = companyId;
            dept.code = 'OPS';
            dept.name = 'Operations';
            Id deptId = SABAdminWorkspaceService.saveDepartment(dept, 'G22H0-DEPT');
            Id replay = SABAdminWorkspaceService.saveDepartment(dept, 'G22H0-DEPT');
            System.assertEquals(deptId, replay, 'Replay returns the same department.');
            dept.recordId = deptId;
            dept.name = 'Operations and logistics';
            dept.parentId = deptId;
            String selfParent;
            try {
                SABAdminWorkspaceService.saveDepartment(dept, 'G22H0-DEPT-SELF');
            } catch (SABAdminWorkspaceService.AdminWorkspaceException ex) {
                selfParent = ex.getMessage();
            }
            System.assertEquals('A department cannot be its own parent.', selfParent, 'No self parent.');
            dept.parentId = null;
            SABAdminWorkspaceService.saveDepartment(dept, 'G22H0-DEPT-2');
            SABAdminWorkspaceService.DimensionRequest cc = new SABAdminWorkspaceService.DimensionRequest();
            cc.companyId = companyId;
            cc.code = 'CC1';
            cc.name = 'Head office';
            SABAdminWorkspaceService.saveCostCenter(cc, 'G22H0-CC');
            chart = SABAdminWorkspaceController.getChart(companyId);
            Test.stopTest();
        }
        System.assert(chart.canManageSetup && chart.canManageProjects, 'Admin can manage setup and projects.');
        System.assertEquals(3, chart.accounts.size(), 'Fixture accounts.');
        System.assertEquals(0, chart.accounts[0].balance, 'No postings yet.');
        System.assertEquals(1, chart.departments.size(), 'One department.');
        System.assertEquals('Operations and logistics', chart.departments[0].name, 'Edited name.');
        System.assertEquals(1, chart.costCenters.size(), 'One cost center.');
        System.assertNotEquals(null, chart.definitions, 'Definitions list.');
    }

    @IsTest
    static void projectsAreSavedAndListedWithTotals() {
        Id companyId = companyId();
        SABAdminWorkspaceController.ProjectsData data;
        String badDates;
        System.runAs(admin()) {
            Test.startTest();
            SABAdminWorkspaceService.ProjectRequest p = new SABAdminWorkspaceService.ProjectRequest();
            p.companyId = companyId;
            p.code = 'prj-1';
            p.name = 'Warehouse fit-out';
            p.startDate = Date.today();
            p.endDate = Date.today().addMonths(3);
            Id projectId = SABAdminWorkspaceService.saveProject(p, 'G22H0-PRJ');
            p.recordId = projectId;
            p.status = 'Active';
            SABAdminWorkspaceService.saveProject(p, 'G22H0-PRJ-2');
            p.endDate = Date.today().addDays(-10);
            try {
                SABAdminWorkspaceService.saveProject(p, 'G22H0-PRJ-3');
            } catch (SABAdminWorkspaceService.AdminWorkspaceException ex) {
                badDates = ex.getMessage();
            }
            data = SABAdminWorkspaceController.getProjects(companyId);
            Test.stopTest();
        }
        System.assertEquals(1, data.projects.size(), 'One project.');
        System.assertEquals('Active', data.projects[0].status, 'Edited status.');
        System.assertEquals('PRJ-1', data.projects[0].code.toUpperCase(), 'Project code.');
        System.assertEquals(0, data.projects[0].cost, 'No tagged lines yet.');
        System.assert(data.canViewFinancials, 'Admin can view project financials.');
        System.assertEquals('The end date cannot be before the start date.', badDates, 'Date order.');
    }

    @IsTest
    static void configurationListsFeaturesGrantsChecksAndAllowsGrants() {
        Id companyId = companyId();
        SABAdminWorkspaceController.ConfigData config;
        List<String> messages = new List<String>();
        Id otherId = otherUser().Id;
        System.runAs(admin()) {
            Test.startTest();
            SABAdminWorkspaceService.GrantRequest g = new SABAdminWorkspaceService.GrantRequest();
            g.companyId = companyId;
            g.userId = otherId;
            g.role = 'Auditor';
            g.approvalLimit = 5000;
            Id grantId = SABAdminWorkspaceService.saveGrant(g, 'G22H0-GRANT');
            try {
                SABAdminWorkspaceService.saveGrant(g, 'G22H0-GRANT-DUP');
            } catch (SABAdminWorkspaceService.AdminWorkspaceException ex) {
                messages.add(ex.getMessage());
            }
            g.grantId = grantId;
            g.active = false;
            SABAdminWorkspaceService.saveGrant(g, 'G22H0-GRANT-END');
            SABAdminWorkspaceService.GrantRequest self = new SABAdminWorkspaceService.GrantRequest();
            self.companyId = companyId;
            self.userId = UserInfo.getUserId();
            self.role = 'Director';
            try {
                SABAdminWorkspaceService.saveGrant(self, 'G22H0-GRANT-SELF');
            } catch (SABAdminWorkspaceService.AdminWorkspaceException ex) {
                messages.add(ex.getMessage());
            }
            config = SABAdminWorkspaceController.getConfiguration(companyId);
            List<SABAdminWorkspaceController.Option> users = SABAdminWorkspaceController.searchUsers(companyId, 'G22H0');
            System.assert(users.size() >= 1, 'Users can be searched.');
            Test.stopTest();
        }
        System.assertEquals('This user already has an active grant. Edit that grant instead.', messages[0], 'One active grant per user.');
        System.assertEquals('You cannot change your own access. Ask another administrator.', messages[1], 'No self grants.');
        System.assert(config.canManageAccess && config.canManageSetup, 'Admin flags.');
        System.assertEquals(8, config.features.size(), 'Known features are always listed.');
        System.assert(config.grants.size() >= 2, 'Fixture and the ended grant.');
        Boolean endedFound = false;
        for (SABAdminWorkspaceController.GrantRow row : config.grants) {
            if (row.userId == otherId) {
                endedFound = !row.active && row.approvalLimit == 5000;
            }
        }
        System.assert(endedFound, 'The ended grant is inactive with its limit.');
        System.assert(!config.checks.isEmpty(), 'Configuration checks run.');
        System.assert(!config.roles.isEmpty(), 'Roles from the picklist.');
        System.assertNotEquals(null, config.runs, 'Processing runs list.');
        System.assertNotEquals(null, config.approvals, 'Approval activity list.');
    }

    @IsTest
    static void permissionsAndCompanyAccessAreEnforced() {
        Id companyId = companyId();
        List<String> messages = new List<String>();
        User noGrant = otherUser();
        System.runAs(noGrant) {
            Test.startTest();
            try {
                SABAdminWorkspaceController.getChart(companyId);
            } catch (AuraHandledException ex) {
                messages.add(ex.getMessage());
            }
            Test.stopTest();
        }
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert as system new Company_User_Access__c(Company__c = companyId, User__c = noGrant.Id, Effective_From__c = Date.today().addDays(-1),
                Grant_Key__c = 'G22H0-OTHER', Is_Active__c = true, Role__c = 'Bookkeeper');
        }
        System.runAs(noGrant) {
            SABAdminWorkspaceService.DimensionRequest dept = new SABAdminWorkspaceService.DimensionRequest();
            dept.companyId = companyId;
            dept.code = 'X';
            dept.name = 'X';
            try {
                SABAdminWorkspaceService.saveDepartment(dept, 'G22H0-DENIED');
            } catch (Exception ex) {
                messages.add(ex.getMessage());
            }
            try {
                SABAdminWorkspaceService.saveGrant(null, 'G22H0-NULL');
            } catch (Exception ex) {
                messages.add(ex.getMessage());
            }
            try {
                SABAdminWorkspaceService.saveProject(new SABAdminWorkspaceService.ProjectRequest(), '');
            } catch (Exception ex) {
                messages.add(ex.getMessage());
            }
        }
        System.assertEquals('You do not have active access to this Accounting Company.', messages[0], 'Grant required.');
        System.assertEquals('You do not have permission to manage company setup.', messages[1], 'Setup permission required.');
        System.assertEquals('Accounting Company is required.', messages[2], 'Request required.');
        System.assertEquals('A request key of up to 160 characters is required.', messages[3], 'Request key required.');
    }
}