@IsTest
private class SABPayrollReviewServiceTest {
    // Resolve fixtures in system mode; business-service calls still run in user mode.
    private static User maker(){return [SELECT Id FROM User WHERE LastName='SABG10CMaker' AND Alias='g10cmkr' WITH SYSTEM_MODE LIMIT 1];}
    private static User reviewer(){return [SELECT Id FROM User WHERE LastName='SABG10CReviewer' AND Alias='g10crev' WITH SYSTEM_MODE LIMIT 1];}
    private static User noGrantUser(){return [SELECT Id FROM User WHERE LastName='SABG10CNoGrant' AND Alias='g10cnog' WITH SYSTEM_MODE LIMIT 1];}
    private static void assign(Id userId,Set<String> names) {
        Set<Id> assigned=new Set<Id>();
        for(PermissionSetAssignment p:[SELECT PermissionSetId FROM PermissionSetAssignment WHERE AssigneeId=:userId WITH SYSTEM_MODE]) assigned.add(p.PermissionSetId);
        List<PermissionSet> permissions=[SELECT Id,Name FROM PermissionSet WHERE Name IN :names WITH SYSTEM_MODE];
        System.assertEquals(names.size(),permissions.size(),'Deploy the complete G10C manifest, including every permission set.');
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
            User preparer=fixtureUser('SABG10CMaker','g10cmkr',unique);
            User approver=fixtureUser('SABG10CReviewer','g10crev',unique);
            User unauthorized=fixtureUser('SABG10CNoGrant','g10cnog',unique);
            insert as system new List<User>{preparer,approver,unauthorized};
            Set<String> sets=new Set<String>{'SAB_Payroll_Calculation_User','SAB_Payroll_Review_User','SAB_Submit_Payroll_Action','SAB_Approve_Payroll_Action','SAB_Cancel_Payroll_Action'};
            assign(preparer.Id,sets);assign(preparer.Id,sets);
            assign(approver.Id,new Set<String>{'SAB_Payroll_Review_User','SAB_Approve_Payroll_Action','SAB_Cancel_Payroll_Action'});
            assign(unauthorized.Id,new Set<String>{'SAB_Payroll_Review_User','SAB_Cancel_Payroll_Action'});
            System.assertEquals(sets.size(),[SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId=:preparer.Id AND PermissionSet.Name IN :sets WITH SYSTEM_MODE],
                'Repeated assignment must not create duplicates.');
        }
        // runAs separates business fixture DML from setup DML and loads the assigned permissions.
        System.runAs(maker()) {
            Accounting_Company__c company=new Accounting_Company__c(Name__c='Payroll Test',Company_Key__c='C01',
                Country_Code__c='BD',Functional_Currency__c='BDT',Fiscal_Calendar_Type__c='Calendar',
                Fiscal_Year_Start_Month__c=1,Setup_Status__c='Active',Is_Active__c=true);
            insert as system company;
            insert as system new List<Company_User_Access__c>{
                new Company_User_Access__c(Company__c=company.Id,User__c=UserInfo.getUserId(),Role__c='HR',
                    Is_Active__c=true,Effective_From__c=Date.today().addDays(-1),Grant_Key__c='G10C-GRANT'),
                new Company_User_Access__c(Company__c=company.Id,User__c=reviewer().Id,Role__c='HR',
                    Is_Active__c=true,Effective_From__c=Date.today().addDays(-1),Grant_Key__c='G10C-REVIEW-GRANT')
            };
            Employee__c employee=new Employee__c(Employee_Reference__c='G10C-EMP',Status__c='Active');insert as system employee;
            Employment__c employment=new Employment__c(Employee__c=employee.Id,Company__c=company.Id,
                Start_Date__c=Date.newInstance(2026,1,1),Employment_Status__c='Active');insert as system employment;
            List<Pay_Component__c> components=new List<Pay_Component__c>();
            for(String category:new List<String>{'Basic Salary','Food Allowance','Deduction','Employer Contribution'}) {
                components.add(new Pay_Component__c(Name=category,Company__c=company.Id,Component_Key__c='G10C-'+category,
                    Category__c=category,Is_Active__c=true));
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
    private static Id companyId(){return [SELECT Id FROM Accounting_Company__c WHERE Company_Key__c='C01' WITH USER_MODE].Id;}
    private static Id employmentId(){return [SELECT Id FROM Employment__c WITH USER_MODE LIMIT 1].Id;}
    private static Id draft(String key){return SABPayrollCalculationService.createDraft(companyId(),Date.newInstance(2026,10,1),Date.newInstance(2026,10,31),'BDT',key);}
    private static Id calculated(){
        Id runId=draft('G10C-RUN');
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
    private static void rejected(Id runId,String action,String reason,String expected){
        Boolean failed=false;
        try{
            if(action=='Submit')SABPayrollReviewService.submit(runId);
            else if(action=='Approve')SABPayrollReviewService.approve(runId);
            else SABPayrollReviewService.cancel(runId,reason);
        }catch(SABPayrollReviewService.ReviewException ex){failed=true;System.assert(ex.getMessage().contains(expected),ex.getMessage());}
        System.assert(failed,'Expected rejection: '+expected);
    }
    @IsTest static void submitsApprovesAndCancelsWithAudit(){
        System.runAs(maker()) {
            assertReviewPermissions();
            Id runId=calculated();allowReviewerEdit(runId);Id maker=UserInfo.getUserId();User approver=reviewer();
            Test.startTest();
            System.assertEquals(runId,SABPayrollReviewService.submit(runId));
            Payroll_Run__c submitted=snapshot(runId);
            System.assertEquals('Submitted',submitted.Workflow_State__c);System.assertEquals(maker,submitted.Submitted_By__c);
            System.assertNotEquals(null,submitted.Submitted_At__c);
            System.runAs(approver){System.assertEquals(runId,SABPayrollReviewService.approve(runId));}
            Payroll_Run__c approved=snapshot(runId);System.assertEquals('Approved',approved.Workflow_State__c);
            System.assertEquals(approver.Id,approved.Approved_By__c);System.assertNotEquals(null,approved.Approved_At__c);
            System.assertEquals(maker,approved.Submitted_By__c);
            SABPayrollReviewService.cancel(runId,'  Correct employee inputs  ');Test.stopTest();
            Payroll_Run__c cancelled=snapshot(runId);System.assertEquals('Cancelled',cancelled.Workflow_State__c);
            System.assertEquals('Correct employee inputs',cancelled.Cancellation_Reason__c);System.assertEquals(maker,cancelled.Cancelled_By__c);
            System.assertNotEquals(null,cancelled.Cancelled_At__c);System.assertEquals(approver.Id,cancelled.Approved_By__c);
            System.assertEquals(9500,cancelled.Net_Total__c);
            System.assertEquals(1,[SELECT COUNT() FROM Payroll_Line__c WHERE Payroll_Run__c=:runId]);
            System.assertEquals(4,[SELECT COUNT() FROM Payroll_Component_Line__c WHERE Payroll_Line__r.Payroll_Run__c=:runId]);
            Database.SaveResult writeResult=Database.update(new Payroll_Run__c(Id=runId,Net_Total__c=1),false);
            System.assertEquals(false,writeResult.isSuccess(),'Workflow write authority must be cleared after the service returns.');
            System.assert(writeResult.getErrors()[0].getMessage().contains('authorized payroll service'));
        }
    }
    @IsTest static void cancelsDraft(){
        System.runAs(maker()) {
            assertReviewPermissions();
            Id runId=draft('CANCELDRAFT');Test.startTest();SABPayrollReviewService.cancel(runId,'Not needed');Test.stopTest();
            System.assertEquals('Cancelled',snapshot(runId).Workflow_State__c);
            System.assertEquals(0,[SELECT COUNT() FROM Payroll_Line__c WHERE Payroll_Run__c=:runId]);
        }
    }
    @IsTest static void cancellationAllowsReplacement(){
        System.runAs(maker()) {
            assertReviewPermissions();
            Id original=calculated();Test.startTest();SABPayrollReviewService.cancel(original,'Wrong source data');
            Id replacement=draft('REPLACEMENT');SABPayrollCalculationService.calculate(replacement,new List<Id>{employmentId()},2);Test.stopTest();
            System.assertEquals('Cancelled',snapshot(original).Workflow_State__c);System.assertEquals('Calculated',snapshot(replacement).Workflow_State__c);
            System.assertEquals(1,[SELECT COUNT() FROM Payroll_Line__c WHERE Payroll_Run__c=:original]);
            System.assertEquals(1,[SELECT COUNT() FROM Payroll_Line__c WHERE Payroll_Run__c=:replacement]);
        }
    }
    @IsTest static void cancelsSubmitted(){
        System.runAs(maker()) {
            assertReviewPermissions();
            Id runId=calculated();Test.startTest();SABPayrollReviewService.submit(runId);SABPayrollReviewService.cancel(runId,'Correction');Test.stopTest();
            Payroll_Run__c run=snapshot(runId);System.assertEquals('Cancelled',run.Workflow_State__c);System.assertNotEquals(null,run.Submitted_At__c);
            System.assertEquals(null,run.Approved_By__c);
        }
    }
    @IsTest static void rejectsDraftSubmissionAndApproval(){
        System.runAs(maker()) {
            assertReviewPermissions();
            Id runId=draft('DRAFTONLY');Test.startTest();rejected(runId,'Submit',null,'Only Calculated');rejected(runId,'Approve',null,'Only Submitted');
            rejected(null,'Submit',null,'required');Test.stopTest();System.assertEquals('Draft',snapshot(runId).Workflow_State__c);
        }
    }
    @IsTest static void rejectsRepeatSubmissionAndSelfApproval(){
        System.runAs(maker()) {
            assertReviewPermissions();
            Id runId=calculated();Test.startTest();SABPayrollReviewService.submit(runId);
            rejected(runId,'Submit',null,'Only Calculated');rejected(runId,'Approve',null,'different user');Test.stopTest();
            System.assertEquals('Submitted',snapshot(runId).Workflow_State__c);System.assertEquals(null,snapshot(runId).Approved_At__c);
        }
    }
    @IsTest static void rejectsBadCancellationReasons(){
        System.runAs(maker()) {
            assertReviewPermissions();
            Id runId=draft('REASONS');String longReason='';for(Integer i=0;i<256;i++)longReason+='x';
            Test.startTest();rejected(runId,'Cancel',' ','reason');rejected(runId,'Cancel',longReason,'255');Test.stopTest();
            System.assertEquals('Draft',snapshot(runId).Workflow_State__c);System.assertEquals(null,snapshot(runId).Cancelled_At__c);
        }
    }
    @IsTest static void rejectsRepeatCancellation(){
        System.runAs(maker()) {
            assertReviewPermissions();
            Id runId=draft('REPEAT');Test.startTest();SABPayrollReviewService.cancel(runId,'Duplicate');
            rejected(runId,'Cancel','Again','Only unposted');Test.stopTest();System.assertEquals('Duplicate',snapshot(runId).Cancellation_Reason__c);
        }
    }
    @IsTest static void deniesCompanyWithoutEffectiveGrant(){
        System.runAs(maker()) {
            assertReviewPermissions();
            Id runId=calculated();User unauthorized=noGrantUser();allowRunEdit(runId,unauthorized.Id);
            Test.startTest();Boolean denied=false;
            System.runAs(unauthorized){
                System.assert(FeatureManagement.checkPermission('SAB_Cancel_Payroll'),'Action permission must be present so company denial is tested.');
                try{SABPayrollReviewService.cancel(runId,'Unauthorized');}
                catch(SABCompanyAccessService.CompanyAccessDeniedException ex){denied=true;}
            }Test.stopTest();System.assert(denied,'An action permission and record access do not replace company authorization.');
            System.assertEquals('Calculated',snapshot(runId).Workflow_State__c);
        }
    }
    private static void transitionRejected(Payroll_Run__c run,String action,Id actor,String expected){
        Boolean failed=false;
        try{SABPayrollReviewService.validateTransition(run,action,'Reason',actor);}
        catch(SABPayrollReviewService.ReviewException ex){failed=true;System.assert(ex.getMessage().contains(expected),ex.getMessage());}
        System.assert(failed,'Expected state rule: '+expected);
    }
    @IsTest static void protectsPostedAndIncompleteAudit(){
        System.runAs(maker()) {
            assertReviewPermissions();
            Payroll_Run__c run=new Payroll_Run__c(Workflow_State__c='Posted');
            transitionRejected(run,'Cancel',UserInfo.getUserId(),'controlled reversal');run.Workflow_State__c='Settled';
            transitionRejected(run,'Submit',UserInfo.getUserId(),'controlled reversal');run.Workflow_State__c='Submitted';
            transitionRejected(run,'Approve',UserInfo.getUserId(),'audit information');
            run.Accounting_Event__c=Accounting_Event__c.SObjectType.getDescribe().getKeyPrefix()+'000000000001';
            transitionRejected(run,'Cancel',UserInfo.getUserId(),'controlled reversal');
        }
    }
    @IsTest static void creatorCannotApproveAnotherSubmittersRun(){
        System.runAs(maker()) {
            assertReviewPermissions();
            Id runId=calculated();Payroll_Run__c run=snapshot(runId);run.Workflow_State__c='Submitted';
            run.Submitted_By__c=reviewer().Id;run.Submitted_At__c=System.now();
            transitionRejected(run,'Approve',UserInfo.getUserId(),'different user');
        }
    }
    private class ReviewData {
        Payroll_Run__c run;List<Payroll_Line__c> lines;List<Payroll_Component_Line__c> details;
        ReviewData(Id runId){
            run=snapshot(runId);
            lines=[SELECT Id,Employment__c,Employment__r.Company__c,Gross_Amount__c,Deduction_Amount__c,Employer_Contribution__c,Net_Amount__c
                FROM Payroll_Line__c WHERE Payroll_Run__c=:runId];
            details=[SELECT Id,Payroll_Line__c,Amount__c,Component_Category__c FROM Payroll_Component_Line__c WHERE Payroll_Line__r.Payroll_Run__c=:runId];
        }
        void rejects(String expected){
            Boolean failed=false;
            try{SABPayrollReviewService.validateTotals(run,lines,details);}
            catch(SABPayrollReviewService.ReviewException ex){failed=true;System.assert(ex.getMessage().contains(expected),ex.getMessage());}
            System.assert(failed,'Expected reconciliation failure: '+expected);
        }
    }
    @IsTest static void detectsCorruptSnapshotTotals(){
        System.runAs(maker()) {
            assertReviewPermissions();
            ReviewData d=new ReviewData(calculated());Test.startTest();
            SABPayrollReviewService.validateTotals(d.run,d.lines,d.details);
            d.run.Net_Total__c=0;d.rejects('Run totals');d.run.Net_Total__c=9500;
            d.lines[0].Net_Amount__c=0;d.rejects('Employee payroll totals');d.lines[0].Net_Amount__c=9500;
            d.details[0].Component_Category__c='Unsupported';d.rejects('category');Test.stopTest();
        }
    }
    @IsTest static void detectsInvalidAmountsAndParents(){
        System.runAs(maker()) {
            assertReviewPermissions();
            ReviewData d=new ReviewData(calculated());Decimal original=d.details[0].Amount__c;Test.startTest();
            d.details[0].Amount__c=-1;d.rejects('parent or amount');d.details[0].Amount__c=null;d.rejects('parent or amount');
            d.details[0].Amount__c=original;d.details[0].Payroll_Line__c=null;d.rejects('parent or amount');Test.stopTest();
        }
    }
    @IsTest static void detectsMissingAndCrossCompanyLines(){
        System.runAs(maker()) {
            assertReviewPermissions();
            ReviewData d=new ReviewData(calculated());Test.startTest();
            d.lines.add(d.lines[0]);d.rejects('employment');d.lines.remove(1);
            d.lines[0].Employment__r.Company__c=null;d.rejects('employment');d.lines[0].Employment__r.Company__c=d.run.Company__c;
            d.lines[0].Employment__c=null;d.rejects('employment');
            d.lines.clear();d.rejects('1 to 200');Test.stopTest();
        }
    }
    @IsTest static void detectsMissingComponentsAndNegativeNet(){
        System.runAs(maker()) {
            assertReviewPermissions();
            ReviewData d=new ReviewData(calculated());Test.startTest();
            for(Payroll_Component_Line__c line:d.details)if(line.Component_Category__c=='Deduction')line.Amount__c=99999;
            d.rejects('Employee payroll totals');d.details.clear();d.rejects('1 to 200');Test.stopTest();
        }
    }
}
