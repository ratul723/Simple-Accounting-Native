/**
 * G17: Distributions (dividends and owner distributions) with settlement.
 *
 *   saveDraft  SAB_Manage_Equity                     create or edit a Draft distribution for one share class
 *   approve    SAB_Approve_Equity + SAB_Post_Journal  Draft -> Posted Payable; the approver differs from the creator.
 *                                                    Entitlements follow the class's ownership at the record date
 *                                                    (posted equity transactions), split by units with Largest Remainder
 *                                                    rounding; an ownership hash is stored. Declaration posts
 *                                                    Dr Source (Equity) / Cr Payable (Liability) on the declaration date.
 *   settle     SAB_Manage_Equity + SAB_Post_Journal  pays unpaid lines (all, or the given ones) with one Disbursement
 *                                                    payment tagged with the distribution; posts Dr Payable / Cr Bank;
 *                                                    records a settlement per line; Posted Payable -> Part Settled / Settled
 *   cancel     SAB_Manage_Equity                     Draft -> Cancelled with a reason
 * Functional currency only. Postings are Subledger journals (event type Distribution). Tagged payments are rejected by
 * the other payment services. Every action is idempotent by request key and audited.
 */
public with sharing class SABDistributionService {
    public class DistributionException extends Exception {}

    private static final String MANAGE = 'SAB_Manage_Equity';
    private static final String APPROVE = 'SAB_Approve_Equity';
    private static final String POST_JOURNAL = 'SAB_Post_Journal';
    private static final Set<String> TYPES = new Set<String>{'Dividend', 'Owner Distribution', 'Other'};
    private static final String SOURCE_TYPE = 'Distribution__c';

    public class DistributionRequest {
        @AuraEnabled public Id distributionId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public Id classId { get; set; }
        @AuraEnabled public String distributionType { get; set; }
        @AuraEnabled public Date declarationDate { get; set; }
        @AuraEnabled public Date recordDate { get; set; }
        @AuraEnabled public Date paymentDueDate { get; set; }
        @AuraEnabled public Decimal totalAmount { get; set; }
        @AuraEnabled public Id sourceAccountId { get; set; }
        @AuraEnabled public Id payableAccountId { get; set; }
        @AuraEnabled public Id bankAccountId { get; set; }
    }

    public class ActionResult {
        @AuraEnabled public Id distributionId;
        @AuraEnabled public String status;
        @AuraEnabled public Id journalEntryId;
        @AuraEnabled public Id paymentId;
        @AuraEnabled public Integer lineCount;
        @AuraEnabled public Boolean replay;
    }

    // ---------------------------------------------------------------- drafts

    @AuraEnabled
    public static Id saveDraft(DistributionRequest request) {
        SABPermissionService.assertPermission(MANAGE, 'Equity management permission is required.');
        if (request == null || request.companyId == null || request.classId == null || request.declarationDate == null
            || request.recordDate == null || request.totalAmount == null || !TYPES.contains(request.distributionType)) {
            throw new DistributionException('Company, class, type, declaration date, record date and total amount are required.');
        }
        SABCompanyAccessService.assertCompanyAccess(request.companyId);
        Store store = new Store();
        validate(request, store);
        Distribution__c distribution;
        if (request.distributionId != null) {
            distribution = store.lockDistribution(request.distributionId);
            if (distribution.Status__c != 'Draft' || distribution.Company__c != request.companyId) {
                throw new DistributionException('Only Draft distributions of the same company can be edited.');
            }
        } else {
            distribution = new Distribution__c(Company__c = request.companyId, Status__c = 'Draft');
        }
        distribution.Equity_Class__c = request.classId;
        distribution.Distribution_Type__c = request.distributionType;
        distribution.Declaration_Date__c = request.declarationDate;
        distribution.Record_Date__c = request.recordDate;
        distribution.Payment_Due_Date__c = request.paymentDueDate;
        distribution.Total_Amount__c = request.totalAmount.setScale(2, RoundingMode.HALF_UP);
        distribution.Currency__c = store.functionalCurrency(request.companyId);
        distribution.Source_Account__c = request.sourceAccountId;
        distribution.Payable_Account__c = request.payableAccountId;
        distribution.Bank_Account__c = request.bankAccountId;
        new Writer().saveDistribution(distribution);
        return distribution.Id;
    }

    // ------------------------------------------------------------- lifecycle

    @AuraEnabled
    public static ActionResult approve(Id distributionId, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(APPROVE, 'Equity approval permission is required.');
        SABPermissionService.assertPermission(POST_JOURNAL, 'Journal posting permission is required.');
        Store store = new Store();
        Distribution__c visible = visibleDistribution(distributionId);
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'DISTRIBUTION_APPROVED', store);
        }
        Distribution__c d = store.lockDistribution(distributionId);
        if (d.Status__c != 'Draft') {
            throw new DistributionException('Only a Draft distribution can be approved.');
        }
        if (d.CreatedById == UserInfo.getUserId()) {
            throw new DistributionException('The creator of a distribution cannot approve it.');
        }
        validate(toRequest(d), store);
        Map<Id, Decimal> holdings = SABEquityService.holdings(d.Equity_Class__c, d.Record_Date__c);
        if (holdings.isEmpty()) {
            throw new DistributionException('Nobody holds units of the class on the record date.');
        }
        List<Id> holders = new List<Id>(holdings.keySet());
        holders.sort();
        List<Decimal> weights = new List<Decimal>();
        List<String> snapshot = new List<String>();
        for (Id holder : holders) {
            weights.add(holdings.get(holder));
            snapshot.add(holder + ':' + holdings.get(holder).stripTrailingZeros().toPlainString());
        }
        List<Decimal> shares = SABAllocationCalculator.split(d.Total_Amount__c, weights, SABAllocationCalculator.LARGEST_REMAINDER).shares;
        List<Distribution_Line__c> lines = new List<Distribution_Line__c>();
        for (Integer i = 0; i < holders.size(); i++) {
            lines.add(new Distribution_Line__c(Distribution__c = d.Id, Stakeholder__c = holders[i], Entitled_Units__c = weights[i],
                Entitled_Amount__c = shares[i], Settlement_State__c = 'Unpaid'));
        }
        String hash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(String.join(snapshot, '|'))));
        Savepoint sp = Database.setSavepoint();
        try {
            SABPostingService.PostingResult postingResult = post(d, 'DECLARATION', d.Id, d.Declaration_Date__c, key, 'Declaration',
                new List<SABSubledgerPostingHelper.LineSpec>{
                    new SABSubledgerPostingHelper.LineSpec(d.Source_Account__c, d.Total_Amount__c, 'Distribution declared'),
                    new SABSubledgerPostingHelper.LineSpec(d.Payable_Account__c, -d.Total_Amount__c, 'Distribution payable')});
            new Writer().approve(new Distribution__c(Id = d.Id, Status__c = 'Posted Payable', Approved_By__c = UserInfo.getUserId(),
                Approved_At__c = System.now(), Journal_Entry__c = postingResult.journalEntryId, Ownership_Snapshot_Hash__c = hash), lines,
                audit(d.Company__c, 'DISTRIBUTION_APPROVED', key, d.Id, 'Declared to ' + lines.size() + ' holders.'));
            ActionResult r = result(d.Id, 'Posted Payable', postingResult.journalEntryId, null, false);
            r.lineCount = lines.size();
            return r;
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
    }

    /** Pays the given unpaid lines (or every unpaid line when lineIds is empty) on paymentDate. */
    @AuraEnabled
    public static ActionResult settle(Id distributionId, List<Id> lineIds, Date paymentDate, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(MANAGE, 'Equity management permission is required.');
        SABPermissionService.assertPermission(POST_JOURNAL, 'Journal posting permission is required.');
        if (paymentDate == null) {
            throw new DistributionException('Payment date is required.');
        }
        Store store = new Store();
        Distribution__c visible = visibleDistribution(distributionId);
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'DISTRIBUTION_SETTLED', store);
        }
        Distribution__c d = store.lockDistribution(distributionId);
        if (d.Status__c != 'Posted Payable' && d.Status__c != 'Part Settled') {
            throw new DistributionException('Only a declared, unsettled distribution can be paid.');
        }
        if (paymentDate < d.Declaration_Date__c) {
            throw new DistributionException('Payment date cannot be before the declaration date.');
        }
        List<Distribution_Line__c> all = store.lines(d.Id);
        // Decide once whether every unpaid line is being paid; never re-derive it from a set that shrinks in the loop.
        Boolean payAll = lineIds == null || lineIds.isEmpty();
        Set<Id> requested = payAll ? new Set<Id>() : new Set<Id>(lineIds);
        Set<Id> unmatched = new Set<Id>(requested);
        List<Distribution_Line__c> paying = new List<Distribution_Line__c>();
        Decimal total = 0;
        Integer unpaidAfter = 0;
        for (Distribution_Line__c l : all) {
            Boolean wanted = payAll || requested.contains(l.Id);
            if (wanted && l.Settlement_State__c == 'Unpaid') {
                paying.add(l);
                total += l.Entitled_Amount__c;
                unmatched.remove(l.Id);
            } else if (l.Settlement_State__c != 'Paid') {
                unpaidAfter++;
            }
        }
        if (!unmatched.isEmpty()) {
            throw new DistributionException('Every line to pay must be an unpaid line of this distribution.');
        }
        if (paying.isEmpty() || total <= 0) {
            throw new DistributionException('There is nothing unpaid to settle.');
        }
        Bank_Account__c bank = store.bank(d.Bank_Account__c);
        Savepoint sp = Database.setSavepoint();
        try {
            Writer writer = new Writer();
            Accounting_Payment__c payment = new Accounting_Payment__c(Company__c = d.Company__c, Bank_Account__c = bank.Id,
                Direction__c = 'Disbursement', Method__c = 'Bank Transfer', Amount__c = total, Transaction_Currency__c = d.Currency__c,
                Functional_Currency__c = d.Currency__c, Exchange_Rate__c = 1, Effective_Date__c = paymentDate,
                Reference__c = ('DIST|' + d.Name).left(80), Distribution__c = d.Id);
            writer.insertPayment(payment);
            SABPostingService.PostingResult postingResult = post(d, 'PAYMENT', payment.Id, paymentDate, key, 'Payment',
                new List<SABSubledgerPostingHelper.LineSpec>{
                    new SABSubledgerPostingHelper.LineSpec(d.Payable_Account__c, total, 'Distribution paid'),
                    new SABSubledgerPostingHelper.LineSpec(bank.GL_Account__c, -total, 'Distribution paid')});
            List<Distribution_Settlement__c> settlements = new List<Distribution_Settlement__c>();
            for (Distribution_Line__c l : paying) {
                l.Settlement_State__c = 'Paid';
                settlements.add(new Distribution_Settlement__c(Distribution_Line__c = l.Id, Payment__c = payment.Id,
                    Allocated_Amount__c = l.Entitled_Amount__c, Effective_Date__c = paymentDate, Status__c = 'Effective',
                    Settlement_Key__c = (payment.Id + '|' + l.Id).left(180)));
            }
            String newStatus = unpaidAfter == 0 ? 'Settled' : 'Part Settled';
            writer.settle(new Accounting_Payment__c(Id = payment.Id, Processing_State__c = 'Succeeded',
                Accounting_Event__c = postingResult.accountingEventId), paying, settlements,
                new Distribution__c(Id = d.Id, Status__c = newStatus),
                audit(d.Company__c, 'DISTRIBUTION_SETTLED', key, d.Id, 'Paid ' + paying.size() + ' lines totalling ' + total + '.'));
            ActionResult r = result(d.Id, newStatus, postingResult.journalEntryId, payment.Id, false);
            r.lineCount = paying.size();
            return r;
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
    }

    @AuraEnabled
    public static ActionResult cancel(Id distributionId, String reason, String requestKey) {
        String key = requireKey(requestKey);
        if (String.isBlank(reason) || reason.trim().length() > 255) {
            throw new DistributionException('A reason of up to 255 characters is required.');
        }
        SABPermissionService.assertPermission(MANAGE, 'Equity management permission is required.');
        Store store = new Store();
        Distribution__c visible = visibleDistribution(distributionId);
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'DISTRIBUTION_CANCELLED', store);
        }
        Distribution__c d = store.lockDistribution(distributionId);
        if (d.Status__c != 'Draft') {
            throw new DistributionException('Only a Draft distribution can be cancelled.');
        }
        new Writer().approve(new Distribution__c(Id = d.Id, Status__c = 'Cancelled'), new List<Distribution_Line__c>(),
            audit(d.Company__c, 'DISTRIBUTION_CANCELLED', key, d.Id, reason.trim()));
        return result(d.Id, 'Cancelled', null, null, false);
    }

    // --------------------------------------------------------------- helpers

    private static void validate(DistributionRequest r, Store store) {
        if (r.totalAmount <= 0) {
            throw new DistributionException('Total amount must be greater than zero.');
        }
        if (r.recordDate > r.declarationDate) {
            throw new DistributionException('The record date cannot be after the declaration date.');
        }
        if (r.paymentDueDate != null && r.paymentDueDate < r.declarationDate) {
            throw new DistributionException('The payment due date cannot be before the declaration date.');
        }
        List<Equity_Class__c> classes = [SELECT Id, Company__c, Is_Active__c FROM Equity_Class__c WHERE Id = :r.classId WITH USER_MODE];
        if (classes.isEmpty() || classes[0].Company__c != r.companyId || classes[0].Is_Active__c != true) {
            throw new DistributionException('The share class must be an active class of the company.');
        }
        if (r.sourceAccountId == null || r.payableAccountId == null || r.bankAccountId == null) {
            throw new DistributionException('Source account, payable account and bank account are required.');
        }
        Map<Id, GL_Account__c> accounts = new Map<Id, GL_Account__c>([SELECT Id, Company__c, Is_Active__c, Account_Type__c FROM GL_Account__c
            WHERE Id IN (:r.sourceAccountId, :r.payableAccountId) WITH USER_MODE]);
        GL_Account__c source = accounts.get(r.sourceAccountId);
        GL_Account__c payable = accounts.get(r.payableAccountId);
        if (source == null || source.Company__c != r.companyId || source.Is_Active__c != true || source.Account_Type__c != 'Equity'
                || payable == null || payable.Company__c != r.companyId || payable.Is_Active__c != true || payable.Account_Type__c != 'Liability') {
            throw new DistributionException('The source must be an active Equity account and the payable an active Liability account of the company.');
        }
        Bank_Account__c bank = store.bank(r.bankAccountId);
        if (bank == null || bank.Company__c != r.companyId || bank.Is_Active__c != true || bank.Currency__c != store.functionalCurrency(r.companyId)) {
            throw new DistributionException('An active functional-currency bank account of the company is required.');
        }
    }

    private static DistributionRequest toRequest(Distribution__c d) {
        DistributionRequest r = new DistributionRequest();
        r.companyId = d.Company__c;
        r.classId = d.Equity_Class__c;
        r.distributionType = d.Distribution_Type__c;
        r.declarationDate = d.Declaration_Date__c;
        r.recordDate = d.Record_Date__c;
        r.paymentDueDate = d.Payment_Due_Date__c;
        r.totalAmount = d.Total_Amount__c;
        r.sourceAccountId = d.Source_Account__c;
        r.payableAccountId = d.Payable_Account__c;
        r.bankAccountId = d.Bank_Account__c;
        return r;
    }

    private static SABPostingService.PostingResult post(Distribution__c d, String stage, Id sourceId, Date onDate, String key, String label,
            List<SABSubledgerPostingHelper.LineSpec> lines) {
        SABSubledgerPostingHelper.PostingSpec spec = new SABSubledgerPostingHelper.PostingSpec();
        spec.companyId = d.Company__c;
        spec.accountingDate = onDate;
        spec.description = ('Distribution ' + label.toLowerCase() + ' ' + d.Name).left(255);
        spec.adapterKey = 'DISTRIBUTION';
        spec.eventKey = 'DISTRIBUTION|' + sourceId + '|' + stage;
        spec.eventType = 'Distribution';
        spec.sourceType = stage == 'PAYMENT' ? 'Accounting_Payment__c' : SOURCE_TYPE;
        spec.sourceRecordId = sourceId;
        spec.sourceBusinessKey = 'DISTRIBUTION|' + d.Id + '|' + stage;
        spec.requestKey = key;
        spec.lines = lines;
        return SABSubledgerPostingHelper.post(spec);
    }

    private static Distribution__c visibleDistribution(Id distributionId) {
        if (distributionId == null) {
            throw new DistributionException('Distribution is required.');
        }
        List<Distribution__c> rows = [SELECT Id, Company__c FROM Distribution__c WHERE Id = :distributionId WITH USER_MODE];
        if (rows.isEmpty()) {
            throw new DistributionException('Distribution not found or not accessible.');
        }
        SABCompanyAccessService.assertCompanyAccess(rows[0].Company__c);
        return rows[0];
    }

    private static String requireKey(String requestKey) {
        Integer maxLength = Business_Action__c.Request_Key__c.getDescribe().getLength();
        if (String.isBlank(requestKey) || requestKey.trim().length() > maxLength) {
            throw new DistributionException('Request key is required and must not exceed ' + maxLength + ' characters.');
        }
        return requestKey.trim();
    }

    private static ActionResult replay(Business_Action__c prior, Id distributionId, String expectedAction, Store store) {
        if (prior.Action__c != expectedAction || prior.Source_Record_Id__c != String.valueOf(distributionId)) {
            throw new DistributionException('Request key has already been used for a different distribution action.');
        }
        Distribution__c d = store.lockDistribution(distributionId);
        return result(d.Id, d.Status__c, null, null, true);
    }

    private static Business_Action__c audit(Id companyId, String actionName, String key, Id recordId, String reason) {
        return new Business_Action__c(Company__c = companyId, Action__c = actionName, Actor__c = UserInfo.getUserId(),
            Action_At__c = System.now(), Reason__c = reason, Request_Key__c = key, Source_Type__c = SOURCE_TYPE,
            Source_Record_Id__c = String.valueOf(recordId), Source_Version__c = 1);
    }

    private static ActionResult result(Id distributionId, String status, Id journalId, Id paymentId, Boolean isReplay) {
        ActionResult r = new ActionResult();
        r.distributionId = distributionId;
        r.status = status;
        r.journalEntryId = journalId;
        r.paymentId = paymentId;
        r.replay = isReplay;
        return r;
    }

    /** Narrow system reads after the permission and company checks. */
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
        Bank_Account__c bank(Id bankAccountId) {
            List<Bank_Account__c> rows = [SELECT Id, Company__c, Is_Active__c, Currency__c, GL_Account__c FROM Bank_Account__c
                WHERE Id = :bankAccountId WITH SYSTEM_MODE];
            return rows.isEmpty() ? null : rows[0];
        }
        Distribution__c lockDistribution(Id distributionId) {
            List<Distribution__c> rows = [SELECT Id, Name, Company__c, Equity_Class__c, Distribution_Type__c, Declaration_Date__c, Record_Date__c,
                Payment_Due_Date__c, Total_Amount__c, Currency__c, Source_Account__c, Payable_Account__c, Bank_Account__c, Status__c, CreatedById
                FROM Distribution__c WHERE Id = :distributionId WITH SYSTEM_MODE FOR UPDATE];
            if (rows.isEmpty()) {
                throw new DistributionException('Distribution not found.');
            }
            return rows[0];
        }
        List<Distribution_Line__c> lines(Id distributionId) {
            return [SELECT Id, Stakeholder__c, Entitled_Amount__c, Settlement_State__c FROM Distribution_Line__c
                WHERE Distribution__c = :distributionId WITH SYSTEM_MODE  LIMIT 10000 FOR UPDATE];
        }
    }

    /** Narrow system writes inside the G17 guard scope, after the service's checks (explicit system mode). */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void saveDistribution(Distribution__c d) {
            SABEquityGuard.beginWrite();
            try {
                upsert as system d;
            } finally {
                SABEquityGuard.endWrite();
            }
        }
        void approve(Distribution__c d, List<Distribution_Line__c> lines, Business_Action__c audit) {
            SABEquityGuard.beginWrite();
            try {
                update as system d;
                if (!lines.isEmpty()) {
                    insert as system lines;
                }
                insert as system audit;
            } finally {
                SABEquityGuard.endWrite();
            }
        }
        void insertPayment(Accounting_Payment__c payment) {
            SABEquityGuard.beginWrite();
            try {
                insert as system payment;
            } finally {
                SABEquityGuard.endWrite();
            }
        }
        void settle(Accounting_Payment__c payment, List<Distribution_Line__c> lines, List<Distribution_Settlement__c> settlements,
                Distribution__c d, Business_Action__c audit) {
            SABEquityGuard.beginWrite();
            SABAccountingPaymentMutationContext.beginMutation();
            try {
                update as system payment;
                update as system lines;
                insert as system settlements;
                update as system d;
                insert as system audit;
            } finally {
                SABAccountingPaymentMutationContext.endMutation();
                SABEquityGuard.endWrite();
            }
        }
    }
}
