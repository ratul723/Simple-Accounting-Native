/**
 * G22A: controller for c/sabAppShell, the Simple Accounting Books app shell.
 *
 * getShellContext returns the persona, the workspaces the user may open for the selected company,
 * the period of today and the header capabilities. search runs SOSL over invoices, bills, journals,
 * payments, GL accounts and fixed assets, limited to companies the user holds an active grant for.
 *
 * Workspace visibility = custom permission (or object access where no SAB_View_<Area> permission
 * exists yet) AND the company feature switch. Optional modules need an enabled Company_Feature__c
 * row; core features are hidden only when their row is explicitly disabled.
 *
 * The period pill reads Accounting_Period__c in user mode: SABPeriodService (shared, API 65.0) has
 * no read method for the period of a date and is deliberately left unchanged.
 */
public with sharing class SABAppShellController {

    private static final Integer MIN_TERM_LENGTH = 2;
    private static final Integer MAX_TERM_LENGTH = 80;
    private static final String ACCESS_READ = 'read';
    private static final String ACCESS_EDIT = 'edit';
    private static final String NO_COMPANY_ACCESS = 'You do not have active access to this Accounting Company.';

    private static final List<WorkspaceRule> RULES = new List<WorkspaceRule>{
        new WorkspaceRule('home', 'SAB_View_Finance_Home', null, null, null, false),
        new WorkspaceRule('journal', null, Journal_Entry__c.SObjectType, ACCESS_READ, null, false),
        new WorkspaceRule('reversal', null, Journal_Entry__c.SObjectType, ACCESS_READ, null, false),
        new WorkspaceRule('close', null, Accounting_Period__c.SObjectType, ACCESS_READ, null, false),
        new WorkspaceRule('audit', null, Business_Action__c.SObjectType, ACCESS_READ, null, false),
        new WorkspaceRule('sales', null, Invoice__c.SObjectType, ACCESS_READ, null, false),
        new WorkspaceRule('purchases', 'SAB_View_Accounts_Payable_Workspace', null, null, null, false),
        new WorkspaceRule('payments', null, Accounting_Payment__c.SObjectType, ACCESS_READ, null, false),
        new WorkspaceRule('bank', null, Bank_Reconciliation__c.SObjectType, ACCESS_READ, null, false),
        new WorkspaceRule('payroll', null, Payroll_Run__c.SObjectType, ACCESS_READ, 'PAYROLL', false),
        new WorkspaceRule('assets', 'SAB_View_Fixed_Asset_Workspace', null, null, 'FIXED_ASSETS', false),
        new WorkspaceRule('budgets', 'SAB_View_Budgets', null, null, 'BUDGETS', false),
        new WorkspaceRule('projects', 'SAB_View_Project_Financials', null, null, 'PROJECTS', true),
        new WorkspaceRule('tax', 'SAB_View_Tax_Returns', null, null, null, false),
        new WorkspaceRule('reports', null, Report_Run__c.SObjectType, ACCESS_READ, null, false),
        new WorkspaceRule('equity', 'SAB_View_Equity', null, null, 'EQUITY', true),
        new WorkspaceRule('loans', 'SAB_View_Loans_Investments', null, null, 'LOANS_INVESTMENTS', true),
        new WorkspaceRule('group', 'SAB_View_Group_Accounting', null, null, 'GROUP_ACCOUNTING', true),
        new WorkspaceRule('approvals', 'SAB_View_Approvals_Close', null, null, null, false),
        new WorkspaceRule('setup', null, Accounting_Company__c.SObjectType, ACCESS_EDIT, null, false),
        new WorkspaceRule('coa', null, GL_Account__c.SObjectType, ACCESS_READ, null, false),
        new WorkspaceRule('import', 'SAB_View_Imports', null, null, null, false),
        new WorkspaceRule('config', null, Company_Feature__c.SObjectType, ACCESS_READ, null, false)
    };

    public class ShellContext {
        @AuraEnabled public Id userId { get; set; }
        @AuraEnabled public SABPersonaService.Persona persona { get; set; }
        @AuraEnabled public List<String> visibleWorkspaces { get; set; }
        @AuraEnabled public Boolean hasPeriod { get; set; }
        @AuraEnabled public String periodKey { get; set; }
        @AuraEnabled public Date periodStart { get; set; }
        @AuraEnabled public String periodStatus { get; set; }
        @AuraEnabled public Boolean canCreateJournal { get; set; }
        @AuraEnabled public Boolean canCreateInvoice { get; set; }
    }

    public class SearchResult {
        @AuraEnabled public String kind { get; set; }
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String title { get; set; }
        @AuraEnabled public String detail { get; set; }
        @AuraEnabled public String workspace { get; set; }
        @AuraEnabled public String icon { get; set; }
    }

    @TestVisible
    private class WorkspaceRule {
        String id;
        String permission;
        Schema.SObjectType objectType;
        String accessMode;
        String featureKey;
        Boolean optionalModule;

        WorkspaceRule(String id, String permission, Schema.SObjectType objectType, String accessMode,
            String featureKey, Boolean optionalModule) {
            this.id = id;
            this.permission = permission;
            this.objectType = objectType;
            this.accessMode = accessMode;
            this.featureKey = featureKey;
            this.optionalModule = optionalModule;
        }
    }

    @AuraEnabled
    public static ShellContext getShellContext(Id companyId) {
        if (companyId != null) {
            assertCompany(companyId);
        }
        ShellContext context = new ShellContext();
        context.userId = UserInfo.getUserId();
        context.persona = SABPersonaService.current();
        context.visibleWorkspaces = visibleWorkspaces(companyId == null ? new Map<String, Boolean>() : featureStates(companyId), companyId != null);
        context.canCreateJournal = Schema.SObjectType.Journal_Entry__c.isCreateable();
        context.canCreateInvoice = Schema.SObjectType.Invoice__c.isCreateable();
        context.hasPeriod = false;
        if (companyId != null) {
            applyPeriod(context, companyId);
        }
        return context;
    }

    @AuraEnabled
    public static List<SearchResult> search(String term) {
        List<SearchResult> results = new List<SearchResult>();
        String cleaned = term == null ? '' : term.trim();
        if (cleaned.length() < MIN_TERM_LENGTH) {
            return results;
        }
        if (cleaned.length() > MAX_TERM_LENGTH) {
            cleaned = cleaned.left(MAX_TERM_LENGTH);
        }
        Set<Id> companyIds = SABCompanyAccessService.getAccessibleCompanyIds();
        if (companyIds == null || companyIds.isEmpty()) {
            return results;
        }
        String searchTerm = escapeSosl(cleaned) + '*';
        results.addAll(searchInvoices(searchTerm, companyIds));
        results.addAll(searchBills(searchTerm, companyIds));
        results.addAll(searchJournals(searchTerm, companyIds));
        results.addAll(searchPayments(searchTerm, companyIds));
        results.addAll(searchAccounts(searchTerm, companyIds));
        results.addAll(searchAssets(searchTerm, companyIds));
        return results;
    }

    @TestVisible
    private static List<String> visibleWorkspaces(Map<String, Boolean> features, Boolean hasCompany) {
        List<String> visible = new List<String>();
        for (WorkspaceRule rule : RULES) {
            if (isAllowed(rule) && featureAllows(rule, features, hasCompany)) {
                visible.add(rule.id);
            }
        }
        return visible;
    }

    private static Boolean isAllowed(WorkspaceRule rule) {
        if (rule.permission != null && !SABPermissionService.hasPermission(rule.permission)) {
            return false;
        }
        if (rule.objectType == null) {
            return true;
        }
        Schema.DescribeSObjectResult describe = rule.objectType.getDescribe(SObjectDescribeOptions.DEFERRED);
        return rule.accessMode == ACCESS_EDIT ? describe.isUpdateable() : describe.isAccessible();
    }

    private static Boolean featureAllows(WorkspaceRule rule, Map<String, Boolean> features, Boolean hasCompany) {
        if (rule.featureKey == null) {
            return true;
        }
        if (!hasCompany) {
            return false;
        }
        Boolean enabled = features.get(rule.featureKey);
        if (rule.optionalModule) {
            return enabled == true;
        }
        return enabled != false;
    }

    private static Map<String, Boolean> featureStates(Id companyId) {
        Map<String, Boolean> states = new Map<String, Boolean>();
        if (!Schema.SObjectType.Company_Feature__c.isAccessible()) {
            return states;
        }
        try {
            for (Company_Feature__c feature : [
                SELECT Feature_Key__c, Enabled__c
                FROM Company_Feature__c
                WHERE Company__c = :companyId
                WITH USER_MODE
                LIMIT 200
            ]) {
                states.put(feature.Feature_Key__c.toUpperCase(), feature.Enabled__c == true);
            }
        } catch (QueryException ex) {
            states.clear();
        }
        return states;
    }

    private static void applyPeriod(ShellContext context, Id companyId) {
        if (!Schema.SObjectType.Accounting_Period__c.isAccessible()) {
            return;
        }
        Date today = Date.today();
        try {
            for (Accounting_Period__c period : [
                SELECT Period_Key__c, Start_Date__c, Status__c
                FROM Accounting_Period__c
                WHERE Company__c = :companyId
                  AND Start_Date__c <= :today
                  AND End_Date__c >= :today
                WITH USER_MODE
                ORDER BY Start_Date__c DESC
                LIMIT 1
            ]) {
                context.hasPeriod = true;
                context.periodKey = period.Period_Key__c;
                context.periodStart = period.Start_Date__c;
                context.periodStatus = period.Status__c;
            }
        } catch (QueryException ex) {
            context.hasPeriod = false;
        }
    }

    private static void assertCompany(Id companyId) {
        if (!SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw new AuraHandledException(NO_COMPANY_ACCESS);
        }
    }

    @TestVisible
    private static String escapeSosl(String value) {
        String escaped = '';
        String reserved = '?&|!{}[]()^~*:\\"\'+-';
        for (Integer i = 0; i < value.length(); i++) {
            String ch = value.substring(i, i + 1);
            escaped += reserved.contains(ch) ? '\\' + ch : ch;
        }
        return escaped;
    }

    private static SearchResult result(String kind, SObject record, Id companyId, String title, String detail,
        String workspace, String icon) {
        SearchResult row = new SearchResult();
        row.kind = kind;
        row.recordId = record.Id;
        row.companyId = companyId;
        row.title = title;
        row.detail = detail;
        row.workspace = workspace;
        row.icon = icon;
        return row;
    }

    private static List<SearchResult> searchInvoices(String searchTerm, Set<Id> companyIds) {
        List<SearchResult> rows = new List<SearchResult>();
        if (!Schema.SObjectType.Invoice__c.isAccessible()) {
            return rows;
        }
        try {
            List<List<SObject>> found = [
                FIND :searchTerm IN ALL FIELDS
                RETURNING Invoice__c(Id, Name, Legal_Number__c, Status__c, Company__c
                    WHERE Company__c IN :companyIds ORDER BY Document_Date__c DESC LIMIT 5)
                WITH USER_MODE
            ];
            for (Invoice__c invoice : (List<Invoice__c>) found[0]) {
                String title = String.isBlank(invoice.Legal_Number__c) ? invoice.Name : invoice.Legal_Number__c;
                rows.add(result('invoice', invoice, invoice.Company__c, title, joinDetail('Invoice', invoice.Status__c), 'sales', 'sales'));
            }
        } catch (QueryException ex) {
            rows.clear();
        }
        return rows;
    }

    private static List<SearchResult> searchBills(String searchTerm, Set<Id> companyIds) {
        List<SearchResult> rows = new List<SearchResult>();
        if (!Schema.SObjectType.Supplier_Bill__c.isAccessible()) {
            return rows;
        }
        try {
            List<List<SObject>> found = [
                FIND :searchTerm IN ALL FIELDS
                RETURNING Supplier_Bill__c(Id, Name, Vendor_Reference__c, Status__c, Company__c
                    WHERE Company__c IN :companyIds ORDER BY Document_Date__c DESC LIMIT 5)
                WITH USER_MODE
            ];
            for (Supplier_Bill__c bill : (List<Supplier_Bill__c>) found[0]) {
                rows.add(result('bill', bill, bill.Company__c, bill.Name,
                    joinDetail(String.isBlank(bill.Vendor_Reference__c) ? 'Bill' : 'Bill ' + bill.Vendor_Reference__c, bill.Status__c),
                    'purchases', 'purch'));
            }
        } catch (QueryException ex) {
            rows.clear();
        }
        return rows;
    }

    private static List<SearchResult> searchJournals(String searchTerm, Set<Id> companyIds) {
        List<SearchResult> rows = new List<SearchResult>();
        if (!Schema.SObjectType.Journal_Entry__c.isAccessible()) {
            return rows;
        }
        try {
            List<List<SObject>> found = [
                FIND :searchTerm IN ALL FIELDS
                RETURNING Journal_Entry__c(Id, Name, Description__c, Status__c, Company__c
                    WHERE Company__c IN :companyIds ORDER BY Accounting_Date__c DESC LIMIT 5)
                WITH USER_MODE
            ];
            for (Journal_Entry__c journal : (List<Journal_Entry__c>) found[0]) {
                rows.add(result('journal', journal, journal.Company__c, journal.Name,
                    joinDetail(journal.Description__c, journal.Status__c), 'journal', 'journal'));
            }
        } catch (QueryException ex) {
            rows.clear();
        }
        return rows;
    }

    private static List<SearchResult> searchPayments(String searchTerm, Set<Id> companyIds) {
        List<SearchResult> rows = new List<SearchResult>();
        if (!Schema.SObjectType.Accounting_Payment__c.isAccessible()) {
            return rows;
        }
        try {
            List<List<SObject>> found = [
                FIND :searchTerm IN ALL FIELDS
                RETURNING Accounting_Payment__c(Id, Name, Reference__c, Direction__c, Company__c
                    WHERE Company__c IN :companyIds ORDER BY Effective_Date__c DESC LIMIT 5)
                WITH USER_MODE
            ];
            for (Accounting_Payment__c payment : (List<Accounting_Payment__c>) found[0]) {
                rows.add(result('payment', payment, payment.Company__c, payment.Name,
                    joinDetail(payment.Direction__c, payment.Reference__c), 'payments', 'pay'));
            }
        } catch (QueryException ex) {
            rows.clear();
        }
        return rows;
    }

    private static List<SearchResult> searchAccounts(String searchTerm, Set<Id> companyIds) {
        List<SearchResult> rows = new List<SearchResult>();
        if (!Schema.SObjectType.GL_Account__c.isAccessible()) {
            return rows;
        }
        try {
            List<List<SObject>> found = [
                FIND :searchTerm IN ALL FIELDS
                RETURNING GL_Account__c(Id, Name, Account_Code__c, Account_Type__c, Company__c
                    WHERE Company__c IN :companyIds ORDER BY Account_Code__c ASC LIMIT 5)
                WITH USER_MODE
            ];
            for (GL_Account__c account : (List<GL_Account__c>) found[0]) {
                rows.add(result('account', account, account.Company__c,
                    String.isBlank(account.Account_Code__c) ? account.Name : account.Account_Code__c + ' ' + account.Name,
                    account.Account_Type__c, 'coa', 'coa'));
            }
        } catch (QueryException ex) {
            rows.clear();
        }
        return rows;
    }

    private static List<SearchResult> searchAssets(String searchTerm, Set<Id> companyIds) {
        List<SearchResult> rows = new List<SearchResult>();
        if (!Schema.SObjectType.Fixed_Asset__c.isAccessible()) {
            return rows;
        }
        try {
            List<List<SObject>> found = [
                FIND :searchTerm IN ALL FIELDS
                RETURNING Fixed_Asset__c(Id, Name, Asset_Tag__c, Status__c, Company__c
                    WHERE Company__c IN :companyIds ORDER BY Acquisition_Date__c DESC LIMIT 5)
                WITH USER_MODE
            ];
            for (Fixed_Asset__c asset : (List<Fixed_Asset__c>) found[0]) {
                rows.add(result('asset', asset, asset.Company__c,
                    String.isBlank(asset.Asset_Tag__c) ? asset.Name : asset.Asset_Tag__c,
                    joinDetail(asset.Name, asset.Status__c), 'assets', 'assets'));
            }
        } catch (QueryException ex) {
            rows.clear();
        }
        return rows;
    }

    private static String joinDetail(String first, String second) {
        if (String.isBlank(first)) {
            return second;
        }
        return String.isBlank(second) ? first : first + ', ' + second;
    }
}
