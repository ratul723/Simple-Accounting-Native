@IsTest
private class SABProjectFinancialServiceTest {
    private static final Date FROM_DATE = Date.newInstance(2026, 1, 1);
    private static final Date TO_DATE = Date.newInstance(2026, 1, 31);
    @TestSetup static void setupData() {
        Id profileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce'
            AND PermissionsViewAllData = false AND PermissionsModifyAllData = false WITH SYSTEM_MODE LIMIT 1].Id;
        String seed = UserInfo.getOrganizationId() + '.' + System.now().getTime();
        List<User> users = new List<User>();
        for (String role : new List<String>{'owner', 'reader', 'denied', 'fls'}) {
            users.add(new User(Alias = role, LastName = 'G11B ' + role, ProfileId = profileId,
                Username = 'g11b.' + role + '.' + seed + '@example.invalid', Email = 'g11b@example.invalid',
                TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'));
        }
        insert as system users;
        Set<String> names = new Set<String>{'SAB_Remaining_Fields_Admin', 'SAB_Post_Journal_Action',
            'SAB_Reverse_Journal_Action', 'SAB_Project_Manager', 'SAB_Project_Financials_User'};
        Map<String, Id> permissionIds = new Map<String, Id>();
        for (PermissionSet row : [SELECT Id, Name FROM PermissionSet WHERE Name IN :names WITH SYSTEM_MODE]) { permissionIds.put(row.Name, row.Id); }
        System.assertEquals(5, permissionIds.size(), 'G11A and G11B dependencies must be deployed.');
        List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
        for (Id permissionId : permissionIds.values()) {
            assignments.add(new PermissionSetAssignment(AssigneeId = users[0].Id, PermissionSetId = permissionId));
        }
        assignments.add(new PermissionSetAssignment(AssigneeId = users[1].Id, PermissionSetId = permissionIds.get('SAB_Project_Financials_User')));
        insert as system assignments;
        PermissionSet actionOnly = new PermissionSet(Name = 'G11B_Test_Action_Only', Label = 'G11B Test Action Only');
        insert as system actionOnly;
        insert as system new SetupEntityAccess(ParentId = actionOnly.Id,
            SetupEntityId = [SELECT Id FROM CustomPermission WHERE DeveloperName = 'SAB_View_Project_Financials' WITH SYSTEM_MODE LIMIT 1].Id);
        insert as system new PermissionSetAssignment(AssigneeId = users[3].Id, PermissionSetId = actionOnly.Id);
        Test.startTest();
        System.enqueueJob(new Fixture());
        Test.stopTest();
    }
    private class Fixture implements Queueable {
        public void execute(QueueableContext context) {
            User owner = actor('owner'); User reader = actor('reader');
            System.runAs(owner) {
                List<Accounting_Company__c> companies = new List<Accounting_Company__c>();
                for (String key : new List<String>{'PB1', 'PB2'}) {
                    companies.add(new Accounting_Company__c(Name__c = key, Company_Key__c = key, Country_Code__c = 'BD',
                        Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1,
                        Setup_Status__c = 'Active', Is_Active__c = true));
                }
                insert as system companies;
                insert as system new List<Company_User_Access__c>{
                    grant(companies[0].Id, owner.Id, 'OWNER1'), grant(companies[1].Id, owner.Id, 'OWNER2'),
                    grant(companies[0].Id, reader.Id, 'READER'), grant(companies[0].Id, actor('denied').Id, 'DENIED'),
                    grant(companies[0].Id, actor('fls').Id, 'FLS')};
                List<Project__c> projects = new List<Project__c>{
                    new Project__c(Name = 'Primary', Company__c = companies[0].Id, Project_Code__c = 'PRIMARY'),
                    new Project__c(Name = 'Other', Company__c = companies[0].Id, Project_Code__c = 'OTHER'),
                    new Project__c(Name = 'Empty', Company__c = companies[0].Id, Project_Code__c = 'EMPTY'),
                    new Project__c(Name = 'Foreign', Company__c = companies[1].Id, Project_Code__c = 'FOREIGN')};
                insert as system projects;
                // Possessing a manual share must not substitute for company authorization.
                insert as system new Project__Share(ParentId = projects[3].Id, UserOrGroupId = reader.Id, AccessLevel = 'Read', RowCause = 'Manual');
                Accounting_Period__c period = new Accounting_Period__c(Name = 'G11B January', Company__c = companies[0].Id,
                    Company_Period_Key__c = 'PB1-JAN', Period_Key__c = 'JAN26', Start_Date__c = FROM_DATE, End_Date__c = TO_DATE,
                    Fiscal_Year__c = 2026, Fiscal_Quarter__c = 1, Period_Number__c = 1, Status__c = 'Open');
                insert as system period;
                List<GL_Account__c> accounts = new List<GL_Account__c>{
                    account(companies[0].Id, '1000', 'Asset', 'Debit'), account(companies[0].Id, '4000', 'Revenue', 'Credit'),
                    account(companies[0].Id, '6000', 'Expense', 'Debit')};
                insert as system accounts;
                Journal_Entry__c journal = draft(companies[0].Id, period.Id, 'G11B POSTED'); insert as system journal;
                Id p = projects[0].Id; Id other = projects[1].Id;
                List<Journal_Entry_Line__c> lines = new List<Journal_Entry_Line__c>{
                    line(journal.Id, accounts[1].Id, p, 1, 0, 1000), line(journal.Id, accounts[1].Id, p, 2, 100, 0),
                    line(journal.Id, accounts[2].Id, p, 3, 300, 0), line(journal.Id, accounts[2].Id, p, 4, 0, 50),
                    line(journal.Id, accounts[0].Id, p, 5, 650, 0), line(journal.Id, accounts[1].Id, other, 6, 0, 400),
                    line(journal.Id, accounts[2].Id, other, 7, 100, 0), line(journal.Id, accounts[0].Id, other, 8, 300, 0),
                    line(journal.Id, accounts[1].Id, null, 9, 0, 200), line(journal.Id, accounts[0].Id, null, 10, 200, 0)};
                insert as system lines;
                SABPostingService.postDraftJournal(postingRequest(journal, companies[0].Id));
                Journal_Entry__c pending = draft(companies[0].Id, period.Id, 'G11B DRAFT'); insert as system pending;
                insert as system new List<Journal_Entry_Line__c>{line(pending.Id, accounts[1].Id, p, 1, 0, 999), line(pending.Id, accounts[0].Id, p, 2, 999, 0)};
            }
        }
    }
    private static Company_User_Access__c grant(Id companyId, Id userId, String key) {
        return new Company_User_Access__c(Company__c = companyId, User__c = userId, Grant_Key__c = 'G11B-' + key,
            Role__c = 'Finance Manager', Is_Active__c = true, Effective_From__c = Date.today());
    }
    private static GL_Account__c account(Id companyId, String code, String type, String balance) {
        return new GL_Account__c(Name = type, Company__c = companyId, Company_Account_Key__c = companyId + ':' + code,
            Account_Code__c = code, Account_Type__c = type, Normal_Balance__c = balance, Is_Active__c = true,
            Is_Control_Account__c = false, Control_Type__c = 'None', Manual_Posting_Allowed__c = true);
    }
    private static Journal_Entry__c draft(Id companyId, Id periodId, String description) {
        return new Journal_Entry__c(Company__c = companyId, Accounting_Period__c = periodId,
            Accounting_Date__c = FROM_DATE.addDays(14), Entry_Type__c = 'Manual', Status__c = 'Draft', Version__c = 1, Description__c = description);
    }
    private static Journal_Entry_Line__c line(Id journalId, Id accountId, Id projectId, Integer lineNo, Decimal debit, Decimal credit) {
        return new Journal_Entry_Line__c(Journal_Entry__c = journalId, GL_Account__c = accountId, Project__c = projectId,
            Line_Number__c = lineNo, Debit_Base__c = debit, Credit_Base__c = credit, Functional_Currency__c = 'BDT', Explanation__c = 'G11B line ' + lineNo);
    }
    private static SABPostingService.PostingRequest postingRequest(Journal_Entry__c journal, Id companyId) {
        SABAccountingEventService.ReservationRequest event = new SABAccountingEventService.ReservationRequest();
        event.companyId = companyId; event.adapterKey = 'MANUAL_JOURNAL'; event.requestKey = 'REQ-G11B';
        event.eventKey = 'EVENT-G11B'; event.eventType = 'Manual Journal'; event.sourceBusinessKey = 'POST-G11B';
        event.sourceRecordId = String.valueOf(journal.Id); event.sourceType = 'Journal_Entry__c'; event.sourceVersion = 1;
        SABPostingService.PostingRequest request = new SABPostingService.PostingRequest();
        request.journalEntryId = journal.Id; request.postingKey = 'POST-G11B'; request.eventRequest = event; return request;
    }
    private static User actor(String role) { return [SELECT Id FROM User WHERE LastName = :('G11B ' + role) WITH SYSTEM_MODE LIMIT 1]; }
    private static Id project(String code) { return [SELECT Id FROM Project__c WHERE Project_Code__c = :code WITH SYSTEM_MODE LIMIT 1].Id; }
    private static SABProjectFinancialService.Report report(Id projectId) { return SABProjectFinancialService.getReport(projectId, FROM_DATE, TO_DATE); }

    @IsTest static void totalsUsePostedBaseAmountsAndIsolateProject() {
        Id projectId = project('PRIMARY');
        System.runAs(actor('reader')) {
            Test.startTest(); SABProjectFinancialService.Report result = report(projectId); Test.stopTest();
            System.assertEquals(900, result.revenue, 'Revenue credits minus debit adjustments.');
            System.assertEquals(250, result.expense, 'Expense debits minus credit adjustments.');
            System.assertEquals(650, result.profit, 'Profit is revenue less expense.');
            System.assertEquals(72.22, result.marginPercent, 'Margin rounds only after calculation.');
            System.assertEquals('BDT', result.currencyCode, 'Report uses company functional currency.');
            System.assertEquals(4, result.lineCount, 'Draft, assets, unassigned and other projects are excluded.');
            System.assertEquals(2, result.accounts.size(), 'Revenue and expense account totals.');
            System.assertEquals(900, result.accounts[0].amount, 'Account revenue reconciles.');
            System.assertEquals(250, result.accounts[1].amount, 'Account expense reconciles.');
            System.assertEquals(4, result.ledger.lines.size(), 'All selected financial lines are visible.');
            System.assertEquals(false, result.ledger.hasMore, 'Small reports have one page.');
            System.assertEquals('Primary', result.projectName, 'Project context returned.');
        }
    }
    @IsTest static void emptyAndOutsideDateRangeReturnZero() {
        Id empty = project('EMPTY'); Id primary = project('PRIMARY');
        System.runAs(actor('reader')) {
            Test.startTest();
            SABProjectFinancialService.Report result = report(empty);
            SABProjectFinancialService.Report outside = SABProjectFinancialService.getReport(primary, FROM_DATE, FROM_DATE.addDays(13));
            SABProjectFinancialService.Report boundary = SABProjectFinancialService.getReport(primary, FROM_DATE.addDays(14), FROM_DATE.addDays(14));
            Test.stopTest();
            System.assertEquals(0, result.profit, 'Empty project has zero profit.');
            System.assertEquals(null, result.marginPercent, 'Zero revenue has no defined margin.');
            System.assertEquals(0, outside.lineCount, 'Accounting date controls inclusion.');
            System.assertEquals(4, boundary.lineCount, 'Both date boundaries are inclusive.');
            System.assertEquals(0, result.accounts.size(), 'No invented account activity.');
        }
    }
    @IsTest static void keysetPagesDoNotRepeatOrSkipSameDateRows() {
        Id projectId = project('PRIMARY');
        System.runAs(actor('reader')) {
            Test.startTest();
            Set<Id> seen = new Set<Id>(); Date cursorDate; Id cursorId;
            for (Integer i = 0; i < 4; i++) {
                SABProjectFinancialService.LedgerPage page = SABProjectFinancialService.getLedgerPage(projectId, FROM_DATE, TO_DATE, cursorDate, cursorId, 1);
                System.assertEquals(1, page.lines.size(), 'One line per page.');
                System.assertEquals(false, seen.contains(page.lines[0].lineId), 'No duplicate line across pages.');
                seen.add(page.lines[0].lineId); cursorDate = page.nextDate; cursorId = page.nextId;
                System.assertEquals(i < 3, page.hasMore, 'Only the last page ends the sequence.');
            }
            SABProjectFinancialService.LedgerPage endPage = SABProjectFinancialService.getLedgerPage(projectId, FROM_DATE, TO_DATE, cursorDate, cursorId, 1);
            Test.stopTest();
            System.assertEquals(4, seen.size(), 'All financial lines reached.');
            System.assertEquals(0, endPage.lines.size(), 'No rows beyond the last cursor.');
        }
    }
    @IsTest static void missingActionPermissionIsDenied() {
        Id projectId = project('PRIMARY');
        System.runAs(actor('denied')) {
            Test.startTest();
            try { report(projectId); System.assert(false, 'Missing custom permission must fail.'); }
            catch (AuraHandledException ex) { System.assert(ex.getMessage().contains('View Project Financials'), ex.getMessage()); }
            Test.stopTest();
        }
    }
    @IsTest static void missingCrudFlsIsDenied() {
        Id projectId = project('PRIMARY');
        System.runAs(actor('fls')) {
            Test.startTest();
            try { report(projectId); System.assert(false, 'Custom permission alone must not grant data access.'); }
            catch (AuraHandledException ex) { System.assert(ex.getMessage().contains('object and field permissions'), ex.getMessage()); }
            Test.stopTest();
        }
    }
    @IsTest static void foreignProjectIsDeniedDespiteManualShare() {
        Id projectId = project('FOREIGN');
        System.runAs(actor('reader')) {
            Test.startTest();
            System.assertEquals(1, [SELECT COUNT() FROM Project__c WHERE Id = :projectId WITH USER_MODE], 'Fixture has a real manual share.');
            try { report(projectId); System.assert(false, 'A share cannot replace company authorization.'); }
            catch (AuraHandledException ex) { System.assert(ex.getMessage().contains('active company access'), ex.getMessage()); }
            Test.stopTest();
        }
    }
    @IsTest static void companyGrantDoesNotReplaceProjectRecordSharing() {
        Id projectId = project('PRIMARY'); User reader = actor('reader');
        List<Project__Share> shares = [SELECT Id FROM Project__Share WHERE ParentId = :projectId
            AND UserOrGroupId = :reader.Id AND RowCause = 'Manual' WITH SYSTEM_MODE];
        System.assertEquals(1, shares.size(), 'The fixture provides one company-managed project share.');
        delete as system shares;
        System.runAs(reader) {
            Test.startTest();
            try { report(projectId); System.assert(false, 'A company grant must not bypass private record sharing.'); }
            catch (AuraHandledException ex) { System.assert(ex.getMessage().contains('Project unavailable'), ex.getMessage()); }
            Test.stopTest();
        }
    }
    @IsTest static void revokedAccessInvalidatesPreviouslySuccessfulReport() {
        Id projectId = project('PRIMARY');
        User reader = actor('reader');
        User owner = actor('owner');

        Company_User_Access__c access = [
            SELECT Id
            FROM Company_User_Access__c
            WHERE Grant_Key__c = 'G11B-READER'
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        Test.startTest();

        System.runAs(reader) {
            System.assertEquals(
                650,
                report(projectId).profit,
                'Initially authorized.'
            );
        }

        System.runAs(owner) {
            delete as user access;
        }

        System.runAs(reader) {
            try {
                report(projectId);
                System.assert(
                    false,
                    'Revoked company access must fail immediately.'
                );
            } catch (AuraHandledException ex) {
                System.assert(
                    ex.getMessage().contains('active company access'),
                    ex.getMessage()
                );
            }
        }

        Test.stopTest();
    }
    @IsTest static void invalidInputsAndInteractiveLimitAreRejected() {
        Id projectId = project('PRIMARY');
        System.runAs(actor('reader')) {
            Test.startTest();
            try { SABProjectFinancialService.getReport(null, FROM_DATE, TO_DATE); System.assert(false, 'Null project must fail.'); }
            catch (AuraHandledException ex) { System.assert(ex.getMessage().contains('Select a Project'), ex.getMessage()); }
            try { SABProjectFinancialService.getReport(projectId, TO_DATE, FROM_DATE); System.assert(false, 'Reversed dates must fail.'); }
            catch (AuraHandledException ex) { System.assert(ex.getMessage().contains('valid start and end'), ex.getMessage()); }
            try { SABProjectFinancialService.getLedgerPage(projectId, FROM_DATE, TO_DATE, null, null, 101); System.assert(false, 'Oversize page must fail.'); }
            catch (AuraHandledException ex) { System.assert(ex.getMessage().contains('between 1 and 100'), ex.getMessage()); }
            try { SABProjectFinancialService.getLedgerPage(projectId, FROM_DATE, TO_DATE, FROM_DATE, null, 10); System.assert(false, 'Partial cursor must fail.'); }
            catch (AuraHandledException ex) { System.assert(ex.getMessage().contains('both ledger cursor'), ex.getMessage()); }
            try { SABProjectFinancialService.getLedgerPage(projectId, FROM_DATE, TO_DATE, FROM_DATE, projectId, 10); System.assert(false, 'Foreign cursor must fail.'); }
            catch (AuraHandledException ex) { System.assert(ex.getMessage().contains('cursor is no longer valid'), ex.getMessage()); }
            SABProjectFinancialService.maxReportLines = 1;
            try { report(projectId); System.assert(false, 'Large scope must fail instead of truncating totals.'); }
            catch (AuraHandledException ex) { System.assert(ex.getMessage().contains('interactive ledger limit'), ex.getMessage()); }
            Test.stopTest();
        }
    }
    @IsTest static void reversalOffsetsOriginalAndPreservesEarlierPeriod() {
        Id projectId = project('PRIMARY');
        Journal_Entry__c journal = [SELECT Id, Accounting_Period__c FROM Journal_Entry__c WHERE Description__c = 'G11B POSTED' WITH SYSTEM_MODE LIMIT 1];
        System.runAs(actor('owner')) {
            SABReversalService.ReversalRequest request = new SABReversalService.ReversalRequest();
            request.originalJournalEntryId = journal.Id; request.reversalAccountingPeriodId = journal.Accounting_Period__c;
            request.reversalAccountingDate = FROM_DATE.addDays(20); request.postingKey = 'REV-G11B'; request.eventKey = 'REVEVENT-G11B';
            request.requestKey = 'REVREQ-G11B'; request.reason = 'G11B reversal regression';
            Test.startTest();
            SABReversalService.reversePostedJournal(request);
            SABProjectFinancialService.Report full = report(projectId);
            SABProjectFinancialService.Report earlier = SABProjectFinancialService.getReport(projectId, FROM_DATE, FROM_DATE.addDays(19));
            SABProjectFinancialService.Report reversalOnly = SABProjectFinancialService.getReport(projectId, FROM_DATE.addDays(20), TO_DATE);
            Test.stopTest();
            System.assertEquals(0, full.revenue, 'Original plus reversal nets revenue to zero.');
            System.assertEquals(0, full.expense, 'Original plus reversal nets expenses to zero.');
            System.assertEquals(8, full.lineCount, 'Both original Reversed and Posted reversing lines are retained.');
            System.assertEquals(650, earlier.profit, 'Later reversal does not erase earlier period profit.');
            System.assertEquals(-650, reversalOnly.profit, 'Reversal period carries the correcting loss.');
            System.assertEquals(null, reversalOnly.marginPercent, 'Negative revenue has no displayed margin.');
        }
    }
}
