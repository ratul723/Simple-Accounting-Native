/**
 * G18: Consolidation groups and runs.
 *
 *   saveGroup / saveMember  SAB_Manage_Consolidation   maintain groups and members (grants to the member company required)
 *   calculate               SAB_Manage_Consolidation   new Calculated run for an as-of date: member balances by account code
 *                                                     plus Elimination adjustments for intercompany transactions between members
 *   approve                 SAB_Approve_Consolidation  Calculated -> Approved; the approver differs from the calculator
 *   publish                 SAB_Approve_Consolidation  Approved -> Published; one Published run per group and as-of date
 *   getTrialBalance         read                       consolidated trial balance of a run, with a stale flag
 *
 * Scope (G18): Subsidiary members effective on the as-of date are consolidated in full; members must share the group's
 * presentation currency (translation is a later stage). Joint ventures, associates and non-controlling interests are
 * outside G18 and are reported as excluded. Member balances use the ledger report rules (Posted and Reversed journals,
 * accounting date on or before the as-of date) and are aggregated by GL account code, so members share a chart of
 * account codes (Mapping_Version__c records which). Every run stores a hash of its inputs; approve, publish and the trial
 * balance recompute it and flag runs whose ledgers changed. Consolidation never posts into a company ledger.
 * Every user action needs a grant to every company the group consolidates.
 */
public with sharing class SABConsolidationService {
    public class ConsolidationException extends Exception {}

    private static final String MANAGE = 'SAB_Manage_Consolidation';
    private static final String APPROVE = 'SAB_Approve_Consolidation';
    private static final String SOURCE_TYPE = 'Consolidation_Run__c';
    private static final Set<String> CONTROL_TYPES = new Set<String>{'Subsidiary', 'Joint Venture', 'Associate', 'Other'};

    public class MemberRequest {
        @AuraEnabled public Id groupId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String controlType { get; set; }
        @AuraEnabled public Decimal ownershipPercent { get; set; }
        @AuraEnabled public Date effectiveFrom { get; set; }
        @AuraEnabled public Date effectiveTo { get; set; }
        @AuraEnabled public String mappingVersion { get; set; }
    }

    public class TrialBalanceRow {
        @AuraEnabled public String accountCode;
        @AuraEnabled public String accountName;
        @AuraEnabled public Decimal memberTotal = 0;
        @AuraEnabled public Decimal eliminations = 0;
        @AuraEnabled public Decimal consolidated = 0;
    }

    public class TrialBalance {
        @AuraEnabled public Id runId;
        @AuraEnabled public String status;
        @AuraEnabled public Date asOfDate;
        @AuraEnabled public String presentationCurrency;
        @AuraEnabled public Boolean stale;
        @AuraEnabled public List<String> consolidatedCompanies = new List<String>();
        @AuraEnabled public List<String> excludedMembers = new List<String>();
        @AuraEnabled public List<TrialBalanceRow> rows = new List<TrialBalanceRow>();
    }

    public class ActionResult {
        @AuraEnabled public Id runId;
        @AuraEnabled public String status;
        @AuraEnabled public Integer eliminationCount;
        @AuraEnabled public Boolean replay;
    }

    // Debit-positive balances per account code, the account names, and the companies consolidated.
    private class Snapshot {
        Map<String, Decimal> balances = new Map<String, Decimal>();
        Map<String, String> names = new Map<String, String>();
        List<Consolidation_Member__c> included = new List<Consolidation_Member__c>();
        List<String> excluded = new List<String>();
        List<Consolidation_Adjustment__c> eliminations = new List<Consolidation_Adjustment__c>();
        String hash;
    }

    // ---------------------------------------------------------- master data

    @AuraEnabled
    public static Id saveGroup(Id groupId, String name, String presentationCurrency, String policyVersion) {
        SABPermissionService.assertPermission(MANAGE, 'Consolidation management permission is required.');
        if (String.isBlank(name) || String.isBlank(presentationCurrency) || String.isBlank(policyVersion)) {
            throw new ConsolidationException('Name, presentation currency and policy version are required.');
        }
        Consolidation_Group__c g = groupId == null ? new Consolidation_Group__c(Is_Active__c = true) : new Store().lockGroup(groupId);
        if (groupId != null) {
            assertGrantsToMembers(new Store().members(groupId));
        }
        g.Name = name.trim().left(80);
        g.Presentation_Currency__c = SABMoneyService.normalizeCurrencyCode(presentationCurrency);
        g.Policy_Version__c = policyVersion.trim().left(80);
        new Writer().upsertRecord(g);
        return g.Id;
    }

    @AuraEnabled
    public static Id saveMember(MemberRequest request) {
        SABPermissionService.assertPermission(MANAGE, 'Consolidation management permission is required.');
        if (request == null || request.groupId == null || request.companyId == null || request.effectiveFrom == null
            || String.isBlank(request.mappingVersion) || !CONTROL_TYPES.contains(request.controlType)) {
            throw new ConsolidationException('Group, company, control type, effective-from date and mapping version are required.');
        }
        SABCompanyAccessService.assertCompanyAccess(request.companyId);
        if (request.ownershipPercent != null && (request.ownershipPercent <= 0 || request.ownershipPercent > 100)) {
            throw new ConsolidationException('Ownership percent must be above 0 and at most 100.');
        }
        if (request.effectiveTo != null && request.effectiveTo < request.effectiveFrom) {
            throw new ConsolidationException('Effective-to cannot be before effective-from.');
        }
        Store store = new Store();
        Consolidation_Group__c g = store.lockGroup(request.groupId);
        if (store.functionalCurrency(request.companyId) != g.Presentation_Currency__c) {
            throw new ConsolidationException('Members must use the group\'s presentation currency ' + g.Presentation_Currency__c
                + '; currency translation is outside G18.');
        }
        for (Consolidation_Member__c m : store.members(g.Id)) {
            Boolean overlaps = m.Company__c == request.companyId && (m.Effective_To__c == null || m.Effective_To__c >= request.effectiveFrom)
                && (request.effectiveTo == null || request.effectiveTo >= m.Effective_From__c);
            if (overlaps) {
                throw new ConsolidationException('The company already has an overlapping membership in this group.');
            }
        }
        Consolidation_Member__c member = new Consolidation_Member__c(Consolidation_Group__c = g.Id, Company__c = request.companyId,
            Control_Type__c = request.controlType, Ownership_Percent__c = request.ownershipPercent, Effective_From__c = request.effectiveFrom,
            Effective_To__c = request.effectiveTo, Mapping_Version__c = request.mappingVersion.trim().left(80));
        new Writer().upsertRecord(member);
        return member.Id;
    }

    // ------------------------------------------------------------------ runs

    @AuraEnabled
    public static ActionResult calculate(Id groupId, Date asOfDate, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(MANAGE, 'Consolidation management permission is required.');
        if (groupId == null || asOfDate == null) {
            throw new ConsolidationException('Group and as-of date are required.');
        }
        Store store = new Store();
        Consolidation_Group__c g = store.lockGroup(groupId);
        List<Consolidation_Member__c> members = store.members(g.Id);
        assertGrantsToMembers(members);
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            if (prior.Action__c != 'CONSOLIDATION_CALCULATED') {
                throw new ConsolidationException('Request key has already been used for a different consolidation action.');
            }
            Consolidation_Run__c done = store.lockRun(Id.valueOf(prior.Source_Record_Id__c));
            return result(done, null, true);
        }
        if (g.Is_Active__c != true) {
            throw new ConsolidationException('The consolidation group is not active.');
        }
        Snapshot snap = snapshot(g, members, asOfDate, store);
        if (snap.included.isEmpty()) {
            throw new ConsolidationException('No Subsidiary member is effective on ' + String.valueOf(asOfDate) + '.');
        }
        Integer attempt = store.runCount(g.Id, asOfDate) + 1;
        Consolidation_Run__c run = new Consolidation_Run__c(Consolidation_Group__c = g.Id, As_Of_Date__c = asOfDate, Policy_Version__c = g.Policy_Version__c,
            Status__c = 'Calculated', Result_Hash__c = snap.hash, Run_Key__c = (g.Id + '|' + String.valueOf(asOfDate) + '|' + attempt).left(180));
        new Writer().calculate(run, snap.eliminations, audit(members, 'CONSOLIDATION_CALCULATED', key, null,
            'Consolidated ' + snap.included.size() + ' companies with ' + snap.eliminations.size() + ' eliminations.'));
        return result(run, snap.eliminations.size(), false);
    }

    @AuraEnabled
    public static ActionResult approve(Id runId, String requestKey) {
        return transition(runId, requestKey, 'Calculated', 'Approved', 'CONSOLIDATION_APPROVED');
    }

    @AuraEnabled
    public static ActionResult publish(Id runId, String requestKey) {
        return transition(runId, requestKey, 'Approved', 'Published', 'CONSOLIDATION_PUBLISHED');
    }

    @AuraEnabled
    public static TrialBalance getTrialBalance(Id runId) {
        if (runId == null) {
            throw new ConsolidationException('Consolidation run is required.');
        }
        Store store = new Store();
        Consolidation_Run__c run = store.lockRun(runId);
        Consolidation_Group__c g = store.lockGroup(run.Consolidation_Group__c);
        List<Consolidation_Member__c> members = store.members(g.Id);
        assertGrantsToMembers(members);
        Snapshot snap = snapshot(g, members, run.As_Of_Date__c, store);
        TrialBalance tb = new TrialBalance();
        tb.runId = run.Id;
        tb.status = run.Status__c;
        tb.asOfDate = run.As_Of_Date__c;
        tb.presentationCurrency = g.Presentation_Currency__c;
        tb.stale = snap.hash != run.Result_Hash__c;
        tb.excludedMembers = snap.excluded;
        for (Consolidation_Member__c m : snap.included) {
            tb.consolidatedCompanies.add(m.Company__r.Name__c);
        }
        Map<String, TrialBalanceRow> rows = new Map<String, TrialBalanceRow>();
        for (String code : snap.balances.keySet()) {
            rowFor(rows, code, snap.names).memberTotal = snap.balances.get(code);
        }
        for (Consolidation_Adjustment__c a : store.adjustments(run.Id)) {
            TrialBalanceRow row = rowFor(rows, a.GL_Account_Key__c, snap.names);
            row.eliminations += nz(a.Debit__c) - nz(a.Credit__c);
        }
        List<String> codes = new List<String>(rows.keySet());
        codes.sort();
        for (String code : codes) {
            TrialBalanceRow row = rows.get(code);
            row.consolidated = row.memberTotal + row.eliminations;
            tb.rows.add(row);
        }
        return tb;
    }

    // --------------------------------------------------------------- helpers

    private static ActionResult transition(Id runId, String requestKey, String fromStatus, String toStatus, String actionName) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(APPROVE, 'Consolidation approval permission is required.');
        if (runId == null) {
            throw new ConsolidationException('Consolidation run is required.');
        }
        Store store = new Store();
        Consolidation_Run__c run = store.lockRun(runId);
        Consolidation_Group__c g = store.lockGroup(run.Consolidation_Group__c);
        List<Consolidation_Member__c> members = store.members(g.Id);
        assertGrantsToMembers(members);
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            if (prior.Action__c != actionName || prior.Source_Record_Id__c != String.valueOf(run.Id)) {
                throw new ConsolidationException('Request key has already been used for a different consolidation action.');
            }
            return result(run, null, true);
        }
        if (run.Status__c != fromStatus) {
            throw new ConsolidationException('Only a ' + fromStatus + ' consolidation run can become ' + toStatus + '.');
        }
        if (run.CreatedById == UserInfo.getUserId()) {
            throw new ConsolidationException('The user who calculated a consolidation run cannot approve or publish it.');
        }
        if (snapshot(g, members, run.As_Of_Date__c, store).hash != run.Result_Hash__c) {
            throw new ConsolidationException('Member ledgers or intercompany transactions changed since calculation; calculate a new run.');
        }
        if (toStatus == 'Published' && store.publishedExists(g.Id, run.As_Of_Date__c)) {
            throw new ConsolidationException('A run is already published for this group and date.');
        }
        Consolidation_Run__c change = new Consolidation_Run__c(Id = run.Id, Status__c = toStatus);
        if (toStatus == 'Approved') {
            change.Approved_By__c = UserInfo.getUserId();
            change.Approved_At__c = System.now();
        }
        new Writer().transition(change, audit(members, actionName, key, run.Id, 'Consolidation run ' + toStatus.toLowerCase() + '.'));
        run.Status__c = toStatus;
        return result(run, null, false);
    }

    /** Member balances by account code, eliminations and the input hash for a group at a date. */
    private static Snapshot snapshot(Consolidation_Group__c g, List<Consolidation_Member__c> members, Date asOfDate, Store store) {
        Snapshot snap = new Snapshot();
        Set<Id> companyIds = new Set<Id>();
        for (Consolidation_Member__c m : members) {
            Boolean effective = m.Effective_From__c <= asOfDate && (m.Effective_To__c == null || m.Effective_To__c >= asOfDate);
            if (!effective) {
                continue;
            }
            if (m.Control_Type__c != 'Subsidiary') {
                snap.excluded.add(m.Company__r.Name__c + ' (' + m.Control_Type__c + ': equity method is outside G18)');
            } else if (m.Company__r.Functional_Currency__c != g.Presentation_Currency__c) {
                throw new ConsolidationException(m.Company__r.Name__c + ' does not use the presentation currency ' + g.Presentation_Currency__c + '.');
            } else {
                snap.included.add(m);
                companyIds.add(m.Company__c);
            }
        }
        for (AggregateResult ar : store.balances(companyIds, asOfDate)) {
            String code = (String) ar.get('accountCode');
            Decimal net = nz((Decimal) ar.get('debitTotal')) - nz((Decimal) ar.get('creditTotal'));
            snap.balances.put(code, (snap.balances.containsKey(code) ? snap.balances.get(code) : 0) + net);
            if (!snap.names.containsKey(code)) {
                snap.names.put(code, (String) ar.get('accountName'));
            }
        }
        List<String> hashInput = new List<String>{g.Id, String.valueOf(asOfDate), g.Policy_Version__c};
        List<String> codes = new List<String>(snap.balances.keySet());
        codes.sort();
        for (String code : codes) {
            hashInput.add(code + '=' + snap.balances.get(code).setScale(2, RoundingMode.HALF_UP).toPlainString());
        }
        for (Intercompany_Transaction__c ic : store.intercompany(companyIds, asOfDate)) {
            if (!companyIds.contains(ic.From_Company__c) || !companyIds.contains(ic.To_Company__c)) {
                continue;
            }
            Decimal amount = ic.Agreed_Amount__c;
            // Reverse each side's posting: payable against receivable, counter against counter.
            snap.eliminations.add(adjustment(ic.To_Payable_Account__r.Account_Code__c, amount, 0, ic, 'Eliminate intercompany payable'));
            snap.eliminations.add(adjustment(ic.From_Receivable_Account__r.Account_Code__c, 0, amount, ic, 'Eliminate intercompany receivable'));
            snap.eliminations.add(adjustment(ic.From_Counter_Account__r.Account_Code__c, amount, 0, ic, 'Eliminate intercompany counter (from)'));
            snap.eliminations.add(adjustment(ic.To_Counter_Account__r.Account_Code__c, 0, amount, ic, 'Eliminate intercompany counter (to)'));
            hashInput.add('IC|' + ic.Id + '|' + amount.setScale(2, RoundingMode.HALF_UP).toPlainString());
        }
        snap.hash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(String.join(hashInput, '\n'))));
        return snap;
    }

    private static Consolidation_Adjustment__c adjustment(String accountCode, Decimal debit, Decimal credit, Intercompany_Transaction__c ic,
            String explanation) {
        return new Consolidation_Adjustment__c(Adjustment_Type__c = 'Elimination', GL_Account_Key__c = accountCode, Debit__c = debit,
            Credit__c = credit, Explanation__c = explanation, Source_Reference__c = ('IC|' + ic.Id).left(180));
    }

    private static TrialBalanceRow rowFor(Map<String, TrialBalanceRow> rows, String code, Map<String, String> names) {
        if (!rows.containsKey(code)) {
            TrialBalanceRow row = new TrialBalanceRow();
            row.accountCode = code;
            row.accountName = names.get(code);
            rows.put(code, row);
        }
        return rows.get(code);
    }

    // Consolidation spans companies, so every user action needs a grant to every member company.
    private static void assertGrantsToMembers(List<Consolidation_Member__c> members) {
        Set<Id> checked = new Set<Id>();
        for (Consolidation_Member__c m : members) {
            if (checked.add(m.Company__c)) {
                SABCompanyAccessService.assertCompanyAccess(m.Company__c);
            }
        }
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }

    private static String requireKey(String requestKey) {
        Integer maxLength = Business_Action__c.Request_Key__c.getDescribe().getLength();
        if (String.isBlank(requestKey) || requestKey.trim().length() > maxLength) {
            throw new ConsolidationException('Request key is required and must not exceed ' + maxLength + ' characters.');
        }
        return requestKey.trim();
    }

    private static Business_Action__c audit(List<Consolidation_Member__c> members, String actionName, String key, Id runId, String reason) {
        return new Business_Action__c(Company__c = members.isEmpty() ? null : members[0].Company__c, Action__c = actionName,
            Actor__c = UserInfo.getUserId(), Action_At__c = System.now(), Reason__c = reason, Request_Key__c = key, Source_Type__c = SOURCE_TYPE,
            Source_Record_Id__c = runId == null ? null : String.valueOf(runId), Source_Version__c = 1);
    }

    private static ActionResult result(Consolidation_Run__c run, Integer eliminations, Boolean isReplay) {
        ActionResult r = new ActionResult();
        r.runId = run.Id;
        r.status = run.Status__c;
        r.eliminationCount = eliminations;
        r.replay = isReplay;
        return r;
    }

    /**
     * Narrow system reads after the permission checks and the grant check for every member company. Groups, members and
     * intercompany transactions span companies, so company sharing cannot scope them; the grant checks do.
     */
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
        Consolidation_Group__c lockGroup(Id groupId) {
            List<Consolidation_Group__c> rows = [SELECT Id, Name, Is_Active__c, Policy_Version__c, Presentation_Currency__c FROM Consolidation_Group__c
                WHERE Id = :groupId WITH SYSTEM_MODE FOR UPDATE];
            if (rows.isEmpty()) {
                throw new ConsolidationException('Consolidation group not found.');
            }
            return rows[0];
        }
        List<Consolidation_Member__c> members(Id groupId) {
            return [SELECT Id, Company__c, Company__r.Name__c, Company__r.Functional_Currency__c, Control_Type__c, Ownership_Percent__c,
                Effective_From__c, Effective_To__c FROM Consolidation_Member__c WHERE Consolidation_Group__c = :groupId WITH SYSTEM_MODE
                ORDER BY Company__r.Name__c LIMIT 200];
        }
        Consolidation_Run__c lockRun(Id runId) {
            List<Consolidation_Run__c> rows = [SELECT Id, Consolidation_Group__c, As_Of_Date__c, Status__c, Result_Hash__c, CreatedById
                FROM Consolidation_Run__c WHERE Id = :runId WITH SYSTEM_MODE FOR UPDATE];
            if (rows.isEmpty()) {
                throw new ConsolidationException('Consolidation run not found.');
            }
            return rows[0];
        }
        Integer runCount(Id groupId, Date asOfDate) {
            return [SELECT COUNT() FROM Consolidation_Run__c WHERE Consolidation_Group__c = :groupId AND As_Of_Date__c = :asOfDate WITH SYSTEM_MODE];
        }
        Boolean publishedExists(Id groupId, Date asOfDate) {
            return [SELECT COUNT() FROM Consolidation_Run__c WHERE Consolidation_Group__c = :groupId AND As_Of_Date__c = :asOfDate
                AND Status__c = 'Published' WITH SYSTEM_MODE] > 0;
        }
        List<AggregateResult> balances(Set<Id> companyIds, Date asOfDate) {
            return [SELECT GL_Account__r.Account_Code__c accountCode, MAX(GL_Account__r.Name) accountName, SUM(Debit_Base__c) debitTotal,
                SUM(Credit_Base__c) creditTotal FROM Journal_Entry_Line__c WHERE Journal_Entry__r.Company__c IN :companyIds
                AND Journal_Entry__r.Status__c IN ('Posted', 'Reversed') AND Journal_Entry__r.Accounting_Date__c <= :asOfDate
                WITH SYSTEM_MODE GROUP BY GL_Account__r.Account_Code__c LIMIT 2000];
        }
        List<Intercompany_Transaction__c> intercompany(Set<Id> companyIds, Date asOfDate) {
            return [SELECT Id, From_Company__c, To_Company__c, Agreed_Amount__c, From_Receivable_Account__r.Account_Code__c,
                From_Counter_Account__r.Account_Code__c, To_Payable_Account__r.Account_Code__c, To_Counter_Account__r.Account_Code__c
                FROM Intercompany_Transaction__c WHERE From_Company__c IN :companyIds AND To_Company__c IN :companyIds
                AND Transaction_Date__c <= :asOfDate AND Reconciliation_State__c = 'Matched' WITH SYSTEM_MODE ORDER BY Id LIMIT 5000];
        }
        List<Consolidation_Adjustment__c> adjustments(Id runId) {
            return [SELECT GL_Account_Key__c, Debit__c, Credit__c FROM Consolidation_Adjustment__c WHERE Consolidation_Run__c = :runId
                WITH SYSTEM_MODE LIMIT 10000];
        }
    }

    /** Narrow system writes inside the G18 guard scope, after the service's checks (explicit system mode). */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void upsertRecord(SObject record) {
            if (record.Id == null) {
                insert as system record;
            } else {
                update as system record;
            }
        }
        void calculate(Consolidation_Run__c run, List<Consolidation_Adjustment__c> eliminations, Business_Action__c audit) {
            SABGroupAccountingGuard.beginWrite();
            try {
                insert as system run;
                for (Consolidation_Adjustment__c a : eliminations) {
                    a.Consolidation_Run__c = run.Id;
                }
                insert as system eliminations;
                audit.Source_Record_Id__c = String.valueOf(run.Id);
                insert as system audit;
            } finally {
                SABGroupAccountingGuard.endWrite();
            }
        }
        void transition(Consolidation_Run__c change, Business_Action__c audit) {
            SABGroupAccountingGuard.beginWrite();
            try {
                update as system change;
                insert as system audit;
            } finally {
                SABGroupAccountingGuard.endWrite();
            }
        }
    }
}
