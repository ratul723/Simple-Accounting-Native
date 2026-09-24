@IsTest
private class SABCompanyContextControllerTest {

    @TestSetup
    static void setupUserAndPermission() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String seed =
            String.valueOf(
                DateTime.now().getTime()
            );

        User u = new User(
            Alias = 'sabctx',
            Email =
                'sabctx.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Context User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username =
                'sabctx.' + seed + '@example.test'
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

    @IsTest
    static void returnsOnlyAuthorizedActiveCompany() {
        User u = contextUser();

        Accounting_Company__c allowedCompany =
            makeCompany(
                'C1',
                'Context Company One'
            );

        makeCompany(
            'C2',
            'Context Company Two'
        );

        grantCompanyAccess(
            allowedCompany.Id,
            u.Id,
            'CTX-ACCESS-1'
        );

        System.runAs(u) {
            Test.startTest();

            List<SABCompanyContextController.CompanyContext>
                companies =
                    SABCompanyContextController.getAccessibleCompanies();

            Test.stopTest();

            System.assertEquals(
                1,
                companies.size()
            );

            System.assertEquals(
                allowedCompany.Id,
                companies[0].companyId
            );

            System.assertEquals(
                'Context Company One',
                companies[0].companyName
            );

            System.assertEquals(
                'BDT',
                companies[0].functionalCurrency
            );
        }
    }

    @IsTest
    static void validatesSelectedCompanyAgainOnServer() {
        User u = contextUser();

        Accounting_Company__c allowedCompany =
            makeCompany(
                'C3',
                'Context Company Three'
            );

        grantCompanyAccess(
            allowedCompany.Id,
            u.Id,
            'CTX-ACCESS-2'
        );

        System.runAs(u) {
            Test.startTest();

            SABCompanyContextController.CompanyContext
                result =
                    SABCompanyContextController.getCompanyContext(
                        allowedCompany.Id
                    );

            Test.stopTest();

            System.assertEquals(
                allowedCompany.Id,
                result.companyId
            );

            System.assertEquals(
                'Context Company Three',
                result.companyName
            );
        }
    }

    @IsTest
    static void unauthorizedCompanyIsRejected() {
        User u = contextUser();

        Accounting_Company__c allowedCompany =
            makeCompany(
                'C4',
                'Context Company Four'
            );

        Accounting_Company__c blockedCompany =
            makeCompany(
                'C5',
                'Context Company Five'
            );

        grantCompanyAccess(
            allowedCompany.Id,
            u.Id,
            'CTX-ACCESS-3'
        );

        System.runAs(u) {
            Boolean thrown = false;

            Test.startTest();

            try {
                SABCompanyContextController.getCompanyContext(
                    blockedCompany.Id
                );
            } catch (AuraHandledException ex) {
                thrown = true;
            }

            Test.stopTest();

            System.assertEquals(
                true,
                thrown
            );
        }
    }

    private static User contextUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB Context User'
            LIMIT 1
        ];
    }

    private static void grantCompanyAccess(
        Id companyId,
        Id userId,
        String grantKey
    ) {
        // Insert the access record in the normal test/system context.
        // CompanyUserAccessTrigger then creates the real Company share for
        // the target user. Do not insert this grant while running as the
        // target user, because that user does not yet have the record access
        // required to create/reconcile the share.
        insert new Company_User_Access__c(
            Company__c = companyId,
            User__c = userId,
            Effective_From__c = Date.today(),
            Grant_Key__c = grantKey,
            Is_Active__c = true,
            Role__c = 'Finance Manager'
        );
    }

    private static Accounting_Company__c makeCompany(
        String keyValue,
        String displayName
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c = displayName,
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
