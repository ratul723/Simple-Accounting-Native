@IsTest
private class SABGeneralLedgerControllerTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    @TestSetup
    static void setupUser() {
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
            Alias = 'sabglui',
            Email =
                'sabglui.' + seed + '@example.test',
            EmailEncodingKey =
                'UTF-8',
            LastName =
                'SAB GL Controller User',
            LanguageLocaleKey =
                'en_US',
            LocaleSidKey =
                'en_US',
            ProfileId =
                p.Id,
            TimeZoneSidKey =
                'Asia/Dhaka',
            Username =
                'sabglui.' + seed + '@example.test'
        );

        insert u;

        PermissionSet ps = [
            SELECT Id
            FROM PermissionSet
            WHERE Name =
                :ADMIN_PERMISSION_SET
            LIMIT 1
        ];

        insert new PermissionSetAssignment(
            AssigneeId =
                u.Id,
            PermissionSetId =
                ps.Id
        );
    }

    @IsTest
    static void filtersAndEmptyAccountReportAreAvailable() {
        User u = [
            SELECT Id
            FROM User
            WHERE LastName =
                'SAB GL Controller User'
            LIMIT 1
        ];

        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    'GL Controller Company',
                Company_Key__c =
                    'GC',
                Country_Code__c =
                    'BD',
                Functional_Currency__c =
                    'BDT',
                Fiscal_Calendar_Type__c =
                    'Calendar',
                Fiscal_Year_Start_Month__c =
                    1,
                Setup_Status__c =
                    'Active',
                Is_Active__c =
                    true
            );

        insert company;

        insert new Company_User_Access__c(
            Company__c =
                company.Id,
            User__c =
                u.Id,
            Effective_From__c =
                Date.today(),
            Grant_Key__c =
                'GL-CONTROLLER',
            Is_Active__c =
                true,
            Role__c =
                'Finance Manager'
        );

        Accounting_Period__c period =
            new Accounting_Period__c(
                Name =
                    'September 2026',
                Company__c =
                    company.Id,
                Company_Period_Key__c =
                    'CP-GC',
                Period_Key__c =
                    'P-GC',
                Start_Date__c =
                    Date.newInstance(
                        2026,
                        9,
                        1
                    ),
                End_Date__c =
                    Date.newInstance(
                        2026,
                        9,
                        30
                    ),
                Fiscal_Year__c =
                    2026,
                Fiscal_Quarter__c =
                    3,
                Period_Number__c =
                    9,
                Status__c =
                    'Open'
            );

        insert period;

        GL_Account__c account =
            new GL_Account__c(
                Name =
                    'Controller Account',
                Company__c =
                    company.Id,
                Company_Account_Key__c =
                    String.valueOf(
                        company.Id
                    )
                    + '-7000',
                Account_Code__c =
                    '7000',
                Account_Type__c =
                    'Expense',
                Normal_Balance__c =
                    'Debit',
                Is_Active__c =
                    true,
                Is_Control_Account__c =
                    false,
                Control_Type__c =
                    'None',
                Manual_Posting_Allowed__c =
                    true
            );

        insert account;

        System.runAs(u) {
            Test.startTest();

            SABGeneralLedgerController.FilterDTO filters =
                SABGeneralLedgerController.getFilters(
                    company.Id
                );

            SABGeneralLedgerController.GeneralLedgerDTO report =
                SABGeneralLedgerController.runGeneralLedger(
                    company.Id,
                    Date.newInstance(
                        2026,
                        9,
                        1
                    ),
                    Date.newInstance(
                        2026,
                        9,
                        30
                    ),
                    account.Id
                );

            Test.stopTest();

            System.assertEquals(
                1,
                filters.periods.size()
            );

            System.assertEquals(
                1,
                filters.accounts.size()
            );

            System.assertEquals(
                account.Id,
                filters.accounts[0].value
            );

            System.assertEquals(
                1,
                report.accounts.size()
            );

            System.assertEquals(
                account.Id,
                report.accounts[0].glAccountId
            );

            System.assertEquals(
                0,
                report.accounts[0].movementLineCount
            );
        }
    }
}
