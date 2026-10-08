/**
 * G14: shared test data for allocation tests, lean by design (SABTestGovernor rules).
 *
 * Users (System Administrator profile; access comes from the G14 permission sets):
 *   preparer  SAB Allocation User + Manage Allocation + Post Journal
 *   approver  SAB Allocation User + Approve Allocation
 *   outsider  SAB Allocation User + Manage Allocation, no company grant
 * Company 'A14' (BDT, default rounding account 7990): Oct 2026 Open, Nov 2026 Closed. GL 1100 Bank, 2100 AP (control),
 * 6100 Rent, 6200 Utilities, 7990 Rounding. Departments Sales and Ops; cost center Main.
 * October actuals (posted through the ledger posting context): Rent 1,000.00 and Utilities 100.01, both against Bank.
 */
@IsTest
public class SABAllocationTestFixture {
    public static final String PREPARER = 'SAB A14 Preparer';
    public static final String APPROVER = 'SAB A14 Approver';
    public static final String OUTSIDER = 'SAB A14 Outsider';

    private static Map<String, User> users = new Map<String, User>();
    private static Map<String, Id> ids = new Map<String, Id>();

    public static void createFixture() {
        User preparerUser;
        User approverUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            preparerUser = newUser(PREPARER, 'a14prp', unique);
            approverUser = newUser(APPROVER, 'a14apr', unique);
            User outsiderUser = newUser(OUTSIDER, 'a14out', unique);
            insert as system new List<User>{preparerUser, approverUser, outsiderUser};
            Map<Id, Set<String>> setsByUser = new Map<Id, Set<String>>{
                preparerUser.Id => new Set<String>{'SAB_Allocation_User', 'SAB_Manage_Allocation_Action', 'SAB_Post_Journal_Action'},
                approverUser.Id => new Set<String>{'SAB_Allocation_User', 'SAB_Approve_Allocation_Action'},
                outsiderUser.Id => new Set<String>{'SAB_Allocation_User', 'SAB_Manage_Allocation_Action'}};
            Map<String, Id> setIds = new Map<String, Id>();
            for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN ('SAB_Allocation_User', 'SAB_Manage_Allocation_Action',
                    'SAB_Approve_Allocation_Action', 'SAB_Post_Journal_Action') WITH SYSTEM_MODE]) {
                setIds.put(p.Name, p.Id);
            }
            System.assertEquals(4, setIds.size(), 'Deploy the G14 permission sets and SAB_Post_Journal_Action first.');
            List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
            for (Id userId : setsByUser.keySet()) {
                for (String name : setsByUser.get(userId)) {
                    rows.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = setIds.get(name)));
                }
            }
            insert as system rows;
        }
        System.runAs(preparerUser) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'A14 Company', Company_Key__c = 'A14', Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active', Is_Active__c = true);
            insert as system company;
            insert as system new List<Company_User_Access__c>{
                new Company_User_Access__c(Company__c = company.Id, User__c = preparerUser.Id, Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'A14-PREPARER', Role__c = 'Finance Manager'),
                new Company_User_Access__c(Company__c = company.Id, User__c = approverUser.Id, Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'A14-APPROVER', Role__c = 'Finance Manager')};
            insert as system new List<Accounting_Period__c>{period(company.Id, 'A14-2026-10', 10, 'Open'),
                period(company.Id, 'A14-2026-11', 11, 'Closed')};
            List<GL_Account__c> accounts = new List<GL_Account__c>{gl(company.Id, '1100', 'Bank', 'Asset', 'Debit', 'Bank'),
                gl(company.Id, '2100', 'Payables', 'Liability', 'Credit', 'AP'), gl(company.Id, '6100', 'Rent', 'Expense', 'Debit', 'None'),
                gl(company.Id, '6200', 'Utilities', 'Expense', 'Debit', 'None'), gl(company.Id, '7990', 'Rounding', 'Expense', 'Debit', 'None')};
            insert as system accounts;
            update as system new Accounting_Company__c(Id = company.Id, Default_Rounding_Account__c = accounts[4].Id);
            insert as system new List<Department__c>{
                new Department__c(Name = 'Sales', Company__c = company.Id, Code__c = 'SAL', Company_Department_Key__c = 'A14-SAL', Is_Active__c = true),
                new Department__c(Name = 'Ops', Company__c = company.Id, Code__c = 'OPS', Company_Department_Key__c = 'A14-OPS', Is_Active__c = true)};
            insert as system new Cost_Center__c(Name = 'Main', Company__c = company.Id, Code__c = 'MAIN', Company_Cost_Center_Key__c = 'A14-MAIN',
                Is_Active__c = true);
            postActual('6100', 1000, 'Rent');
            postActual('6200', 100.01, 'Utilities');
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static Accounting_Period__c period(Id companyId, String key, Integer month, String status) {
        Date starts = Date.newInstance(2026, month, 1);
        return new Accounting_Period__c(Name = key, Company__c = companyId, Company_Period_Key__c = key, Period_Key__c = key,
            Start_Date__c = starts, End_Date__c = starts.addMonths(1).addDays(-1), Fiscal_Year__c = 2026, Fiscal_Quarter__c = 4,
            Period_Number__c = month, Status__c = status,
            // Validation rule: a Closed period must carry its closing stamp.
            Closed_At__c = status == 'Closed' ? System.now() : null, Closed_By__c = status == 'Closed' ? UserInfo.getUserId() : null);
    }

    private static GL_Account__c gl(Id companyId, String code, String label, String type, String balance, String control) {
        return new GL_Account__c(Name = label, Company__c = companyId, Company_Account_Key__c = 'A14-' + code, Account_Code__c = code,
            Account_Type__c = type, Normal_Balance__c = balance, Is_Active__c = true, Is_Control_Account__c = control != 'None',
            Control_Type__c = control, Manual_Posting_Allowed__c = control == 'None');
    }

    /** Posts Dr expense / Cr Bank in October through the same trusted context SABPostingService uses. */
    public static void postActual(String expenseCode, Decimal amount, String description) {
        Journal_Entry__c journal = new Journal_Entry__c(Company__c = companyId(), Accounting_Period__c = periodId('A14-2026-10'),
            Accounting_Date__c = Date.newInstance(2026, 10, 15), Entry_Type__c = 'Manual', Status__c = 'Draft', Version__c = 1,
            Description__c = description);
        insert as system journal;
        insert as system new List<Journal_Entry_Line__c>{line(journal.Id, 1, accountId(expenseCode), amount, 0),
            line(journal.Id, 2, accountId('1100'), 0, amount)};
        SABLedgerMutationContext.beginPosting();
        try {
            update as system new Journal_Entry__c(Id = journal.Id, Status__c = 'Posted');
        } finally {
            SABLedgerMutationContext.endPosting();
        }
    }

    private static Journal_Entry_Line__c line(Id journalId, Integer n, Id accountId, Decimal debit, Decimal credit) {
        return new Journal_Entry_Line__c(Journal_Entry__c = journalId, Line_Number__c = n, GL_Account__c = accountId, Debit_Base__c = debit,
            Credit_Base__c = credit, Transaction_Amount__c = debit > 0 ? debit : credit, Transaction_Currency__c = 'BDT',
            Functional_Currency__c = 'BDT', Applied_Exchange_Rate__c = 1, Rate_Date__c = Date.newInstance(2026, 10, 15),
            Rate_Source__c = 'Test', Explanation__c = 'Allocation source');
    }

    private static User newUser(String lastName, String alias, String unique) {
        return new User(Username = alias + '.' + unique + '@example.invalid', Email = alias + '@example.invalid', LastName = lastName,
            Alias = alias, TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', ProfileId = UserInfo.getProfileId());
    }

    public static User user(String lastName) {
        if (!users.containsKey(lastName)) {
            users.put(lastName, [SELECT Id FROM User WHERE LastName = :lastName AND Alias LIKE 'a14%' WITH SYSTEM_MODE LIMIT 1]);
        }
        return users.get(lastName);
    }

    private static Id cached(String key, String soql) {
        if (!ids.containsKey(key)) {
            ids.put(key, Database.query(soql, AccessLevel.SYSTEM_MODE).Id);
        }
        return ids.get(key);
    }

    public static Id companyId() {
        return cached('company', 'SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = \'A14\' LIMIT 1');
    }

    public static Id periodId(String key) {
        return cached('period' + key, 'SELECT Id FROM Accounting_Period__c WHERE Company_Period_Key__c = \'' + String.escapeSingleQuotes(key)
            + '\' LIMIT 1');
    }

    public static Id accountId(String code) {
        return cached('gl' + code, 'SELECT Id FROM GL_Account__c WHERE Company_Account_Key__c = \'A14-' + String.escapeSingleQuotes(code)
            + '\' LIMIT 1');
    }

    public static Id departmentId(String code) {
        return cached('dept' + code, 'SELECT Id FROM Department__c WHERE Company_Department_Key__c = \'A14-' + String.escapeSingleQuotes(code)
            + '\' LIMIT 1');
    }

    /** A Percent or Manual Driver rule seeded through the guard scope, created by the running user. Targets: {deptCode, weight}. */
    public static Id seedRule(String ruleKey, String status, String driver, String rounding, List<String> sourceCodes, List<List<Object>> targets) {
        SABAllocationRuleService.SourceFilter source = new SABAllocationRuleService.SourceFilter();
        for (String code : sourceCodes) {
            source.accountIds.add(accountId(code));
        }
        Allocation_Rule__c rule = new Allocation_Rule__c(Name = ruleKey, Company__c = companyId(), Rule_Key__c = ruleKey, Version__c = 1,
            Status__c = status, Driver_Type__c = driver, Rounding_Policy__c = rounding, Effective_From__c = Date.newInstance(2026, 1, 1),
            Source_Filter_JSON__c = JSON.serialize(source));
        SABAllocationGuard.beginWrite();
        try {
            insert as system rule;
            List<Allocation_Rule_Line__c> lines = new List<Allocation_Rule_Line__c>();
            Integer sequence = 1;
            for (List<Object> t : targets) {
                lines.add(new Allocation_Rule_Line__c(Allocation_Rule__c = rule.Id, Sequence__c = sequence++,
                    Target_Department__c = departmentId((String) t[0]),
                    Percentage__c = driver == 'Percent' ? (Decimal) t[1] : null, Driver_Value__c = driver == 'Percent' ? null : (Decimal) t[1]));
            }
            insert as system lines;
        } finally {
            SABAllocationGuard.endWrite();
        }
        return rule.Id;
    }
}
