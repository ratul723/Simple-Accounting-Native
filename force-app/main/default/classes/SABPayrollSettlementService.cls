/**
 * G10E: Payroll net-pay settlement.
 *
 * Pays the outstanding net pay of a Posted payroll run through one controlled
 * Accounting_Payment__c disbursement and moves the run to Settled.
 *
 *   prepare   (Process)              Draft payment for all outstanding net pay
 *   authorize (Authorize)            Draft -> Authorized, never by the preparer
 *   submit    (Process)              Authorized -> Submitted, provider key unique per company
 *   succeeded (Process + Post Journal) Dr Net Payable / Cr Bank, one Effective settlement per line
 *   failed    (Process)              Payment -> Failed, no ledger impact
 *   return    (Process + Post Journal) one employee bank return: Dr Bank / Cr Net Payable,
 *                                    settlement -> Failed plus a negative Reversed row, run -> Posted
 *
 * Scope: functional currency only, whole-run payments, no reversal of a settled accrual.
 * Every action is idempotent by request key and audited in Business_Action__c.
 */
public with sharing class SABPayrollSettlementService {
    public class PayrollSettlementException extends Exception {}

    private static final String PROCESS = 'SAB_Process_Payroll_Payment';
    private static final String AUTHORIZE = 'SAB_Authorize_Payroll_Payment';
    private static final String POST_JOURNAL = 'SAB_Post_Journal';
    private static final String VIEW_DETAIL = 'SAB_View_Payroll_Detail';

    private static final String STATE_DRAFT = 'Draft';
    private static final String STATE_AUTHORIZED = 'Authorized';
    private static final String STATE_SUBMITTED = 'Submitted';
    private static final String STATE_SUCCEEDED = 'Succeeded';
    private static final String STATE_FAILED = 'Failed';
    private static final Set<String> IN_FLIGHT = new Set<String>{STATE_DRAFT, STATE_AUTHORIZED, STATE_SUBMITTED};

    private static final String RUN_POSTED = 'Posted';
    private static final String RUN_SETTLED = 'Settled';
    private static final String SETTLEMENT_EFFECTIVE = 'Effective';
    private static final String SETTLEMENT_FAILED = 'Failed';
    private static final String SETTLEMENT_REVERSED = 'Reversed';

    private static final String ADAPTER_PAYMENT = 'PAYROLL_PAYMENT';
    private static final String ADAPTER_RETURN = 'PAYROLL_PAYMENT_RETURN';
    private static final String EVENT_TYPE_PAYMENT = 'Payment Disbursement';
    private static final String EVENT_TYPE_RETURN = 'Payment Receipt';

    private static final String SOURCE_RUN = 'Payroll_Run__c';
    private static final String SOURCE_PAYMENT = 'Accounting_Payment__c';
    private static final String SOURCE_SETTLEMENT = 'Payroll_Settlement__c';

    private static final String ACTION_PREPARED = 'PAYROLL_PAYMENT_PREPARED';
    private static final String ACTION_LINKED = 'PAYROLL_PAYMENT_LINKED';
    private static final String ACTION_AUTHORIZED = 'PAYROLL_PAYMENT_AUTHORIZED';
    private static final String ACTION_SUBMITTED = 'PAYROLL_PAYMENT_SUBMITTED';
    private static final String ACTION_SUCCEEDED = 'PAYROLL_PAYMENT_SUCCEEDED';
    private static final String ACTION_FAILED = 'PAYROLL_PAYMENT_FAILED';
    private static final String ACTION_RETURNED = 'PAYROLL_PAYMENT_RETURNED';

    private static final Integer MAX_REASON = 255;
    private static final Integer MAX_LINES = 200;

    // Write scopes opened only by this service; the guard triggers read them.
    @TestVisible private static Id permittedRunId;
    @TestVisible private static Boolean settlementWriteScope = false;
    // G10H: payroll payments carry Payroll_Run__c and change only inside this scope.
    @TestVisible private static Boolean paymentWriteScope = false;

    // ---------------------------------------------------------------- results

    public class PaymentResult {
        @AuraEnabled public Id payrollRunId;
        @AuraEnabled public String runState;
        @AuraEnabled public Id paymentId;
        @AuraEnabled public String paymentState;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Id accountingEventId;
        @AuraEnabled public Id journalEntryId;
        @AuraEnabled public Boolean replay;
    }

    public class ReturnResult {
        @AuraEnabled public Id payrollRunId;
        @AuraEnabled public String runState;
        @AuraEnabled public Id settlementId;
        @AuraEnabled public Id reversalSettlementId;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Id accountingEventId;
        @AuraEnabled public Id journalEntryId;
        @AuraEnabled public Boolean replay;
    }

    public class LineSummary {
        @AuraEnabled public Id payrollLineId;
        @AuraEnabled public Id employmentId;
        @AuraEnabled public Decimal netAmount;
        @AuraEnabled public Decimal settledAmount;
        @AuraEnabled public Decimal outstandingAmount;
        @AuraEnabled public Id effectiveSettlementId;
    }

    public class SettlementSummary {
        @AuraEnabled public Id payrollRunId;
        @AuraEnabled public String runState;
        @AuraEnabled public Id paymentId;
        @AuraEnabled public String paymentState;
        @AuraEnabled public Decimal netTotal;
        @AuraEnabled public Decimal settledTotal;
        @AuraEnabled public Decimal outstandingTotal;
        @AuraEnabled public List<LineSummary> lines;
    }

    // ----------------------------------------------------------- guard hooks

    /** Payroll_Run__c guard allow-list entry (see SABPayrollCalculationService.guard). */
    public static Boolean permitsWorkflowWrite(SObject row) {
        return permittedRunId != null && row.getSObjectType() == Payroll_Run__c.SObjectType
            && (Id) row.get('Id') == permittedRunId;
    }

    /** Trigger entry point for Payroll_Settlement__c; callers cannot open the write scope. */
    public static void guardSettlements(List<SObject> rows, Boolean isDelete) {
        for (SObject row : rows) {
            if (isDelete || !settlementWriteScope) {
                row.addError('Payroll settlements are created and returned only by the payroll settlement service.');
            }
        }
    }

    /**
     * G10H: Accounting_Payment__c guard (SABPayrollPaymentGuardTrigger). A payment tagged with Payroll_Run__c
     * can be created, changed or deleted only by this service, whatever other payment service or user tries.
     * Reads only the rows in the trigger: no SOQL.
     */
    public static void guardPayments(List<Accounting_Payment__c> rows, Map<Id, Accounting_Payment__c> oldMap, Boolean isDelete) {
        if (paymentWriteScope) {
            return;
        }
        for (Accounting_Payment__c row : rows) {
            Accounting_Payment__c old = oldMap == null ? null : oldMap.get(row.Id);
            if (row.Payroll_Run__c != null || (old != null && old.Payroll_Run__c != null)) {
                row.addError('Payroll payments are processed only through payroll settlement.');
            }
        }
    }

    // --------------------------------------------------------------- actions

    @AuraEnabled
    public static PaymentResult preparePayment(Id runId, Id bankAccountId, Date paymentDate, String method,
            String reference, String requestKey) {
        String key = requireRequestKey(requestKey);
        if (runId == null || bankAccountId == null || paymentDate == null || String.isBlank(method)) {
            throw new PayrollSettlementException('Payroll run, bank account, payment date and payment method are required.');
        }
        String methodValue = method.trim();
        if (!activeMethods().contains(methodValue)) {
            throw new PayrollSettlementException('Payment method is not an active Accounting Payment method.');
        }
        String referenceValue = String.isBlank(reference) ? null : reference.trim();
        if (referenceValue != null && referenceValue.length() > Accounting_Payment__c.Reference__c.getDescribe().getLength()) {
            throw new PayrollSettlementException('Payment reference exceeds its supported length.');
        }
        Payroll_Run__c visible = authorize(runId, new List<String>{PROCESS}, true);
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replayPrepare(prior, visible, bankAccountId, paymentDate, methodValue);
        }
        Context ctx = lock(visible);
        assertPayableRun(ctx);
        if (ctx.run.Workflow_State__c != RUN_POSTED) {
            throw new PayrollSettlementException(ctx.run.Workflow_State__c == RUN_SETTLED
                ? 'Payroll run is already fully settled.' : 'Only a Posted payroll run can be paid.');
        }
        new Store().assertAccrualPosted(ctx.run);
        Bank_Account__c bank = loadBank(bankAccountId);
        assertBank(bank.Company__c, bank.Is_Active__c, bank.Currency__c, bank.GL_Account__r, ctx);
        assertPaymentDate(ctx, paymentDate, false);
        if (ctx.run.Settlement_Payment__c != null) {
            Accounting_Payment__c current = new Store().payment(ctx.run.Settlement_Payment__c, false);
            if (IN_FLIGHT.contains(current.Processing_State__c)) {
                throw new PayrollSettlementException('Payroll run already has an in-flight payment; complete it or record it as failed first.');
            }
        }
        Balance balance = balance(ctx.run);
        if (balance.outstanding <= 0) {
            throw new PayrollSettlementException('Payroll run has no outstanding net pay.');
        }
        String currencyCode = functionalCurrency(ctx);
        Accounting_Payment__c payment = new Accounting_Payment__c(Company__c = ctx.run.Company__c,
            Bank_Account__c = bankAccountId, Direction__c = 'Disbursement', Method__c = methodValue,
            Reference__c = referenceValue, Amount__c = balance.outstanding, Transaction_Currency__c = currencyCode,
            Functional_Currency__c = currencyCode, Exchange_Rate__c = 1, Effective_Date__c = paymentDate,
            Payroll_Run__c = ctx.run.Id);
        Savepoint sp = Database.setSavepoint();
        try {
            paymentWriteScope = true;
            try {
                insert as user payment;
            } finally {
                paymentWriteScope = false;
            }
            updateRun(new Payroll_Run__c(Id = ctx.run.Id, Settlement_Payment__c = payment.Id));
            new Writer().actions(new List<Business_Action__c>{
                action(ctx.run.Company__c, ACTION_PREPARED, key, SOURCE_PAYMENT, payment.Id,
                    'Payroll net-pay payment prepared for ' + balance.outstanding + ' ' + currencyCode + '.'),
                action(ctx.run.Company__c, ACTION_LINKED, linkKey(payment.Id), SOURCE_RUN, ctx.run.Id,
                    'Payment ' + payment.Id + ' settles payroll run ' + ctx.run.Id + '.')
            });
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
        return paymentResult(ctx.run.Id, RUN_POSTED, payment.Id, STATE_DRAFT, balance.outstanding, null, null, false);
    }

    @AuraEnabled
    public static PaymentResult authorizePayment(Id runId, String requestKey) {
        String key = requireRequestKey(requestKey);
        requireRun(runId);
        Payroll_Run__c visible = authorize(runId, new List<String>{AUTHORIZE}, true);
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replayLifecycle(prior, visible, ACTION_AUTHORIZED);
        }
        Context ctx = lock(visible);
        assertPayableRun(ctx);
        Accounting_Payment__c payment = currentPayment(ctx, STATE_DRAFT, 'authorization');
        if (payment.CreatedById == UserInfo.getUserId()) {
            throw new PayrollSettlementException('The payroll payment preparer cannot authorize their own payment.');
        }
        assertPaymentSetup(payment, ctx);
        payment.Processing_State__c = STATE_AUTHORIZED;
        return lifecycleWrite(ctx, payment, ACTION_AUTHORIZED, key, 'Payroll net-pay payment authorized.');
    }

    @AuraEnabled
    public static PaymentResult submitPayment(Id runId, String providerRequestKey, String requestKey) {
        String key = requireRequestKey(requestKey);
        requireRun(runId);
        if (String.isBlank(providerRequestKey)
            || providerRequestKey.trim().length() > Accounting_Payment__c.Provider_Request_Key__c.getDescribe().getLength()) {
            throw new PayrollSettlementException('Provider request key is required and must fit its supported length.');
        }
        String provider = providerRequestKey.trim();
        Payroll_Run__c visible = authorize(runId, new List<String>{PROCESS}, true);
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replayLifecycle(prior, visible, ACTION_SUBMITTED);
        }
        Context ctx = lock(visible);
        assertPayableRun(ctx);
        Accounting_Payment__c payment = currentPayment(ctx, STATE_AUTHORIZED, 'submission');
        assertPaymentSetup(payment, ctx);
        if (new Store().providerKeyInUse(ctx.run.Company__c, provider, payment.Id)) {
            throw new PayrollSettlementException('Provider request key is already assigned to another payment in this company.');
        }
        payment.Provider_Request_Key__c = provider;
        payment.Processing_State__c = STATE_SUBMITTED;
        return lifecycleWrite(ctx, payment, ACTION_SUBMITTED, key, 'Payroll net-pay payment submitted for execution.');
    }

    /** Call only after the bank or provider confirms the disbursement succeeded. */
    @AuraEnabled
    public static PaymentResult recordPaymentSucceeded(Id runId, String requestKey) {
        String key = requireRequestKey(requestKey);
        requireRun(runId);
        Payroll_Run__c visible = authorize(runId, new List<String>{PROCESS, POST_JOURNAL}, true);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            assertPriorAction(prior, ACTION_SUCCEEDED, SOURCE_PAYMENT, visible.Id);
            return succeededReplay(visible.Id, store.payment(Id.valueOf(prior.Source_Record_Id__c), false));
        }
        Context ctx = lock(visible);
        assertPayableRun(ctx);
        if (ctx.run.Settlement_Payment__c == null) {
            throw new PayrollSettlementException('Payroll run has no payment to record.');
        }
        Accounting_Payment__c payment = store.payment(ctx.run.Settlement_Payment__c, true);
        if (payment.Processing_State__c == STATE_SUCCEEDED) {
            return succeededReplay(ctx.run.Id, payment);
        }
        if (ctx.run.Workflow_State__c != RUN_POSTED || payment.Processing_State__c != STATE_SUBMITTED) {
            throw new PayrollSettlementException('Payroll payment must be Submitted before success is recorded.');
        }
        if (String.isBlank(payment.Provider_Request_Key__c) || payment.Accounting_Event__c != null) {
            throw new PayrollSettlementException('Submitted payroll payment has an inconsistent provider or accounting state.');
        }
        assertPaymentSetup(payment, ctx);
        Id periodId = assertPaymentDate(ctx, payment.Effective_Date__c, true);
        Balance balance = balance(ctx.run);
        Decimal amount = payment.Amount__c;
        if (balance.outstanding != amount) {
            throw new PayrollSettlementException('Payroll settlement integrity check failed: outstanding net pay no longer matches the payment amount.');
        }
        assertLedgerAccounts(ctx.run.Company__c, ctx.run.Net_Payable_Account__c, payment.Bank_Account__r.GL_Account__c);
        String eventKey = 'PAYROLL|' + ctx.run.Id + '|PAYMENT|' + payment.Id;
        Savepoint sp = Database.setSavepoint();
        try {
            SABPostingService.PostingResult posted = postJournal(ctx, periodId, payment.Effective_Date__c, amount,
                ctx.run.Net_Payable_Account__c, payment.Bank_Account__r.GL_Account__c, eventKey, ADAPTER_PAYMENT,
                EVENT_TYPE_PAYMENT, SOURCE_PAYMENT, payment.Id, key, 'Payroll net pay ' + ctx.run.Id);
            payment.Accounting_Event__c = posted.accountingEventId;
            payment.Processing_State__c = STATE_SUCCEEDED;
            Writer writer = new Writer();
            writer.payment(payment);
            List<Payroll_Settlement__c> settlements = new List<Payroll_Settlement__c>();
            for (LineBalance line : balance.lines.values()) {
                if (line.outstanding > 0) {
                    settlements.add(new Payroll_Settlement__c(Payment__c = payment.Id, Payroll_Line__c = line.lineId,
                        Allocated_Amount__c = line.outstanding, Effective_Date__c = payment.Effective_Date__c,
                        Status__c = SETTLEMENT_EFFECTIVE, Settlement_Key__c = 'PAYROLL|' + payment.Id + '|' + line.lineId));
                }
            }
            writer.insertSettlements(settlements);
            updateRun(new Payroll_Run__c(Id = ctx.run.Id, Workflow_State__c = RUN_SETTLED,
                Settled_Amount__c = balance.settled + amount, Settled_By__c = UserInfo.getUserId(), Settled_At__c = System.now()));
            writer.actions(new List<Business_Action__c>{action(ctx.run.Company__c, ACTION_SUCCEEDED, key, SOURCE_PAYMENT,
                payment.Id, 'Payroll net-pay payment succeeded; ' + settlements.size() + ' employee lines settled.')});
            return paymentResult(ctx.run.Id, RUN_SETTLED, payment.Id, STATE_SUCCEEDED, amount,
                posted.accountingEventId, posted.journalEntryId, false);
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
    }

    /** Provider rejected or the payment was abandoned before execution. No ledger impact. */
    @AuraEnabled
    public static PaymentResult recordPaymentFailed(Id runId, String reason, String requestKey) {
        String key = requireRequestKey(requestKey);
        requireRun(runId);
        String reasonText = requireReason(reason);
        Payroll_Run__c visible = authorize(runId, new List<String>{PROCESS}, true);
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replayLifecycle(prior, visible, ACTION_FAILED);
        }
        Context ctx = lock(visible);
        assertPayableRun(ctx);
        if (ctx.run.Settlement_Payment__c == null) {
            throw new PayrollSettlementException('Payroll run has no payment to record.');
        }
        Accounting_Payment__c payment = new Store().payment(ctx.run.Settlement_Payment__c, true);
        if (!IN_FLIGHT.contains(payment.Processing_State__c)) {
            throw new PayrollSettlementException('Only a Draft, Authorized or Submitted payroll payment can fail; '
                + 'succeeded payments are reversed per employee through bank returns.');
        }
        payment.Processing_State__c = STATE_FAILED;
        return lifecycleWrite(ctx, payment, ACTION_FAILED, key, 'Payroll net-pay payment failed: ' + reasonText);
    }

    /** Bank return of one employee's net pay after a succeeded payment. */
    @AuraEnabled
    public static ReturnResult recordLineReturn(Id settlementId, Date returnDate, String reason, String requestKey) {
        String key = requireRequestKey(requestKey);
        if (settlementId == null || returnDate == null) {
            throw new PayrollSettlementException('Payroll settlement and return date are required.');
        }
        String reasonText = requireReason(reason);
        SABPermissionService.assertPermission(PROCESS, 'Payroll payment processing permission is required.');
        SABPermissionService.assertPermission(POST_JOURNAL, 'Journal posting permission is required.');
        SABPermissionService.assertPermission(VIEW_DETAIL, 'Payroll detail permission is required.');
        Store store = new Store();
        Id runId = store.runForSettlement(settlementId);
        Payroll_Run__c visible = authorize(runId, new List<String>(), true);
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            if (prior.Action__c != ACTION_RETURNED || prior.Source_Type__c != SOURCE_SETTLEMENT
                || prior.Source_Record_Id__c != String.valueOf(settlementId)) {
                throw new PayrollSettlementException('Request key has already been used for a different payroll action.');
            }
            return returnReplay(visible.Id, settlementId);
        }
        Context ctx = lock(visible);
        assertPayableRun(ctx);
        Payroll_Settlement__c original = store.settlement(settlementId, true);
        if (original.Status__c != SETTLEMENT_EFFECTIVE || original.Reversal_Of__c != null || original.Allocated_Amount__c <= 0) {
            throw new PayrollSettlementException('Only an Effective payroll settlement can be returned.');
        }
        if (ctx.run.Workflow_State__c != RUN_SETTLED && ctx.run.Workflow_State__c != RUN_POSTED) {
            throw new PayrollSettlementException('Payroll run is not in a settleable state.');
        }
        Accounting_Payment__c payment = store.payment(original.Payment__c, true);
        if (payment.Processing_State__c != STATE_SUCCEEDED || payment.Company__c != ctx.run.Company__c) {
            throw new PayrollSettlementException('Only net pay from a succeeded payroll payment can be returned.');
        }
        if (returnDate < payment.Effective_Date__c) {
            throw new PayrollSettlementException('Return date cannot be before the payment date.');
        }
        Id periodId = assertPaymentDate(ctx, returnDate, true);
        Id bankGl = payment.Bank_Account__r.GL_Account__c;
        assertLedgerAccounts(ctx.run.Company__c, ctx.run.Net_Payable_Account__c, bankGl);
        Decimal amount = original.Allocated_Amount__c;
        Balance balance = balance(ctx.run);
        String eventKey = 'PAYROLL|' + ctx.run.Id + '|RETURN|' + original.Id;
        Savepoint sp = Database.setSavepoint();
        try {
            SABPostingService.PostingResult posted = postJournal(ctx, periodId, returnDate, amount, bankGl,
                ctx.run.Net_Payable_Account__c, eventKey, ADAPTER_RETURN, EVENT_TYPE_RETURN, SOURCE_SETTLEMENT,
                original.Id, key, 'Payroll net pay return ' + original.Id);
            Writer writer = new Writer();
            writer.updateSettlements(new List<Payroll_Settlement__c>{
                new Payroll_Settlement__c(Id = original.Id, Status__c = SETTLEMENT_FAILED)});
            Payroll_Settlement__c reversal = new Payroll_Settlement__c(Payment__c = original.Payment__c,
                Payroll_Line__c = original.Payroll_Line__c, Allocated_Amount__c = -amount, Effective_Date__c = returnDate,
                Status__c = SETTLEMENT_REVERSED, Reversal_Of__c = original.Id, Settlement_Key__c = returnKey(original.Id));
            writer.insertSettlements(new List<Payroll_Settlement__c>{reversal});
            updateRun(new Payroll_Run__c(Id = ctx.run.Id, Workflow_State__c = RUN_POSTED,
                Settled_Amount__c = balance.settled - amount, Settled_By__c = null, Settled_At__c = null));
            writer.actions(new List<Business_Action__c>{action(ctx.run.Company__c, ACTION_RETURNED, key, SOURCE_SETTLEMENT,
                original.Id, 'Payroll net pay returned by the bank: ' + reasonText)});
            return returnResult(ctx.run.Id, RUN_POSTED, original.Id, reversal.Id, amount,
                posted.accountingEventId, posted.journalEntryId, false);
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
    }

    @AuraEnabled
    public static SettlementSummary getSettlementSummary(Id runId) {
        requireRun(runId);
        Payroll_Run__c visible = authorize(runId, new List<String>(), false);
        List<Payroll_Run__c> runs = [SELECT Id, Company__c, Workflow_State__c, Net_Total__c, Settlement_Payment__c
            FROM Payroll_Run__c WHERE Id = :visible.Id WITH USER_MODE];
        Payroll_Run__c run = runs[0];
        Balance balance = balance(run);
        SettlementSummary summary = new SettlementSummary();
        summary.payrollRunId = run.Id;
        summary.runState = run.Workflow_State__c;
        summary.netTotal = balance.net;
        summary.settledTotal = balance.settled;
        summary.outstandingTotal = balance.outstanding;
        summary.lines = new List<LineSummary>();
        for (LineBalance line : balance.lines.values()) {
            LineSummary row = new LineSummary();
            row.payrollLineId = line.lineId;
            row.employmentId = line.employmentId;
            row.netAmount = line.net;
            row.settledAmount = line.settled;
            row.outstandingAmount = line.outstanding;
            row.effectiveSettlementId = line.effectiveSettlementId;
            summary.lines.add(row);
        }
        if (run.Settlement_Payment__c != null) {
            summary.paymentId = run.Settlement_Payment__c;
            summary.paymentState = new Store().payment(run.Settlement_Payment__c, false).Processing_State__c;
        }
        return summary;
    }

    // ------------------------------------------------------- authorization

    // Order: custom permissions, payroll detail, user-mode run read, company grant, record access.
    private static Payroll_Run__c authorize(Id runId, List<String> permissions, Boolean edit) {
        for (String permission : permissions) {
            SABPermissionService.assertPermission(permission, permissionMessage(permission));
        }
        SABPermissionService.assertPermission(VIEW_DETAIL, 'Payroll detail permission is required.');
        List<Payroll_Run__c> visible = [SELECT Id, Company__c FROM Payroll_Run__c WHERE Id = :runId WITH USER_MODE];
        if (visible.isEmpty()) {
            throw new PayrollSettlementException('Payroll Run not found or not accessible.');
        }
        SABCompanyAccessService.assertCompanyAccess(visible[0].Company__c);
        if (edit) {
            SABAccessControlService.assertRecordEditAccess(runId);
        } else {
            SABAccessControlService.assertRecordReadAccess(runId);
        }
        return visible[0];
    }

    private static String permissionMessage(String permission) {
        if (permission == AUTHORIZE) {
            return 'Payroll payment authorization permission is required.';
        }
        if (permission == POST_JOURNAL) {
            return 'Journal posting permission is required.';
        }
        return 'Payroll payment processing permission is required.';
    }

    private class Context {
        Payroll_Run__c run;
        Accounting_Company__c company;
    }

    // Company then run lock serializes every settlement action for the company.
    private static Context lock(Payroll_Run__c visible) {
        Id companyId = visible.Company__c;
        Id runId = visible.Id;
        List<Accounting_Company__c> companies = [SELECT Id, Is_Active__c, Functional_Currency__c
            FROM Accounting_Company__c WHERE Id = :companyId WITH USER_MODE FOR UPDATE];
        List<Payroll_Run__c> runs = Database.queryWithBinds(
            'SELECT Id, Company__c, Workflow_State__c, Currency__c, Version__c, Run_Key__c, Net_Total__c,'
            + ' Accounting_Event__c, Accounting_Date__c, Net_Payable_Account__c, Settlement_Payment__c,'
            + ' Settled_Amount__c FROM Payroll_Run__c WHERE Id = :runId FOR UPDATE',
            new Map<String, Object>{'runId' => runId}, AccessLevel.USER_MODE);
        if (companies.isEmpty() || runs.isEmpty()) {
            throw new PayrollSettlementException('Payroll Run not found or not accessible.');
        }
        Context ctx = new Context();
        ctx.company = companies[0];
        ctx.run = runs[0];
        if (ctx.run.Company__c != companyId) {
            throw new PayrollSettlementException('Payroll company changed; retry the request.');
        }
        return ctx;
    }

    private static void assertPayableRun(Context ctx) {
        if (ctx.company.Is_Active__c != true) {
            throw new PayrollSettlementException('Payroll company must be active.');
        }
        Payroll_Run__c run = ctx.run;
        if (run.Workflow_State__c != RUN_POSTED && run.Workflow_State__c != RUN_SETTLED) {
            throw new PayrollSettlementException('Only a Posted payroll run can be paid.');
        }
        if (run.Accounting_Event__c == null || run.Accounting_Date__c == null || run.Net_Payable_Account__c == null) {
            throw new PayrollSettlementException('Posted payroll is missing its accrual posting audit information.');
        }
        functionalCurrency(ctx);
    }

    private static String functionalCurrency(Context ctx) {
        String companyCurrency = SABMoneyService.normalizeCurrencyCode(ctx.company.Functional_Currency__c);
        if (SABMoneyService.normalizeCurrencyCode(ctx.run.Currency__c) != companyCurrency) {
            throw new PayrollSettlementException('G10E settles payroll in the company functional currency only.');
        }
        return companyCurrency;
    }

    // ---------------------------------------------------------- validation

    private static Bank_Account__c loadBank(Id bankAccountId) {
        List<Bank_Account__c> banks = [SELECT Id, Company__c, Currency__c, Is_Active__c, GL_Account__c,
            GL_Account__r.Company__c, GL_Account__r.Is_Active__c, GL_Account__r.Account_Type__c
            FROM Bank_Account__c WHERE Id = :bankAccountId WITH USER_MODE];
        if (banks.isEmpty()) {
            throw new PayrollSettlementException('Bank account not found or not accessible.');
        }
        return banks[0];
    }

    private static void assertBank(Id bankCompanyId, Boolean active, String bankCurrency, GL_Account__c gl, Context ctx) {
        if (bankCompanyId != ctx.run.Company__c || active != true || gl == null || gl.Company__c != ctx.run.Company__c
            || gl.Is_Active__c != true || gl.Account_Type__c != 'Asset') {
            throw new PayrollSettlementException('Bank account must be active, belong to the payroll company and map to an active Asset GL account.');
        }
        if (SABMoneyService.normalizeCurrencyCode(bankCurrency) != functionalCurrency(ctx)) {
            throw new PayrollSettlementException('Bank account currency must equal the company functional currency.');
        }
    }

    // Revalidates a payment loaded through the Store before every state change.
    private static void assertPaymentSetup(Accounting_Payment__c payment, Context ctx) {
        if ((payment.Payroll_Run__c != null && payment.Payroll_Run__c != ctx.run.Id)
            || payment.Company__c != ctx.run.Company__c || payment.Direction__c != 'Disbursement'
            || payment.Party_Profile__c != null || payment.Amount__c == null || payment.Amount__c <= 0) {
            throw new PayrollSettlementException('Payroll payment identity is inconsistent with the payroll run.');
        }
        if (SABMoneyService.normalizeCurrencyCode(payment.Transaction_Currency__c) != functionalCurrency(ctx)) {
            throw new PayrollSettlementException('G10E settles payroll in the company functional currency only.');
        }
        Bank_Account__c bank = payment.Bank_Account__r;
        assertBank(bank.Company__c, bank.Is_Active__c, bank.Currency__c, bank.GL_Account__r, ctx);
        assertPaymentDate(ctx, payment.Effective_Date__c, false);
    }

    // Returns the single Open period containing the date; locks it when posting.
    private static Id assertPaymentDate(Context ctx, Date effectiveDate, Boolean lockPeriod) {
        if (effectiveDate < ctx.run.Accounting_Date__c) {
            throw new PayrollSettlementException('Payment date cannot be before the payroll accrual date.');
        }
        Id companyId = ctx.run.Company__c;
        String soql = 'SELECT Id, Status__c FROM Accounting_Period__c WHERE Company__c = :companyId'
            + ' AND Start_Date__c <= :effectiveDate AND End_Date__c >= :effectiveDate LIMIT 2'
            + (lockPeriod ? ' FOR UPDATE' : '');
        List<Accounting_Period__c> periods = Database.queryWithBinds(soql,
            new Map<String, Object>{'companyId' => companyId, 'effectiveDate' => effectiveDate}, AccessLevel.USER_MODE);
        if (periods.size() != 1 || periods[0].Status__c != 'Open') {
            throw new PayrollSettlementException('Payment date must fall inside exactly one accessible Open accounting period.');
        }
        return periods[0].Id;
    }

    private static void assertLedgerAccounts(Id companyId, Id payableId, Id bankGlId) {
        Map<Id, GL_Account__c> accounts = new Map<Id, GL_Account__c>([SELECT Id, Company__c, Is_Active__c, Account_Type__c
            FROM GL_Account__c WHERE Id IN :new Set<Id>{payableId, bankGlId} WITH USER_MODE]);
        GL_Account__c payable = accounts.get(payableId);
        GL_Account__c bank = accounts.get(bankGlId);
        if (payable == null || payable.Company__c != companyId || payable.Is_Active__c != true || payable.Account_Type__c != 'Liability'
            || bank == null || bank.Company__c != companyId || bank.Is_Active__c != true || bank.Account_Type__c != 'Asset') {
            throw new PayrollSettlementException('Net payable must be an active Liability and the bank GL an active Asset account in the payroll company.');
        }
    }

    private static Accounting_Payment__c currentPayment(Context ctx, String requiredState, String stepLabel) {
        if (ctx.run.Workflow_State__c != RUN_POSTED || ctx.run.Settlement_Payment__c == null) {
            throw new PayrollSettlementException('Payroll run has no open payment for ' + stepLabel + '.');
        }
        Accounting_Payment__c payment = new Store().payment(ctx.run.Settlement_Payment__c, true);
        if (payment.Processing_State__c != requiredState) {
            throw new PayrollSettlementException('Payroll payment must be ' + requiredState + ' before ' + stepLabel + '.');
        }
        return payment;
    }

    private static String requireRequestKey(String requestKey) {
        Integer maxLength = Math.min(Business_Action__c.Request_Key__c.getDescribe().getLength(),
            Accounting_Event__c.Created_Request_Key__c.getDescribe().getLength());
        if (String.isBlank(requestKey) || requestKey.trim().length() > maxLength) {
            throw new PayrollSettlementException('Request key is required and must not exceed ' + maxLength + ' characters.');
        }
        return requestKey.trim();
    }

    private static String requireReason(String reason) {
        if (String.isBlank(reason) || reason.trim().length() > MAX_REASON) {
            throw new PayrollSettlementException('Reason is required and must not exceed ' + MAX_REASON + ' characters.');
        }
        return reason.trim();
    }

    private static void requireRun(Id runId) {
        if (runId == null) {
            throw new PayrollSettlementException('Payroll Run is required.');
        }
    }

    private static Set<String> activeMethods() {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry entry : Accounting_Payment__c.Method__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        return values;
    }

    // ------------------------------------------------------------- balances

    private class LineBalance {
        Id lineId;
        Id employmentId;
        Decimal net = 0;
        Decimal settled = 0;
        Decimal outstanding = 0;
        Id effectiveSettlementId;
    }

    private class Balance {
        Decimal net = 0;
        Decimal settled = 0;
        Decimal outstanding = 0;
        Map<Id, LineBalance> lines = new Map<Id, LineBalance>();
    }

    // Net per line minus Effective settlements; fails closed on hidden rows or over-settlement.
    private static Balance balance(Payroll_Run__c run) {
        Id runId = run.Id;
        List<Payroll_Line__c> lines = [SELECT Id, Employment__c, Net_Amount__c FROM Payroll_Line__c
            WHERE Payroll_Run__c = :runId WITH USER_MODE ORDER BY Id LIMIT 201];
        Store store = new Store();
        if (lines.isEmpty() || lines.size() > MAX_LINES || lines.size() != store.lineCount(runId)) {
            throw new PayrollSettlementException('Payroll line visibility or volume is incomplete; settlement cannot omit employees.');
        }
        Balance result = new Balance();
        for (Payroll_Line__c line : lines) {
            if (line.Net_Amount__c == null || line.Net_Amount__c < 0) {
                throw new PayrollSettlementException('Payroll line net amount is invalid.');
            }
            LineBalance row = new LineBalance();
            row.lineId = line.Id;
            row.employmentId = line.Employment__c;
            row.net = line.Net_Amount__c;
            result.lines.put(line.Id, row);
            result.net += line.Net_Amount__c;
        }
        if (result.net != run.Net_Total__c) {
            throw new PayrollSettlementException('Payroll settlement integrity check failed: line net pay does not reconcile to the run.');
        }
        for (Payroll_Settlement__c settlement : store.settlementsForRun(runId)) {
            LineBalance row = result.lines.get(settlement.Payroll_Line__c);
            if (row == null) {
                throw new PayrollSettlementException('Payroll settlement integrity check failed: settlement line is outside the run.');
            }
            if (settlement.Status__c == SETTLEMENT_EFFECTIVE) {
                if (row.effectiveSettlementId != null) {
                    throw new PayrollSettlementException('Payroll settlement integrity check failed: a line has more than one Effective settlement.');
                }
                row.settled += settlement.Allocated_Amount__c;
                row.effectiveSettlementId = settlement.Id;
            }
        }
        for (LineBalance row : result.lines.values()) {
            row.outstanding = row.net - row.settled;
            if (row.settled < 0 || row.outstanding < 0) {
                throw new PayrollSettlementException('Payroll settlement integrity check failed: a line is over-settled.');
            }
            result.settled += row.settled;
            result.outstanding += row.outstanding;
        }
        return result;
    }

    // --------------------------------------------------------------- ledger

    private static SABPostingService.PostingResult postJournal(Context ctx, Id periodId, Date accountingDate, Decimal amount,
            Id debitAccount, Id creditAccount, String eventKey, String adapter, String eventType, String sourceType,
            Id sourceId, String requestKey, String description) {
        String currencyCode = functionalCurrency(ctx);
        Journal_Entry__c journal = new Journal_Entry__c(Company__c = ctx.run.Company__c, Accounting_Period__c = periodId,
            Accounting_Date__c = accountingDate, Entry_Type__c = 'Subledger', Status__c = 'Draft', Version__c = 1,
            Description__c = description);
        insert as user journal;
        List<Journal_Entry_Line__c> lines = new List<Journal_Entry_Line__c>{
            journalLine(journal.Id, 1, debitAccount, amount, 0, currencyCode, accountingDate, eventKey),
            journalLine(journal.Id, 2, creditAccount, 0, amount, currencyCode, accountingDate, eventKey)
        };
        insert as user lines;
        SABAccountingEventService.ReservationRequest eventRequest = new SABAccountingEventService.ReservationRequest();
        eventRequest.companyId = ctx.run.Company__c;
        eventRequest.adapterKey = adapter;
        eventRequest.requestKey = requestKey;
        eventRequest.eventKey = eventKey;
        eventRequest.eventType = eventType;
        eventRequest.sourceBusinessKey = ctx.run.Run_Key__c;
        eventRequest.sourceRecordId = String.valueOf(sourceId);
        eventRequest.sourceType = sourceType;
        eventRequest.sourceVersion = 1;
        SABPostingService.PostingRequest posting = new SABPostingService.PostingRequest();
        posting.journalEntryId = journal.Id;
        posting.postingKey = eventKey;
        posting.eventRequest = eventRequest;
        return SABPostingService.postDraftJournal(posting);
    }

    private static Journal_Entry_Line__c journalLine(Id journalId, Integer lineNumber, Id account, Decimal debit,
            Decimal credit, String currencyCode, Date rateDate, String eventKey) {
        return new Journal_Entry_Line__c(Journal_Entry__c = journalId, Line_Number__c = lineNumber, GL_Account__c = account,
            Debit_Base__c = debit, Credit_Base__c = credit, Transaction_Amount__c = debit > 0 ? debit : credit,
            Transaction_Currency__c = currencyCode, Functional_Currency__c = currencyCode, Applied_Exchange_Rate__c = 1,
            Rate_Date__c = rateDate, Rate_Source__c = 'Payroll Functional Currency',
            Source_Line_Key__c = eventKey + '|' + lineNumber, Explanation__c = 'Payroll net-pay settlement');
    }

    // --------------------------------------------------------------- replay

    private static PaymentResult replayPrepare(Business_Action__c prior, Payroll_Run__c visible, Id bankAccountId,
            Date paymentDate, String method) {
        assertPriorAction(prior, ACTION_PREPARED, SOURCE_PAYMENT, visible.Id);
        Accounting_Payment__c payment = new Store().payment(Id.valueOf(prior.Source_Record_Id__c), false);
        if (payment.Bank_Account__c != bankAccountId || payment.Effective_Date__c != paymentDate || payment.Method__c != method) {
            throw new PayrollSettlementException('Request key has already been used for a different payroll payment request.');
        }
        return paymentResult(visible.Id, null, payment.Id, payment.Processing_State__c, payment.Amount__c, null, null, true);
    }

    private static PaymentResult replayLifecycle(Business_Action__c prior, Payroll_Run__c visible, String expectedAction) {
        assertPriorAction(prior, expectedAction, SOURCE_PAYMENT, visible.Id);
        Accounting_Payment__c payment = new Store().payment(Id.valueOf(prior.Source_Record_Id__c), false);
        return paymentResult(visible.Id, null, payment.Id, payment.Processing_State__c, payment.Amount__c, null, null, true);
    }

    private static void assertPriorAction(Business_Action__c prior, String expectedAction, String sourceType, Id runId) {
        if (prior.Action__c != expectedAction || prior.Source_Type__c != sourceType
            || !new Store().isLinked(prior.Source_Record_Id__c, runId)) {
            throw new PayrollSettlementException('Request key has already been used for a different payroll action.');
        }
    }

    private static PaymentResult succeededReplay(Id runId, Accounting_Payment__c payment) {
        Accounting_Event__c eventRecord = new Store().event('PAYROLL|' + runId + '|PAYMENT|' + payment.Id);
        if (payment.Processing_State__c != STATE_SUCCEEDED || eventRecord == null || payment.Accounting_Event__c != eventRecord.Id
            || eventRecord.Adapter_Key__c != ADAPTER_PAYMENT || eventRecord.State__c != 'Posted'
            || eventRecord.Journal_Entry__c == null || eventRecord.Journal_Entry__r.Status__c != 'Posted') {
            throw new PayrollSettlementException('Succeeded payroll payment does not have a consistent posting chain.');
        }
        return paymentResult(runId, null, payment.Id, STATE_SUCCEEDED, payment.Amount__c, eventRecord.Id,
            eventRecord.Journal_Entry__c, true);
    }

    private static ReturnResult returnReplay(Id runId, Id settlementId) {
        Store store = new Store();
        Accounting_Event__c eventRecord = store.event('PAYROLL|' + runId + '|RETURN|' + settlementId);
        Payroll_Settlement__c reversal = store.settlementByKey(returnKey(settlementId));
        if (eventRecord == null || eventRecord.Adapter_Key__c != ADAPTER_RETURN || eventRecord.State__c != 'Posted'
            || reversal == null || reversal.Reversal_Of__c != settlementId) {
            throw new PayrollSettlementException('Returned payroll settlement does not have a consistent posting chain.');
        }
        return returnResult(runId, null, settlementId, reversal.Id, -reversal.Allocated_Amount__c, eventRecord.Id,
            eventRecord.Journal_Entry__c, true);
    }

    // ---------------------------------------------------------------- writes

    private static PaymentResult lifecycleWrite(Context ctx, Accounting_Payment__c payment, String actionName, String key,
            String reason) {
        Savepoint sp = Database.setSavepoint();
        try {
            Writer writer = new Writer();
            writer.payment(payment);
            writer.actions(new List<Business_Action__c>{
                action(ctx.run.Company__c, actionName, key, SOURCE_PAYMENT, payment.Id, reason)});
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
        return paymentResult(ctx.run.Id, ctx.run.Workflow_State__c, payment.Id, payment.Processing_State__c,
            payment.Amount__c, null, null, false);
    }

    private static void updateRun(Payroll_Run__c change) {
        permittedRunId = change.Id;
        try {
            update as user change;
        } finally {
            permittedRunId = null;
        }
    }

    private static Business_Action__c action(Id companyId, String actionName, String key, String sourceType,
            Id sourceId, String reason) {
        return new Business_Action__c(Company__c = companyId, Action__c = actionName, Actor__c = UserInfo.getUserId(),
            Action_At__c = System.now(), Reason__c = reason, Request_Key__c = key, Source_Type__c = sourceType,
            Source_Record_Id__c = String.valueOf(sourceId), Source_Version__c = 1);
    }

    private static String linkKey(Id paymentId) {
        return 'PAYROLLPAY|' + paymentId;
    }

    private static String returnKey(Id settlementId) {
        return 'PAYROLL|RETURN|' + settlementId;
    }

    private static PaymentResult paymentResult(Id runId, String runState, Id paymentId, String paymentState, Decimal amount,
            Id eventId, Id journalId, Boolean replay) {
        PaymentResult r = new PaymentResult();
        r.payrollRunId = runId;
        r.runState = runState;
        r.paymentId = paymentId;
        r.paymentState = paymentState;
        r.amount = amount;
        r.accountingEventId = eventId;
        r.journalEntryId = journalId;
        r.replay = replay;
        return r;
    }

    private static ReturnResult returnResult(Id runId, String runState, Id settlementId, Id reversalId, Decimal amount,
            Id eventId, Id journalId, Boolean replay) {
        ReturnResult r = new ReturnResult();
        r.payrollRunId = runId;
        r.runState = runState;
        r.settlementId = settlementId;
        r.reversalSettlementId = reversalId;
        r.amount = amount;
        r.accountingEventId = eventId;
        r.journalEntryId = journalId;
        r.replay = replay;
        return r;
    }

    /**
     * Narrow system reads. Every caller has already passed the custom permission, payroll detail,
     * user-mode run read, company grant and run record-access checks. Settlements, payments and audit
     * rows are dependent records of that authorized run and must be read completely whatever their sharing.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Type__c, Source_Record_Id__c
                FROM Business_Action__c WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        Boolean isLinked(String paymentId, Id runId) {
            String key = 'PAYROLLPAY|' + paymentId;
            String runText = String.valueOf(runId);
            return [SELECT COUNT() FROM Business_Action__c WHERE Request_Key__c = :key AND Action__c = :ACTION_LINKED
                AND Source_Type__c = :SOURCE_RUN AND Source_Record_Id__c = :runText WITH SYSTEM_MODE] == 1;
        }
        Accounting_Payment__c payment(Id paymentId, Boolean lockRow) {
            String soql = 'SELECT Id, CreatedById, Company__c, Payroll_Run__c, Bank_Account__c, Direction__c, Party_Profile__c, Method__c,'
                + ' Reference__c, Amount__c, Transaction_Currency__c, Functional_Currency__c, Exchange_Rate__c,'
                + ' Effective_Date__c, Processing_State__c, Provider_Request_Key__c, Accounting_Event__c,'
                + ' Bank_Account__r.Company__c, Bank_Account__r.Currency__c, Bank_Account__r.Is_Active__c,'
                + ' Bank_Account__r.GL_Account__c, Bank_Account__r.GL_Account__r.Company__c,'
                + ' Bank_Account__r.GL_Account__r.Is_Active__c, Bank_Account__r.GL_Account__r.Account_Type__c'
                + ' FROM Accounting_Payment__c WHERE Id = :paymentId' + (lockRow ? ' FOR UPDATE' : '');
            List<Accounting_Payment__c> rows = Database.queryWithBinds(soql,
                new Map<String, Object>{'paymentId' => paymentId}, AccessLevel.SYSTEM_MODE);
            if (rows.isEmpty()) {
                throw new PayrollSettlementException('Payroll payment was not found.');
            }
            return rows[0];
        }
        Boolean providerKeyInUse(Id companyId, String providerKey, Id paymentId) {
            return [SELECT COUNT() FROM Accounting_Payment__c WHERE Company__c = :companyId
                AND Provider_Request_Key__c = :providerKey AND Id != :paymentId WITH SYSTEM_MODE] > 0;
        }
        void assertAccrualPosted(Payroll_Run__c run) {
            Id eventId = run.Accounting_Event__c;
            List<Accounting_Event__c> rows = [SELECT Id, Company__c, Adapter_Key__c, State__c, Source_Record_Id__c
                FROM Accounting_Event__c WHERE Id = :eventId WITH SYSTEM_MODE];
            if (rows.isEmpty() || rows[0].Company__c != run.Company__c || rows[0].Adapter_Key__c != 'PAYROLL_ACCRUAL'
                || rows[0].State__c != 'Posted' || rows[0].Source_Record_Id__c != String.valueOf(run.Id)) {
                throw new PayrollSettlementException('Payroll accrual posting is missing or inconsistent.');
            }
        }
        Integer lineCount(Id runId) {
            return [SELECT COUNT() FROM Payroll_Line__c WHERE Payroll_Run__c = :runId WITH SYSTEM_MODE];
        }
        List<Payroll_Settlement__c> settlementsForRun(Id runId) {
            return [SELECT Id, Payroll_Line__c, Payment__c, Allocated_Amount__c, Status__c, Reversal_Of__c
                FROM Payroll_Settlement__c WHERE Payroll_Line__r.Payroll_Run__c = :runId WITH SYSTEM_MODE LIMIT 2000];
        }
        Id runForSettlement(Id settlementId) {
            List<Payroll_Settlement__c> rows = [SELECT Payroll_Line__r.Payroll_Run__c FROM Payroll_Settlement__c
                WHERE Id = :settlementId WITH SYSTEM_MODE];
            if (rows.isEmpty()) {
                throw new PayrollSettlementException('Payroll settlement was not found.');
            }
            return rows[0].Payroll_Line__r.Payroll_Run__c;
        }
        Payroll_Settlement__c settlement(Id settlementId, Boolean lockRow) {
            String soql = 'SELECT Id, Payment__c, Payroll_Line__c, Allocated_Amount__c, Status__c, Reversal_Of__c,'
                + ' Effective_Date__c FROM Payroll_Settlement__c WHERE Id = :settlementId' + (lockRow ? ' FOR UPDATE' : '');
            return (Payroll_Settlement__c) Database.queryWithBinds(soql,
                new Map<String, Object>{'settlementId' => settlementId}, AccessLevel.SYSTEM_MODE)[0];
        }
        Payroll_Settlement__c settlementByKey(String key) {
            List<Payroll_Settlement__c> rows = [SELECT Id, Allocated_Amount__c, Reversal_Of__c FROM Payroll_Settlement__c
                WHERE Settlement_Key__c = :key WITH SYSTEM_MODE];
            return rows.isEmpty() ? null : rows[0];
        }
        Accounting_Event__c event(String eventKey) {
            List<Accounting_Event__c> rows = [SELECT Id, Adapter_Key__c, State__c, Journal_Entry__c, Journal_Entry__r.Status__c
                FROM Accounting_Event__c WHERE Event_Key__c = :eventKey WITH SYSTEM_MODE];
            return rows.isEmpty() ? null : rows[0];
        }
    }

    /**
     * Narrow system writes for service-managed rows: payment lifecycle fields (inside the shared payment
     * mutation context), settlement snapshots (inside this service's settlement scope) and audit rows.
     * Callers have completed every permission, company and record check first.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void payment(Accounting_Payment__c payment) {
            Accounting_Payment__c change = new Accounting_Payment__c(Id = payment.Id,
                Processing_State__c = payment.Processing_State__c, Provider_Request_Key__c = payment.Provider_Request_Key__c,
                Accounting_Event__c = payment.Accounting_Event__c);
            SABAccountingPaymentMutationContext.beginMutation();
            paymentWriteScope = true;
            try {
                update change;
            } finally {
                paymentWriteScope = false;
                SABAccountingPaymentMutationContext.endMutation();
            }
        }
        void insertSettlements(List<Payroll_Settlement__c> rows) {
            settlementWriteScope = true;
            try {
                insert rows;
            } finally {
                settlementWriteScope = false;
            }
        }
        void updateSettlements(List<Payroll_Settlement__c> rows) {
            settlementWriteScope = true;
            try {
                update rows;
            } finally {
                settlementWriteScope = false;
            }
        }
        void actions(List<Business_Action__c> rows) {
            insert rows;
        }
    }
}
