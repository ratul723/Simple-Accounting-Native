/**
 * G22G-5: aggregate payroll read model for the redesigned People and payroll workspace.
 *
 * Returns run totals, the employee count per run, gross cost by department and the posting journal by account. No
 * employee-level amounts are returned, so finance users and directors without SAB_View_Payroll_Detail see payroll cost
 * the way the Harbourline demo shows it ("Directors see aggregate payroll cost"). Employee lines, payments and every
 * action stay with SABPayrollWorkspaceController and the payroll services, which require the detail permission.
 *
 * Reads run in user mode after the company grant check; a user without read access to payroll runs is refused.
 */
public with sharing class SABPayrollSummaryController {

    private static final Integer RUN_LIMIT = 100;
    private static final String VIEW_DETAIL = 'SAB_View_Payroll_Detail';

    public class SummaryData {
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Boolean canViewDetail { get; set; }
        @AuraEnabled public Id selectedRunId { get; set; }
        @AuraEnabled public List<RunRow> runs { get; set; }
        @AuraEnabled public List<DepartmentRow> departments { get; set; }
        @AuraEnabled public List<JournalRow> journalLines { get; set; }
        @AuraEnabled public String journalName { get; set; }
        @AuraEnabled public Id journalId { get; set; }
        @AuraEnabled public Datetime postedAt { get; set; }
        @AuraEnabled public String postedBy { get; set; }
    }

    public class RunRow {
        @AuraEnabled public Id runId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String runKey { get; set; }
        @AuraEnabled public Date periodStart { get; set; }
        @AuraEnabled public Date periodEnd { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String state { get; set; }
        @AuraEnabled public Decimal grossTotal { get; set; }
        @AuraEnabled public Decimal deductionTotal { get; set; }
        @AuraEnabled public Decimal employerTotal { get; set; }
        @AuraEnabled public Decimal netTotal { get; set; }
        @AuraEnabled public Decimal settledAmount { get; set; }
        @AuraEnabled public Integer employeeCount { get; set; }
    }

    public class DepartmentRow {
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public Decimal gross { get; set; }
        @AuraEnabled public Decimal share { get; set; }
    }

    public class JournalRow {
        @AuraEnabled public String accountCode { get; set; }
        @AuraEnabled public String accountName { get; set; }
        @AuraEnabled public Decimal debit { get; set; }
        @AuraEnabled public Decimal credit { get; set; }
    }

    @AuraEnabled
    public static SummaryData getSummary(Id companyId, Id runId) {
        if (companyId == null || !SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw auraError('You do not have active access to this Accounting Company.');
        }
        if (!Schema.SObjectType.Payroll_Run__c.isAccessible()) {
            throw auraError('You do not have access to payroll runs.');
        }
        try {
            SummaryData data = new SummaryData();
            data.currencyCode = [SELECT Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH USER_MODE LIMIT 1].Functional_Currency__c;
            data.canViewDetail = SABPermissionService.hasPermission(VIEW_DETAIL);
            data.runs = runs(companyId);
            data.departments = new List<DepartmentRow>();
            data.journalLines = new List<JournalRow>();
            RunRow selected = pick(data.runs, runId);
            if (selected == null) {
                return data;
            }
            data.selectedRunId = selected.runId;
            data.departments = departments(selected);
            loadJournal(data, selected.runId);
            return data;
        } catch (QueryException ex) {
            throw auraError('Payroll could not be loaded: ' + ex.getMessage());
        }
    }

    private static List<RunRow> runs(Id companyId) {
        Map<Id, RunRow> byId = new Map<Id, RunRow>();
        List<RunRow> rows = new List<RunRow>();
        for (Payroll_Run__c run : [
            SELECT Id, Name, Run_Key__c, Pay_Period_Start__c, Pay_Period_End__c, Accounting_Date__c, Workflow_State__c, Gross_Total__c,
                   Deduction_Total__c, Employer_Total__c, Net_Total__c, Settled_Amount__c
            FROM Payroll_Run__c
            WHERE Company__c = :companyId
            WITH USER_MODE
            ORDER BY Pay_Period_Start__c DESC, Name DESC
            LIMIT :RUN_LIMIT
        ]) {
            RunRow row = new RunRow();
            row.runId = run.Id;
            row.name = run.Name;
            row.runKey = run.Run_Key__c;
            row.periodStart = run.Pay_Period_Start__c;
            row.periodEnd = run.Pay_Period_End__c;
            row.accountingDate = run.Accounting_Date__c;
            row.state = run.Workflow_State__c;
            row.grossTotal = zero(run.Gross_Total__c);
            row.deductionTotal = zero(run.Deduction_Total__c);
            row.employerTotal = zero(run.Employer_Total__c);
            row.netTotal = zero(run.Net_Total__c);
            row.settledAmount = zero(run.Settled_Amount__c);
            row.employeeCount = 0;
            byId.put(run.Id, row);
            rows.add(row);
        }
        if (byId.isEmpty() || !Schema.SObjectType.Payroll_Line__c.isAccessible()) {
            return rows;
        }
        Set<Id> runIds = byId.keySet();
        for (AggregateResult agg : [
            SELECT Payroll_Run__c runId, COUNT(Id) lineCount
            FROM Payroll_Line__c
            WHERE Payroll_Run__c IN :runIds
            WITH USER_MODE
            GROUP BY Payroll_Run__c
        ]) {
            byId.get((Id) agg.get('runId')).employeeCount = (Integer) agg.get('lineCount');
        }
        return rows;
    }

    private static RunRow pick(List<RunRow> rows, Id runId) {
        for (RunRow row : rows) {
            if (row.runId == runId) {
                return row;
            }
        }
        for (RunRow row : rows) {
            if (row.state != 'Cancelled') {
                return row;
            }
        }
        return rows.isEmpty() ? null : rows[0];
    }

    private static List<DepartmentRow> departments(RunRow run) {
        List<DepartmentRow> rows = new List<DepartmentRow>();
        if (!Schema.SObjectType.Payroll_Line__c.isAccessible()) {
            return rows;
        }
        Id runId = run.runId;
        Decimal total = 0;
        for (AggregateResult agg : [
            SELECT Department_Snapshot__c department, SUM(Gross_Amount__c) gross
            FROM Payroll_Line__c
            WHERE Payroll_Run__c = :runId
            WITH USER_MODE
            GROUP BY Department_Snapshot__c
            ORDER BY SUM(Gross_Amount__c) DESC
        ]) {
            DepartmentRow row = new DepartmentRow();
            String name = (String) agg.get('department');
            row.name = String.isBlank(name) ? 'Unassigned' : name;
            row.gross = zero((Decimal) agg.get('gross'));
            total += row.gross;
            rows.add(row);
        }
        for (DepartmentRow row : rows) {
            row.share = total == 0 ? 0 : (row.gross * 100 / total).setScale(1);
        }
        return rows;
    }

    private static void loadJournal(SummaryData data, Id runId) {
        if (!Schema.SObjectType.Journal_Entry__c.isAccessible() || !Schema.SObjectType.Journal_Entry_Line__c.isAccessible()) {
            return;
        }
        Payroll_Run__c run = [SELECT Accounting_Event__c FROM Payroll_Run__c WHERE Id = :runId WITH USER_MODE LIMIT 1];
        if (run.Accounting_Event__c == null) {
            return;
        }
        Id eventId = run.Accounting_Event__c;
        List<Journal_Entry__c> journals = [
            SELECT Id, Name, Posted_At__c, Posted_By__r.Name
            FROM Journal_Entry__c
            WHERE Accounting_Event__c = :eventId AND Status__c IN ('Posted', 'Reversed')
            WITH USER_MODE
            ORDER BY Posted_At__c
            LIMIT 1
        ];
        if (journals.isEmpty()) {
            return;
        }
        Journal_Entry__c journal = journals[0];
        data.journalId = journal.Id;
        data.journalName = journal.Name;
        data.postedAt = journal.Posted_At__c;
        data.postedBy = journal.Posted_By__r == null ? null : journal.Posted_By__r.Name;
        Id journalId = journal.Id;
        for (AggregateResult agg : [
            SELECT GL_Account__r.Account_Code__c code, GL_Account__r.Name accountName, SUM(Debit_Base__c) debit, SUM(Credit_Base__c) credit
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__c = :journalId
            WITH USER_MODE
            GROUP BY GL_Account__r.Account_Code__c, GL_Account__r.Name
            ORDER BY GL_Account__r.Account_Code__c
        ]) {
            JournalRow row = new JournalRow();
            row.accountCode = (String) agg.get('code');
            row.accountName = (String) agg.get('accountName');
            row.debit = zero((Decimal) agg.get('debit'));
            row.credit = zero((Decimal) agg.get('credit'));
            data.journalLines.add(row);
        }
    }

    private static Decimal zero(Decimal value) {
        return value == null ? 0 : value;
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}