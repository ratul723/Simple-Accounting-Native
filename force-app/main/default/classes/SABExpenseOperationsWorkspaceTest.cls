@IsTest
private class SABExpenseOperationsWorkspaceTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Remaining_Fields_Admin',
            'SAB_Expense_Operations_Workspace',
            'SAB_Submit_Expense_Claim_Action',
            'SAB_Review_Expense_Claim_Action',
            'SAB_Post_Expense_Claim_Action',
            'SAB_Expense_Reimbursement_Action'
        };

    @TestSetup
    static void setupFixture() {
        User testUser = createUser();
        assignPermissionSets(testUser);

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c = 'G8D Workspace Company',
                    Company_Key__c = 'E8D',
                    Country_Code__c = 'BD',
                    Functional_Currency__c = 'BDT',
                    Fiscal_Calendar_Type__c = 'Calendar',
                    Fiscal_Year_Start_Month__c = 1,
                    Setup_Status__c = 'Active',
                    Is_Active__c = true
                );
            insert company;

            insert new Company_User_Access__c(
                Company__c = company.Id,
                User__c = testUser.Id,
                Effective_From__c = Date.today(),
                Grant_Key__c = 'G8D-ACCESS',
                Is_Active__c = true,
                Role__c = 'Finance Manager'
            );

            GL_Account__c expenseAccount =
                new GL_Account__c(
                    Name = 'G8D Staff Expense',
                    Company__c = company.Id,
                    Company_Account_Key__c = 'E8D-6100',
                    Account_Code__c = '6100',
                    Account_Type__c = 'Expense',
                    Normal_Balance__c = 'Debit',
                    Is_Active__c = true,
                    Is_Control_Account__c = false,
                    Control_Type__c = 'None',
                    Manual_Posting_Allowed__c = true
                );
            insert expenseAccount;

            GL_Account__c bankGL =
                new GL_Account__c(
                    Name = 'G8D Bank GL',
                    Company__c = company.Id,
                    Company_Account_Key__c = 'E8D-1100',
                    Account_Code__c = '1100',
                    Account_Type__c = 'Asset',
                    Normal_Balance__c = 'Debit',
                    Is_Active__c = true,
                    Is_Control_Account__c = false,
                    Control_Type__c = 'None',
                    Manual_Posting_Allowed__c = true
                );
            insert bankGL;

            Bank_Account__c bank =
                new Bank_Account__c(
                    Name = 'G8D Operating Bank',
                    Company__c = company.Id,
                    Currency__c = 'BDT',
                    GL_Account__c = bankGL.Id,
                    Is_Active__c = true
                );
            insert bank;

            Employee__c employee =
                new Employee__c(
                    Name = 'G8D Employee',
                    Employee_Reference__c = 'G8D-EMP-001',
                    Status__c = 'Active',
                    User__c = testUser.Id
                );
            insert employee;

            Employment__c employment =
                new Employment__c(
                    Company__c = company.Id,
                    Employee__c = employee.Id,
                    Employment_Key__c = 'G8D-EMPLOYMENT-001',
                    Employment_Status__c = 'Active',
                    Start_Date__c = Date.newInstance(2026, 1, 1)
                );
            insert employment;

            Expense_Claim__c claim =
                new Expense_Claim__c(
                    Company__c = company.Id,
                    Claimant_Employment__c = employment.Id,
                    Claim_Date__c = Date.newInstance(2026, 9, 20),
                    Accounting_Date__c = Date.newInstance(2026, 9, 20),
                    Currency__c = 'BDT',
                    Status__c = 'Draft'
                );
            insert claim;

            insert new Expense_Claim_Line__c(
                Expense_Claim__c = claim.Id,
                Expense_Date__c = Date.newInstance(2026, 9, 19),
                Category__c = 'Travel',
                Description__c = 'G8D transport',
                Amount__c = 150,
                Expense_Account__c = expenseAccount.Id
            );

            SABExpenseClaimSettlementService.settlementMutationInProgress =
                true;
            try {
                claim.Total__c = 150;
                claim.Status__c = 'Part Paid';
                update claim;
            } finally {
                SABExpenseClaimSettlementService.settlementMutationInProgress =
                    false;
            }

            Accounting_Payment__c payment =
                new Accounting_Payment__c(
                    Company__c = company.Id,
                    Bank_Account__c = bank.Id,
                    Direction__c = 'Disbursement',
                    Method__c = 'Bank Transfer',
                    Reference__c = 'G8D-REIMB-001',
                    Amount__c = 100,
                    Transaction_Currency__c = 'BDT',
                    Effective_Date__c = Date.newInstance(2026, 9, 25),
                    Processing_State__c = 'Draft'
                );
            insert payment;

            SABAccountingPaymentMutationContext.beginMutation();
            try {
                payment.Functional_Currency__c = 'BDT';
                payment.Exchange_Rate__c = 1;
                payment.Processing_State__c = 'Succeeded';
                update payment;
            } finally {
                SABAccountingPaymentMutationContext.endMutation();
            }

            SABExpenseClaimSettlementService.settlementMutationInProgress =
                true;
            try {
                insert new Claim_Settlement__c(
                    Expense_Claim__c = claim.Id,
                    Payment__c = payment.Id,
                    Allocated_Amount__c = 100,
                    Effective_Date__c = Date.newInstance(2026, 9, 25),
                    Settlement_Key__c = 'G8D-SETTLEMENT-001',
                    Status__c = 'Effective'
                );
            } finally {
                SABExpenseClaimSettlementService.settlementMutationInProgress =
                    false;
            }
        }
    }

    @IsTest
    static void dashboardShowsExpenseOperations() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Company__c company = getCompany();

            Test.startTest();

            SABExpenseOperationsWorkspaceController.DashboardDTO dashboard =
                SABExpenseOperationsWorkspaceController.getDashboard(
                    company.Id
                );

            Test.stopTest();

            System.assertEquals(
                company.Id,
                dashboard.companyId
            );
            System.assertEquals(
                'BDT',
                dashboard.functionalCurrency
            );
            System.assertEquals(
                1,
                dashboard.partPaidCount
            );
            System.assertEquals(
                Decimal.valueOf('50.0000'),
                dashboard.reimbursementOutstanding
            );
            System.assertEquals(
                1,
                dashboard.claims.size()
            );
            System.assertEquals(
                Decimal.valueOf('100.0000'),
                dashboard.claims[0].paidAmount
            );
            System.assertEquals(
                Decimal.valueOf('50.0000'),
                dashboard.claims[0].remainingAmount
            );
            System.assertEquals(
                1,
                dashboard.claims[0].lineCount
            );
            System.assertEquals(
                1,
                dashboard.claims[0].settlementCount
            );
            System.assertEquals(
                1,
                dashboard.reimbursementPayments.size()
            );
            System.assertEquals(
                'Succeeded',
                dashboard.reimbursementPayments[0].processingState
            );
            System.assertEquals(
                Decimal.valueOf('0.0000'),
                dashboard.reimbursementPayments[0].remainingAmount
            );

            System.assertEquals(
                true,
                dashboard.canSubmitClaim
            );
            System.assertEquals(
                true,
                dashboard.canReviewClaim
            );
            System.assertEquals(
                true,
                dashboard.canPostClaim
            );
            System.assertEquals(
                true,
                dashboard.canProcessReimbursement
            );
        }
    }

    @IsTest
    static void claimDetailShowsLinesAndSettlementHistory() {
        User testUser = getUser();

        System.runAs(testUser) {
            Expense_Claim__c claim = [
                SELECT Id
                FROM Expense_Claim__c
                WHERE Company__r.Company_Key__c = 'E8D'
                LIMIT 1
            ];

            Test.startTest();

            SABExpenseOperationsWorkspaceController.ClaimDetailDTO detail =
                SABExpenseOperationsWorkspaceController.getClaimDetail(
                    claim.Id
                );

            Test.stopTest();

            System.assertEquals(
                claim.Id,
                detail.claimId
            );
            System.assertEquals(
                1,
                detail.lines.size()
            );
            System.assertEquals(
                'Travel',
                detail.lines[0].category
            );
            System.assertEquals(
                Decimal.valueOf('150.0000'),
                detail.lines[0].amount
            );
            System.assertEquals(
                1,
                detail.settlements.size()
            );
            System.assertEquals(
                Decimal.valueOf('100.0000'),
                detail.settlements[0].allocatedAmount
            );
            System.assertEquals(
                'Effective',
                detail.settlements[0].status
            );
        }
    }

    @IsTest
    static void companyIsRequired() {
        User testUser = getUser();

        System.runAs(testUser) {
            Boolean blocked = false;

            try {
                SABExpenseOperationsWorkspaceController.getDashboard(
                    null
                );
            } catch (AuraHandledException ex) {
                blocked = true;
            }

            System.assertEquals(true, blocked);
        }
    }

    private static User createUser() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String seed =
            String.valueOf(
                Datetime.now().getTime()
            );

        User row = new User(
            Alias = 'g8dwrk',
            Email = 'g8dwrk.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'G8D Expense Workspace User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = 'g8dwrk.' + seed + '@example.test'
        );
        insert row;
        return row;
    }

    private static void assignPermissionSets(User userRecord) {
        Map<String, Id> ids =
            new Map<String, Id>();

        for (PermissionSet row : [
            SELECT Id,
                   Name
            FROM PermissionSet
            WHERE Name IN :REQUIRED_PERMISSION_SETS
        ]) {
            ids.put(row.Name, row.Id);
        }

        System.assertEquals(
            REQUIRED_PERMISSION_SETS.size(),
            ids.size(),
            'All G8D dependency Permission Sets must exist.'
        );

        List<PermissionSetAssignment> rows =
            new List<PermissionSetAssignment>();

        for (String permissionSetName : REQUIRED_PERMISSION_SETS) {
            rows.add(
                new PermissionSetAssignment(
                    AssigneeId = userRecord.Id,
                    PermissionSetId =
                        ids.get(permissionSetName)
                )
            );
        }

        insert rows;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'G8D Expense Workspace User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getCompany() {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c = 'E8D'
            LIMIT 1
        ];
    }
}
