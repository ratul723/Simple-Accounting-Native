@IsTest
private class SABBudgetVarianceServiceTest {

    @TestSetup
    static void setupData() {
        SABBudgetTestFixture.createFixture();
        // Approved FY2026 budget: Oct sales 1,200; Oct supplies (Sales dept) 250; Nov supplies 100.
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.APPROVER)) {
            SABBudgetTestFixture.seedBudget('Approved', 1, new List<List<Object>>{
                new List<Object>{'B13-2026-10', '4000', null, (Decimal) 1200},
                new List<Object>{'B13-2026-10', '6000', 'SAL', (Decimal) 250},
                new List<Object>{'B13-2026-11', '6000', null, (Decimal) 100}});
        }
    }

    private static Map<String, SABBudgetVarianceService.VarianceRow> byKey(SABBudgetVarianceService.VarianceResult result) {
        Map<String, SABBudgetVarianceService.VarianceRow> rows = new Map<String, SABBudgetVarianceService.VarianceRow>();
        for (SABBudgetVarianceService.VarianceRow row : result.rows) {
            rows.put(row.accountCode + (row.dimensionName == null ? '' : '|' + row.dimensionName), row);
        }
        return rows;
    }

    @IsTest
    static void comparesTheApprovedBudgetWithPostedActualsByAccount() {
        SABBudgetVarianceService.VarianceResult result;
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.PLANNER)) {
            SABTestGovernor.startTest();
            result = SABBudgetVarianceService.getBudgetVsActual(SABBudgetTestFixture.companyId(), 2026, null, null, null);
            SABTestGovernor.stopTest();
        }
        Map<String, SABBudgetVarianceService.VarianceRow> rows = byKey(result);
        System.assertEquals('Approved', result.budgetStatus, 'Defaults to the Approved budget.');
        System.assertEquals('ACCOUNT', result.groupBy, 'Defaults to account grouping.');
        SABBudgetVarianceService.VarianceRow sales = rows.get('4000');
        System.assertEquals(1200, sales.budget, 'Sales budget.');
        System.assertEquals(1000, sales.actual, 'Sales actual is the credit balance.');
        System.assertEquals(-200, sales.variance, 'Sales under budget.');
        System.assertEquals(-16.67, sales.variancePercent, 'Variance percent.');
        System.assertEquals(false, sales.favourable, 'Revenue below budget is unfavourable.');
        SABBudgetVarianceService.VarianceRow supplies = rows.get('6000');
        System.assertEquals(350, supplies.budget, 'Supplies budget across both periods.');
        System.assertEquals(300, supplies.actual, 'The Draft journal of 999 is excluded.');
        System.assertEquals(true, supplies.favourable, 'Expense below budget is favourable.');
        SABBudgetVarianceService.VarianceRow bank = rows.get('1100');
        System.assertEquals(true, bank.unbudgeted, 'Accounts with actuals but no budget appear as unbudgeted.');
        System.assertEquals(700, bank.actual, 'Bank actual is the debit balance.');
        System.assertEquals(null, bank.favourable, 'Balance-sheet accounts carry no favourable flag.');
        System.assertEquals(1000, result.totalRevenueActual, 'Revenue total.');
        System.assertEquals(350, result.totalExpenseBudget, 'Expense budget total.');
        System.assertEquals('1100', result.rows[0].accountCode, 'Rows are ordered by account code.');
    }

    @IsTest
    static void filtersPeriodsAndGroupsByDepartment() {
        SABBudgetVarianceService.VarianceResult october;
        SABBudgetVarianceService.VarianceResult byDepartment;
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.APPROVER)) {
            SABTestGovernor.startTest();
            october = SABBudgetVarianceService.getBudgetVsActual(SABBudgetTestFixture.companyId(), 2026, null,
                new List<Id>{SABBudgetTestFixture.periodId('B13-2026-10')}, 'account');
            byDepartment = SABBudgetVarianceService.getBudgetVsActual(SABBudgetTestFixture.companyId(), 2026, null, null, 'ACCOUNT_DEPARTMENT');
            SABTestGovernor.stopTest();
        }
        SABBudgetVarianceService.VarianceRow octSupplies = byKey(october).get('6000');
        System.assertEquals(250, octSupplies.budget, 'Only the October budget line.');
        System.assertEquals(50, octSupplies.variance, 'October supplies over budget.');
        System.assertEquals(false, octSupplies.favourable, 'Expense over budget is unfavourable.');
        Map<String, SABBudgetVarianceService.VarianceRow> departments = byKey(byDepartment);
        System.assertEquals(250, departments.get('6000|Sales').budget, 'Sales department budget.');
        System.assertEquals(300, departments.get('6000|Sales').actual, 'Sales department actual.');
        System.assertEquals(100, departments.get('6000').budget, 'Budget without a department stays on its own row.');
        System.assertEquals(0, departments.get('6000').actual, 'No undepartmented supplies actuals.');
    }

    @IsTest
    static void refusesInvalidRequestsAndUsersWithoutAGrant() {
        List<String> messages = new List<String>();
        Id companyId = SABBudgetTestFixture.companyId();
        SABTestGovernor.startTest();
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.PLANNER)) {
            for (Integer i = 0; i < 4; i++) {
                try {
                    if (i == 0) {
                        SABBudgetVarianceService.getBudgetVsActual(companyId, 2025, null, null, null);
                    } else if (i == 1) {
                        SABBudgetVarianceService.getBudgetVsActual(companyId, 2026, null, null, 'PROJECT');
                    } else if (i == 2) {
                        SABBudgetVarianceService.getBudgetVsActual(companyId, 2026, null,
                            new List<Id>{SABBudgetTestFixture.periodId('B13-2025-12')}, null);
                    } else {
                        SABBudgetVarianceService.getBudgetVsActual(null, 2026, null, null, null);
                    }
                } catch (SABBudgetVarianceService.BudgetVarianceException ex) {
                    messages.add(ex.getMessage());
                }
            }
        }
        Boolean outsiderDenied = false;
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.OUTSIDER)) {
            try {
                SABBudgetVarianceService.getBudgetVsActual(companyId, 2026, null, null, null);
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                outsiderDenied = true;
            }
        }
        SABTestGovernor.stopTest();
        List<String> fragments = new List<String>{'No Approved budget exists for 2025', 'Group by must be', 'fiscal year 2026', 'are required'};
        System.assertEquals(fragments.size(), messages.size(), 'Every invalid request was refused.');
        for (Integer i = 0; i < fragments.size(); i++) {
            System.assert(messages[i].contains(fragments[i]), 'Expected "' + fragments[i] + '" but got: ' + messages[i]);
        }
        System.assertEquals(true, outsiderDenied, 'Users without a company grant cannot read budgets or actuals.');
    }
}
