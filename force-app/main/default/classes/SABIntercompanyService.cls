/**
 * G18: Intercompany transactions.
 *
 *   recordTransaction  SAB_Manage_Intercompany + SAB_Post_Journal, with grants to both companies
 *     From company  Dr Intercompany receivable (Asset) / Cr counter account (for example intercompany revenue)
 *     To company    Dr counter account (for example intercompany expense) / Cr Intercompany payable (Liability)
 *   Both sides post the agreed amount as Subledger journals on the transaction date (event type Intercompany), so the
 *   transaction is Matched. Both companies must share the transaction currency as functional currency. Idempotent and audited.
 */
public with sharing class SABIntercompanyService {
    public class IntercompanyException extends Exception {}

    private static final String MANAGE = 'SAB_Manage_Intercompany';
    private static final String POST_JOURNAL = 'SAB_Post_Journal';
    private static final String SOURCE_TYPE = 'Intercompany_Transaction__c';

    public class IntercompanyRequest {
        @AuraEnabled public Id fromCompanyId { get; set; }
        @AuraEnabled public Id toCompanyId { get; set; }
        @AuraEnabled public Date transactionDate { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Id fromReceivableAccountId { get; set; }
        @AuraEnabled public Id fromCounterAccountId { get; set; }
        @AuraEnabled public Id toPayableAccountId { get; set; }
        @AuraEnabled public Id toCounterAccountId { get; set; }
    }

    public class ActionResult {
        @AuraEnabled public Id transactionId;
        @AuraEnabled public Id fromJournalId;
        @AuraEnabled public Id toJournalId;
        @AuraEnabled public String reconciliationState;
        @AuraEnabled public Boolean replay;
    }

    @AuraEnabled
    public static ActionResult recordTransaction(IntercompanyRequest request, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(MANAGE, 'Intercompany permission is required.');
        SABPermissionService.assertPermission(POST_JOURNAL, 'Journal posting permission is required.');
        if (request == null || request.fromCompanyId == null || request.toCompanyId == null || request.transactionDate == null
            || request.amount == null || String.isBlank(request.description)) {
            throw new IntercompanyException('From company, to company, date, amount and description are required.');
        }
        if (request.fromCompanyId == request.toCompanyId) {
            throw new IntercompanyException('An intercompany transaction needs two different companies.');
        }
        SABCompanyAccessService.assertCompanyAccess(request.fromCompanyId);
        SABCompanyAccessService.assertCompanyAccess(request.toCompanyId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            if (prior.Action__c != 'INTERCOMPANY_RECORDED') {
                throw new IntercompanyException('Request key has already been used for a different action.');
            }
            Intercompany_Transaction__c done = store.transactionById(Id.valueOf(prior.Source_Record_Id__c));
            return result(done, true);
        }
        Decimal amount = request.amount.setScale(2, RoundingMode.HALF_UP);
        if (amount <= 0) {
            throw new IntercompanyException('The agreed amount must be greater than zero.');
        }
        if (request.description.trim().length() > 255) {
            throw new IntercompanyException('Description cannot exceed 255 characters.');
        }
        Map<Id, Accounting_Company__c> companies = store.companies(new Set<Id>{request.fromCompanyId, request.toCompanyId});
        String currencyCode = companies.get(request.fromCompanyId).Functional_Currency__c;
        if (companies.get(request.toCompanyId).Functional_Currency__c != currencyCode) {
            throw new IntercompanyException('Both companies must share the same functional currency in G18.');
        }
        validateAccount(request.fromReceivableAccountId, request.fromCompanyId, new Set<String>{'Asset'}, 'From receivable', store);
        validateAccount(request.fromCounterAccountId, request.fromCompanyId, new Set<String>{'Revenue', 'Expense', 'Asset', 'Liability'},
            'From counter', store);
        validateAccount(request.toPayableAccountId, request.toCompanyId, new Set<String>{'Liability'}, 'To payable', store);
        validateAccount(request.toCounterAccountId, request.toCompanyId, new Set<String>{'Revenue', 'Expense', 'Asset', 'Liability'},
            'To counter', store);
        Intercompany_Transaction__c tx = new Intercompany_Transaction__c(From_Company__c = request.fromCompanyId, To_Company__c = request.toCompanyId,
            Transaction_Date__c = request.transactionDate, Agreed_Amount__c = amount, Currency__c = currencyCode,
            Description__c = request.description.trim(), From_Receivable_Account__c = request.fromReceivableAccountId,
            From_Counter_Account__c = request.fromCounterAccountId, To_Payable_Account__c = request.toPayableAccountId,
            To_Counter_Account__c = request.toCounterAccountId, Reconciliation_State__c = 'Open');
        Savepoint sp = Database.setSavepoint();
        try {
            Writer writer = new Writer();
            writer.insertTransaction(tx);
            Id fromJournal = post(tx, 'FROM', tx.From_Company__c, key, new List<SABSubledgerPostingHelper.LineSpec>{
                new SABSubledgerPostingHelper.LineSpec(tx.From_Receivable_Account__c, amount, 'Intercompany receivable'),
                new SABSubledgerPostingHelper.LineSpec(tx.From_Counter_Account__c, -amount, tx.Description__c)});
            Id toJournal = post(tx, 'TO', tx.To_Company__c, key + '|TO', new List<SABSubledgerPostingHelper.LineSpec>{
                new SABSubledgerPostingHelper.LineSpec(tx.To_Counter_Account__c, amount, tx.Description__c),
                new SABSubledgerPostingHelper.LineSpec(tx.To_Payable_Account__c, -amount, 'Intercompany payable')});
            tx.From_Journal__c = fromJournal;
            tx.To_Journal__c = toJournal;
            tx.From_Document_Key__c = 'IC|' + tx.Id + '|FROM';
            tx.To_Document_Key__c = 'IC|' + tx.Id + '|TO';
            tx.Reconciliation_State__c = 'Matched';
            writer.complete(tx, new Business_Action__c(Company__c = tx.From_Company__c, Action__c = 'INTERCOMPANY_RECORDED',
                Actor__c = UserInfo.getUserId(), Action_At__c = System.now(), Request_Key__c = key, Source_Type__c = SOURCE_TYPE,
                Source_Record_Id__c = String.valueOf(tx.Id), Source_Version__c = 1,
                Reason__c = ('Intercompany ' + amount + ' ' + currencyCode + ': ' + tx.Description__c).left(255)));
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
        return result(tx, false);
    }

    private static Id post(Intercompany_Transaction__c tx, String side, Id companyId, String key, List<SABSubledgerPostingHelper.LineSpec> lines) {
        SABSubledgerPostingHelper.PostingSpec spec = new SABSubledgerPostingHelper.PostingSpec();
        spec.companyId = companyId;
        spec.accountingDate = tx.Transaction_Date__c;
        spec.description = ('Intercompany ' + side.toLowerCase() + ': ' + tx.Description__c).left(255);
        spec.adapterKey = 'INTERCOMPANY';
        spec.eventKey = 'IC|' + tx.Id + '|' + side;
        spec.eventType = 'Intercompany';
        spec.sourceType = SOURCE_TYPE;
        spec.sourceRecordId = tx.Id;
        spec.sourceBusinessKey = 'IC|' + tx.Id + '|' + side;
        spec.requestKey = key;
        spec.lines = lines;
        return SABSubledgerPostingHelper.post(spec).journalEntryId;
    }

    private static void validateAccount(Id accountId, Id companyId, Set<String> types, String label, Store store) {
        GL_Account__c a = accountId == null ? null : store.account(accountId);
        if (a == null || a.Company__c != companyId || a.Is_Active__c != true || !types.contains(a.Account_Type__c)) {
            throw new IntercompanyException(label + ' account must be an active ' + String.join(new List<String>(types), '/')
                + ' account of its company.');
        }
    }

    private static String requireKey(String requestKey) {
        Integer maxLength = Business_Action__c.Request_Key__c.getDescribe().getLength() - 3;
        if (String.isBlank(requestKey) || requestKey.trim().length() > maxLength) {
            throw new IntercompanyException('Request key is required and must not exceed ' + maxLength + ' characters.');
        }
        return requestKey.trim();
    }

    private static ActionResult result(Intercompany_Transaction__c tx, Boolean isReplay) {
        ActionResult r = new ActionResult();
        r.transactionId = tx.Id;
        r.fromJournalId = tx.From_Journal__c;
        r.toJournalId = tx.To_Journal__c;
        r.reconciliationState = tx.Reconciliation_State__c;
        r.replay = isReplay;
        return r;
    }

    /** Narrow system reads after the permission and two-company grant checks. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c FROM Business_Action__c WHERE Request_Key__c = :key
                WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        Map<Id, Accounting_Company__c> companies(Set<Id> ids) {
            return new Map<Id, Accounting_Company__c>([SELECT Id, Functional_Currency__c FROM Accounting_Company__c WHERE Id IN :ids WITH SYSTEM_MODE]);
        }
        GL_Account__c account(Id accountId) {
            List<GL_Account__c> rows = [SELECT Id, Company__c, Is_Active__c, Account_Type__c FROM GL_Account__c WHERE Id = :accountId WITH SYSTEM_MODE];
            return rows.isEmpty() ? null : rows[0];
        }
        Intercompany_Transaction__c transactionById(Id txId) {
            return [SELECT Id, From_Journal__c, To_Journal__c, Reconciliation_State__c FROM Intercompany_Transaction__c WHERE Id = :txId
                WITH SYSTEM_MODE];
        }
    }

    /** Narrow system writes inside the G18 guard scope, after the service's checks (explicit system mode). */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void insertTransaction(Intercompany_Transaction__c tx) {
            SABGroupAccountingGuard.beginWrite();
            try {
                insert as system tx;
            } finally {
                SABGroupAccountingGuard.endWrite();
            }
        }
        void complete(Intercompany_Transaction__c tx, Business_Action__c audit) {
            SABGroupAccountingGuard.beginWrite();
            try {
                update as system new Intercompany_Transaction__c(Id = tx.Id, From_Journal__c = tx.From_Journal__c, To_Journal__c = tx.To_Journal__c,
                    From_Document_Key__c = tx.From_Document_Key__c, To_Document_Key__c = tx.To_Document_Key__c,
                    Reconciliation_State__c = tx.Reconciliation_State__c);
                insert as system audit;
            } finally {
                SABGroupAccountingGuard.endWrite();
            }
        }
    }
}
