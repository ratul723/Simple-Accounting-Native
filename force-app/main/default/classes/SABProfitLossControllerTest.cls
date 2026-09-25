@IsTest
private class SABProfitLossControllerTest {

    @IsTest
    static void controllerExposesDefinitionPeriodAndZeroActivityReport() {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c = 'P&L Controller',
                Company_Key__c = 'PLC',
                Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT',
                Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active',
                Is_Active__c = true
            );

        insert company;

        insert new Company_User_Access__c(
            Company__c = company.Id,
            User__c = UserInfo.getUserId(),
            Effective_From__c = Date.today(),
            Grant_Key__c = 'PL-CONTROLLER',
            Is_Active__c = true,
            Role__c = 'Finance Manager'
        );

        Accounting_Period__c period =
            new Accounting_Period__c(
                Name = 'September 2026',
                Company__c = company.Id,
                Company_Period_Key__c = 'CP-PLC',
                Period_Key__c = 'P-PLC',
                Start_Date__c =
                    Date.newInstance(2026, 9, 1),
                End_Date__c =
                    Date.newInstance(2026, 9, 30),
                Fiscal_Year__c = 2026,
                Fiscal_Quarter__c = 3,
                Period_Number__c = 9,
                Status__c = 'Open'
            );

        insert period;

        GL_Account__c revenue =
            new GL_Account__c(
                Name = 'Controller Revenue',
                Company__c = company.Id,
                Company_Account_Key__c =
                    String.valueOf(company.Id) + '-4000',
                Account_Code__c = '4000',
                Account_Type__c = 'Revenue',
                Normal_Balance__c = 'Credit',
                Is_Active__c = true,
                Is_Control_Account__c = false,
                Control_Type__c = 'None',
                Manual_Posting_Allowed__c = true
            );

        insert revenue;

        Report_Definition__c definition =
            new Report_Definition__c(
                Name = 'Controller P&L',
                Company__c = company.Id,
                Definition_Key__c = 'PL|CONTROLLER|V1',
                Effective_From__c =
                    Date.newInstance(2026, 1, 1),
                Report_Type__c = 'P&L',
                Status__c = 'Active',
                Version__c = 1
            );

        insert definition;

        insert new Report_Mapping__c(
            Report_Definition__c = definition.Id,
            GL_Account__c = revenue.Id,
            Row_Key__c = 'REVENUE',
            Group_Key__c = 'REVENUE',
            Sign_Multiplier__c = -1,
            Display_Order__c = 100,
            Effective_From__c =
                Date.newInstance(2026, 1, 1)
        );

        Test.startTest();

        SABProfitLossController.FilterDTO filters =
            SABProfitLossController.getFilters(company.Id);

        SABProfitLossController.ProfitLossDTO report =
            SABProfitLossController.runProfitLoss(
                company.Id,
                definition.Id,
                Date.newInstance(2026, 9, 1),
                Date.newInstance(2026, 9, 30),
                null,
                null,
                null,
                null,
                null
            );

        Test.stopTest();

        System.assertEquals(1, filters.definitions.size());
        System.assertEquals(1, filters.periods.size());
        System.assertEquals(
            Decimal.valueOf('0'),
            report.currentRevenue
        );
        System.assertEquals(
            Decimal.valueOf('0'),
            report.currentExpense
        );
        System.assertEquals(
            Decimal.valueOf('0'),
            report.currentNetProfitLoss
        );
    }
}
