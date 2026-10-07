@IsTest
private class SABPayrollWorkspaceCreationTest {

    /**
     * Keep permission assignment in @TestSetup so USER_MODE DML in the test method
     * evaluates the same effective CRUD/FLS that a real payroll workspace user has.
     *
     * Assigning the Permission Set inside the same test method can leave USER_MODE
     * field-access evaluation using the transaction's earlier permission snapshot.
     */
    @TestSetup
    static void setupPermissions() {
        assignCalculationPermission();
    }

    @IsTest
    static void workspaceCreationGeneratesSystemFields() {
        Accounting_Company__c company=new Accounting_Company__c(Name__c='Payroll Create',Company_Key__c='PC1',
            Country_Code__c='BD',Functional_Currency__c='BDT',Fiscal_Calendar_Type__c='Calendar',
            Fiscal_Year_Start_Month__c=1,Setup_Status__c='Active',Is_Active__c=true);
        insert company;

        insert new Company_User_Access__c(
            Company__c=company.Id,
            User__c=UserInfo.getUserId(),
            Role__c='HR',
            Is_Active__c=true,
            Effective_From__c=Date.today().addDays(-1),
            Grant_Key__c='PAY-CREATE-GRANT'
        );

        Date starts=Date.newInstance(2026,10,1);
        Date ends=Date.newInstance(2026,10,31);

        Test.startTest();
        Id runId=SABPayrollCalculationService.createDraftForWorkspace(
            company.Id,
            starts,
            ends,
            ' bdt '
        );
        Test.stopTest();

        Payroll_Run__c run=[
            SELECT Company__c,
                   Currency__c,
                   Pay_Period_Start__c,
                   Pay_Period_End__c,
                   Workflow_State__c,
                   Run_Key__c,
                   Gross_Total__c,
                   Deduction_Total__c,
                   Employer_Total__c,
                   Net_Total__c
            FROM Payroll_Run__c
            WHERE Id=:runId
        ];

        System.assertEquals(company.Id,run.Company__c);
        System.assertEquals('BDT',run.Currency__c);
        System.assertEquals(starts,run.Pay_Period_Start__c);
        System.assertEquals(ends,run.Pay_Period_End__c);
        // System.assertEquals(1,run.Version__c);
        System.assertEquals('Draft',run.Workflow_State__c);
        System.assert(
            run.Run_Key__c.startsWith(
                'PAY|'+String.valueOf(company.Id)+'|2026-10-01|2026-10-31|'
            ),
            'Workspace creation must generate the internal Run Key server-side.'
        );
        System.assertEquals(0,run.Gross_Total__c);
        System.assertEquals(0,run.Deduction_Total__c);
        System.assertEquals(0,run.Employer_Total__c);
        System.assertEquals(0,run.Net_Total__c);
    }

    private static void assignCalculationPermission() {
        System.runAs(new User(Id=UserInfo.getUserId())) {
            PermissionSet ps=[
                SELECT Id
                FROM PermissionSet
                WHERE Name='SAB_Payroll_Calculation_User'
                LIMIT 1
            ];

            Id uid=UserInfo.getUserId();

            if ([
                SELECT COUNT()
                FROM PermissionSetAssignment
                WHERE AssigneeId=:uid
                  AND PermissionSetId=:ps.Id
            ] == 0) {
                insert new PermissionSetAssignment(
                    AssigneeId=uid,
                    PermissionSetId=ps.Id
                );
            }
        }
    }
}
