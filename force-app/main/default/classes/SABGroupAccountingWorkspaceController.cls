/**
 * G22D: controller for c/sabGroupAccountingWorkspace (Group accounting).
 *
 * Read only. Actions call the G18 services directly, unchanged: SABIntercompanyService.recordTransaction and
 * SABConsolidationService.saveGroup / saveMember / calculate / approve / publish / getTrialBalance, each lifecycle
 * action with a request key.
 *
 * Scope follows the selected company: intercompany transactions where it is the From or To company, and the
 * consolidation groups it is a member of, with every member and the latest runs of those groups.
 */
public with sharing class SABGroupAccountingWorkspaceController {

    private static final Integer MAX_TRANSACTIONS = 200;
    private static final Integer RUNS_PER_GROUP = 10;

    public class WorkspaceData {
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Boolean canManageIntercompany { get; set; }
        @AuraEnabled public Boolean canManageConsolidation { get; set; }
        @AuraEnabled public Boolean canApproveConsolidation { get; set; }
        @AuraEnabled public Boolean canPostJournal { get; set; }
        @AuraEnabled public Boolean consolidationAvailable { get; set; }
        @AuraEnabled public Date fiscalYearStart { get; set; }
        @AuraEnabled public Decimal receivableTotal { get; set; }
        @AuraEnabled public Decimal payableTotal { get; set; }
        @AuraEnabled public Decimal volumeThisYear { get; set; }
        @AuraEnabled public Integer unmatchedCount { get; set; }
        @AuraEnabled public List<IntercompanyRow> transactions { get; set; }
        @AuraEnabled public List<GroupRow> groups { get; set; }
    }

    public class IntercompanyRow {
        @AuraEnabled public Id transactionId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public Date transactionDate { get; set; }
        @AuraEnabled public String fromCompany { get; set; }
        @AuraEnabled public String toCompany { get; set; }
        @AuraEnabled public String direction { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public String state { get; set; }
    }

    public class GroupRow {
        @AuraEnabled public Id groupId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String presentationCurrency { get; set; }
        @AuraEnabled public String policyVersion { get; set; }
        @AuraEnabled public Boolean active { get; set; }
        @AuraEnabled public List<MemberRow> members { get; set; }
        @AuraEnabled public List<RunRow> runs { get; set; }
    }

    public class MemberRow {
        @AuraEnabled public Id memberId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String companyName { get; set; }
        @AuraEnabled public String controlType { get; set; }
        @AuraEnabled public Decimal ownershipPercent { get; set; }
        @AuraEnabled public Date effectiveFrom { get; set; }
        @AuraEnabled public Date effectiveTo { get; set; }
        @AuraEnabled public String mappingVersion { get; set; }
    }

    public class RunRow {
        @AuraEnabled public Id runId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public Date asOfDate { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Boolean calculatedByMe { get; set; }
        @AuraEnabled public Datetime calculatedAt { get; set; }
        @AuraEnabled public Integer eliminationCount { get; set; }
    }

    public class Option {
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String kind { get; set; }

        Option(String value, String label, String kind) {
            this.value = value;
            this.label = label;
            this.kind = kind;
        }
    }

    @AuraEnabled
    public static WorkspaceData getWorkspace(Id companyId) {
        assertView(companyId);
        try {
            return build(companyId, Date.today());
        } catch (QueryException ex) {
            throw auraError('Group accounting could not be loaded: ' + ex.getMessage());
        }
    }

    /** Other companies the user holds an active grant for, as intercompany counterparties and group members. */
    @AuraEnabled
    public static List<Option> getCompanyOptions(Id companyId) {
        assertView(companyId);
        List<Option> options = new List<Option>();
        for (SABCompanyContextController.CompanyContext company : SABCompanyContextController.getAccessibleCompanies()) {
            options.add(new Option(company.companyId, company.companyName + ' (' + company.companyKey + ', ' + company.functionalCurrency + ')',
                company.functionalCurrency));
        }
        return options;
    }

    /** Active GL accounts of a company the user holds a grant for. */
    @AuraEnabled
    public static List<Option> getAccountOptions(Id companyId, Id accountCompanyId) {
        assertView(companyId);
        if (accountCompanyId == null || !SABCompanyAccessService.hasCompanyAccess(accountCompanyId)) {
            throw auraError('You do not have active access to that Accounting Company.');
        }
        List<Option> options = new List<Option>();
        try {
            for (GL_Account__c account : [
                SELECT Id, Name, Account_Code__c, Account_Type__c
                FROM GL_Account__c
                WHERE Company__c = :accountCompanyId AND Is_Active__c = true
                WITH USER_MODE
                ORDER BY Account_Code__c
                LIMIT 1000
            ]) {
                options.add(new Option(account.Id, account.Account_Code__c + ' ' + account.Name, account.Account_Type__c));
            }
        } catch (QueryException ex) {
            throw auraError('Accounts could not be loaded: ' + ex.getMessage());
        }
        return options;
    }

    @TestVisible
    private static WorkspaceData build(Id companyId, Date today) {
        Accounting_Company__c company = [
            SELECT Functional_Currency__c, Fiscal_Year_Start_Month__c
            FROM Accounting_Company__c
            WHERE Id = :companyId
            WITH USER_MODE
            LIMIT 1
        ];
        WorkspaceData data = new WorkspaceData();
        data.currencyCode = company.Functional_Currency__c;
        data.canManageIntercompany = SABPermissionService.hasPermission('SAB_Manage_Intercompany');
        data.canManageConsolidation = SABPermissionService.hasPermission('SAB_Manage_Consolidation');
        data.canApproveConsolidation = SABPermissionService.hasPermission('SAB_Approve_Consolidation');
        data.canPostJournal = SABPermissionService.hasPermission('SAB_Post_Journal');
        data.fiscalYearStart = fiscalYearStart(today, company.Fiscal_Year_Start_Month__c);
        loadTransactions(data, companyId);
        data.consolidationAvailable = SABGroupAccountingReadPolicy.canReadConsolidation();
        data.groups = data.consolidationAvailable ? groups(companyId) : new List<GroupRow>();
        return data;
    }

    @TestVisible
    private static Date fiscalYearStart(Date today, Decimal startMonth) {
        Integer month = startMonth == null || startMonth < 1 || startMonth > 12 ? 1 : startMonth.intValue();
        Integer year = today.month() >= month ? today.year() : today.year() - 1;
        return Date.newInstance(year, month, 1);
    }

    private static void loadTransactions(WorkspaceData data, Id companyId) {
        data.transactions = new List<IntercompanyRow>();
        data.receivableTotal = 0;
        data.payableTotal = 0;
        data.volumeThisYear = 0;
        data.unmatchedCount = 0;
        if (!Schema.SObjectType.Intercompany_Transaction__c.isAccessible()) {
            return;
        }
        for (Intercompany_Transaction__c tx : [
            SELECT Id, Name, Transaction_Date__c, From_Company__c, From_Company__r.Name__c, To_Company__c, To_Company__r.Name__c,
                   Description__c, Agreed_Amount__c, Currency__c, Reconciliation_State__c
            FROM Intercompany_Transaction__c
            WHERE From_Company__c = :companyId OR To_Company__c = :companyId
            WITH USER_MODE
            ORDER BY Transaction_Date__c DESC, Name DESC
            LIMIT :MAX_TRANSACTIONS
        ]) {
            IntercompanyRow row = new IntercompanyRow();
            row.transactionId = tx.Id;
            row.name = tx.Name;
            row.transactionDate = tx.Transaction_Date__c;
            row.fromCompany = tx.From_Company__r == null ? null : tx.From_Company__r.Name__c;
            row.toCompany = tx.To_Company__r == null ? null : tx.To_Company__r.Name__c;
            row.direction = tx.From_Company__c == companyId ? 'Receivable' : 'Payable';
            row.description = tx.Description__c;
            row.amount = tx.Agreed_Amount__c == null ? 0 : tx.Agreed_Amount__c;
            row.currencyCode = tx.Currency__c;
            row.state = tx.Reconciliation_State__c;
            data.transactions.add(row);
            if (row.transactionDate != null && row.transactionDate >= data.fiscalYearStart) {
                data.volumeThisYear += row.amount;
            }
            if (row.state != 'Matched' && row.state != 'Corrected') {
                data.unmatchedCount++;
            }
            if (row.direction == 'Receivable') {
                data.receivableTotal += row.amount;
            } else {
                data.payableTotal += row.amount;
            }
        }
    }

    private static List<GroupRow> groups(Id companyId) {
        Set<Id> groupIds = new Set<Id>();
        for (Consolidation_Member__c member : [
            SELECT Consolidation_Group__c
            FROM Consolidation_Member__c
            WHERE Company__c = :companyId
            WITH USER_MODE
            LIMIT 200
        ]) {
            groupIds.add(member.Consolidation_Group__c);
        }
        List<GroupRow> rows = new List<GroupRow>();
        if (groupIds.isEmpty()) {
            return rows;
        }
        Map<Id, GroupRow> byId = new Map<Id, GroupRow>();
        for (Consolidation_Group__c g : [
            SELECT Id, Name, Presentation_Currency__c, Policy_Version__c, Is_Active__c
            FROM Consolidation_Group__c
            WHERE Id IN :groupIds
            WITH USER_MODE
            ORDER BY Name
        ]) {
            GroupRow row = new GroupRow();
            row.groupId = g.Id;
            row.name = g.Name;
            row.presentationCurrency = g.Presentation_Currency__c;
            row.policyVersion = g.Policy_Version__c;
            row.active = g.Is_Active__c == true;
            row.members = new List<MemberRow>();
            row.runs = new List<RunRow>();
            byId.put(g.Id, row);
            rows.add(row);
        }
        Set<Id> visibleGroups = byId.keySet();
        for (Consolidation_Member__c member : [
            SELECT Id, Consolidation_Group__c, Company__c, Company__r.Name__c, Control_Type__c, Ownership_Percent__c, Effective_From__c,
                   Effective_To__c, Mapping_Version__c
            FROM Consolidation_Member__c
            WHERE Consolidation_Group__c IN :visibleGroups
            WITH USER_MODE
            ORDER BY Consolidation_Group__c, Company__r.Name__c
            LIMIT 2000
        ]) {
            MemberRow row = new MemberRow();
            row.memberId = member.Id;
            row.companyId = member.Company__c;
            row.companyName = member.Company__r == null ? null : member.Company__r.Name__c;
            row.controlType = member.Control_Type__c;
            row.ownershipPercent = member.Ownership_Percent__c;
            row.effectiveFrom = member.Effective_From__c;
            row.effectiveTo = member.Effective_To__c;
            row.mappingVersion = member.Mapping_Version__c;
            byId.get(member.Consolidation_Group__c).members.add(row);
        }
        loadRuns(byId);
        return rows;
    }

    private static void loadRuns(Map<Id, GroupRow> byId) {
        Set<Id> visibleGroups = byId.keySet();
        Id userId = UserInfo.getUserId();
        Map<Id, RunRow> runById = new Map<Id, RunRow>();
        for (Consolidation_Run__c run : [
            SELECT Id, Name, Consolidation_Group__c, As_Of_Date__c, Status__c, CreatedById, CreatedDate
            FROM Consolidation_Run__c
            WHERE Consolidation_Group__c IN :visibleGroups
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 500
        ]) {
            GroupRow groupRow = byId.get(run.Consolidation_Group__c);
            if (groupRow.runs.size() >= RUNS_PER_GROUP) {
                continue;
            }
            RunRow row = new RunRow();
            row.runId = run.Id;
            row.name = run.Name;
            row.asOfDate = run.As_Of_Date__c;
            row.status = run.Status__c;
            row.calculatedByMe = run.CreatedById == userId;
            row.calculatedAt = run.CreatedDate;
            row.eliminationCount = 0;
            groupRow.runs.add(row);
            runById.put(run.Id, row);
        }
        if (runById.isEmpty() || !Schema.SObjectType.Consolidation_Adjustment__c.isAccessible()) {
            return;
        }
        Set<Id> runIds = runById.keySet();
        for (AggregateResult agg : [
            SELECT Consolidation_Run__c runId, COUNT(Id) adjustments
            FROM Consolidation_Adjustment__c
            WHERE Consolidation_Run__c IN :runIds
            WITH USER_MODE
            GROUP BY Consolidation_Run__c
        ]) {
            runById.get((Id) agg.get('runId')).eliminationCount = (Integer) agg.get('adjustments');
        }
    }

    private static void assertView(Id companyId) {
        try {
            SABGroupAccountingReadPolicy.assertCanView(companyId);
        } catch (SABGroupAccountingReadPolicy.GroupAccountingAccessException ex) {
            throw auraError(ex.getMessage());
        }
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
