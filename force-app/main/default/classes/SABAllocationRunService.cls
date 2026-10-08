/**
 * G14: Allocation runs.
 *
 *   preview   SAB_Manage_Allocation                   calculate an Approved rule for an Open period -> Preview run
 *   approve   SAB_Approve_Allocation                  Preview -> Approved; approver differs from the preparer
 *   post      SAB_Manage_Allocation + SAB_Post_Journal Approved -> Posted: re-checks the source balances against the
 *                                                     preview, then posts a Subledger journal through SABPostingService
 *                                                     (event type Allocation, source record = the run)
 *   discard   SAB_Manage_Allocation                   Preview/Approved -> Failed with a reason
 *
 * Source balances use the ledger report rules: lines of Posted and Reversed journals in the period, net debit - credit
 * per source account, filtered by the rule's source department/cost center. Each source account's balance is split
 * across the targets by SABAllocationCalculator; the journal credits the source and debits the targets (directions swap
 * for a credit balance). One live (non-Failed) run per rule and period. Every action is idempotent and audited.
 */
public with sharing class SABAllocationRunService {
    public class AllocationRunException extends Exception {}

    private static final String MANAGE = 'SAB_Manage_Allocation';
    private static final String APPROVE = 'SAB_Approve_Allocation';
    private static final String POST_JOURNAL = 'SAB_Post_Journal';
    public static final String PREVIEW = 'Preview';
    public static final String APPROVED = 'Approved';
    public static final String POSTED = 'Posted';
    public static final String FAILED = 'Failed';
    private static final String ADAPTER = 'COST_ALLOCATION';
    private static final String SOURCE_TYPE = 'Allocation_Run__c';

    // ------------------------------------------------------------------ DTOs

    public class Allocation {
        public Integer sequence;
        public Id targetAccountId;
        public Id targetDepartmentId;
        public Id targetCostCenterId;
        public Decimal amount;
    }

    public class SourceAllocation {
        public Id sourceAccountId;
        public Decimal sourceAmount;
        public List<Allocation> allocations = new List<Allocation>();
        public Decimal roundingResidual = 0;
    }

    public class RunOutput {
        public Id sourceDepartmentId;
        public Id sourceCostCenterId;
        public Id roundingAccountId;
        public List<SourceAllocation> sources = new List<SourceAllocation>();
    }

    public class ActionResult {
        @AuraEnabled public Id runId;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal sourceAmount;
        @AuraEnabled public Id journalEntryId;
        @AuraEnabled public Boolean replay;
    }

    // ------------------------------------------------------------- lifecycle

    @AuraEnabled
    public static ActionResult preview(Id ruleId, Id periodId, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(MANAGE, 'Allocation management permission is required.');
        if (ruleId == null || periodId == null) {
            throw new AllocationRunException('Allocation rule and accounting period are required.');
        }
        List<Allocation_Rule__c> visible = [SELECT Id, Company__c FROM Allocation_Rule__c WHERE Id = :ruleId WITH USER_MODE];
        if (visible.isEmpty()) {
            throw new AllocationRunException('Allocation rule not found or not accessible.');
        }
        SABCompanyAccessService.assertCompanyAccess(visible[0].Company__c);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            if (prior.Action__c != 'ALLOCATION_RUN_PREVIEWED' || !String.valueOf(prior.Reason__c).startsWith(ruleId + '|' + periodId)) {
                throw new AllocationRunException('Request key has already been used for a different allocation action.');
            }
            return result(store.lockRun(Id.valueOf(prior.Source_Record_Id__c)), true);
        }
        Allocation_Rule__c rule = store.lockRule(ruleId);
        Accounting_Period__c period = store.period(periodId);
        if (rule.Status__c != SABAllocationRuleService.APPROVED) {
            throw new AllocationRunException('Only an Approved allocation rule can be run.');
        }
        if (period.Company__c != rule.Company__c || period.Status__c != 'Open') {
            throw new AllocationRunException('The period must be an Open period of the rule\'s company.');
        }
        if (rule.Effective_From__c > period.End_Date__c || (rule.Effective_To__c != null && rule.Effective_To__c < period.Start_Date__c)) {
            throw new AllocationRunException('The allocation rule is not effective in this period.');
        }
        if (store.liveRunExists(rule.Id, period.Id)) {
            throw new AllocationRunException('This rule already has a live run for the period; discard it before previewing again.');
        }
        RunOutput output = calculate(rule, period, store);
        Decimal total = 0;
        for (SourceAllocation s : output.sources) {
            total += s.sourceAmount;
        }
        Integer attempt = store.runCount(rule.Id, period.Id) + 1;
        Allocation_Run__c run = new Allocation_Run__c(Company__c = rule.Company__c, Allocation_Rule__c = rule.Id, Accounting_Period__c = period.Id,
            Rule_Version__c = rule.Version__c, Status__c = PREVIEW, Source_Amount_Snapshot__c = total,
            Calculated_Output_JSON__c = JSON.serialize(output),
            Run_Key__c = (String.valueOf(rule.Company__c) + '|' + rule.Rule_Key__c + '|V' + rule.Version__c + '|' + period.Id + '|' + attempt).left(180));
        new Writer().create(run, audit(run.Company__c, 'ALLOCATION_RUN_PREVIEWED', key, null,
            ruleId + '|' + periodId + ': previewed ' + output.sources.size() + ' source accounts.'));
        return result(run, false);
    }

    @AuraEnabled
    public static ActionResult approve(Id runId, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(APPROVE, 'Allocation approval permission is required.');
        Allocation_Run__c visible = authorize(runId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'ALLOCATION_RUN_APPROVED');
        }
        Allocation_Run__c run = store.lockRun(runId);
        if (run.Status__c != PREVIEW) {
            throw new AllocationRunException('Only a Preview allocation run can be approved.');
        }
        if (run.CreatedById == UserInfo.getUserId()) {
            throw new AllocationRunException('The preparer of an allocation run cannot approve it.');
        }
        run.Status__c = APPROVED;
        run.Approved_By__c = UserInfo.getUserId();
        run.Approved_At__c = System.now();
        new Writer().lifecycle(run, audit(run.Company__c, 'ALLOCATION_RUN_APPROVED', key, run.Id, 'Allocation run approved.'));
        return result(run, false);
    }

    @AuraEnabled
    public static ActionResult discard(Id runId, String reason, String requestKey) {
        String key = requireKey(requestKey);
        if (String.isBlank(reason) || reason.trim().length() > 255) {
            throw new AllocationRunException('A reason of up to 255 characters is required.');
        }
        SABPermissionService.assertPermission(MANAGE, 'Allocation management permission is required.');
        Allocation_Run__c visible = authorize(runId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'ALLOCATION_RUN_DISCARDED');
        }
        Allocation_Run__c run = store.lockRun(runId);
        if (run.Status__c != PREVIEW && run.Status__c != APPROVED) {
            throw new AllocationRunException('Only a Preview or Approved allocation run can be discarded.');
        }
        run.Status__c = FAILED;
        new Writer().lifecycle(run, audit(run.Company__c, 'ALLOCATION_RUN_DISCARDED', key, run.Id, reason.trim()));
        return result(run, false);
    }

    @AuraEnabled
    public static ActionResult post(Id runId, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(MANAGE, 'Allocation management permission is required.');
        SABPermissionService.assertPermission(POST_JOURNAL, 'Journal posting permission is required.');
        Allocation_Run__c visible = authorize(runId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'ALLOCATION_RUN_POSTED');
        }
        Allocation_Run__c run = store.lockRun(runId);
        if (run.Status__c != APPROVED) {
            throw new AllocationRunException('Only an Approved allocation run can be postingResult.');
        }
        Allocation_Rule__c rule = store.lockRule(run.Allocation_Rule__c);
        Accounting_Period__c period = store.lockPeriod(run.Accounting_Period__c);
        if (period.Status__c != 'Open') {
            throw new AllocationRunException('The allocation period is no longer Open.');
        }
        RunOutput output = (RunOutput) JSON.deserialize(run.Calculated_Output_JSON__c, RunOutput.class);
        Map<Id, Decimal> current = sourceBalances(rule.Company__c, period.Id, output.sourceDepartmentId, output.sourceCostCenterId,
            accountIds(output), store);
        for (SourceAllocation s : output.sources) {
            Decimal now = current.containsKey(s.sourceAccountId) ? current.get(s.sourceAccountId) : 0;
            if (now != s.sourceAmount) {
                throw new AllocationRunException('Source balances changed since the preview; discard this run and preview again.');
            }
        }
        Savepoint sp = Database.setSavepoint();
        try {
            SABPostingService.PostingResult postingResult = postJournal(run, rule, period, output, key);
            run.Status__c = POSTED;
            run.Journal_Entry__c = postingResult.journalEntryId;
            new Writer().lifecycle(run, audit(run.Company__c, 'ALLOCATION_RUN_POSTED', key, run.Id,
                'Allocation journal postingResult for ' + run.Source_Amount_Snapshot__c + '.'));
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
        return result(run, false);
    }

    // ----------------------------------------------------------- calculation

    @TestVisible
    private static RunOutput calculate(Allocation_Rule__c rule, Accounting_Period__c period, Store store) {
        SABAllocationRuleService.SourceFilter source = SABAllocationRuleService.parseSource(rule.Source_Filter_JSON__c);
        List<Allocation_Rule_Line__c> lines = store.ruleLines(rule.Id);
        SABAllocationRuleService.validate(rule.Company__c, rule.Driver_Type__c, source, lines);
        Map<Id, Decimal> balances = sourceBalances(rule.Company__c, period.Id, source.departmentId, source.costCenterId,
            new Set<Id>(source.accountIds), store);
        List<Decimal> weights = new List<Decimal>();
        for (Allocation_Rule_Line__c line : lines) {
            weights.add(rule.Driver_Type__c == SABAllocationRuleService.PERCENT ? line.Percentage__c : line.Driver_Value__c);
        }
        RunOutput output = new RunOutput();
        output.sourceDepartmentId = source.departmentId;
        output.sourceCostCenterId = source.costCenterId;
        if (rule.Rounding_Policy__c == SABAllocationCalculator.ROUNDING_ACCOUNT) {
            output.roundingAccountId = store.roundingAccount(rule.Company__c);
        }
        for (Id accountId : source.accountIds) {
            Decimal balance = balances.containsKey(accountId) ? balances.get(accountId) : 0;
            if (balance == 0) {
                continue;
            }
            SABAllocationCalculator.SplitResult split = SABAllocationCalculator.split(balance, weights, rule.Rounding_Policy__c);
            SourceAllocation s = new SourceAllocation();
            s.sourceAccountId = accountId;
            s.sourceAmount = balance;
            s.roundingResidual = split.roundingResidual;
            for (Integer i = 0; i < lines.size(); i++) {
                Allocation a = new Allocation();
                a.sequence = lines[i].Sequence__c.intValue();
                a.targetAccountId = lines[i].Target_GL_Account__c == null ? accountId : lines[i].Target_GL_Account__c;
                a.targetDepartmentId = lines[i].Target_Department__c;
                a.targetCostCenterId = lines[i].Target_Cost_Center__c;
                a.amount = split.shares[i];
                s.allocations.add(a);
            }
            output.sources.add(s);
        }
        if (output.sources.isEmpty()) {
            throw new AllocationRunException('The source accounts have no posted balance to allocate in this period.');
        }
        return output;
    }

    // Net debit - credit per source account for Posted and Reversed journals of the period (ledger report rules).
    private static Map<Id, Decimal> sourceBalances(Id companyId, Id periodId, Id departmentId, Id costCenterId, Set<Id> accounts, Store store) {
        Map<Id, Decimal> result = new Map<Id, Decimal>();
        for (AggregateResult ar : store.balances(companyId, periodId, departmentId, costCenterId, accounts)) {
            Decimal debit = ar.get('debitTotal') == null ? 0 : (Decimal) ar.get('debitTotal');
            Decimal credit = ar.get('creditTotal') == null ? 0 : (Decimal) ar.get('creditTotal');
            result.put((Id) ar.get('accountId'), (debit - credit).setScale(2, RoundingMode.HALF_UP));
        }
        return result;
    }

    private static Set<Id> accountIds(RunOutput output) {
        Set<Id> ids = new Set<Id>();
        for (SourceAllocation s : output.sources) {
            ids.add(s.sourceAccountId);
        }
        return ids;
    }

    // --------------------------------------------------------------- ledger

    private static SABPostingService.PostingResult postJournal(Allocation_Run__c run, Allocation_Rule__c rule, Accounting_Period__c period,
            RunOutput output, String requestKey) {
        String currencyCode = new Store().functionalCurrency(run.Company__c);
        String eventKey = 'ALLOCATION|' + run.Id;
        Journal_Entry__c journal = new Journal_Entry__c(Company__c = run.Company__c, Accounting_Period__c = period.Id,
            Accounting_Date__c = period.End_Date__c, Entry_Type__c = 'Subledger', Status__c = 'Draft', Version__c = 1,
            Description__c = ('Allocation ' + rule.Rule_Key__c + ' v' + rule.Version__c).left(255));
        List<Journal_Entry_Line__c> lines = new List<Journal_Entry_Line__c>();
        Integer n = 1;
        for (SourceAllocation s : output.sources) {
            // Credit the source balance away (a debit balance is credited; a credit balance is debited).
            lines.add(line(n++, s.sourceAccountId, output.sourceDepartmentId, output.sourceCostCenterId, -s.sourceAmount, currencyCode, period, eventKey));
            for (Allocation a : s.allocations) {
                lines.add(line(n++, a.targetAccountId, a.targetDepartmentId, a.targetCostCenterId, a.amount, currencyCode, period, eventKey));
            }
            if (s.roundingResidual != 0) {
                lines.add(line(n++, output.roundingAccountId, null, null, s.roundingResidual, currencyCode, period, eventKey));
            }
        }
        new Writer().journal(journal, lines);
        SABAccountingEventService.ReservationRequest eventRequest = new SABAccountingEventService.ReservationRequest();
        eventRequest.companyId = run.Company__c;
        eventRequest.adapterKey = ADAPTER;
        eventRequest.requestKey = requestKey.left(120);
        eventRequest.eventKey = eventKey;
        eventRequest.eventType = eventType();
        eventRequest.sourceBusinessKey = run.Run_Key__c.left(180);
        eventRequest.sourceRecordId = String.valueOf(run.Id);
        eventRequest.sourceType = SOURCE_TYPE;
        eventRequest.sourceVersion = run.Rule_Version__c.intValue();
        SABPostingService.PostingRequest posting = new SABPostingService.PostingRequest();
        posting.journalEntryId = journal.Id;
        posting.postingKey = eventKey;
        posting.eventRequest = eventRequest;
        return SABPostingService.postDraftJournal(posting);
    }

    // Signed amount: positive = debit, negative = credit.
    private static Journal_Entry_Line__c line(Integer n, Id accountId, Id departmentId, Id costCenterId, Decimal signedAmount,
            String currencyCode, Accounting_Period__c period, String eventKey) {
        Decimal debit = signedAmount > 0 ? signedAmount : 0;
        Decimal credit = signedAmount < 0 ? -signedAmount : 0;
        return new Journal_Entry_Line__c(Line_Number__c = n, GL_Account__c = accountId, Department__c = departmentId,
            Cost_Center__c = costCenterId, Debit_Base__c = debit, Credit_Base__c = credit, Transaction_Amount__c = debit > 0 ? debit : credit,
            Transaction_Currency__c = currencyCode, Functional_Currency__c = currencyCode, Applied_Exchange_Rate__c = 1,
            Rate_Date__c = period.End_Date__c, Rate_Source__c = 'Allocation Functional Currency', Source_Line_Key__c = eventKey + '|' + n,
            Explanation__c = 'Cost allocation');
    }

    // 'Allocation' is the defined event type; fall back to 'Manual Journal' only if an org has deactivated it.
    @TestVisible
    private static String eventType() {
        Set<String> active = new Set<String>();
        for (Schema.PicklistEntry entry : Accounting_Event__c.Event_Type__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                active.add(entry.getValue());
            }
        }
        return active.contains('Allocation') ? 'Allocation' : 'Manual Journal';
    }

    // --------------------------------------------------------------- helpers

    private static Allocation_Run__c authorize(Id runId) {
        if (runId == null) {
            throw new AllocationRunException('Allocation run is required.');
        }
        List<Allocation_Run__c> visible = [SELECT Id, Company__c FROM Allocation_Run__c WHERE Id = :runId WITH USER_MODE];
        if (visible.isEmpty()) {
            throw new AllocationRunException('Allocation run not found or not accessible.');
        }
        SABCompanyAccessService.assertCompanyAccess(visible[0].Company__c);
        return visible[0];
    }

    private static String requireKey(String requestKey) {
        Integer maxLength = Business_Action__c.Request_Key__c.getDescribe().getLength();
        if (String.isBlank(requestKey) || requestKey.trim().length() > maxLength) {
            throw new AllocationRunException('Request key is required and must not exceed ' + maxLength + ' characters.');
        }
        return requestKey.trim();
    }

    private static ActionResult replay(Business_Action__c prior, Id runId, String expectedAction) {
        if (prior.Action__c != expectedAction || prior.Source_Record_Id__c != String.valueOf(runId)) {
            throw new AllocationRunException('Request key has already been used for a different allocation action.');
        }
        return result(new Store().lockRun(runId), true);
    }

    private static Business_Action__c audit(Id companyId, String actionName, String key, Id runId, String reason) {
        return new Business_Action__c(Company__c = companyId, Action__c = actionName, Actor__c = UserInfo.getUserId(),
            Action_At__c = System.now(), Reason__c = reason, Request_Key__c = key, Source_Type__c = SOURCE_TYPE,
            Source_Record_Id__c = runId == null ? null : String.valueOf(runId), Source_Version__c = 1);
    }

    private static ActionResult result(Allocation_Run__c run, Boolean isReplay) {
        ActionResult r = new ActionResult();
        r.runId = run.Id;
        r.status = run.Status__c;
        r.sourceAmount = run.Source_Amount_Snapshot__c;
        r.journalEntryId = run.Journal_Entry__c;
        r.replay = isReplay;
        return r;
    }

    /**
     * Narrow system reads after the permission and company checks. Source balances must see every posted journal
     * line of the company whatever the running user's sharing, so the allocation never misses hidden costs.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    @TestVisible
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c, Reason__c FROM Business_Action__c
                WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        Allocation_Rule__c lockRule(Id ruleId) {
            return [SELECT Id, Company__c, Rule_Key__c, Version__c, Status__c, Driver_Type__c, Rounding_Policy__c, Effective_From__c,
                Effective_To__c, Source_Filter_JSON__c FROM Allocation_Rule__c WHERE Id = :ruleId WITH SYSTEM_MODE FOR UPDATE];
        }
        List<Allocation_Rule_Line__c> ruleLines(Id ruleId) {
            return [SELECT Id, Sequence__c, Target_GL_Account__c, Target_Department__c, Target_Cost_Center__c, Target_Project__c,
                Percentage__c, Driver_Value__c FROM Allocation_Rule_Line__c WHERE Allocation_Rule__c = :ruleId WITH SYSTEM_MODE
                ORDER BY Sequence__c LIMIT 201];
        }
        Accounting_Period__c period(Id periodId) {
            List<Accounting_Period__c> rows = [SELECT Id, Company__c, Status__c, Start_Date__c, End_Date__c FROM Accounting_Period__c
                WHERE Id = :periodId WITH SYSTEM_MODE];
            if (rows.isEmpty()) {
                throw new AllocationRunException('Accounting period not found.');
            }
            return rows[0];
        }
        Accounting_Period__c lockPeriod(Id periodId) {
            return [SELECT Id, Company__c, Status__c, Start_Date__c, End_Date__c FROM Accounting_Period__c WHERE Id = :periodId
                WITH SYSTEM_MODE FOR UPDATE];
        }
        Boolean liveRunExists(Id ruleId, Id periodId) {
            return [SELECT COUNT() FROM Allocation_Run__c WHERE Allocation_Rule__c = :ruleId AND Accounting_Period__c = :periodId
                AND Status__c != :FAILED WITH SYSTEM_MODE] > 0;
        }
        Integer runCount(Id ruleId, Id periodId) {
            return [SELECT COUNT() FROM Allocation_Run__c WHERE Allocation_Rule__c = :ruleId AND Accounting_Period__c = :periodId
                WITH SYSTEM_MODE];
        }
        Allocation_Run__c lockRun(Id runId) {
            return [SELECT Id, Company__c, Allocation_Rule__c, Accounting_Period__c, Rule_Version__c, Status__c, Run_Key__c,
                Source_Amount_Snapshot__c, Calculated_Output_JSON__c, Journal_Entry__c, Approved_By__c, Approved_At__c, CreatedById
                FROM Allocation_Run__c WHERE Id = :runId WITH SYSTEM_MODE FOR UPDATE];
        }
        Id roundingAccount(Id companyId) {
            return [SELECT Default_Rounding_Account__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE].Default_Rounding_Account__c;
        }
        String functionalCurrency(Id companyId) {
            return [SELECT Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE].Functional_Currency__c;
        }
        List<AggregateResult> balances(Id companyId, Id periodId, Id departmentId, Id costCenterId, Set<Id> accounts) {
            String soql = 'SELECT GL_Account__c accountId, SUM(Debit_Base__c) debitTotal, SUM(Credit_Base__c) creditTotal'
                + ' FROM Journal_Entry_Line__c WHERE Journal_Entry__r.Company__c = :companyId'
                + ' AND Journal_Entry__r.Status__c IN (\'Posted\', \'Reversed\') AND Journal_Entry__r.Accounting_Period__c = :periodId'
                + ' AND GL_Account__c IN :accounts'
                + (departmentId == null ? '' : ' AND Department__c = :departmentId')
                + (costCenterId == null ? '' : ' AND Cost_Center__c = :costCenterId')
                + ' GROUP BY GL_Account__c';
            return Database.queryWithBinds(soql, new Map<String, Object>{'companyId' => companyId, 'periodId' => periodId,
                'accounts' => accounts, 'departmentId' => departmentId, 'costCenterId' => costCenterId}, AccessLevel.SYSTEM_MODE);
        }
    }

    /** Narrow system writes inside the allocation guard scope, after the service's checks (explicit system mode). */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void create(Allocation_Run__c run, Business_Action__c audit) {
            SABAllocationGuard.beginWrite();
            try {
                insert as system run;
                audit.Source_Record_Id__c = String.valueOf(run.Id);
                insert as system audit;
            } finally {
                SABAllocationGuard.endWrite();
            }
        }
        void lifecycle(Allocation_Run__c run, Business_Action__c audit) {
            SABAllocationGuard.beginWrite();
            try {
                update as system new Allocation_Run__c(Id = run.Id, Status__c = run.Status__c, Approved_By__c = run.Approved_By__c,
                    Approved_At__c = run.Approved_At__c, Journal_Entry__c = run.Journal_Entry__c);
                insert as system audit;
            } finally {
                SABAllocationGuard.endWrite();
            }
        }
        void journal(Journal_Entry__c journal, List<Journal_Entry_Line__c> lines) {
            insert as system journal;
            for (Journal_Entry_Line__c line : lines) {
                line.Journal_Entry__c = journal.Id;
            }
            insert as system lines;
        }
    }
}
