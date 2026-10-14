/**
 * G22H-0: read model for the Chart of accounts, Projects and Configuration and diagnostics workspaces.
 *
 *   getChart          GL accounts with posted balances, departments, cost centers, projects, report definitions and mappings
 *   getProjects       projects with posted revenue and cost from journal lines tagged with the project
 *   getConfiguration  company features, access grants, approval activity, configuration checks and processing runs
 *   searchUsers       active users for the access grant form
 *
 * Read only. Writes go through SABSetupRecordService (accounts, features) and SABAdminWorkspaceService (departments,
 * cost centers, projects, access grants). Reads run in user mode after the company grant check; a list the user cannot
 * read comes back empty. Diagnostics carry counts and statuses only, no financial detail.
 */
public with sharing class SABAdminWorkspaceController {

    private static final List<String> KNOWN_FEATURES = new List<String>{
        'PAYROLL', 'FIXED_ASSETS', 'BUDGETS', 'PURCHASING', 'PROJECTS', 'EQUITY', 'LOANS_INVESTMENTS', 'GROUP_ACCOUNTING' };

    // ------------------------------------------------------------------ DTOs

    public class Option {
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public String label { get; set; }

        Option(String value, String label) {
            this.value = value;
            this.label = label;
        }
    }

    public class AccountRow {
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public String code { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String accountType { get; set; }
        @AuraEnabled public String normalBalance { get; set; }
        @AuraEnabled public String controlType { get; set; }
        @AuraEnabled public Boolean isControlAccount { get; set; }
        @AuraEnabled public Boolean manualPostingAllowed { get; set; }
        @AuraEnabled public Boolean active { get; set; }
        @AuraEnabled public String cashFlowCategory { get; set; }
        @AuraEnabled public String reportGroup { get; set; }
        @AuraEnabled public Decimal balance { get; set; }
    }

    public class DimensionRow {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public String code { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public Id parentId { get; set; }
        @AuraEnabled public String parentName { get; set; }
        @AuraEnabled public Id personId { get; set; }
        @AuraEnabled public String personName { get; set; }
        @AuraEnabled public Boolean active { get; set; }
        @AuraEnabled public Date activeFrom { get; set; }
        @AuraEnabled public Date activeTo { get; set; }
    }

    public class ProjectRow {
        @AuraEnabled public Id projectId { get; set; }
        @AuraEnabled public String code { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date endDate { get; set; }
        @AuraEnabled public Id managerId { get; set; }
        @AuraEnabled public String managerName { get; set; }
        @AuraEnabled public Id customerAccountId { get; set; }
        @AuraEnabled public String customerName { get; set; }
        @AuraEnabled public Decimal revenue { get; set; }
        @AuraEnabled public Decimal cost { get; set; }
        @AuraEnabled public Integer lineCount { get; set; }
    }

    public class MappingRow {
        @AuraEnabled public String rowKey { get; set; }
        @AuraEnabled public String groupKey { get; set; }
        @AuraEnabled public Decimal displayOrder { get; set; }
        @AuraEnabled public Decimal sign { get; set; }
        @AuraEnabled public List<String> accounts { get; set; }
    }

    public class DefinitionRow {
        @AuraEnabled public Id definitionId { get; set; }
        @AuraEnabled public String definitionKey { get; set; }
        @AuraEnabled public String reportType { get; set; }
        @AuraEnabled public Decimal version { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Date effectiveFrom { get; set; }
        @AuraEnabled public Date effectiveTo { get; set; }
        @AuraEnabled public List<MappingRow> rows { get; set; }
    }

    public class ChartData {
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Boolean canManageSetup { get; set; }
        @AuraEnabled public Boolean canManageProjects { get; set; }
        @AuraEnabled public List<AccountRow> accounts { get; set; }
        @AuraEnabled public List<DimensionRow> departments { get; set; }
        @AuraEnabled public List<DimensionRow> costCenters { get; set; }
        @AuraEnabled public List<ProjectRow> projects { get; set; }
        @AuraEnabled public List<DefinitionRow> definitions { get; set; }
    }

    public class ProjectsData {
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Boolean canManageProjects { get; set; }
        @AuraEnabled public Boolean canViewFinancials { get; set; }
        @AuraEnabled public Boolean projectsEnabled { get; set; }
        @AuraEnabled public List<ProjectRow> projects { get; set; }
        @AuraEnabled public List<Option> customers { get; set; }
    }

    public class FeatureRow {
        @AuraEnabled public Id featureId { get; set; }
        @AuraEnabled public String featureKey { get; set; }
        @AuraEnabled public Boolean enabled { get; set; }
        @AuraEnabled public String configurationStatus { get; set; }
        @AuraEnabled public Datetime enabledAt { get; set; }
    }

    public class GrantRow {
        @AuraEnabled public Id grantId { get; set; }
        @AuraEnabled public Id userId { get; set; }
        @AuraEnabled public String userName { get; set; }
        @AuraEnabled public String role { get; set; }
        @AuraEnabled public Date effectiveFrom { get; set; }
        @AuraEnabled public Date effectiveTo { get; set; }
        @AuraEnabled public Decimal approvalLimit { get; set; }
        @AuraEnabled public Boolean active { get; set; }
    }

    public class ApprovalRow {
        @AuraEnabled public String sourceType { get; set; }
        @AuraEnabled public Integer pending { get; set; }
        @AuraEnabled public Integer approved { get; set; }
        @AuraEnabled public Integer rejected { get; set; }
        @AuraEnabled public Integer other { get; set; }
    }

    public class CheckRow {
        @AuraEnabled public String title { get; set; }
        @AuraEnabled public String detail { get; set; }
        @AuraEnabled public String status { get; set; }

        CheckRow(String title, String detail, String status) {
            this.title = title;
            this.detail = detail;
            this.status = status;
        }
    }

    public class RunRow {
        @AuraEnabled public Id runId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String runType { get; set; }
        @AuraEnabled public Datetime startedAt { get; set; }
        @AuraEnabled public Datetime completedAt { get; set; }
        @AuraEnabled public Decimal processed { get; set; }
        @AuraEnabled public Decimal failures { get; set; }
        @AuraEnabled public Decimal retries { get; set; }
        @AuraEnabled public String status { get; set; }
    }

    public class ConfigData {
        @AuraEnabled public Boolean canManageSetup { get; set; }
        @AuraEnabled public Boolean canManageAccess { get; set; }
        @AuraEnabled public List<FeatureRow> features { get; set; }
        @AuraEnabled public List<GrantRow> grants { get; set; }
        @AuraEnabled public List<ApprovalRow> approvals { get; set; }
        @AuraEnabled public List<CheckRow> checks { get; set; }
        @AuraEnabled public List<RunRow> runs { get; set; }
        @AuraEnabled public List<String> roles { get; set; }
    }

    // ------------------------------------------------------------------ chart

    @AuraEnabled
    public static ChartData getChart(Id companyId) {
        assertCompany(companyId);
        try {
            ChartData data = new ChartData();
            data.currencyCode = currencyOf(companyId);
            data.canManageSetup = SABPermissionService.hasPermission('SAB_Manage_Company_Setup');
            data.canManageProjects = SABPermissionService.hasPermission('SAB_Manage_Projects');
            data.accounts = accounts(companyId);
            data.departments = departments(companyId);
            data.costCenters = costCenters(companyId);
            data.projects = projects(companyId, false);
            data.definitions = definitions(companyId);
            return data;
        } catch (QueryException ex) {
            throw auraError('The chart of accounts could not be loaded: ' + ex.getMessage());
        }
    }

    private static List<AccountRow> accounts(Id companyId) {
        List<AccountRow> rows = new List<AccountRow>();
        if (!Schema.SObjectType.GL_Account__c.isAccessible()) {
            return rows;
        }
        Map<Id, Decimal> balances = new Map<Id, Decimal>();
        if (Schema.SObjectType.Journal_Entry_Line__c.isAccessible()) {
            for (AggregateResult agg : [
                SELECT GL_Account__c accountId, SUM(Debit_Base__c) debit, SUM(Credit_Base__c) credit
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__r.Company__c = :companyId AND Journal_Entry__r.Status__c IN ('Posted', 'Reversed')
                WITH USER_MODE
                GROUP BY GL_Account__c
            ]) {
                balances.put((Id) agg.get('accountId'), zero((Decimal) agg.get('debit')) - zero((Decimal) agg.get('credit')));
            }
        }
        for (GL_Account__c a : [
            SELECT Id, Account_Code__c, Name, Account_Type__c, Normal_Balance__c, Control_Type__c, Is_Control_Account__c, Manual_Posting_Allowed__c,
                   Is_Active__c, Cash_Flow_Category__c, Report_Group__c
            FROM GL_Account__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Account_Code__c LIMIT 2000
        ]) {
            AccountRow row = new AccountRow();
            row.accountId = a.Id;
            row.code = a.Account_Code__c;
            row.name = a.Name;
            row.accountType = a.Account_Type__c;
            row.normalBalance = a.Normal_Balance__c;
            row.controlType = a.Control_Type__c;
            row.isControlAccount = a.Is_Control_Account__c == true;
            row.manualPostingAllowed = a.Manual_Posting_Allowed__c == true;
            row.active = a.Is_Active__c == true;
            row.cashFlowCategory = a.Cash_Flow_Category__c;
            row.reportGroup = a.Report_Group__c;
            row.balance = balances.containsKey(a.Id) ? balances.get(a.Id) : 0;
            rows.add(row);
        }
        return rows;
    }

    private static List<DimensionRow> departments(Id companyId) {
        List<DimensionRow> rows = new List<DimensionRow>();
        if (!Schema.SObjectType.Department__c.isAccessible()) {
            return rows;
        }
        for (Department__c d : [
            SELECT Id, Code__c, Name, Parent_Department__c, Parent_Department__r.Name, Manager__c, Manager__r.Name, Is_Active__c, Active_From__c, Active_To__c
            FROM Department__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Code__c LIMIT 1000
        ]) {
            DimensionRow row = dimension(d.Id, d.Code__c, d.Name, d.Is_Active__c, d.Active_From__c, d.Active_To__c);
            row.parentId = d.Parent_Department__c;
            row.parentName = d.Parent_Department__r == null ? null : d.Parent_Department__r.Name;
            row.personId = d.Manager__c;
            row.personName = d.Manager__r == null ? null : d.Manager__r.Name;
            rows.add(row);
        }
        return rows;
    }

    private static List<DimensionRow> costCenters(Id companyId) {
        List<DimensionRow> rows = new List<DimensionRow>();
        if (!Schema.SObjectType.Cost_Center__c.isAccessible()) {
            return rows;
        }
        for (Cost_Center__c c : [
            SELECT Id, Code__c, Name, Owner_User__c, Owner_User__r.Name, Is_Active__c, Active_From__c, Active_To__c
            FROM Cost_Center__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Code__c LIMIT 1000
        ]) {
            DimensionRow row = dimension(c.Id, c.Code__c, c.Name, c.Is_Active__c, c.Active_From__c, c.Active_To__c);
            row.personId = c.Owner_User__c;
            row.personName = c.Owner_User__r == null ? null : c.Owner_User__r.Name;
            rows.add(row);
        }
        return rows;
    }

    private static DimensionRow dimension(Id recordId, String code, String name, Boolean active, Date activeFrom, Date activeTo) {
        DimensionRow row = new DimensionRow();
        row.recordId = recordId;
        row.code = code;
        row.name = name;
        row.active = active == true;
        row.activeFrom = activeFrom;
        row.activeTo = activeTo;
        return row;
    }

    private static List<DefinitionRow> definitions(Id companyId) {
        List<DefinitionRow> rows = new List<DefinitionRow>();
        if (!Schema.SObjectType.Report_Definition__c.isAccessible() || !Schema.SObjectType.Report_Mapping__c.isAccessible()) {
            return rows;
        }
        Map<Id, DefinitionRow> byId = new Map<Id, DefinitionRow>();
        for (Report_Definition__c d : [
            SELECT Id, Definition_Key__c, Report_Type__c, Version__c, Status__c, Effective_From__c, Effective_To__c
            FROM Report_Definition__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Report_Type__c, Version__c DESC LIMIT 50
        ]) {
            DefinitionRow row = new DefinitionRow();
            row.definitionId = d.Id;
            row.definitionKey = d.Definition_Key__c;
            row.reportType = d.Report_Type__c;
            row.version = d.Version__c;
            row.status = d.Status__c;
            row.effectiveFrom = d.Effective_From__c;
            row.effectiveTo = d.Effective_To__c;
            row.rows = new List<MappingRow>();
            byId.put(d.Id, row);
            rows.add(row);
        }
        if (byId.isEmpty()) {
            return rows;
        }
        Set<Id> definitionIds = byId.keySet();
        Map<String, MappingRow> mappings = new Map<String, MappingRow>();
        for (Report_Mapping__c m : [
            SELECT Report_Definition__c, Row_Key__c, Group_Key__c, Display_Order__c, Sign_Multiplier__c, GL_Account__r.Account_Code__c, GL_Account__r.Name
            FROM Report_Mapping__c WHERE Report_Definition__c IN :definitionIds WITH USER_MODE ORDER BY Display_Order__c, Row_Key__c LIMIT 5000
        ]) {
            String key = m.Report_Definition__c + '|' + m.Row_Key__c;
            MappingRow row = mappings.get(key);
            if (row == null) {
                row = new MappingRow();
                row.rowKey = m.Row_Key__c;
                row.groupKey = m.Group_Key__c;
                row.displayOrder = m.Display_Order__c;
                row.sign = m.Sign_Multiplier__c;
                row.accounts = new List<String>();
                mappings.put(key, row);
                byId.get(m.Report_Definition__c).rows.add(row);
            }
            if (m.GL_Account__r != null) {
                row.accounts.add(m.GL_Account__r.Account_Code__c + ' ' + m.GL_Account__r.Name);
            }
        }
        return rows;
    }

    // --------------------------------------------------------------- projects

    @AuraEnabled
    public static ProjectsData getProjects(Id companyId) {
        assertCompany(companyId);
        try {
            ProjectsData data = new ProjectsData();
            data.currencyCode = currencyOf(companyId);
            data.canManageProjects = SABPermissionService.hasPermission('SAB_Manage_Projects');
            data.canViewFinancials = SABPermissionService.hasPermission('SAB_View_Project_Financials');
            List<Company_Feature__c> feature = [SELECT Enabled__c FROM Company_Feature__c WHERE Company__c = :companyId AND Feature_Key__c = 'PROJECTS' WITH USER_MODE LIMIT 1];
            data.projectsEnabled = feature.isEmpty() || feature[0].Enabled__c == true;
            data.projects = projects(companyId, data.canViewFinancials);
            data.customers = new List<Option>();
            if (Schema.SObjectType.Party_Accounting_Profile__c.isAccessible()) {
                for (Party_Accounting_Profile__c p : [
                    SELECT Account__c, Account__r.Name FROM Party_Accounting_Profile__c
                    WHERE Company__c = :companyId AND Is_Customer__c = true AND Is_Active__c = true WITH USER_MODE ORDER BY Account__r.Name LIMIT 500
                ]) {
                    if (p.Account__r != null) {
                        data.customers.add(new Option(p.Account__c, p.Account__r.Name));
                    }
                }
            }
            return data;
        } catch (QueryException ex) {
            throw auraError('Projects could not be loaded: ' + ex.getMessage());
        }
    }

    private static List<ProjectRow> projects(Id companyId, Boolean withTotals) {
        List<ProjectRow> rows = new List<ProjectRow>();
        if (!Schema.SObjectType.Project__c.isAccessible()) {
            return rows;
        }
        Map<Id, ProjectRow> byId = new Map<Id, ProjectRow>();
        for (Project__c p : [
            SELECT Id, Project_Code__c, Name, Status__c, Start_Date__c, End_Date__c, Manager__c, Manager__r.Name, Customer_Account__c, Customer_Account__r.Name
            FROM Project__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Project_Code__c LIMIT 500
        ]) {
            ProjectRow row = new ProjectRow();
            row.projectId = p.Id;
            row.code = p.Project_Code__c;
            row.name = p.Name;
            row.status = p.Status__c;
            row.startDate = p.Start_Date__c;
            row.endDate = p.End_Date__c;
            row.managerId = p.Manager__c;
            row.managerName = p.Manager__r == null ? null : p.Manager__r.Name;
            row.customerAccountId = p.Customer_Account__c;
            row.customerName = p.Customer_Account__r == null ? null : p.Customer_Account__r.Name;
            row.revenue = 0;
            row.cost = 0;
            row.lineCount = 0;
            byId.put(p.Id, row);
            rows.add(row);
        }
        if (!withTotals || byId.isEmpty() || !Schema.SObjectType.Journal_Entry_Line__c.isAccessible()) {
            return rows;
        }
        Set<Id> projectIds = byId.keySet();
        for (AggregateResult agg : [
            SELECT Project__c projectId, GL_Account__r.Account_Type__c accountType, SUM(Debit_Base__c) debit, SUM(Credit_Base__c) credit, COUNT(Id) lines
            FROM Journal_Entry_Line__c
            WHERE Project__c IN :projectIds AND Journal_Entry__r.Status__c IN ('Posted', 'Reversed')
            WITH USER_MODE
            GROUP BY Project__c, GL_Account__r.Account_Type__c
        ]) {
            ProjectRow row = byId.get((Id) agg.get('projectId'));
            Decimal net = zero((Decimal) agg.get('debit')) - zero((Decimal) agg.get('credit'));
            String type = (String) agg.get('accountType');
            if (type == 'Revenue') {
                row.revenue -= net;
            } else if (type == 'Expense') {
                row.cost += net;
            }
            row.lineCount += (Integer) agg.get('lines');
        }
        return rows;
    }

    // ---------------------------------------------------------- configuration

    @AuraEnabled
    public static ConfigData getConfiguration(Id companyId) {
        assertCompany(companyId);
        try {
            ConfigData data = new ConfigData();
            data.canManageSetup = SABPermissionService.hasPermission('SAB_Manage_Company_Setup');
            data.canManageAccess = SABPermissionService.hasPermission('SAB_Manage_Company_Access');
            data.features = features(companyId);
            data.grants = grants(companyId);
            data.approvals = approvals(companyId);
            data.checks = checks(companyId);
            data.runs = runs(companyId);
            data.roles = new List<String>();
            for (Schema.PicklistEntry e : Company_User_Access__c.Role__c.getDescribe().getPicklistValues()) {
                if (e.isActive()) {
                    data.roles.add(e.getValue());
                }
            }
            return data;
        } catch (QueryException ex) {
            throw auraError('Configuration could not be loaded: ' + ex.getMessage());
        }
    }

    private static List<FeatureRow> features(Id companyId) {
        Map<String, FeatureRow> byKey = new Map<String, FeatureRow>();
        for (String key : KNOWN_FEATURES) {
            FeatureRow row = new FeatureRow();
            row.featureKey = key;
            // A feature without a row is on: navigation only hides features switched off explicitly.
            row.enabled = true;
            row.configurationStatus = 'Not Configured';
            byKey.put(key, row);
        }
        if (Schema.SObjectType.Company_Feature__c.isAccessible()) {
            for (Company_Feature__c f : [
                SELECT Id, Feature_Key__c, Enabled__c, Configuration_Status__c, Enabled_At__c FROM Company_Feature__c
                WHERE Company__c = :companyId WITH USER_MODE ORDER BY Feature_Key__c LIMIT 200
            ]) {
                FeatureRow row = byKey.containsKey(f.Feature_Key__c) ? byKey.get(f.Feature_Key__c) : new FeatureRow();
                row.featureId = f.Id;
                row.featureKey = f.Feature_Key__c;
                row.enabled = f.Enabled__c == true;
                row.configurationStatus = f.Configuration_Status__c;
                row.enabledAt = f.Enabled_At__c;
                byKey.put(f.Feature_Key__c, row);
            }
        }
        return byKey.values();
    }

    private static List<GrantRow> grants(Id companyId) {
        List<GrantRow> rows = new List<GrantRow>();
        if (!Schema.SObjectType.Company_User_Access__c.isAccessible()) {
            return rows;
        }
        for (Company_User_Access__c g : [
            SELECT Id, User__c, User__r.Name, Role__c, Effective_From__c, Effective_To__c, Approval_Limit__c, Is_Active__c
            FROM Company_User_Access__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Is_Active__c DESC, User__r.Name LIMIT 500
        ]) {
            GrantRow row = new GrantRow();
            row.grantId = g.Id;
            row.userId = g.User__c;
            row.userName = g.User__r == null ? null : g.User__r.Name;
            row.role = g.Role__c;
            row.effectiveFrom = g.Effective_From__c;
            row.effectiveTo = g.Effective_To__c;
            row.approvalLimit = g.Approval_Limit__c;
            row.active = g.Is_Active__c == true && (g.Effective_To__c == null || g.Effective_To__c >= Date.today());
            rows.add(row);
        }
        return rows;
    }

    private static List<ApprovalRow> approvals(Id companyId) {
        Map<String, ApprovalRow> byType = new Map<String, ApprovalRow>();
        if (!Schema.SObjectType.Approval_Request__c.isAccessible()) {
            return byType.values();
        }
        for (AggregateResult agg : [
            SELECT Source_Type__c sourceType, Status__c status, COUNT(Id) total
            FROM Approval_Request__c WHERE Company__c = :companyId
            WITH USER_MODE
            GROUP BY Source_Type__c, Status__c
        ]) {
            String type = (String) agg.get('sourceType');
            ApprovalRow row = byType.get(type);
            if (row == null) {
                row = new ApprovalRow();
                row.sourceType = type;
                row.pending = 0;
                row.approved = 0;
                row.rejected = 0;
                row.other = 0;
                byType.put(type, row);
            }
            Integer total = (Integer) agg.get('total');
            String status = (String) agg.get('status');
            if (status == 'Pending') {
                row.pending += total;
            } else if (status == 'Approved') {
                row.approved += total;
            } else if (status == 'Rejected') {
                row.rejected += total;
            } else {
                row.other += total;
            }
        }
        return byType.values();
    }

    private static List<CheckRow> checks(Id companyId) {
        List<CheckRow> rows = new List<CheckRow>();
        try {
            SABCompanySetupService.SetupResult setup = SABCompanySetupService.validateCoreSetup(companyId);
            if (setup.errors.isEmpty()) {
                rows.add(new CheckRow('Core setup is ready', 'Periods, chart of accounts, numbering and features pass the setup check.', 'Pass'));
            }
            for (String error : setup.errors) {
                rows.add(new CheckRow('Core setup', error, 'Fail'));
            }
            for (String warning : setup.warnings) {
                rows.add(new CheckRow('Core setup', warning, 'Warning'));
            }
        } catch (Exception ex) {
            rows.add(new CheckRow('Core setup', ex.getMessage(), 'Fail'));
        }
        if (Schema.SObjectType.GL_Account__c.isAccessible()) {
            Integer blank = [SELECT COUNT() FROM GL_Account__c WHERE Company__c = :companyId AND Is_Active__c = true AND Cash_Flow_Category__c = null
                AND Account_Type__c IN ('Asset', 'Liability', 'Equity') WITH USER_MODE];
            rows.add(blank == 0
                ? new CheckRow('Cash flow categories', 'Every active balance sheet account has a cash flow category.', 'Pass')
                : new CheckRow('Cash flow categories', blank + ' balance sheet accounts have no cash flow category and report as operating.', 'Warning'));
        }
        if (Schema.SObjectType.Report_Definition__c.isAccessible()) {
            Set<String> types = new Set<String>();
            for (Report_Definition__c d : [SELECT Report_Type__c FROM Report_Definition__c WHERE Company__c = :companyId AND Status__c = 'Active' WITH USER_MODE LIMIT 50]) {
                types.add(d.Report_Type__c);
            }
            Boolean complete = types.contains('P&L') && types.contains('Balance Sheet');
            rows.add(new CheckRow('Report definitions', complete ? 'Active profit and loss and balance sheet definitions exist.'
                : 'Add an active profit and loss and balance sheet definition before running statements.', complete ? 'Pass' : 'Warning'));
        }
        if (Schema.SObjectType.Bank_Account__c.isAccessible()) {
            Integer banks = [SELECT COUNT() FROM Bank_Account__c WHERE Company__c = :companyId AND Is_Active__c = true WITH USER_MODE];
            rows.add(new CheckRow('Bank accounts', banks > 0 ? banks + ' active bank accounts linked to the ledger.' : 'No active bank account. Payments and reconciliation need one.',
                banks > 0 ? 'Pass' : 'Warning'));
        }
        return rows;
    }

    private static List<RunRow> runs(Id companyId) {
        List<RunRow> rows = new List<RunRow>();
        if (!Schema.SObjectType.Processing_Run__c.isAccessible()) {
            return rows;
        }
        for (Processing_Run__c r : [
            SELECT Id, Name, Run_Type__c, Started_At__c, Completed_At__c, Processed_Count__c, Failure_Count__c, Retry_Count__c, Status__c
            FROM Processing_Run__c WHERE Company__c = :companyId OR Company__c = null
            WITH USER_MODE ORDER BY CreatedDate DESC LIMIT 50
        ]) {
            RunRow row = new RunRow();
            row.runId = r.Id;
            row.name = r.Name;
            row.runType = r.Run_Type__c;
            row.startedAt = r.Started_At__c;
            row.completedAt = r.Completed_At__c;
            row.processed = r.Processed_Count__c;
            row.failures = r.Failure_Count__c;
            row.retries = r.Retry_Count__c;
            row.status = r.Status__c;
            rows.add(row);
        }
        return rows;
    }

    // ------------------------------------------------------------------ users

    @AuraEnabled
    public static List<Option> searchUsers(Id companyId, String term) {
        assertCompany(companyId);
        String pattern = '%' + String.escapeSingleQuotes(String.isBlank(term) ? '' : term.trim()) + '%';
        List<Option> rows = new List<Option>();
        for (User u : [
            SELECT Id, Name, Username FROM User
            WHERE IsActive = true AND UserType = 'Standard' AND (Name LIKE :pattern OR Username LIKE :pattern)
            WITH USER_MODE ORDER BY Name LIMIT 20
        ]) {
            rows.add(new Option(u.Id, u.Name + ' (' + u.Username + ')'));
        }
        return rows;
    }

    // ---------------------------------------------------------------- helpers

    private static String currencyOf(Id companyId) {
        return [SELECT Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH USER_MODE LIMIT 1].Functional_Currency__c;
    }

    private static void assertCompany(Id companyId) {
        if (companyId == null || !SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw auraError('You do not have active access to this Accounting Company.');
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
