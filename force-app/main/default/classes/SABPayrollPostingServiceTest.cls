@IsTest
private class SABPayrollPostingServiceTest {
    // Resolve fixtures in system mode; business-service calls still run in user mode.
    private static User maker(){return [SELECT Id FROM User WHERE LastName='SABG10DMaker' AND Alias='g10dmkr' WITH SYSTEM_MODE LIMIT 1];}
    private static User reviewer(){return [SELECT Id FROM User WHERE LastName='SABG10DReviewer' AND Alias='g10drev' WITH SYSTEM_MODE LIMIT 1];}
    private static User noGrantUser(){return [SELECT Id FROM User WHERE LastName='SABG10DNoGrant' AND Alias='g10dnog' WITH SYSTEM_MODE LIMIT 1];}
    private static void assign(Id userId,Set<String> names) {
        Set<Id> assigned=new Set<Id>();
        for(PermissionSetAssignment p:[SELECT PermissionSetId FROM PermissionSetAssignment WHERE AssigneeId=:userId WITH SYSTEM_MODE]) assigned.add(p.PermissionSetId);
        List<PermissionSet> permissions=[SELECT Id,Name FROM PermissionSet WHERE Name IN :names WITH SYSTEM_MODE];
        System.assertEquals(names.size(),permissions.size(),'Deploy the complete G10D manifest, including every permission set.');
        List<PermissionSetAssignment> additions=new List<PermissionSetAssignment>();
        for(PermissionSet p:permissions)
            if(!assigned.contains(p.Id)) additions.add(new PermissionSetAssignment(AssigneeId=userId,PermissionSetId=p.Id));
        if(!additions.isEmpty()) insert as system additions;
    }
    private static User fixtureUser(String lastName,String alias,String unique) {
        return new User(Username=alias+'.'+unique+'@example.invalid',Email=alias+'@example.invalid',LastName=lastName,
            Alias=alias,TimeZoneSidKey='Asia/Dhaka',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US',ProfileId=UserInfo.getProfileId());
    }
    private static void assertReviewPermissions(){
        for(String permission:new List<String>{'SAB_Submit_Payroll','SAB_Approve_Payroll','SAB_Cancel_Payroll','SAB_View_Payroll_Detail'})
            System.assert(FeatureManagement.checkPermission(permission),'Fixture user must have '+permission+' inside runAs.');
        System.assert(Payroll_Run__c.Submitted_By__c.getDescribe().isAccessible(),'Review permission set must grant audit-field read access.');
        System.assert(Payroll_Run__c.Submitted_By__c.getDescribe().isUpdateable(),'Review permission set must grant audit-field write access.');
    }
    @TestSetup static void setupData(){
        System.runAs(new User(Id=UserInfo.getUserId())) {
            String unique=UserInfo.getOrganizationId()+'.'+String.valueOf(System.now().getTime());
            User preparer=fixtureUser('SABG10DMaker','g10dmkr',unique);
            User approver=fixtureUser('SABG10DReviewer','g10drev',unique);
            User unauthorized=fixtureUser('SABG10DNoGrant','g10dnog',unique);
            insert as system new List<User>{preparer,approver,unauthorized};
            Set<String> sets=new Set<String>{'SAB_Payroll_Calculation_User','SAB_Payroll_Posting_User','SAB_Post_Payroll_Action','SAB_Post_Journal_Action','SAB_Payroll_Review_User','SAB_Submit_Payroll_Action','SAB_Approve_Payroll_Action','SAB_Cancel_Payroll_Action'};
            assign(preparer.Id,sets);assign(preparer.Id,sets);
            assign(approver.Id,new Set<String>{'SAB_Payroll_Review_User','SAB_Approve_Payroll_Action','SAB_Cancel_Payroll_Action'});
            assign(unauthorized.Id,new Set<String>{'SAB_Payroll_Posting_User','SAB_Post_Payroll_Action','SAB_Post_Journal_Action'});
            System.assertEquals(sets.size(),[SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId=:preparer.Id AND PermissionSet.Name IN :sets WITH SYSTEM_MODE],
                'Repeated assignment must not create duplicates.');
        }
        // runAs separates business fixture DML from setup DML and loads the assigned permissions.
        System.runAs(maker()) {
            Accounting_Company__c company=new Accounting_Company__c(Name__c='Payroll Test',Company_Key__c='D01',
                Country_Code__c='BD',Functional_Currency__c='BDT',Fiscal_Calendar_Type__c='Calendar',
                Fiscal_Year_Start_Month__c=1,Setup_Status__c='Active',Is_Active__c=true);
            insert as system company;
            insert as system new List<Company_User_Access__c>{
                new Company_User_Access__c(Company__c=company.Id,User__c=UserInfo.getUserId(),Role__c='HR',
                    Is_Active__c=true,Effective_From__c=Date.today().addDays(-1),Grant_Key__c='G10D-GRANT'),
                new Company_User_Access__c(Company__c=company.Id,User__c=reviewer().Id,Role__c='HR',
                    Is_Active__c=true,Effective_From__c=Date.today().addDays(-1),Grant_Key__c='G10D-REVIEW-GRANT')
            };
            GL_Account__c expense=makeGL(company.Id,'6100','Payroll Expense','Expense','Debit');
            GL_Account__c deduction=makeGL(company.Id,'2100','Deduction Liability','Liability','Credit');
            GL_Account__c employer=makeGL(company.Id,'2200','Employer Liability','Liability','Credit');
            makeGL(company.Id,'2300','Salary Payable','Liability','Credit');
            insert as system new List<Accounting_Period__c>{
                new Accounting_Period__c(Company__c=company.Id,Company_Period_Key__c='D01-OCT',Period_Key__c='2026-10',Start_Date__c=Date.newInstance(2026,10,1),End_Date__c=Date.newInstance(2026,10,31),Fiscal_Year__c=2026,Fiscal_Quarter__c=4,Period_Number__c=10,Status__c='Open'),
                new Accounting_Period__c(Company__c=company.Id,Company_Period_Key__c='D01-NOV',Period_Key__c='2026-11',Start_Date__c=Date.newInstance(2026,11,1),End_Date__c=Date.newInstance(2026,11,30),Fiscal_Year__c=2026,Fiscal_Quarter__c=4,Period_Number__c=11,Status__c='Closed',Closed_At__c=System.now(),Closed_By__c=UserInfo.getUserId())
            };
            Employee__c employee=new Employee__c(Employee_Reference__c='G10D-EMP',Status__c='Active');insert as system employee;
            Employment__c employment=new Employment__c(Employee__c=employee.Id,Company__c=company.Id,
                Start_Date__c=Date.newInstance(2026,1,1),Employment_Status__c='Active');insert as system employment;
            List<Pay_Component__c> components=new List<Pay_Component__c>();
            for(String category:new List<String>{'Basic Salary','Food Allowance','Deduction','Employer Contribution'}) {
                components.add(new Pay_Component__c(Name=category,Company__c=company.Id,Component_Key__c='G10D-'+category,
                    Category__c=category,Is_Active__c=true,Expense_Account__c=category=='Deduction'?null:expense.Id,Liability_Account__c=category=='Deduction'?deduction.Id:(category=='Employer Contribution'?employer.Id:null)));
            }
            insert as system components;
            List<Employee_Pay_Component__c> assignments=new List<Employee_Pay_Component__c>();
            List<Decimal> amounts=new List<Decimal>{10000,500,1000,250};
            for(Integer i=0;i<components.size();i++) assignments.add(new Employee_Pay_Component__c(
                Employment__c=employment.Id,Pay_Component__c=components[i].Id,Amount__c=amounts[i],Currency__c='BDT',
                Effective_From__c=Date.newInstance(2026,1,1),Status__c='Approved'));
            insert as system assignments;
        }
    }
    private static Id companyId(){return [SELECT Id FROM Accounting_Company__c WHERE Company_Key__c='D01' WITH USER_MODE].Id;}
    private static Id employmentId(){return [SELECT Id FROM Employment__c WITH USER_MODE LIMIT 1].Id;}
    private static Id draft(String key){return SABPayrollCalculationService.createDraft(companyId(),Date.newInstance(2026,10,1),Date.newInstance(2026,10,31),'BDT',key);}
    private static Id calculated(){
        Id runId=draft('G10D-RUN');
        SABPayrollCalculationService.calculate(runId,new List<Id>{employmentId()},2);return runId;
    }
    private static void allowRunEdit(Id runId,Id userId){
        List<UserRecordAccess> access=[SELECT RecordId,HasEditAccess FROM UserRecordAccess WHERE UserId=:userId AND RecordId=:runId WITH SYSTEM_MODE];
        if(access.isEmpty() || !access[0].HasEditAccess)
            insert as system new Payroll_Run__Share(ParentId=runId,UserOrGroupId=userId,AccessLevel='Edit',RowCause=Schema.Payroll_Run__Share.RowCause.Manual);
    }
    private static void allowReviewerEdit(Id runId){allowRunEdit(runId,reviewer().Id);}
    private static Payroll_Run__c snapshot(Id runId){
        return [SELECT Id,Company__c,CreatedById,Workflow_State__c,Accounting_Event__c,Gross_Total__c,Deduction_Total__c,
            Employer_Total__c,Net_Total__c,Submitted_By__c,Submitted_At__c,Approved_By__c,Approved_At__c,
            Cancelled_By__c,Cancelled_At__c,Cancellation_Reason__c FROM Payroll_Run__c WHERE Id=:runId WITH USER_MODE];
    }
    private static GL_Account__c makeGL(Id companyId,String code,String label,String type,String balance){
        GL_Account__c a=new GL_Account__c(Name=label,Company__c=companyId,Company_Account_Key__c=String.valueOf(companyId)+'-'+code,
            Account_Code__c=code,Account_Type__c=type,Normal_Balance__c=balance,Is_Active__c=true,
            Is_Control_Account__c=false,Control_Type__c='None',Manual_Posting_Allowed__c=true);
        insert as system a;return a;
    }
    private static Id account(String code){return [SELECT Id FROM GL_Account__c WHERE Account_Code__c=:code WITH USER_MODE LIMIT 1].Id;}
    private static Id period(String key){return [SELECT Id FROM Accounting_Period__c WHERE Company_Period_Key__c=:key WITH USER_MODE].Id;}
    private static Id approved(){
        Id runId=calculated();allowReviewerEdit(runId);SABPayrollReviewService.submit(runId);
        System.runAs(reviewer()){SABPayrollReviewService.approve(runId);}return runId;
    }
    private static SABPayrollPostingService.PostingResult post(Id runId){
        return SABPayrollPostingService.post(runId,period('D01-OCT'),Date.newInstance(2026,10,31),account('2300'),'G10D-POST');
    }
    private static void rejects(Id runId,Id periodId,Date dateValue,Id payable,String expected){
        Boolean rejected=false;
        try{SABPayrollPostingService.post(runId,periodId,dateValue,payable,'G10D-REJECT');}
        catch(SABPayrollPostingService.PayrollPostingException ex){rejected=true;System.assert(ex.getMessage().contains(expected),ex.getMessage());}
        System.assert(rejected,'Expected posting rejection: '+expected);
    }
    @IsTest static void postsBalancedPayrollAndReplays(){
        System.runAs(maker()){
            assertReviewPermissions();Id runId=approved();Test.startTest();
            SABPayrollPostingService.PostingResult r=post(runId);SABPayrollPostingService.PostingResult replay=post(runId);
            // Budget: the cancel attempt runs inside this window; the outer window already holds setup plus calculate/submit/approve.
            Database.SaveResult direct=Database.update(new Payroll_Run__c(Id=runId,Workflow_State__c='Approved'),false);
            Boolean cancelled=false;String cancelMessage;
            try{SABPayrollReviewService.cancel(runId,'Cannot cancel posted');}
            catch(SABPayrollReviewService.ReviewException ex){cancelled=true;cancelMessage=ex.getMessage();}
            Test.stopTest();
            System.assertEquals(false,r.replay);System.assertEquals(true,replay.replay);
            System.assertEquals(r.journalEntryId,replay.journalEntryId);System.assertEquals(r.accountingEventId,replay.accountingEventId);
            Payroll_Run__c run=[SELECT Workflow_State__c,Accounting_Event__c,Accounting_Date__c,Posted_By__c,Posted_At__c,Net_Payable_Account__c,Posting_Request_Key__c
                FROM Payroll_Run__c WHERE Id=:runId WITH USER_MODE];
            System.assertEquals('Posted',run.Workflow_State__c);System.assertEquals(r.accountingEventId,run.Accounting_Event__c);
            System.assertEquals(UserInfo.getUserId(),run.Posted_By__c);System.assertNotEquals(null,run.Posted_At__c);
            System.assertEquals('G10D-POST',run.Posting_Request_Key__c);System.assertEquals(account('2300'),run.Net_Payable_Account__c);
            Journal_Entry__c journal=[SELECT Status__c,Entry_Type__c,Accounting_Event__c FROM Journal_Entry__c WHERE Id=:r.journalEntryId WITH USER_MODE];
            System.assertEquals('Posted',journal.Status__c);System.assertEquals('Subledger',journal.Entry_Type__c);
            List<Journal_Entry_Line__c> lines=[SELECT GL_Account__r.Account_Code__c,Debit_Base__c,Credit_Base__c,Applied_Exchange_Rate__c,Rate_Source__c
                FROM Journal_Entry_Line__c WHERE Journal_Entry__c=:journal.Id WITH USER_MODE];
            System.assertEquals(4,lines.size());Decimal debit=0;Decimal credit=0;Map<String,Decimal> credits=new Map<String,Decimal>();
            for(Journal_Entry_Line__c l:lines){debit+=l.Debit_Base__c;credit+=l.Credit_Base__c;credits.put(l.GL_Account__r.Account_Code__c,l.Credit_Base__c);System.assertEquals(1,l.Applied_Exchange_Rate__c);}
            System.assertEquals(10750,debit);System.assertEquals(debit,credit);System.assertEquals(9500,credits.get('2300'));
            System.assertEquals(1000,credits.get('2100'));System.assertEquals(250,credits.get('2200'));
            System.assertEquals(1,[SELECT COUNT() FROM Accounting_Event__c WHERE Source_Record_Id__c=:runId WITH USER_MODE]);
            System.assertEquals(false,direct.isSuccess());System.assert(direct.getErrors()[0].getMessage().contains('authorized payroll service'));
            System.assert(cancelled,'Posted payroll cannot be cancelled.');System.assert(cancelMessage.contains('controlled reversal'),cancelMessage);
        }
    }
    @IsTest static void rejectsReplayWithChangedIdentity(){
        System.runAs(maker()){
            Id runId=approved();Id p=period('D01-OCT');Id payable=account('2300');Test.startTest();post(runId);
            rejects(runId,p,Date.newInstance(2026,10,30),payable,'posting identity');
            rejects(runId,p,Date.newInstance(2026,10,31),account('2100'),'posting identity');
            rejects(runId,period('D01-NOV'),Date.newInstance(2026,10,31),payable,'inconsistent');Test.stopTest();
            System.assertEquals(1,[SELECT COUNT() FROM Accounting_Event__c WHERE Source_Record_Id__c=:runId WITH USER_MODE]);
        }
    }
    @IsTest static void requiresApprovedState(){
        System.runAs(maker()){
            Id runId=draft('DRAFT-REJECT');Id p=period('D01-OCT');Id a=account('2300');Test.startTest();
            rejects(runId,p,Date.newInstance(2026,10,31),a,'Approved');
            SABPayrollCalculationService.calculate(runId,new List<Id>{employmentId()},2);
            rejects(runId,p,Date.newInstance(2026,10,31),a,'Approved');Test.stopTest();
            System.assertEquals(0,[SELECT COUNT() FROM Accounting_Event__c WHERE Source_Record_Id__c=:runId WITH USER_MODE]);
        }
    }
    @IsTest static void rejectsInvalidPeriodAndInput(){
        System.runAs(maker()){
            Id runId=approved();Id p=period('D01-OCT');Id a=account('2300');Test.startTest();
            rejects(null,p,Date.newInstance(2026,10,31),a,'required');
            rejects(runId,p,Date.newInstance(2026,9,30),a,'Open period');
            rejects(runId,period('D01-NOV'),Date.newInstance(2026,11,15),a,'Open period');
            Boolean longKey=false;String key='';for(Integer i=0;i<101;i++)key+='x';
            try{SABPayrollPostingService.post(runId,p,Date.newInstance(2026,10,31),a,key);}
            catch(SABPayrollPostingService.PayrollPostingException ex){longKey=true;System.assert(ex.getMessage().contains('length'));}
            System.assert(longKey);Test.stopTest();System.assertEquals('Approved',snapshot(runId).Workflow_State__c);
        }
    }
    @IsTest static void rejectsExpenseAsPayable(){
        System.runAs(maker()){
            Id runId=approved();Test.startTest();rejects(runId,period('D01-OCT'),Date.newInstance(2026,10,31),account('6100'),'accounts');Test.stopTest();
            System.assertEquals('Approved',snapshot(runId).Workflow_State__c);
            System.assertEquals(0,[SELECT COUNT() FROM Accounting_Event__c WHERE Source_Record_Id__c=:runId WITH USER_MODE]);
        }
    }
    @IsTest static void deniesUserWithoutCompanyGrant(){
        System.runAs(maker()){
            Id runId=approved();User denied=noGrantUser();allowRunEdit(runId,denied.Id);Id p=period('D01-OCT');Id a=account('2300');Test.startTest();
            Boolean blocked=false;System.runAs(denied){
                System.assert(FeatureManagement.checkPermission('SAB_Post_Payroll'));
                try{SABPayrollPostingService.post(runId,p,Date.newInstance(2026,10,31),a,'DENIED');}
                catch(SABCompanyAccessService.CompanyAccessDeniedException ex){blocked=true;}
            }Test.stopTest();System.assert(blocked);System.assertEquals('Approved',snapshot(runId).Workflow_State__c);
        }
    }
    @IsTest static void requiresPostingActionPermission(){
        System.runAs(maker()){
            Id runId=approved();User u=reviewer();Id p=period('D01-OCT');Id a=account('2300');Test.startTest();Boolean blocked=false;
            System.runAs(u){
                System.assertEquals(false,FeatureManagement.checkPermission('SAB_Post_Payroll'));
                try{SABPayrollPostingService.post(runId,p,Date.newInstance(2026,10,31),a,'NO-ACTION');}
                catch(SABPermissionService.PermissionDeniedException ex){blocked=true;System.assert(ex.getMessage().contains('Payroll posting'));}
            }Test.stopTest();System.assert(blocked);
        }
    }
    @IsTest static void rejectsForeignCurrency(){
        System.runAs(maker()){
            List<Employee_Pay_Component__c> rows=[SELECT Id,Currency__c FROM Employee_Pay_Component__c WITH SYSTEM_MODE];
            for(Employee_Pay_Component__c r:rows)r.Currency__c='USD';update as system rows;
            Id runId=SABPayrollCalculationService.createDraft(companyId(),Date.newInstance(2026,10,1),Date.newInstance(2026,10,31),'USD','FX');
            SABPayrollCalculationService.calculate(runId,new List<Id>{employmentId()},2);allowReviewerEdit(runId);SABPayrollReviewService.submit(runId);
            System.runAs(reviewer()){SABPayrollReviewService.approve(runId);}
            Test.startTest();rejects(runId,period('D01-OCT'),Date.newInstance(2026,10,31),account('2300'),'functional currency');Test.stopTest();
        }
    }
    private static List<Payroll_Component_Line__c> components(Id runId){
        return [SELECT Id,Amount__c,Component_Category__c,Expense_Account__c,Liability_Account__c,
            Payroll_Line__r.Department_Snapshot__c,Payroll_Line__r.Cost_Center_Snapshot__c
            FROM Payroll_Component_Line__c WHERE Payroll_Line__r.Payroll_Run__c=:runId WITH USER_MODE];
    }
    private static void rejectBuild(Payroll_Run__c run,List<Payroll_Component_Line__c> details,Id payable,String message){
        Boolean rejected=false;try{SABPayrollPostingService.buildLines(run,details,payable);}
        catch(SABPayrollPostingService.PayrollPostingException ex){rejected=true;System.assert(ex.getMessage().contains(message),ex.getMessage());}
        System.assert(rejected,'Expected builder rejection: '+message);
    }
    @IsTest static void rejectsMissingSnapshotMappings(){
        System.runAs(maker()){
            Id id=calculated();Payroll_Run__c r=snapshot(id);List<Payroll_Component_Line__c> d=components(id);Id payable=account('2300');Test.startTest();
            for(Payroll_Component_Line__c c:d)if(c.Component_Category__c=='Basic Salary')c.Expense_Account__c=null;
            rejectBuild(r,d,payable,'snapshotted');Test.stopTest();
        }
    }
    @IsTest static void validatesAmountsCategoriesAndBalance(){
        System.runAs(maker()){
            Id id=calculated();Payroll_Run__c r=snapshot(id);List<Payroll_Component_Line__c> d=components(id);Id payable=account('2300');Test.startTest();
            Decimal original=d[0].Amount__c;String category=d[0].Component_Category__c;
            d[0].Amount__c=-1;rejectBuild(r,d,payable,'amount');d[0].Amount__c=null;rejectBuild(r,d,payable,'amount');
            d[0].Amount__c=original;d[0].Component_Category__c='Unsupported';rejectBuild(r,d,payable,'category');d[0].Component_Category__c=category;
            r.Net_Total__c=-1;rejectBuild(r,d,payable,'net total');r.Net_Total__c=1;rejectBuild(r,d,payable,'balanced');
            d.clear();rejectBuild(r,d,payable,'1 to 1000');Test.stopTest();
        }
    }
    @IsTest static void aggregatesAndSkipsZeroComponents(){
        System.runAs(maker()){
            Id id=calculated();Payroll_Run__c r=snapshot(id);List<Payroll_Component_Line__c> d=components(id);Id payable=account('2300');
            Payroll_Component_Line__c zero=d[0].clone(false,true,false,false);zero.Amount__c=0;d.add(zero);Test.startTest();
            List<Journal_Entry_Line__c> lines=SABPayrollPostingService.buildLines(r,d,payable);Test.stopTest();
            System.assertEquals(4,lines.size());Decimal debits=0;for(Journal_Entry_Line__c l:lines)debits+=l.Debit_Base__c;System.assertEquals(10750,debits);
        }
    }
    @IsTest static void handlesZeroNetAndRejectsAllZeroPayroll(){
        System.runAs(maker()){
            Id id=calculated();Payroll_Run__c r=snapshot(id);List<Payroll_Component_Line__c> d=components(id);Id payable=account('2300');
            for(Payroll_Component_Line__c c:d)if(c.Component_Category__c=='Deduction')c.Amount__c=10500;
            r.Net_Total__c=0;Test.startTest();List<Journal_Entry_Line__c> lines=SABPayrollPostingService.buildLines(r,d,payable);System.assertEquals(3,lines.size());
            for(Payroll_Component_Line__c c:d)c.Amount__c=0;rejectBuild(r,d,payable,'nonzero balanced');Test.stopTest();
        }
    }
    @IsTest static void rejectsCrossCompanyAccounts(){
        System.runAs(maker()){
            Id id=calculated();Payroll_Run__c r=snapshot(id);List<Journal_Entry_Line__c> lines=SABPayrollPostingService.buildLines(r,components(id),account('2300'));
            Id company=companyId();Test.startTest();Boolean denied=false;
            try{SABPayrollPostingService.validateAccounts(null,lines);}catch(SABPayrollPostingService.PayrollPostingException ex){denied=true;System.assert(ex.getMessage().contains('same-company'));}
            System.assert(denied);Test.stopTest();
        }
    }
    @IsTest static void rollsBackJournalWhenEventIdentityConflicts(){
        System.runAs(maker()){
            Id runId=approved();SABAccountingEventService.ReservationRequest reserved=new SABAccountingEventService.ReservationRequest();
            reserved.companyId=companyId();reserved.adapterKey='DIFFERENT_ADAPTER';reserved.requestKey='RESERVE';
            reserved.eventKey='PAYROLL|'+runId+'|V1|ACCRUAL';reserved.eventType='Payroll';reserved.sourceType='Payroll_Run__c';
            reserved.sourceRecordId=String.valueOf(runId);reserved.sourceVersion=1;reserved.sourceBusinessKey='DIFFERENT';
            SABAccountingEventService.reserveForPosting(reserved);
            Integer beforeCount=[SELECT COUNT() FROM Journal_Entry__c WITH USER_MODE];Test.startTest();Boolean blocked=false;
            try{post(runId);}catch(SABAccountingEventService.AccountingEventException ex){blocked=true;System.assert(ex.getMessage().contains('identity'));}
            Test.stopTest();System.assert(blocked);System.assertEquals(beforeCount,[SELECT COUNT() FROM Journal_Entry__c WITH USER_MODE]);
            Payroll_Run__c run=snapshot(runId);System.assertEquals('Approved',run.Workflow_State__c);System.assertEquals(null,run.Accounting_Event__c);
            System.assertEquals(1,[SELECT COUNT() FROM Accounting_Event__c WHERE Event_Key__c=:reserved.eventKey WITH USER_MODE]);
        }
    }

    @IsTest static void preservesDimensionsAndRejectsLedgerLineOverflow(){
        System.runAs(maker()){
            Id runId=calculated();Payroll_Run__c run=snapshot(runId);List<Payroll_Component_Line__c> details=components(runId);Id payable=account('2300');Id expense=account('6100');
            Id dimension=Department__c.SObjectType.getDescribe().getKeyPrefix()+'000000000001';
            for(Payroll_Component_Line__c d:details)if(d.Component_Category__c=='Food Allowance')d.putSObject('Payroll_Line__r',new Payroll_Line__c(Department_Snapshot__c=dimension,Cost_Center_Snapshot__c=null));
            Test.startTest();List<Journal_Entry_Line__c> lines=SABPayrollPostingService.buildLines(run,details,payable);
            Boolean preserved=false;for(Journal_Entry_Line__c l:lines)if(l.Department__c==dimension){preserved=true;System.assertEquals(500,l.Debit_Base__c);}
            System.assert(preserved);System.assertEquals(5,lines.size());
            List<Payroll_Component_Line__c> many=new List<Payroll_Component_Line__c>();
            for(Integer i=1;i<=201;i++){
                Payroll_Component_Line__c d=details[0].clone(false,true,false,false);d.Component_Category__c='Basic Salary';d.Amount__c=1;d.Expense_Account__c=expense;
                String indexText=String.valueOf(i);String zeros='000000000000';
                Id departmentId=Department__c.SObjectType.getDescribe().getKeyPrefix()+zeros.substring(indexText.length())+indexText;
                d.Payroll_Line__r.Department_Snapshot__c=departmentId;many.add(d);
            }
            run.Net_Total__c=201;rejectBuild(run,many,payable,'2 to 200');Test.stopTest();
        }
    }

}
