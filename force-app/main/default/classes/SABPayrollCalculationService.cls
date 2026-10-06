/**
 * G10B: compensation snapshots. G10F: Approved benefit awards are consumed into the run.
 * G10I: calendar-day proration, formula pay and statutory rules (SABPayrollRuleEngine).
 * Order per employee: fixed (prorated) -> formula -> benefit awards -> statutory. No GL posting.
 */
public with sharing class SABPayrollCalculationService {
    public class PayrollException extends Exception {}
    // @TestVisible so tests can seed payroll snapshots without replaying G10B-G10C (keeps @TestSetup SOQL low).
    @TestVisible private static Boolean writing = false;
    private static final String ACTION = 'SAB_Calculate_Payroll';

    // Trigger entry point: callers cannot enable the private write scope.
    public static void guard(List<SObject> rows) {
        if (!writing) {
            for (SObject row : rows) {
                if (!SABPayrollReviewService.permitsWorkflowWrite(row) && !SABPayrollPostingService.permitsWorkflowWrite(row)
                    && !SABPayrollSettlementService.permitsWorkflowWrite(row))
                    row.addError('Use the authorized payroll service to change payroll records.');
            }
        }
    }
    private static void authorize(Id companyId) {
        SABPermissionService.assertPermission(ACTION, 'Payroll calculation permission is required.');
        SABPermissionService.assertPermission('SAB_View_Payroll_Detail', 'Payroll detail permission is required.');
        SABCompanyAccessService.assertCompanyAccess(companyId);
        SABAccessControlService.assertRecordReadAccess(companyId);
    }
    @AuraEnabled
    public static Id createDraft(Id companyId, Date periodStart, Date periodEnd, String currencyCode, String runKey) {
        authorize(companyId);
        if (periodStart == null || periodEnd == null || periodEnd < periodStart) {
            throw new PayrollException('A valid payroll start and end date are required.');
        }
        if (String.isBlank(runKey) || runKey.trim().length() > 180) {
            throw new PayrollException('Run key is required and must not exceed 180 characters.');
        }
        String normalized = SABMoneyService.normalizeCurrencyCode(currencyCode);
        Payroll_Run__c run = new Payroll_Run__c(Company__c=companyId,
            Pay_Period_Start__c=periodStart, Pay_Period_End__c=periodEnd,
            Currency__c=normalized, Run_Key__c=runKey.trim(), Version__c=1,
            Workflow_State__c='Draft', Gross_Total__c=0, Deduction_Total__c=0,
            Employer_Total__c=0, Net_Total__c=0);
        writing=true;
        try { insert as user run; } finally { writing=false; }
        return run.Id;
    }
    @AuraEnabled
    public static Id calculate(Id runId, List<Id> employmentIds, Integer minorUnits) {
        if (runId == null || employmentIds == null || employmentIds.isEmpty() || employmentIds.size() > 200) {
            throw new PayrollException('Select a run and between 1 and 200 employments.');
        }
        if (minorUnits == null || minorUnits < 0 || minorUnits > 3) {
            throw new PayrollException('Currency minor units must be explicitly supplied from 0 to 3.');
        }
        Set<Id> selected = new Set<Id>(employmentIds);
        if (selected.contains(null) || selected.size()!=employmentIds.size()) {
            throw new PayrollException('Employment selection contains null or duplicate IDs.');
        }
        List<Payroll_Run__c> visible = [SELECT Id, Company__c FROM Payroll_Run__c WHERE Id=:runId WITH USER_MODE];
        if (visible.isEmpty()) throw new PayrollException('Payroll run not found or not accessible.');
        authorize(visible[0].Company__c);
        SABAccessControlService.assertRecordEditAccess(runId);
        // Serialize calculations for a company, including distinct runs for overlapping periods.
        Id companyId=visible[0].Company__c;
        List<Accounting_Company__c> companyLock=[SELECT Id FROM Accounting_Company__c WHERE Id=:companyId WITH USER_MODE FOR UPDATE];
        if (companyLock.isEmpty()) throw new PayrollException('Payroll company not found or not accessible.');
        Payroll_Run__c run=[SELECT Id, Company__c, Pay_Period_Start__c, Pay_Period_End__c, Currency__c,
            Workflow_State__c, Version__c FROM Payroll_Run__c WHERE Id=:runId WITH USER_MODE FOR UPDATE];
        if (run.Workflow_State__c!='Draft') throw new PayrollException('Only Draft payroll runs can be calculated.');
        Date starts=run.Pay_Period_Start__c, ends=run.Pay_Period_End__c;
        List<Employment__c> employments=[SELECT Id, Company__c, Start_Date__c, End_Date__c,
            Employment_Status__c, Employee__r.Status__c, Department__c, Cost_Center__c
            FROM Employment__c WHERE Id IN :selected WITH USER_MODE];
        if (employments.size()!=selected.size()) throw new PayrollException('One or more employments are not accessible.');
        Integer totalDays=SABPayrollRuleEngine.periodDays(starts,ends);
        Map<Id,SABPayrollRuleEngine.Window> activeWindows=new Map<Id,SABPayrollRuleEngine.Window>();
        for (Employment__c e:employments) {
            if (e.Company__c!=companyId) throw new PayrollException('All employments must belong to the payroll company.');
            // G10I: Active employments, or final pay for an employment that ended inside or after the period start.
            Boolean active=e.Employment_Status__c=='Active' && e.Employee__r.Status__c=='Active';
            Boolean finalPay=e.Employment_Status__c=='Ended' && e.End_Date__c!=null;
            if (!active && !finalPay) throw new PayrollException('Only active employments, or ended employments for final pay, can be calculated.');
            SABPayrollRuleEngine.Window w=SABPayrollRuleEngine.overlap(starts,ends,e.Start_Date__c,e.End_Date__c);
            if (w==null) throw new PayrollException('An employment does not overlap the pay period.');
            activeWindows.put(e.Id,w);
        }
        // Narrow system query prevents duplicate results hidden by record sharing.
        List<SObject> duplicates=Database.queryWithBinds(
            'SELECT Id FROM Payroll_Line__c WHERE Employment__c IN :ids'
            +' AND Payroll_Run__r.Company__c = :companyId AND Payroll_Run__r.Workflow_State__c != \'Cancelled\''
            +' AND Payroll_Run__r.Pay_Period_Start__c <= :ends AND Payroll_Run__r.Pay_Period_End__c >= :starts LIMIT 1',
            new Map<String,Object>{'ids'=>selected,'companyId'=>companyId,'ends'=>ends,'starts'=>starts},AccessLevel.SYSTEM_MODE);
        if (!duplicates.isEmpty()) throw new PayrollException('An overlapping non-cancelled payroll already contains a selected employment.');
        List<Employee_Pay_Component__c> assignments=[SELECT Id, Employment__c, Pay_Component__c,
            Pay_Component__r.Company__c, Pay_Component__r.Category__c, Pay_Component__r.Is_Active__c,
            Pay_Component__r.Expense_Account__c, Pay_Component__r.Liability_Account__c, Pay_Component__r.Country_Rule_Key__c,
            Amount__c, Currency__c, Effective_From__c, Effective_To__c, Formula_Parameter_JSON__c
            FROM Employee_Pay_Component__c WHERE Employment__c IN :selected AND Status__c='Approved'
            AND Effective_From__c<=:ends AND (Effective_To__c=null OR Effective_To__c>=:starts)
            WITH USER_MODE LIMIT 1001];
        if (assignments.size()>1000) throw new PayrollException('The supported limit is 1000 compensation components per run.');
        List<SObject> expectedAssignments=Database.queryWithBinds(
            'SELECT Id FROM Employee_Pay_Component__c WHERE Employment__c IN :ids AND Status__c = \'Approved\''
            +' AND Effective_From__c <= :ends AND (Effective_To__c = null OR Effective_To__c >= :starts) LIMIT 1001',
            new Map<String,Object>{'ids'=>selected,'starts'=>starts,'ends'=>ends},AccessLevel.SYSTEM_MODE);
        if (expectedAssignments.size()!=assignments.size())
            throw new PayrollException('Compensation visibility is incomplete; calculation cannot omit hidden assignments.');
        Map<Id,Payroll_Line__c> lines=new Map<Id,Payroll_Line__c>();
        for (Employment__c e:employments) lines.put(e.Id,new Payroll_Line__c(Payroll_Run__c=runId,
            Employment__c=e.Id, Department_Snapshot__c=e.Department__c==null?null:String.valueOf(e.Department__c),
            Cost_Center_Snapshot__c=e.Cost_Center__c==null?null:String.valueOf(e.Cost_Center__c),
            Gross_Amount__c=0,Deduction_Amount__c=0,Employer_Contribution__c=0,Net_Amount__c=0));
        Accumulator acc=new Accumulator(lines,minorUnits,run,totalDays);
        // G10I: classify and validate every assignment before evaluating any of them.
        Map<String,List<SABPayrollRuleEngine.Window>> windowsByPair=new Map<String,List<SABPayrollRuleEngine.Window>>();
        List<Classified> fixedRows=new List<Classified>(), formulaRows=new List<Classified>(), statutoryRows=new List<Classified>();
        Set<Id> covered=new Set<Id>();
        for (Employee_Pay_Component__c a:assignments) {
            if (!a.Pay_Component__r.Is_Active__c || (a.Pay_Component__r.Company__c!=null && a.Pay_Component__r.Company__c!=companyId))
                throw new PayrollException('Pay Component is inactive or belongs to another company.');
            if (a.Currency__c!=run.Currency__c) throw new PayrollException('Compensation currency must match payroll currency.');
            if (a.Amount__c!=null && a.Amount__c<0) throw new PayrollException('Compensation amounts cannot be negative.');
            String category=a.Pay_Component__r.Category__c;
            if (!SABPayrollRuleEngine.ALL_CATEGORIES.contains(category)) throw new PayrollException('Unsupported compensation category.');
            SABPayrollRuleEngine.Window w=SABPayrollRuleEngine.overlap(activeWindows.get(a.Employment__c).startDate,
                activeWindows.get(a.Employment__c).endDate,a.Effective_From__c,a.Effective_To__c);
            if (w==null) continue;
            String pair=String.valueOf(a.Employment__c)+':'+String.valueOf(a.Pay_Component__c);
            if (!windowsByPair.containsKey(pair)) windowsByPair.put(pair,new List<SABPayrollRuleEngine.Window>());
            for (SABPayrollRuleEngine.Window other:windowsByPair.get(pair)) {
                if (SABPayrollRuleEngine.overlap(w.startDate,w.endDate,other.startDate,other.endDate)!=null)
                    throw new PayrollException('Overlapping approved compensation assignments were found.');
            }
            windowsByPair.get(pair).add(w);
            covered.add(a.Employment__c);
            Classified c=new Classified(a,w);
            if (!String.isBlank(a.Pay_Component__r.Country_Rule_Key__c)) {
                if (!String.isBlank(a.Formula_Parameter_JSON__c))
                    throw new PayrollException('Statutory pay components are calculated by their rule and take no formula.');
                if (category!='Deduction' && category!='Employer Contribution')
                    throw new PayrollException('Statutory pay components must be Deduction or Employer Contribution.');
                statutoryRows.add(c);
            } else if (!String.isBlank(a.Formula_Parameter_JSON__c)) {
                try { c.formula=SABPayrollRuleEngine.parseFormula(a.Formula_Parameter_JSON__c); }
                catch (SABPayrollRuleEngine.RuleException ex) { throw new PayrollException(ex.getMessage()); }
                formulaRows.add(c);
            } else {
                if (a.Amount__c==null) throw new PayrollException('Fixed compensation needs an amount.');
                fixedRows.add(c);
            }
        }
        if (covered.size()!=selected.size()) throw new PayrollException('Each selected employment needs approved compensation for this period.');
        // 1. Fixed pay, prorated by covered calendar days.
        for (Classified c:fixedRows) {
            Decimal raw=SABPayrollRuleEngine.prorate(c.a.Amount__c,c.w.days,totalDays);
            acc.add(c,raw,c.w.days==totalDays?SABPayrollRuleEngine.RULE_FIXED:SABPayrollRuleEngine.RULE_PRORATED,null);
        }
        // 2. Formula pay; PERCENT_OF reads the employee's fixed totals only, so formula order never matters.
        Map<Id,Map<String,Decimal>> fixedTotals=acc.snapshotTotals();
        for (Classified c:formulaRows) {
            Map<String,Decimal> basis=fixedTotals.containsKey(c.a.Employment__c)?fixedTotals.get(c.a.Employment__c):new Map<String,Decimal>();
            Decimal raw;
            try { raw=SABPayrollRuleEngine.evaluateFormula(c.formula,c.a.Amount__c,basis,c.w.days,totalDays); }
            catch (SABPayrollRuleEngine.RuleException ex) { throw new PayrollException(ex.getMessage()); }
            acc.add(c,raw,SABPayrollRuleEngine.RULE_FORMULA,new Map<String,Object>{'formula'=>c.a.Formula_Parameter_JSON__c});
        }
        // 3. G10F: consume Approved awards (service started by period end, arrears included); fails closed on hidden awards.
        List<SABPayrollBenefitAwardService.EligibleAward> awards;
        try {
            awards=SABPayrollBenefitAwardService.eligibleAwards(run,selected,minorUnits,assignments.size());
        } catch (SABPayrollBenefitAwardService.BenefitAwardException ex) { throw new PayrollException(ex.getMessage()); }
        for (SABPayrollBenefitAwardService.EligibleAward a:awards) acc.addAward(a);
        // 4. Statutory rules on the final gross (after formulas and awards).
        if (!statutoryRows.isEmpty()) {
            String countryCode=new RuleStore().companyCountry(companyId);
            Map<String,SABPayrollRuleEngine.StatutoryRule> rules=new Map<String,SABPayrollRuleEngine.StatutoryRule>();
            for (Classified c:statutoryRows) {
                String key=c.a.Pay_Component__r.Country_Rule_Key__c;
                try {
                    if (!rules.containsKey(key)) rules.put(key,SABPayrollRuleEngine.ruleFor(key,countryCode,ends));
                    SABPayrollRuleEngine.StatutoryRule rule=rules.get(key);
                    Map<String,Decimal> employeeTotals=acc.totalsFor(c.a.Employment__c);
                    Decimal raw=SABPayrollRuleEngine.evaluateStatutory(rule,employeeTotals);
                    acc.add(c,raw,SABPayrollRuleEngine.RULE_STATUTORY,new Map<String,Object>{'ruleKey'=>rule.ruleKey,
                        'ruleVersion'=>rule.ruleVersion,'method'=>rule.method,'country'=>countryCode,
                        'basis'=>SABPayrollRuleEngine.statutoryBasis(rule,employeeTotals)});
                } catch (SABPayrollRuleEngine.RuleException ex) { throw new PayrollException(ex.getMessage()); }
            }
        }
        List<Payroll_Component_Line__c> details=acc.details;
        List<Id> detailEmployments=acc.detailEmployments;
        Payroll_Run__c totals=new Payroll_Run__c(Id=runId,Workflow_State__c='Calculated',
            Gross_Total__c=0,Deduction_Total__c=0,Employer_Total__c=0,Net_Total__c=0);
        for (Payroll_Line__c line:lines.values()) {
            line.Net_Amount__c=line.Gross_Amount__c-line.Deduction_Amount__c;
            if (line.Net_Amount__c<0) throw new PayrollException('Deductions cannot exceed gross pay in G10B.');
            totals.Gross_Total__c+=line.Gross_Amount__c;totals.Deduction_Total__c+=line.Deduction_Amount__c;
            totals.Employer_Total__c+=line.Employer_Contribution__c;totals.Net_Total__c+=line.Net_Amount__c;
        }
        Savepoint checkpoint=Database.setSavepoint(); writing=true;
        try {
            List<Payroll_Line__c> insertLines=lines.values(); insert as user insertLines;
            for (Integer i=0;i<details.size();i++) details[i].Payroll_Line__c=lines.get(detailEmployments[i]).Id;
            insert as user details;
            update as user totals;
            SABPayrollBenefitAwardService.consume(run,awards);
        } catch (Exception ex) { Database.rollback(checkpoint); throw ex; }
        finally { writing=false; }
        return runId;
    }

    // G10I: one validated assignment and its covered window within the employment and the period.
    private class Classified {
        Employee_Pay_Component__c a;
        SABPayrollRuleEngine.Window w;
        SABPayrollRuleEngine.Formula formula;
        Classified(Employee_Pay_Component__c a, SABPayrollRuleEngine.Window w) {
            this.a=a;
            this.w=w;
        }
    }

    // G10I: builds line totals, per-category totals and auditable component snapshots in calculation order.
    private class Accumulator {
        Map<Id,Payroll_Line__c> lines;
        Map<Id,Map<String,Decimal>> categoryTotals=new Map<Id,Map<String,Decimal>>();
        List<Payroll_Component_Line__c> details=new List<Payroll_Component_Line__c>();
        List<Id> detailEmployments=new List<Id>();
        Integer minorUnits;
        Payroll_Run__c run;
        Integer totalDays;
        Accumulator(Map<Id,Payroll_Line__c> lines, Integer minorUnits, Payroll_Run__c run, Integer totalDays) {
            this.lines=lines;
            this.minorUnits=minorUnits;
            this.run=run;
            this.totalDays=totalDays;
        }
        void add(Classified c, Decimal raw, String ruleVersion, Map<String,Object> extra) {
            Decimal amount=SABMoneyService.roundForMinorUnits(raw,minorUnits,RoundingMode.HALF_UP);
            Map<String,Object> snapshot=new Map<String,Object>{'assignmentId'=>c.a.Id,'periodStart'=>run.Pay_Period_Start__c,
                'periodEnd'=>run.Pay_Period_End__c,'currency'=>run.Currency__c,'sourceAmount'=>c.a.Amount__c,'minorUnits'=>minorUnits,
                'rounding'=>'HALF_UP','effectiveFrom'=>c.a.Effective_From__c,'effectiveTo'=>c.a.Effective_To__c,
                'coveredFrom'=>c.w.startDate,'coveredTo'=>c.w.endDate,'coveredDays'=>c.w.days,'periodDays'=>totalDays,'unrounded'=>raw};
            if (extra!=null) snapshot.putAll(extra);
            record(c.a.Employment__c,c.a.Pay_Component__c,null,c.a.Pay_Component__r.Category__c,amount,
                c.a.Pay_Component__r.Expense_Account__c,c.a.Pay_Component__r.Liability_Account__c,ruleVersion,JSON.serialize(snapshot));
        }
        void addAward(SABPayrollBenefitAwardService.EligibleAward a) {
            record(a.employmentId,a.payComponentId,a.awardId,a.category,a.amount,a.expenseAccountId,a.liabilityAccountId,
                SABPayrollBenefitAwardService.RULE_VERSION,a.eligibilitySnapshot);
        }
        void record(Id employmentId, Id componentId, Id awardId, String category, Decimal amount, Id expenseId, Id liabilityId,
                String ruleVersion, String snapshot) {
            Payroll_Line__c line=lines.get(employmentId);
            if (category=='Deduction') line.Deduction_Amount__c+=amount;
            else if (category=='Employer Contribution') line.Employer_Contribution__c+=amount;
            else line.Gross_Amount__c+=amount;
            Map<String,Decimal> totals=totalsFor(employmentId);
            totals.put(category,(totals.containsKey(category)?totals.get(category):0)+amount);
            details.add(new Payroll_Component_Line__c(Pay_Component__c=componentId,Benefit_Award__c=awardId,Amount__c=amount,
                Component_Category__c=category,Expense_Account__c=expenseId,Liability_Account__c=liabilityId,
                Rule_Version__c=ruleVersion,Eligibility_Snapshot__c=snapshot));
            detailEmployments.add(employmentId);
        }
        Map<String,Decimal> totalsFor(Id employmentId) {
            if (!categoryTotals.containsKey(employmentId)) categoryTotals.put(employmentId,new Map<String,Decimal>());
            return categoryTotals.get(employmentId);
        }
        Map<Id,Map<String,Decimal>> snapshotTotals() {
            Map<Id,Map<String,Decimal>> copy=new Map<Id,Map<String,Decimal>>();
            for (Id employmentId:categoryTotals.keySet()) copy.put(employmentId,categoryTotals.get(employmentId).clone());
            return copy;
        }
    }

    /**
     * G10I: the company's country code for statutory rule matching. A narrow system read of one field
     * after the calculation's permission, company and record checks; it runs only when statutory rules apply.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class RuleStore {
        String companyCountry(Id companyId) {
            List<Accounting_Company__c> rows=[SELECT Country_Code__c FROM Accounting_Company__c WHERE Id=:companyId WITH SYSTEM_MODE];
            return rows.isEmpty()?null:rows[0].Country_Code__c;
        }
    }
}
