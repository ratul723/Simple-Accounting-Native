/**
 * G13: Budget versus actual.
 *
 * Compares a budget version (default: the company's Approved budget for the year) with posted actuals for the same
 * company, fiscal year and periods. Actuals use the ledger report rules (SABLedgerReportService): journal lines of
 * Posted and Reversed journals (a reversal journal is itself Posted, so reversed activity nets to zero), netted in
 * the account's normal-balance direction (Debit: debit - credit; Credit: credit - debit).
 *
 * Grouping: ACCOUNT, ACCOUNT_DEPARTMENT or ACCOUNT_COST_CENTER. Accounts with actuals but no budget line appear as
 * unbudgeted rows. variance = actual - budget; Revenue is favourable when variance >= 0 and Expense when
 * variance <= 0; balance-sheet accounts carry no favourable flag.
 *
 * Read-only: company grant plus CRUD/FLS read checks, then user-mode queries.
 */
public with sharing class SABBudgetVarianceService {
    public class BudgetVarianceException extends Exception {}

    public static final String BY_ACCOUNT = 'ACCOUNT';
    public static final String BY_DEPARTMENT = 'ACCOUNT_DEPARTMENT';
    public static final String BY_COST_CENTER = 'ACCOUNT_COST_CENTER';
    private static final Set<String> GROUPINGS = new Set<String>{BY_ACCOUNT, BY_DEPARTMENT, BY_COST_CENTER};

    public class VarianceRow {
        @AuraEnabled public Id glAccountId;
        @AuraEnabled public String accountCode;
        @AuraEnabled public String accountName;
        @AuraEnabled public String accountType;
        @AuraEnabled public Id dimensionId;
        @AuraEnabled public String dimensionName;
        @AuraEnabled public Decimal budget;
        @AuraEnabled public Decimal actual;
        @AuraEnabled public Decimal variance;
        @AuraEnabled public Decimal variancePercent;
        @AuraEnabled public Boolean favourable;
        @AuraEnabled public Boolean unbudgeted;
    }

    public class VarianceResult {
        @AuraEnabled public Id budgetId;
        @AuraEnabled public String budgetName;
        @AuraEnabled public Decimal budgetVersion;
        @AuraEnabled public String budgetStatus;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public Integer fiscalYear;
        @AuraEnabled public String groupBy;
        @AuraEnabled public List<VarianceRow> rows;
        @AuraEnabled public Decimal totalRevenueBudget;
        @AuraEnabled public Decimal totalRevenueActual;
        @AuraEnabled public Decimal totalExpenseBudget;
        @AuraEnabled public Decimal totalExpenseActual;
    }

    /**
     * @param budgetId   optional; defaults to the Approved budget of the company and year
     * @param periodIds  optional; defaults to every period of the fiscal year that the budget covers
     */
    @AuraEnabled
    public static VarianceResult getBudgetVsActual(Id companyId, Integer fiscalYear, Id budgetId, List<Id> periodIds, String groupBy) {
        if (companyId == null || fiscalYear == null) {
            throw new BudgetVarianceException('Company and fiscal year are required.');
        }
        String grouping = String.isBlank(groupBy) ? BY_ACCOUNT : groupBy.trim().toUpperCase();
        if (!GROUPINGS.contains(grouping)) {
            throw new BudgetVarianceException('Group by must be ACCOUNT, ACCOUNT_DEPARTMENT or ACCOUNT_COST_CENTER.');
        }
        SABCompanyAccessService.assertCompanyAccess(companyId);
        assertReadAccess();
        Budget__c budget = loadBudget(companyId, fiscalYear, budgetId);
        Set<Id> periods = scopePeriods(companyId, fiscalYear, periodIds);

        Map<String, VarianceRow> rows = new Map<String, VarianceRow>();
        Map<Id, GL_Account__c> accounts = new Map<Id, GL_Account__c>();
        for (Budget_Line__c line : [SELECT GL_Account__c, Department__c, Department__r.Name, Cost_Center__c, Cost_Center__r.Name, Amount__c
                FROM Budget_Line__c WHERE Budget__c = :budget.Id AND Accounting_Period__c IN :periods WITH USER_MODE LIMIT 2001]) {
            Id dimension = dimensionOf(grouping, line.Department__c, line.Cost_Center__c);
            String dimensionName = grouping == BY_DEPARTMENT ? (line.Department__r == null ? null : line.Department__r.Name)
                : (grouping == BY_COST_CENTER ? (line.Cost_Center__r == null ? null : line.Cost_Center__r.Name) : null);
            VarianceRow row = rowFor(rows, line.GL_Account__c, dimension, dimensionName);
            row.budget += line.Amount__c;
            row.unbudgeted = false;
            accounts.put(line.GL_Account__c, null);
        }

        List<AggregateResult> actuals = [SELECT GL_Account__c accountId, Department__c departmentId, Cost_Center__c costCenterId,
            SUM(Debit_Base__c) debitTotal, SUM(Credit_Base__c) creditTotal FROM Journal_Entry_Line__c
            WHERE Journal_Entry__r.Company__c = :companyId AND Journal_Entry__r.Status__c IN ('Posted', 'Reversed')
            AND Journal_Entry__r.Accounting_Period__c IN :periods WITH USER_MODE
            GROUP BY GL_Account__c, Department__c, Cost_Center__c LIMIT 2000];
        for (AggregateResult ar : actuals) {
            accounts.put((Id) ar.get('accountId'), null);
        }
        accounts = new Map<Id, GL_Account__c>([SELECT Id, Account_Code__c, Name, Account_Type__c, Normal_Balance__c FROM GL_Account__c
            WHERE Id IN :accounts.keySet() WITH USER_MODE]);
        Map<Id, String> dimensionNames = dimensionNames(grouping, actuals);
        for (AggregateResult ar : actuals) {
            GL_Account__c account = accounts.get((Id) ar.get('accountId'));
            if (account == null) {
                continue;
            }
            Decimal debit = ar.get('debitTotal') == null ? 0 : (Decimal) ar.get('debitTotal');
            Decimal credit = ar.get('creditTotal') == null ? 0 : (Decimal) ar.get('creditTotal');
            Decimal net = account.Normal_Balance__c == 'Credit' ? credit - debit : debit - credit;
            Id dimension = dimensionOf(grouping, (Id) ar.get('departmentId'), (Id) ar.get('costCenterId'));
            VarianceRow row = rowFor(rows, account.Id, dimension, dimensionNames.get(dimension));
            row.actual += net;
        }

        VarianceResult result = new VarianceResult();
        result.budgetId = budget.Id;
        result.budgetName = budget.Name;
        result.budgetVersion = budget.Version__c;
        result.budgetStatus = budget.Status__c;
        result.currencyCode = budget.Currency__c;
        result.fiscalYear = fiscalYear;
        result.groupBy = grouping;
        result.totalRevenueBudget = 0;
        result.totalRevenueActual = 0;
        result.totalExpenseBudget = 0;
        result.totalExpenseActual = 0;
        result.rows = new List<VarianceRow>();
        for (VarianceRow row : rows.values()) {
            GL_Account__c account = accounts.get(row.glAccountId);
            if (account == null) {
                continue;
            }
            row.accountCode = account.Account_Code__c;
            row.accountName = account.Name;
            row.accountType = account.Account_Type__c;
            row.variance = row.actual - row.budget;
            row.variancePercent = row.budget == 0 ? null : (row.variance * 100 / row.budget.abs()).setScale(2, RoundingMode.HALF_UP);
            row.favourable = row.accountType == 'Revenue' ? row.variance >= 0 : (row.accountType == 'Expense' ? row.variance <= 0 : null);
            if (row.accountType == 'Revenue') {
                result.totalRevenueBudget += row.budget;
                result.totalRevenueActual += row.actual;
            } else if (row.accountType == 'Expense') {
                result.totalExpenseBudget += row.budget;
                result.totalExpenseActual += row.actual;
            }
            result.rows.add(row);
        }
        result.rows.sort(new RowOrder());
        return result;
    }

    // --------------------------------------------------------------- helpers

    private static void assertReadAccess() {
        SABAccessControlService.assertReadable(Budget__c.SObjectType, new List<Schema.SObjectField>{Budget__c.Company__c,
            Budget__c.Fiscal_Year__c, Budget__c.Version__c, Budget__c.Status__c, Budget__c.Currency__c});
        SABAccessControlService.assertReadable(Budget_Line__c.SObjectType, new List<Schema.SObjectField>{Budget_Line__c.GL_Account__c,
            Budget_Line__c.Accounting_Period__c, Budget_Line__c.Department__c, Budget_Line__c.Cost_Center__c, Budget_Line__c.Amount__c});
        SABAccessControlService.assertReadable(Journal_Entry_Line__c.SObjectType, new List<Schema.SObjectField>{
            Journal_Entry_Line__c.GL_Account__c, Journal_Entry_Line__c.Department__c, Journal_Entry_Line__c.Cost_Center__c,
            Journal_Entry_Line__c.Debit_Base__c, Journal_Entry_Line__c.Credit_Base__c});
        SABAccessControlService.assertReadable(GL_Account__c.SObjectType, new List<Schema.SObjectField>{GL_Account__c.Account_Code__c,
            GL_Account__c.Account_Type__c, GL_Account__c.Normal_Balance__c});
    }

    private static Budget__c loadBudget(Id companyId, Integer fiscalYear, Id budgetId) {
        List<Budget__c> rows = budgetId == null
            ? [SELECT Id, Name, Company__c, Fiscal_Year__c, Version__c, Status__c, Currency__c FROM Budget__c WHERE Company__c = :companyId
                AND Fiscal_Year__c = :fiscalYear AND Status__c = 'Approved' WITH USER_MODE LIMIT 2]
            : [SELECT Id, Name, Company__c, Fiscal_Year__c, Version__c, Status__c, Currency__c FROM Budget__c WHERE Id = :budgetId
                WITH USER_MODE];
        if (rows.isEmpty()) {
            throw new BudgetVarianceException(budgetId == null ? 'No Approved budget exists for ' + fiscalYear + '.'
                : 'Budget not found or not accessible.');
        }
        if (rows.size() > 1) {
            throw new BudgetVarianceException('More than one Approved budget exists for ' + fiscalYear + '.');
        }
        if (rows[0].Company__c != companyId || rows[0].Fiscal_Year__c != fiscalYear) {
            throw new BudgetVarianceException('The budget belongs to a different company or fiscal year.');
        }
        return rows[0];
    }

    private static Set<Id> scopePeriods(Id companyId, Integer fiscalYear, List<Id> periodIds) {
        Map<Id, Accounting_Period__c> yearPeriods = new Map<Id, Accounting_Period__c>([SELECT Id FROM Accounting_Period__c
            WHERE Company__c = :companyId AND Fiscal_Year__c = :fiscalYear WITH USER_MODE LIMIT 60]);
        if (periodIds == null || periodIds.isEmpty()) {
            return yearPeriods.keySet();
        }
        Set<Id> requested = new Set<Id>(periodIds);
        if (!yearPeriods.keySet().containsAll(requested)) {
            throw new BudgetVarianceException('Every period must belong to the company\'s fiscal year ' + fiscalYear + '.');
        }
        return requested;
    }

    private static Id dimensionOf(String grouping, Id departmentId, Id costCenterId) {
        return grouping == BY_DEPARTMENT ? departmentId : (grouping == BY_COST_CENTER ? costCenterId : null);
    }

    private static Map<Id, String> dimensionNames(String grouping, List<AggregateResult> actuals) {
        Map<Id, String> names = new Map<Id, String>();
        if (grouping == BY_ACCOUNT) {
            return names;
        }
        Set<Id> ids = new Set<Id>();
        for (AggregateResult ar : actuals) {
            Id dimension = dimensionOf(grouping, (Id) ar.get('departmentId'), (Id) ar.get('costCenterId'));
            if (dimension != null) {
                ids.add(dimension);
            }
        }
        if (grouping == BY_DEPARTMENT) {
            for (Department__c d : [SELECT Id, Name FROM Department__c WHERE Id IN :ids WITH USER_MODE]) {
                names.put(d.Id, d.Name);
            }
        } else {
            for (Cost_Center__c c : [SELECT Id, Name FROM Cost_Center__c WHERE Id IN :ids WITH USER_MODE]) {
                names.put(c.Id, c.Name);
            }
        }
        return names;
    }

    private static VarianceRow rowFor(Map<String, VarianceRow> rows, Id accountId, Id dimensionId, String dimensionName) {
        String key = String.valueOf(accountId) + '|' + String.valueOf(dimensionId);
        if (!rows.containsKey(key)) {
            VarianceRow row = new VarianceRow();
            row.glAccountId = accountId;
            row.dimensionId = dimensionId;
            row.dimensionName = dimensionName;
            row.budget = 0;
            row.actual = 0;
            row.unbudgeted = true;
            rows.put(key, row);
        } else if (rows.get(key).dimensionName == null && dimensionName != null) {
            rows.get(key).dimensionName = dimensionName;
        }
        return rows.get(key);
    }

    private class RowOrder implements System.Comparator<VarianceRow> {
        public Integer compare(VarianceRow a, VarianceRow b) {
            Integer byCode = (a.accountCode == null ? '' : a.accountCode).compareTo(b.accountCode == null ? '' : b.accountCode);
            if (byCode != 0) {
                return byCode;
            }
            return (a.dimensionName == null ? '' : a.dimensionName).compareTo(b.dimensionName == null ? '' : b.dimensionName);
        }
    }
}
