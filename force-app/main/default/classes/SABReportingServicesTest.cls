@IsTest
private class SABReportingServicesTest {

    @TestSetup
    static void setupData() {
        SABReportingTestFixture.createFixture();
    }

    private static Map<String, SABCashFlowService.Section> sections(SABCashFlowService.CashFlowStatement s) {
        Map<String, SABCashFlowService.Section> result = new Map<String, SABCashFlowService.Section>();
        for (SABCashFlowService.Section section : s.sections) {
            result.put(section.name, section);
        }
        return result;
    }

    @IsTest
    static void cashFlowClassifiesEveryCashMovementAndReconciles() {
        SABCashFlowService.CashFlowStatement s;
        System.runAs(SABReportingTestFixture.user(SABReportingTestFixture.VIEWER)) {
            SABTestGovernor.startTest();
            s = SABCashFlowService.getCashFlow(SABReportingTestFixture.companyId(), Date.newInstance(2026, 2, 1), Date.newInstance(2026, 3, 31));
            SABTestGovernor.stopTest();
        }
        Map<String, SABCashFlowService.Section> bySection = sections(s);
        System.assertEquals(400, bySection.get('Operating').total, 'Sales 500 - expenses 200 + receivable collected 100.');
        System.assertEquals(-400, bySection.get('Investing').total, 'Equipment bought.');
        System.assertEquals(600, bySection.get('Financing').total, 'Loan drawn.');
        System.assertEquals(600, s.netChange, 'Net change in cash.');
        System.assertEquals(1000, s.openingCash, 'Cash before February.');
        System.assertEquals(1600, s.closingCash, 'Opening plus net change.');
        System.assertEquals(true, s.reconciled, 'Matches the cash ledger at 31 March.');
        Map<String, Decimal> operating = new Map<String, Decimal>();
        for (SABCashFlowService.Line l : bySection.get('Operating').lines) {
            operating.put(l.accountCode, l.amount);
        }
        System.assertEquals(500, operating.get('4000'), 'Cash sales.');
        System.assertEquals(-200, operating.get('6000'), 'Cash expenses.');
        System.assertEquals(100, operating.get('1200'), 'Receivable collected.');
        System.assertEquals(false, operating.containsKey('2100'), 'Non-cash journals are ignored.');
        System.assertEquals(1, [SELECT COUNT() FROM Report_Run__c WHERE Report_Type__c = 'Cash Flow' WITH SYSTEM_MODE], 'The run is logged.');
    }

    @IsTest
    static void dashboardReportsBalancesPeriodsTrendAndBudget() {
        Budget__c budget = new Budget__c(Name = 'R21 FY2026', Company__c = SABReportingTestFixture.companyId(), Fiscal_Year__c = 2026, Version__c = 1,
            Currency__c = 'USD', Status__c = 'Approved', Budget_Key__c = 'R21|2026|V1');
        SABBudgetGuard.beginWrite();
        try {
            insert as system budget;
            Id jan = [SELECT Id FROM Accounting_Period__c WHERE Company_Period_Key__c = 'R21-2026-01' WITH SYSTEM_MODE].Id;
            insert as system new List<Budget_Line__c>{
                new Budget_Line__c(Budget__c = budget.Id, Accounting_Period__c = jan, GL_Account__c = SABReportingTestFixture.accountId('4000'), Amount__c = 1000,
                    Line_Key__c = 'R21-B-4000'),
                new Budget_Line__c(Budget__c = budget.Id, Accounting_Period__c = jan, GL_Account__c = SABReportingTestFixture.accountId('6000'), Amount__c = 300,
                    Line_Key__c = 'R21-B-6000')};
        } finally {
            SABBudgetGuard.endWrite();
        }
        SABManagementDashboardService.Dashboard d;
        System.runAs(SABReportingTestFixture.user(SABReportingTestFixture.VIEWER)) {
            SABTestGovernor.startTest();
            d = SABManagementDashboardService.getDashboard(SABReportingTestFixture.companyId(), Date.newInstance(2026, 3, 31));
            SABTestGovernor.stopTest();
        }
        System.assertEquals(1600, d.cashBalance, 'Cash at 31 March.');
        System.assertEquals(200, d.receivables, 'Receivables 300 less 100 collected.');
        System.assertEquals(150, d.payables, 'Payables as a positive credit balance.');
        System.assertEquals(0, d.revenueMonthToDate, 'No March revenue.');
        System.assertEquals(150, d.expenseMonthToDate, 'March expenses.');
        System.assertEquals(-150, d.netMonthToDate, 'March net.');
        System.assertEquals(800, d.revenueYearToDate, 'Revenue since 1 January.');
        System.assertEquals(350, d.expenseYearToDate, 'Expenses since 1 January.');
        System.assertEquals(450, d.netYearToDate, 'Net income year to date.');
        System.assertEquals(Date.newInstance(2026, 1, 1), d.yearStart, 'Fiscal year starts in January.');
        System.assertEquals(1000, d.budgetRevenueYearToDate, 'Approved budget revenue to date.');
        System.assertEquals(300, d.budgetExpenseYearToDate, 'Approved budget expense to date.');
        System.assertEquals(12, d.trend.size(), 'Twelve months.');
        System.assertEquals(800, d.trend[10].revenue, 'February revenue in the trend.');
        System.assertEquals(-150, d.trend[11].net, 'March net in the trend.');
    }

    @IsTest
    static void refusesUsersWithoutPermissionOrGrantAndBadRanges() {
        List<String> refused = new List<String>();
        Id companyId = SABReportingTestFixture.companyId();
        SABTestGovernor.startTest();
        System.runAs(SABReportingTestFixture.user(SABReportingTestFixture.NOVIEW)) {
            try {
                SABManagementDashboardService.getDashboard(companyId, null);
            } catch (SABPermissionService.PermissionDeniedException ex) {
                refused.add('no-permission');
            }
        }
        System.runAs(SABReportingTestFixture.user(SABReportingTestFixture.OUTSIDER)) {
            try {
                SABCashFlowService.getCashFlow(companyId, Date.newInstance(2026, 1, 1), Date.newInstance(2026, 1, 31));
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                refused.add('no-grant');
            }
        }
        System.runAs(SABReportingTestFixture.user(SABReportingTestFixture.VIEWER)) {
            try {
                SABCashFlowService.getCashFlow(companyId, Date.newInstance(2026, 3, 1), Date.newInstance(2026, 2, 1));
            } catch (SABCashFlowService.CashFlowException ex) {
                refused.add('bad-range');
            }
            try {
                SABReportSupport.authorize(null);
            } catch (SABReportSupport.ReportException ex) {
                refused.add('no-company');
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals(new List<String>{'no-permission', 'no-grant', 'bad-range', 'no-company'}, refused, 'Refused requests.');
    }
}
