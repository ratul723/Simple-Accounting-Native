@IsTest
private class SABPayrollRulesCalculationTest {
    private static final String MAKER = 'SABG10IMaker';
    private static final Date STARTS = Date.newInstance(2026, 10, 1);
    private static final Date ENDS = Date.newInstance(2026, 10, 31);

    private static Map<String, Id> ids = new Map<String, Id>();
    private static User makerUser;

    // ------------------------------------------------------------- fixtures

    @TestSetup
    static void setupData() {
        User preparer;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            preparer = new User(Username = 'g10imkr.' + unique + '@example.invalid', Email = 'g10imkr@example.invalid',
                LastName = MAKER, Alias = 'g10imkr', TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = UserInfo.getProfileId());
            insert as system preparer;
            PermissionSet calc = [SELECT Id FROM PermissionSet WHERE Name = 'SAB_Payroll_Calculation_User' WITH SYSTEM_MODE];
            insert as system new PermissionSetAssignment(AssigneeId = preparer.Id, PermissionSetId = calc.Id);
        }
        System.runAs(preparer) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'Rules Test', Company_Key__c = 'I10',
                Country_Code__c = 'BD', Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active', Is_Active__c = true);
            insert as system company;
            insert as system new Company_User_Access__c(Company__c = company.Id, User__c = preparer.Id, Role__c = 'HR',
                Is_Active__c = true, Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'G10I-MAKER');
            List<Employee__c> employees = new List<Employee__c>{
                new Employee__c(Employee_Reference__c = 'G10I-EMP-1', Status__c = 'Active'),
                new Employee__c(Employee_Reference__c = 'G10I-EMP-2', Status__c = 'Active')};
            insert as system employees;
            insert as system new List<Employment__c>{
                new Employment__c(Employee__c = employees[0].Id, Company__c = company.Id, Start_Date__c = Date.newInstance(2026, 1, 1),
                    Employment_Status__c = 'Active', Employment_Key__c = 'G10I-E1'),
                new Employment__c(Employee__c = employees[1].Id, Company__c = company.Id, Start_Date__c = Date.newInstance(2026, 10, 17),
                    Employment_Status__c = 'Active', Employment_Key__c = 'G10I-E2')};
            Map<String, String> categories = new Map<String, String>{'BASIC' => 'Basic Salary', 'HOUSE' => 'Other',
                'MEAL' => 'Food Allowance', 'TRANSPORT' => 'Other', 'BONUS' => 'Incentive', 'PF' => 'Deduction',
                'TAX' => 'Deduction', 'ERPF' => 'Employer Contribution'};
            Map<String, String> ruleKeys = new Map<String, String>{'PF' => 'BD_PF', 'TAX' => 'BD_TAX', 'ERPF' => 'BD_PF_ER'};
            List<Pay_Component__c> components = new List<Pay_Component__c>();
            for (String key : categories.keySet()) {
                components.add(new Pay_Component__c(Name = key, Company__c = company.Id, Component_Key__c = 'G10I-' + key,
                    Category__c = categories.get(key), Is_Active__c = true, Country_Rule_Key__c = ruleKeys.get(key)));
            }
            insert as system components;
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static User maker() {
        if (makerUser == null) {
            makerUser = [SELECT Id FROM User WHERE LastName = :MAKER AND Alias = 'g10imkr' WITH SYSTEM_MODE LIMIT 1];
        }
        return makerUser;
    }

    private static Id idOf(String key, String soql) {
        if (!ids.containsKey(key)) {
            ids.put(key, Database.query(soql).Id);
        }
        return ids.get(key);
    }

    private static Id companyId() {
        return idOf('company', 'SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = \'I10\' WITH SYSTEM_MODE LIMIT 1');
    }

    private static Id employment(String key) {
        return idOf(key, 'SELECT Id FROM Employment__c WHERE Employment_Key__c = \'' + String.escapeSingleQuotes(key)
            + '\' WITH SYSTEM_MODE LIMIT 1');
    }

    private static Id component(String key) {
        return idOf(key, 'SELECT Id FROM Pay_Component__c WHERE Component_Key__c = \'G10I-' + String.escapeSingleQuotes(key)
            + '\' WITH SYSTEM_MODE LIMIT 1');
    }

    private static Employee_Pay_Component__c assignment(Id employmentId, String componentKey, Decimal amount, String formula, Date fromDate,
            Date toDate) {
        return new Employee_Pay_Component__c(Employment__c = employmentId, Pay_Component__c = component(componentKey), Amount__c = amount,
            Formula_Parameter_JSON__c = formula, Currency__c = 'BDT', Effective_From__c = fromDate, Effective_To__c = toDate,
            Status__c = 'Approved');
    }

    // Full package per employee: basic, 40% house rent, daily meal, flat transport, and three statutory components.
    private static List<Employee_Pay_Component__c> standardPackage(Id employmentId) {
        Date jan = Date.newInstance(2026, 1, 1);
        return new List<Employee_Pay_Component__c>{
            assignment(employmentId, 'BASIC', 31000, null, jan, null),
            assignment(employmentId, 'HOUSE', null, '{"type":"PERCENT_OF","percent":40,"basis":["Basic Salary"]}', jan, null),
            assignment(employmentId, 'MEAL', null, '{"type":"DAILY_RATE","rate":50}', jan, null),
            assignment(employmentId, 'TRANSPORT', 300, '{"type":"FIXED","prorate":false}', jan, null),
            assignment(employmentId, 'PF', null, null, jan, null),
            assignment(employmentId, 'TAX', null, null, jan, null),
            assignment(employmentId, 'ERPF', null, null, jan, null)};
    }

    private static SAB_Statutory_Rule__mdt rule(String body) {
        return (SAB_Statutory_Rule__mdt) JSON.deserialize(body, SAB_Statutory_Rule__mdt.class);
    }

    private static void useStandardRules() {
        SABPayrollRuleEngine.ruleOverride = new List<SAB_Statutory_Rule__mdt>{
            rule('{"Rule_Key__c":"BD_PF","Rule_Version__c":"BD-2026.1","Method__c":"Rate","Rate_Percent__c":10,'
                + '"Basis_Categories__c":"Basic Salary","Is_Active__c":true,"Effective_From__c":"2026-01-01"}'),
            rule('{"Rule_Key__c":"BD_TAX","Rule_Version__c":"BD-2026.1","Method__c":"Slab","Country_Code__c":"BD",'
                + '"Bands__c":"[[20000,0],[40000,10],[null,20]]","Is_Active__c":true,"Effective_From__c":"2026-07-01"}'),
            rule('{"Rule_Key__c":"BD_PF_ER","Rule_Version__c":"BD-2026.1","Method__c":"Capped_Rate","Rate_Percent__c":10,'
                + '"Basis_Ceiling__c":25000,"Amount_Cap__c":2000,"Basis_Categories__c":"Basic Salary","Is_Active__c":true,'
                + '"Effective_From__c":"2026-01-01"}')};
    }

    private static Id draft(String key) {
        return SABPayrollCalculationService.createDraft(companyId(), STARTS, ENDS, 'BDT', key);
    }

    private static Map<Id, Payroll_Line__c> linesByEmployment(Id runId) {
        Map<Id, Payroll_Line__c> result = new Map<Id, Payroll_Line__c>();
        for (Payroll_Line__c line : [SELECT Employment__c, Gross_Amount__c, Deduction_Amount__c, Employer_Contribution__c, Net_Amount__c
                FROM Payroll_Line__c WHERE Payroll_Run__c = :runId WITH SYSTEM_MODE]) {
            result.put(line.Employment__c, line);
        }
        return result;
    }

    private static String calculationError(Id runId, List<Id> employmentIds) {
        try {
            SABPayrollCalculationService.calculate(runId, employmentIds, 2);
        } catch (SABPayrollCalculationService.PayrollException ex) {
            return ex.getMessage();
        }
        return null;
    }

    // ---------------------------------------------------------------- tests

    @IsTest
    static void calculatesFormulaProrationAwardsAndStatutoryRules() {
        Id e1 = employment('G10I-E1');
        Id e2 = employment('G10I-E2');
        List<Employee_Pay_Component__c> rows = standardPackage(e1);
        rows.addAll(standardPackage(e2));
        insert as system rows;
        insert as system new Benefit_Award__c(Employment__c = e1, Pay_Component__c = component('BONUS'), Award_Key__c = 'G10I-BONUS',
            Amount__c = 2000, Currency__c = 'BDT', Status__c = 'Approved', Service_Period_Start__c = STARTS);
        useStandardRules();
        Id runId;
        System.runAs(maker()) {
            runId = draft('G10I-RUN');
            SABTestGovernor.startTest();
            SABPayrollCalculationService.calculate(runId, new List<Id>{e1, e2}, 2);
            SABTestGovernor.stopTest();
        }
        Map<Id, Payroll_Line__c> lines = linesByEmployment(runId);
        System.assertEquals(47250, lines.get(e1).Gross_Amount__c, 'E1 gross: 31,000 + 12,400 + 1,550 + 300 + 2,000 award.');
        System.assertEquals(6550, lines.get(e1).Deduction_Amount__c, 'E1 PF 3,100 + slab tax 3,450.');
        System.assertEquals(2000, lines.get(e1).Employer_Contribution__c, 'E1 employer PF capped at 2,000.');
        System.assertEquals(40700, lines.get(e1).Net_Amount__c, 'E1 net.');
        System.assertEquals(22050, lines.get(e2).Gross_Amount__c, 'E2 (15 of 31 days): 15,000 + 6,000 + 750 + 300.');
        System.assertEquals(1705, lines.get(e2).Deduction_Amount__c, 'E2 PF 1,500 + tax 205.');
        System.assertEquals(1500, lines.get(e2).Employer_Contribution__c, 'E2 employer PF 10% of 15,000.');
        Payroll_Run__c run = [SELECT Workflow_State__c, Gross_Total__c, Deduction_Total__c, Employer_Total__c, Net_Total__c
            FROM Payroll_Run__c WHERE Id = :runId WITH SYSTEM_MODE];
        System.assertEquals('Calculated', run.Workflow_State__c, 'Run is Calculated.');
        System.assertEquals(69300, run.Gross_Total__c, 'Run gross.');
        System.assertEquals(8255, run.Deduction_Total__c, 'Run deductions.');
        System.assertEquals(3500, run.Employer_Total__c, 'Run employer cost.');
        System.assertEquals(61045, run.Net_Total__c, 'Run net.');
        Map<String, Integer> byRule = new Map<String, Integer>();
        for (AggregateResult ar : [SELECT Rule_Version__c rv, COUNT(Id) n FROM Payroll_Component_Line__c
                WHERE Payroll_Line__r.Payroll_Run__c = :runId WITH SYSTEM_MODE GROUP BY Rule_Version__c]) {
            byRule.put((String) ar.get('rv'), (Integer) ar.get('n'));
        }
        System.assertEquals(1, byRule.get('G10B_FIXED_V1'), 'E1 full-period basic keeps the G10B rule version.');
        System.assertEquals(1, byRule.get('G10I_PRORATED_V1'), 'E2 basic is prorated.');
        System.assertEquals(6, byRule.get('G10I_FORMULA_V1'), 'House, meal and transport for both employees.');
        System.assertEquals(6, byRule.get('G10I_STATUTORY_V1'), 'Three statutory components for both employees.');
        System.assertEquals(1, byRule.get('G10F_AWARD_V1'), 'Award line.');
        Payroll_Component_Line__c tax = [SELECT Amount__c, Eligibility_Snapshot__c FROM Payroll_Component_Line__c
            WHERE Payroll_Line__r.Employment__c = :e1 AND Payroll_Line__r.Payroll_Run__c = :runId AND Pay_Component__r.Component_Key__c = 'G10I-TAX'
            WITH SYSTEM_MODE];
        Map<String, Object> snapshot = (Map<String, Object>) JSON.deserializeUntyped(tax.Eligibility_Snapshot__c);
        System.assertEquals('BD-2026.1', snapshot.get('ruleVersion'), 'Rule version is recorded for audit.');
        System.assertEquals('BD', snapshot.get('country'), 'Country is recorded.');
        System.assertEquals(47250, Decimal.valueOf(String.valueOf(snapshot.get('basis'))), 'Statutory basis includes the award.');
    }

    @IsTest
    static void paysFinalPayAndMidPeriodRaise() {
        Id e1 = employment('G10I-E1');
        update as system new Employment__c(Id = e1, Employment_Status__c = 'Ended', End_Date__c = Date.newInstance(2026, 10, 20));
        Id e2 = employment('G10I-E2');
        insert as system new List<Employee_Pay_Component__c>{
            assignment(e1, 'BASIC', 31000, null, Date.newInstance(2026, 1, 1), null),
            assignment(e2, 'BASIC', 30000, null, Date.newInstance(2026, 10, 1), Date.newInstance(2026, 10, 24)),
            assignment(e2, 'BASIC', 32000, null, Date.newInstance(2026, 10, 25), null)};
        Id runId;
        System.runAs(maker()) {
            runId = draft('G10I-FINAL');
            SABTestGovernor.startTest();
            SABPayrollCalculationService.calculate(runId, new List<Id>{e1, e2}, 2);
            SABTestGovernor.stopTest();
        }
        Map<Id, Payroll_Line__c> lines = linesByEmployment(runId);
        System.assertEquals(20000, lines.get(e1).Gross_Amount__c, 'Final pay for Oct 1-20: 31,000 x 20/31.');
        // E2 starts Oct 17: 30,000 for Oct 17-24 (8 days) and 32,000 for Oct 25-31 (7 days).
        System.assertEquals(7741.94 + 7225.81, lines.get(e2).Gross_Amount__c, 'Raise mid-period: each rate for its own days.');
        System.assertEquals(2, [SELECT COUNT() FROM Payroll_Component_Line__c WHERE Payroll_Line__r.Employment__c = :e2
            AND Payroll_Line__r.Payroll_Run__c = :runId WITH SYSTEM_MODE], 'One prorated line per consecutive assignment.');
    }

    @IsTest
    static void failsClosedOnMissingOrAmbiguousRules() {
        Id e1 = employment('G10I-E1');
        insert as system standardPackage(e1);
        List<String> messages = new List<String>();
        System.runAs(maker()) {
            Id runId = draft('G10I-RULES');
            SABTestGovernor.startTest();
            SABPayrollRuleEngine.ruleOverride = new List<SAB_Statutory_Rule__mdt>();
            messages.add(calculationError(runId, new List<Id>{e1}));
            useStandardRules();
            SABPayrollRuleEngine.ruleOverride.add(SABPayrollRuleEngine.ruleOverride[0].clone());
            messages.add(calculationError(runId, new List<Id>{e1}));
            useStandardRules();
            SABPayrollRuleEngine.ruleOverride[1] = rule('{"Rule_Key__c":"BD_TAX","Rule_Version__c":"IN-1","Method__c":"Rate",'
                + '"Rate_Percent__c":5,"Country_Code__c":"IN","Is_Active__c":true,"Effective_From__c":"2026-01-01"}');
            messages.add(calculationError(runId, new List<Id>{e1}));
            SABTestGovernor.stopTest();
            System.assertEquals('Draft', [SELECT Workflow_State__c FROM Payroll_Run__c WHERE Id = :runId WITH SYSTEM_MODE].Workflow_State__c,
                'Failed calculations leave the run Draft.');
            System.assertEquals(0, [SELECT COUNT() FROM Payroll_Line__c WHERE Payroll_Run__c = :runId WITH SYSTEM_MODE],
                'Failed calculations leave no snapshot rows.');
        }
        System.assert(messages[0] != null && messages[0].contains('No active statutory rule'), 'Missing rule: ' + messages[0]);
        System.assert(messages[1] != null && messages[1].contains('More than one'), 'Ambiguous rule: ' + messages[1]);
        System.assert(messages[2] != null && messages[2].contains('for country BD'), 'Wrong-country rule: ' + messages[2]);
    }

    @IsTest
    static void rejectsInvalidCompensationShapes() {
        Id e1 = employment('G10I-E1');
        Id e2 = employment('G10I-E2');
        Date jan = Date.newInstance(2026, 1, 1);
        insert as system new List<Employee_Pay_Component__c>{
            assignment(e1, 'BASIC', 31000, null, jan, null),
            assignment(e2, 'BASIC', 31000, null, jan, null)};
        Pay_Component__c misfiled = new Pay_Component__c(Name = 'Misfiled', Company__c = companyId(), Component_Key__c = 'G10I-MISFILED',
            Category__c = 'Other', Is_Active__c = true, Country_Rule_Key__c = 'BD_PF');
        insert as system misfiled;
        List<String> messages = new List<String>();
        System.runAs(maker()) {
            Id runId = draft('G10I-SHAPES');
            SABTestGovernor.startTest();
            Employee_Pay_Component__c pfWithFormula = assignment(e1, 'PF', null, '{"type":"DAILY_RATE","rate":1}', jan, null);
            insert as system pfWithFormula;
            messages.add(calculationError(runId, new List<Id>{e1}));
            delete as system pfWithFormula;
            Employee_Pay_Component__c misfiledRow = new Employee_Pay_Component__c(Employment__c = e1, Pay_Component__c = misfiled.Id,
                Currency__c = 'BDT', Effective_From__c = jan, Status__c = 'Approved');
            insert as system misfiledRow;
            messages.add(calculationError(runId, new List<Id>{e1}));
            delete as system misfiledRow;
            Employee_Pay_Component__c overlapping = assignment(e2, 'BASIC', 1000, null, Date.newInstance(2026, 10, 20), null);
            insert as system overlapping;
            messages.add(calculationError(runId, new List<Id>{e2}));
            delete as system overlapping;
            Employee_Pay_Component__c noAmount = assignment(e2, 'MEAL', null, null, jan, null);
            insert as system noAmount;
            messages.add(calculationError(runId, new List<Id>{e2}));
            delete as system noAmount;
            update as system new Employment__c(Id = e2, Employment_Status__c = 'Leave');
            messages.add(calculationError(runId, new List<Id>{e2}));
            SABTestGovernor.stopTest();
        }
        System.assert(messages[0] != null && messages[0].contains('take no formula'), messages[0]);
        System.assert(messages[1] != null && messages[1].contains('must be Deduction or Employer Contribution'), messages[1]);
        System.assert(messages[2] != null && messages[2].contains('Overlapping approved compensation'), messages[2]);
        System.assert(messages[3] != null && messages[3].contains('needs an amount'), messages[3]);
        System.assert(messages[4] != null && messages[4].contains('Only active employments'), messages[4]);
    }
}
