/**
 * G10F: Benefit-award consumption into payroll.
 *
 * - SABPayrollCalculationService.calculate pulls every Approved, unconsumed award for the selected
 *   employments whose service has started by the pay period end (arrears included) and snapshots it
 *   as a Payroll_Component_Line__c linked through Benefit_Award__c.
 * - The awards are marked Consumed with Consumed_By_Payroll_Run__c in the same transaction.
 * - Cancelling an unposted run (SABPayrollReviewService.cancel) releases them back to Approved.
 * - Posted and Settled runs keep their awards Consumed permanently.
 * - Consumed status and the run link change only through this service (SABBenefitAwardPayrollGuardTrigger).
 */
public with sharing class SABPayrollBenefitAwardService {
    public class BenefitAwardException extends Exception {}

    public static final String RULE_VERSION = 'G10F_AWARD_V1';
    private static final Integer MAX_COMPONENTS = 1000;
    private static final String APPROVED = 'Approved';
    private static final String CONSUMED = 'Consumed';
    private static final Set<String> CATEGORIES = new Set<String>{'Basic Salary', 'Incentive', 'Food Allowance', 'Other',
        'Deduction', 'Employer Contribution'};

    // Opened only while this service writes awards; the guard trigger reads it.
    @TestVisible private static Boolean awardWriteScope = false;

    /** Award snapshot handed to the calculation service. */
    public class EligibleAward {
        public Id awardId;
        public Id employmentId;
        public Id payComponentId;
        public String category;
        public Id expenseAccountId;
        public Id liabilityAccountId;
        public Decimal amount;
        public String eligibilitySnapshot;
    }

    // ------------------------------------------------------------ guard hook

    /** Trigger entry point for Benefit_Award__c. G10A approve and cancel flows are unaffected. */
    public static void guardAwards(List<Benefit_Award__c> rows, Map<Id, Benefit_Award__c> oldMap, Boolean isDelete) {
        if (awardWriteScope) {
            return;
        }
        for (Benefit_Award__c row : rows) {
            Benefit_Award__c old = oldMap == null ? null : oldMap.get(row.Id);
            Boolean touchesConsumption = isDelete
                ? row.Status__c == CONSUMED
                : (row.Status__c == CONSUMED || row.Consumed_By_Payroll_Run__c != null
                    || (old != null && (old.Status__c == CONSUMED || old.Consumed_By_Payroll_Run__c != row.Consumed_By_Payroll_Run__c)));
            if (touchesConsumption) {
                row.addError('Benefit award consumption is controlled by payroll calculation and cancellation.');
            }
        }
    }

    // ----------------------------------------------------- calculation side

    /**
     * Returns the eligible awards for an authorized, locked Draft run. Called by
     * SABPayrollCalculationService.calculate after its permission, company and record checks.
     * Fails closed when any eligible award is hidden from the calculating user.
     */
    public static List<EligibleAward> eligibleAwards(Payroll_Run__c run, Set<Id> employmentIds, Integer minorUnits,
            Integer assignmentCount) {
        Date ends = run.Pay_Period_End__c;
        // The system lock replaces the old G10B existence query, so a run without awards costs no extra SOQL.
        Set<Id> locked = new Store().lockEligible(employmentIds, ends);
        if (locked.isEmpty()) {
            return new List<EligibleAward>();
        }
        List<Benefit_Award__c> visible = [SELECT Id, Award_Key__c, Employment__c, Pay_Component__c, Amount__c, Currency__c,
            Service_Period_Start__c, Service_Period_End__c, Pay_Component__r.Company__c, Pay_Component__r.Category__c,
            Pay_Component__r.Is_Active__c, Pay_Component__r.Expense_Account__c, Pay_Component__r.Liability_Account__c
            FROM Benefit_Award__c WHERE Employment__c IN :employmentIds AND Status__c = :APPROVED
            AND Consumed_By_Payroll_Run__c = null AND (Service_Period_Start__c = null OR Service_Period_Start__c <= :ends)
            WITH USER_MODE ORDER BY Award_Key__c LIMIT 1001];
        Set<Id> visibleIds = new Map<Id, Benefit_Award__c>(visible).keySet();
        assertComplete(visibleIds, locked);
        if (visible.size() + assignmentCount > MAX_COMPONENTS) {
            throw new BenefitAwardException('The supported limit is 1000 compensation and award components per run.');
        }
        List<EligibleAward> result = new List<EligibleAward>();
        for (Benefit_Award__c award : visible) {
            result.add(snapshot(award, run, minorUnits));
        }
        return result;
    }

    @TestVisible
    private static void assertComplete(Set<Id> visibleIds, Set<Id> lockedIds) {
        if (!visibleIds.equals(lockedIds)) {
            throw new BenefitAwardException('Benefit award visibility is incomplete; calculation cannot omit hidden approved awards.');
        }
    }

    @TestVisible
    private static EligibleAward snapshot(Benefit_Award__c award, Payroll_Run__c run, Integer minorUnits) {
        Pay_Component__c component = award.Pay_Component__r;
        if (component == null || component.Is_Active__c != true
            || (component.Company__c != null && component.Company__c != run.Company__c)) {
            throw new BenefitAwardException('Benefit award ' + award.Award_Key__c + ' uses an inactive pay component or one from another company.');
        }
        if (!CATEGORIES.contains(component.Category__c)) {
            throw new BenefitAwardException('Benefit award ' + award.Award_Key__c + ' uses an unsupported pay component category.');
        }
        if (award.Currency__c != run.Currency__c) {
            throw new BenefitAwardException('Benefit award ' + award.Award_Key__c + ' currency must match payroll currency.');
        }
        if (award.Amount__c == null || award.Amount__c <= 0) {
            throw new BenefitAwardException('Benefit award ' + award.Award_Key__c + ' amount must be greater than zero.');
        }
        Decimal amount = SABMoneyService.roundForMinorUnits(award.Amount__c, minorUnits, RoundingMode.HALF_UP);
        if (amount <= 0) {
            throw new BenefitAwardException('Benefit award ' + award.Award_Key__c + ' rounds to zero at the payroll currency precision.');
        }
        EligibleAward row = new EligibleAward();
        row.awardId = award.Id;
        row.employmentId = award.Employment__c;
        row.payComponentId = award.Pay_Component__c;
        row.category = component.Category__c;
        row.expenseAccountId = component.Expense_Account__c;
        row.liabilityAccountId = component.Liability_Account__c;
        row.amount = amount;
        row.eligibilitySnapshot = JSON.serialize(new Map<String, Object>{'awardId' => award.Id, 'awardKey' => award.Award_Key__c,
            'periodStart' => run.Pay_Period_Start__c, 'periodEnd' => run.Pay_Period_End__c, 'currency' => run.Currency__c,
            'sourceAmount' => award.Amount__c, 'minorUnits' => minorUnits, 'rounding' => 'HALF_UP',
            'serviceStart' => award.Service_Period_Start__c, 'serviceEnd' => award.Service_Period_End__c});
        return row;
    }

    /** Marks snapshotted awards Consumed by the run. Runs inside the calculation savepoint. */
    public static void consume(Payroll_Run__c run, List<EligibleAward> awards) {
        if (awards == null || awards.isEmpty()) {
            return;
        }
        List<Benefit_Award__c> changes = new List<Benefit_Award__c>();
        Decimal total = 0;
        for (EligibleAward award : awards) {
            changes.add(new Benefit_Award__c(Id = award.awardId, Status__c = CONSUMED, Consumed_By_Payroll_Run__c = run.Id));
            total += award.amount;
        }
        new Writer().awards(changes, new Business_Action__c(Company__c = run.Company__c, Action__c = 'PAYROLL_AWARDS_CONSUMED',
            Actor__c = UserInfo.getUserId(), Action_At__c = System.now(), Request_Key__c = 'PAYROLL|' + run.Id + '|AWARDS|CONSUMED',
            Reason__c = changes.size() + ' benefit awards consumed, total ' + total + ' ' + run.Currency__c + '.',
            Source_Type__c = 'Payroll_Run__c', Source_Record_Id__c = String.valueOf(run.Id), Source_Version__c = 1));
    }

    // ------------------------------------------------------ cancellation side

    /**
     * Returns a cancelled run's awards to Approved. Called by SABPayrollReviewService.cancel after its
     * authorization and the Cancelled state change; refuses to release awards of any run that is not Cancelled.
     */
    public static Integer releaseForRun(Id runId) {
        Store store = new Store();
        // One query when nothing was consumed (the common case); the run-state check guards every real release.
        List<Benefit_Award__c> consumed = store.consumedBy(runId);
        if (consumed.isEmpty()) {
            return 0;
        }
        Payroll_Run__c run = store.run(runId);
        if (run == null || run.Workflow_State__c != 'Cancelled') {
            throw new BenefitAwardException('Benefit awards are released only by cancelling an unposted payroll run.');
        }
        List<Benefit_Award__c> changes = new List<Benefit_Award__c>();
        for (Benefit_Award__c award : consumed) {
            changes.add(new Benefit_Award__c(Id = award.Id, Status__c = APPROVED, Consumed_By_Payroll_Run__c = null));
        }
        new Writer().awards(changes, new Business_Action__c(Company__c = run.Company__c, Action__c = 'PAYROLL_AWARDS_RELEASED',
            Actor__c = UserInfo.getUserId(), Action_At__c = System.now(), Request_Key__c = 'PAYROLL|' + runId + '|AWARDS|RELEASED',
            Reason__c = changes.size() + ' benefit awards released by payroll cancellation.', Source_Type__c = 'Payroll_Run__c',
            Source_Record_Id__c = String.valueOf(runId), Source_Version__c = 1));
        return changes.size();
    }

    /**
     * Narrow system reads. Callers have already authorized the run (permission, company grant, record access);
     * awards are read completely so a hidden award can never be skipped or left consumed.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Set<Id> lockEligible(Set<Id> employmentIds, Date ends) {
            return new Map<Id, Benefit_Award__c>([SELECT Id FROM Benefit_Award__c WHERE Employment__c IN :employmentIds
                AND Status__c = :APPROVED AND Consumed_By_Payroll_Run__c = null
                AND (Service_Period_Start__c = null OR Service_Period_Start__c <= :ends)
                WITH SYSTEM_MODE LIMIT 1001 FOR UPDATE]).keySet();
        }
        Payroll_Run__c run(Id runId) {
            List<Payroll_Run__c> rows = [SELECT Id, Company__c, Workflow_State__c FROM Payroll_Run__c WHERE Id = :runId WITH SYSTEM_MODE];
            return rows.isEmpty() ? null : rows[0];
        }
        List<Benefit_Award__c> consumedBy(Id runId) {
            return [SELECT Id FROM Benefit_Award__c WHERE Consumed_By_Payroll_Run__c = :runId AND Status__c = :CONSUMED
                WITH SYSTEM_MODE LIMIT 1001 FOR UPDATE];
        }
    }

    /** Narrow system writes for service-owned award consumption fields and the audit row. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void awards(List<Benefit_Award__c> changes, Business_Action__c audit) {
            awardWriteScope = true;
            try {
                update changes;
            } finally {
                awardWriteScope = false;
            }
            insert audit;
        }
    }
}
