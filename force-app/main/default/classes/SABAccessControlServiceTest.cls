@IsTest
private class SABAccessControlServiceTest {

    @TestSetup
    static void setupUser() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String uniqueValue =
            'sabaccess.'
            + String.valueOf(
                DateTime.now().getTime()
            );

        User u = new User(
            Alias = 'sabacc',
            Email = uniqueValue + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Access Control User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = uniqueValue + '@example.test'
        );

        insert u;

        PermissionSet adminPermissionSet = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = 'SAB_Remaining_Fields_Admin'
            LIMIT 1
        ];

        insert new PermissionSetAssignment(
            AssigneeId = u.Id,
            PermissionSetId = adminPermissionSet.Id
        );
    }

    private static User targetUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB Access Control User'
            LIMIT 1
        ];
    }

    @IsTest
    static void crudAndFieldChecksPassWithGrantedPermissionSet() {
        User u = targetUser();

        System.runAs(u) {
            SABAccessControlService.assertReadable(
                Accounting_Company__c.SObjectType,
                new List<Schema.SObjectField>{
                    Accounting_Company__c.Company_Key__c,
                    Accounting_Company__c.Functional_Currency__c,
                    Accounting_Company__c.Is_Active__c
                }
            );

            SABAccessControlService.assertUpdateable(
                Accounting_Company__c.SObjectType,
                new List<Schema.SObjectField>{
                    Accounting_Company__c.Is_Active__c
                }
            );

            SABAccessControlService.assertReadable(
                Journal_Entry__c.SObjectType,
                new List<Schema.SObjectField>{
                    Journal_Entry__c.Company__c,
                    Journal_Entry__c.Status__c,
                    Journal_Entry__c.Accounting_Period__c
                }
            );
        }
    }

    @IsTest
    static void companyGrantAndActualSharingBothAllowRead() {
        User u = targetUser();

        Accounting_Company__c company =
            makeCompany('A71');

        insert new Company_User_Access__c(
            Company__c = company.Id,
            User__c = u.Id,
            Effective_From__c = Date.today(),
            Grant_Key__c = 'ACCESS-7A-1',
            Is_Active__c = true,
            Role__c = 'Finance Manager'
        );

        System.runAs(u) {
            SABAccessControlService.assertCompanyAndRecordReadAccess(
                    company.Id,
                    company.Id
                );
        }
    }

    @IsTest
    static void companyAuthorizationDoesNotSubstituteForRecordId() {
        User u = targetUser();

        Accounting_Company__c company =
            makeCompany('A72');

        insert new Company_User_Access__c(
            Company__c = company.Id,
            User__c = u.Id,
            Effective_From__c = Date.today(),
            Grant_Key__c = 'ACCESS-7A-2',
            Is_Active__c = true,
            Role__c = 'Finance Manager'
        );

        System.runAs(u) {
            Boolean thrown = false;

            try {
                SABAccessControlService.assertCompanyAndRecordReadAccess(
                        company.Id,
                        null
                    );
            } catch (Exception ex) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }
    }

    @IsTest
    static void unauthorizedCompanyFailsEvenIfObjectCrudExists() {
        User u = targetUser();

        Accounting_Company__c company =
            makeCompany('A73');

        System.runAs(u) {
            Boolean thrown = false;

            try {
                SABAccessControlService.assertCompanyAndRecordReadAccess(
                        company.Id,
                        company.Id
                    );
            } catch (Exception ex) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }
    }

    @IsTest
    static void nullInputsAreRejected() {
        Boolean objectThrown = false;
        Boolean recordThrown = false;

        try {
            SABAccessControlService.assertObjectAccess(
                null,
                SABAccessControlService.AccessOperation.READ_ACCESS
            );
        } catch (
            SABAccessControlService.AccessDeniedException ex
        ) {
            objectThrown = true;
        }

        try {
            SABAccessControlService.assertRecordReadAccess(
                null
            );
        } catch (
            SABAccessControlService.AccessDeniedException ex
        ) {
            recordThrown = true;
        }

        System.assertEquals(true, objectThrown);
        System.assertEquals(true, recordThrown);
    }

    private static Accounting_Company__c makeCompany(
        String keyValue
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c = 'Access Company ' + keyValue,
                Company_Key__c = keyValue,
                Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT',
                Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active',
                Is_Active__c = true
            );

        insert company;
        return company;
    }
}
