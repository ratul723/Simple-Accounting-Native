@IsTest
private class SABPayrollSummaryControllerTest {

    private static final String KEY = 'G22P';

    @TestSetup
    static void setupData() {
        Accounting_Company__c company = new Accounting_Company__c(Name__c = 'Payroll Summary Co', Company_Key__c = KEY, Country_Code__c = 'BD',
            Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active',
            Is_Active__c = true);
        insert as system company;
        insert as system new Company_User_Access__c(Company__c = company.Id, User__c = UserInfo.getUserId(), Role__c = 'Director', Is_Active__c = true,
            Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'G22P-ACCESS');
        List<Employee__c> employees = new List<Employee__c>{
            new Employee__c(Employee_Reference__c = 'G22P-EMP-1', Status__c = 'Active'),
            new Employee__c(Employee_Reference__c = 'G22P-EMP-2', Status__c = 'Active') };
        insert as system employees;
        List<Employment__c> employments = new List<Employment__c>{
            new Employment__c(Employee__c = employees[0].Id, Company__c = company.Id, Start_Date__c = Date.newInstance(2026, 1, 1), Employment_Status__c = 'Active'),
            new Employment__c(Employee__c = employees[1].Id, Company__c = company.Id, Start_Date__c = Date.newInstance(2026, 1, 1), Employment_Status__c = 'Active') };
        insert as system employments;
        SABPayrollCalculationService.writing = true;
        try {
            Payroll_Run__c september = run(company.Id, 'G22P-SEP', 'Posted', Date.newInstance(2026, 9, 1), 3000);
            Payroll_Run__c october = run(company.Id, 'G22P-OCT', 'Cancelled', Date.newInstance(2026, 10, 1), 0);
            insert as system new List<Payroll_Run__c>{ september, october };
            insert as system new List<Payroll_Line__c>{
                new Payroll_Line__c(Payroll_Run__c = september.Id, Employment__c = employments[0].Id, Gross_Amount__c = 2000, Deduction_Amount__c = 200,
                    Employer_Contribution__c = 100, Net_Amount__c = 1800, Department_Snapshot__c = 'Operations'),
                new Payroll_Line__c(Payroll_Run__c = september.Id, Employment__c = employments[1].Id, Gross_Amount__c = 1000, Deduction_Amount__c = 100,
                    Employer_Contribution__c = 50, Net_Amount__c = 900) };
        } finally {
            SABPayrollCalculationService.writing = false;
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static Payroll_Run__c run(Id companyId, String key, String state, Date starts, Decimal gross) {
        return new Payroll_Run__c(Company__c = companyId, Pay_Period_Start__c = starts, Pay_Period_End__c = starts.addMonths(1).addDays(-1), Currency__c = 'BDT',
            Run_Key__c = key, Version__c = 1, Workflow_State__c = state, Gross_Total__c = gross, Deduction_Total__c = gross / 10, Employer_Total__c = gross / 20,
            Net_Total__c = gross - gross / 10, Accounting_Date__c = starts.addMonths(1).addDays(-1));
    }

    private static Id companyId() {
        return [SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = :KEY WITH SYSTEM_MODE LIMIT 1].Id;
    }

    @IsTest
    static void summaryListsRunsDepartmentsAndCounts() {
        Id companyId = companyId();
        SABPayrollSummaryController.SummaryData latest;
        SABPayrollSummaryController.SummaryData cancelled;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            latest = SABPayrollSummaryController.getSummary(companyId, null);
            Id octoberId = [SELECT Id FROM Payroll_Run__c WHERE Run_Key__c = 'G22P-OCT' WITH SYSTEM_MODE].Id;
            cancelled = SABPayrollSummaryController.getSummary(companyId, octoberId);
            Test.stopTest();
        }
        System.assertEquals('BDT', latest.currencyCode, 'Functional currency.');
        System.assertEquals(SABPermissionService.hasPermission('SAB_View_Payroll_Detail'), latest.canViewDetail, 'Detail flag follows the running user.');
        System.assertEquals(2, latest.runs.size(), 'Both runs are listed.');
        System.assertEquals('G22P-SEP', latest.runs[1].runKey, 'Newest first.');
        System.assertEquals(latest.runs[1].runId, latest.selectedRunId, 'The latest run that is not cancelled is selected.');
        System.assertEquals(2, latest.runs[1].employeeCount, 'Two employees paid.');
        System.assertEquals(2, latest.departments.size(), 'Two departments.');
        System.assertEquals('Operations', latest.departments[0].name, 'Largest department first.');
        System.assertEquals(66.7, latest.departments[0].share, 'Share of gross.');
        System.assertEquals('Unassigned', latest.departments[1].name, 'Blank department is unassigned.');
        System.assertEquals(0, latest.journalLines.size(), 'No posting journal seeded.');
        System.assertEquals(0, cancelled.departments.size(), 'The cancelled run has no lines.');
    }

    @IsTest
    static void accessRulesAreEnforced() {
        String message;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            try {
                SABPayrollSummaryController.getSummary(null, null);
            } catch (AuraHandledException ex) {
                message = ex.getMessage();
            }
            Test.stopTest();
        }
        System.assertEquals('You do not have active access to this Accounting Company.', message, 'A company grant is required.');
    }
}