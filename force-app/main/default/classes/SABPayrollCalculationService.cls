/** G10B: fixed-period compensation snapshots. G10F: Approved benefit awards are consumed into the run. No statutory rules or GL posting. */
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
        for (Employment__c e:employments) {
            if (e.Company__c!=companyId) throw new PayrollException('All employments must belong to the payroll company.');
            if (e.Employment_Status__c!='Active' || e.Employee__r.Status__c!='Active'
                || e.Start_Date__c>starts || (e.End_Date__c!=null && e.End_Date__c<ends)) {
                throw new PayrollException('G10B requires active employment covering the complete pay period.');
            }
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
            Pay_Component__r.Expense_Account__c, Pay_Component__r.Liability_Account__c,
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
        Set<String> pairs=new Set<String>(); Set<Id> covered=new Set<Id>();
        List<Payroll_Component_Line__c> details=new List<Payroll_Component_Line__c>();
        List<Id> detailEmployments=new List<Id>();
        for (Employee_Pay_Component__c a:assignments) {
            if (!a.Pay_Component__r.Is_Active__c || (a.Pay_Component__r.Company__c!=null && a.Pay_Component__r.Company__c!=companyId))
                throw new PayrollException('Pay Component is inactive or belongs to another company.');
            if (a.Amount__c==null || a.Amount__c<0 || !String.isBlank(a.Formula_Parameter_JSON__c))
                throw new PayrollException('G10B supports non-negative fixed amounts only; formula evaluation is not enabled.');
            if (a.Currency__c!=run.Currency__c) throw new PayrollException('Compensation currency must match payroll currency.');
            if (a.Effective_From__c>starts || (a.Effective_To__c!=null && a.Effective_To__c<ends))
                throw new PayrollException('Partial-period compensation requires an approved proration policy.');
            String pair=String.valueOf(a.Employment__c)+':'+String.valueOf(a.Pay_Component__c);
            if (pairs.contains(pair)) throw new PayrollException('Overlapping approved compensation assignments were found.');
            pairs.add(pair); covered.add(a.Employment__c);
            Decimal amount=SABMoneyService.roundForMinorUnits(a.Amount__c,minorUnits,RoundingMode.HALF_UP);
            String category=a.Pay_Component__r.Category__c;
            Payroll_Line__c line=lines.get(a.Employment__c);
            if (category=='Deduction') line.Deduction_Amount__c+=amount;
            else if (category=='Employer Contribution') line.Employer_Contribution__c+=amount;
            else if (new Set<String>{'Basic Salary','Incentive','Food Allowance','Other'}.contains(category)) line.Gross_Amount__c+=amount;
            else throw new PayrollException('Unsupported compensation category.');
            details.add(new Payroll_Component_Line__c(Pay_Component__c=a.Pay_Component__c,Amount__c=amount,
                Component_Category__c=category,Expense_Account__c=a.Pay_Component__r.Expense_Account__c,
                Liability_Account__c=a.Pay_Component__r.Liability_Account__c,Rule_Version__c='G10B_FIXED_V1',
                Eligibility_Snapshot__c=JSON.serialize(new Map<String,Object>{'assignmentId'=>a.Id,
                    'periodStart'=>starts,'periodEnd'=>ends,'currency'=>run.Currency__c,'sourceAmount'=>a.Amount__c,
                    'minorUnits'=>minorUnits,'rounding'=>'HALF_UP','effectiveFrom'=>a.Effective_From__c,'effectiveTo'=>a.Effective_To__c})));
            detailEmployments.add(a.Employment__c);
        }
        if (covered.size()!=selected.size()) throw new PayrollException('Each selected employment needs approved compensation for this period.');
        // G10F: consume Approved awards (service started by period end, arrears included); fails closed on hidden awards.
        List<SABPayrollBenefitAwardService.EligibleAward> awards;
        try {
            awards=SABPayrollBenefitAwardService.eligibleAwards(run,selected,minorUnits,assignments.size());
        } catch (SABPayrollBenefitAwardService.BenefitAwardException ex) { throw new PayrollException(ex.getMessage()); }
        for (SABPayrollBenefitAwardService.EligibleAward a:awards) {
            Payroll_Line__c line=lines.get(a.employmentId);
            if (a.category=='Deduction') line.Deduction_Amount__c+=a.amount;
            else if (a.category=='Employer Contribution') line.Employer_Contribution__c+=a.amount;
            else line.Gross_Amount__c+=a.amount;
            details.add(new Payroll_Component_Line__c(Pay_Component__c=a.payComponentId,Benefit_Award__c=a.awardId,Amount__c=a.amount,
                Component_Category__c=a.category,Expense_Account__c=a.expenseAccountId,Liability_Account__c=a.liabilityAccountId,
                Rule_Version__c=SABPayrollBenefitAwardService.RULE_VERSION,Eligibility_Snapshot__c=a.eligibilitySnapshot));
            detailEmployments.add(a.employmentId);
        }
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
}
