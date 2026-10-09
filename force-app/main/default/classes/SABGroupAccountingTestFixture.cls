/**
 * G18: shared test data for group accounting tests, lean by design (SABTestGovernor rules).
 *
 * Users (System Administrator profile; access comes from the G18 permission sets):
 *   manager   Group Accounting User + Manage Intercompany + Manage Consolidation + Post Journal; grants P, S, J, E
 *   approver  Group Accounting User + Manage Consolidation + Approve Consolidation; grants P, S, J
 *   outsider  Group Accounting User + Manage Intercompany + Manage Consolidation + Post Journal; grant P only
 * Companies (USD unless noted): P parent and S subsidiary with Jan-Mar 2026 Open periods and the same account codes
 * 1100 Bank, 1400 IC receivable, 2400 IC payable, 4000 Sales, 4100 IC revenue, 6100 IC expense; J joint venture (no ledger);
 * E in EUR (no ledger). Group G18 (USD, policy v1): P and S Subsidiary members, J Joint Venture, all from 1 Jan 2026.
 * Posted actuals: P sales 5,000 and S sales 2,000 (10 Jan). seedIntercompany adds a matched 1,000 charge P -> S (15 Jan).
 */
@IsTest
public class SABGroupAccountingTestFixture {
    public static final String MANAGER = 'SAB G18 Manager';
    public static final String APPROVER = 'SAB G18 Approver';
    public static final String OUTSIDER = 'SAB G18 Outsider';
    private static final List<String> CODES = new List<String>{'1100', '1400', '2400', '4000', '4100', '6100'};

    private static Map<String, User> users = new Map<String, User>();
    private static Map<String, Id> ids = new Map<String, Id>();

    public static void createFixture() {
        Map<String, User> created = new Map<String, User>();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            created.put(MANAGER, newUser(MANAGER, 'g18mgr', unique));
            created.put(APPROVER, newUser(APPROVER, 'g18apr', unique));
            created.put(OUTSIDER, newUser(OUTSIDER, 'g18out', unique));
            insert as system created.values();
            Map<String, Set<String>> setsByUser = new Map<String, Set<String>>{
                MANAGER => new Set<String>{'SAB_Group_Accounting_User', 'SAB_Manage_Intercompany_Action', 'SAB_Manage_Consolidation_Action',
                    'SAB_Post_Journal_Action'},
                APPROVER => new Set<String>{'SAB_Group_Accounting_User', 'SAB_Manage_Consolidation_Action', 'SAB_Approve_Consolidation_Action'},
                OUTSIDER => new Set<String>{'SAB_Group_Accounting_User', 'SAB_Manage_Intercompany_Action', 'SAB_Manage_Consolidation_Action',
                    'SAB_Post_Journal_Action'}};
            Map<String, Id> setIds = new Map<String, Id>();
            for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN ('SAB_Group_Accounting_User', 'SAB_Manage_Intercompany_Action',
                    'SAB_Manage_Consolidation_Action', 'SAB_Approve_Consolidation_Action', 'SAB_Post_Journal_Action') WITH SYSTEM_MODE]) {
                setIds.put(p.Name, p.Id);
            }
            System.assertEquals(5, setIds.size(), 'Deploy the G18 permission sets and SAB_Post_Journal_Action first.');
            List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
            for (String who : setsByUser.keySet()) {
                for (String name : setsByUser.get(who)) {
                    rows.add(new PermissionSetAssignment(AssigneeId = created.get(who).Id, PermissionSetId = setIds.get(name)));
                }
            }
            insert as system rows;
        }
        System.runAs(created.get(MANAGER)) {
            List<Accounting_Company__c> companies = new List<Accounting_Company__c>{company('P', 'USD'), company('S', 'USD'), company('J', 'USD'),
                company('E', 'EUR')};
            insert as system companies;
            Map<String, Id> byKey = new Map<String, Id>();
            for (Accounting_Company__c c : companies) {
                byKey.put(c.Company_Key__c.right(1), c.Id);
            }
            List<Company_User_Access__c> grants = new List<Company_User_Access__c>();
            for (String k : new List<String>{'P', 'S', 'J', 'E'}) {
                grants.add(grant(byKey.get(k), created.get(MANAGER).Id, 'G18-MGR-' + k));
            }
            for (String k : new List<String>{'P', 'S', 'J'}) {
                grants.add(grant(byKey.get(k), created.get(APPROVER).Id, 'G18-APR-' + k));
            }
            grants.add(grant(byKey.get('P'), created.get(OUTSIDER).Id, 'G18-OUT-P'));
            insert as system grants;
            List<Accounting_Period__c> periods = new List<Accounting_Period__c>();
            List<GL_Account__c> accounts = new List<GL_Account__c>();
            for (String k : new List<String>{'P', 'S'}) {
                for (Integer month = 1; month <= 3; month++) {
                    Date starts = Date.newInstance(2026, month, 1);
                    String key = 'G18' + k + '-2026-0' + month;
                    periods.add(new Accounting_Period__c(Name = key, Company__c = byKey.get(k), Company_Period_Key__c = key, Period_Key__c = key,
                        Start_Date__c = starts, End_Date__c = starts.addMonths(1).addDays(-1), Fiscal_Year__c = 2026, Fiscal_Quarter__c = 1,
                        Period_Number__c = month, Status__c = 'Open'));
                }
                Map<String, List<String>> defs = new Map<String, List<String>>{'1100' => new List<String>{'Bank', 'Asset', 'Debit'},
                    '1400' => new List<String>{'IC receivable', 'Asset', 'Debit'}, '2400' => new List<String>{'IC payable', 'Liability', 'Credit'},
                    '4000' => new List<String>{'Sales', 'Revenue', 'Credit'}, '4100' => new List<String>{'IC revenue', 'Revenue', 'Credit'},
                    '6100' => new List<String>{'IC expense', 'Expense', 'Debit'}};
                for (String code : CODES) {
                    List<String> d = defs.get(code);
                    accounts.add(new GL_Account__c(Name = d[0], Company__c = byKey.get(k), Company_Account_Key__c = 'G18' + k + '-' + code,
                        Account_Code__c = code, Account_Type__c = d[1], Normal_Balance__c = d[2], Is_Active__c = true, Is_Control_Account__c = false,
                        Control_Type__c = 'None', Manual_Posting_Allowed__c = true));
                }
            }
            insert as system periods;
            insert as system accounts;
            Consolidation_Group__c g = new Consolidation_Group__c(Name = 'G18 Group', Presentation_Currency__c = 'USD', Policy_Version__c = 'v1',
                Is_Active__c = true);
            insert as system g;
            insert as system new List<Consolidation_Member__c>{member(g.Id, byKey.get('P'), 'Subsidiary'), member(g.Id, byKey.get('S'), 'Subsidiary'),
                member(g.Id, byKey.get('J'), 'Joint Venture')};
            postPairs(new List<List<Object>>{
                new List<Object>{'P', Date.newInstance(2026, 1, 10), '1100', '4000', (Decimal) 5000},
                new List<Object>{'S', Date.newInstance(2026, 1, 10), '1100', '4000', (Decimal) 2000}});
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static Accounting_Company__c company(String key, String currencyCode) {
        return new Accounting_Company__c(Name__c = 'G18 Company ' + key, Company_Key__c = 'G18' + key, Country_Code__c = 'BD',
            Functional_Currency__c = currencyCode, Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active',
            Is_Active__c = true);
    }

    private static Company_User_Access__c grant(Id companyId, Id userId, String key) {
        return new Company_User_Access__c(Company__c = companyId, User__c = userId, Is_Active__c = true, Effective_From__c = Date.today().addDays(-1),
            Grant_Key__c = key, Role__c = 'Finance Manager');
    }

    private static Consolidation_Member__c member(Id groupId, Id companyId, String controlType) {
        return new Consolidation_Member__c(Consolidation_Group__c = groupId, Company__c = companyId, Control_Type__c = controlType,
            Ownership_Percent__c = 100, Effective_From__c = Date.newInstance(2026, 1, 1), Mapping_Version__c = 'CHART-1');
    }

    /** Posts balanced two-line journals {companyKey, date, debitCode, creditCode, amount} through the ledger posting context. */
    public static void postPairs(List<List<Object>> specs) {
        List<Journal_Entry__c> journals = new List<Journal_Entry__c>();
        for (List<Object> s : specs) {
            Date onDate = (Date) s[1];
            String companyKey = (String) s[0];
            journals.add(new Journal_Entry__c(Company__c = companyId(companyKey), Accounting_Period__c = periodId(companyKey, onDate.month()),
                Accounting_Date__c = onDate, Entry_Type__c = 'Manual', Status__c = 'Draft', Version__c = 1, Description__c = 'G18 seed'));
        }
        insert as system journals;
        List<Journal_Entry_Line__c> lines = new List<Journal_Entry_Line__c>();
        for (Integer i = 0; i < specs.size(); i++) {
            List<Object> s = specs[i];
            String companyKey = (String) s[0];
            Decimal amount = (Decimal) s[4];
            lines.add(line(journals[i].Id, 1, accountId(companyKey, (String) s[2]), amount, 0, (Date) s[1]));
            lines.add(line(journals[i].Id, 2, accountId(companyKey, (String) s[3]), 0, amount, (Date) s[1]));
        }
        insert as system lines;
        List<Journal_Entry__c> posted = new List<Journal_Entry__c>();
        for (Journal_Entry__c j : journals) {
            posted.add(new Journal_Entry__c(Id = j.Id, Status__c = 'Posted'));
        }
        SABLedgerMutationContext.beginPosting();
        try {
            update as system posted;
        } finally {
            SABLedgerMutationContext.endPosting();
        }
    }

    private static Journal_Entry_Line__c line(Id journalId, Integer n, Id accountId, Decimal debit, Decimal credit, Date onDate) {
        return new Journal_Entry_Line__c(Journal_Entry__c = journalId, Line_Number__c = n, GL_Account__c = accountId, Debit_Base__c = debit,
            Credit_Base__c = credit, Transaction_Amount__c = debit > 0 ? debit : credit, Transaction_Currency__c = 'USD', Functional_Currency__c = 'USD',
            Applied_Exchange_Rate__c = 1, Rate_Date__c = onDate, Rate_Source__c = 'Test', Explanation__c = 'G18 seed');
    }

    /** A matched 1,000 intercompany charge P -> S on 15 Jan with both sides posted (seeded, no service call). */
    public static Id seedIntercompany() {
        Date onDate = Date.newInstance(2026, 1, 15);
        postPairs(new List<List<Object>>{new List<Object>{'P', onDate, '1400', '4100', (Decimal) 1000},
            new List<Object>{'S', onDate, '6100', '2400', (Decimal) 1000}});
        Intercompany_Transaction__c ic = new Intercompany_Transaction__c(From_Company__c = companyId('P'), To_Company__c = companyId('S'),
            Transaction_Date__c = onDate, Agreed_Amount__c = 1000, Currency__c = 'USD', Description__c = 'Management fee',
            From_Receivable_Account__c = accountId('P', '1400'), From_Counter_Account__c = accountId('P', '4100'),
            To_Payable_Account__c = accountId('S', '2400'), To_Counter_Account__c = accountId('S', '6100'), Reconciliation_State__c = 'Matched');
        SABGroupAccountingGuard.beginWrite();
        try {
            insert as system ic;
        } finally {
            SABGroupAccountingGuard.endWrite();
        }
        return ic.Id;
    }

    private static User newUser(String lastName, String alias, String unique) {
        return new User(Username = alias + '.' + unique + '@example.invalid', Email = alias + '@example.invalid', LastName = lastName,
            Alias = alias, TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', ProfileId = UserInfo.getProfileId());
    }

    public static User user(String lastName) {
        if (!users.containsKey(lastName)) {
            users.put(lastName, [SELECT Id FROM User WHERE LastName = :lastName AND Alias LIKE 'g18%' WITH SYSTEM_MODE LIMIT 1]);
        }
        return users.get(lastName);
    }

    private static Id cached(String key, String soql) {
        if (!ids.containsKey(key)) {
            ids.put(key, Database.query(soql, AccessLevel.SYSTEM_MODE).Id);
        }
        return ids.get(key);
    }

    public static Id companyId(String key) {
        return cached('company' + key, 'SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = \'G18' + String.escapeSingleQuotes(key) + '\' LIMIT 1');
    }

    public static Id accountId(String companyKey, String code) {
        return cached('gl' + companyKey + code, 'SELECT Id FROM GL_Account__c WHERE Company_Account_Key__c = \'G18'
            + String.escapeSingleQuotes(companyKey) + '-' + String.escapeSingleQuotes(code) + '\' LIMIT 1');
    }

    private static Id periodId(String companyKey, Integer month) {
        return cached('period' + companyKey + month, 'SELECT Id FROM Accounting_Period__c WHERE Company_Period_Key__c = \'G18'
            + String.escapeSingleQuotes(companyKey) + '-2026-0' + month + '\' LIMIT 1');
    }

    public static Id groupId() {
        return cached('group', 'SELECT Id FROM Consolidation_Group__c WHERE Name = \'G18 Group\' LIMIT 1');
    }

    public static SABIntercompanyService.IntercompanyRequest intercompanyRequest(Decimal amount) {
        SABIntercompanyService.IntercompanyRequest r = new SABIntercompanyService.IntercompanyRequest();
        r.fromCompanyId = companyId('P');
        r.toCompanyId = companyId('S');
        r.transactionDate = Date.newInstance(2026, 2, 20);
        r.amount = amount;
        r.description = 'Shared services recharge';
        r.fromReceivableAccountId = accountId('P', '1400');
        r.fromCounterAccountId = accountId('P', '4100');
        r.toPayableAccountId = accountId('S', '2400');
        r.toCounterAccountId = accountId('S', '6100');
        return r;
    }
}
