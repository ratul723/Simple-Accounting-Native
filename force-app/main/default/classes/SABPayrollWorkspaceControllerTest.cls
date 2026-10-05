@IsTest
private class SABPayrollWorkspaceControllerTest {
    private static final String VIEWER = 'SABG10GViewer';
    private static final String NO_VIEW = 'SABG10GNoView';
    private static final String NO_GRANT = 'SABG10GNoGrant';
    private static final Date STARTS = Date.newInstance(2026, 10, 1);
    private static final Date ENDS = Date.newInstance(2026, 10, 31);

    private static Map<String, User> users = new Map<String, User>();

    // ------------------------------------------------------------- fixtures

    private static User newUser(String lastName, String alias, String unique) {
        return new User(Username = alias + '.' + unique + '@example.invalid', Email = alias + '@example.invalid',
            LastName = lastName, Alias = alias, TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = UserInfo.getProfileId());
    }

    @TestSetup
    static void setupData() {
        User viewerUser;
        User noViewUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            viewerUser = newUser(VIEWER, 'g10gvw', unique);
            noViewUser = newUser(NO_VIEW, 'g10gnv', unique);
            User noGrant = newUser(NO_GRANT, 'g10gng', unique);
            insert as system new List<User>{viewerUser, noViewUser, noGrant};
            Map<String, Id> sets = new Map<String, Id>();
            for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN ('SAB_Payroll_Workspace_User',
                    'SAB_Process_Payroll_Payment_Action', 'SAB_Employee_Compensation_User', 'SAB_Approve_Employee_Compensation_Action')
                    WITH SYSTEM_MODE]) {
                sets.put(p.Name, p.Id);
            }
            System.assertEquals(4, sets.size(), 'Deploy SAB_Payroll_Workspace_User with the G10A and G10E permission sets.');
            insert as system new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = viewerUser.Id, PermissionSetId = sets.get('SAB_Payroll_Workspace_User')),
                new PermissionSetAssignment(AssigneeId = viewerUser.Id, PermissionSetId = sets.get('SAB_Process_Payroll_Payment_Action')),
                new PermissionSetAssignment(AssigneeId = noGrant.Id, PermissionSetId = sets.get('SAB_Payroll_Workspace_User')),
                // HR approver persona: compensation access without payroll detail.
                new PermissionSetAssignment(AssigneeId = noViewUser.Id, PermissionSetId = sets.get('SAB_Employee_Compensation_User')),
                new PermissionSetAssignment(AssigneeId = noViewUser.Id, PermissionSetId = sets.get('SAB_Approve_Employee_Compensation_Action'))
            };
        }
        System.runAs(viewerUser) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'Workspace Test', Company_Key__c = 'G10',
                Country_Code__c = 'BD', Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active', Is_Active__c = true);
            insert as system company;
            insert as system new List<Company_User_Access__c>{
                new Company_User_Access__c(Company__c = company.Id, User__c = viewerUser.Id, Role__c = 'HR', Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'G10G-VIEWER'),
                new Company_User_Access__c(Company__c = company.Id, User__c = noViewUser.Id, Role__c = 'HR', Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'G10G-NOVIEW')
            };
            Map<String, GL_Account__c> accounts = new Map<String, GL_Account__c>{
                '6100' => gl(company.Id, '6100', 'Payroll Expense', 'Expense', 'Debit'),
                '2300' => gl(company.Id, '2300', 'Salary Payable', 'Liability', 'Credit'),
                '1100' => gl(company.Id, '1100', 'Operating Bank', 'Asset', 'Debit')
            };
            insert as system accounts.values();
            insert as system new List<Accounting_Period__c>{
                new Accounting_Period__c(Company__c = company.Id, Company_Period_Key__c = 'G10-OCT', Period_Key__c = '2026-10',
                    Start_Date__c = STARTS, End_Date__c = ENDS, Fiscal_Year__c = 2026, Fiscal_Quarter__c = 4, Period_Number__c = 10,
                    Status__c = 'Open'),
                new Accounting_Period__c(Company__c = company.Id, Company_Period_Key__c = 'G10-NOV', Period_Key__c = '2026-11',
                    Start_Date__c = Date.newInstance(2026, 11, 1), End_Date__c = Date.newInstance(2026, 11, 30), Fiscal_Year__c = 2026,
                    Fiscal_Quarter__c = 4, Period_Number__c = 11, Status__c = 'Closed', Closed_At__c = System.now(),
                    Closed_By__c = UserInfo.getUserId())
            };
            Bank_Account__c operating = new Bank_Account__c(Name = 'G10G Operating', Company__c = company.Id, Currency__c = 'BDT',
                GL_Account__c = accounts.get('1100').Id, Is_Active__c = true);
            insert as system new List<Bank_Account__c>{operating,
                new Bank_Account__c(Name = 'G10G Dormant', Company__c = company.Id, Currency__c = 'BDT',
                    GL_Account__c = accounts.get('1100').Id, Is_Active__c = false),
                new Bank_Account__c(Name = 'G10G USD', Company__c = company.Id, Currency__c = 'USD',
                    GL_Account__c = accounts.get('1100').Id, Is_Active__c = true)};
            List<Employee__c> employees = new List<Employee__c>{
                new Employee__c(Employee_Reference__c = 'G10G-EMP-1', Status__c = 'Active'),
                new Employee__c(Employee_Reference__c = 'G10G-EMP-2', Status__c = 'Active')};
            insert as system employees;
            Employment__c active = new Employment__c(Employee__c = employees[0].Id, Company__c = company.Id,
                Start_Date__c = Date.newInstance(2026, 1, 1), Employment_Status__c = 'Active');
            Employment__c ended = new Employment__c(Employee__c = employees[1].Id, Company__c = company.Id,
                Start_Date__c = Date.newInstance(2025, 1, 1), End_Date__c = Date.newInstance(2025, 12, 31), Employment_Status__c = 'Ended');
            insert as system new List<Employment__c>{active, ended};
            Pay_Component__c basic = new Pay_Component__c(Name = 'Basic Salary', Company__c = company.Id, Component_Key__c = 'G10G-BASIC',
                Category__c = 'Basic Salary', Is_Active__c = true, Expense_Account__c = accounts.get('6100').Id);
            Pay_Component__c bonus = new Pay_Component__c(Name = 'Bonus', Company__c = company.Id, Component_Key__c = 'G10G-BONUS',
                Category__c = 'Incentive', Is_Active__c = true, Expense_Account__c = accounts.get('6100').Id);
            insert as system new List<Pay_Component__c>{basic, bonus};
            insert as system new List<Employee_Pay_Component__c>{
                new Employee_Pay_Component__c(Employment__c = active.Id, Pay_Component__c = basic.Id, Amount__c = 10000,
                    Currency__c = 'BDT', Effective_From__c = Date.newInstance(2026, 1, 1), Status__c = 'Approved'),
                new Employee_Pay_Component__c(Employment__c = active.Id, Pay_Component__c = bonus.Id, Amount__c = 750,
                    Currency__c = 'BDT', Effective_From__c = Date.newInstance(2026, 11, 1), Status__c = 'Draft')};
            seedRuns(company.Id, active.Id, basic.Id, bonus.Id, operating.Id);
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    // Approved run (one consumed award) and a Settled run (paid by one succeeded payment), seeded through the
    // service write scopes so the setup does not replay G10B-G10F.
    private static void seedRuns(Id companyId, Id employmentId, Id basicId, Id bonusId, Id bankId) {
        Payroll_Run__c approved = run(companyId, 'G10G-APPROVED', 'Approved', 10500, STARTS, ENDS);
        Payroll_Run__c settled = run(companyId, 'G10G-SETTLED', 'Settled', 10000, Date.newInstance(2026, 9, 1), Date.newInstance(2026, 9, 30));
        settled.Settled_Amount__c = 10000;
        SABPayrollCalculationService.writing = true;
        try {
            insert as system new List<Payroll_Run__c>{approved, settled};
            Payroll_Line__c approvedLine = line(approved.Id, employmentId, 10500);
            Payroll_Line__c settledLine = line(settled.Id, employmentId, 10000);
            insert as system new List<Payroll_Line__c>{approvedLine, settledLine};
            SABPayrollBenefitAwardService.awardWriteScope = true;
            Benefit_Award__c consumed = award(employmentId, bonusId, 'G10G-CONSUMED', 500, 'Consumed', approved.Id);
            insert as system new List<Benefit_Award__c>{consumed,
                award(employmentId, bonusId, 'G10G-PROPOSED', 300, 'Proposed', null),
                award(employmentId, bonusId, 'G10G-APPROVED', 200, 'Approved', null),
                award(employmentId, bonusId, 'G10G-CANCELLED', 100, 'Cancelled', null)};
            SABPayrollBenefitAwardService.awardWriteScope = false;
            insert as system new List<Payroll_Component_Line__c>{
                component(approvedLine.Id, basicId, null, 10000, 'Basic Salary'),
                component(approvedLine.Id, bonusId, consumed.Id, 500, 'Incentive'),
                component(settledLine.Id, basicId, null, 10000, 'Basic Salary')};
            Accounting_Payment__c payment = new Accounting_Payment__c(Company__c = companyId, Bank_Account__c = bankId,
                Direction__c = 'Disbursement', Amount__c = 10000, Transaction_Currency__c = 'BDT', Effective_Date__c = Date.newInstance(2026, 9, 30),
                Reference__c = 'SEP-NET-PAY');
            insert as system payment;
            SABAccountingPaymentMutationContext.beginMutation();
            try {
                update as system new Accounting_Payment__c(Id = payment.Id, Processing_State__c = 'Succeeded', Provider_Request_Key__c = 'G10G-BANK');
            } finally {
                SABAccountingPaymentMutationContext.endMutation();
            }
            update as system new Payroll_Run__c(Id = settled.Id, Settlement_Payment__c = payment.Id);
            SABPayrollSettlementService.settlementWriteScope = true;
            insert as system new Payroll_Settlement__c(Payment__c = payment.Id, Payroll_Line__c = settledLine.Id, Allocated_Amount__c = 10000,
                Effective_Date__c = Date.newInstance(2026, 9, 30), Status__c = 'Effective', Settlement_Key__c = 'G10G|SEED|SETTLED');
            SABPayrollSettlementService.settlementWriteScope = false;
        } finally {
            SABPayrollCalculationService.writing = false;
            SABPayrollBenefitAwardService.awardWriteScope = false;
            SABPayrollSettlementService.settlementWriteScope = false;
        }
    }

    private static Payroll_Run__c run(Id companyId, String key, String state, Decimal net, Date starts, Date ends) {
        return new Payroll_Run__c(Company__c = companyId, Pay_Period_Start__c = starts, Pay_Period_End__c = ends, Currency__c = 'BDT',
            Run_Key__c = key, Version__c = 1, Workflow_State__c = state, Gross_Total__c = net, Deduction_Total__c = 0,
            Employer_Total__c = 0, Net_Total__c = net, Accounting_Date__c = ends);
    }

    private static Payroll_Line__c line(Id runId, Id employmentId, Decimal net) {
        return new Payroll_Line__c(Payroll_Run__c = runId, Employment__c = employmentId, Gross_Amount__c = net,
            Deduction_Amount__c = 0, Employer_Contribution__c = 0, Net_Amount__c = net);
    }

    private static Payroll_Component_Line__c component(Id lineId, Id componentId, Id awardId, Decimal amount, String category) {
        return new Payroll_Component_Line__c(Payroll_Line__c = lineId, Pay_Component__c = componentId, Benefit_Award__c = awardId,
            Amount__c = amount, Component_Category__c = category, Rule_Version__c = awardId == null ? 'G10B_FIXED_V1' : 'G10F_AWARD_V1');
    }

    private static Benefit_Award__c award(Id employmentId, Id componentId, String key, Decimal amount, String status, Id runId) {
        return new Benefit_Award__c(Employment__c = employmentId, Pay_Component__c = componentId, Award_Key__c = key, Amount__c = amount,
            Currency__c = 'BDT', Status__c = status, Service_Period_Start__c = STARTS, Consumed_By_Payroll_Run__c = runId);
    }

    private static GL_Account__c gl(Id companyId, String code, String label, String type, String balance) {
        return new GL_Account__c(Name = label, Company__c = companyId, Company_Account_Key__c = String.valueOf(companyId) + '-' + code,
            Account_Code__c = code, Account_Type__c = type, Normal_Balance__c = balance, Is_Active__c = true,
            Is_Control_Account__c = false, Control_Type__c = 'None', Manual_Posting_Allowed__c = true);
    }

    private static User fixtureUser(String lastName) {
        if (!users.containsKey(lastName)) {
            users.put(lastName, [SELECT Id FROM User WHERE LastName = :lastName AND Alias LIKE 'g10g%' WITH SYSTEM_MODE LIMIT 1]);
        }
        return users.get(lastName);
    }

    private static Id companyId() {
        return [SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = 'G10' WITH SYSTEM_MODE].Id;
    }

    private static Id runId(String key) {
        return [SELECT Id FROM Payroll_Run__c WHERE Run_Key__c = :key WITH SYSTEM_MODE].Id;
    }

    // ---------------------------------------------------------------- tests

    @IsTest
    static void workspaceListsCompanyScopedReadModels() {
        Id companyId = companyId();
        SABPayrollWorkspaceController.WorkspaceDTO ws;
        System.runAs(fixtureUser(VIEWER)) {
            SABTestGovernor.startTest();
            ws = SABPayrollWorkspaceController.getWorkspace(companyId);
            SABTestGovernor.stopTest();
        }
        System.assertEquals('Workspace Test', ws.companyName, 'Company name is returned.');
        System.assertEquals('BDT', ws.functionalCurrency, 'Functional currency is returned.');
        System.assertEquals(2, ws.runs.size(), 'Both runs are listed.');
        System.assertEquals('G10G-APPROVED', ws.runs[0].runKey, 'Newest period first.');
        System.assertEquals('Succeeded', ws.runs[1].paymentState, 'Settled run shows its payment state.');
        System.assertEquals(0, ws.runs[1].outstandingAmount, 'Settled run has nothing outstanding.');
        System.assertEquals(0, ws.outstandingNetPay, 'No net pay is outstanding.');
        Map<String, Integer> counts = new Map<String, Integer>();
        for (SABPayrollWorkspaceController.StateCount c : ws.stateCounts) {
            counts.put(c.state, c.count);
        }
        System.assertEquals(1, counts.get('Approved'), 'One Approved run.');
        System.assertEquals(1, counts.get('Settled'), 'One Settled run.');
        System.assertEquals(0, counts.get('Draft'), 'Every state is reported, including zero counts.');
        System.assertEquals(1, ws.employments.size(), 'Only active employments can be calculated.');
        System.assertEquals('G10G-EMP-1', ws.employments[0].employeeReference, 'Employee reference is shown.');
        System.assertEquals(1, ws.openPeriods.size(), 'Only Open periods are offered.');
        System.assertEquals(ENDS, ws.openPeriods[0].endDate, 'Period dates drive the default posting period.');
        System.assertEquals(1, ws.payableAccounts.size(), 'Only active Liability accounts are offered for net payable.');
        System.assertEquals(1, ws.bankAccounts.size(), 'Only active functional-currency banks are offered.');
        System.assert(ws.bankAccounts[0].label.startsWith('G10G Operating'), 'Operating bank is offered.');
        System.assert(!ws.paymentMethods.isEmpty(), 'Payment methods come from the live picklist.');
        System.assertEquals(true, ws.capabilities.processPayment, 'Capability flags follow custom permissions.');
        System.assertEquals(false, ws.capabilities.authorizePayment, 'Missing permissions are reported as false.');
    }

    @IsTest
    static void runDetailShowsLinesAwardsAndSettlement() {
        Id approvedId = runId('G10G-APPROVED');
        Id settledId = runId('G10G-SETTLED');
        SABPayrollWorkspaceController.RunDetailDTO approved;
        SABPayrollWorkspaceController.RunDetailDTO settled;
        System.runAs(fixtureUser(VIEWER)) {
            SABTestGovernor.startTest();
            approved = SABPayrollWorkspaceController.getRunDetail(approvedId);
            settled = SABPayrollWorkspaceController.getRunDetail(settledId);
            SABTestGovernor.stopTest();
        }
        System.assertEquals('Approved', approved.run.state, 'Approved run detail.');
        System.assertEquals(1, approved.lines.size(), 'One employee line.');
        System.assertEquals(10500, approved.lines[0].netAmount, 'Line net is shown.');
        System.assertEquals(0, approved.lines[0].outstandingAmount, 'Unposted runs show no settlement balance.');
        System.assertEquals(1, approved.awards.size(), 'Consumed award is listed.');
        System.assertEquals('G10G-CONSUMED', approved.awards[0].awardKey, 'Award key is shown.');
        System.assertEquals(null, approved.payment, 'No payment yet.');
        System.assertEquals(10000, settled.lines[0].settledAmount, 'Settled amount comes from the settlement service.');
        System.assertEquals(0, settled.lines[0].outstandingAmount, 'Nothing outstanding.');
        System.assertNotEquals(null, settled.lines[0].effectiveSettlementId, 'Effective settlement is exposed for bank returns.');
        System.assertEquals('Succeeded', settled.payment.state, 'Payment state is shown.');
        System.assertEquals('G10G Operating', settled.payment.bankAccountName, 'Payment bank is shown.');
        System.assertEquals('SEP-NET-PAY', settled.payment.reference, 'Payment reference is shown.');
    }

    @IsTest
    static void hrQueueListsPendingCompensationAndOpenAwards() {
        Id companyId = companyId();
        SABPayrollWorkspaceController.HrQueueDTO queue;
        SABPayrollWorkspaceController.HrQueueDTO approverQueue;
        System.runAs(fixtureUser(VIEWER)) {
            SABTestGovernor.startTest();
            queue = SABPayrollWorkspaceController.getHrQueue(companyId);
        }
        System.runAs(fixtureUser(NO_VIEW)) {
            // A compensation approver without payroll detail still gets the HR queue.
            approverQueue = SABPayrollWorkspaceController.getHrQueue(companyId);
            SABTestGovernor.stopTest();
        }
        System.assertEquals(1, queue.pendingAssignments.size(), 'Only Draft compensation is pending.');
        System.assertEquals(750, queue.pendingAssignments[0].amount, 'Pending amount is shown.');
        Set<String> keys = new Set<String>();
        for (SABPayrollWorkspaceController.AwardDTO a : queue.awards) {
            keys.add(a.awardKey);
        }
        System.assertEquals(new Set<String>{'G10G-PROPOSED', 'G10G-APPROVED', 'G10G-CONSUMED'}, keys,
            'Proposed, Approved and Consumed awards are listed; Cancelled are not.');
        System.assertEquals(queue.awards.size(), approverQueue.awards.size(), 'Approver sees the same queue.');
    }

    @IsTest
    static void enforcesPermissionAndCompanyAccess() {
        Id companyId = companyId();
        Id approvedId = runId('G10G-APPROVED');
        List<String> failures = new List<String>();
        SABTestGovernor.startTest();
        System.runAs(fixtureUser(NO_VIEW)) {
            try {
                SABPayrollWorkspaceController.getWorkspace(companyId);
            } catch (SABPermissionService.PermissionDeniedException ex) {
                failures.add('workspace-permission');
            }
            try {
                SABPayrollWorkspaceController.getRunDetail(approvedId);
            } catch (SABPermissionService.PermissionDeniedException ex) {
                failures.add('detail-permission');
            }
        }
        System.runAs(fixtureUser(NO_GRANT)) {
            try {
                SABPayrollWorkspaceController.getWorkspace(companyId);
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                failures.add('workspace-company');
            }
            try {
                SABPayrollWorkspaceController.getRunDetail(approvedId);
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                failures.add('detail-company');
            }
            try {
                SABPayrollWorkspaceController.getHrQueue(companyId);
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                failures.add('hr-company');
            }
        }
        System.runAs(fixtureUser(VIEWER)) {
            for (Integer i = 0; i < 3; i++) {
                try {
                    if (i == 0) {
                        SABPayrollWorkspaceController.getWorkspace(null);
                    } else if (i == 1) {
                        SABPayrollWorkspaceController.getRunDetail(null);
                    } else {
                        SABPayrollWorkspaceController.getHrQueue(null);
                    }
                } catch (SABPayrollWorkspaceController.PayrollWorkspaceException ex) {
                    failures.add('required-' + i);
                }
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals(new List<String>{'workspace-permission', 'detail-permission', 'workspace-company', 'detail-company',
            'hr-company', 'required-0', 'required-1', 'required-2'}, failures, 'Every unauthorized or incomplete request is refused.');
    }

    @IsTest
    static void hrQueueRequiresSomeCompensationOrPayrollPermission() {
        Id companyId = companyId();
        String message;
        User bare = new User(Id = UserInfo.getUserId());
        SABTestGovernor.startTest();
        System.runAs(bare) {
            if (!FeatureManagement.checkPermission('SAB_View_Payroll_Detail')
                && !FeatureManagement.checkPermission('SAB_Manage_Employee_Compensation')
                && !FeatureManagement.checkPermission('SAB_Approve_Employee_Compensation')) {
                try {
                    SABPayrollWorkspaceController.getHrQueue(companyId);
                } catch (SABPermissionService.PermissionDeniedException ex) {
                    message = ex.getMessage();
                }
                System.assert(message != null && message.contains('compensation permission'), 'HR queue needs a permission: ' + message);
            }
        }
        SABTestGovernor.stopTest();
        SABPayrollWorkspaceController.Capabilities caps = SABPayrollWorkspaceController.capabilities();
        System.assertNotEquals(null, caps.calculate, 'Every capability flag is populated.');
        System.assertNotEquals(null, caps.approveCompensation, 'Every capability flag is populated.');
    }
}
