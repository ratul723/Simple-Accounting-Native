/** G11B: read-only, accrual-based project profitability from accessible posted ledger lines. */
public with sharing class SABProjectFinancialService {
    @TestVisible private static Integer maxReportLines = 10000;
    private static final String FILTER =
        ' FROM Journal_Entry_Line__c WHERE Project__c = :projectId'
        + ' AND Journal_Entry__r.Company__c = :companyId'
        + ' AND GL_Account__r.Company__c = :companyId'
        + ' AND Journal_Entry__r.Status__c IN (\'Posted\', \'Reversed\')'
        + ' AND GL_Account__r.Account_Type__c IN (\'Revenue\', \'Expense\')'
        + ' AND Journal_Entry__r.Accounting_Date__c >= :fromDate'
        + ' AND Journal_Entry__r.Accounting_Date__c <= :toDate';

    public class AccountTotal {
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public String accountCode { get; set; }
        @AuraEnabled public String accountName { get; set; }
        @AuraEnabled public String accountType { get; set; }
        @AuraEnabled public Decimal debit { get; set; }
        @AuraEnabled public Decimal credit { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public Integer lineCount { get; set; }
    }
    public class LedgerLine {
        @AuraEnabled public Id lineId { get; set; }
        @AuraEnabled public Id journalId { get; set; }
        @AuraEnabled public String journalName { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String entryType { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String accountName { get; set; }
        @AuraEnabled public String accountType { get; set; }
        @AuraEnabled public Decimal lineNumber { get; set; }
        @AuraEnabled public Decimal debit { get; set; }
        @AuraEnabled public Decimal credit { get; set; }
        @AuraEnabled public String explanation { get; set; }
    }
    public class LedgerPage {
        @AuraEnabled public List<LedgerLine> lines { get; set; }
        @AuraEnabled public Boolean hasMore { get; set; }
        @AuraEnabled public Date nextDate { get; set; }
        @AuraEnabled public Id nextId { get; set; }
    }
    public class Report {
        @AuraEnabled public Id projectId { get; set; }
        @AuraEnabled public String projectName { get; set; }
        @AuraEnabled public String projectCode { get; set; }
        @AuraEnabled public String projectStatus { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Date fromDate { get; set; }
        @AuraEnabled public Date toDate { get; set; }
        @AuraEnabled public Decimal revenue { get; set; }
        @AuraEnabled public Decimal expense { get; set; }
        @AuraEnabled public Decimal profit { get; set; }
        @AuraEnabled public Decimal marginPercent { get; set; }
        @AuraEnabled public Integer lineCount { get; set; }
        @AuraEnabled public List<AccountTotal> accounts { get; set; }
        @AuraEnabled public LedgerPage ledger { get; set; }
    }

    // Deliberately not cacheable: each request rechecks current permission and company grants.
    @AuraEnabled
    public static Report getReport(Id projectId, Date fromDate, Date toDate) {
        Project__c project = authorize(projectId, fromDate, toDate);
        Map<String, Object> binds = scope(project, fromDate, toDate);
        try {
            List<AggregateResult> counts = Database.queryWithBinds('SELECT COUNT(Id) total' + FILTER, binds, AccessLevel.USER_MODE);
            Integer count = (Integer) counts[0].get('total');
            if (count > maxReportLines) {
                throw failure('This date range exceeds the interactive ledger limit. Select a shorter date range.');
            }
            List<AggregateResult> groups = Database.queryWithBinds(
                'SELECT GL_Account__c accountId, GL_Account__r.Account_Code__c code,'
                + ' GL_Account__r.Name accountName, GL_Account__r.Account_Type__c accountType,'
                + ' Functional_Currency__c currencyCode, SUM(Debit_Base__c) debits,'
                + ' SUM(Credit_Base__c) credits, COUNT(Id) total' + FILTER
                + ' GROUP BY GL_Account__c, GL_Account__r.Account_Code__c, GL_Account__r.Name,'
                + ' GL_Account__r.Account_Type__c, Functional_Currency__c'
                + ' ORDER BY GL_Account__r.Account_Code__c, GL_Account__c LIMIT 501', binds, AccessLevel.USER_MODE);
            if (groups.size() > 500) {
                throw failure('This date range contains too many accounts. Select a shorter date range.');
            }
            Report result = new Report();
            result.projectId = project.Id; result.projectName = project.Name;
            result.projectCode = project.Project_Code__c; result.projectStatus = project.Status__c;
            result.currencyCode = project.Company__r.Functional_Currency__c;
            result.fromDate = fromDate; result.toDate = toDate; result.lineCount = count;
            result.revenue = 0; result.expense = 0; result.accounts = new List<AccountTotal>();
            for (AggregateResult groupRow : groups) {
                assertCurrency((String) groupRow.get('currencyCode'), result.currencyCode);
                AccountTotal row = new AccountTotal();
                row.accountId = (Id) groupRow.get('accountId'); row.accountCode = (String) groupRow.get('code');
                row.accountName = (String) groupRow.get('accountName'); row.accountType = (String) groupRow.get('accountType');
                row.debit = numberValue(groupRow.get('debits')); row.credit = numberValue(groupRow.get('credits'));
                row.lineCount = (Integer) groupRow.get('total');
                row.amount = row.accountType == 'Revenue' ? row.credit - row.debit : row.debit - row.credit;
                if (row.accountType == 'Revenue') { result.revenue += row.amount; } else { result.expense += row.amount; }
                result.accounts.add(row);
            }
            result.profit = result.revenue - result.expense;
            result.marginPercent = result.revenue > 0 ? (result.profit * 100 / result.revenue).setScale(2) : null;
            result.ledger = loadLines(binds, result.currencyCode, null, null, 50);
            return result;
        } catch (QueryException ex) {
            throw failure('Unable to read project financials. Check your object and field permissions.');
        }
    }

    @AuraEnabled
    public static LedgerPage getLedgerPage(Id projectId, Date fromDate, Date toDate, Date afterDate, Id afterId, Integer pageSize) {
        Project__c project = authorize(projectId, fromDate, toDate);
        if (pageSize == null || pageSize < 1 || pageSize > 100) {
            throw failure('Page size must be between 1 and 100.');
        }
        if ((afterDate == null) != (afterId == null)) {
            throw failure('Provide both ledger cursor values or neither.');
        }
        Map<String, Object> binds = scope(project, fromDate, toDate);
        try {
            if (afterId != null) {
                binds.put('afterId', afterId); binds.put('afterDate', afterDate);
                List<SObject> cursorRows = Database.queryWithBinds('SELECT Id' + FILTER
                    + ' AND Id = :afterId AND Journal_Entry__r.Accounting_Date__c = :afterDate LIMIT 1', binds, AccessLevel.USER_MODE);
                if (cursorRows.isEmpty()) { throw failure('The ledger cursor is no longer valid. Refresh the report.'); }
            }
            return loadLines(binds, project.Company__r.Functional_Currency__c, afterDate, afterId, pageSize);
        } catch (QueryException ex) {
            throw failure('Unable to read project ledger details. Check your object and field permissions.');
        }
    }

    private static Project__c authorize(Id projectId, Date fromDate, Date toDate) {
        if (!FeatureManagement.checkPermission('SAB_View_Project_Financials')) {
            throw failure('You need View Project Financials permission.');
        }
        if (projectId == null || projectId.getSObjectType() != Project__c.SObjectType) {
            throw failure('Select a Project record.');
        }
        if (fromDate == null || toDate == null || fromDate > toDate) {
            throw failure('Enter a valid start and end date.');
        }
        Set<Id> companies = SABCompanyAccessService.getAccessibleCompanyIds();
        // Both company authorization and actual record visibility are mandatory, including for administrators.
        try {
            List<Project__c> projects = [SELECT Id, Name, Project_Code__c, Status__c, Company__c,
                Company__r.Functional_Currency__c FROM Project__c
                WHERE Id = :projectId AND Company__c IN :companies WITH USER_MODE LIMIT 1];
            if (projects.isEmpty()) { throw failure('Project unavailable or active company access is missing.'); }
            return projects[0];
        } catch (QueryException ex) {
            throw failure('Unable to read the Project. Check your object and field permissions.');
        }
    }

    private static Map<String, Object> scope(Project__c project, Date fromDate, Date toDate) {
        return new Map<String, Object>{'projectId' => project.Id, 'companyId' => project.Company__c,
            'fromDate' => fromDate, 'toDate' => toDate};
    }

    private static LedgerPage loadLines(Map<String, Object> binds, String currencyCode, Date afterDate, Id afterId, Integer pageSize) {
        binds.put('fetchSize', pageSize + 1);
        String cursorClause = '';
        if (afterId != null) {
            binds.put('afterId', afterId); binds.put('afterDate', afterDate);
            cursorClause = ' AND (Journal_Entry__r.Accounting_Date__c > :afterDate'
                + ' OR (Journal_Entry__r.Accounting_Date__c = :afterDate AND Id > :afterId))';
        }
        List<Journal_Entry_Line__c> rows = Database.queryWithBinds(
            'SELECT Id, Journal_Entry__c, Journal_Entry__r.Name, Journal_Entry__r.Accounting_Date__c,'
            + ' Journal_Entry__r.Entry_Type__c, Journal_Entry__r.Status__c, GL_Account__r.Name,'
            + ' GL_Account__r.Account_Type__c, Line_Number__c, Debit_Base__c, Credit_Base__c,'
            + ' Functional_Currency__c, Explanation__c' + FILTER + cursorClause
            + ' ORDER BY Journal_Entry__r.Accounting_Date__c, Id LIMIT :fetchSize', binds, AccessLevel.USER_MODE);
        LedgerPage result = new LedgerPage(); result.lines = new List<LedgerLine>();
        result.hasMore = rows.size() > pageSize;
        for (Integer i = 0; i < rows.size() && i < pageSize; i++) {
            Journal_Entry_Line__c source = rows[i]; assertCurrency(source.Functional_Currency__c, currencyCode);
            LedgerLine row = new LedgerLine(); row.lineId = source.Id; row.journalId = source.Journal_Entry__c;
            row.journalName = source.Journal_Entry__r.Name; row.accountingDate = source.Journal_Entry__r.Accounting_Date__c;
            row.entryType = source.Journal_Entry__r.Entry_Type__c; row.status = source.Journal_Entry__r.Status__c;
            row.accountName = source.GL_Account__r.Name; row.accountType = source.GL_Account__r.Account_Type__c;
            row.lineNumber = source.Line_Number__c; row.debit = numberValue(source.Debit_Base__c);
            row.credit = numberValue(source.Credit_Base__c); row.explanation = source.Explanation__c;
            result.lines.add(row);
            result.nextDate = row.accountingDate; result.nextId = row.lineId;
        }
        return result;
    }
    private static Decimal numberValue(Object value) { return value == null ? 0 : (Decimal) value; }
    private static void assertCurrency(String actual, String expected) {
        if (actual != expected) { throw failure('Ledger currency differs from company functional currency. Review the journal data.'); }
    }
    private static AuraHandledException failure(String message) {
        AuraHandledException error = new AuraHandledException(message); error.setMessage(message); return error;
    }
}
