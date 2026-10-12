/**
 * G22G-4: ledger side of the redesigned Banking and reconciliation workspace.
 *
 * Returns the posted journal lines on a bank account's GL account up to the statement end date, with the amount already
 * matched by Proposed or Confirmed reconciliation matches, so the workspace can show the demo's "Posted ledger lines"
 * pane next to the statement lines. Lines with nothing left to match are returned only when they are matched to this
 * statement's reconciliation. Matching, confirming and finalising stay with SABBankReconciliationWorkspaceController,
 * unchanged. Reads run in user mode after the company grant check.
 */
public with sharing class SABBankLedgerLinesController {

    private static final Integer MAX_LINES = 500;
    private static final Set<String> ACTIVE_MATCHES = new Set<String>{ 'Proposed', 'Confirmed' };

    public class LedgerLine {
        @AuraEnabled public Id journalEntryLineId { get; set; }
        @AuraEnabled public Id journalEntryId { get; set; }
        @AuraEnabled public String journalName { get; set; }
        @AuraEnabled public String entryType { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public Decimal matchedAmount { get; set; }
        @AuraEnabled public Decimal remainingAmount { get; set; }
        @AuraEnabled public Boolean matchedHere { get; set; }
    }

    @AuraEnabled
    public static List<LedgerLine> getLedgerLines(Id companyId, Id bankStatementId) {
        if (companyId == null || !SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw auraError('You do not have active access to this Accounting Company.');
        }
        if (bankStatementId == null) {
            throw auraError('A bank statement is required.');
        }
        try {
            Bank_Statement__c statement = [
                SELECT Company__c, Statement_End_Date__c, Bank_Account__r.GL_Account__c
                FROM Bank_Statement__c
                WHERE Id = :bankStatementId
                WITH USER_MODE
                LIMIT 1
            ];
            if (statement.Company__c != companyId) {
                throw auraError('The bank statement does not belong to this Accounting Company.');
            }
            return lines(companyId, statement);
        } catch (QueryException ex) {
            throw auraError('Ledger lines could not be loaded: ' + ex.getMessage());
        }
    }

    private static List<LedgerLine> lines(Id companyId, Bank_Statement__c statement) {
        List<LedgerLine> rows = new List<LedgerLine>();
        Id glAccountId = statement.Bank_Account__r == null ? null : statement.Bank_Account__r.GL_Account__c;
        if (glAccountId == null) {
            return rows;
        }
        Date endDate = statement.Statement_End_Date__c == null ? Date.today() : statement.Statement_End_Date__c;
        Map<Id, LedgerLine> byId = new Map<Id, LedgerLine>();
        for (Journal_Entry_Line__c line : [
            SELECT Id, Journal_Entry__c, Journal_Entry__r.Name, Journal_Entry__r.Entry_Type__c, Journal_Entry__r.Accounting_Date__c,
                   Journal_Entry__r.Description__c, Explanation__c, Debit_Base__c, Credit_Base__c
            FROM Journal_Entry_Line__c
            WHERE GL_Account__c = :glAccountId AND Journal_Entry__r.Company__c = :companyId AND Journal_Entry__r.Status__c = 'Posted'
              AND Journal_Entry__r.Accounting_Date__c <= :endDate
            WITH USER_MODE
            ORDER BY Journal_Entry__r.Accounting_Date__c DESC, Journal_Entry__c, Line_Number__c
            LIMIT :MAX_LINES
        ]) {
            LedgerLine row = new LedgerLine();
            row.journalEntryLineId = line.Id;
            row.journalEntryId = line.Journal_Entry__c;
            row.journalName = line.Journal_Entry__r.Name;
            row.entryType = line.Journal_Entry__r.Entry_Type__c;
            row.accountingDate = line.Journal_Entry__r.Accounting_Date__c;
            row.description = String.isBlank(line.Explanation__c) ? line.Journal_Entry__r.Description__c : line.Explanation__c;
            row.amount = zero(line.Debit_Base__c) - zero(line.Credit_Base__c);
            row.matchedAmount = 0;
            row.matchedHere = false;
            byId.put(line.Id, row);
        }
        if (byId.isEmpty()) {
            return rows;
        }
        Set<Id> lineIds = byId.keySet();
        Id statementId = statement.Id;
        for (Reconciliation_Match__c match : [
            SELECT Journal_Entry_Line__c, Matched_Amount__c, Bank_Reconciliation__r.Bank_Statement__c
            FROM Reconciliation_Match__c
            WHERE Journal_Entry_Line__c IN :lineIds AND Status__c IN :ACTIVE_MATCHES
            WITH USER_MODE
            LIMIT 5000
        ]) {
            LedgerLine row = byId.get(match.Journal_Entry_Line__c);
            row.matchedAmount += zero(match.Matched_Amount__c);
            if (match.Bank_Reconciliation__r != null && match.Bank_Reconciliation__r.Bank_Statement__c == statementId) {
                row.matchedHere = true;
            }
        }
        for (LedgerLine row : byId.values()) {
            row.remainingAmount = remaining(row.amount, row.matchedAmount);
            if (row.remainingAmount != 0 || row.matchedHere) {
                rows.add(row);
            }
        }
        return rows;
    }

    @TestVisible
    private static Decimal remaining(Decimal amount, Decimal matched) {
        Decimal size = amount.abs() - matched.abs();
        if (size <= 0) {
            return 0;
        }
        return amount < 0 ? -size : size;
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
