/**
 * G21: Management dashboard.
 *
 * As of a date: cash balance (cash accounts as in SABCashFlowService), receivables (AR control accounts, debit balance)
 * and payables (AP control accounts, credit balance); revenue, expenses and net income month-to-date and fiscal
 * year-to-date (fiscal year from Accounting_Company__c.Fiscal_Year_Start_Month__c); a 12-month revenue / expense / net
 * trend; and year-to-date budget for revenue and expense from the Approved budget (G13) when one exists.
 * Ledger figures use Posted and Reversed journals by accounting date. Each run is logged in Report_Run__c.
 */
public with sharing class SABManagementDashboardService {
    public class MonthPoint {
        @AuraEnabled public String label;
        @AuraEnabled public Integer year;
        @AuraEnabled public Integer month;
        @AuraEnabled public Decimal revenue = 0;
        @AuraEnabled public Decimal expense = 0;
        @AuraEnabled public Decimal net = 0;
    }

    public class RunSummary {
        @AuraEnabled public String reportType;
        @AuraEnabled public Datetime generatedAt;
        @AuraEnabled public String generatedByName;
    }

    public class Dashboard {
        @AuraEnabled public Date asOfDate;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public Decimal cashBalance = 0;
        @AuraEnabled public Decimal receivables = 0;
        @AuraEnabled public Decimal payables = 0;
        @AuraEnabled public Decimal revenueMonthToDate = 0;
        @AuraEnabled public Decimal expenseMonthToDate = 0;
        @AuraEnabled public Decimal netMonthToDate = 0;
        @AuraEnabled public Decimal revenueYearToDate = 0;
        @AuraEnabled public Decimal expenseYearToDate = 0;
        @AuraEnabled public Decimal netYearToDate = 0;
        @AuraEnabled public Decimal budgetRevenueYearToDate;
        @AuraEnabled public Decimal budgetExpenseYearToDate;
        @AuraEnabled public Date yearStart;
        @AuraEnabled public List<MonthPoint> trend = new List<MonthPoint>();
        @AuraEnabled public List<RunSummary> recentRuns = new List<RunSummary>();
    }

    @AuraEnabled
    public static Dashboard getDashboard(Id companyId, Date asOfDate) {
        SABReportSupport.authorize(companyId);
        Date asOf = asOfDate == null ? Date.today() : asOfDate;
        Store store = new Store();
        Accounting_Company__c company = store.company(companyId);
        Dashboard d = new Dashboard();
        d.asOfDate = asOf;
        d.currencyCode = company.Functional_Currency__c;
        Set<Id> cash = SABReportSupport.cashAccounts(companyId);
        d.cashBalance = cash.isEmpty() ? 0 : store.balance(companyId, cash, null, asOf, false);
        d.receivables = store.balance(companyId, null, 'AR', asOf, false);
        d.payables = store.balance(companyId, null, 'AP', asOf, true);
        Integer startMonth = company.Fiscal_Year_Start_Month__c == null ? 1 : company.Fiscal_Year_Start_Month__c.intValue();
        d.yearStart = Date.newInstance(asOf.month() >= startMonth ? asOf.year() : asOf.year() - 1, startMonth, 1);
        Date monthStart = asOf.toStartOfMonth();
        Date trendStart = monthStart.addMonths(-11);
        Map<String, MonthPoint> points = new Map<String, MonthPoint>();
        for (Integer i = 0; i < 12; i++) {
            Date m = trendStart.addMonths(i);
            MonthPoint p = new MonthPoint();
            p.year = m.year();
            p.month = m.month();
            p.label = Datetime.newInstance(m.year(), m.month(), 1).format('MMM yyyy');
            points.put(m.year() + '-' + m.month(), p);
            d.trend.add(p);
        }
        Date earliest = trendStart < d.yearStart ? trendStart : d.yearStart;
        for (AggregateResult ar : store.incomeByMonth(companyId, earliest, asOf)) {
            Integer year = (Integer) ar.get('y');
            Integer month = (Integer) ar.get('m');
            String type = (String) ar.get('accountType');
            Decimal debit = nz((Decimal) ar.get('debitTotal'));
            Decimal credit = nz((Decimal) ar.get('creditTotal'));
            Decimal revenue = type == 'Revenue' ? credit - debit : 0;
            Decimal expense = type == 'Expense' ? debit - credit : 0;
            Date first = Date.newInstance(year, month, 1);
            if (first >= d.yearStart) {
                d.revenueYearToDate += revenue;
                d.expenseYearToDate += expense;
            }
            if (first == monthStart) {
                d.revenueMonthToDate += revenue;
                d.expenseMonthToDate += expense;
            }
            MonthPoint p = points.get(year + '-' + month);
            if (p != null) {
                p.revenue += revenue;
                p.expense += expense;
            }
        }
        for (MonthPoint p : d.trend) {
            p.net = p.revenue - p.expense;
        }
        d.netMonthToDate = d.revenueMonthToDate - d.expenseMonthToDate;
        d.netYearToDate = d.revenueYearToDate - d.expenseYearToDate;
        for (AggregateResult ar : store.budgetToDate(companyId, d.yearStart, asOf)) {
            String type = (String) ar.get('accountType');
            Decimal amount = nz((Decimal) ar.get('amountTotal'));
            if (type == 'Revenue') {
                d.budgetRevenueYearToDate = nz(d.budgetRevenueYearToDate) + amount;
            } else if (type == 'Expense') {
                d.budgetExpenseYearToDate = nz(d.budgetExpenseYearToDate) + amount;
            }
        }
        for (Report_Run__c r : store.recentRuns(companyId)) {
            RunSummary s = new RunSummary();
            s.reportType = r.Report_Type__c;
            s.generatedAt = r.Generated_At__c;
            s.generatedByName = r.Generated_By__r == null ? null : r.Generated_By__r.Name;
            d.recentRuns.add(s);
        }
        SABReportSupport.logRun(companyId, 'Management Dashboard', new Map<String, Object>{'asOfDate' => asOf}, d);
        return d;
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }

    /** Ledger, budget and run-log reads after SABReportSupport.authorize (permission and company grant). */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Accounting_Company__c company(Id companyId) {
            return [SELECT Id, Functional_Currency__c, Fiscal_Year_Start_Month__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE];
        }
        /** Balance as of a date for a set of accounts or a control type; creditPositive flips the sign for liabilities. */
        Decimal balance(Id companyId, Set<Id> accounts, String controlType, Date asOf, Boolean creditPositive) {
            AggregateResult ar = accounts != null
                ? [SELECT SUM(Debit_Base__c) debitTotal, SUM(Credit_Base__c) creditTotal FROM Journal_Entry_Line__c WHERE GL_Account__c IN :accounts
                    AND Journal_Entry__r.Company__c = :companyId AND Journal_Entry__r.Status__c IN ('Posted', 'Reversed')
                    AND Journal_Entry__r.Accounting_Date__c <= :asOf WITH SYSTEM_MODE]
                : [SELECT SUM(Debit_Base__c) debitTotal, SUM(Credit_Base__c) creditTotal FROM Journal_Entry_Line__c
                    WHERE GL_Account__r.Control_Type__c = :controlType AND Journal_Entry__r.Company__c = :companyId
                    AND Journal_Entry__r.Status__c IN ('Posted', 'Reversed') AND Journal_Entry__r.Accounting_Date__c <= :asOf WITH SYSTEM_MODE];
            Decimal net = nz((Decimal) ar.get('debitTotal')) - nz((Decimal) ar.get('creditTotal'));
            return creditPositive ? -net : net;
        }
        List<AggregateResult> incomeByMonth(Id companyId, Date fromDate, Date toDate) {
            return [SELECT CALENDAR_YEAR(Journal_Entry__r.Accounting_Date__c) y, CALENDAR_MONTH(Journal_Entry__r.Accounting_Date__c) m,
                GL_Account__r.Account_Type__c accountType, SUM(Debit_Base__c) debitTotal, SUM(Credit_Base__c) creditTotal FROM Journal_Entry_Line__c
                WHERE Journal_Entry__r.Company__c = :companyId AND Journal_Entry__r.Status__c IN ('Posted', 'Reversed')
                AND Journal_Entry__r.Accounting_Date__c >= :fromDate AND Journal_Entry__r.Accounting_Date__c <= :toDate
                AND GL_Account__r.Account_Type__c IN ('Revenue', 'Expense') WITH SYSTEM_MODE
                GROUP BY CALENDAR_YEAR(Journal_Entry__r.Accounting_Date__c), CALENDAR_MONTH(Journal_Entry__r.Accounting_Date__c),
                GL_Account__r.Account_Type__c LIMIT 2000];
        }
        List<AggregateResult> budgetToDate(Id companyId, Date fromDate, Date toDate) {
            return [SELECT GL_Account__r.Account_Type__c accountType, SUM(Amount__c) amountTotal FROM Budget_Line__c
                WHERE Budget__r.Company__c = :companyId AND Budget__r.Status__c = 'Approved' AND Accounting_Period__r.Start_Date__c >= :fromDate
                AND Accounting_Period__r.End_Date__c <= :toDate AND GL_Account__r.Account_Type__c IN ('Revenue', 'Expense') WITH SYSTEM_MODE
                GROUP BY GL_Account__r.Account_Type__c];
        }
        List<Report_Run__c> recentRuns(Id companyId) {
            return [SELECT Report_Type__c, Generated_At__c, Generated_By__r.Name FROM Report_Run__c WHERE Company__c = :companyId WITH SYSTEM_MODE
                ORDER BY Generated_At__c DESC LIMIT 10];
        }
    }
}
