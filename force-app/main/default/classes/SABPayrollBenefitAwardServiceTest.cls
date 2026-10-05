@IsTest
private class SABPayrollBenefitAwardServiceTest {
    private static final String MAKER = 'SABG10FMaker';
    private static final String REVIEWER = 'SABG10F-Reviewer';
    private static final Date STARTS = Date.newInstance(2026, 10, 1);
    private static final Date ENDS = Date.newInstance(2026, 10, 31);
    private static final Set<String> MAKER_SETS = new Set<String>{'SAB_Payroll_Calculation_User', 'SAB_Payroll_Review_User',
        'SAB_Submit_Payroll_Action', 'SAB_Cancel_Payroll_Action', 'SAB_Payroll_Posting_User', 'SAB_Post_Payroll_Action',
        'SAB_Post_Journal_Action'};
    private static final Set<String> REVIEWER_SETS = new Set<String>{'SAB_Payroll_Review_User', 'SAB_Approve_Payroll_Action'};

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
        User preparer;
        User approver;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            preparer = newUser(MAKER, 'g10fmkr', unique);
            approver = newUser(REVIEWER, 'g10frev', unique);
            insert as system new List<User>{preparer, approver};
            Set<String> names = new Set<String>(MAKER_SETS);
            names.addAll(REVIEWER_SETS);
            Map<String, Id> setIds = new Map<String, Id>();
            for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN :names WITH SYSTEM_MODE]) {
                setIds.put(p.Name, p.Id);
            }
            System.assertEquals(names.size(), setIds.size(), 'Deploy every payroll permission set before running G10F tests.');
            List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
            for (String name : MAKER_SETS) {
                rows.add(new PermissionSetAssignment(AssigneeId = preparer.Id, PermissionSetId = setIds.get(name)));
            }
            for (String name : REVIEWER_SETS) {
                rows.add(new PermissionSetAssignment(AssigneeId = approver.Id, PermissionSetId = setIds.get(name)));
            }
            insert as system rows;
        }
        System.runAs(preparer) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'Benefit Award Test', Company_Key__c = 'F10',
                Country_Code__c = 'BD', Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active', Is_Active__c = true);
            insert as system company;
            insert as system new List<Company_User_Access__c>{
                new Company_User_Access__c(Company__c = company.Id, User__c = preparer.Id, Role__c = 'HR', Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'G10F-MAKER'),
                new Company_User_Access__c(Company__c = company.Id, User__c = approver.Id, Role__c = 'HR', Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'G10F-REVIEWER')
            };
            Map<String, GL_Account__c> accounts = new Map<String, GL_Account__c>{
                '6100' => gl(company.Id, '6100', 'Payroll Expense', 'Expense', 'Debit'),
                '6200' => gl(company.Id, '6200', 'Bonus Expense', 'Expense', 'Debit'),
                '2100' => gl(company.Id, '2100', 'Deduction Liability', 'Liability', 'Credit'),
                '2200' => gl(company.Id, '2200', 'Employer Liability', 'Liability', 'Credit'),
                '2300' => gl(company.Id, '2300', 'Salary Payable', 'Liability', 'Credit')
            };
            insert as system accounts.values();
            insert as system new Accounting_Period__c(Company__c = company.Id, Company_Period_Key__c = 'F10-OCT', Period_Key__c = '2026-10',
                Start_Date__c = STARTS, End_Date__c = ENDS, Fiscal_Year__c = 2026, Fiscal_Quarter__c = 4, Period_Number__c = 10,
                Status__c = 'Open');
            Employee__c employee = new Employee__c(Employee_Reference__c = 'G10F-EMP', Status__c = 'Active');
            insert as system employee;
            Employment__c employment = new Employment__c(Employee__c = employee.Id, Company__c = company.Id,
                Start_Date__c = Date.newInstance(2026, 1, 1), Employment_Status__c = 'Active');
            insert as system employment;
            Map<String, Pay_Component__c> components = new Map<String, Pay_Component__c>();
            for (String category : new List<String>{'Basic Salary', 'Food Allowance', 'Deduction', 'Employer Contribution', 'Incentive'}) {
                components.put(category, new Pay_Component__c(Name = category, Company__c = company.Id, Component_Key__c = 'G10F-' + category,
                    Category__c = category, Is_Active__c = true,
                    Expense_Account__c = category == 'Deduction' ? null : accounts.get(category == 'Incentive' ? '6200' : '6100').Id,
                    Liability_Account__c = category == 'Deduction' ? accounts.get('2100').Id
                        : (category == 'Employer Contribution' ? accounts.get('2200').Id : null)));
            }
            insert as system components.values();
            List<Employee_Pay_Component__c> assignments = new List<Employee_Pay_Component__c>();
            Map<String, Decimal> amounts = new Map<String, Decimal>{'Basic Salary' => 10000, 'Food Allowance' => 500,
                'Deduction' => 1000, 'Employer Contribution' => 250};
            for (String category : amounts.keySet()) {
                assignments.add(new Employee_Pay_Component__c(Employment__c = employment.Id, Pay_Component__c = components.get(category).Id,
                    Amount__c = amounts.get(category), Currency__c = 'BDT', Effective_From__c = Date.newInstance(2026, 1, 1),
                    Status__c = 'Approved'));
            }
            insert as system assignments;
            Id incentive = components.get('Incentive').Id;
            Id food = components.get('Food Allowance').Id;
            insert as system new List<Benefit_Award__c>{
                award(employment.Id, incentive, 'F10-BONUS', 2000, 'Approved', STARTS),
                award(employment.Id, food, 'F10-ARREARS', 125, 'Approved', null),
                award(employment.Id, incentive, 'F10-FUTURE', 999, 'Approved', Date.newInstance(2026, 11, 1)),
                award(employment.Id, incentive, 'F10-PROPOSED', 400, 'Proposed', STARTS),
                award(employment.Id, incentive, 'F10-CANCELLED', 500, 'Cancelled', STARTS)
            };
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static Benefit_Award__c award(Id employmentId, Id componentId, String key, Decimal amount, String status, Date serviceStart) {
        return new Benefit_Award__c(Employment__c = employmentId, Pay_Component__c = componentId, Award_Key__c = key,
            Amount__c = amount, Currency__c = 'BDT', Status__c = status, Service_Period_Start__c = serviceStart);
    }

    private static GL_Account__c gl(Id companyId, String code, String label, String type, String balance) {
        return new GL_Account__c(Name = label, Company__c = companyId, Company_Account_Key__c = String.valueOf(companyId) + '-' + code,
            Account_Code__c = code, Account_Type__c = type, Normal_Balance__c = balance, Is_Active__c = true,
            Is_Control_Account__c = false, Control_Type__c = 'None', Manual_Posting_Allowed__c = true);
    }

    private static User fixtureUser(String lastName) {
        if (!users.containsKey(lastName)) {
            users.put(lastName, [SELECT Id FROM User WHERE LastName = :lastName AND Alias LIKE 'g10f%' WITH SYSTEM_MODE LIMIT 1]);
        }
        return users.get(lastName);
    }

    private static Id cached(String key, String soql) {
        if (!ids.containsKey(key)) {
            ids.put(key, Database.query(soql).Id);
        }
        return ids.get(key);
    }

    private static Id companyId() {
        return cached('company', 'SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = \'F10\' WITH SYSTEM_MODE LIMIT 1');
    }

    private static Id employmentId() {
        return cached('employment', 'SELECT Id FROM Employment__c WHERE Company__r.Company_Key__c = \'F10\' WITH SYSTEM_MODE LIMIT 1');
    }

    private static Map<String, Benefit_Award__c> awards() {
        Map<String, Benefit_Award__c> result = new Map<String, Benefit_Award__c>();
        for (Benefit_Award__c a : [SELECT Id, Award_Key__c, Status__c, Consumed_By_Payroll_Run__c, Amount__c, Currency__c
                FROM Benefit_Award__c WHERE Award_Key__c LIKE 'F10-%' WITH SYSTEM_MODE]) {
            result.put(a.Award_Key__c, a);
        }
        return result;
    }

    private static Id calculatedRun(String key) {
        Id runId = SABPayrollCalculationService.createDraft(companyId(), STARTS, ENDS, 'BDT', key);
        SABPayrollCalculationService.calculate(runId, new List<Id>{employmentId()}, 2);
        return runId;
    }

    private static void rejectsCalculation(Id runId, String fragment) {
        String message;
        try {
            SABPayrollCalculationService.calculate(runId, new List<Id>{employmentId()}, 2);
        } catch (SABPayrollCalculationService.PayrollException ex) {
            message = ex.getMessage();
        }
        System.assert(message != null && message.contains(fragment), 'Expected "' + fragment + '" but got: ' + message);
    }

    private static void updateAward(Benefit_Award__c change) {
        update as system change;
    }

    // ---------------------------------------------------------------- tests

    @IsTest
    static void consumesEligibleAwardsIntoRun() {
        Id runId;
        System.runAs(fixtureUser(MAKER)) {
            SABTestGovernor.startTest();
            runId = calculatedRun('F10-RUN');
            SABTestGovernor.stopTest();
        }
        Payroll_Run__c run = [SELECT Workflow_State__c, Gross_Total__c, Deduction_Total__c, Net_Total__c FROM Payroll_Run__c
            WHERE Id = :runId WITH SYSTEM_MODE];
        System.assertEquals('Calculated', run.Workflow_State__c, 'Run is Calculated.');
        System.assertEquals(12625, run.Gross_Total__c, 'Gross = 10,500 fixed + 2,000 bonus + 125 arrears.');
        System.assertEquals(11625, run.Net_Total__c, 'Net includes both consumed awards.');
        List<Payroll_Component_Line__c> awardLines = [SELECT Amount__c, Rule_Version__c, Expense_Account__r.Account_Code__c,
            Benefit_Award__r.Award_Key__c, Eligibility_Snapshot__c FROM Payroll_Component_Line__c
            WHERE Payroll_Line__r.Payroll_Run__c = :runId AND Benefit_Award__c != null WITH SYSTEM_MODE ORDER BY Amount__c DESC];
        System.assertEquals(2, awardLines.size(), 'Only the two eligible awards are consumed.');
        System.assertEquals('F10-BONUS', awardLines[0].Benefit_Award__r.Award_Key__c, 'Bonus award line.');
        System.assertEquals(2000, awardLines[0].Amount__c, 'Bonus amount.');
        System.assertEquals('6200', awardLines[0].Expense_Account__r.Account_Code__c, 'Bonus uses its pay component expense account.');
        System.assertEquals('G10F_AWARD_V1', awardLines[0].Rule_Version__c, 'Award lines carry the G10F rule version.');
        System.assert(awardLines[0].Eligibility_Snapshot__c.contains('F10-BONUS'), 'Snapshot records the award key.');
        System.assertEquals('F10-ARREARS', awardLines[1].Benefit_Award__r.Award_Key__c, 'Undated award is paid as arrears.');
        Map<String, Benefit_Award__c> byKey = awards();
        for (String key : new List<String>{'F10-BONUS', 'F10-ARREARS'}) {
            System.assertEquals('Consumed', byKey.get(key).Status__c, key + ' is Consumed.');
            System.assertEquals(runId, byKey.get(key).Consumed_By_Payroll_Run__c, key + ' links the run.');
        }
        System.assertEquals('Approved', byKey.get('F10-FUTURE').Status__c, 'Future award waits for its period.');
        System.assertEquals(null, byKey.get('F10-FUTURE').Consumed_By_Payroll_Run__c, 'Future award is not linked.');
        System.assertEquals('Proposed', byKey.get('F10-PROPOSED').Status__c, 'Proposed award is ignored.');
        System.assertEquals('Cancelled', byKey.get('F10-CANCELLED').Status__c, 'Cancelled award is ignored.');
        System.assertEquals(1, [SELECT COUNT() FROM Business_Action__c WHERE Request_Key__c = :('PAYROLL|' + runId + '|AWARDS|CONSUMED')
            WITH SYSTEM_MODE], 'Consumption is audited once.');
    }

    @IsTest
    static void cancellationReleasesAwardsForNextRun() {
        Id firstRun;
        Id secondRun;
        System.runAs(fixtureUser(MAKER)) {
            SABTestGovernor.startTest();
            firstRun = calculatedRun('F10-FIRST');
            SABTestGovernor.step('first calculation');
            SABPayrollReviewService.cancel(firstRun, 'Wrong bonus batch');
            SABTestGovernor.step('cancel and release');
            SABTestGovernor.requireHeadroom(25, 'second calculation');
            secondRun = calculatedRun('F10-SECOND');
            SABTestGovernor.stopTest();
        }
        Map<String, Benefit_Award__c> byKey = awards();
        System.assertEquals('Consumed', byKey.get('F10-BONUS').Status__c, 'Released award is consumed by the next run.');
        System.assertEquals(secondRun, byKey.get('F10-BONUS').Consumed_By_Payroll_Run__c, 'Award now links the replacement run.');
        System.assertEquals(12625, [SELECT Gross_Total__c FROM Payroll_Run__c WHERE Id = :secondRun WITH SYSTEM_MODE].Gross_Total__c,
            'Replacement run pays the released awards.');
        System.assertEquals('Cancelled', [SELECT Workflow_State__c FROM Payroll_Run__c WHERE Id = :firstRun WITH SYSTEM_MODE].Workflow_State__c,
            'First run is Cancelled.');
        System.assertEquals(2, [SELECT COUNT() FROM Payroll_Component_Line__c WHERE Payroll_Line__r.Payroll_Run__c = :firstRun
            AND Benefit_Award__c != null WITH SYSTEM_MODE], 'Cancelled run keeps its award snapshots as history.');
        System.assertEquals(1, [SELECT COUNT() FROM Business_Action__c WHERE Request_Key__c = :('PAYROLL|' + firstRun + '|AWARDS|RELEASED')
            WITH SYSTEM_MODE], 'Release is audited once.');
    }

    @IsTest
    static void postedRunKeepsAwardsConsumedAndPostsAwardExpense() {
        Id runId;
        SABPayrollPostingService.PostingResult posted;
        SABTestGovernor.startTest();
        System.runAs(fixtureUser(MAKER)) {
            runId = calculatedRun('F10-POSTED');
            SABPayrollReviewService.submit(runId);
        }
        System.runAs(fixtureUser(REVIEWER)) {
            SABPayrollReviewService.approve(runId);
        }
        System.runAs(fixtureUser(MAKER)) {
            SABTestGovernor.step('calculate, submit, approve');
            SABTestGovernor.requireHeadroom(40, 'accrual posting');
            Id periodId = [SELECT Id FROM Accounting_Period__c WHERE Company_Period_Key__c = 'F10-OCT' WITH SYSTEM_MODE].Id;
            Id payable = [SELECT Id FROM GL_Account__c WHERE Account_Code__c = '2300' AND Company__c = :companyId() WITH SYSTEM_MODE].Id;
            posted = SABPayrollPostingService.post(runId, periodId, ENDS, payable, 'F10-ACCRUAL');
        }
        SABTestGovernor.stopTest();
        Map<String, Decimal> debits = new Map<String, Decimal>();
        Map<String, Decimal> credits = new Map<String, Decimal>();
        for (Journal_Entry_Line__c line : [SELECT GL_Account__r.Account_Code__c, Debit_Base__c, Credit_Base__c FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c = :posted.journalEntryId WITH SYSTEM_MODE]) {
            String code = line.GL_Account__r.Account_Code__c;
            debits.put(code, (debits.containsKey(code) ? debits.get(code) : 0) + line.Debit_Base__c);
            credits.put(code, (credits.containsKey(code) ? credits.get(code) : 0) + line.Credit_Base__c);
        }
        System.assertEquals(2000, debits.get('6200'), 'Bonus award posts to its own expense account.');
        System.assertEquals(10875, debits.get('6100'), 'Fixed pay, arrears award and employer contribution post to 6100.');
        System.assertEquals(11625, credits.get('2300'), 'Net payable includes the awards.');
        System.runAs(fixtureUser(MAKER)) {
            String message;
            try {
                SABPayrollReviewService.cancel(runId, 'Too late');
            } catch (SABPayrollReviewService.ReviewException ex) {
                message = ex.getMessage();
            }
            System.assert(message != null && message.contains('controlled reversal'), 'Posted payroll cannot be cancelled: ' + message);
        }
        System.assertEquals('Consumed', awards().get('F10-BONUS').Status__c, 'Posted awards stay Consumed.');
    }

    @IsTest
    static void guardBlocksDirectConsumptionChanges() {
        Map<String, Benefit_Award__c> byKey = awards();
        Benefit_Award__c bonus = byKey.get('F10-BONUS');
        List<Database.SaveResult> outside = Database.update(new List<Benefit_Award__c>{
            new Benefit_Award__c(Id = bonus.Id, Status__c = 'Consumed')}, false);
        System.assertEquals(false, outside[0].isSuccess(), 'Status cannot be set to Consumed directly.');
        System.assert(outside[0].getErrors()[0].getMessage().contains('controlled by payroll'), 'Guard explains the rule.');
        Benefit_Award__c forged = award(employmentId(), [SELECT Pay_Component__c FROM Benefit_Award__c WHERE Id = :bonus.Id
            WITH SYSTEM_MODE].Pay_Component__c, 'F10-FORGED', 10, 'Consumed', STARTS);
        System.assertEquals(false, Database.insert(forged, false).isSuccess(), 'A Consumed award cannot be inserted.');
        // G10A flows still work: approving a Proposed award is an ordinary update.
        Benefit_Award__c proposed = byKey.get('F10-PROPOSED');
        updateAward(new Benefit_Award__c(Id = proposed.Id, Status__c = 'Approved', Approved_By__c = UserInfo.getUserId(),
            Approved_At__c = System.now()));
        Id runId;
        System.runAs(fixtureUser(MAKER)) {
            SABTestGovernor.startTest();
            runId = calculatedRun('F10-GUARD');
            SABTestGovernor.stopTest();
        }
        System.assertEquals(13025, [SELECT Gross_Total__c FROM Payroll_Run__c WHERE Id = :runId WITH SYSTEM_MODE].Gross_Total__c,
            'Newly approved 400 award is consumed with the bonus and arrears awards.');
        List<Database.SaveResult> edits = Database.update(new List<Benefit_Award__c>{
            new Benefit_Award__c(Id = bonus.Id, Amount__c = 1),
            new Benefit_Award__c(Id = byKey.get('F10-ARREARS').Id, Status__c = 'Approved',
                Consumed_By_Payroll_Run__c = null)}, false);
        System.assertEquals(false, edits[0].isSuccess(), 'A consumed award cannot be edited.');
        System.assertEquals(false, edits[1].isSuccess(), 'A consumed award cannot be released directly.');
        System.assertEquals(false, Database.delete(bonus.Id, false).isSuccess(), 'A consumed award cannot be deleted.');
        System.assertEquals('Consumed', awards().get('F10-BONUS').Status__c, 'Award stays Consumed.');
    }

    @IsTest
    static void rejectsInvalidAwards() {
        Map<String, Benefit_Award__c> byKey = awards();
        Id bonusId = byKey.get('F10-BONUS').Id;
        Pay_Component__c incentive = [SELECT Id FROM Pay_Component__c WHERE Category__c = 'Incentive' AND Company__c = :companyId()
            WITH SYSTEM_MODE];
        System.runAs(fixtureUser(MAKER)) {
            SABTestGovernor.startTest();
            Id runId = SABPayrollCalculationService.createDraft(companyId(), STARTS, ENDS, 'BDT', 'F10-INVALID');
            updateAward(new Benefit_Award__c(Id = bonusId, Currency__c = 'USD'));
            rejectsCalculation(runId, 'currency must match');
            updateAward(new Benefit_Award__c(Id = bonusId, Currency__c = 'BDT', Amount__c = 0.001));
            rejectsCalculation(runId, 'rounds to zero');
            updateAward(new Benefit_Award__c(Id = bonusId, Amount__c = 2000));
            update as system new Pay_Component__c(Id = incentive.Id, Is_Active__c = false);
            rejectsCalculation(runId, 'inactive pay component');
            update as system new Pay_Component__c(Id = incentive.Id, Is_Active__c = true);
            SABTestGovernor.requireHeadroom(20, 'negative net case');
            update as system new Benefit_Award__c(Id = byKey.get('F10-ARREARS').Id, Pay_Component__c = [SELECT Id FROM Pay_Component__c
                WHERE Category__c = 'Deduction' AND Company__c = :companyId() WITH SYSTEM_MODE].Id, Amount__c = 20000);
            rejectsCalculation(runId, 'Deductions cannot exceed gross pay');
            SABTestGovernor.stopTest();
            System.assertEquals(0, [SELECT COUNT() FROM Payroll_Line__c WHERE Payroll_Run__c = :runId WITH SYSTEM_MODE],
                'Rejected calculations leave no snapshot rows.');
            System.assertEquals('Draft', [SELECT Workflow_State__c FROM Payroll_Run__c WHERE Id = :runId WITH SYSTEM_MODE].Workflow_State__c,
                'Run stays Draft.');
        }
        System.assertEquals('Approved', awards().get('F10-BONUS').Status__c, 'Rejected calculations consume nothing.');
    }

    @IsTest
    static void failsClosedOnHiddenAwardsAndRefusesUncancelledRelease() {
        Id visibleId = awards().get('F10-BONUS').Id;
        Id hiddenId = awards().get('F10-ARREARS').Id;
        String hidden;
        try {
            SABPayrollBenefitAwardService.assertComplete(new Set<Id>{visibleId}, new Set<Id>{visibleId, hiddenId});
        } catch (SABPayrollBenefitAwardService.BenefitAwardException ex) {
            hidden = ex.getMessage();
        }
        System.assert(hidden != null && hidden.contains('visibility is incomplete'), 'Hidden approved awards fail closed: ' + hidden);
        SABPayrollBenefitAwardService.assertComplete(new Set<Id>{visibleId}, new Set<Id>{visibleId});
        Id runId;
        String refused;
        Integer releasedFromDraft;
        System.runAs(fixtureUser(MAKER)) {
            SABTestGovernor.startTest();
            releasedFromDraft = SABPayrollBenefitAwardService.releaseForRun(
                SABPayrollCalculationService.createDraft(companyId(), STARTS, ENDS, 'BDT', 'F10-DRAFT'));
            runId = calculatedRun('F10-LIVE');
            try {
                SABPayrollBenefitAwardService.releaseForRun(runId);
            } catch (SABPayrollBenefitAwardService.BenefitAwardException ex) {
                refused = ex.getMessage();
            }
            SABTestGovernor.stopTest();
        }
        System.assertEquals(0, releasedFromDraft, 'A run that consumed nothing releases nothing.');
        System.assert(refused != null && refused.contains('only by cancelling'), 'A live run cannot release its awards: ' + refused);
        System.assertEquals('Consumed', awards().get('F10-BONUS').Status__c, 'Refused release leaves awards Consumed.');
        System.assertEquals(runId, awards().get('F10-BONUS').Consumed_By_Payroll_Run__c, 'Award still links the live run.');
    }
}
