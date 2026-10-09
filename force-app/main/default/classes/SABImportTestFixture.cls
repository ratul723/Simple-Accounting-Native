/**
 * G20: shared test data for import and integration tests, lean by design (SABTestGovernor rules).
 *
 * Users (System Administrator profile; access comes from the G20 permission sets):
 *   importer  Import User + Manage Imports + Commit Imports + View Integration Log
 *   outsider  Import User + Manage Imports + View Integration Log, no company grant
 * Company 'I20' (USD): Jan 2026 Open, Feb 2026 Closed. GL 1100 Bank, 1200 Receivables (AR control), 4000 Sales.
 */
@IsTest
public class SABImportTestFixture {
    public static final String IMPORTER = 'SAB I20 Importer';
    public static final String OUTSIDER = 'SAB I20 Outsider';

    private static Map<String, User> users = new Map<String, User>();

    public static void createFixture() {
        Map<String, User> created = new Map<String, User>();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            for (List<String> u : new List<List<String>>{new List<String>{IMPORTER, 'i20imp'}, new List<String>{OUTSIDER, 'i20out'}}) {
                created.put(u[0], new User(Username = u[1] + '.' + unique + '@example.invalid', Email = u[1] + '@example.invalid', LastName = u[0],
                    Alias = u[1], TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US',
                    ProfileId = UserInfo.getProfileId()));
            }
            insert as system created.values();
            Map<String, Set<String>> setsByUser = new Map<String, Set<String>>{
                IMPORTER => new Set<String>{'SAB_Import_User', 'SAB_Manage_Imports_Action', 'SAB_Commit_Imports_Action', 'SAB_View_Integration_Log_Action'},
                OUTSIDER => new Set<String>{'SAB_Import_User', 'SAB_Manage_Imports_Action', 'SAB_View_Integration_Log_Action'}};
            Map<String, Id> setIds = new Map<String, Id>();
            for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN ('SAB_Import_User', 'SAB_Manage_Imports_Action',
                    'SAB_Commit_Imports_Action', 'SAB_View_Integration_Log_Action') WITH SYSTEM_MODE]) {
                setIds.put(p.Name, p.Id);
            }
            System.assertEquals(4, setIds.size(), 'Deploy the G20 permission sets first.');
            List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
            for (String who : setsByUser.keySet()) {
                for (String name : setsByUser.get(who)) {
                    rows.add(new PermissionSetAssignment(AssigneeId = created.get(who).Id, PermissionSetId = setIds.get(name)));
                }
            }
            insert as system rows;
        }
        System.runAs(created.get(IMPORTER)) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'I20 Company', Company_Key__c = 'I20', Country_Code__c = 'BD',
                Functional_Currency__c = 'USD', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active',
                Is_Active__c = true);
            insert as system company;
            insert as system new Company_User_Access__c(Company__c = company.Id, User__c = created.get(IMPORTER).Id, Is_Active__c = true,
                Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'I20-IMPORTER', Role__c = 'Finance Manager');
            insert as system new List<Accounting_Period__c>{
                new Accounting_Period__c(Name = 'I20-2026-01', Company__c = company.Id, Company_Period_Key__c = 'I20-2026-01', Period_Key__c = 'I20-2026-01',
                    Start_Date__c = Date.newInstance(2026, 1, 1), End_Date__c = Date.newInstance(2026, 1, 31), Fiscal_Year__c = 2026, Fiscal_Quarter__c = 1,
                    Period_Number__c = 1, Status__c = 'Open'),
                new Accounting_Period__c(Name = 'I20-2026-02', Company__c = company.Id, Company_Period_Key__c = 'I20-2026-02', Period_Key__c = 'I20-2026-02',
                    Start_Date__c = Date.newInstance(2026, 2, 1), End_Date__c = Date.newInstance(2026, 2, 28), Fiscal_Year__c = 2026, Fiscal_Quarter__c = 1,
                    Period_Number__c = 2, Status__c = 'Closed', Closed_At__c = System.now(), Closed_By__c = UserInfo.getUserId())};
            insert as system new List<GL_Account__c>{gl(company.Id, '1100', 'Bank', 'Asset', 'Debit', 'None'),
                gl(company.Id, '1200', 'Receivables', 'Asset', 'Debit', 'AR'), gl(company.Id, '4000', 'Sales', 'Revenue', 'Credit', 'None')};
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static GL_Account__c gl(Id companyId, String code, String label, String type, String balance, String control) {
        return new GL_Account__c(Name = label, Company__c = companyId, Company_Account_Key__c = companyId + '-' + code, Account_Code__c = code,
            Account_Type__c = type, Normal_Balance__c = balance, Is_Active__c = true, Is_Control_Account__c = control != 'None', Control_Type__c = control,
            Manual_Posting_Allowed__c = control == 'None');
    }

    public static User user(String lastName) {
        if (!users.containsKey(lastName)) {
            users.put(lastName, [SELECT Id FROM User WHERE LastName = :lastName AND Alias LIKE 'i20%' WITH SYSTEM_MODE LIMIT 1]);
        }
        return users.get(lastName);
    }

    public static Id companyId() {
        return [SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = 'I20' WITH SYSTEM_MODE LIMIT 1].Id;
    }
}
