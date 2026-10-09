/**
 * G21: shared test data for reporting tests, lean by design (SABTestGovernor rules).
 *
 * Users (System Administrator profile): viewer (Report Centre User, grant), noview (grant only), outsider (Report Centre User, no grant).
 * Company 'R21' (USD, fiscal year from January): Jan-Mar 2026 Open. GL 1100 Bank (bank account), 1200 Receivables (AR control),
 * 2100 Payables (AP control), 1500 Equipment (Investing), 2500 Loan (Financing), 3000 Equity (Financing), 4000 Sales, 6000 Expenses.
 * Posted journals: 5 Jan Bank 1,000 / Equity; 10 Feb Bank 500 / Sales; 12 Feb AR 300 / Sales; 20 Feb Expenses 200 / Bank;
 * 5 Mar Equipment 400 / Bank; 10 Mar Bank 600 / Loan; 15 Mar Bank 100 / AR; 20 Mar Expenses 150 / AP.
 */
@IsTest
public class SABReportingTestFixture {
    public static final String VIEWER = 'SAB R21 Viewer';
    public static final String NOVIEW = 'SAB R21 NoView';
    public static final String OUTSIDER = 'SAB R21 Outsider';

    private static Map<String, User> users = new Map<String, User>();
    private static Map<String, Id> ids = new Map<String, Id>();

    public static void createFixture() {
        Map<String, User> created = new Map<String, User>();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            for (List<String> u : new List<List<String>>{new List<String>{VIEWER, 'r21vw'}, new List<String>{NOVIEW, 'r21nv'},
                    new List<String>{OUTSIDER, 'r21out'}}) {
                created.put(u[0], new User(Username = u[1] + '.' + unique + '@example.invalid', Email = u[1] + '@example.invalid', LastName = u[0],
                    Alias = u[1], TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US',
                    ProfileId = UserInfo.getProfileId()));
            }
            insert as system created.values();
            Id reportSet = [SELECT Id FROM PermissionSet WHERE Name = 'SAB_Report_Centre_User' WITH SYSTEM_MODE].Id;
            insert as system new List<PermissionSetAssignment>{new PermissionSetAssignment(AssigneeId = created.get(VIEWER).Id, PermissionSetId = reportSet),
                new PermissionSetAssignment(AssigneeId = created.get(OUTSIDER).Id, PermissionSetId = reportSet)};
        }
        System.runAs(created.get(VIEWER)) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'R21 Company', Company_Key__c = 'R21', Country_Code__c = 'BD',
                Functional_Currency__c = 'USD', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active',
                Is_Active__c = true);
            insert as system company;
            insert as system new List<Company_User_Access__c>{grant(company.Id, created.get(VIEWER).Id, 'R21-VIEWER'),
                grant(company.Id, created.get(NOVIEW).Id, 'R21-NOVIEW')};
            List<Accounting_Period__c> periods = new List<Accounting_Period__c>();
            for (Integer month = 1; month <= 3; month++) {
                Date starts = Date.newInstance(2026, month, 1);
                String key = 'R21-2026-0' + month;
                periods.add(new Accounting_Period__c(Name = key, Company__c = company.Id, Company_Period_Key__c = key, Period_Key__c = key,
                    Start_Date__c = starts, End_Date__c = starts.addMonths(1).addDays(-1), Fiscal_Year__c = 2026, Fiscal_Quarter__c = 1,
                    Period_Number__c = month, Status__c = 'Open'));
            }
            insert as system periods;
            List<GL_Account__c> accounts = new List<GL_Account__c>{gl(company.Id, '1100', 'Bank', 'Asset', 'Debit', 'None', null),
                gl(company.Id, '1200', 'Receivables', 'Asset', 'Debit', 'AR', null), gl(company.Id, '2100', 'Payables', 'Liability', 'Credit', 'AP', null),
                gl(company.Id, '1500', 'Equipment', 'Asset', 'Debit', 'None', 'Investing'), gl(company.Id, '2500', 'Loan', 'Liability', 'Credit', 'None', 'Financing'),
                gl(company.Id, '3000', 'Equity', 'Equity', 'Credit', 'None', 'Financing'), gl(company.Id, '4000', 'Sales', 'Revenue', 'Credit', 'None', null),
                gl(company.Id, '6000', 'Expenses', 'Expense', 'Debit', 'None', null)};
            insert as system accounts;
            // Seeding uses the inserted records directly: no lookups, so the setup stays within the 50-query cap.
            Map<String, Id> accountByCode = new Map<String, Id>();
            for (GL_Account__c a : accounts) {
                accountByCode.put(a.Account_Code__c, a.Id);
            }
            Map<Integer, Id> periodByMonth = new Map<Integer, Id>();
            for (Accounting_Period__c p : periods) {
                periodByMonth.put(p.Period_Number__c.intValue(), p.Id);
            }
            insert as system new Bank_Account__c(Name = 'R21 Operating', Company__c = company.Id, Currency__c = 'USD', GL_Account__c = accountByCode.get('1100'),
                Is_Active__c = true);
            post(company.Id, periodByMonth, accountByCode, new List<List<Object>>{new List<Object>{1, 5, '1100', '3000', 1000},
                new List<Object>{2, 10, '1100', '4000', 500}, new List<Object>{2, 12, '1200', '4000', 300}, new List<Object>{2, 20, '6000', '1100', 200},
                new List<Object>{3, 5, '1500', '1100', 400}, new List<Object>{3, 10, '1100', '2500', 600}, new List<Object>{3, 15, '1100', '1200', 100},
                new List<Object>{3, 20, '6000', '2100', 150}});
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static Company_User_Access__c grant(Id companyId, Id userId, String key) {
        return new Company_User_Access__c(Company__c = companyId, User__c = userId, Is_Active__c = true, Effective_From__c = Date.today().addDays(-1),
            Grant_Key__c = key, Role__c = 'Finance Manager');
    }

    private static GL_Account__c gl(Id companyId, String code, String label, String type, String balance, String control, String category) {
        return new GL_Account__c(Name = label, Company__c = companyId, Company_Account_Key__c = companyId + '-' + code, Account_Code__c = code,
            Account_Type__c = type, Normal_Balance__c = balance, Is_Active__c = true, Is_Control_Account__c = control != 'None', Control_Type__c = control,
            Manual_Posting_Allowed__c = control == 'None', Cash_Flow_Category__c = category);
    }

    // {month, day, debitCode, creditCode, amount}: balanced two-line journals posted through the ledger posting context.
    private static void post(Id companyId, Map<Integer, Id> periods, Map<String, Id> accounts, List<List<Object>> specs) {
        List<Journal_Entry__c> journals = new List<Journal_Entry__c>();
        for (List<Object> s : specs) {
            journals.add(new Journal_Entry__c(Company__c = companyId, Accounting_Period__c = periods.get((Integer) s[0]),
                Accounting_Date__c = Date.newInstance(2026, (Integer) s[0], (Integer) s[1]), Entry_Type__c = 'Manual', Status__c = 'Draft', Version__c = 1,
                Description__c = 'R21 seed'));
        }
        insert as system journals;
        List<Journal_Entry_Line__c> lines = new List<Journal_Entry_Line__c>();
        for (Integer i = 0; i < specs.size(); i++) {
            Decimal amount = (Integer) specs[i][4];
            Date onDate = journals[i].Accounting_Date__c;
            lines.add(line(journals[i].Id, 1, accounts.get((String) specs[i][2]), amount, 0, onDate));
            lines.add(line(journals[i].Id, 2, accounts.get((String) specs[i][3]), 0, amount, onDate));
        }
        insert as system lines;
        for (Journal_Entry__c j : journals) {
            j.Status__c = 'Posted';
        }
        SABLedgerMutationContext.beginPosting();
        try {
            update as system journals;
        } finally {
            SABLedgerMutationContext.endPosting();
        }
    }

    private static Journal_Entry_Line__c line(Id journalId, Integer n, Id accountId, Decimal debit, Decimal credit, Date onDate) {
        return new Journal_Entry_Line__c(Journal_Entry__c = journalId, Line_Number__c = n, GL_Account__c = accountId, Debit_Base__c = debit,
            Credit_Base__c = credit, Transaction_Amount__c = debit > 0 ? debit : credit, Transaction_Currency__c = 'USD', Functional_Currency__c = 'USD',
            Applied_Exchange_Rate__c = 1, Rate_Date__c = onDate, Rate_Source__c = 'Test', Explanation__c = 'R21 seed');
    }

    public static User user(String lastName) {
        if (!users.containsKey(lastName)) {
            users.put(lastName, [SELECT Id FROM User WHERE LastName = :lastName AND Alias LIKE 'r21%' WITH SYSTEM_MODE LIMIT 1]);
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
        return cached('company', 'SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = \'R21\' LIMIT 1');
    }

    public static Id accountId(String code) {
        return cached('gl' + code, 'SELECT Id FROM GL_Account__c WHERE Account_Code__c = \'' + String.escapeSingleQuotes(code)
            + '\' AND Company__r.Company_Key__c = \'R21\' LIMIT 1');
    }
}
