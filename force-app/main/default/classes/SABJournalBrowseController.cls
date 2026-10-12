/**
 * G22G-1: read model for the redesigned Journals and Journal reversals workspaces.
 *
 * Adds what the demo layout needs and SABJournalWorkspaceController does not return: every journal of the company
 * with its status, entry type, debit total, poster and reversal links, the chart of accounts with control flags (so
 * the editor can warn about control accounts as it is typed), and every period with its dates and status (so the
 * editor can show the period of an accounting date). Writes stay with SABJournalWorkspaceController (saveDraft,
 * validateJournal, postJournal, reverseJournal), unchanged.
 *
 * Reads run in user mode after the company grant check, so journals the user cannot see are not returned.
 */
public with sharing class SABJournalBrowseController {

    private static final Integer MAX_JOURNALS = 300;

    public class BrowseData {
        @AuraEnabled public List<JournalRow> journals { get; set; }
        @AuraEnabled public List<AccountRow> accounts { get; set; }
        @AuraEnabled public List<PeriodRow> periods { get; set; }
    }

    public class JournalRow {
        @AuraEnabled public Id journalId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public String entryType { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Decimal totalDebit { get; set; }
        @AuraEnabled public String periodKey { get; set; }
        @AuraEnabled public String postedBy { get; set; }
        @AuraEnabled public Datetime postedAt { get; set; }
        @AuraEnabled public String postingKey { get; set; }
        @AuraEnabled public Id accountingEventId { get; set; }
        @AuraEnabled public String accountingEventName { get; set; }
        @AuraEnabled public Id reversalOfId { get; set; }
        @AuraEnabled public String reversalOfName { get; set; }
        @AuraEnabled public Id reversalJournalId { get; set; }
        @AuraEnabled public String reversalJournalName { get; set; }
        @AuraEnabled public String createdBy { get; set; }
    }

    public class AccountRow {
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public String code { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String accountType { get; set; }
        @AuraEnabled public Boolean manualPostingAllowed { get; set; }
        @AuraEnabled public String controlType { get; set; }
        @AuraEnabled public Boolean active { get; set; }
    }

    public class PeriodRow {
        @AuraEnabled public Id periodId { get; set; }
        @AuraEnabled public String periodKey { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date endDate { get; set; }
        @AuraEnabled public String status { get; set; }
    }

    @AuraEnabled
    public static BrowseData getBrowseData(Id companyId) {
        if (companyId == null || !SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw auraError('You do not have active access to this Accounting Company.');
        }
        try {
            BrowseData data = new BrowseData();
            data.journals = journals(companyId);
            data.accounts = accounts(companyId);
            data.periods = periods(companyId);
            return data;
        } catch (QueryException ex) {
            throw auraError('Journals could not be loaded: ' + ex.getMessage());
        }
    }

    private static List<JournalRow> journals(Id companyId) {
        Map<Id, JournalRow> byId = new Map<Id, JournalRow>();
        List<JournalRow> rows = new List<JournalRow>();
        for (Journal_Entry__c journal : [
            SELECT Id, Name, Accounting_Date__c, Description__c, Entry_Type__c, Status__c, Accounting_Period__r.Period_Key__c,
                   Posted_By__r.Name, Posted_At__c, Posting_Key__c, Accounting_Event__c, Accounting_Event__r.Name,
                   Reversal_Of__c, Reversal_Of__r.Name, Reversal_Journal__c, Reversal_Journal__r.Name, CreatedBy.Name
            FROM Journal_Entry__c
            WHERE Company__c = :companyId
            WITH USER_MODE
            ORDER BY Accounting_Date__c DESC, Name DESC
            LIMIT :MAX_JOURNALS
        ]) {
            JournalRow row = new JournalRow();
            row.journalId = journal.Id;
            row.name = journal.Name;
            row.accountingDate = journal.Accounting_Date__c;
            row.description = journal.Description__c;
            row.entryType = journal.Entry_Type__c;
            row.status = journal.Status__c;
            row.totalDebit = 0;
            row.periodKey = journal.Accounting_Period__r == null ? null : journal.Accounting_Period__r.Period_Key__c;
            row.postedBy = journal.Posted_By__r == null ? null : journal.Posted_By__r.Name;
            row.postedAt = journal.Posted_At__c;
            row.postingKey = journal.Posting_Key__c;
            row.accountingEventId = journal.Accounting_Event__c;
            row.accountingEventName = journal.Accounting_Event__r == null ? null : journal.Accounting_Event__r.Name;
            row.reversalOfId = journal.Reversal_Of__c;
            row.reversalOfName = journal.Reversal_Of__r == null ? null : journal.Reversal_Of__r.Name;
            row.reversalJournalId = journal.Reversal_Journal__c;
            row.reversalJournalName = journal.Reversal_Journal__r == null ? null : journal.Reversal_Journal__r.Name;
            row.createdBy = journal.CreatedBy == null ? null : journal.CreatedBy.Name;
            byId.put(journal.Id, row);
            rows.add(row);
        }
        if (byId.isEmpty()) {
            return rows;
        }
        Set<Id> journalIds = byId.keySet();
        for (AggregateResult agg : [
            SELECT Journal_Entry__c journalId, SUM(Debit_Base__c) debitTotal
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__c IN :journalIds
            WITH USER_MODE
            GROUP BY Journal_Entry__c
        ]) {
            Decimal total = (Decimal) agg.get('debitTotal');
            byId.get((Id) agg.get('journalId')).totalDebit = total == null ? 0 : total;
        }
        return rows;
    }

    private static List<AccountRow> accounts(Id companyId) {
        List<AccountRow> rows = new List<AccountRow>();
        for (GL_Account__c account : [
            SELECT Id, Account_Code__c, Name, Account_Type__c, Manual_Posting_Allowed__c, Control_Type__c, Is_Active__c
            FROM GL_Account__c
            WHERE Company__c = :companyId
            WITH USER_MODE
            ORDER BY Account_Code__c
            LIMIT 2000
        ]) {
            AccountRow row = new AccountRow();
            row.accountId = account.Id;
            row.code = account.Account_Code__c;
            row.name = account.Name;
            row.accountType = account.Account_Type__c;
            row.manualPostingAllowed = account.Manual_Posting_Allowed__c == true;
            row.controlType = account.Control_Type__c;
            row.active = account.Is_Active__c == true;
            rows.add(row);
        }
        return rows;
    }

    private static List<PeriodRow> periods(Id companyId) {
        List<PeriodRow> rows = new List<PeriodRow>();
        for (Accounting_Period__c period : [
            SELECT Id, Period_Key__c, Start_Date__c, End_Date__c, Status__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
            WITH USER_MODE
            ORDER BY Start_Date__c
            LIMIT 400
        ]) {
            PeriodRow row = new PeriodRow();
            row.periodId = period.Id;
            row.periodKey = period.Period_Key__c;
            row.startDate = period.Start_Date__c;
            row.endDate = period.End_Date__c;
            row.status = period.Status__c;
            rows.add(row);
        }
        return rows;
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
