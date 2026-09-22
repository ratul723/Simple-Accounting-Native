@IsTest
private class SABCompanyAccessServiceTest {
    private static Accounting_Company__c makeCompany(String keyValue) {
        Accounting_Company__c company = new Accounting_Company__c(
            Name__c = 'Test Company ' + keyValue, 
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

    private static User makeUser() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String token = String.valueOf(DateTime.now().getTime());

        User u = new User(
            Alias = 'sabusr',
            Email = 'sab.' + token + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Access Test',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = 'sab.' + token + '@example.test'
        );
        insert u;
        return u;
    }

    @IsTest
    static void activeGrantAllowsCompanyAndReturnsRole() {
        Accounting_Company__c company = makeCompany('COMP-ACCESS-1');
        Accounting_Company__c otherCompany = makeCompany('COMP-ACCESS-2');
        User u = makeUser();

        insert new Company_User_Access__c(
            Company__c = company.Id,
            User__c = u.Id,
            Effective_From__c = Date.today().addDays(-1),
            Effective_To__c = null,
            Grant_Key__c = 'GRANT-' + u.Id + '-' + company.Id,
            Is_Active__c = true,
            Role__c = 'Bookkeeper'
        );

        System.runAs(u) {
            System.assertEquals(
                true,
                SABCompanyAccessService.hasCompanyAccess(company.Id)
            );
            System.assertEquals(
                false,
                SABCompanyAccessService.hasCompanyAccess(otherCompany.Id)
            );
            System.assertEquals(
                'Bookkeeper',
                SABCompanyAccessService.getCompanyRole(company.Id)
            );
            System.assert(
                SABCompanyAccessService.getAccessibleCompanyIds().contains(company.Id)
            );
        }
    }

    @IsTest
    static void expiredOrInactiveGrantDoesNotAllowAccess() {
        Accounting_Company__c expiredCompany = makeCompany('COMP-EXPIRED');
        Accounting_Company__c inactiveCompany = makeCompany('COMP-INACTIVE');
        User u = makeUser();

        insert new List<Company_User_Access__c>{
            new Company_User_Access__c(
                Company__c = expiredCompany.Id,
                User__c = u.Id,
                Effective_From__c = Date.today().addDays(-10),
                Effective_To__c = Date.today().addDays(-1),
                Grant_Key__c = 'GRANT-EXPIRED-' + u.Id,
                Is_Active__c = true,
                Role__c = 'Bookkeeper'
            ),
            new Company_User_Access__c(
                Company__c = inactiveCompany.Id,
                User__c = u.Id,
                Effective_From__c = Date.today().addDays(-1),
                Grant_Key__c = 'GRANT-INACTIVE-' + u.Id,
                Is_Active__c = false,
                Role__c = 'Bookkeeper'
            )
        };

        System.runAs(u) {
            System.assertEquals(
                false,
                SABCompanyAccessService.hasCompanyAccess(expiredCompany.Id)
            );
            System.assertEquals(
                false,
                SABCompanyAccessService.hasCompanyAccess(inactiveCompany.Id)
            );
        }
    }

    @IsTest
    static void assertAccessThrowsForUnauthorizedCompany() {
        Accounting_Company__c company = makeCompany('COMP-NO-ACCESS');
        User u = makeUser();

        System.runAs(u) {
            Boolean thrown = false;
            try {
                SABCompanyAccessService.assertCompanyAccess(company.Id);
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                thrown = true;
            }
            System.assertEquals(true, thrown);
        }
    }
}