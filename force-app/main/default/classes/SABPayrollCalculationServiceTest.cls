@IsTest
private class SABPayrollCalculationServiceTest {
    private static void ensurePayrollPermission() {
        System.runAs(new User(Id=UserInfo.getUserId())) {
            PermissionSet p=[SELECT Id FROM PermissionSet WHERE Name='SAB_Payroll_Calculation_User'];
            Id assigneeId=UserInfo.getUserId();
            List<PermissionSetAssignment> existing=[SELECT Id FROM PermissionSetAssignment
                WHERE AssigneeId=:assigneeId AND PermissionSetId=:p.Id LIMIT 1];
            if (existing.isEmpty()) {
                insert new PermissionSetAssignment(AssigneeId=assigneeId,PermissionSetId=p.Id);
            }
            System.assertEquals(1,[SELECT COUNT() FROM PermissionSetAssignment
                WHERE AssigneeId=:assigneeId AND PermissionSetId=:p.Id],
                'The payroll permission must be assigned exactly once.');
        }
    }
    @TestSetup
    static void setupData() {
        ensurePayrollPermission();
        // Regression: running setup again must reuse the existing assignment.
        ensurePayrollPermission();
        Accounting_Company__c company=new Accounting_Company__c(Name__c='Payroll Test',Company_Key__c='B01',
            Country_Code__c='BD',Functional_Currency__c='BDT',Fiscal_Calendar_Type__c='Calendar',
            Fiscal_Year_Start_Month__c=1,Setup_Status__c='Active',Is_Active__c=true);
        insert company;
        insert new Company_User_Access__c(Company__c=company.Id,User__c=UserInfo.getUserId(),Role__c='HR',
            Is_Active__c=true,Effective_From__c=Date.today().addDays(-1),Grant_Key__c='G10B-GRANT');
        Employee__c employee=new Employee__c(Employee_Reference__c='G10B-EMP',Status__c='Active');insert employee;
        Employment__c employment=new Employment__c(Employee__c=employee.Id,Company__c=company.Id,
            Start_Date__c=Date.newInstance(2026,1,1),Employment_Status__c='Active');insert employment;
        List<Pay_Component__c> components=new List<Pay_Component__c>();
        for(String category:new List<String>{'Basic Salary','Food Allowance','Deduction','Employer Contribution'}) {
            components.add(new Pay_Component__c(Name=category,Company__c=company.Id,Component_Key__c='G10B-'+category,
                Category__c=category,Is_Active__c=true));
        }
        insert components;
        List<Employee_Pay_Component__c> assignments=new List<Employee_Pay_Component__c>();
        List<Decimal> amounts=new List<Decimal>{10000,500,1000,250};
        for(Integer i=0;i<components.size();i++) assignments.add(new Employee_Pay_Component__c(
            Employment__c=employment.Id,Pay_Component__c=components[i].Id,Amount__c=amounts[i],Currency__c='BDT',
            Effective_From__c=Date.newInstance(2026,1,1),Status__c='Approved'));
        insert assignments;
    }
    private static Id companyId(){return [SELECT Id FROM Accounting_Company__c WHERE Company_Key__c='B01'].Id;}
    private static Id employmentId(){return [SELECT Id FROM Employment__c LIMIT 1].Id;}
    private static Id draft(String key){return SABPayrollCalculationService.createDraft(companyId(),Date.newInstance(2026,10,1),Date.newInstance(2026,10,31),' bdt ',key);}
    private static void rejectsCalculation(Id runId,List<Id> ids,Integer units,String message){
        Boolean rejected=false;
        try{SABPayrollCalculationService.calculate(runId,ids,units);}
        catch(SABPayrollCalculationService.PayrollException ex){rejected=true;System.assert(ex.getMessage().contains(message),ex.getMessage());}
        System.assert(rejected,'Expected rejection: '+message);
        if(runId!=null) System.assertEquals(0,[SELECT COUNT() FROM Payroll_Line__c WHERE Payroll_Run__c=:runId],'Rejected calculation must not leave rows.');
    }
    @IsTest static void calculatesAndFreezesSnapshots(){
        Id runId=draft('SUCCESS');Id emp=employmentId();Test.startTest();
        System.assertEquals(runId,SABPayrollCalculationService.calculate(runId,new List<Id>{emp},2));Test.stopTest();
        Payroll_Run__c run=[SELECT Workflow_State__c,Gross_Total__c,Deduction_Total__c,Employer_Total__c,Net_Total__c FROM Payroll_Run__c WHERE Id=:runId];
        System.assertEquals('Calculated',run.Workflow_State__c);System.assertEquals(10500,run.Gross_Total__c);
        System.assertEquals(1000,run.Deduction_Total__c);System.assertEquals(250,run.Employer_Total__c);System.assertEquals(9500,run.Net_Total__c);
        Payroll_Line__c line=[SELECT Id,Net_Amount__c FROM Payroll_Line__c WHERE Payroll_Run__c=:runId];System.assertEquals(9500,line.Net_Amount__c);
        List<Payroll_Component_Line__c> details=[SELECT Amount__c,Eligibility_Snapshot__c,Rule_Version__c FROM Payroll_Component_Line__c WHERE Payroll_Line__c=:line.Id];
        System.assertEquals(4,details.size());System.assert(details[0].Eligibility_Snapshot__c.contains('assignmentId'));
        System.assertEquals('G10B_FIXED_V1',details[0].Rule_Version__c);
        Boolean rejected=false;
        try{SABPayrollCalculationService.calculate(runId,new List<Id>{emp},2);}
        catch(SABPayrollCalculationService.PayrollException ex){rejected=true;System.assert(ex.getMessage().contains('Only Draft'));}
        System.assert(rejected);System.assertEquals(1,[SELECT COUNT() FROM Payroll_Line__c WHERE Payroll_Run__c=:runId]);
    }
    @IsTest static void protectsDirectPayrollWrites(){
        Id runId=draft('GUARD');
        Database.SaveResult r=Database.update(new Payroll_Run__c(Id=runId,Workflow_State__c='Posted'),false);
        System.assertEquals(false,r.isSuccess());System.assert(r.getErrors()[0].getMessage().contains('authorized payroll service'));
        Payroll_Line__c line=new Payroll_Line__c(Payroll_Run__c=runId,Employment__c=employmentId());
        r=Database.insert(line,false);System.assertEquals(false,r.isSuccess());
        SABPayrollCalculationService.calculate(runId,new List<Id>{employmentId()},2);
        Payroll_Component_Line__c detail=[SELECT Id,Amount__c FROM Payroll_Component_Line__c LIMIT 1];detail.Amount__c=999;
        r=Database.update(detail,false);System.assertEquals(false,r.isSuccess());
    }
    @IsTest static void rejectsDuplicatePayrollPeriod(){
        Id emp=employmentId();Id first=draft('FIRST');SABPayrollCalculationService.calculate(first,new List<Id>{emp},2);
        Id second=draft('SECOND');Test.startTest();rejectsCalculation(second,new List<Id>{emp},2,'overlapping');Test.stopTest();
    }
    @IsTest static void validatesSelection(){
        Id runId=draft('INPUT');Id emp=employmentId();Test.startTest();
        rejectsCalculation(null,null,2,'Select a run');
        rejectsCalculation(runId,new List<Id>{emp},4,'minor units');
        rejectsCalculation(runId,new List<Id>{emp,emp},2,'duplicate');
        rejectsCalculation(runId,new List<Id>{null},2,'null');Test.stopTest();
    }
    @IsTest static void validatesDraft(){
        Id c=companyId();Integer rejected=0;Test.startTest();
        try{SABPayrollCalculationService.createDraft(c,null,Date.today(),'BDT','X');}
        catch(SABPayrollCalculationService.PayrollException ex){rejected++;System.assert(ex.getMessage().contains('date'));}
        try{SABPayrollCalculationService.createDraft(c,Date.today(),Date.today(),'BDT',' ');}
        catch(SABPayrollCalculationService.PayrollException ex){rejected++;System.assert(ex.getMessage().contains('key'));}
        Test.stopTest();System.assertEquals(2,rejected);
    }
    @IsTest static void rejectsPartialEmployment(){
        Employment__c e=[SELECT Id,Start_Date__c FROM Employment__c LIMIT 1];e.Start_Date__c=Date.newInstance(2026,10,10);update e;
        Id runId=draft('PARTEMP');Test.startTest();rejectsCalculation(runId,new List<Id>{e.Id},2,'complete pay period');Test.stopTest();
    }
    @IsTest static void rejectsInactiveComponent(){
        Pay_Component__c p=[SELECT Id,Is_Active__c FROM Pay_Component__c LIMIT 1];p.Is_Active__c=false;update p;
        Id r=draft('INACTIVE');Test.startTest();rejectsCalculation(r,new List<Id>{employmentId()},2,'inactive');Test.stopTest();
    }
    @IsTest static void rejectsFormula(){
        Employee_Pay_Component__c a=[SELECT Id,Formula_Parameter_JSON__c FROM Employee_Pay_Component__c LIMIT 1];a.Formula_Parameter_JSON__c='{"rate":1}';update a;
        Id r=draft('FORMULA');Test.startTest();rejectsCalculation(r,new List<Id>{employmentId()},2,'fixed amounts');Test.stopTest();
    }
    @IsTest static void rejectsCurrencyMismatch(){
        Employee_Pay_Component__c a=[SELECT Id,Currency__c FROM Employee_Pay_Component__c LIMIT 1];a.Currency__c='USD';update a;
        Id r=draft('CURRENCY');Test.startTest();rejectsCalculation(r,new List<Id>{employmentId()},2,'currency');Test.stopTest();
    }
    @IsTest static void rejectsPartialAssignment(){
        Employee_Pay_Component__c a=[SELECT Id,Effective_From__c FROM Employee_Pay_Component__c LIMIT 1];a.Effective_From__c=Date.newInstance(2026,10,10);update a;
        Id r=draft('PARTASSIGN');Test.startTest();rejectsCalculation(r,new List<Id>{employmentId()},2,'proration');Test.stopTest();
    }
    @IsTest static void rejectsMissingApprovedCompensation(){
        List<Employee_Pay_Component__c> rows=[SELECT Id,Status__c FROM Employee_Pay_Component__c];
        for(Employee_Pay_Component__c a:rows)a.Status__c='Draft';update rows;
        Id r=draft('MISSING');Test.startTest();rejectsCalculation(r,new List<Id>{employmentId()},2,'needs approved compensation');Test.stopTest();
    }
    @IsTest static void rejectsNegativeNet(){
        Employee_Pay_Component__c a=[SELECT Id,Amount__c FROM Employee_Pay_Component__c WHERE Pay_Component__r.Category__c='Deduction'];a.Amount__c=99999;update a;
        Id r=draft('NEGATIVE');Test.startTest();rejectsCalculation(r,new List<Id>{employmentId()},2,'Deductions');Test.stopTest();
    }
    @IsTest static void rejectsApprovedAwardOmission(){
        Id emp=employmentId();Id component=[SELECT Id FROM Pay_Component__c WHERE Category__c='Food Allowance'].Id;
        insert new Benefit_Award__c(Employment__c=emp,Pay_Component__c=component,Award_Key__c='G10B-AWARD',
            Amount__c=50,Currency__c='BDT',Status__c='Approved',Service_Period_Start__c=Date.newInstance(2026,10,1));
        Id r=draft('AWARD');Test.startTest();rejectsCalculation(r,new List<Id>{emp},2,'Approved benefits');Test.stopTest();
    }
    @IsTest static void rejectsCompanyWithoutGrant(){
        Accounting_Company__c other=new Accounting_Company__c(Name__c='Other',Company_Key__c='B02',Country_Code__c='BD',
            Functional_Currency__c='BDT',Fiscal_Calendar_Type__c='Calendar',Fiscal_Year_Start_Month__c=1,Setup_Status__c='Active',Is_Active__c=true);insert other;
        Boolean rejected=false;Test.startTest();
        try{SABPayrollCalculationService.createDraft(other.Id,Date.today(),Date.today(),'BDT','DENIED');}
        catch(SABCompanyAccessService.CompanyAccessDeniedException ex){rejected=true;}
        Test.stopTest();System.assert(rejected,'Company access is required even for the test administrator.');
    }
}
