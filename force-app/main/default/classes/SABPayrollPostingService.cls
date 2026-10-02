/** G10D: approved payroll accrual through the existing accounting event / journal pipeline. */
public with sharing class SABPayrollPostingService {
    public class PayrollPostingException extends Exception {}
    private static Id permittedRunId;
    public static Boolean permitsWorkflowWrite(SObject row){
        return permittedRunId!=null && row.getSObjectType()==Payroll_Run__c.SObjectType && (Id)row.get('Id')==permittedRunId;
    }
    public class PostingResult {
        @AuraEnabled public Id payrollRunId;
        @AuraEnabled public Id accountingEventId;
        @AuraEnabled public Id journalEntryId;
        @AuraEnabled public Boolean replay;
    }
    @AuraEnabled
    public static PostingResult post(Id runId,Id periodId,Date accountingDate,Id payableAccountId,String requestKey){
        if(runId==null || periodId==null || accountingDate==null || payableAccountId==null || String.isBlank(requestKey))
            throw new PayrollPostingException('Run, accounting period, accounting date, net payable account and request key are required.');
        if(requestKey.trim().length()>Payroll_Run__c.Posting_Request_Key__c.getDescribe().getLength())
            throw new PayrollPostingException('Posting request key exceeds its supported length.');
        SABPermissionService.assertPermission('SAB_Post_Payroll','Payroll posting permission is required.');
        SABPermissionService.assertPermission('SAB_Post_Journal','Journal posting permission is required.');
        SABPermissionService.assertPermission('SAB_View_Payroll_Detail','Payroll detail permission is required.');
        List<Payroll_Run__c> visible=[SELECT Id,Company__c FROM Payroll_Run__c WHERE Id=:runId WITH USER_MODE];
        if(visible.isEmpty())throw new PayrollPostingException('Payroll Run not found or not accessible.');
        Id companyId=visible[0].Company__c;
        SABCompanyAccessService.assertCompanyAccess(companyId);
        SABAccessControlService.assertRecordReadAccess(companyId);
        SABAccessControlService.assertRecordEditAccess(runId);
        List<Accounting_Company__c> companies=[SELECT Id,Is_Active__c,Functional_Currency__c FROM Accounting_Company__c WHERE Id=:companyId WITH USER_MODE FOR UPDATE];
        List<Payroll_Run__c> runs=Database.queryWithBinds(
            'SELECT Id,Company__c,Workflow_State__c,Currency__c,Version__c,Run_Key__c,Net_Total__c,Accounting_Event__c,Accounting_Date__c,'
            +' Approved_By__c,Approved_At__c,Net_Payable_Account__c,Posted_By__c,Posted_At__c,Posting_Request_Key__c'
            +' FROM Payroll_Run__c WHERE Id=:runId FOR UPDATE',new Map<String,Object>{'runId'=>runId},AccessLevel.USER_MODE);
        if(runs.isEmpty())throw new PayrollPostingException('Payroll Run not found or not accessible.');
        Payroll_Run__c run=runs[0];
        if(run.Company__c!=companyId)throw new PayrollPostingException('Payroll company changed; retry posting.');
        if(run.Workflow_State__c=='Posted')return postedReplay(run,periodId,accountingDate,payableAccountId);
        if(run.Workflow_State__c!='Approved' || run.Accounting_Event__c!=null)
            throw new PayrollPostingException('Only an unposted Approved payroll run can be posted.');
        if(run.Approved_By__c==null || run.Approved_At__c==null)
            throw new PayrollPostingException('Payroll approval audit information is required.');
        if(companies.isEmpty() || companies[0].Is_Active__c!=true)
            throw new PayrollPostingException('Payroll company must be active.');
        String payrollCurrencyCode=SABMoneyService.normalizeCurrencyCode(run.Currency__c);
        if(payrollCurrencyCode!=SABMoneyService.normalizeCurrencyCode(companies[0].Functional_Currency__c))
            throw new PayrollPostingException('G10D posting requires payroll currency to equal company functional currency.');
        String key=eventKey(run);
        List<Accounting_Period__c> periods=[SELECT Id,Company__c,Start_Date__c,End_Date__c,Status__c FROM Accounting_Period__c WHERE Id=:periodId WITH USER_MODE FOR UPDATE];
        if(periods.isEmpty() || periods[0].Company__c!=companyId || periods[0].Status__c!='Open'
            || accountingDate<periods[0].Start_Date__c || accountingDate>periods[0].End_Date__c)
            throw new PayrollPostingException('Accounting date must fall inside an accessible Open period for the payroll company.');
        SABPayrollReviewService.assertReconciled(runId);
        List<Payroll_Component_Line__c> details=[SELECT Id,Amount__c,Component_Category__c,Expense_Account__c,Liability_Account__c,
            Payroll_Line__r.Department_Snapshot__c,Payroll_Line__r.Cost_Center_Snapshot__c
            FROM Payroll_Component_Line__c WHERE Payroll_Line__r.Payroll_Run__c=:runId WITH USER_MODE ORDER BY Id LIMIT 1001];
        List<Journal_Entry_Line__c> lines=buildLines(run,details,payableAccountId);
        List<Journal_Entry_Line__c> accountChecks=new List<Journal_Entry_Line__c>();accountChecks.addAll(lines);
        accountChecks.add(new Journal_Entry_Line__c(GL_Account__c=payableAccountId,Debit_Base__c=0,Credit_Base__c=1));
        validateAccounts(companyId,accountChecks);
        Savepoint sp=Database.setSavepoint();
        try{
            Journal_Entry__c journal=new Journal_Entry__c(Company__c=companyId,Accounting_Period__c=periodId,
                Accounting_Date__c=accountingDate,Entry_Type__c='Subledger',Status__c='Draft',Version__c=1,
                Description__c='Payroll accrual '+String.valueOf(run.Id));
            insert as user journal;
            Integer numberValue=1;
            for(Journal_Entry_Line__c line:lines){
                line.Journal_Entry__c=journal.Id;line.Line_Number__c=numberValue;
                line.Transaction_Currency__c=payrollCurrencyCode;line.Functional_Currency__c=payrollCurrencyCode;
                line.Applied_Exchange_Rate__c=1;line.Rate_Date__c=accountingDate;line.Rate_Source__c='Payroll Snapshot';
                line.Source_Line_Key__c=key+'|'+numberValue;line.Explanation__c='Approved payroll snapshot';numberValue++;
            }
            insert as user lines;
            SABAccountingEventService.ReservationRequest eventRequest=new SABAccountingEventService.ReservationRequest();
            eventRequest.companyId=companyId;eventRequest.adapterKey='PAYROLL_ACCRUAL';eventRequest.requestKey=requestKey.trim();
            eventRequest.eventKey=key;eventRequest.eventType='Payroll';eventRequest.sourceBusinessKey=run.Run_Key__c;
            eventRequest.sourceRecordId=String.valueOf(runId);eventRequest.sourceType='Payroll_Run__c';eventRequest.sourceVersion=run.Version__c.intValue();
            SABPostingService.PostingRequest posting=new SABPostingService.PostingRequest();
            posting.journalEntryId=journal.Id;posting.postingKey=key;posting.eventRequest=eventRequest;
            SABPostingService.PostingResult posted=SABPostingService.postDraftJournal(posting);
            Payroll_Run__c change=new Payroll_Run__c(Id=runId,Workflow_State__c='Posted',Accounting_Event__c=posted.accountingEventId,
                Accounting_Date__c=accountingDate,Net_Payable_Account__c=payableAccountId,
                Posted_By__c=UserInfo.getUserId(),Posted_At__c=posted.postedAt,Posting_Request_Key__c=requestKey.trim());
            permittedRunId=runId;
            try{update as user change;}finally{permittedRunId=null;}
            return result(runId,posted.accountingEventId,posted.journalEntryId,false);
        }catch(Exception ex){Database.rollback(sp);throw ex;}
    }
    private static String eventKey(Payroll_Run__c run){
        if(run.Version__c==null || run.Version__c<=0 || run.Version__c!=run.Version__c.setScale(0))
            throw new PayrollPostingException('Payroll version must be a positive integer.');
        return 'PAYROLL|'+run.Id+'|V'+run.Version__c.intValue()+'|ACCRUAL';
    }
    private static PostingResult result(Id runId,Id eventId,Id journalId,Boolean replay){
        PostingResult r=new PostingResult();r.payrollRunId=runId;r.accountingEventId=eventId;r.journalEntryId=journalId;r.replay=replay;return r;
    }
    private static PostingResult postedReplay(Payroll_Run__c run,Id periodId,Date accountingDate,Id accountId){
        if(run.Accounting_Event__c==null || run.Posted_By__c==null || run.Posted_At__c==null
            || run.Accounting_Date__c!=accountingDate || run.Net_Payable_Account__c!=accountId)
            throw new PayrollPostingException('Posted payroll does not match the requested posting identity.');
        Id eventId=run.Accounting_Event__c;
        List<Accounting_Event__c> events=[SELECT Id,Company__c,Adapter_Key__c,Event_Key__c,State__c,Source_Type__c,Source_Record_Id__c,Source_Version__c,
            Journal_Entry__c,Journal_Entry__r.Company__c,Journal_Entry__r.Status__c,Journal_Entry__r.Accounting_Event__c,
            Journal_Entry__r.Posting_Key__c,Journal_Entry__r.Accounting_Period__c,Journal_Entry__r.Accounting_Date__c
            FROM Accounting_Event__c WHERE Id=:eventId WITH USER_MODE];
        if(events.isEmpty())throw new PayrollPostingException('Posted payroll accounting event is not accessible.');
        Accounting_Event__c e=events[0];String key=eventKey(run);
        if(e.Company__c!=run.Company__c || e.Adapter_Key__c!='PAYROLL_ACCRUAL' || e.Event_Key__c!=key || e.State__c!='Posted'
            || e.Source_Type__c!='Payroll_Run__c' || e.Source_Record_Id__c!=String.valueOf(run.Id) || e.Source_Version__c!=run.Version__c
            || e.Journal_Entry__c==null || e.Journal_Entry__r.Company__c!=run.Company__c || e.Journal_Entry__r.Status__c!='Posted'
            || e.Journal_Entry__r.Accounting_Event__c!=e.Id || e.Journal_Entry__r.Posting_Key__c!=key
            || e.Journal_Entry__r.Accounting_Period__c!=periodId || e.Journal_Entry__r.Accounting_Date__c!=accountingDate)
            throw new PayrollPostingException('Posted payroll accounting event or journal identity is inconsistent.');
        return result(run.Id,e.Id,e.Journal_Entry__c,true);
    }
    @TestVisible
    private static List<Journal_Entry_Line__c> buildLines(Payroll_Run__c run,List<Payroll_Component_Line__c> details,Id payableId){
        if(details.isEmpty() || details.size()>1000)throw new PayrollPostingException('Payroll posting requires 1 to 1000 visible component snapshots.');
        Map<String,Journal_Entry_Line__c> groups=new Map<String,Journal_Entry_Line__c>();
        Decimal debits=0;Decimal credits=0;
        for(Payroll_Component_Line__c d:details){
            Decimal amount=d.Amount__c;
            if(amount==null || amount<0 || amount!=amount.setScale(Journal_Entry_Line__c.Debit_Base__c.getDescribe().getScale()))
                throw new PayrollPostingException('Component amount is invalid or exceeds ledger precision.');
            if(amount==0)continue;
            Id department=d.Payroll_Line__r.Department_Snapshot__c;Id center=d.Payroll_Line__r.Cost_Center_Snapshot__c;
            if(d.Component_Category__c=='Deduction'){
                accumulate(groups,d.Liability_Account__c,department,center,amount,false);credits+=amount;
            }else if(d.Component_Category__c=='Employer Contribution'){
                accumulate(groups,d.Expense_Account__c,department,center,amount,true);debits+=amount;
                accumulate(groups,d.Liability_Account__c,department,center,amount,false);credits+=amount;
            }else if(new Set<String>{'Basic Salary','Food Allowance','Incentive','Other'}.contains(d.Component_Category__c)){
                accumulate(groups,d.Expense_Account__c,department,center,amount,true);debits+=amount;
            }else throw new PayrollPostingException('Unsupported payroll component category.');
        }
        if(run.Net_Total__c==null || run.Net_Total__c<0)throw new PayrollPostingException('Payroll net total is invalid.');
        if(run.Net_Total__c>0){accumulate(groups,payableId,null,null,run.Net_Total__c,false);credits+=run.Net_Total__c;}
        if(debits==0 || debits!=credits)throw new PayrollPostingException('Payroll posting must produce nonzero balanced debit and credit totals.');
        if(groups.size()<2 || groups.size()>200)throw new PayrollPostingException('Payroll posting must produce 2 to 200 aggregated journal lines.');
        List<String> keys=new List<String>(groups.keySet());keys.sort();List<Journal_Entry_Line__c> lines=new List<Journal_Entry_Line__c>();
        for(String key:keys)lines.add(groups.get(key));return lines;
    }
    private static void accumulate(Map<String,Journal_Entry_Line__c> groups,Id account,Id department,Id center,Decimal amount,Boolean debit){
        if(account==null)throw new PayrollPostingException('Nonzero payroll components require snapshotted expense or liability accounts.');
        String key=String.valueOf(account)+'|'+String.valueOf(department)+'|'+String.valueOf(center)+'|'+debit;
        if(!groups.containsKey(key))groups.put(key,new Journal_Entry_Line__c(GL_Account__c=account,Department__c=department,Cost_Center__c=center,Debit_Base__c=0,Credit_Base__c=0,Transaction_Amount__c=0));
        Journal_Entry_Line__c line=groups.get(key);if(debit)line.Debit_Base__c+=amount;else line.Credit_Base__c+=amount;line.Transaction_Amount__c+=amount;
    }
    @TestVisible
    private static void validateAccounts(Id companyId,List<Journal_Entry_Line__c> lines){
        Set<Id> ids=new Set<Id>();for(Journal_Entry_Line__c l:lines)ids.add(l.GL_Account__c);
        Map<Id,GL_Account__c> accounts=new Map<Id,GL_Account__c>([SELECT Id,Company__c,Is_Active__c,Account_Type__c FROM GL_Account__c WHERE Id IN :ids WITH USER_MODE]);
        for(Journal_Entry_Line__c l:lines){
            GL_Account__c a=accounts.get(l.GL_Account__c);
            if(a==null || a.Company__c!=companyId || !a.Is_Active__c || a.Account_Type__c!=(l.Debit_Base__c>0?'Expense':'Liability'))
                throw new PayrollPostingException('Payroll accounts must be accessible, active, same-company Expense debit or Liability credit accounts.');
        }
    }
}
