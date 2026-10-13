/**
 * G22A shared test fixture for the app shell and Finance home.
 *
 * @TestSetup data stays inside the 50-query cap: one user (running user's System Administrator profile)
 * with SAB_Remaining_Fields_Admin, SAB_App_User and SAB_Post_Journal_Action; one Active company with a
 * grant, the current month's open period, cash, revenue and expense accounts (one bulk insert) and an
 * active bank account. Tests that need a draft journal or a company in setup seed it themselves through
 * seedDraftJournal() and seedSetupCompany(), outside their test window.
 */
@IsTest
public class SABAppShellTestFixture {

    public static final String ACTIVE_KEY = 'G22A';
    public static final String SETUP_KEY = 'G22S';
    public static final String USER_LAST_NAME = 'SAB G22A Shell User';
    public static final List<String> BASE_PERMISSION_SETS = new List<String>{
        'SAB_Remaining_Fields_Admin', 'SAB_App_User', 'SAB_Post_Journal_Action'
    };

    public static void seed() {
        User user = createUser('sabg22a', USER_LAST_NAME, BASE_PERMISSION_SETS);
        System.runAs(user) {
            Accounting_Company__c company = company(ACTIVE_KEY, 'Harbourline Trading Test', 'Active');
            insert as system company;
            insert as system new Company_User_Access__c(Company__c = company.Id, User__c = user.Id, Effective_From__c = Date.today(),
                Grant_Key__c = 'G22A-GRANT', Is_Active__c = true, Role__c = 'Finance Manager');
            insert as system currentPeriod(company.Id);
            List<GL_Account__c> accounts = new List<GL_Account__c>{
                account(company.Id, '1000', 'Operating account', 'Asset', 'Debit'),
                account(company.Id, '4000', 'Sales revenue', 'Revenue', 'Credit'),
                account(company.Id, '6000', 'Office expenses', 'Expense', 'Debit')
            };
            insert as system accounts;
            insert as system new Bank_Account__c(Name = 'Operating', Company__c = company.Id, Bank_Name__c = 'Test Bank',
                Currency__c = 'AUD', GL_Account__c = accounts[0].Id, Is_Active__c = true);
        }
    }

    /** Draft journal Dr 1000 / Cr 4000 for 500 in the current period. Call as the fixture user, outside the test window. */
    public static Journal_Entry__c seedDraftJournal() {
        Id companyId = companyId(ACTIVE_KEY);
        Date today = Date.today();
        Id periodId = [
            SELECT Id FROM Accounting_Period__c
            WHERE Company__c = :companyId AND Start_Date__c <= :today AND End_Date__c >= :today
            WITH SYSTEM_MODE LIMIT 1
        ].Id;
        Map<String, Id> accountIds = new Map<String, Id>();
        for (GL_Account__c account : [SELECT Id, Account_Code__c FROM GL_Account__c WHERE Company__c = :companyId WITH SYSTEM_MODE]) {
            accountIds.put(account.Account_Code__c, account.Id);
        }
        Journal_Entry__c journal = new Journal_Entry__c(Company__c = companyId, Accounting_Period__c = periodId,
            Accounting_Date__c = today, Entry_Type__c = 'Manual', Status__c = 'Draft',
            Description__c = 'Fixture draft journal', Version__c = 1);
        insert as system journal;
        insert as system new List<Journal_Entry_Line__c>{
            line(journal.Id, accountIds.get('1000'), 1, 500, 0),
            line(journal.Id, accountIds.get('4000'), 2, 0, 500)
        };
        return journal;
    }

    /** A company still in setup with a grant for the given user. */
    public static Id seedSetupCompany(Id userId) {
        Accounting_Company__c company = company(SETUP_KEY, 'Harbourline Setup Test', 'In Progress');
        insert as system company;
        insert as system new Company_User_Access__c(Company__c = company.Id, User__c = userId, Effective_From__c = Date.today(),
            Grant_Key__c = 'G22S-GRANT', Is_Active__c = true, Role__c = 'Finance Manager');
        return company.Id;
    }

    public static User createUser(String alias, String lastName, List<String> permissionSetNames) {
        String seed = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
        User user = new User(Alias = alias, Email = alias + '.' + seed + '@example.test', EmailEncodingKey = 'UTF-8',
            LastName = lastName, FirstName = 'Alex', LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_AU',
            ProfileId = UserInfo.getProfileId(), TimeZoneSidKey = 'Australia/Sydney', Username = alias + '.' + seed + '@example.test');
        insert as system user;
        if (!permissionSetNames.isEmpty()) {
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (PermissionSet permissionSet : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSetNames WITH SYSTEM_MODE]) {
                assignments.add(new PermissionSetAssignment(AssigneeId = user.Id, PermissionSetId = permissionSet.Id));
            }
            System.assertEquals(permissionSetNames.size(), assignments.size(), 'Every fixture permission set must exist.');
            insert as system assignments;
        }
        return user;
    }

    public static User fixtureUser() {
        return [SELECT Id FROM User WHERE LastName = :USER_LAST_NAME WITH SYSTEM_MODE LIMIT 1];
    }

    public static Id companyId(String key) {
        return [SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = :key WITH SYSTEM_MODE LIMIT 1].Id;
    }

    public static Journal_Entry_Line__c line(Id journalId, Id accountId, Integer lineNumber, Decimal debit, Decimal credit) {
        return new Journal_Entry_Line__c(Journal_Entry__c = journalId, GL_Account__c = accountId, Line_Number__c = lineNumber,
            Debit_Base__c = debit, Credit_Base__c = credit, Functional_Currency__c = 'AUD', Explanation__c = 'G22A fixture line');
    }

    private static Accounting_Company__c company(String key, String name, String setupStatus) {
        Accounting_Company__c company = new Accounting_Company__c(Name__c = name, Company_Key__c = key, Country_Code__c = 'AU',
            Functional_Currency__c = 'AUD', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1,
            Setup_Status__c = setupStatus, Is_Active__c = true);
        return company;
    }

    private static Accounting_Period__c currentPeriod(Id companyId) {
        Date startDate = Date.today().toStartOfMonth();
        Date endDate = startDate.addMonths(1).addDays(-1);
        String suffix = ACTIVE_KEY + '-' + startDate.year() + '-' + startDate.month();
        Accounting_Period__c period = new Accounting_Period__c(Name = 'Period ' + suffix, Company__c = companyId,
            Company_Period_Key__c = 'CP-' + suffix, Period_Key__c = 'P-' + suffix, Start_Date__c = startDate,
            End_Date__c = endDate, Fiscal_Year__c = startDate.year(), Fiscal_Quarter__c = ((startDate.month() - 1) / 3) + 1,
            Period_Number__c = startDate.month(), Status__c = 'Open');
        return period;
    }

    private static GL_Account__c account(Id companyId, String code, String name, String type, String normalBalance) {
        GL_Account__c account = new GL_Account__c(Name = name, Company__c = companyId,
            Company_Account_Key__c = String.valueOf(companyId) + '-' + code, Account_Code__c = code, Account_Type__c = type,
            Normal_Balance__c = normalBalance, Is_Active__c = true, Is_Control_Account__c = false, Control_Type__c = 'None',
            Manual_Posting_Allowed__c = true);
        return account;
    }
}