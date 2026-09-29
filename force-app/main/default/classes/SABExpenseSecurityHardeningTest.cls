@IsTest
private class SABExpenseSecurityHardeningTest {

    private static final String WORKSPACE_PERMISSION_SET =
        'SAB_Expense_Operations_Workspace';
    private static final String REIMBURSEMENT_PERMISSION_SET =
        'SAB_Expense_Reimbursement_Action';

    @TestSetup
    static void setupUsers() {
        Profile adminProfile = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
              AND PermissionsModifyAllData = true
            ORDER BY Name
            LIMIT 1
        ];

        Profile standardProfile = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
              AND PermissionsModifyAllData = false
            ORDER BY Name
            LIMIT 1
        ];

        String seed = String.valueOf(Datetime.now().getTime());

        User adminWithoutWorkspace = new User(
            Alias = 'g8eadm',
            Email = 'g8e.admin.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'G8E Admin Without Workspace',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = adminProfile.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = 'g8e.admin.' + seed + '@example.test'
        );

        User workspaceUser = new User(
            Alias = 'g8ews',
            Email = 'g8e.workspace.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'G8E Workspace User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = 'g8e.workspace.' + seed + '@example.test'
        );

        User financeUser = new User(
            Alias = 'g8efin',
            Email = 'g8e.finance.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'G8E Finance User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = 'g8e.finance.' + seed + '@example.test'
        );

        insert new List<User>{
            adminWithoutWorkspace,
            workspaceUser,
            financeUser
        };

        Set<String> requiredPermissionSets = new Set<String>{
            WORKSPACE_PERMISSION_SET,
            REIMBURSEMENT_PERMISSION_SET
        };

        Map<String, Id> permissionIds = new Map<String, Id>();
        for (PermissionSet row : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN :requiredPermissionSets
        ]) {
            permissionIds.put(row.Name, row.Id);
        }

        System.assertEquals(
            2,
            permissionIds.size(),
            'G8E dependency Permission Sets must exist.'
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = workspaceUser.Id,
                PermissionSetId = permissionIds.get(WORKSPACE_PERMISSION_SET)
            ),
            new PermissionSetAssignment(
                AssigneeId = financeUser.Id,
                PermissionSetId = permissionIds.get(REIMBURSEMENT_PERMISSION_SET)
            )
        };
    }

    @IsTest
    static void systemAdministratorDoesNotBypassWorkspacePermission() {
        User adminUser = getUser('G8E Admin Without Workspace');
        Accounting_Company__c company = makeCompany('E8A');

        insert new Company_User_Access__c(
            Company__c = company.Id,
            User__c = adminUser.Id,
            Effective_From__c = Date.today(),
            Grant_Key__c = 'G8E-ADMIN-GRANT',
            Is_Active__c = true,
            Role__c = 'Finance Manager'
        );

        System.runAs(adminUser) {
            System.assertEquals(
                false,
                SABPermissionService.hasPermission(
                    'SAB_View_Expense_Operations'
                )
            );

            Boolean blocked = false;
            try {
                SABExpenseOperationsWorkspaceController.getDashboard(
                    company.Id
                );
            } catch (Exception ex) {
                blocked = true;
            }

            System.assertEquals(true, blocked);
        }
    }

    @IsTest
    static void workspacePermissionDoesNotBypassCompanyAuthorization() {
        User workspaceUser = getUser('G8E Workspace User');
        Accounting_Company__c company = makeCompany('E8B');

        System.runAs(workspaceUser) {
            System.assertEquals(
                true,
                SABPermissionService.hasPermission(
                    'SAB_View_Expense_Operations'
                )
            );

            System.assertEquals(
                false,
                SABCompanyAccessService.hasCompanyAccess(
                    company.Id
                )
            );

            Boolean blocked = false;
            try {
                SABExpenseOperationsWorkspaceController.getDashboard(
                    company.Id
                );
            } catch (Exception ex) {
                blocked = true;
            }

            System.assertEquals(true, blocked);
        }
    }

    @IsTest
    static void authorizedWorkspacePassesCrudFlsPolicy() {
        User workspaceUser = getUser('G8E Workspace User');
        Accounting_Company__c company = makeCompany('E8C');

        insert new Company_User_Access__c(
            Company__c = company.Id,
            User__c = workspaceUser.Id,
            Effective_From__c = Date.today(),
            Grant_Key__c = 'G8E-WS-GRANT',
            Is_Active__c = true,
            Role__c = 'Finance Manager'
        );

        System.runAs(workspaceUser) {
            Test.startTest();
            SABExpenseOperationsWorkspaceController.DashboardDTO dashboard =
                SABExpenseOperationsWorkspaceController.getDashboard(
                    company.Id
                );
            Test.stopTest();

            System.assertEquals(company.Id, dashboard.companyId);
            System.assertEquals(0, dashboard.claims.size());
            System.assertEquals(
                0,
                dashboard.reimbursementPayments.size()
            );
        }
    }

    @IsTest
    static void directClaimLifecycleInjectionIsBlocked() {
        ExpenseFixture fixture = makeExpenseFixture('E8D', false);

        Expense_Claim__c injected = new Expense_Claim__c(
            Company__c = fixture.company.Id,
            Claimant_Employment__c = fixture.employment.Id,
            Claim_Date__c = Date.newInstance(2026, 9, 15),
            Accounting_Date__c = Date.newInstance(2026, 9, 15),
            Currency__c = 'BDT',
            Status__c = 'Draft',
            Total__c = 999
        );

        Database.SaveResult result = Database.insert(injected, false);

        System.assertEquals(false, result.isSuccess());
        System.assert(
            result.getErrors()[0].getMessage().contains('system-managed')
            || result.getErrors()[0].getMessage().contains('Total'),
            result.getErrors()[0].getMessage()
        );
    }

    @IsTest
    static void directTaxSnapshotInjectionIsBlocked() {
        ExpenseFixture fixture = makeExpenseFixture('E8E', true);

        Expense_Claim_Line__c line = new Expense_Claim_Line__c(
            Expense_Claim__c = fixture.claim.Id,
            Expense_Date__c = Date.newInstance(2026, 9, 14),
            Category__c = 'Travel',
            Description__c = 'Direct snapshot injection',
            Amount__c = 100,
            Expense_Account__c = fixture.expenseAccount.Id,
            Taxable_Base__c = 100,
            Tax_Amount__c = 15
        );

        Database.SaveResult result = Database.insert(line, false);

        System.assertEquals(false, result.isSuccess());
        System.assert(
            result.getErrors()[0].getMessage().contains(
                'tax snapshot fields are system-managed'
            ),
            result.getErrors()[0].getMessage()
        );
    }

    @IsTest
    static void directClaimSettlementInsertIsBlocked() {
        ExpenseFixture fixture = makeExpenseFixture('E8F', true);
        Accounting_Payment__c payment =
            makePayment(fixture.company, 'E8F', 100);

        Claim_Settlement__c settlement = new Claim_Settlement__c(
            Expense_Claim__c = fixture.claim.Id,
            Payment__c = payment.Id,
            Allocated_Amount__c = 50,
            Effective_Date__c = Date.newInstance(2026, 9, 25),
            Settlement_Key__c = 'G8E-DIRECT-SETTLEMENT',
            Status__c = 'Effective'
        );

        Database.SaveResult result = Database.insert(settlement, false);

        System.assertEquals(false, result.isSuccess());
        System.assert(
            result.getErrors()[0].getMessage().contains(
                'must be created through the Expense Claim Settlement service'
            ),
            result.getErrors()[0].getMessage()
        );
    }

    @IsTest
    static void crossCompanySettlementIsBlocked() {
        User financeUser = getUser('G8E Finance User');
        ExpenseFixture claimFixture = makeExpenseFixture('E8G', true);
        Accounting_Company__c paymentCompany = makeCompany('E8H');
        Accounting_Payment__c payment =
            makePayment(paymentCompany, 'E8H', 100);

        SABAccountingPaymentMutationContext.beginMutation();
        try {
            payment.Functional_Currency__c = 'BDT';
            payment.Exchange_Rate__c = 1;
            payment.Processing_State__c = 'Succeeded';
            update payment;
        } finally {
            SABAccountingPaymentMutationContext.endMutation();
        }

        SABExpenseClaimSettlementService.settlementMutationInProgress = true;
        try {
            claimFixture.claim.Total__c = 100;
            claimFixture.claim.Status__c = 'Posted';
            update claimFixture.claim;
        } finally {
            SABExpenseClaimSettlementService.settlementMutationInProgress =
                false;
        }

        insert new Company_User_Access__c(
            Company__c = claimFixture.company.Id,
            User__c = financeUser.Id,
            Effective_From__c = Date.today(),
            Grant_Key__c = 'G8E-FINANCE-CLAIM-GRANT',
            Is_Active__c = true,
            Role__c = 'Finance Manager'
        );

        System.runAs(financeUser) {
            SABExpenseClaimSettlementService.SettlementRequest request =
                new SABExpenseClaimSettlementService.SettlementRequest();
            request.expenseClaimId = claimFixture.claim.Id;
            request.paymentId = payment.Id;
            request.amount = 50;
            request.settlementKey = 'G8E-CROSS-COMPANY';

            Boolean blocked = false;

            Test.startTest();
            try {
                SABExpenseClaimSettlementService.settleClaim(request);
            } catch (
                SABExpenseClaimSettlementService.ExpenseClaimSettlementException ex
            ) {
                blocked = ex.getMessage().contains('Cross-company');
            }
            Test.stopTest();

            System.assertEquals(true, blocked);
        }
    }

    private class ExpenseFixture {
        Accounting_Company__c company;
        Employee__c employee;
        Employment__c employment;
        Expense_Claim__c claim;
        GL_Account__c expenseAccount;
    }

    private static ExpenseFixture makeExpenseFixture(
        String keyValue,
        Boolean createClaim
    ) {
        ExpenseFixture fixture = new ExpenseFixture();
        fixture.company = makeCompany(keyValue);

        fixture.employee = new Employee__c(
            Name = 'Employee ' + keyValue,
            Employee_Reference__c = keyValue + '-EMP',
            Status__c = 'Active'
        );
        insert fixture.employee;

        fixture.employment = new Employment__c(
            Company__c = fixture.company.Id,
            Employee__c = fixture.employee.Id,
            Employment_Key__c = keyValue + '-EMPLOYMENT',
            Employment_Status__c = 'Active',
            Start_Date__c = Date.newInstance(2026, 1, 1)
        );
        insert fixture.employment;

        fixture.expenseAccount = makeGL(
            fixture.company.Id,
            keyValue + '-6100',
            '6100',
            'Expense',
            'Debit',
            false,
            'None'
        );

        if (createClaim) {
            fixture.claim = new Expense_Claim__c(
                Company__c = fixture.company.Id,
                Claimant_Employment__c = fixture.employment.Id,
                Claim_Date__c = Date.newInstance(2026, 9, 15),
                Accounting_Date__c = Date.newInstance(2026, 9, 15),
                Currency__c = 'BDT',
                Status__c = 'Draft'
            );
            insert fixture.claim;
        }

        return fixture;
    }

    private static Accounting_Payment__c makePayment(
        Accounting_Company__c company,
        String keyValue,
        Decimal amountValue
    ) {
        GL_Account__c bankGL = makeGL(
            company.Id,
            keyValue + '-1100',
            '1100',
            'Asset',
            'Debit',
            false,
            'None'
        );

        Bank_Account__c bank = new Bank_Account__c(
            Name = 'Bank ' + keyValue,
            Company__c = company.Id,
            Currency__c = 'BDT',
            GL_Account__c = bankGL.Id,
            Is_Active__c = true
        );
        insert bank;

        Accounting_Payment__c payment = new Accounting_Payment__c(
            Company__c = company.Id,
            Bank_Account__c = bank.Id,
            Direction__c = 'Disbursement',
            Method__c = 'Bank Transfer',
            Reference__c = keyValue + '-PAY',
            Amount__c = amountValue,
            Transaction_Currency__c = 'BDT',
            Effective_Date__c = Date.newInstance(2026, 9, 25),
            Processing_State__c = 'Draft'
        );
        insert payment;
        return payment;
    }

    private static Accounting_Company__c makeCompany(String keyValue) {
        Accounting_Company__c company = new Accounting_Company__c(
            Name__c = 'G8E Company ' + keyValue,
            Company_Key__c = keyValue,
            Country_Code__c = 'BD',
            Functional_Currency__c = 'BDT',
            Fiscal_Calendar_Type__c = 'Calendar',
            Fiscal_Year_Start_Month__c = 1,
            Setup_Status__c = 'Active',
            Is_Active__c = true
        );
        insert company;
        return company;
    }

    private static GL_Account__c makeGL(
        Id companyId,
        String companyKey,
        String accountCode,
        String accountType,
        String normalBalance,
        Boolean isControl,
        String controlType
    ) {
        GL_Account__c row = new GL_Account__c(
            Name = accountType + ' ' + companyKey,
            Company__c = companyId,
            Company_Account_Key__c = companyKey,
            Account_Code__c = accountCode,
            Account_Type__c = accountType,
            Normal_Balance__c = normalBalance,
            Is_Active__c = true,
            Is_Control_Account__c = isControl,
            Control_Type__c = controlType,
            Manual_Posting_Allowed__c = !isControl
        );
        insert row;
        return row;
    }

    private static User getUser(String lastName) {
        return [
            SELECT Id
            FROM User
            WHERE LastName = :lastName
            LIMIT 1
        ];
    }
}
