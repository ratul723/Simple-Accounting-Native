/**
 * New requirements batch 1 (R2): report mappings maintained with the chart of accounts.
 *
 *   getOptions                the company's active P&L and balance sheet rows, every mapping, and unmapped posted accounts
 *   saveAccountWithMapping    save a GL account (SABSetupRecordService.saveAccount) and its statement row together;
 *                             a new account must choose a row
 *   moveAccount               put an existing account on another row of a definition (or a new row)
 *   createVersion             copy a definition and its mappings into a new Draft version
 *   activateVersion           make a Draft version Active and retire the previous one of the same report type
 *   deleteDraftVersion        delete a Draft version and its mappings (Active and Retired versions stay for history)
 *   unmappedPostedAccounts    accounts that have postings but no mapping in the active definition for their type
 *
 * Asset, Liability and Equity accounts belong on the Balance Sheet; Revenue and Expense on the P&L. A mapping's sign
 * follows the account's normal balance (Debit +1, Credit -1) and it is effective from the definition's start date.
 * Writes need SAB_Manage_Company_Setup and the company grant, are idempotent by request key and audited.
 */
public with sharing class SABReportMappingService {
    public class ReportMappingException extends Exception {}

    private static final String SETUP_PERMISSION = 'SAB_Manage_Company_Setup';
    public static final String BALANCE_SHEET = 'Balance Sheet';
    public static final String PROFIT_LOSS = 'P&L';

    public class RowOption {
        @AuraEnabled public String groupKey { get; set; }
        @AuraEnabled public String rowKey { get; set; }
        @AuraEnabled public Decimal displayOrder { get; set; }
    }

    public class DefinitionOption {
        @AuraEnabled public Id definitionId { get; set; }
        @AuraEnabled public String reportType { get; set; }
        @AuraEnabled public Decimal version { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Date effectiveFrom { get; set; }
        @AuraEnabled public List<RowOption> rows { get; set; }
    }

    public class AccountMapping {
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public Id definitionId { get; set; }
        @AuraEnabled public String groupKey { get; set; }
        @AuraEnabled public String rowKey { get; set; }
    }

    public class UnmappedAccount {
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public String code { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String accountType { get; set; }
        @AuraEnabled public String reportType { get; set; }
    }

    public class Options {
        @AuraEnabled public Boolean canManage { get; set; }
        @AuraEnabled public List<DefinitionOption> definitions { get; set; }
        @AuraEnabled public List<AccountMapping> mappings { get; set; }
        @AuraEnabled public List<UnmappedAccount> unmapped { get; set; }
    }

    public class MappingChoice {
        @AuraEnabled public Id definitionId { get; set; }
        @AuraEnabled public String groupKey { get; set; }
        @AuraEnabled public String rowKey { get; set; }
    }

    // ------------------------------------------------------------------ reads

    @AuraEnabled
    public static Options getOptions(Id companyId) {
        assertCompany(companyId);
        Options o = new Options();
        o.canManage = SABPermissionService.hasPermission(SETUP_PERMISSION);
        o.definitions = new List<DefinitionOption>();
        o.mappings = new List<AccountMapping>();
        Map<Id, DefinitionOption> byId = new Map<Id, DefinitionOption>();
        for (Report_Definition__c d : new Store().definitions(companyId)) {
            DefinitionOption option = new DefinitionOption();
            option.definitionId = d.Id;
            option.reportType = d.Report_Type__c;
            option.version = d.Version__c;
            option.status = d.Status__c;
            option.effectiveFrom = d.Effective_From__c;
            option.rows = new List<RowOption>();
            byId.put(d.Id, option);
            o.definitions.add(option);
        }
        Set<String> seenRows = new Set<String>();
        for (Report_Mapping__c m : new Store().mappings(byId.keySet())) {
            String rowId = m.Report_Definition__c + '|' + m.Group_Key__c + '|' + m.Row_Key__c;
            if (seenRows.add(rowId)) {
                RowOption row = new RowOption();
                row.groupKey = m.Group_Key__c;
                row.rowKey = m.Row_Key__c;
                row.displayOrder = m.Display_Order__c;
                byId.get(m.Report_Definition__c).rows.add(row);
            }
            AccountMapping mapping = new AccountMapping();
            mapping.accountId = m.GL_Account__c;
            mapping.definitionId = m.Report_Definition__c;
            mapping.groupKey = m.Group_Key__c;
            mapping.rowKey = m.Row_Key__c;
            o.mappings.add(mapping);
        }
        o.unmapped = unmappedPostedAccounts(companyId);
        return o;
    }

    /** Accounts with posted lines that have no mapping in the active definition for their statement. */
    public static List<UnmappedAccount> unmappedPostedAccounts(Id companyId) {
        Store store = new Store();
        Map<String, Id> activeByType = new Map<String, Id>();
        for (Report_Definition__c d : store.definitions(companyId)) {
            if (d.Status__c == 'Active' && !activeByType.containsKey(d.Report_Type__c)) {
                activeByType.put(d.Report_Type__c, d.Id);
            }
        }
        Set<Id> mapped = new Set<Id>();
        for (Report_Mapping__c m : store.mappings(new Set<Id>(activeByType.values()))) {
            mapped.add(m.GL_Account__c);
        }
        List<UnmappedAccount> rows = new List<UnmappedAccount>();
        for (GL_Account__c a : store.postedAccounts(companyId)) {
            if (!mapped.contains(a.Id)) {
                UnmappedAccount row = new UnmappedAccount();
                row.accountId = a.Id;
                row.code = a.Account_Code__c;
                row.name = a.Name;
                row.accountType = a.Account_Type__c;
                row.reportType = reportTypeFor(a.Account_Type__c);
                rows.add(row);
            }
        }
        return rows;
    }

    public static String reportTypeFor(String accountType) {
        return accountType == 'Revenue' || accountType == 'Expense' ? PROFIT_LOSS : BALANCE_SHEET;
    }

    // ----------------------------------------------------------------- writes

    @AuraEnabled
    public static Id saveAccountWithMapping(SABSetupRecordService.AccountRequest request, MappingChoice mapping, String requestKey) {
        if (request == null || request.companyId == null) {
            throw new ReportMappingException('Accounting Company is required.');
        }
        Boolean isNew = request.accountId == null;
        Boolean chosen = mapping != null && String.isNotBlank(mapping.rowKey);
        if (isNew && !chosen) {
            throw new ReportMappingException('Choose where this account appears on the Balance Sheet / P&L.');
        }
        Savepoint sp = Database.setSavepoint();
        try {
            Id accountId = SABSetupRecordService.saveAccount(request, requestKey);
            if (chosen) {
                upsertMapping(request.companyId, accountId, mapping, requestKey + '-MAP');
            }
            return accountId;
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
    }

    @AuraEnabled
    public static Id moveAccount(Id companyId, Id accountId, MappingChoice mapping, String requestKey) {
        if (accountId == null || mapping == null || String.isBlank(mapping.rowKey)) {
            throw new ReportMappingException('Choose an account and a statement row.');
        }
        assertManage(companyId);
        return upsertMapping(companyId, accountId, mapping, requireKey(requestKey));
    }

    private static Id upsertMapping(Id companyId, Id accountId, MappingChoice mapping, String key) {
        assertManage(companyId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return Id.valueOf(prior.Source_Record_Id__c);
        }
        GL_Account__c account = store.account(accountId);
        if (account == null || account.Company__c != companyId) {
            throw new ReportMappingException('The GL account does not belong to this Accounting Company.');
        }
        Report_Definition__c definition = mapping.definitionId == null ? store.activeDefinition(companyId, reportTypeFor(account.Account_Type__c))
            : store.definition(mapping.definitionId);
        if (definition == null || definition.Company__c != companyId) {
            throw new ReportMappingException('There is no ' + reportTypeFor(account.Account_Type__c) + ' definition for this company. Add one in Chart of accounts > Report mapping.');
        }
        if (definition.Report_Type__c != reportTypeFor(account.Account_Type__c)) {
            throw new ReportMappingException(account.Account_Type__c + ' accounts belong on the ' + reportTypeFor(account.Account_Type__c) + ', not the ' + definition.Report_Type__c + '.');
        }
        if (definition.Status__c == 'Retired') {
            throw new ReportMappingException('Retired definitions cannot be changed. Start a new version instead.');
        }
        String rowKey = mapping.rowKey.trim().toUpperCase().replaceAll('[^A-Z0-9]+', '_').left(80);
        String groupKey = String.isBlank(mapping.groupKey) ? store.groupFor(definition.Id, rowKey) : mapping.groupKey.trim().toUpperCase().replaceAll('[^A-Z0-9]+', '_').left(80);
        if (String.isBlank(groupKey)) {
            throw new ReportMappingException('Choose the section for the new row.');
        }
        Report_Mapping__c row = store.existing(definition.Id, accountId);
        if (row == null) {
            row = new Report_Mapping__c(Report_Definition__c = definition.Id, GL_Account__c = accountId);
        }
        row.Group_Key__c = groupKey;
        row.Row_Key__c = rowKey;
        row.Display_Order__c = store.orderFor(definition.Id, rowKey);
        row.Sign_Multiplier__c = account.Normal_Balance__c == 'Credit' ? -1 : 1;
        row.Effective_From__c = definition.Effective_From__c;
        new Writer().saveMapping(row, audit(companyId, 'REPORT_MAPPING_SAVED', key,
            account.Account_Code__c + ' mapped to ' + groupKey + ' / ' + rowKey));
        return row.Id;
    }

    @AuraEnabled
    public static Id createVersion(Id companyId, Id definitionId, String requestKey) {
        String key = requireKey(requestKey);
        assertManage(companyId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return Id.valueOf(prior.Source_Record_Id__c);
        }
        Report_Definition__c source = store.definition(definitionId);
        if (source == null || source.Company__c != companyId) {
            throw new ReportMappingException('The report definition does not belong to this Accounting Company.');
        }
        Decimal next = store.maxVersion(companyId, source.Report_Type__c) + 1;
        String companyKey = store.companyKey(companyId);
        Report_Definition__c copy = new Report_Definition__c(Company__c = companyId, Report_Type__c = source.Report_Type__c, Version__c = next, Status__c = 'Draft',
            Effective_From__c = Date.today(), Definition_Key__c = (companyKey + '-' + (source.Report_Type__c == PROFIT_LOSS ? 'PL' : 'BS') + '-V' + next).left(80));
        List<Report_Mapping__c> mappings = new List<Report_Mapping__c>();
        for (Report_Mapping__c m : store.mappings(new Set<Id>{ source.Id })) {
            mappings.add(new Report_Mapping__c(GL_Account__c = m.GL_Account__c, Group_Key__c = m.Group_Key__c, Row_Key__c = m.Row_Key__c,
                Display_Order__c = m.Display_Order__c, Sign_Multiplier__c = m.Sign_Multiplier__c, Effective_From__c = copy.Effective_From__c));
        }
        new Writer().saveVersion(copy, mappings, audit(companyId, 'REPORT_DEFINITION_VERSIONED', key,
            source.Report_Type__c + ' v' + next + ' drafted from v' + source.Version__c));
        return copy.Id;
    }

    @AuraEnabled
    public static Id activateVersion(Id companyId, Id definitionId, String requestKey) {
        String key = requireKey(requestKey);
        assertManage(companyId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return definitionId;
        }
        Report_Definition__c target = store.definition(definitionId);
        if (target == null || target.Company__c != companyId) {
            throw new ReportMappingException('The report definition does not belong to this Accounting Company.');
        }
        if (target.Status__c != 'Draft') {
            throw new ReportMappingException('Only a Draft version can be activated.');
        }
        List<Report_Definition__c> changes = new List<Report_Definition__c>{ new Report_Definition__c(Id = target.Id, Status__c = 'Active') };
        for (Report_Definition__c d : store.definitions(companyId)) {
            if (d.Id != target.Id && d.Report_Type__c == target.Report_Type__c && d.Status__c == 'Active') {
                changes.add(new Report_Definition__c(Id = d.Id, Status__c = 'Retired',
                    Effective_To__c = target.Effective_From__c == null ? Date.today() : target.Effective_From__c.addDays(-1)));
            }
        }
        new Writer().updateDefinitions(changes, audit(companyId, 'REPORT_DEFINITION_ACTIVATED', key, target.Report_Type__c + ' v' + target.Version__c + ' activated'));
        return target.Id;
    }

    @AuraEnabled
    public static Id deleteDraftVersion(Id companyId, Id definitionId, String requestKey) {
        String key = requireKey(requestKey);
        assertManage(companyId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return definitionId;
        }
        Report_Definition__c target = store.definition(definitionId);
        if (target == null || target.Company__c != companyId) {
            throw new ReportMappingException('The report definition does not belong to this Accounting Company.');
        }
        if (target.Status__c != 'Draft') {
            throw new ReportMappingException('Only a Draft version can be deleted. Active and retired versions are kept for history.');
        }
        Business_Action__c entry = audit(companyId, 'REPORT_DEFINITION_DRAFT_DELETED', key, target.Report_Type__c + ' v' + target.Version__c + ' draft deleted');
        entry.Source_Record_Id__c = String.valueOf(target.Id);
        new Writer().deleteDraft(target, store.mappings(new Set<Id>{ target.Id }), entry);
        return target.Id;
    }

    // ---------------------------------------------------------------- helpers

    private static void assertCompany(Id companyId) {
        if (companyId == null || !SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw new ReportMappingException('You do not have active access to this Accounting Company.');
        }
    }

    private static void assertManage(Id companyId) {
        assertCompany(companyId);
        if (!SABPermissionService.hasPermission(SETUP_PERMISSION)) {
            throw new ReportMappingException('You do not have permission to manage company setup.');
        }
    }

    private static String requireKey(String requestKey) {
        if (String.isBlank(requestKey) || requestKey.trim().length() > 150) {
            throw new ReportMappingException('A request key of up to 150 characters is required.');
        }
        return requestKey.trim();
    }

    private static Business_Action__c audit(Id companyId, String actionName, String key, String reason) {
        return new Business_Action__c(Company__c = companyId, Action__c = actionName, Actor__c = UserInfo.getUserId(), Action_At__c = System.now(),
            Reason__c = reason.left(255), Request_Key__c = key, Source_Type__c = 'Report_Mapping__c', Source_Version__c = 1);
    }

    // System reads after the company and permission checks; definitions and mappings are configuration.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Source_Record_Id__c FROM Business_Action__c WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }

        String companyKey(Id companyId) {
            return [SELECT Company_Key__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE LIMIT 1].Company_Key__c;
        }

        List<Report_Definition__c> definitions(Id companyId) {
            return [SELECT Id, Company__c, Report_Type__c, Version__c, Status__c, Effective_From__c FROM Report_Definition__c
                WHERE Company__c = :companyId AND Report_Type__c IN (:BALANCE_SHEET, :PROFIT_LOSS) WITH SYSTEM_MODE ORDER BY Report_Type__c, Version__c DESC LIMIT 50];
        }

        Report_Definition__c definition(Id definitionId) {
            List<Report_Definition__c> rows = [SELECT Id, Company__c, Report_Type__c, Version__c, Status__c, Effective_From__c FROM Report_Definition__c
                WHERE Id = :definitionId WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }

        Report_Definition__c activeDefinition(Id companyId, String reportType) {
            List<Report_Definition__c> rows = [SELECT Id, Company__c, Report_Type__c, Version__c, Status__c, Effective_From__c FROM Report_Definition__c
                WHERE Company__c = :companyId AND Report_Type__c = :reportType AND Status__c = 'Active' WITH SYSTEM_MODE ORDER BY Version__c DESC LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }

        Decimal maxVersion(Id companyId, String reportType) {
            List<Report_Definition__c> rows = [SELECT Version__c FROM Report_Definition__c WHERE Company__c = :companyId AND Report_Type__c = :reportType
                WITH SYSTEM_MODE ORDER BY Version__c DESC LIMIT 1];
            return rows.isEmpty() || rows[0].Version__c == null ? 0 : rows[0].Version__c;
        }

        List<Report_Mapping__c> mappings(Set<Id> definitionIds) {
            if (definitionIds.isEmpty()) {
                return new List<Report_Mapping__c>();
            }
            return [SELECT Id, Report_Definition__c, GL_Account__c, Group_Key__c, Row_Key__c, Display_Order__c, Sign_Multiplier__c FROM Report_Mapping__c
                WHERE Report_Definition__c IN :definitionIds WITH SYSTEM_MODE ORDER BY Display_Order__c, Row_Key__c LIMIT 5000];
        }

        Report_Mapping__c existing(Id definitionId, Id accountId) {
            List<Report_Mapping__c> rows = [SELECT Id FROM Report_Mapping__c WHERE Report_Definition__c = :definitionId AND GL_Account__c = :accountId WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }

        String groupFor(Id definitionId, String rowKey) {
            List<Report_Mapping__c> rows = [SELECT Group_Key__c FROM Report_Mapping__c WHERE Report_Definition__c = :definitionId AND Row_Key__c = :rowKey WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0].Group_Key__c;
        }

        Decimal orderFor(Id definitionId, String rowKey) {
            List<Report_Mapping__c> same = [SELECT Display_Order__c FROM Report_Mapping__c WHERE Report_Definition__c = :definitionId AND Row_Key__c = :rowKey
                AND Display_Order__c != null WITH SYSTEM_MODE LIMIT 1];
            if (!same.isEmpty()) {
                return same[0].Display_Order__c;
            }
            List<Report_Mapping__c> last = [SELECT Display_Order__c FROM Report_Mapping__c WHERE Report_Definition__c = :definitionId AND Display_Order__c != null
                WITH SYSTEM_MODE ORDER BY Display_Order__c DESC LIMIT 1];
            return last.isEmpty() ? 10 : last[0].Display_Order__c + 10;
        }

        GL_Account__c account(Id accountId) {
            List<GL_Account__c> rows = [SELECT Id, Company__c, Account_Code__c, Account_Type__c, Normal_Balance__c FROM GL_Account__c WHERE Id = :accountId WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }

        List<GL_Account__c> postedAccounts(Id companyId) {
            Set<Id> ids = new Set<Id>();
            for (AggregateResult agg : [SELECT GL_Account__c accountId FROM Journal_Entry_Line__c WHERE Journal_Entry__r.Company__c = :companyId
                    AND Journal_Entry__r.Status__c IN ('Posted', 'Reversed') WITH SYSTEM_MODE GROUP BY GL_Account__c LIMIT 2000]) {
                ids.add((Id) agg.get('accountId'));
            }
            if (ids.isEmpty()) {
                return new List<GL_Account__c>();
            }
            return [SELECT Id, Account_Code__c, Name, Account_Type__c FROM GL_Account__c WHERE Id IN :ids WITH SYSTEM_MODE ORDER BY Account_Code__c];
        }
    }

    // System writes after the company and permission checks.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void saveMapping(Report_Mapping__c row, Business_Action__c entry) {
            upsert as system row;
            entry.Source_Record_Id__c = String.valueOf(row.Id);
            insert as system entry;
        }

        void saveVersion(Report_Definition__c copy, List<Report_Mapping__c> mappings, Business_Action__c entry) {
            insert as system copy;
            for (Report_Mapping__c m : mappings) {
                m.Report_Definition__c = copy.Id;
            }
            insert as system mappings;
            entry.Source_Record_Id__c = String.valueOf(copy.Id);
            insert as system entry;
        }

        void deleteDraft(Report_Definition__c definition, List<Report_Mapping__c> mappings, Business_Action__c entry) {
            if (!mappings.isEmpty()) {
                delete as system mappings;
            }
            delete as system new Report_Definition__c(Id = definition.Id);
            insert as system entry;
        }

        void updateDefinitions(List<Report_Definition__c> rows, Business_Action__c entry) {
            update as system rows;
            entry.Source_Record_Id__c = String.valueOf(rows[0].Id);
            insert as system entry;
        }
    }
}