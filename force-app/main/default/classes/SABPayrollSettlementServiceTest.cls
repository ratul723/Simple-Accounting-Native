@IsTest
private class SABPayrollSettlementServiceTest {
    private static final Date PAY_DATE = Date.newInstance(2026, 10, 31);
    private static final String MAKER = 'SABG10EMaker';
    private static final String REVIEWER = 'SABG10E-Reviewer';
    private static final String DUAL = 'SABG10EDual';
    private static final String NO_GRANT = 'SABG10ENoGrant';
    private static final Set<String> MAKER_SETS = new Set<String>{'SAB_Payroll_Calculation_User', 'SAB_Payroll_Review_User',
        'SAB_Submit_Payroll_Action', 'SAB_Cancel_Payroll_Action', 'SAB_Payroll_Posting_User', 'SAB_Post_Payroll_Action', 'SAB_Post_Journal_Action',
        'SAB_Payroll_Settlement_User', 'SAB_Process_Payroll_Payment_Action'};
    private static final Set<String> REVIEWER_SETS = new Set<String>{'SAB_Payroll_Review_User', 'SAB_Approve_Payroll_Action',
        'SAB_Payroll_Settlement_User', 'SAB_Authorize_Payroll_Payment_Action'};
    private static final Set<String> DUAL_SETS = new Set<String>{'SAB_Payroll_Settlement_User', 'SAB_Process_Payroll_Payment_Action',
        'SAB_Authorize_Payroll_Payment_Action', 'SAB_Post_Journal_Action'};
    private static final Set<String> NO_GRANT_SETS = new Set<String>{'SAB_Payroll_Settlement_User', 'SAB_Process_Payroll_Payment_Action'};

    // Fixture lookups run in system mode and are cached per test transaction to protect the SOQL budget.
    private static Map<String, User> users = new Map<String, User>();
    private static Map<String, Id> ids = new Map<String, Id>();

    // ------------------------------------------------------------- fixtures

    private static User fixtureUser(String lastName) {
        if (!users.containsKey(lastName)) {
            users.put(lastName, [SELECT Id FROM User WHERE LastName = :lastName AND Alias LIKE 'g10e%' WITH SYSTEM_MODE LIMIT 1]);
        }
        return users.get(lastName);
    }

    private static User newUser(String lastName, String alias, String unique) {
        return new User(Username = alias + '.' + unique + '@example.invalid', Email = alias + '@example.invalid',
            LastName = lastName, Alias = alias, TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = UserInfo.getProfileId());
    }

    // One PermissionSet query for every fixture user keeps @TestSetup cheap.
    private static void assignAll(Map<Id, Set<String>> setsByUser) {
        Set<String> names = new Set<String>();
        for (Set<String> userSets : setsByUser.values()) {
            names.addAll(userSets);
        }
        Map<String, Id> idsByName = new Map<String, Id>();
        for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN :names WITH SYSTEM_MODE]) {
            idsByName.put(p.Name, p.Id);
        }
        System.assertEquals(names.size(), idsByName.size(), 'Deploy the complete G10E manifest, including every permission set.');
        List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
        for (Id userId : setsByUser.keySet()) {
            for (String name : setsByUser.get(userId)) {
                rows.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = idsByName.get(name)));
            }
        }
        insert as system rows;
    }

    @TestSetup
    static void setupData() {
        User preparer;
        User approver;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            preparer = newUser(MAKER, 'g10emkr', unique);
            approver = newUser(REVIEWER, 'g10erev', unique);
            User both = newUser(DUAL, 'g10edul', unique);
            User outsider = newUser(NO_GRANT, 'g10enog', unique);
            insert as system new List<User>{preparer, approver, both, outsider};
            assignAll(new Map<Id, Set<String>>{preparer.Id => MAKER_SETS, approver.Id => REVIEWER_SETS,
                both.Id => DUAL_SETS, outsider.Id => NO_GRANT_SETS});
            users.put(DUAL, both);
        }
        System.runAs(preparer) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'Payroll Settlement Test', Company_Key__c = 'E10',
                Country_Code__c = 'BD', Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active', Is_Active__c = true);
            insert as system company;
            List<Company_User_Access__c> grants = new List<Company_User_Access__c>();
            Map<String, Id> granted = new Map<String, Id>{'G10E-MAKER' => preparer.Id, 'G10E-REVIEWER' => approver.Id,
                'G10E-DUAL' => users.get(DUAL).Id};
            for (String grantKey : granted.keySet()) {
                grants.add(new Company_User_Access__c(Company__c = company.Id, User__c = granted.get(grantKey), Role__c = 'HR',
                    Is_Active__c = true, Effective_From__c = Date.today().addDays(-1), Grant_Key__c = grantKey));
            }
            insert as system grants;
            Map<String, GL_Account__c> accounts = new Map<String, GL_Account__c>{
                '6100' => gl(company.Id, '6100', 'Payroll Expense', 'Expense', 'Debit'),
                '2100' => gl(company.Id, '2100', 'Deduction Liability', 'Liability', 'Credit'),
                '2200' => gl(company.Id, '2200', 'Employer Liability', 'Liability', 'Credit'),
                '2300' => gl(company.Id, '2300', 'Salary Payable', 'Liability', 'Credit'),
                '1100' => gl(company.Id, '1100', 'Operating Bank', 'Asset', 'Debit'),
                '1200' => gl(company.Id, '1200', 'USD Bank', 'Asset', 'Debit')
            };
            insert as system accounts.values();
            insert as system new List<Accounting_Period__c>{
                new Accounting_Period__c(Company__c = company.Id, Company_Period_Key__c = 'E10-OCT', Period_Key__c = '2026-10',
                    Start_Date__c = Date.newInstance(2026, 10, 1), End_Date__c = Date.newInstance(2026, 10, 31), Fiscal_Year__c = 2026,
                    Fiscal_Quarter__c = 4, Period_Number__c = 10, Status__c = 'Open'),
                new Accounting_Period__c(Company__c = company.Id, Company_Period_Key__c = 'E10-NOV', Period_Key__c = '2026-11',
                    Start_Date__c = Date.newInstance(2026, 11, 1), End_Date__c = Date.newInstance(2026, 11, 30), Fiscal_Year__c = 2026,
                    Fiscal_Quarter__c = 4, Period_Number__c = 11, Status__c = 'Closed', Closed_At__c = System.now(),
                    Closed_By__c = UserInfo.getUserId())
            };
            insert as system new List<Bank_Account__c>{
                new Bank_Account__c(Name = 'G10E Operating', Company__c = company.Id, Currency__c = 'BDT',
                    GL_Account__c = accounts.get('1100').Id, Is_Active__c = true),
                new Bank_Account__c(Name = 'G10E Dormant', Company__c = company.Id, Currency__c = 'BDT',
                    GL_Account__c = accounts.get('1100').Id, Is_Active__c = false),
                new Bank_Account__c(Name = 'G10E USD', Company__c = company.Id, Currency__c = 'USD',
                    GL_Account__c = accounts.get('1200').Id, Is_Active__c = true)
            };
            List<Employee__c> employees = new List<Employee__c>{
                new Employee__c(Employee_Reference__c = 'G10E-EMP-1', Status__c = 'Active'),
                new Employee__c(Employee_Reference__c = 'G10E-EMP-2', Status__c = 'Active')
            };
            insert as system employees;
            List<Employment__c> employments = new List<Employment__c>();
            for (Employee__c e : employees) {
                employments.add(new Employment__c(Employee__c = e.Id, Company__c = company.Id,
                    Start_Date__c = Date.newInstance(2026, 1, 1), Employment_Status__c = 'Active'));
            }
            insert as system employments;
            List<Pay_Component__c> components = new List<Pay_Component__c>();
            for (String category : new List<String>{'Basic Salary', 'Food Allowance', 'Deduction', 'Employer Contribution'}) {
                components.add(new Pay_Component__c(Name = category, Company__c = company.Id, Component_Key__c = 'G10E-' + category,
                    Category__c = category, Is_Active__c = true,
                    Expense_Account__c = category == 'Deduction' ? null : accounts.get('6100').Id,
                    Liability_Account__c = category == 'Deduction' ? accounts.get('2100').Id
                        : (category == 'Employer Contribution' ? accounts.get('2200').Id : null)));
            }
            insert as system components;
            seedApprovedRun(company.Id, employments, components, approver.Id);
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    // Approved two-employee snapshot exactly as G10B-G10C would produce it (9,500 net each), written through
    // the calculation write scope. Replaying the real chain here costs ~40 queries that every test would inherit.
    private static void seedApprovedRun(Id companyId, List<Employment__c> employments, List<Pay_Component__c> components, Id approverId) {
        List<Decimal> amounts = new List<Decimal>{10000, 500, 1000, 250};
        Payroll_Run__c run = new Payroll_Run__c(Company__c = companyId, Pay_Period_Start__c = Date.newInstance(2026, 10, 1),
            Pay_Period_End__c = Date.newInstance(2026, 10, 31), Currency__c = 'BDT', Run_Key__c = 'G10E-RUN', Version__c = 1,
            Workflow_State__c = 'Approved', Gross_Total__c = 21000, Deduction_Total__c = 2000, Employer_Total__c = 500,
            Net_Total__c = 19000, Submitted_By__c = UserInfo.getUserId(), Submitted_At__c = System.now(),
            Approved_By__c = approverId, Approved_At__c = System.now());
        SABPayrollCalculationService.writing = true;
        try {
            insert as system run;
            List<Payroll_Line__c> lines = new List<Payroll_Line__c>();
            for (Employment__c e : employments) {
                lines.add(new Payroll_Line__c(Payroll_Run__c = run.Id, Employment__c = e.Id, Gross_Amount__c = 10500,
                    Deduction_Amount__c = 1000, Employer_Contribution__c = 250, Net_Amount__c = 9500));
            }
            insert as system lines;
            List<Payroll_Component_Line__c> details = new List<Payroll_Component_Line__c>();
            for (Payroll_Line__c line : lines) {
                for (Integer i = 0; i < components.size(); i++) {
                    details.add(new Payroll_Component_Line__c(Payroll_Line__c = line.Id, Pay_Component__c = components[i].Id,
                        Amount__c = amounts[i], Component_Category__c = components[i].Category__c,
                        Expense_Account__c = components[i].Expense_Account__c, Liability_Account__c = components[i].Liability_Account__c,
                        Rule_Version__c = 'G10B_FIXED_V1'));
                }
            }
            insert as system details;
        } finally {
            SABPayrollCalculationService.writing = false;
        }
    }

    private static GL_Account__c gl(Id companyId, String code, String label, String type, String balance) {
        return new GL_Account__c(Name = label, Company__c = companyId, Company_Account_Key__c = String.valueOf(companyId) + '-' + code,
            Account_Code__c = code, Account_Type__c = type, Normal_Balance__c = balance, Is_Active__c = true,
            Is_Control_Account__c = false, Control_Type__c = 'None', Manual_Posting_Allowed__c = true);
    }

    private static Id runId() {
        if (!ids.containsKey('run')) {
            ids.put('run', [SELECT Id FROM Payroll_Run__c WHERE Run_Key__c = 'G10E-RUN' WITH SYSTEM_MODE].Id);
        }
        return ids.get('run');
    }

    private static Id companyId() {
        if (!ids.containsKey('company')) {
            ids.put('company', [SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = 'E10' WITH SYSTEM_MODE].Id);
        }
        return ids.get('company');
    }

    private static Id account(String code) {
        if (!ids.containsKey('gl' + code)) {
            ids.put('gl' + code, [SELECT Id FROM GL_Account__c WHERE Account_Code__c = :code AND Company__r.Company_Key__c = 'E10'
                WITH SYSTEM_MODE].Id);
        }
        return ids.get('gl' + code);
    }

    private static Id bank(String name) {
        if (!ids.containsKey('bank' + name)) {
            ids.put('bank' + name, [SELECT Id FROM Bank_Account__c WHERE Name = :name WITH SYSTEM_MODE].Id);
        }
        return ids.get('bank' + name);
    }

    private static Map<Id, Id> linesByEmployee() {
        Map<Id, Id> result = new Map<Id, Id>();
        for (Payroll_Line__c line : [SELECT Id, Employment__c FROM Payroll_Line__c WHERE Payroll_Run__c = :runId()
                WITH SYSTEM_MODE ORDER BY Employment__r.Employee__r.Employee_Reference__c]) {
            result.put(line.Id, line.Employment__c);
        }
        return result;
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

    // Real G10D accrual posting: heavy, so only ever call it alone inside Test.startTest()/stopTest().
    private static void postAccrual() {
        SABPayrollPostingService.post(runId(), [SELECT Id FROM Accounting_Period__c WHERE Company_Period_Key__c = 'E10-OCT'
            WITH SYSTEM_MODE].Id, PAY_DATE, account('2300'), 'G10E-ACCRUAL');
    }

    private static SABPayrollSettlementService.PaymentResult prepare(String key) {
        return SABPayrollSettlementService.preparePayment(runId(), bank('G10E Operating'), PAY_DATE, method(), 'OCT-NET-PAY', key);
    }

    private static Payroll_Run__c run() {
        return [SELECT Workflow_State__c, Settlement_Payment__c, Settled_Amount__c, Settled_By__c, Settled_At__c
            FROM Payroll_Run__c WHERE Id = :runId() WITH SYSTEM_MODE];
    }

    private static String paymentState(Id paymentId) {
        return [SELECT Processing_State__c FROM Accounting_Payment__c WHERE Id = :paymentId WITH SYSTEM_MODE].Processing_State__c;
    }

    private static void expect(Exception ex, String fragment) {
        expectText(ex.getMessage(), fragment);
    }

    private static void expectText(String message, String fragment) {
        System.assert(message != null && message.contains(fragment), 'Expected "' + fragment + '" but got: ' + message);
    }

    // ------------------------------------------------------------- seeding

    // Cheap stand-in for the G10D accrual (about 3 queries instead of a full posting chain):
    // a Posted PAYROLL_ACCRUAL event plus the run's posting audit fields, written through the service scope.
    private static void markPosted() {
        Accounting_Event__c accrual = new Accounting_Event__c(Company__c = companyId(), Adapter_Key__c = 'PAYROLL_ACCRUAL',
            Event_Key__c = 'PAYROLL|' + runId() + '|V1|ACCRUAL', Event_Type__c = 'Payroll', Source_Type__c = 'Payroll_Run__c',
            Source_Record_Id__c = String.valueOf(runId()), Source_Business_Key__c = 'G10E-RUN', Source_Version__c = 1,
            Created_Request_Key__c = 'G10E-ACCRUAL', State__c = 'Posted');
        insert as system accrual;
        seedRun(new Payroll_Run__c(Id = runId(), Workflow_State__c = 'Posted', Accounting_Event__c = accrual.Id,
            Accounting_Date__c = PAY_DATE, Net_Payable_Account__c = account('2300'), Posted_By__c = UserInfo.getUserId(),
            Posted_At__c = System.now(), Posting_Request_Key__c = 'G10E-ACCRUAL'));
        SABTestGovernor.step('seed posted run');
    }

    // Seeds a payroll payment in a given state through the trusted mutation scopes (no provider round trip).
    private static Id seedPayment(Decimal amount, String state, String providerKey) {
        Accounting_Payment__c payment = new Accounting_Payment__c(Company__c = companyId(), Bank_Account__c = bank('G10E Operating'),
            Direction__c = 'Disbursement', Method__c = method(), Amount__c = amount, Transaction_Currency__c = 'BDT',
            Functional_Currency__c = 'BDT', Exchange_Rate__c = 1, Effective_Date__c = PAY_DATE);
        insert as system payment;
        SABAccountingPaymentMutationContext.beginMutation();
        try {
            update as system new Accounting_Payment__c(Id = payment.Id, Processing_State__c = state, Provider_Request_Key__c = providerKey);
        } finally {
            SABAccountingPaymentMutationContext.endMutation();
        }
        insert as system new Business_Action__c(Company__c = companyId(), Action__c = 'PAYROLL_PAYMENT_LINKED',
            Action_At__c = System.now(), Request_Key__c = 'PAYROLLPAY|' + payment.Id, Source_Type__c = 'Payroll_Run__c',
            Source_Record_Id__c = String.valueOf(runId()), Source_Version__c = 1);
        return payment.Id;
    }

    private static void seedRun(Payroll_Run__c change) {
        SABPayrollSettlementService.permittedRunId = change.Id;
        try {
            update as system change;
        } finally {
            SABPayrollSettlementService.permittedRunId = null;
        }
    }

    private static List<Payroll_Settlement__c> seedSettlements(List<Payroll_Settlement__c> rows) {
        SABPayrollSettlementService.settlementWriteScope = true;
        try {
            insert as system rows;
        } finally {
            SABPayrollSettlementService.settlementWriteScope = false;
        }
        return rows;
    }

    private static Payroll_Settlement__c settlement(Id paymentId, Id lineId, Decimal amount, String status, Id reversalOf) {
        return new Payroll_Settlement__c(Payment__c = paymentId, Payroll_Line__c = lineId, Allocated_Amount__c = amount,
            Effective_Date__c = PAY_DATE, Status__c = status, Reversal_Of__c = reversalOf,
            Settlement_Key__c = 'SEED|' + lineId + '|' + status + '|' + amount);
    }

    // Fully settled run: one succeeded 19,000 payment, one Effective 9,500 settlement per employee.
    private static List<Payroll_Settlement__c> seedSettledRun() {
        Id paymentId = seedPayment(19000, 'Succeeded', 'SEED-PROVIDER');
        List<Payroll_Settlement__c> rows = new List<Payroll_Settlement__c>();
        for (Id lineId : linesByEmployee().keySet()) {
            rows.add(settlement(paymentId, lineId, 9500, 'Effective', null));
        }
        seedSettlements(rows);
        seedRun(new Payroll_Run__c(Id = runId(), Workflow_State__c = 'Settled', Settlement_Payment__c = paymentId,
            Settled_Amount__c = 19000, Settled_By__c = UserInfo.getUserId(), Settled_At__c = System.now()));
        return rows;
    }

    // ---------------------------------------------------------------- tests
    // Budget pattern: cheap seeding before startTest, one ledger posting per window, cheap checks after stopTest.

    @IsTest
    static void settlesTwoEmployeeRunEndToEnd() {
        Id paymentId;
        System.runAs(fixtureUser(MAKER)) {
            markPosted();
        }
        SABTestGovernor.startTest();
        System.runAs(fixtureUser(MAKER)) {
            SABPayrollSettlementService.PaymentResult prepared = prepare('E2E-PREPARE');
            SABTestGovernor.step('prepare');
            paymentId = prepared.paymentId;
            System.assertEquals(19000, prepared.amount, 'Payment must cover all outstanding net pay.');
            System.assertEquals('Draft', prepared.paymentState, 'Prepared payment starts Draft.');
        }
        System.runAs(fixtureUser(REVIEWER)) {
            System.assertEquals('Authorized', SABPayrollSettlementService.authorizePayment(runId(), 'E2E-AUTHORIZE').paymentState,
                'Authorizer moves the payment to Authorized.');
            SABTestGovernor.step('authorize');
        }
        SABPayrollSettlementService.PaymentResult paid;
        SABPayrollSettlementService.PaymentResult replay;
        System.runAs(fixtureUser(MAKER)) {
            SABPayrollSettlementService.submitPayment(runId(), 'BANK-BATCH-0001', 'E2E-SUBMIT');
            SABTestGovernor.step('submit');
            SABTestGovernor.requireHeadroom(40, 'record payment success');
            paid = SABPayrollSettlementService.recordPaymentSucceeded(runId(), 'E2E-PAID');
            SABTestGovernor.step('success');
            replay = SABPayrollSettlementService.recordPaymentSucceeded(runId(), 'E2E-PAID');
        }
        SABTestGovernor.stopTest();
        System.assertEquals(false, paid.replay, 'First success posts.');
        System.assertEquals(true, replay.replay, 'Same request key replays.');
        System.assertEquals(paid.journalEntryId, replay.journalEntryId, 'Replay returns the original journal.');
        System.assertEquals('Settled', paid.runState, 'Run settles with the payment.');
        Payroll_Run__c run = run();
        System.assertEquals('Settled', run.Workflow_State__c, 'Run must be Settled.');
        System.assertEquals(19000, run.Settled_Amount__c, 'Settled amount equals net pay.');
        System.assertEquals(fixtureUser(MAKER).Id, run.Settled_By__c, 'Settled By is the recording user.');
        System.assertNotEquals(null, run.Settled_At__c, 'Settled At is stamped.');
        Accounting_Payment__c payment = [SELECT Processing_State__c, Provider_Request_Key__c, Accounting_Event__r.Adapter_Key__c
            FROM Accounting_Payment__c WHERE Id = :paymentId WITH SYSTEM_MODE];
        System.assertEquals('Succeeded', payment.Processing_State__c, 'Payment must be Succeeded.');
        System.assertEquals('BANK-BATCH-0001', payment.Provider_Request_Key__c, 'Provider key is kept.');
        System.assertEquals('PAYROLL_PAYMENT', payment.Accounting_Event__r.Adapter_Key__c, 'Payment posts through PAYROLL_PAYMENT.');
        Map<String, Journal_Entry_Line__c> byCode = new Map<String, Journal_Entry_Line__c>();
        for (Journal_Entry_Line__c line : [SELECT GL_Account__r.Account_Code__c, Debit_Base__c, Credit_Base__c
                FROM Journal_Entry_Line__c WHERE Journal_Entry__c = :paid.journalEntryId WITH SYSTEM_MODE]) {
            byCode.put(line.GL_Account__r.Account_Code__c, line);
        }
        System.assertEquals(2, byCode.size(), 'Journal has a payable and a bank line.');
        System.assertEquals(19000, byCode.get('2300').Debit_Base__c, 'Dr Net Payable 2300.');
        System.assertEquals(19000, byCode.get('1100').Credit_Base__c, 'Cr Bank 1100.');
        List<Payroll_Settlement__c> settlements = [SELECT Id, Payroll_Line__c, Allocated_Amount__c, Status__c FROM Payroll_Settlement__c
            WHERE Payment__c = :paymentId WITH SYSTEM_MODE];
        System.assertEquals(2, settlements.size(), 'One settlement per employee line.');
        for (Payroll_Settlement__c s : settlements) {
            System.assertEquals('Effective', s.Status__c, 'Settlements are Effective.');
            System.assertEquals(9500, s.Allocated_Amount__c, 'Each employee receives 9,500.');
        }
        // Direct DML is blocked around the whole settlement lifecycle (guards run no queries).
        Database.SaveResult directInsert = Database.insert(settlement(paymentId, settlements[0].Payroll_Line__c, 1, 'Effective', null), false);
        System.assertEquals(false, directInsert.isSuccess(), 'Direct settlement insert must fail.');
        expectText(directInsert.getErrors()[0].getMessage(), 'payroll settlement service');
        System.assertEquals(false, Database.update(new Payroll_Settlement__c(Id = settlements[0].Id, Status__c = 'Failed'), false).isSuccess(),
            'Direct settlement update must fail.');
        System.assertEquals(false, Database.delete(settlements[0].Id, false).isSuccess(), 'Direct settlement delete must fail.');
        Database.SaveResult runUpdate = Database.update(new Payroll_Run__c(Id = runId(), Workflow_State__c = 'Posted'), false);
        System.assertEquals(false, runUpdate.isSuccess(), 'Direct run update must fail.');
        expectText(runUpdate.getErrors()[0].getMessage(), 'authorized payroll service');
    }

    @IsTest
    static void enforcesPermissionsAndStateOrder() {
        System.runAs(fixtureUser(MAKER)) {
            markPosted();
        }
        SABTestGovernor.startTest();
        System.runAs(fixtureUser(REVIEWER)) {
            System.assertEquals(false, FeatureManagement.checkPermission('SAB_Process_Payroll_Payment'), 'Reviewer lacks process.');
            try {
                prepare('ORDER-REVIEWER-PREPARE');
                System.assert(false, 'Authorizer must not prepare payments.');
            } catch (SABPermissionService.PermissionDeniedException ex) {
                expect(ex, 'processing permission');
            }
        }
        System.runAs(fixtureUser(MAKER)) {
            System.assertEquals(false, FeatureManagement.checkPermission('SAB_Authorize_Payroll_Payment'), 'Maker lacks authorize.');
            try {
                SABPayrollSettlementService.authorizePayment(runId(), 'ORDER-MAKER-AUTH');
                System.assert(false, 'Preparer must not hold authorization.');
            } catch (SABPermissionService.PermissionDeniedException ex) {
                expect(ex, 'authorization permission');
            }
            try {
                SABPayrollSettlementService.submitPayment(runId(), 'PROVIDER-EARLY', 'ORDER-SUBMIT-NONE');
                System.assert(false, 'Submit requires a payment.');
            } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                expect(ex, 'no open payment');
            }
            prepare('ORDER-PREPARE');
            SABTestGovernor.step('prepare');
            try {
                SABPayrollSettlementService.submitPayment(runId(), 'PROVIDER-EARLY', 'ORDER-SUBMIT-DRAFT');
                System.assert(false, 'Draft payment cannot be submitted.');
            } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                expect(ex, 'must be Authorized');
            }
            try {
                SABPayrollSettlementService.recordPaymentSucceeded(runId(), 'ORDER-PAID-DRAFT');
                System.assert(false, 'Draft payment cannot succeed.');
            } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                expect(ex, 'must be Submitted');
            }
        }
        System.runAs(fixtureUser(REVIEWER)) {
            SABTestGovernor.requireHeadroom(20, 'authorize payment');
            SABPayrollSettlementService.authorizePayment(runId(), 'ORDER-AUTH');
            try {
                SABPayrollSettlementService.submitPayment(runId(), 'PROVIDER-1', 'ORDER-REVIEWER-SUBMIT');
                System.assert(false, 'Authorizer must not submit.');
            } catch (SABPermissionService.PermissionDeniedException ex) {
                expect(ex, 'processing permission');
            }
        }
        System.runAs(fixtureUser(MAKER)) {
            SABTestGovernor.requireHeadroom(15, 'second prepare');
            try {
                prepare('ORDER-SECOND-PREPARE');
                System.assert(false, 'An in-flight payment blocks a second payment.');
            } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                expect(ex, 'in-flight');
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals('Authorized', paymentState(run().Settlement_Payment__c), 'Payment stays Authorized.');
    }

    @IsTest
    static void blocksSelfAuthorizationAndDuplicateProviderKey() {
        System.runAs(fixtureUser(MAKER)) {
            markPosted();
        }
        SABTestGovernor.startTest();
        System.runAs(fixtureUser(DUAL)) {
            System.assert(FeatureManagement.checkPermission('SAB_Process_Payroll_Payment'), 'Dual user holds process.');
            System.assert(FeatureManagement.checkPermission('SAB_Authorize_Payroll_Payment'), 'Dual user holds authorize.');
            prepare('SELF-PREPARE');
            try {
                SABPayrollSettlementService.authorizePayment(runId(), 'SELF-AUTH');
                System.assert(false, 'Preparer must not authorize their own payment.');
            } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                expect(ex, 'cannot authorize their own payment');
            }
        }
        System.assertEquals('Draft', paymentState(run().Settlement_Payment__c), 'Self-authorization changes nothing.');
        System.runAs(fixtureUser(REVIEWER)) {
            SABPayrollSettlementService.authorizePayment(runId(), 'SELF-REVIEWER-AUTH');
        }
        System.runAs(fixtureUser(MAKER)) {
            Accounting_Payment__c other = new Accounting_Payment__c(Company__c = companyId(), Bank_Account__c = bank('G10E Operating'),
                Direction__c = 'Disbursement', Method__c = method(), Amount__c = 1, Transaction_Currency__c = 'BDT',
                Effective_Date__c = PAY_DATE);
            insert as system other;
            SABAccountingPaymentMutationContext.beginMutation();
            try {
                update as system new Accounting_Payment__c(Id = other.Id, Provider_Request_Key__c = 'DUPLICATE-PROVIDER');
            } finally {
                SABAccountingPaymentMutationContext.endMutation();
            }
            SABTestGovernor.requireHeadroom(15, 'duplicate provider submit');
            try {
                SABPayrollSettlementService.submitPayment(runId(), 'DUPLICATE-PROVIDER', 'SELF-SUBMIT');
                System.assert(false, 'Provider key must be unique per company.');
            } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                expect(ex, 'Provider request key is already assigned');
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals('Authorized', paymentState(run().Settlement_Payment__c), 'Payment stays Authorized.');
    }

    @IsTest
    static void failedPaymentAllowsNewPaymentAndRequestKeysAreIdempotent() {
        System.runAs(fixtureUser(MAKER)) {
            markPosted();
            SABTestGovernor.startTest();
            SABPayrollSettlementService.PaymentResult first = prepare('KEY-PREPARE');
            SABPayrollSettlementService.PaymentResult replay = prepare('KEY-PREPARE');
            try {
                SABPayrollSettlementService.preparePayment(runId(), bank('G10E Operating'), PAY_DATE.addDays(-1), method(), null, 'KEY-PREPARE');
                System.assert(false, 'A reused key with different inputs must be rejected.');
            } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                expect(ex, 'different payroll payment request');
            }
            try {
                SABPayrollSettlementService.submitPayment(runId(), 'PROVIDER-MISUSE', 'KEY-PREPARE');
                System.assert(false, 'A key from another action must be rejected.');
            } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                expect(ex, 'different payroll action');
            }
            try {
                SABPayrollSettlementService.recordPaymentFailed(runId(), ' ', 'KEY-FAIL');
                System.assert(false, 'Failure reason is required.');
            } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                expect(ex, 'Reason is required');
            }
            SABPayrollSettlementService.PaymentResult failed =
                SABPayrollSettlementService.recordPaymentFailed(runId(), 'Bank rejected the batch file', 'KEY-FAIL');
            SABTestGovernor.step('prepare, replays, misuse, failure');
            SABTestGovernor.requireHeadroom(30, 'failure replay and second prepare');
            SABPayrollSettlementService.PaymentResult failedReplay =
                SABPayrollSettlementService.recordPaymentFailed(runId(), 'Bank rejected the batch file', 'KEY-FAIL');
            SABPayrollSettlementService.PaymentResult second = prepare('KEY-PREPARE-2');
            SABTestGovernor.stopTest();
            System.assertEquals(true, replay.replay, 'Same key replays.');
            System.assertEquals(first.paymentId, replay.paymentId, 'Replay returns the original payment.');
            System.assertEquals('Failed', failed.paymentState, 'Payment moves to Failed.');
            System.assertEquals(true, failedReplay.replay, 'Failure replays by key.');
            System.assertNotEquals(first.paymentId, second.paymentId, 'A new payment replaces the failed one.');
            System.assertEquals(19000, second.amount, 'Failed payment settled nothing.');
            System.assertEquals('Failed', paymentState(first.paymentId), 'Original stays Failed.');
            Payroll_Run__c run = run();
            System.assertEquals('Posted', run.Workflow_State__c, 'Run stays Posted.');
            System.assertEquals(second.paymentId, run.Settlement_Payment__c, 'Run links the new payment.');
            System.assertEquals(0, [SELECT COUNT() FROM Accounting_Event__c WHERE Adapter_Key__c = 'PAYROLL_PAYMENT' WITH SYSTEM_MODE],
                'Failure has no ledger impact.');
            System.assertEquals(1, [SELECT COUNT() FROM Business_Action__c WHERE Request_Key__c = 'KEY-FAIL' WITH SYSTEM_MODE],
                'Replay is not re-audited.');
        }
    }

    @IsTest
    static void bankReturnReversesCashAndReopensLine() {
        System.runAs(fixtureUser(MAKER)) {
            markPosted();
            List<Payroll_Settlement__c> settled = seedSettledRun();
            Id returnedId = settled[0].Id;
            SABTestGovernor.startTest();
            SABPayrollSettlementService.ReturnResult r =
                SABPayrollSettlementService.recordLineReturn(returnedId, PAY_DATE, 'Employee account closed', 'RETURN-1');
            SABTestGovernor.step('bank return');
            SABTestGovernor.requireHeadroom(30, 'return replay, second return and summary');
            SABPayrollSettlementService.ReturnResult replay =
                SABPayrollSettlementService.recordLineReturn(returnedId, PAY_DATE, 'Employee account closed', 'RETURN-1');
            try {
                SABPayrollSettlementService.recordLineReturn(returnedId, PAY_DATE, 'Second return', 'RETURN-2');
                System.assert(false, 'A settlement can be returned once.');
            } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                expect(ex, 'Only an Effective payroll settlement');
            }
            SABPayrollSettlementService.SettlementSummary summary = SABPayrollSettlementService.getSettlementSummary(runId());
            SABTestGovernor.stopTest();
            System.assertEquals(false, r.replay, 'First return posts.');
            System.assertEquals(true, replay.replay, 'Same key replays.');
            System.assertEquals(r.journalEntryId, replay.journalEntryId, 'Replay returns the original journal.');
            System.assertEquals(r.reversalSettlementId, replay.reversalSettlementId, 'Replay returns the original reversal.');
            System.assertEquals(9500, r.amount, 'One employee is returned.');
            Payroll_Run__c run = run();
            System.assertEquals('Posted', run.Workflow_State__c, 'Run reopens for re-payment.');
            System.assertEquals(9500, run.Settled_Amount__c, 'Only the other employee stays settled.');
            System.assertEquals(null, run.Settled_By__c, 'Settled audit is cleared on reopen.');
            Map<Id, Payroll_Settlement__c> rows = new Map<Id, Payroll_Settlement__c>([SELECT Id, Allocated_Amount__c, Status__c, Reversal_Of__c
                FROM Payroll_Settlement__c WHERE Id IN :new Set<Id>{returnedId, r.reversalSettlementId} WITH SYSTEM_MODE]);
            System.assertEquals('Failed', rows.get(returnedId).Status__c, 'Returned settlement is Failed.');
            Payroll_Settlement__c reversal = rows.get(r.reversalSettlementId);
            System.assertEquals(-9500, reversal.Allocated_Amount__c, 'Reversal row is negative.');
            System.assertEquals('Reversed', reversal.Status__c, 'Reversal row is Reversed.');
            System.assertEquals(returnedId, reversal.Reversal_Of__c, 'Reversal points to the original.');
            for (Journal_Entry_Line__c line : [SELECT GL_Account__r.Account_Code__c, Debit_Base__c, Credit_Base__c,
                    Journal_Entry__r.Accounting_Event__r.Adapter_Key__c FROM Journal_Entry_Line__c WHERE Journal_Entry__c = :r.journalEntryId
                    WITH SYSTEM_MODE]) {
                System.assertEquals(9500, line.GL_Account__r.Account_Code__c == '1100' ? line.Debit_Base__c : line.Credit_Base__c,
                    'Return journal is Dr Bank / Cr Net Payable 9,500.');
                System.assertEquals('PAYROLL_PAYMENT_RETURN', line.Journal_Entry__r.Accounting_Event__r.Adapter_Key__c,
                    'Return posts through PAYROLL_PAYMENT_RETURN.');
            }
            System.assertEquals(9500, summary.outstandingTotal, 'Returned net pay is outstanding again.');
            System.assertEquals(9500, summary.settledTotal, 'Other employee stays settled.');
            System.assertEquals('Succeeded', summary.paymentState, 'Original payment stays Succeeded.');
            for (SABPayrollSettlementService.LineSummary line : summary.lines) {
                System.assertEquals(line.payrollLineId == settled[0].Payroll_Line__c ? 9500 : 0, line.outstandingAmount,
                    'Only the returned line is outstanding.');
            }
        }
    }

    @IsTest
    static void returnedLineRepaysOnlyOutstandingNetPay() {
        Id returnedLine;
        System.runAs(fixtureUser(MAKER)) {
            markPosted();
            List<Id> lines = new List<Id>(linesByEmployee().keySet());
            returnedLine = lines[0];
            Id original = seedPayment(19000, 'Succeeded', 'SEED-PROVIDER');
            List<Payroll_Settlement__c> rows = seedSettlements(new List<Payroll_Settlement__c>{
                settlement(original, lines[0], 9500, 'Failed', null), settlement(original, lines[1], 9500, 'Effective', null)});
            seedSettlements(new List<Payroll_Settlement__c>{settlement(original, lines[0], -9500, 'Reversed', rows[0].Id)});
            seedRun(new Payroll_Run__c(Id = runId(), Workflow_State__c = 'Posted', Settlement_Payment__c = original, Settled_Amount__c = 9500));
        }
        SABTestGovernor.startTest();
        SABPayrollSettlementService.PaymentResult prepared;
        SABPayrollSettlementService.PaymentResult paid;
        System.runAs(fixtureUser(MAKER)) {
            prepared = prepare('REPAY-PREPARE');
            SABTestGovernor.step('prepare');
        }
        System.runAs(fixtureUser(REVIEWER)) {
            SABPayrollSettlementService.authorizePayment(runId(), 'REPAY-AUTH');
            SABTestGovernor.step('authorize');
        }
        System.runAs(fixtureUser(MAKER)) {
            SABPayrollSettlementService.submitPayment(runId(), 'BANK-BATCH-REPAY', 'REPAY-SUBMIT');
            SABTestGovernor.step('submit');
            SABTestGovernor.requireHeadroom(40, 'record re-payment success');
            paid = SABPayrollSettlementService.recordPaymentSucceeded(runId(), 'REPAY-PAID');
        }
        SABTestGovernor.stopTest();
        System.assertEquals(9500, prepared.amount, 'Re-payment covers only the returned employee.');
        System.assertEquals(9500, paid.amount, 'Success posts only 9,500.');
        Payroll_Run__c run = run();
        System.assertEquals('Settled', run.Workflow_State__c, 'Run settles again.');
        System.assertEquals(19000, run.Settled_Amount__c, 'Both employees are settled.');
        List<Payroll_Settlement__c> repaid = [SELECT Payroll_Line__c, Allocated_Amount__c FROM Payroll_Settlement__c
            WHERE Payment__c = :paid.paymentId WITH SYSTEM_MODE];
        System.assertEquals(1, repaid.size(), 'Only the returned line is settled again.');
        System.assertEquals(returnedLine, repaid[0].Payroll_Line__c, 'Re-payment targets the returned line.');
        System.assertEquals(9500, repaid[0].Allocated_Amount__c, 'Re-payment amount is 9,500.');
    }

    @IsTest
    static void rejectsInvalidPaymentSetup() {
        System.runAs(fixtureUser(MAKER)) {
            markPosted();
            Id runId = runId();
            Id operating = bank('G10E Operating');
            Id dormant = bank('G10E Dormant');
            Id usd = bank('G10E USD');
            String method = method();
            String longReference = 'R'.repeat(121);
            String longKey = 'K'.repeat(121);
            SABTestGovernor.startTest();
            Map<String, List<Object>> cases = new Map<String, List<Object>>{
                'required' => new List<Object>{null, operating, PAY_DATE, method, null, 'BAD-1'},
                'active Accounting Payment method' => new List<Object>{runId, operating, PAY_DATE, 'Carrier Pigeon', null, 'BAD-2'},
                'reference exceeds' => new List<Object>{runId, operating, PAY_DATE, method, longReference, 'BAD-3'},
                'Request key is required' => new List<Object>{runId, operating, PAY_DATE, method, null, longKey},
                'must be active' => new List<Object>{runId, dormant, PAY_DATE, method, null, 'BAD-5'},
                'functional currency' => new List<Object>{runId, usd, PAY_DATE, method, null, 'BAD-6'},
                'Open accounting period' => new List<Object>{runId, operating, Date.newInstance(2026, 11, 15), method, null, 'BAD-7'},
                'before the payroll accrual date' => new List<Object>{runId, operating, Date.newInstance(2026, 10, 30), method, null, 'BAD-8'}
            };
            for (String expected : cases.keySet()) {
                List<Object> c = cases.get(expected);
                SABTestGovernor.requireHeadroom(15, 'invalid setup case: ' + expected);
                try {
                    SABPayrollSettlementService.preparePayment((Id) c[0], (Id) c[1], (Date) c[2], (String) c[3], (String) c[4], (String) c[5]);
                    System.assert(false, 'Expected rejection: ' + expected);
                } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                    expect(ex, expected);
                }
                SABTestGovernor.step(expected);
            }
            SABTestGovernor.stopTest();
            System.assertEquals(null, run().Settlement_Payment__c, 'No payment is linked.');
            System.assertEquals(0, [SELECT COUNT() FROM Business_Action__c WHERE Request_Key__c LIKE 'BAD-%' WITH SYSTEM_MODE],
                'Rejected requests are not audited.');
        }
    }

    @IsTest
    static void rejectsUnpostedRun() {
        System.runAs(fixtureUser(MAKER)) {
            SABTestGovernor.startTest();
            try {
                prepare('UNPOSTED-PREPARE');
                System.assert(false, 'Approved payroll is not yet payable.');
            } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                expect(ex, 'Only a Posted payroll run');
            }
            SABPayrollSettlementService.SettlementSummary summary = SABPayrollSettlementService.getSettlementSummary(runId());
            SABTestGovernor.stopTest();
            System.assertEquals('Approved', summary.runState, 'Run is still Approved.');
            System.assertEquals(19000, summary.outstandingTotal, 'All net pay is outstanding.');
            System.assertEquals(2, summary.lines.size(), 'Two employee lines.');
            System.assertEquals(null, summary.paymentId, 'No payment yet.');
        }
    }

    @IsTest
    static void deniesUserWithoutCompanyGrant() {
        System.runAs(fixtureUser(MAKER)) {
            markPosted();
        }
        SABTestGovernor.startTest();
        Integer denied = 0;
        System.runAs(fixtureUser(NO_GRANT)) {
            System.assert(FeatureManagement.checkPermission('SAB_Process_Payroll_Payment'), 'Outsider holds process permission.');
            try {
                prepare('NO-GRANT-PREPARE');
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                denied++;
            }
            try {
                SABPayrollSettlementService.getSettlementSummary(runId());
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                denied++;
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals(2, denied, 'Both actions require a company grant.');
        System.assertEquals(null, run().Settlement_Payment__c, 'No payment is linked.');
    }

    @IsTest
    static void integrityCheckBlocksOverSettlement() {
        System.runAs(fixtureUser(MAKER)) {
            markPosted();
            Id paymentId = seedPayment(19000, 'Submitted', 'SEED-SUBMITTED');
            seedRun(new Payroll_Run__c(Id = runId(), Settlement_Payment__c = paymentId));
            Id lineId = new List<Id>(linesByEmployee().keySet())[0];
            // A settlement outside the service makes outstanding net pay disagree with the payment.
            seedSettlements(new List<Payroll_Settlement__c>{settlement(paymentId, lineId, 9500, 'Effective', null)});
            SABTestGovernor.startTest();
            try {
                SABPayrollSettlementService.recordPaymentSucceeded(runId(), 'INTEGRITY-PAID');
                System.assert(false, 'Over-settlement must be rejected.');
            } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                expect(ex, 'integrity check failed');
            }
            SABTestGovernor.stopTest();
            seedSettlements(new List<Payroll_Settlement__c>{settlement(paymentId, lineId, 1, 'Effective', null)});
            try {
                SABPayrollSettlementService.getSettlementSummary(runId());
                System.assert(false, 'Two Effective settlements on one line must be rejected.');
            } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                expect(ex, 'more than one Effective settlement');
            }
            System.assertEquals('Submitted', paymentState(paymentId), 'Payment stays Submitted.');
            System.assertEquals('Posted', run().Workflow_State__c, 'Run stays Posted.');
            System.assertEquals(0, [SELECT COUNT() FROM Accounting_Event__c WHERE Adapter_Key__c = 'PAYROLL_PAYMENT' WITH SYSTEM_MODE],
                'No payment journal is posted.');
        }
    }

    @IsTest
    static void settledRunReplaysAccrualAndRejectsFurtherPayment() {
        System.runAs(fixtureUser(MAKER)) {
            Id periodId = [SELECT Id FROM Accounting_Period__c WHERE Company_Period_Key__c = 'E10-OCT' WITH SYSTEM_MODE].Id;
            SABTestGovernor.startTest();
            // The real G10D accrual, then the settled state, then the replay and rejections in one window.
            postAccrual();
            SABTestGovernor.step('real accrual posting');
            seedSettledRun();
            SABTestGovernor.step('seed settled run');
            SABTestGovernor.requireHeadroom(35, 'settled replay and rejections');
            SABPayrollPostingService.PostingResult replay =
                SABPayrollPostingService.post(runId(), periodId, PAY_DATE, account('2300'), 'G10E-ACCRUAL');
            String prepareError;
            String failError;
            String cancelError;
            try {
                prepare('SETTLED-PREPARE');
            } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                prepareError = ex.getMessage();
            }
            try {
                SABPayrollSettlementService.recordPaymentFailed(runId(), 'Too late', 'SETTLED-FAIL');
            } catch (SABPayrollSettlementService.PayrollSettlementException ex) {
                failError = ex.getMessage();
            }
            try {
                SABPayrollReviewService.cancel(runId(), 'Cannot cancel settled payroll');
            } catch (SABPayrollReviewService.ReviewException ex) {
                cancelError = ex.getMessage();
            }
            SABTestGovernor.stopTest();
            System.assertEquals(true, replay.replay, 'A Settled run replays its accrual posting.');
            expectText(prepareError, 'already fully settled');
            expectText(failError, 'bank returns');
            expectText(cancelError, 'controlled reversal');
            System.assertEquals('Settled', run().Workflow_State__c, 'Run stays Settled.');
        }
    }

}
