/**
 * G17: shared test data for equity tests, lean by design (SABTestGovernor rules).
 *
 * Users (System Administrator profile; access comes from the G17 permission sets):
 *   manager   Equity User + Manage Equity + Post Journal
 *   approver  Equity User + Approve Equity + Post Journal
 *   outsider  Equity User + Manage Equity, no company grant
 * Company 'E17' (USD): periods Jan-Mar 2026 Open. GL 1100 Bank, 2600 Dividends payable, 3000 Share capital,
 * 3100 Share premium, 3200 Retained earnings, 4000 Sales. USD bank account on 1100. Share class ORD (par 1.00);
 * stakeholders A and B holding 600 and 400 units from posted issues on 5 Jan (seeded, no journals).
 */
@IsTest
public class SABEquityTestFixture {
    public static final String MANAGER = 'SAB E17 Manager';
    public static final String APPROVER = 'SAB E17 Approver';
    public static final String OUTSIDER = 'SAB E17 Outsider';

    private static Map<String, User> users = new Map<String, User>();
    private static Map<String, Id> ids = new Map<String, Id>();

    public static void createFixture() {
        User managerUser;
        User approverUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            managerUser = newUser(MANAGER, 'e17mgr', unique);
            approverUser = newUser(APPROVER, 'e17apr', unique);
            User outsiderUser = newUser(OUTSIDER, 'e17out', unique);
            insert as system new List<User>{managerUser, approverUser, outsiderUser};
            Map<Id, Set<String>> setsByUser = new Map<Id, Set<String>>{
                managerUser.Id => new Set<String>{'SAB_Equity_User', 'SAB_Manage_Equity_Action', 'SAB_Post_Journal_Action'},
                approverUser.Id => new Set<String>{'SAB_Equity_User', 'SAB_Approve_Equity_Action', 'SAB_Post_Journal_Action'},
                outsiderUser.Id => new Set<String>{'SAB_Equity_User', 'SAB_Manage_Equity_Action'}};
            Map<String, Id> setIds = new Map<String, Id>();
            for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN ('SAB_Equity_User', 'SAB_Manage_Equity_Action',
                    'SAB_Approve_Equity_Action', 'SAB_Post_Journal_Action') WITH SYSTEM_MODE]) {
                setIds.put(p.Name, p.Id);
            }
            System.assertEquals(4, setIds.size(), 'Deploy the G17 permission sets and SAB_Post_Journal_Action first.');
            List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
            for (Id userId : setsByUser.keySet()) {
                for (String name : setsByUser.get(userId)) {
                    rows.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = setIds.get(name)));
                }
            }
            insert as system rows;
        }
        System.runAs(managerUser) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'E17 Company', Company_Key__c = 'E17', Country_Code__c = 'BD',
                Functional_Currency__c = 'USD', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active', Is_Active__c = true);
            insert as system company;
            insert as system new List<Company_User_Access__c>{
                new Company_User_Access__c(Company__c = company.Id, User__c = managerUser.Id, Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'E17-MANAGER', Role__c = 'Finance Manager'),
                new Company_User_Access__c(Company__c = company.Id, User__c = approverUser.Id, Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'E17-APPROVER', Role__c = 'Finance Manager')};
            List<Accounting_Period__c> periods = new List<Accounting_Period__c>();
            for (Integer month = 1; month <= 3; month++) {
                Date starts = Date.newInstance(2026, month, 1);
                String key = 'E17-2026-0' + month;
                periods.add(new Accounting_Period__c(Name = key, Company__c = company.Id, Company_Period_Key__c = key, Period_Key__c = key,
                    Start_Date__c = starts, End_Date__c = starts.addMonths(1).addDays(-1), Fiscal_Year__c = 2026, Fiscal_Quarter__c = 1,
                    Period_Number__c = month, Status__c = 'Open'));
            }
            insert as system periods;
            Map<String, List<String>> accounts = new Map<String, List<String>>{
                '1100' => new List<String>{'Bank', 'Asset', 'Debit'}, '2600' => new List<String>{'Dividends payable', 'Liability', 'Credit'},
                '3000' => new List<String>{'Share capital', 'Equity', 'Credit'}, '3100' => new List<String>{'Share premium', 'Equity', 'Credit'},
                '3200' => new List<String>{'Retained earnings', 'Equity', 'Credit'}, '4000' => new List<String>{'Sales', 'Revenue', 'Credit'}};
            List<GL_Account__c> rows = new List<GL_Account__c>();
            for (String code : accounts.keySet()) {
                List<String> a = accounts.get(code);
                rows.add(new GL_Account__c(Name = a[0], Company__c = company.Id, Company_Account_Key__c = 'E17-' + code, Account_Code__c = code,
                    Account_Type__c = a[1], Normal_Balance__c = a[2], Is_Active__c = true, Is_Control_Account__c = false, Control_Type__c = 'None',
                    Manual_Posting_Allowed__c = true));
            }
            insert as system rows;
            insert as system new Bank_Account__c(Name = 'E17 Operating', Company__c = company.Id, Currency__c = 'USD',
                GL_Account__c = accountId('1100'), Is_Active__c = true);
            insert as system new Equity_Class__c(Name = 'Ordinary', Company__c = company.Id, Class_Code__c = 'ORD', Par_Value__c = 1,
                Capital_Account__c = accountId('3000'), Premium_Account__c = accountId('3100'), Is_Active__c = true);
            List<Stakeholder__c> holders = new List<Stakeholder__c>{
                new Stakeholder__c(Name = 'Alpha Holdings', Company__c = company.Id, Stakeholder_Reference__c = 'A', Stakeholder_Key__c = company.Id + '|A',
                    Status__c = 'Active'),
                new Stakeholder__c(Name = 'Beta Partners', Company__c = company.Id, Stakeholder_Reference__c = 'B', Stakeholder_Key__c = company.Id + '|B',
                    Status__c = 'Active')};
            insert as system holders;
            seedPostedIssues(new Map<Id, Decimal>{holders[0].Id => 600, holders[1].Id => 400});
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static void seedPostedIssues(Map<Id, Decimal> unitsByHolder) {
        List<Equity_Transaction__c> rows = new List<Equity_Transaction__c>();
        for (Id holder : unitsByHolder.keySet()) {
            rows.add(new Equity_Transaction__c(Company__c = companyId(), Equity_Class__c = classId(), Stakeholder__c = holder,
                Transaction_Type__c = 'Issue', Transaction_Date__c = Date.newInstance(2026, 1, 5), Units__c = unitsByHolder.get(holder),
                Value__c = unitsByHolder.get(holder), Currency__c = 'USD', Status__c = 'Posted'));
        }
        SABEquityGuard.beginWrite();
        try {
            insert as system rows;
        } finally {
            SABEquityGuard.endWrite();
        }
    }

    private static User newUser(String lastName, String alias, String unique) {
        return new User(Username = alias + '.' + unique + '@example.invalid', Email = alias + '@example.invalid', LastName = lastName,
            Alias = alias, TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', ProfileId = UserInfo.getProfileId());
    }

    public static User user(String lastName) {
        if (!users.containsKey(lastName)) {
            users.put(lastName, [SELECT Id FROM User WHERE LastName = :lastName AND Alias LIKE 'e17%' WITH SYSTEM_MODE LIMIT 1]);
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
        return cached('company', 'SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = \'E17\' LIMIT 1');
    }

    public static Id accountId(String code) {
        return cached('gl' + code, 'SELECT Id FROM GL_Account__c WHERE Company_Account_Key__c = \'E17-' + String.escapeSingleQuotes(code) + '\' LIMIT 1');
    }

    public static Id bankAccountId() {
        return cached('bank', 'SELECT Id FROM Bank_Account__c WHERE Name = \'E17 Operating\' LIMIT 1');
    }

    public static Id classId() {
        return cached('class', 'SELECT Id FROM Equity_Class__c WHERE Class_Code__c = \'ORD\' LIMIT 1');
    }

    public static Id stakeholderId(String reference) {
        return cached('holder' + reference, 'SELECT Id FROM Stakeholder__c WHERE Stakeholder_Reference__c = \'' + String.escapeSingleQuotes(reference)
            + '\' LIMIT 1');
    }

    public static SABEquityService.TransactionRequest transaction(String type, String holder, Decimal units, Decimal value) {
        SABEquityService.TransactionRequest r = new SABEquityService.TransactionRequest();
        r.companyId = companyId();
        r.classId = classId();
        r.stakeholderId = stakeholderId(holder);
        r.transactionType = type;
        r.transactionDate = Date.newInstance(2026, 2, 10);
        r.units = units;
        r.value = value;
        r.bankAccountId = bankAccountId();
        return r;
    }

    public static SABDistributionService.DistributionRequest distribution(Decimal total) {
        SABDistributionService.DistributionRequest r = new SABDistributionService.DistributionRequest();
        r.companyId = companyId();
        r.classId = classId();
        r.distributionType = 'Dividend';
        r.declarationDate = Date.newInstance(2026, 2, 15);
        r.recordDate = Date.newInstance(2026, 2, 10);
        r.paymentDueDate = Date.newInstance(2026, 3, 1);
        r.totalAmount = total;
        r.sourceAccountId = accountId('3200');
        r.payableAccountId = accountId('2600');
        r.bankAccountId = bankAccountId();
        return r;
    }

    /** A declared (Posted Payable) distribution of 1,000 with lines A 600 and B 400, seeded without journals; paidHolders start Paid. */
    public static Id seedDeclared(Set<String> paidHolders) {
        SABDistributionService.DistributionRequest r = distribution(1000);
        Distribution__c d = new Distribution__c(Company__c = r.companyId, Equity_Class__c = r.classId, Distribution_Type__c = 'Dividend',
            Declaration_Date__c = r.declarationDate, Record_Date__c = r.recordDate, Payment_Due_Date__c = r.paymentDueDate, Total_Amount__c = 1000,
            Currency__c = 'USD', Source_Account__c = r.sourceAccountId, Payable_Account__c = r.payableAccountId, Bank_Account__c = r.bankAccountId,
            Status__c = paidHolders.isEmpty() ? 'Posted Payable' : 'Part Settled');
        SABEquityGuard.beginWrite();
        try {
            insert as system d;
            insert as system new List<Distribution_Line__c>{
                new Distribution_Line__c(Distribution__c = d.Id, Stakeholder__c = stakeholderId('A'), Entitled_Units__c = 600, Entitled_Amount__c = 600,
                    Settlement_State__c = paidHolders.contains('A') ? 'Paid' : 'Unpaid'),
                new Distribution_Line__c(Distribution__c = d.Id, Stakeholder__c = stakeholderId('B'), Entitled_Units__c = 400, Entitled_Amount__c = 400,
                    Settlement_State__c = paidHolders.contains('B') ? 'Paid' : 'Unpaid')};
        } finally {
            SABEquityGuard.endWrite();
        }
        return d.Id;
    }

    /** A Succeeded disbursement tagged with a distribution, seeded through the G17 scope and the payment mutation context. */
    public static Id seedTaggedPayment(Id distributionId) {
        Accounting_Payment__c payment = new Accounting_Payment__c(Company__c = companyId(), Bank_Account__c = bankAccountId(),
            Direction__c = 'Disbursement', Method__c = 'Bank Transfer', Amount__c = 600, Transaction_Currency__c = 'USD', Functional_Currency__c = 'USD',
            Exchange_Rate__c = 1, Effective_Date__c = Date.newInstance(2026, 3, 1), Distribution__c = distributionId);
        SABEquityGuard.beginWrite();
        try {
            insert as system payment;
            SABAccountingPaymentMutationContext.beginMutation();
            try {
                update as system new Accounting_Payment__c(Id = payment.Id, Processing_State__c = 'Succeeded');
            } finally {
                SABAccountingPaymentMutationContext.endMutation();
            }
        } finally {
            SABEquityGuard.endWrite();
        }
        return payment.Id;
    }
}
