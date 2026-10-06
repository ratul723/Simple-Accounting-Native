@IsTest
private class SABCompanyFeatureAccessTest {
    private static final String ADMIN_NAME = 'SAB P12 Feature Admin';
    private static final String READER_NAME = 'SAB P12 Feature Reader';
    private static final String OUTSIDER_NAME = 'SAB P12 Feature Outsider';

    @TestSetup
    static void setupData() {
        User adminUser;
        User readerUser;
        User outsiderUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Id standardProfile = restrictedProfileId();
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            adminUser = newUser(standardProfile, ADMIN_NAME, 'p12fad', unique);
            readerUser = newUser(standardProfile, READER_NAME, 'p12frd', unique);
            outsiderUser = newUser(standardProfile, OUTSIDER_NAME, 'p12fou', unique);
            insert as system new List<User>{adminUser, readerUser, outsiderUser};
            Map<String, Id> sets = new Map<String, Id>();
            for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN ('SAB_Company_Feature_Admin', 'SAB_Company_Feature_User')
                    WITH SYSTEM_MODE]) {
                sets.put(p.Name, p.Id);
            }
            System.assertEquals(2, sets.size(), 'Deploy both G12 Company Feature permission sets.');
            insert as system new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = adminUser.Id, PermissionSetId = sets.get('SAB_Company_Feature_Admin')),
                new PermissionSetAssignment(AssigneeId = readerUser.Id, PermissionSetId = sets.get('SAB_Company_Feature_User')),
                new PermissionSetAssignment(AssigneeId = outsiderUser.Id, PermissionSetId = sets.get('SAB_Company_Feature_User'))};
        }
        System.runAs(adminUser) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'P12 Feature Co', Company_Key__c = 'P12F', Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active', Is_Active__c = true);
            insert as system company;
            insert as system new List<Company_User_Access__c>{
                new Company_User_Access__c(Company__c = company.Id, User__c = adminUser.Id, Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'P12F-ADMIN', Role__c = 'Finance Manager'),
                new Company_User_Access__c(Company__c = company.Id, User__c = readerUser.Id, Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'P12F-READER', Role__c = 'Finance Manager')};
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    // Sharing is the subject of this test, so the profile must not bypass it: a standard-licence profile without
    // View All Data or Modify All Data, preferring 'Standard User'. (The alphabetically first standard profile is often
    // 'Analytics Cloud Integration User', which has View All Data and sees every record.)
    private static Id restrictedProfileId() {
        List<Profile> candidates = [SELECT Id, Name FROM Profile WHERE UserType = 'Standard' AND PermissionsViewAllData = false
            AND PermissionsModifyAllData = false WITH SYSTEM_MODE ORDER BY Name];
        System.assert(!candidates.isEmpty(), 'The org needs a standard-licence profile without View All Data.');
        for (Profile candidate : candidates) {
            if (candidate.Name == 'Standard User') {
                return candidate.Id;
            }
        }
        return candidates[0].Id;
    }

    private static User newUser(Id profileId, String lastName, String alias, String unique) {
        return new User(Username = alias + '.' + unique + '@example.invalid', Email = alias + '@example.invalid', LastName = lastName,
            Alias = alias, TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', ProfileId = profileId);
    }

    private static User fixtureUser(String lastName) {
        return [SELECT Id FROM User WHERE LastName = :lastName AND Alias LIKE 'p12f%' WITH SYSTEM_MODE LIMIT 1];
    }

    @IsTest
    static void bothPermissionSetsMakeTheCompanyFeatureTabVisible() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Map<String, String> visibility = new Map<String, String>();
            for (PermissionSetTabSetting tab : [SELECT Parent.Name, Name, Visibility FROM PermissionSetTabSetting
                    WHERE Parent.Name IN ('SAB_Company_Feature_Admin', 'SAB_Company_Feature_User') AND Name = 'Company_Feature__c' WITH SYSTEM_MODE]) {
                visibility.put(tab.Parent.Name, tab.Visibility);
            }
            System.assertEquals('DefaultOn', visibility.get('SAB_Company_Feature_User'), 'Feature users see the Company Feature tab.');
            System.assertEquals('DefaultOn', visibility.get('SAB_Company_Feature_Admin'), 'Feature admins see the Company Feature tab.');
        }
    }

    @IsTest
    static void adminCreatesGrantedUsersReadAndOutsidersSeeNothing() {
        Id companyId = [SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = 'P12F' WITH SYSTEM_MODE].Id;
        Company_Feature__c feature = new Company_Feature__c(Company__c = companyId, Company_Feature_Key__c = 'P12F-PURCHASING',
            Feature_Key__c = 'PURCHASING', Enabled__c = false, Configuration_Status__c = 'Not Configured');
        List<Company_Feature__c> readerRows;
        List<Company_Feature__c> outsiderRows;
        Boolean readerEditRefused = false;
        SABTestGovernor.startTest();
        System.runAs(fixtureUser(ADMIN_NAME)) {
            insert as user feature;
            update as user new Company_Feature__c(Id = feature.Id, Configuration_Status__c = 'In Progress');
        }
        System.runAs(fixtureUser(READER_NAME)) {
            readerRows = [SELECT Id, Feature_Key__c, Enabled__c, Configuration_Status__c FROM Company_Feature__c WITH USER_MODE];
            try {
                update as user new Company_Feature__c(Id = feature.Id, Enabled__c = true);
            } catch (Exception ex) {
                readerEditRefused = true;
            }
        }
        System.runAs(fixtureUser(OUTSIDER_NAME)) {
            outsiderRows = [SELECT Id FROM Company_Feature__c WITH USER_MODE];
        }
        SABTestGovernor.stopTest();
        System.assertEquals(1, readerRows.size(), 'A granted feature user reads the company feature.');
        System.assertEquals('In Progress', readerRows[0].Configuration_Status__c, 'Feature fields are readable.');
        System.assertEquals(true, readerEditRefused, 'Feature users cannot edit features.');
        System.assertEquals(false, [SELECT Enabled__c FROM Company_Feature__c WHERE Id = :feature.Id WITH SYSTEM_MODE].Enabled__c,
            'The refused edit changed nothing.');
        if (Schema.getGlobalDescribe().containsKey('Company_Feature__Share')) {
            System.assertEquals(0, outsiderRows.size(), 'Users without a company grant see no features.');
        }
    }
}
