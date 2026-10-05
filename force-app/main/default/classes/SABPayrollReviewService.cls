/** G10C: reconcile snapshots and control review/approval/cancellation. G10F: cancellation releases consumed benefit awards. No GL posting. */
public with sharing class SABPayrollReviewService {
    public class ReviewException extends Exception {}
    private static Id permittedRunId;
    // Used only by the existing guard. There is no public setter or generic write method.
    public static Boolean permitsWorkflowWrite(SObject row) {
        return permittedRunId!=null && row.getSObjectType()==Payroll_Run__c.SObjectType
            && (Id)row.get('Id')==permittedRunId;
    }
    @AuraEnabled
    public static Id submit(Id runId) { return transition(runId,'Submit',null); }
    @AuraEnabled
    public static Id approve(Id runId) { return transition(runId,'Approve',null); }
    @AuraEnabled
    public static Id cancel(Id runId,String reason) { return transition(runId,'Cancel',reason); }

    private static Id transition(Id runId,String action,String reason) {
        if(runId==null) throw new ReviewException('Payroll Run is required.');
        SABPermissionService.assertPermission('SAB_'+action+'_Payroll',action+' payroll permission is required.');
        SABPermissionService.assertPermission('SAB_View_Payroll_Detail','Payroll detail permission is required.');
        List<Payroll_Run__c> visible=[SELECT Id,Company__c FROM Payroll_Run__c WHERE Id=:runId WITH USER_MODE];
        if(visible.isEmpty()) throw new ReviewException('Payroll Run not found or not accessible.');
        Id companyId=visible[0].Company__c;
        SABCompanyAccessService.assertCompanyAccess(companyId);
        SABAccessControlService.assertRecordReadAccess(companyId);
        SABAccessControlService.assertRecordEditAccess(runId);
        List<Accounting_Company__c> locks=[SELECT Id FROM Accounting_Company__c WHERE Id=:companyId WITH USER_MODE FOR UPDATE];
        if(locks.isEmpty()) throw new ReviewException('Payroll company not found or not accessible.');
        List<Payroll_Run__c> locked=Database.queryWithBinds(
            'SELECT Id, Company__c, CreatedById, Workflow_State__c, Accounting_Event__c,'
            +' Gross_Total__c, Deduction_Total__c, Employer_Total__c, Net_Total__c,'
            +' Submitted_By__c, Submitted_At__c, Approved_By__c, Approved_At__c, Cancelled_By__c, Cancelled_At__c, Cancellation_Reason__c'
            +' FROM Payroll_Run__c WHERE Id = :runId FOR UPDATE',
            new Map<String,Object>{'runId'=>runId},AccessLevel.USER_MODE);
        if(locked.isEmpty()) throw new ReviewException('Payroll Run not found or not accessible.');
        Payroll_Run__c run=locked[0];
        validateTransition(run,action,reason,UserInfo.getUserId());
        if(action!='Cancel') reconcile(run);
        Payroll_Run__c change=new Payroll_Run__c(Id=runId);
        if(action=='Submit') {
            change.Workflow_State__c='Submitted';change.Submitted_By__c=UserInfo.getUserId();change.Submitted_At__c=System.now();
        } else if(action=='Approve') {
            change.Workflow_State__c='Approved';change.Approved_By__c=UserInfo.getUserId();change.Approved_At__c=System.now();
        } else {
            change.Workflow_State__c='Cancelled';change.Cancelled_By__c=UserInfo.getUserId();
            change.Cancelled_At__c=System.now();change.Cancellation_Reason__c=reason.trim();
        }
        Savepoint checkpoint=Database.setSavepoint();
        try {
            permittedRunId=runId;
            try {update as user change;} finally {permittedRunId=null;}
            // G10F: awards consumed by a cancelled run return to Approved for the next payroll.
            // A Draft run was never calculated, so it cannot hold awards: skip the lookup.
            if(action=='Cancel' && run.Workflow_State__c!='Draft') SABPayrollBenefitAwardService.releaseForRun(runId);
        } catch(Exception ex) {Database.rollback(checkpoint);throw ex;}
        return runId;
    }
    @TestVisible
    private static void validateTransition(Payroll_Run__c run,String action,String reason,Id actorId) {
        if(run.Accounting_Event__c!=null || run.Workflow_State__c=='Posted' || run.Workflow_State__c=='Settled')
            throw new ReviewException('Posted or accounting-linked payroll requires a controlled reversal, not review or cancellation.');
        if(action=='Submit' && run.Workflow_State__c!='Calculated')
            throw new ReviewException('Only Calculated payroll can be submitted.');
        if(action=='Approve') {
            if(run.Workflow_State__c!='Submitted') throw new ReviewException('Only Submitted payroll can be approved.');
            if(run.Submitted_By__c==null || run.Submitted_At__c==null) throw new ReviewException('Submission audit information is missing.');
            if(actorId==run.Submitted_By__c || actorId==run.CreatedById)
                throw new ReviewException('A different user must approve payroll; preparers and submitters cannot approve their own run.');
        }
        if(action=='Cancel') {
            if(!new Set<String>{'Draft','Calculated','Submitted','Approved'}.contains(run.Workflow_State__c))
                throw new ReviewException('Only unposted Draft, Calculated, Submitted or Approved payroll can be cancelled.');
            if(String.isBlank(reason) || reason.trim().length()>255)
                throw new ReviewException('Cancellation reason is required and must not exceed 255 characters.');
        }
    }
    // Authorized read-only reconciliation reused by G10D; no write scope is exposed.
    public static void assertReconciled(Id runId){
        SABPermissionService.assertPermission('SAB_View_Payroll_Detail','Payroll detail permission is required.');
        List<Payroll_Run__c> rows=[SELECT Id,Company__c,Gross_Total__c,Deduction_Total__c,Employer_Total__c,Net_Total__c
            FROM Payroll_Run__c WHERE Id=:runId WITH USER_MODE];
        if(rows.isEmpty())throw new ReviewException('Payroll Run not found or not accessible.');
        SABCompanyAccessService.assertCompanyAccess(rows[0].Company__c);
        SABAccessControlService.assertRecordReadAccess(runId);
        reconcile(rows[0]);
    }
    private static void reconcile(Payroll_Run__c run) {
        Id runId=run.Id;
        List<Payroll_Line__c> lines=[SELECT Id,Employment__c,Employment__r.Company__c,Gross_Amount__c,
            Deduction_Amount__c,Employer_Contribution__c,Net_Amount__c FROM Payroll_Line__c
            WHERE Payroll_Run__c=:runId WITH USER_MODE LIMIT 201];
        List<Payroll_Component_Line__c> details=[SELECT Id,Payroll_Line__c,Amount__c,Component_Category__c
            FROM Payroll_Component_Line__c WHERE Payroll_Line__r.Payroll_Run__c=:runId WITH USER_MODE LIMIT 1001];
        List<Integer> expected=new SnapshotCounts().forRun(runId);
        if(lines.size()!=expected[0] || details.size()!=expected[1])
            throw new ReviewException('Payroll detail visibility or volume is incomplete; review cannot omit rows.');
        validateTotals(run,lines,details);
    }
    // Count only, scoped to an already-authorized locked run. No hidden salary values are returned.
    private without sharing class SnapshotCounts {
        List<Integer> forRun(Id runId) {
            return new List<Integer>{
                [SELECT COUNT() FROM Payroll_Line__c WHERE Payroll_Run__c=:runId WITH SYSTEM_MODE],
                [SELECT COUNT() FROM Payroll_Component_Line__c WHERE Payroll_Line__r.Payroll_Run__c=:runId WITH SYSTEM_MODE]
            };
        }
    }
    private class Totals {Decimal gross=0;Decimal deductions=0;Decimal employer=0;Integer components=0;}
    @TestVisible
    private static void validateTotals(Payroll_Run__c run,List<Payroll_Line__c> lines,List<Payroll_Component_Line__c> details) {
        if(lines.isEmpty() || lines.size()>200 || details.isEmpty() || details.size()>1000)
            throw new ReviewException('Payroll must contain 1 to 200 employee lines and 1 to 1000 component lines.');
        Map<Id,Totals> amounts=new Map<Id,Totals>();Set<Id> employees=new Set<Id>();
        for(Payroll_Line__c line:lines) {
            if(line.Employment__c==null || line.Employment__r.Company__c!=run.Company__c || employees.contains(line.Employment__c))
                throw new ReviewException('Payroll employment is missing, duplicated or belongs to another company.');
            employees.add(line.Employment__c);amounts.put(line.Id,new Totals());
        }
        for(Payroll_Component_Line__c detail:details) {
            if(!amounts.containsKey(detail.Payroll_Line__c) || detail.Amount__c==null || detail.Amount__c<0)
                throw new ReviewException('Invalid payroll component parent or amount.');
            Totals t=amounts.get(detail.Payroll_Line__c);t.components++;
            if(detail.Component_Category__c=='Deduction')t.deductions+=detail.Amount__c;
            else if(detail.Component_Category__c=='Employer Contribution')t.employer+=detail.Amount__c;
            else if(new Set<String>{'Basic Salary','Food Allowance','Incentive','Other'}.contains(detail.Component_Category__c))t.gross+=detail.Amount__c;
            else throw new ReviewException('Unsupported payroll component category.');
        }
        Totals total=new Totals();Decimal net=0;
        for(Payroll_Line__c line:lines) {
            Totals t=amounts.get(line.Id);Decimal expectedNet=t.gross-t.deductions;
            if(t.components==0 || expectedNet<0 || line.Gross_Amount__c!=t.gross || line.Deduction_Amount__c!=t.deductions
                || line.Employer_Contribution__c!=t.employer || line.Net_Amount__c!=expectedNet)
                throw new ReviewException('Employee payroll totals do not reconcile to component snapshots.');
            total.gross+=t.gross;total.deductions+=t.deductions;total.employer+=t.employer;net+=expectedNet;
        }
        if(run.Gross_Total__c!=total.gross || run.Deduction_Total__c!=total.deductions
            || run.Employer_Total__c!=total.employer || run.Net_Total__c!=net)
            throw new ReviewException('Payroll Run totals do not reconcile to employee snapshots.');
    }
}
