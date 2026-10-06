@IsTest
private class SABProjectPolicyTest {
    @TestSetup
    static void setupData() {
        String seed = UserInfo.getOrganizationId() + '.' + System.now().getTime();
        Id profileId = [
            SELECT Id
            FROM Profile
            WHERE Name = 'Minimum Access - Salesforce'
                AND PermissionsViewAllData = false
                AND PermissionsModifyAllData = false
            LIMIT 1
        ].Id;
        List<User> users = new List<User>();
        for (String suffix : new List<String>{'manager', 'denied', 'reader'}) {
            users.add(new User(Alias = suffix, LastName = 'G11A ' + suffix,
                Username = 'g11a.' + suffix + '.' + seed + '@example.invalid', Email = 'g11a@example.invalid',
                ProfileId = profileId, TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'));
        }
        insert users;
        Id permissionId = [SELECT Id FROM PermissionSet WHERE Name = 'SAB_Project_Manager' LIMIT 1].Id;
        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(AssigneeId = users[0].Id, PermissionSetId = permissionId),
            new PermissionSetAssignment(AssigneeId = users[2].Id, PermissionSetId = permissionId)
        };
        System.runAs(users[0]) {
            List<Accounting_Company__c> companies = new List<Accounting_Company__c>();
            for (String code : new List<String>{'P11A', 'P11B', 'P11X'}) {
                companies.add(new Accounting_Company__c(Name__c = code, Company_Key__c = code, Country_Code__c = 'BD',
                    Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar',
                    Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active', Is_Active__c = true));
            }
            insert as system companies;
            List<Company_User_Access__c> grants = new List<Company_User_Access__c>();
            for (Integer i = 0; i < 2; i++) {
                grants.add(new Company_User_Access__c(Company__c = companies[i].Id, User__c = users[0].Id,
                    Role__c = 'Finance Manager', Is_Active__c = true, Effective_From__c = Date.today(), Grant_Key__c = 'G11A-' + i));
            }
            grants.add(new Company_User_Access__c(Company__c = companies[0].Id, User__c = users[1].Id,
                Role__c = 'Bookkeeper', Is_Active__c = true, Effective_From__c = Date.today(), Grant_Key__c = 'G11A-DENIED'));
            insert as system grants;
        }
    }
    private static User actor(String suffix) {
        return [SELECT Id FROM User WHERE LastName = :('G11A ' + suffix) LIMIT 1];
    }
    private static Id company(String key) {
        return [SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = :key WITH SYSTEM_MODE LIMIT 1].Id;
    }
    private static Project__c project(Id companyId, String code) {
        return new Project__c(Name = 'Project ' + code, Company__c = companyId, Project_Code__c = code);
    }
    private static void assertRejected(Database.SaveResult result, String expected) {
        System.assertEquals(false, result.isSuccess(), 'Invalid project must be rejected.');
        System.assert(result.getErrors()[0].getMessage().contains(expected), result.getErrors()[0].getMessage());
    }
    @IsTest static void createNormalizesAndDefaultsUsingUserMode() {
        System.runAs(actor('manager')) {
            Id cid = company('P11A');
            Project__c row = project(cid, '  build-01  ');
            row.Start_Date__c = Date.today(); row.End_Date__c = Date.today();
            row.Manager__c = UserInfo.getUserId();
            Test.startTest();
            insert as user row;
            Test.stopTest();
            Project__c saved = [SELECT Project_Code__c, Company_Project_Key__c, Status__c, Manager__c FROM Project__c WHERE Id = :row.Id WITH USER_MODE];
            System.assertEquals('BUILD-01', saved.Project_Code__c, 'Code is normalized.');
            System.assertEquals(cid + ':BUILD-01', saved.Company_Project_Key__c, 'Key is company scoped.');
            System.assertEquals('Planned', saved.Status__c, 'New project defaults to Planned.');
            System.assertEquals(UserInfo.getUserId(), saved.Manager__c, 'Manager is retained.');
        }
    }
    @IsTest static void duplicateCodeIsCompanyScopedAndKeysCannotBeSpoofed() {
        System.runAs(actor('manager')) {
            Id a = company('P11A'); Id b = company('P11B');
            insert as system new List<Project__c>{project(a, 'same'), project(b, 'SAME')};
            Project__c duplicate = project(a, ' Same '); duplicate.Company_Project_Key__c = 'spoof';
            Test.startTest();
            Database.SaveResult result = Database.insert(duplicate, false, AccessLevel.SYSTEM_MODE);
            Test.stopTest();
            System.assertEquals(false, result.isSuccess(), 'Duplicate within company must fail.');
            System.assertEquals(StatusCode.DUPLICATE_VALUE, result.getErrors()[0].getStatusCode(), 'Unique key enforces duplicate protection.');
            System.assertEquals(2, [SELECT COUNT() FROM Project__c], 'Same code across companies is permitted.');
        }
    }
    @IsTest static void lifecycleAndDescriptiveEdits() {
        System.runAs(actor('manager')) {
            Project__c row = project(company('P11A'), 'LIFE'); insert as system row;
            Test.startTest();
            row.Status__c = 'Active'; update as system row;
            row.Name = 'Updated description'; update as system row;
            row.Status__c = 'Complete'; update as system row;
            row.Status__c = 'Active';
            assertRejected(Database.update(row, false, AccessLevel.SYSTEM_MODE), 'Allowed transitions');
            Test.stopTest();
            System.assertEquals('Complete', [SELECT Status__c FROM Project__c WHERE Id = :row.Id].Status__c, 'Failed reopening preserves Complete.');
        }
    }
    @IsTest static void cancellationFromPlannedAndActive() {
        System.runAs(actor('manager')) {
            List<Project__c> rows = new List<Project__c>{project(company('P11A'), 'C1'), project(company('P11A'), 'C2')};
            insert as system rows;
            rows[1].Status__c = 'Active'; update as system rows[1];
            Test.startTest();
            for (Project__c row : rows) { row.Status__c = 'Cancelled'; }
            update as system rows;
            rows[0].Status__c = 'Planned';
            assertRejected(Database.update(rows[0], false, AccessLevel.SYSTEM_MODE), 'Allowed transitions');
            Test.stopTest();
            System.assertEquals(2, [SELECT COUNT() FROM Project__c WHERE Status__c = 'Cancelled'], 'Both paths cancel successfully.');
        }
    }
    @IsTest static void invalidDatesAndInitialStatus() {
        System.runAs(actor('manager')) {
            Id cid = company('P11A');
            Project__c dates = project(cid, 'DATES'); dates.Start_Date__c = Date.today(); dates.End_Date__c = Date.today().addDays(-1);
            Project__c state = project(cid, 'STATE'); state.Status__c = 'Complete';
            Project__c blankCode = project(cid, '   ');
            Test.startTest();
            List<Database.SaveResult> results = Database.insert(new List<Project__c>{dates, state, blankCode}, false, AccessLevel.SYSTEM_MODE);
            Test.stopTest();
            assertRejected(results[0], 'end date'); assertRejected(results[1], 'start as Planned');
            System.assertEquals(false, results[2].isSuccess(), 'A blank code is rejected by the field or policy.');
            System.assertEquals(0, [SELECT COUNT() FROM Project__c], 'No invalid project is committed.');
        }
    }
    @IsTest static void identityAndInvalidTransitionsAreRejected() {
        System.runAs(actor('manager')) {
            Id a = company('P11A'); Id b = company('P11B');
            Project__c row = project(a, 'FIXED'); insert as system row;
            Test.startTest();
            row.Company__c = b; assertRejected(Database.update(row, false, AccessLevel.SYSTEM_MODE), 'cannot change');
            row.Company__c = a; row.Project_Code__c = 'NEW'; assertRejected(Database.update(row, false, AccessLevel.SYSTEM_MODE), 'cannot change');
            row.Project_Code__c = 'FIXED'; row.Status__c = 'Complete'; assertRejected(Database.update(row, false, AccessLevel.SYSTEM_MODE), 'Allowed transitions');
            row.Status__c = null; assertRejected(Database.update(row, false, AccessLevel.SYSTEM_MODE), 'valid project status');
            Test.stopTest();
            Project__c persisted = [SELECT Company__c, Project_Code__c, Status__c FROM Project__c WHERE Id = :row.Id];
            System.assertEquals(a, persisted.Company__c, 'Company remains unchanged.');
            System.assertEquals('FIXED', persisted.Project_Code__c, 'Code remains unchanged.');
            System.assertEquals('Planned', persisted.Status__c, 'Invalid transitions do not commit.');
        }
    }
    @IsTest static void companyGrantIsRequiredAndRevocationAppliesImmediately() {
        System.runAs(actor('manager')) {
            Id a = company('P11A'); Id denied = company('P11X');
            Project__c row = project(a, 'REVOKE'); insert as system row;
            Company_User_Access__c grant = [SELECT Id FROM Company_User_Access__c WHERE Grant_Key__c = 'G11A-0' WITH SYSTEM_MODE LIMIT 1];
            Test.startTest();
            assertRejected(Database.insert(project(denied, 'NOACCESS'), false, AccessLevel.SYSTEM_MODE), 'active company access');
            delete as system grant;
            row.Name = 'Denied update'; assertRejected(Database.update(row, false, AccessLevel.SYSTEM_MODE), 'active company access');
            Test.stopTest();
            System.assertEquals('Project REVOKE', [SELECT Name FROM Project__c WHERE Id = :row.Id].Name, 'Revocation prevents changing even an owned project.');
        }
    }
    @IsTest static void actionPermissionIsRequiredEvenWithCompanyGrant() {
        System.runAs(actor('denied')) {
            Id cid = company('P11A');
            Test.startTest();
            assertRejected(Database.insert(project(cid, 'DENIED'), false, AccessLevel.SYSTEM_MODE), 'Manage Projects permission');
            Test.stopTest();
            System.assertEquals(0, [SELECT COUNT() FROM Project__c WITH SYSTEM_MODE], 'Denied request creates no data.');
        }
    }
    @IsTest static void deleteIsBlockedAndBulkCreateIsSupported() {
        System.runAs(actor('manager')) {
            Id cid = company('P11A'); List<Project__c> rows = new List<Project__c>();
            for (Integer i = 0; i < 200; i++) { rows.add(project(cid, 'BULK-' + i)); }
            Test.startTest();
            insert as system rows;
            Database.DeleteResult result = Database.delete(rows[0], false, AccessLevel.SYSTEM_MODE);
            Test.stopTest();
            System.assertEquals(false, result.isSuccess(), 'Deletion must be blocked.');
            System.assert(result.getErrors()[0].getMessage().contains('accounting history'), 'Retention message is returned.');
            System.assertEquals(200, [SELECT COUNT() FROM Project__c], 'All bulk rows persist.');
        }
    }
    @IsTest static void unrelatedUserCannotReadPrivateProjects() {
        Id projectId;
        System.runAs(actor('manager')) {
            Project__c row = project(company('P11A'), 'PRIVATE'); insert as user row;
            projectId = row.Id;
        }
        System.runAs(actor('reader')) {
            Test.startTest();
            List<Project__c> visible = [SELECT Id FROM Project__c WHERE Id = :projectId WITH USER_MODE];
            Test.stopTest();
            System.assertEquals(0, visible.size(), 'Project object permission alone grants no access to another company project.');
        }
    }
    @IsTest static void legacyLifecycleAndRestoreAuthorizationPolicy() {
        System.runAs(actor('manager')) {
            Id cid = company('P11A');
            Project__c beforeRow = project(cid, 'LEGACY');
            // In-memory legacy snapshot: no test bypass of the production trigger.
            beforeRow.Id = Project__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).getKeyPrefix() + '000000000001';
            Project__c afterRow = beforeRow.clone(true, false, false, false); afterRow.Status__c = 'Planned';
            Test.startTest();
            SABProjectPolicy.beforeSave(new List<Project__c>{afterRow}, new Map<Id, Project__c>{beforeRow.Id => beforeRow});
            SABProjectPolicy.afterUndelete(new List<Project__c>{afterRow});
            System.assertEquals(false, afterRow.hasErrors(), 'Authorized legacy project can enter Planned and pass restore authorization.');
            Project__c denied = project(company('P11X'), 'RESTORE');
            SABProjectPolicy.afterUndelete(new List<Project__c>{denied});
            System.assertEquals(true, denied.hasErrors(), 'Restore to an unauthorized company is rejected.');
            Test.stopTest();
        }
    }
}
