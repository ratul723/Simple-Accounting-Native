/**
 * G17: Stakeholders, share classes and equity transactions.
 *
 *   saveStakeholder      SAB_Manage_Equity                     create or update a stakeholder (key: company | reference)
 *   saveClass            SAB_Manage_Equity                     create or update a share class and its Equity accounts
 *   saveTransaction      SAB_Manage_Equity                     create or edit a Draft equity transaction
 *   approveTransaction   SAB_Approve_Equity + SAB_Post_Journal  Draft -> Posted; the approver differs from the creator
 *   cancelTransaction    SAB_Manage_Equity                     Draft -> Cancelled with a reason
 *   holdings             read                                  units per stakeholder in a class at a date (posted transactions)
 *
 * Postings (Subledger journals, event type Equity):
 *   Issue                Dr Bank (value) / Cr Capital (units x par) / Cr Premium (value - capital)
 *   Redemption           Dr Capital (units x par) / Dr or Cr Premium (value - capital) / Cr Bank (value); units <= holding
 *   Capital Contribution Dr Bank / Cr Premium (contributed capital); no units
 *   Transfer             units move between two stakeholders of the company; no journal
 * Functional currency only. Every lifecycle action is idempotent by request key and audited.
 */
public with sharing class SABEquityService {
    public class EquityException extends Exception {}

    private static final String MANAGE = 'SAB_Manage_Equity';
    private static final String APPROVE = 'SAB_Approve_Equity';
    private static final String POST_JOURNAL = 'SAB_Post_Journal';
    private static final Set<String> TYPES = new Set<String>{'Issue', 'Transfer', 'Redemption', 'Capital Contribution'};
    private static final String SOURCE_TYPE = 'Equity_Transaction__c';

    public class ClassRequest {
        @AuraEnabled public Id classId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String classCode { get; set; }
        @AuraEnabled public Decimal parValue { get; set; }
        @AuraEnabled public Id capitalAccountId { get; set; }
        @AuraEnabled public Id premiumAccountId { get; set; }
        @AuraEnabled public String rightsMetadata { get; set; }
    }

    public class TransactionRequest {
        @AuraEnabled public Id transactionId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public Id classId { get; set; }
        @AuraEnabled public Id stakeholderId { get; set; }
        @AuraEnabled public Id toStakeholderId { get; set; }
        @AuraEnabled public String transactionType { get; set; }
        @AuraEnabled public Date transactionDate { get; set; }
        @AuraEnabled public Decimal units { get; set; }
        @AuraEnabled public Decimal value { get; set; }
        @AuraEnabled public Id bankAccountId { get; set; }
    }

    public class ActionResult {
        @AuraEnabled public Id transactionId;
        @AuraEnabled public String status;
        @AuraEnabled public Id journalEntryId;
        @AuraEnabled public Boolean replay;
    }

    // --------------------------------------------------------- master data

    @AuraEnabled
    public static Id saveStakeholder(Id companyId, String name, String reference, Id accountId) {
        SABPermissionService.assertPermission(MANAGE, 'Equity management permission is required.');
        if (companyId == null || String.isBlank(name) || String.isBlank(reference)) {
            throw new EquityException('Company, name and reference are required.');
        }
        SABCompanyAccessService.assertCompanyAccess(companyId);
        if (name.trim().length() > 80 || reference.trim().length() > 80) {
            throw new EquityException('Stakeholder name and reference cannot exceed 80 characters.');
        }
        String key = String.valueOf(companyId) + '|' + reference.trim().toUpperCase();
        Stakeholder__c stakeholder = new Store().stakeholderByKey(key);
        if (stakeholder == null) {
            stakeholder = new Stakeholder__c(Company__c = companyId, Stakeholder_Key__c = key, Status__c = 'Active');
        }
        stakeholder.Name = name.trim();
        stakeholder.Stakeholder_Reference__c = reference.trim();
        stakeholder.Account__c = accountId;
        new Writer().upsertRecord(stakeholder);
        return stakeholder.Id;
    }

    @AuraEnabled
    public static Id saveClass(ClassRequest request) {
        SABPermissionService.assertPermission(MANAGE, 'Equity management permission is required.');
        if (request == null || request.companyId == null || String.isBlank(request.name) || String.isBlank(request.classCode)
            || request.capitalAccountId == null || request.premiumAccountId == null) {
            throw new EquityException('Company, name, class code, capital account and premium account are required.');
        }
        SABCompanyAccessService.assertCompanyAccess(request.companyId);
        if (request.parValue == null || request.parValue < 0) {
            throw new EquityException('Par value cannot be negative (use 0 for no-par shares).');
        }
        if (request.capitalAccountId == request.premiumAccountId) {
            throw new EquityException('Capital and premium must be different accounts.');
        }
        for (GL_Account__c a : [SELECT Id, Company__c, Is_Active__c, Account_Type__c FROM GL_Account__c
                WHERE Id IN (:request.capitalAccountId, :request.premiumAccountId) WITH USER_MODE]) {
            if (a.Company__c != request.companyId || a.Is_Active__c != true || a.Account_Type__c != 'Equity') {
                throw new EquityException('Capital and premium accounts must be active Equity accounts of the company.');
            }
        }
        Equity_Class__c equityClass = request.classId == null ? new Equity_Class__c(Company__c = request.companyId)
            : new Store().equityClass(request.classId);
        if (equityClass.Company__c != request.companyId) {
            throw new EquityException('A share class cannot move to another company.');
        }
        equityClass.Name = request.name.trim().left(80);
        equityClass.Class_Code__c = request.classCode.trim().toUpperCase().left(40);
        equityClass.Par_Value__c = request.parValue;
        equityClass.Capital_Account__c = request.capitalAccountId;
        equityClass.Premium_Account__c = request.premiumAccountId;
        equityClass.Rights_Metadata__c = request.rightsMetadata;
        equityClass.Is_Active__c = true;
        new Writer().upsertRecord(equityClass);
        return equityClass.Id;
    }

    // ---------------------------------------------------------- transactions

    @AuraEnabled
    public static Id saveTransaction(TransactionRequest request) {
        SABPermissionService.assertPermission(MANAGE, 'Equity management permission is required.');
        if (request == null || request.companyId == null || request.classId == null || request.stakeholderId == null
            || request.transactionDate == null || request.value == null || !TYPES.contains(request.transactionType)) {
            throw new EquityException('Company, class, stakeholder, transaction type, date and value are required.');
        }
        SABCompanyAccessService.assertCompanyAccess(request.companyId);
        Store store = new Store();
        validateTransaction(request, store);
        Equity_Transaction__c tx;
        if (request.transactionId != null) {
            tx = store.lockTransaction(request.transactionId);
            if (tx.Status__c != 'Draft' || tx.Company__c != request.companyId) {
                throw new EquityException('Only Draft equity transactions of the same company can be edited.');
            }
        } else {
            tx = new Equity_Transaction__c(Company__c = request.companyId, Status__c = 'Draft');
        }
        tx.Equity_Class__c = request.classId;
        tx.Stakeholder__c = request.stakeholderId;
        tx.To_Stakeholder__c = request.toStakeholderId;
        tx.Transaction_Type__c = request.transactionType;
        tx.Transaction_Date__c = request.transactionDate;
        tx.Units__c = request.units;
        tx.Value__c = request.value.setScale(2, RoundingMode.HALF_UP);
        tx.Bank_Account__c = request.bankAccountId;
        tx.Currency__c = store.functionalCurrency(request.companyId);
        new Writer().upsertRecord(tx);
        return tx.Id;
    }

    @AuraEnabled
    public static ActionResult approveTransaction(Id transactionId, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(APPROVE, 'Equity approval permission is required.');
        SABPermissionService.assertPermission(POST_JOURNAL, 'Journal posting permission is required.');
        Store store = new Store();
        Equity_Transaction__c tx = visibleTransaction(transactionId, store);
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, tx.Id, 'EQUITY_TRANSACTION_POSTED', store);
        }
        tx = store.lockTransaction(transactionId);
        if (tx.Status__c != 'Draft') {
            throw new EquityException('Only a Draft equity transaction can be approved.');
        }
        if (tx.CreatedById == UserInfo.getUserId()) {
            throw new EquityException('The creator of an equity transaction cannot approve it.');
        }
        TransactionRequest request = new TransactionRequest();
        request.companyId = tx.Company__c;
        request.classId = tx.Equity_Class__c;
        request.stakeholderId = tx.Stakeholder__c;
        request.toStakeholderId = tx.To_Stakeholder__c;
        request.transactionType = tx.Transaction_Type__c;
        request.transactionDate = tx.Transaction_Date__c;
        request.units = tx.Units__c;
        request.value = tx.Value__c;
        request.bankAccountId = tx.Bank_Account__c;
        request.transactionId = tx.Id;
        Equity_Class__c equityClass = validateTransaction(request, store);
        Savepoint sp = Database.setSavepoint();
        try {
            SABPostingService.PostingResult postingResult;
            if (tx.Transaction_Type__c != 'Transfer') {
                postingResult = postTransaction(tx, equityClass, key, store);
            }
            new Writer().approve(new Equity_Transaction__c(Id = tx.Id, Status__c = 'Posted', Approved_By__c = UserInfo.getUserId(),
                Approved_At__c = System.now(), Journal_Entry__c = postingResult == null ? null : postingResult.journalEntryId,
                Accounting_Event__c = postingResult == null ? null : postingResult.accountingEventId),
                audit(tx.Company__c, 'EQUITY_TRANSACTION_POSTED', key, tx.Id, tx.Transaction_Type__c + ' approved and posted.'));
            return result(tx.Id, 'Posted', postingResult == null ? null : postingResult.journalEntryId, false);
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
    }

    @AuraEnabled
    public static ActionResult cancelTransaction(Id transactionId, String reason, String requestKey) {
        String key = requireKey(requestKey);
        if (String.isBlank(reason) || reason.trim().length() > 255) {
            throw new EquityException('A reason of up to 255 characters is required.');
        }
        SABPermissionService.assertPermission(MANAGE, 'Equity management permission is required.');
        Store store = new Store();
        Equity_Transaction__c tx = visibleTransaction(transactionId, store);
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, tx.Id, 'EQUITY_TRANSACTION_CANCELLED', store);
        }
        tx = store.lockTransaction(transactionId);
        if (tx.Status__c != 'Draft') {
            throw new EquityException('Only a Draft equity transaction can be cancelled.');
        }
        new Writer().approve(new Equity_Transaction__c(Id = tx.Id, Status__c = 'Cancelled'),
            audit(tx.Company__c, 'EQUITY_TRANSACTION_CANCELLED', key, tx.Id, reason.trim()));
        return result(tx.Id, 'Cancelled', null, false);
    }

    /** Units held per stakeholder in a class from posted transactions dated on or before asOf (zero holdings omitted). */
    public static Map<Id, Decimal> holdings(Id classId, Date asOf) {
        Map<Id, Decimal> units = new Map<Id, Decimal>();
        for (Equity_Transaction__c t : new Store().postedTransactions(classId, asOf)) {
            Decimal u = t.Units__c == null ? 0 : t.Units__c;
            if (t.Transaction_Type__c == 'Issue') {
                add(units, t.Stakeholder__c, u);
            } else if (t.Transaction_Type__c == 'Redemption') {
                add(units, t.Stakeholder__c, -u);
            } else if (t.Transaction_Type__c == 'Transfer') {
                add(units, t.Stakeholder__c, -u);
                add(units, t.To_Stakeholder__c, u);
            }
        }
        for (Id holder : new List<Id>(units.keySet())) {
            if (units.get(holder) == 0) {
                units.remove(holder);
            }
        }
        return units;
    }

    // --------------------------------------------------------------- helpers

    private static void add(Map<Id, Decimal> units, Id holder, Decimal delta) {
        units.put(holder, (units.containsKey(holder) ? units.get(holder) : 0) + delta);
    }

    private static Equity_Class__c validateTransaction(TransactionRequest r, Store store) {
        Equity_Class__c equityClass = store.equityClass(r.classId);
        if (equityClass.Company__c != r.companyId || equityClass.Is_Active__c != true) {
            throw new EquityException('The share class must be an active class of the company.');
        }
        Map<Id, Stakeholder__c> holders = store.stakeholders(new Set<Id>{r.stakeholderId, r.toStakeholderId});
        Stakeholder__c fromHolder = holders.get(r.stakeholderId);
        if (fromHolder == null || fromHolder.Company__c != r.companyId || fromHolder.Status__c == 'Inactive') {
            throw new EquityException('The stakeholder must be an active stakeholder of the company.');
        }
        Boolean needsUnits = r.transactionType != 'Capital Contribution';
        if (needsUnits && (r.units == null || r.units <= 0)) {
            throw new EquityException(r.transactionType + ' needs units greater than zero.');
        }
        if (!needsUnits && r.units != null && r.units != 0) {
            throw new EquityException('A capital contribution does not issue units.');
        }
        if (r.transactionType == 'Transfer') {
            Stakeholder__c toHolder = holders.get(r.toStakeholderId);
            if (toHolder == null || toHolder.Company__c != r.companyId || toHolder.Id == fromHolder.Id || toHolder.Status__c == 'Inactive') {
                throw new EquityException('A transfer needs a different, active receiving stakeholder of the company.');
            }
            if (r.value < 0) {
                throw new EquityException('Transfer value cannot be negative.');
            }
        } else {
            if (r.value <= 0) {
                throw new EquityException(r.transactionType + ' value must be greater than zero.');
            }
            Bank_Account__c bank = r.bankAccountId == null ? null : store.bank(r.bankAccountId);
            if (bank == null || bank.Company__c != r.companyId || bank.Is_Active__c != true
                    || bank.Currency__c != store.functionalCurrency(r.companyId)) {
                throw new EquityException('An active functional-currency bank account of the company is required.');
            }
        }
        if (r.transactionType == 'Issue' && (r.units * nz(equityClass.Par_Value__c)).setScale(2, RoundingMode.HALF_UP) > r.value) {
            throw new EquityException('Shares cannot be issued below par value.');
        }
        if (r.transactionType == 'Redemption' || r.transactionType == 'Transfer') {
            Map<Id, Decimal> held = holdings(r.classId, r.transactionDate);
            Decimal available = held.containsKey(fromHolder.Id) ? held.get(fromHolder.Id) : 0;
            if (r.units > available) {
                throw new EquityException('The stakeholder holds ' + available.stripTrailingZeros().toPlainString() + ' units on '
                    + String.valueOf(r.transactionDate) + '.');
            }
        }
        return equityClass;
    }

    private static SABPostingService.PostingResult postTransaction(Equity_Transaction__c tx, Equity_Class__c equityClass, String key, Store store) {
        Id bankGl = store.bank(tx.Bank_Account__c).GL_Account__c;
        Decimal value = tx.Value__c;
        Decimal capital = tx.Transaction_Type__c == 'Capital Contribution' ? 0
            : (nz(tx.Units__c) * nz(equityClass.Par_Value__c)).setScale(2, RoundingMode.HALF_UP);
        Decimal premium = value - capital;
        List<SABSubledgerPostingHelper.LineSpec> lines = new List<SABSubledgerPostingHelper.LineSpec>();
        if (tx.Transaction_Type__c == 'Redemption') {
            lines.add(new SABSubledgerPostingHelper.LineSpec(equityClass.Capital_Account__c, capital, 'Share capital redeemed'));
            lines.add(new SABSubledgerPostingHelper.LineSpec(equityClass.Premium_Account__c, premium, 'Premium on redemption'));
            lines.add(new SABSubledgerPostingHelper.LineSpec(bankGl, -value, 'Redemption paid'));
        } else {
            lines.add(new SABSubledgerPostingHelper.LineSpec(bankGl, value, tx.Transaction_Type__c + ' received'));
            lines.add(new SABSubledgerPostingHelper.LineSpec(equityClass.Capital_Account__c, -capital, 'Share capital'));
            lines.add(new SABSubledgerPostingHelper.LineSpec(equityClass.Premium_Account__c, -premium, 'Share premium / contributed capital'));
        }
        SABSubledgerPostingHelper.PostingSpec spec = new SABSubledgerPostingHelper.PostingSpec();
        spec.companyId = tx.Company__c;
        spec.accountingDate = tx.Transaction_Date__c;
        spec.description = ('Equity ' + tx.Transaction_Type__c.toLowerCase() + ' ' + equityClass.Class_Code__c).left(255);
        spec.adapterKey = 'EQUITY';
        spec.eventKey = 'EQUITY|' + tx.Id;
        spec.eventType = 'Equity';
        spec.sourceType = SOURCE_TYPE;
        spec.sourceRecordId = tx.Id;
        spec.sourceBusinessKey = 'EQUITY|' + equityClass.Class_Code__c + '|' + tx.Id;
        spec.requestKey = key;
        spec.lines = lines;
        return SABSubledgerPostingHelper.post(spec);
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }

    private static Equity_Transaction__c visibleTransaction(Id transactionId, Store store) {
        if (transactionId == null) {
            throw new EquityException('Equity transaction is required.');
        }
        List<Equity_Transaction__c> rows = [SELECT Id, Company__c FROM Equity_Transaction__c WHERE Id = :transactionId WITH USER_MODE];
        if (rows.isEmpty()) {
            throw new EquityException('Equity transaction not found or not accessible.');
        }
        SABCompanyAccessService.assertCompanyAccess(rows[0].Company__c);
        return rows[0];
    }

    private static String requireKey(String requestKey) {
        Integer maxLength = Business_Action__c.Request_Key__c.getDescribe().getLength();
        if (String.isBlank(requestKey) || requestKey.trim().length() > maxLength) {
            throw new EquityException('Request key is required and must not exceed ' + maxLength + ' characters.');
        }
        return requestKey.trim();
    }

    private static ActionResult replay(Business_Action__c prior, Id transactionId, String expectedAction, Store store) {
        if (prior.Action__c != expectedAction || prior.Source_Record_Id__c != String.valueOf(transactionId)) {
            throw new EquityException('Request key has already been used for a different equity action.');
        }
        Equity_Transaction__c tx = store.lockTransaction(transactionId);
        return result(tx.Id, tx.Status__c, tx.Journal_Entry__c, true);
    }

    private static Business_Action__c audit(Id companyId, String actionName, String key, Id recordId, String reason) {
        return new Business_Action__c(Company__c = companyId, Action__c = actionName, Actor__c = UserInfo.getUserId(),
            Action_At__c = System.now(), Reason__c = reason, Request_Key__c = key, Source_Type__c = SOURCE_TYPE,
            Source_Record_Id__c = String.valueOf(recordId), Source_Version__c = 1);
    }

    private static ActionResult result(Id transactionId, String status, Id journalId, Boolean isReplay) {
        ActionResult r = new ActionResult();
        r.transactionId = transactionId;
        r.status = status;
        r.journalEntryId = journalId;
        r.replay = isReplay;
        return r;
    }

    /** Narrow system reads after the permission and company checks; holdings use every posted transaction of the class. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c FROM Business_Action__c WHERE Request_Key__c = :key
                WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        String functionalCurrency(Id companyId) {
            return [SELECT Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE].Functional_Currency__c;
        }
        Stakeholder__c stakeholderByKey(String key) {
            List<Stakeholder__c> rows = [SELECT Id, Name, Company__c FROM Stakeholder__c WHERE Stakeholder_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        Map<Id, Stakeholder__c> stakeholders(Set<Id> ids) {
            return new Map<Id, Stakeholder__c>([SELECT Id, Company__c, Status__c FROM Stakeholder__c WHERE Id IN :ids WITH SYSTEM_MODE]);
        }
        Equity_Class__c equityClass(Id classId) {
            List<Equity_Class__c> rows = [SELECT Id, Company__c, Class_Code__c, Is_Active__c, Par_Value__c, Capital_Account__c, Premium_Account__c
                FROM Equity_Class__c WHERE Id = :classId WITH SYSTEM_MODE];
            if (rows.isEmpty()) {
                throw new EquityException('Share class not found.');
            }
            return rows[0];
        }
        Bank_Account__c bank(Id bankAccountId) {
            List<Bank_Account__c> rows = [SELECT Id, Company__c, Is_Active__c, Currency__c, GL_Account__c FROM Bank_Account__c
                WHERE Id = :bankAccountId WITH SYSTEM_MODE];
            return rows.isEmpty() ? null : rows[0];
        }
        Equity_Transaction__c lockTransaction(Id transactionId) {
            List<Equity_Transaction__c> rows = [SELECT Id, Company__c, Equity_Class__c, Stakeholder__c, To_Stakeholder__c, Transaction_Type__c,
                Transaction_Date__c, Units__c, Value__c, Bank_Account__c, Status__c, Journal_Entry__c, CreatedById FROM Equity_Transaction__c
                WHERE Id = :transactionId WITH SYSTEM_MODE FOR UPDATE];
            if (rows.isEmpty()) {
                throw new EquityException('Equity transaction not found.');
            }
            return rows[0];
        }
        List<Equity_Transaction__c> postedTransactions(Id classId, Date asOf) {
            return [SELECT Stakeholder__c, To_Stakeholder__c, Transaction_Type__c, Units__c FROM Equity_Transaction__c
                WHERE Equity_Class__c = :classId AND Status__c = 'Posted' AND Transaction_Date__c <= :asOf WITH SYSTEM_MODE LIMIT 50000];
        }
    }

    /** Narrow system writes inside the G17 guard scope, after the service's checks (explicit system mode). */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void upsertRecord(SObject record) {
            SABEquityGuard.beginWrite();
            try {
                // Generic SObjects cannot be upserted; insert new records and update existing ones.
                if (record.Id == null) {
                    insert as system record;
                } else {
                    update as system record;
                }
            } finally {
                SABEquityGuard.endWrite();
            }
        }
        void approve(Equity_Transaction__c tx, Business_Action__c audit) {
            SABEquityGuard.beginWrite();
            try {
                update as system tx;
                insert as system audit;
            } finally {
                SABEquityGuard.endWrite();
            }
        }
    }
}
