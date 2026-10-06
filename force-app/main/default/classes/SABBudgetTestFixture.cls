/**
 * G13: shared test data for budget tests, lean by design (SABTestGovernor rules).
 *
 * Users (System Administrator profile; field access comes from the G13 permission sets):
 *   planner   SAB Budget User + Manage Budget
 *   approver  SAB Budget User + Approve Budget
 *   outsider  SAB Budget User, no company grant
 * Company 'B13' (BDT): FY2026 periods Oct and Nov, an FY2025 period; GL 1100 Bank (Asset), 4000 Sales (Revenue),
 * 6000 Supplies (Expense), 6100 Old (inactive); departments Sales and Ops; cost center Main.
 * Actuals (posted through the ledger posting context): Oct sale Dr 1100 / Cr 4000 1,000; Oct supplies Dr 6000 (Sales)
 * / Cr 1100 300. A Draft journal of 999 on 6000 must never count.
 */
@IsTest
public class SABBudgetTestFixture {
    public static final String PLANNER = 'SAB B13 Planner';
    public static final String APPROVER = 'SAB B13 Approver';
    public static final String OUTSIDER = 'SAB B13 Outsider';

    private static Map<String, User> users = new Map<String, User>();
    private static Map<String, Id> ids = new Map<String, Id>();

    public static void createFixture() {
        User plannerUser;
        User approverUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            plannerUser = newUser(PLANNER, 'b13pln', unique);
            approverUser = newUser(APPROVER, 'b13apr', unique);
            User outsiderUser = newUser(OUTSIDER, 'b13out', unique);
            insert as system new List<User>{plannerUser, approverUser, outsiderUser};
            Map<Id, Set<String>> setsByUser = new Map<Id, Set<String>>{
                plannerUser.Id => new Set<String>{'SAB_Budget_User', 'SAB_Manage_Budget_Action'},
                approverUser.Id => new Set<String>{'SAB_Budget_User', 'SAB_Approve_Budget_Action'},
                outsiderUser.Id => new Set<String>{'SAB_Budget_User'}};
            Map<String, Id> setIds = new Map<String, Id>();
            for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN ('SAB_Budget_User', 'SAB_Manage_Budget_Action',
                    'SAB_Approve_Budget_Action') WITH SYSTEM_MODE]) {
                setIds.put(p.Name, p.Id);
            }
            System.assertEquals(3, setIds.size(), 'Deploy the G13 budget permission sets first.');
            List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
            for (Id userId : setsByUser.keySet()) {
                for (String name : setsByUser.get(userId)) {
                    rows.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = setIds.get(name)));
                }
            }
            insert as system rows;
        }
        System.runAs(plannerUser) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'B13 Company', Company_Key__c = 'B13', Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active', Is_Active__c = true);
            insert as system company;
            insert as system new List<Company_User_Access__c>{
                new Company_User_Access__c(Company__c = company.Id, User__c = plannerUser.Id, Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'B13-PLANNER', Role__c = 'Finance Manager'),
                new Company_User_Access__c(Company__c = company.Id, User__c = approverUser.Id, Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'B13-APPROVER', Role__c = 'Finance Manager')};
            insert as system new List<Accounting_Period__c>{
                period(company.Id, 'B13-2026-10', 2026, 10), period(company.Id, 'B13-2026-11', 2026, 11), period(company.Id, 'B13-2025-12', 2025, 12)};
            insert as system new List<GL_Account__c>{
                gl(company.Id, '1100', 'Bank', 'Asset', 'Debit', true), gl(company.Id, '4000', 'Sales', 'Revenue', 'Credit', true),
                gl(company.Id, '6000', 'Supplies', 'Expense', 'Debit', true), gl(company.Id, '6100', 'Old Expense', 'Expense', 'Debit', false)};
            insert as system new List<Department__c>{
                new Department__c(Name = 'Sales', Company__c = company.Id, Code__c = 'SAL', Company_Department_Key__c = 'B13-SAL', Is_Active__c = true),
                new Department__c(Name = 'Ops', Company__c = company.Id, Code__c = 'OPS', Company_Department_Key__c = 'B13-OPS', Is_Active__c = true)};
            insert as system new Cost_Center__c(Name = 'Main', Company__c = company.Id, Code__c = 'MAIN', Company_Cost_Center_Key__c = 'B13-MAIN',
                Is_Active__c = true);
            postActuals(company.Id);
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static Accounting_Period__c period(Id companyId, String key, Integer year, Integer month) {
        Date starts = Date.newInstance(year, month, 1);
        return new Accounting_Period__c(Name = key, Company__c = companyId, Company_Period_Key__c = key, Period_Key__c = key,
            Start_Date__c = starts, End_Date__c = starts.addMonths(1).addDays(-1), Fiscal_Year__c = year,
            Fiscal_Quarter__c = ((month - 1) / 3) + 1, Period_Number__c = month, Status__c = 'Open');
    }

    private static GL_Account__c gl(Id companyId, String code, String label, String type, String balance, Boolean active) {
        return new GL_Account__c(Name = label, Company__c = companyId, Company_Account_Key__c = 'B13-' + code, Account_Code__c = code,
            Account_Type__c = type, Normal_Balance__c = balance, Is_Active__c = active, Is_Control_Account__c = false,
            Control_Type__c = 'None', Manual_Posting_Allowed__c = true);
    }

    // Two posted journals and one Draft journal, posted through the same trusted context SABPostingService uses.
    private static void postActuals(Id companyId) {
        Id october = periodId('B13-2026-10');
        Date onDate = Date.newInstance(2026, 10, 15);
        List<Journal_Entry__c> journals = new List<Journal_Entry__c>{journal(companyId, october, onDate, 'Sale'),
            journal(companyId, october, onDate, 'Supplies'), journal(companyId, october, onDate, 'Unposted')};
        insert as system journals;
        Id bank = accountId('1100');
        Id sales = accountId('4000');
        Id supplies = accountId('6000');
        Id salesDept = departmentId('SAL');
        insert as system new List<Journal_Entry_Line__c>{
            line(journals[0].Id, 1, bank, 1000, 0, null), line(journals[0].Id, 2, sales, 0, 1000, null),
            line(journals[1].Id, 1, supplies, 300, 0, salesDept), line(journals[1].Id, 2, bank, 0, 300, null),
            line(journals[2].Id, 1, supplies, 999, 0, null), line(journals[2].Id, 2, bank, 0, 999, null)};
        SABLedgerMutationContext.beginPosting();
        try {
            update as system new List<Journal_Entry__c>{new Journal_Entry__c(Id = journals[0].Id, Status__c = 'Posted'),
                new Journal_Entry__c(Id = journals[1].Id, Status__c = 'Posted')};
        } finally {
            SABLedgerMutationContext.endPosting();
        }
    }

    private static Journal_Entry__c journal(Id companyId, Id periodId, Date onDate, String description) {
        return new Journal_Entry__c(Company__c = companyId, Accounting_Period__c = periodId, Accounting_Date__c = onDate,
            Entry_Type__c = 'Manual', Status__c = 'Draft', Version__c = 1, Description__c = description);
    }

    private static Journal_Entry_Line__c line(Id journalId, Integer n, Id accountId, Decimal debit, Decimal credit, Id departmentId) {
        return new Journal_Entry_Line__c(Journal_Entry__c = journalId, Line_Number__c = n, GL_Account__c = accountId, Debit_Base__c = debit,
            Credit_Base__c = credit, Transaction_Amount__c = debit > 0 ? debit : -credit, Transaction_Currency__c = 'BDT',
            Functional_Currency__c = 'BDT', Applied_Exchange_Rate__c = 1, Rate_Date__c = Date.newInstance(2026, 10, 15),
            Rate_Source__c = 'Test', Explanation__c = 'Budget actuals', Department__c = departmentId);
    }

    private static User newUser(String lastName, String alias, String unique) {
        return new User(Username = alias + '.' + unique + '@example.invalid', Email = alias + '@example.invalid', LastName = lastName,
            Alias = alias, TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', ProfileId = UserInfo.getProfileId());
    }

    public static User user(String lastName) {
        if (!users.containsKey(lastName)) {
            users.put(lastName, [SELECT Id FROM User WHERE LastName = :lastName AND Alias LIKE 'b13%' WITH SYSTEM_MODE LIMIT 1]);
        }
        return users.get(lastName);
    }

    private static Id cached(String key, String soql) {
        if (!ids.containsKey(key)) {
            ids.put(key, Database.query(soql).Id);
        }
        return ids.get(key);
    }

    public static Id companyId() {
        return cached('company', 'SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = \'B13\' WITH SYSTEM_MODE LIMIT 1');
    }

    public static Id periodId(String key) {
        return cached('period' + key, 'SELECT Id FROM Accounting_Period__c WHERE Company_Period_Key__c = \'' + String.escapeSingleQuotes(key)
            + '\' WITH SYSTEM_MODE LIMIT 1');
    }

    public static Id accountId(String code) {
        return cached('gl' + code, 'SELECT Id FROM GL_Account__c WHERE Company_Account_Key__c = \'B13-' + String.escapeSingleQuotes(code)
            + '\' WITH SYSTEM_MODE LIMIT 1');
    }

    public static Id departmentId(String code) {
        return cached('dept' + code, 'SELECT Id FROM Department__c WHERE Company_Department_Key__c = \'B13-' + String.escapeSingleQuotes(code)
            + '\' WITH SYSTEM_MODE LIMIT 1');
    }

    public static Id costCenterId() {
        return cached('cc', 'SELECT Id FROM Cost_Center__c WHERE Company_Cost_Center_Key__c = \'B13-MAIN\' WITH SYSTEM_MODE LIMIT 1');
    }

    /** Budget seeded through the guard scope in any status, created by the running user. Lines: {periodKey, accountCode, deptCode, amount}. */
    public static Id seedBudget(String status, Integer version, List<List<Object>> lines) {
        Budget__c budget = new Budget__c(Name = 'Seeded v' + version, Company__c = companyId(), Fiscal_Year__c = 2026, Version__c = version,
            Currency__c = 'BDT', Status__c = status, Budget_Key__c = companyId() + '|2026|V' + version,
            Approved_By__c = status == 'Approved' ? UserInfo.getUserId() : null, Approved_At__c = status == 'Approved' ? System.now() : null);
        SABBudgetGuard.beginWrite();
        try {
            insert as system budget;
            List<Budget_Line__c> rows = new List<Budget_Line__c>();
            for (List<Object> spec : lines) {
                Budget_Line__c row = new Budget_Line__c(Budget__c = budget.Id, Accounting_Period__c = periodId((String) spec[0]),
                    GL_Account__c = accountId((String) spec[1]), Department__c = spec[2] == null ? null : departmentId((String) spec[2]),
                    Amount__c = (Decimal) spec[3]);
                row.Line_Key__c = SABBudgetService.lineKey(budget.Id, row);
                rows.add(row);
            }
            insert as system rows;
        } finally {
            SABBudgetGuard.endWrite();
        }
        return budget.Id;
    }
}
