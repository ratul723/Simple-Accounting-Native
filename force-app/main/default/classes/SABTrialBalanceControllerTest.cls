@IsTest
private class SABTrialBalanceControllerTest {

    @IsTest
    static void periodsAndReportAreAvailableForAuthorizedCompany() {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    'TB Controller',
                Company_Key__c =
                    'TC',
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
                UserInfo.getUserId(),
            Effective_From__c =
                Date.today(),
            Grant_Key__c =
                'TB-CONTROLLER',
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
                    'CP-TC',
                Period_Key__c =
                    'P-TC',
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
                    'No Activity Account',
                Company__c =
                    company.Id,
                Company_Account_Key__c =
                    String.valueOf(
                        company.Id
                    )
                    + '-9999',
                Account_Code__c =
                    '9999',
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

        Test.startTest();

        List<SABTrialBalanceController.PeriodOptionDTO> periods =
            SABTrialBalanceController.getPeriods(
                company.Id
            );

        SABTrialBalanceController.TrialBalanceDTO report =
            SABTrialBalanceController.runTrialBalance(
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
                true
            );

        Test.stopTest();

        System.assertEquals(
            1,
            periods.size()
        );

        System.assertEquals(
            period.Id,
            periods[0].value
        );

        System.assertEquals(
            true,
            report.balanced
        );

        System.assertEquals(
            1,
            report.rows.size()
        );

        System.assertEquals(
            account.Id,
            report.rows[0].glAccountId
        );
    }
}
