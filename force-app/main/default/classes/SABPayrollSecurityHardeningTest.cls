@IsTest
private class SABPayrollSecurityHardeningTest {
    private static final String MAKER = 'SABG10HMaker';
    private static final String EXPENSE = 'SABG10HExpense';
    private static final Date PAY_DATE = Date.newInstance(2026, 10, 31);
    private static final String GUARD_MESSAGE = 'Payroll payments are processed only through payroll settlement.';

    private static Map<String, User> users = new Map<String, User>();
    private static Map<String, Id> ids = new Map<String, Id>();

    // ------------------------------------------------------------- fixtures

    private static User newUser(String lastName, String alias, String unique) {
        return new User(Username = alias + '.' + unique + '@example.invalid', Email = alias + '@example.invalid',
            LastName = lastName, Alias = alias, TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = UserInfo.getProfileId());
    }

    @TestSetup
    static void setupData() {
        User makerUser;
        User expenseUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            makerUser = newUser(MAKER, 'g10hmkr', unique);
            expenseUser = newUser(EXPENSE, 'g10hexp', unique);
            insert as system new List<User>{makerUser, expenseUser};
            Map<Id, Set<String>> setsByUser = new Map<Id, Set<String>>{
                makerUser.Id => new Set<String>{'SAB_Payroll_Settlement_User', 'SAB_Process_Payroll_Payment_Action',
                    'SAB_Employee_Compensation_User', 'SAB_Manage_Employee_Compensation_Action', 'SAB_Approve_Employee_Compensation_Action'},
                expenseUser.Id => new Set<String>{'SAB_Expense_Reimbursement_Action', 'SAB_Payroll_Settlement_User'}};
            Set<String> names = new Set<String>();
            for (Set<String> s : setsByUser.values()) {
                names.addAll(s);
            }
            Map<String, Id> setIds = new Map<String, Id>();
            for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN :names WITH SYSTEM_MODE]) {
                setIds.put(p.Name, p.Id);
            }
            System.assertEquals(names.size(), setIds.size(), 'Deploy G8C, G10A and G10E permission sets before G10H tests.');
            List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
            for (Id userId : setsByUser.keySet()) {
                for (String name : setsByUser.get(userId)) {
                    rows.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = setIds.get(name)));
                }
            }
            insert as system rows;
        }
        System.runAs(makerUser) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'Hardening Test', Company_Key__c = 'H10',
                Country_Code__c = 'BD', Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active', Is_Active__c = true);
            insert as system company;
            insert as system new List<Company_User_Access__c>{
                new Company_User_Access__c(Company__c = company.Id, User__c = makerUser.Id, Role__c = 'HR', Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'G10H-MAKER'),
                new Company_User_Access__c(Company__c = company.Id, User__c = expenseUser.Id, Role__c = 'HR', Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'G10H-EXPENSE')};
            Map<String, GL_Account__c> accounts = new Map<String, GL_Account__c>{
                '6100' => gl(company.Id, '6100', 'Payroll Expense', 'Expense', 'Debit'),
                '2300' => gl(company.Id, '2300', 'Salary Payable', 'Liability', 'Credit'),
                '1100' => gl(company.Id, '1100', 'Operating Bank', 'Asset', 'Debit')};
            insert as system accounts.values();
            insert as system new Accounting_Period__c(Company__c = company.Id, Company_Period_Key__c = 'H10-OCT', Period_Key__c = '2026-10',
                Start_Date__c = Date.newInstance(2026, 10, 1), End_Date__c = PAY_DATE, Fiscal_Year__c = 2026, Fiscal_Quarter__c = 4,
                Period_Number__c = 10, Status__c = 'Open');
            insert as system new Bank_Account__c(Name = 'G10H Operating', Company__c = company.Id, Currency__c = 'BDT',
                GL_Account__c = accounts.get('1100').Id, Is_Active__c = true);
            Department__c department = new Department__c(Name = 'Operations', Company__c = company.Id, Code__c = 'OPS',
                Company_Department_Key__c = String.valueOf(company.Id) + '-OPS');
            insert as system department;
            Employee__c employee = new Employee__c(Employee_Reference__c = 'G10H-EMP', Status__c = 'Active');
            insert as system employee;
            Employment__c employment = new Employment__c(Employee__c = employee.Id, Company__c = company.Id, Department__c = department.Id,
                Start_Date__c = Date.newInstance(2026, 1, 1), Employment_Status__c = 'Active');
            insert as system employment;
            Pay_Component__c basic = new Pay_Component__c(Name = 'Basic Salary', Company__c = company.Id, Component_Key__c = 'G10H-BASIC',
                Category__c = 'Basic Salary', Is_Active__c = true, Expense_Account__c = accounts.get('6100').Id);
            Pay_Component__c bonus = new Pay_Component__c(Name = 'Bonus', Company__c = company.Id, Component_Key__c = 'G10H-BONUS',
                Category__c = 'Incentive', Is_Active__c = true, Expense_Account__c = accounts.get('6100').Id);
            insert as system new List<Pay_Component__c>{basic, bonus};
            insert as system new Employee_Pay_Component__c(Employment__c = employment.Id, Pay_Component__c = bonus.Id, Amount__c = 400,
                Currency__c = 'BDT', Effective_From__c = Date.newInstance(2026, 11, 1), Status__c = 'Draft');
            seedPostedRun(company.Id, employment.Id, basic.Id, accounts.get('2300').Id);
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    // Posted one-employee run (9,500 net) seeded through the service write scopes.
    private static void seedPostedRun(Id companyId, Id employmentId, Id basicId, Id payableId) {
        Payroll_Run__c run = new Payroll_Run__c(Company__c = companyId, Pay_Period_Start__c = Date.newInstance(2026, 10, 1),
            Pay_Period_End__c = PAY_DATE, Currency__c = 'BDT', Run_Key__c = 'G10H-RUN', Version__c = 1, Workflow_State__c = 'Approved',
            Gross_Total__c = 9500, Deduction_Total__c = 0, Employer_Total__c = 0, Net_Total__c = 9500,
            Submitted_By__c = UserInfo.getUserId(), Submitted_At__c = System.now(), Approved_By__c = UserInfo.getUserId(),
            Approved_At__c = System.now());
        SABPayrollCalculationService.writing = true;
        try {
            insert as system run;
            Payroll_Line__c line = new Payroll_Line__c(Payroll_Run__c = run.Id, Employment__c = employmentId, Gross_Amount__c = 9500,
                Deduction_Amount__c = 0, Employer_Contribution__c = 0, Net_Amount__c = 9500);
            insert as system line;
            insert as system new Payroll_Component_Line__c(Payroll_Line__c = line.Id, Pay_Component__c = basicId, Amount__c = 9500,
                Component_Category__c = 'Basic Salary', Rule_Version__c = 'G10B_FIXED_V1');
            Accounting_Event__c accrual = new Accounting_Event__c(Company__c = companyId, Adapter_Key__c = 'PAYROLL_ACCRUAL',
                Event_Key__c = 'PAYROLL|' + run.Id + '|V1|ACCRUAL', Event_Type__c = 'Payroll', Source_Type__c = 'Payroll_Run__c',
                Source_Record_Id__c = String.valueOf(run.Id), Source_Version__c = 1, State__c = 'Posted');
            insert as system accrual;
            update as system new Payroll_Run__c(Id = run.Id, Workflow_State__c = 'Posted', Accounting_Event__c = accrual.Id,
                Accounting_Date__c = PAY_DATE, Net_Payable_Account__c = payableId, Posted_By__c = UserInfo.getUserId(),
                Posted_At__c = System.now(), Posting_Request_Key__c = 'G10H-ACCRUAL');
        } finally {
            SABPayrollCalculationService.writing = false;
        }
    }

    private static GL_Account__c gl(Id companyId, String code, String label, String type, String balance) {
        return new GL_Account__c(Name = label, Company__c = companyId, Company_Account_Key__c = String.valueOf(companyId) + '-' + code,
            Account_Code__c = code, Account_Type__c = type, Normal_Balance__c = balance, Is_Active__c = true,
            Is_Control_Account__c = false, Control_Type__c = 'None', Manual_Posting_Allowed__c = true);
    }

    private static User fixtureUser(String lastName) {
        if (!users.containsKey(lastName)) {
            users.put(lastName, [SELECT Id FROM User WHERE LastName = :lastName AND Alias LIKE 'g10h%' WITH SYSTEM_MODE LIMIT 1]);
        }
        return users.get(lastName);
    }

    private static Id cached(String key, String soql) {
        if (!ids.containsKey(key)) {
            ids.put(key, Database.query(soql).Id);
        }
        return ids.get(key);
    }

    private static Id runId() {
        return cached('run', 'SELECT Id FROM Payroll_Run__c WHERE Run_Key__c = \'G10H-RUN\' WITH SYSTEM_MODE LIMIT 1');
    }

    private static Id companyId() {
        return cached('company', 'SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = \'H10\' WITH SYSTEM_MODE LIMIT 1');
    }

    private static Id bankId() {
        return cached('bank', 'SELECT Id FROM Bank_Account__c WHERE Name = \'G10H Operating\' WITH SYSTEM_MODE LIMIT 1');
    }

    private static String method() {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry entry : Accounting_Payment__c.Method__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        if (values.contains('Bank Transfer')) {
            return 'Bank Transfer';
        }
        return values.contains('BankTransfer') ? 'BankTransfer' : new List<String>(values)[0];
    }

    private static Id preparePayrollPayment(String key) {
        return SABPayrollSettlementService.preparePayment(runId(), bankId(), PAY_DATE, method(), 'OCT-NET', key).paymentId;
    }

    // A succeeded payroll payment, written through the payroll payment scope exactly as the service would.
    private static Id seedSucceededPayrollPayment() {
        Accounting_Payment__c payment = new Accounting_Payment__c(Company__c = companyId(), Bank_Account__c = bankId(),
            Direction__c = 'Disbursement', Method__c = method(), Amount__c = 9500, Transaction_Currency__c = 'BDT',
            Functional_Currency__c = 'BDT', Exchange_Rate__c = 1, Effective_Date__c = PAY_DATE, Payroll_Run__c = runId());
        SABPayrollSettlementService.paymentWriteScope = true;
        SABAccountingPaymentMutationContext.beginMutation();
        try {
            insert as system payment;
            update as system new Accounting_Payment__c(Id = payment.Id, Processing_State__c = 'Succeeded', Provider_Request_Key__c = 'G10H-BANK');
        } finally {
            SABAccountingPaymentMutationContext.endMutation();
            SABPayrollSettlementService.paymentWriteScope = false;
        }
        return payment.Id;
    }

    private static void expectBlocked(Database.SaveResult result, String what) {
        System.assertEquals(false, result.isSuccess(), what + ' must be blocked.');
        System.assert(result.getErrors()[0].getMessage().contains(GUARD_MESSAGE), what + ': ' + result.getErrors()[0].getMessage());
    }

    // ---------------------------------------------------------------- tests

    @IsTest
    static void payrollPaymentIsTaggedAndLockedAgainstOtherWriters() {
        Id paymentId;
        System.runAs(fixtureUser(MAKER)) {
            SABTestGovernor.startTest();
            paymentId = preparePayrollPayment('G10H-PREPARE');
            SABTestGovernor.stopTest();
        }
        System.assertEquals(runId(), [SELECT Payroll_Run__c FROM Accounting_Payment__c WHERE Id = :paymentId WITH SYSTEM_MODE].Payroll_Run__c,
            'Prepared payroll payment is tagged with its run.');
        expectBlocked(Database.update(new Accounting_Payment__c(Id = paymentId, Reference__c = 'TAMPERED'), false), 'Direct edit');
        // Other payment services write through the shared mutation context; that no longer opens payroll payments.
        SABAccountingPaymentMutationContext.beginMutation();
        try {
            expectBlocked(Database.update(new Accounting_Payment__c(Id = paymentId, Processing_State__c = 'Authorized'), false),
                'Another payment service');
        } finally {
            SABAccountingPaymentMutationContext.endMutation();
        }
        Database.DeleteResult deleted = Database.delete(paymentId, false);
        System.assertEquals(false, deleted.isSuccess(), 'Payroll payment cannot be deleted.');
        expectBlocked(Database.insert(new Accounting_Payment__c(Company__c = companyId(), Bank_Account__c = bankId(),
            Direction__c = 'Disbursement', Amount__c = 1, Transaction_Currency__c = 'BDT', Effective_Date__c = PAY_DATE,
            Payroll_Run__c = runId()), false), 'Forged payroll tag');
        Database.SaveResult tagged = Database.update(new Accounting_Payment__c(Id = paymentId, Payroll_Run__c = null), false);
        System.assertEquals(false, tagged.isSuccess(), 'The payroll tag cannot be removed.');
        // Ordinary payments are untouched by the guard.
        Accounting_Payment__c ordinary = new Accounting_Payment__c(Company__c = companyId(), Bank_Account__c = bankId(),
            Direction__c = 'Disbursement', Amount__c = 5, Transaction_Currency__c = 'BDT', Effective_Date__c = PAY_DATE);
        System.assert(Database.insert(ordinary, false).isSuccess(), 'Untagged payments insert normally.');
        System.assert(Database.update(new Accounting_Payment__c(Id = ordinary.Id, Reference__c = 'OK'), false).isSuccess(),
            'Untagged Draft payments still edit normally.');
        System.assertEquals('Draft', [SELECT Processing_State__c FROM Accounting_Payment__c WHERE Id = :paymentId WITH SYSTEM_MODE]
            .Processing_State__c, 'Payroll payment is unchanged.');
    }

    @IsTest
    static void expenseReimbursementRefusesPayrollPayment() {
        Id paymentId;
        System.runAs(fixtureUser(MAKER)) {
            paymentId = preparePayrollPayment('G10H-PREPARE-ER');
        }
        String message;
        SABTestGovernor.startTest();
        System.runAs(fixtureUser(EXPENSE)) {
            System.assert(FeatureManagement.checkPermission('SAB_Process_Expense_Reimbursement'), 'Fixture holds the reimbursement permission.');
            try {
                SABExpenseReimbursementPaymentService.authorizePayment(paymentId, 'G10H-ER-AUTH');
            } catch (SABExpenseReimbursementPaymentService.ExpenseReimbursementException ex) {
                message = ex.getMessage();
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals(GUARD_MESSAGE, message, 'Reimbursement service refuses payroll payments.');
        System.assertEquals('Draft', [SELECT Processing_State__c FROM Accounting_Payment__c WHERE Id = :paymentId WITH SYSTEM_MODE]
            .Processing_State__c, 'Payment stays Draft.');
        System.assertEquals(0, [SELECT COUNT() FROM Business_Action__c WHERE Request_Key__c = 'G10H-ER-AUTH' WITH SYSTEM_MODE],
            'Nothing is audited for the refused request.');
    }

    @IsTest
    static void allocationAndClaimSettlementRefusePayrollPayment() {
        Id paymentId = seedSucceededPayrollPayment();
        SABPaymentAllocationService.PaymentAllocationRequest request = new SABPaymentAllocationService.PaymentAllocationRequest();
        request.supplierBillId = paymentId;
        request.allocatedAmount = 100;
        String allocationMessage;
        String claimMessage;
        SABTestGovernor.startTest();
        System.runAs(fixtureUser(MAKER)) {
            try {
                SABPaymentAllocationService.allocatePayment(paymentId, new List<SABPaymentAllocationService.PaymentAllocationRequest>{request});
            } catch (SABPaymentAllocationService.PaymentAllocationException ex) {
                allocationMessage = ex.getMessage();
            }
            try {
                SABExpenseClaimSettlementService.lockPayment(paymentId);
            } catch (SABExpenseClaimSettlementService.ExpenseClaimSettlementException ex) {
                claimMessage = ex.getMessage();
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals(GUARD_MESSAGE, allocationMessage, 'AP/AR allocation refuses payroll payments.');
        System.assertEquals(GUARD_MESSAGE, claimMessage, 'Expense claim settlement refuses payroll payments.');
        System.assertEquals(0, [SELECT COUNT() FROM Payment_Allocation__c WHERE Payment__c = :paymentId WITH SYSTEM_MODE],
            'No allocation was created.');
    }

    @IsTest
    static void compensationActionsRunWithFieldChecksAndCompleteIntegrityReads() {
        Id companyId = companyId();
        Id employmentId = [SELECT Id FROM Employment__c WHERE Company__c = :companyId WITH SYSTEM_MODE LIMIT 1].Id;
        Id bonusId = [SELECT Id FROM Pay_Component__c WHERE Component_Key__c = 'G10H-BONUS' WITH SYSTEM_MODE].Id;
        Id assignmentId = [SELECT Id FROM Employee_Pay_Component__c WHERE Status__c = 'Draft' AND Employment__c = :employmentId
            WITH SYSTEM_MODE LIMIT 1].Id;
        List<SABEmployeeCompensationService.EmploymentDTO> employments;
        Id awardId;
        String duplicate;
        System.runAs(fixtureUser(MAKER)) {
            SABTestGovernor.startTest();
            employments = SABEmployeeCompensationService.getEmployments(companyId, false);
            SABEmployeeCompensationService.BenefitAwardRequest award = new SABEmployeeCompensationService.BenefitAwardRequest();
            award.employmentId = employmentId;
            award.payComponentId = bonusId;
            award.awardKey = 'G10H-AWARD';
            award.amount = 250;
            award.currencyCode = 'BDT';
            award.servicePeriodStart = Date.newInstance(2026, 10, 1);
            awardId = SABEmployeeCompensationService.createBenefitAward(award);
            SABEmployeeCompensationService.approveBenefitAward(awardId);
            try {
                SABEmployeeCompensationService.createBenefitAward(award);
            } catch (SABEmployeeCompensationService.EmployeeCompensationException ex) {
                duplicate = ex.getMessage();
            }
            SABEmployeeCompensationService.approveAssignment(assignmentId);
            SABEmployeeCompensationService.cancelBenefitAward(awardId);
            SABTestGovernor.stopTest();
        }
        System.assertEquals(1, employments.size(), 'User-mode employment read returns the active employment.');
        System.assertEquals('Operations', employments[0].departmentName, 'Department name is readable to compensation users.');
        System.assert(duplicate != null && duplicate.contains('already exists'), 'Duplicate award key is caught by the complete read: ' + duplicate);
        System.assertEquals('Cancelled', [SELECT Status__c FROM Benefit_Award__c WHERE Id = :awardId WITH SYSTEM_MODE].Status__c,
            'Award approved, then cancelled.');
        System.assertEquals('Approved', [SELECT Status__c FROM Employee_Pay_Component__c WHERE Id = :assignmentId WITH SYSTEM_MODE].Status__c,
            'Draft compensation approved.');
    }

    @IsTest
    static void sharingTriggersDelegateToTheHandler() {
        Id companyId = companyId();
        Id expenseUserId = fixtureUser(EXPENSE).Id;
        Pay_Component__c component = new Pay_Component__c(Name = 'Overtime', Company__c = companyId, Component_Key__c = 'G10H-OT',
            Category__c = 'Other', Is_Active__c = true);
        Employment__c employment = [SELECT Id, End_Date__c FROM Employment__c WHERE Company__c = :companyId WITH SYSTEM_MODE LIMIT 1];
        SABTestGovernor.startTest();
        System.runAs(fixtureUser(MAKER)) {
            insert as system component;
            update as system new Pay_Component__c(Id = component.Id, Name = 'Overtime Pay');
            delete as system component;
            undelete as system component;
            update as system new Employment__c(Id = employment.Id, End_Date__c = Date.newInstance(2027, 12, 31));
        }
        SABTestGovernor.stopTest();
        System.assertEquals('Overtime Pay', [SELECT Name FROM Pay_Component__c WHERE Id = :component.Id WITH SYSTEM_MODE].Name,
            'Undeleted component is restored.');
        if (Schema.getGlobalDescribe().containsKey('Employment__Share')) {
            Integer shares = Database.countQueryWithBinds('SELECT COUNT() FROM Employment__Share WHERE ParentId = :parentId'
                + ' AND UserOrGroupId = :userId AND RowCause = \'Manual\'',
                new Map<String, Object>{'parentId' => employment.Id, 'userId' => expenseUserId}, AccessLevel.SYSTEM_MODE);
            System.assert(shares > 0, 'Company users keep their employment share after the handler refactor.');
        }
    }
}
