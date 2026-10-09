/**
 * G19: shared test data for approval and close task tests, lean by design (SABTestGovernor rules).
 *
 * Users (System Administrator profile; access comes from the G19 permission sets and the existing action sets):
 *   requester  Approval User + Request Approval
 *   approverA  Approval User + Approve Financial Document + Close Task User (also the close task assignee)
 *   approverB  Approval User + Approve Financial Document + Close Task User
 *   manager    Close Task User + Manage Close Tasks + Close Period + Remaining Fields Admin (period-action audit fields)
 *   outsider   Approval User + Request Approval + Approve Financial Document, no company grant
 * Company 'A19' (USD): Jan and Feb 2026 Open; GL 4000 Sales (the approval source record in tests).
 */
@IsTest
public class SABApprovalCloseTestFixture {
    public static final String REQUESTER = 'SAB A19 Requester';
    public static final String APPROVER_A = 'SAB A19 Approver A';
    public static final String APPROVER_B = 'SAB A19 Approver B';
    public static final String MANAGER = 'SAB A19 Manager';
    public static final String OUTSIDER = 'SAB A19 Outsider';

    private static Map<String, User> users = new Map<String, User>();
    private static Map<String, Id> ids = new Map<String, Id>();

    public static void createFixture() {
        Map<String, User> created = new Map<String, User>();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            Map<String, String> aliases = new Map<String, String>{REQUESTER => 'a19req', APPROVER_A => 'a19apa', APPROVER_B => 'a19apb',
                MANAGER => 'a19mgr', OUTSIDER => 'a19out'};
            for (String name : aliases.keySet()) {
                created.put(name, new User(Username = aliases.get(name) + '.' + unique + '@example.invalid', Email = aliases.get(name) + '@example.invalid',
                    LastName = name, Alias = aliases.get(name), TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
                    LanguageLocaleKey = 'en_US', ProfileId = UserInfo.getProfileId()));
            }
            insert as system created.values();
            Map<String, Set<String>> setsByUser = new Map<String, Set<String>>{
                REQUESTER => new Set<String>{'SAB_Approval_User', 'SAB_Request_Approval_Action'},
                APPROVER_A => new Set<String>{'SAB_Approval_User', 'SAB_Approve_Financial_Document_Action', 'SAB_Close_Task_User'},
                APPROVER_B => new Set<String>{'SAB_Approval_User', 'SAB_Approve_Financial_Document_Action', 'SAB_Close_Task_User'},
                // Closing a period reads the period-action audit fields; like SABPeriodServiceTest, that access comes from Remaining Fields Admin.
                MANAGER => new Set<String>{'SAB_Close_Task_User', 'SAB_Manage_Close_Tasks_Action', 'SAB_Close_Period_Action', 'SAB_Remaining_Fields_Admin'},
                OUTSIDER => new Set<String>{'SAB_Approval_User', 'SAB_Request_Approval_Action', 'SAB_Approve_Financial_Document_Action'}};
            Set<String> names = new Set<String>();
            for (Set<String> s : setsByUser.values()) {
                names.addAll(s);
            }
            Map<String, Id> setIds = new Map<String, Id>();
            for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN :names WITH SYSTEM_MODE]) {
                setIds.put(p.Name, p.Id);
            }
            System.assertEquals(names.size(), setIds.size(), 'Deploy the G19 permission sets first; missing: ' + names);
            List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
            for (String who : setsByUser.keySet()) {
                for (String name : setsByUser.get(who)) {
                    rows.add(new PermissionSetAssignment(AssigneeId = created.get(who).Id, PermissionSetId = setIds.get(name)));
                }
            }
            insert as system rows;
        }
        System.runAs(created.get(MANAGER)) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'A19 Company', Company_Key__c = 'A19', Country_Code__c = 'BD',
                Functional_Currency__c = 'USD', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active',
                Is_Active__c = true);
            insert as system company;
            List<Company_User_Access__c> grants = new List<Company_User_Access__c>();
            for (String who : new List<String>{REQUESTER, APPROVER_A, APPROVER_B, MANAGER}) {
                grants.add(new Company_User_Access__c(Company__c = company.Id, User__c = created.get(who).Id, Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'A19-' + created.get(who).Alias, Role__c = 'Finance Manager'));
            }
            insert as system grants;
            List<Accounting_Period__c> periods = new List<Accounting_Period__c>();
            for (Integer month = 1; month <= 2; month++) {
                Date starts = Date.newInstance(2026, month, 1);
                String key = 'A19-2026-0' + month;
                periods.add(new Accounting_Period__c(Name = key, Company__c = company.Id, Company_Period_Key__c = key, Period_Key__c = key,
                    Start_Date__c = starts, End_Date__c = starts.addMonths(1).addDays(-1), Fiscal_Year__c = 2026, Fiscal_Quarter__c = 1,
                    Period_Number__c = month, Status__c = 'Open'));
            }
            insert as system periods;
            insert as system new GL_Account__c(Name = 'Sales', Company__c = company.Id, Company_Account_Key__c = 'A19-4000', Account_Code__c = '4000',
                Account_Type__c = 'Revenue', Normal_Balance__c = 'Credit', Is_Active__c = true, Is_Control_Account__c = false, Control_Type__c = 'None',
                Manual_Posting_Allowed__c = true);
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    public static User user(String lastName) {
        if (!users.containsKey(lastName)) {
            users.put(lastName, [SELECT Id FROM User WHERE LastName = :lastName AND Alias LIKE 'a19%' WITH SYSTEM_MODE LIMIT 1]);
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
        return cached('company', 'SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = \'A19\' LIMIT 1');
    }

    public static Id periodId(Integer month) {
        return cached('period' + month, 'SELECT Id FROM Accounting_Period__c WHERE Company_Period_Key__c = \'A19-2026-0' + month + '\' LIMIT 1');
    }

    public static Id sourceId() {
        return cached('source', 'SELECT Id FROM GL_Account__c WHERE Company_Account_Key__c = \'A19-4000\' LIMIT 1');
    }

    public static SABApprovalService.SubmissionRequest submission(List<String> approvers, Integer version) {
        SABApprovalService.SubmissionRequest r = new SABApprovalService.SubmissionRequest();
        r.companyId = companyId();
        r.sourceType = 'GL_Account__c';
        r.sourceRecordId = sourceId();
        r.sourceVersion = version;
        r.sourceBusinessKey = 'A19-4000';
        r.policyVersion = 'MANUAL-1';
        r.approverIds = new List<Id>();
        for (String name : approvers) {
            r.approverIds.add(user(name).Id);
        }
        return r;
    }

    public static SAB_Close_Task_Template__mdt template(String body) {
        return (SAB_Close_Task_Template__mdt) JSON.deserialize(body, SAB_Close_Task_Template__mdt.class);
    }
}
