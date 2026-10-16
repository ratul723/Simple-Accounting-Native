@IsTest
private class SABAppShellControllerTest {

    @TestSetup
    static void setupData() {
        SABAppShellTestFixture.seed();
        SABTestGovernor.assertSetupWithin(50);
    }

    @IsTest
    static void shellContextCarriesPersonaWorkspacesAndPeriod() {
        Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
        SABAppShellController.ShellContext context;
        Test.startTest();
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            context = SABAppShellController.getShellContext(companyId);
        }
        Test.stopTest();
        System.assertEquals(SABPersonaService.BOOKKEEPER, context.persona.key, 'Post journal permission gives Bookkeeper.');
        System.assert(context.visibleWorkspaces.contains('home'), 'SAB_App_User grants Finance home.');
        System.assert(context.visibleWorkspaces.contains('journal'), 'Journal access shows Journals.');
        System.assert(!context.visibleWorkspaces.contains('projects'), 'Optional modules need their view permission.');
        System.assertNotEquals(null, context.disabledFeatures, 'Disabled features are listed.');
        System.assertEquals(false, context.companyInactive, 'The fixture company is active.');
        System.assertEquals(context.visibleWorkspaces.contains('customers'), context.visibleWorkspaces.contains('suppliers'),
            'Customers and Suppliers follow the same access rule.');
        System.assert(!context.visibleWorkspaces.contains('allocations'), 'Allocations need SAB_View_Allocations.');
        System.assert(!context.visibleWorkspaces.contains('fx') && !context.visibleWorkspaces.contains('expenses'), 'FX and expenses need their view permissions.');
        System.assert(context.hasPeriod, 'The current month period is found.');
        System.assertEquals('Open', context.periodStatus, 'Period status is returned.');
        System.assertEquals(Date.today().toStartOfMonth(), context.periodStart, 'Period start is returned.');
        System.assertNotEquals(null, context.userId, 'User id keys the theme preference.');
        System.assert(!context.canCreateCompany, 'Creating companies needs its own permission.');
    }

    @IsTest
    static void featureSwitchesControlModules() {
        Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
        insert as system new List<Company_Feature__c>{
            new Company_Feature__c(Company__c = companyId, Company_Feature_Key__c = 'G22A-PAYROLL', Feature_Key__c = 'PAYROLL',
                Enabled__c = false, Configuration_Status__c = 'Not Configured'),
            new Company_Feature__c(Company__c = companyId, Company_Feature_Key__c = 'G22A-PROJECTS', Feature_Key__c = 'projects',
                Enabled__c = true, Configuration_Status__c = 'Not Configured')
        };
        SABAppShellController.ShellContext context;
        Test.startTest();
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            context = SABAppShellController.getShellContext(companyId);
        }
        Test.stopTest();
        System.assert(!context.visibleWorkspaces.contains('payroll'), 'A disabled core feature hides its workspace.');
        List<String> noCompany = SABAppShellController.visibleWorkspaces(new Map<String, Boolean>(), false);
        System.assert(!noCompany.contains('payroll'), 'Feature workspaces need a company.');
        List<String> enabled = SABAppShellController.visibleWorkspaces(new Map<String, Boolean>{ 'PAYROLL' => true }, true);
        System.assertEquals(enabled.contains('payroll'), Schema.SObjectType.Payroll_Run__c.isAccessible(),
            'An enabled core feature follows object access.');
        List<String> disabled = SABAppShellController.visibleWorkspaces(new Map<String, Boolean>{ 'PAYROLL' => false }, true);
        System.assert(!disabled.contains('payroll'), 'A disabled feature hides its workspace.');
    }

    @IsTest
    static void companyWithoutGrantIsRefused() {
        Accounting_Company__c other = new Accounting_Company__c(Name__c = 'No Grant Co', Company_Key__c = 'G22N',
            Country_Code__c = 'AU', Functional_Currency__c = 'AUD', Fiscal_Calendar_Type__c = 'Calendar',
            Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active', Is_Active__c = true);
        insert as system other;
        Boolean refused = false;
        Test.startTest();
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            try {
                SABAppShellController.getShellContext(other.Id);
            } catch (AuraHandledException ex) {
                refused = true;
            }
        }
        Test.stopTest();
        System.assert(refused, 'A company without an active grant is refused.');
    }

    @IsTest
    static void contextWithoutCompanyHasNoPeriod() {
        SABAppShellController.ShellContext context;
        Test.startTest();
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            context = SABAppShellController.getShellContext(null);
        }
        Test.stopTest();
        System.assert(!context.hasPeriod, 'No company means no period.');
        System.assert(context.visibleWorkspaces.contains('home'), 'Home is still listed.');
    }

    @IsTest
    static void searchReturnsAccessibleRecords() {
        Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
        GL_Account__c account = [SELECT Id FROM GL_Account__c WHERE Company__c = :companyId AND Account_Code__c = '1000' WITH SYSTEM_MODE];
        List<SABAppShellController.SearchResult> results;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Journal_Entry__c journal = SABAppShellTestFixture.seedDraftJournal();
            Test.setFixedSearchResults(new List<Id>{ account.Id, journal.Id });
            Test.startTest();
            results = SABAppShellController.search('Operating');
            Test.stopTest();
        }
        Set<String> kinds = new Set<String>();
        for (SABAppShellController.SearchResult row : results) {
            kinds.add(row.kind);
            System.assertEquals(companyId, row.companyId, 'Results carry their company.');
        }
        System.assert(kinds.contains('account'), 'GL accounts are searchable.');
        System.assert(kinds.contains('journal'), 'Journals are searchable.');
    }

    @IsTest
    static void searchMatchesCodesAndBankNamesByPrefix() {
        List<SABAppShellController.SearchResult> byCode;
        List<SABAppShellController.SearchResult> byBank;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            byCode = SABAppShellController.search('100');
            byBank = SABAppShellController.search('Operating');
            Test.stopTest();
        }
        Boolean accountFound = false;
        for (SABAppShellController.SearchResult row : byCode) {
            accountFound = accountFound || (row.kind == 'account' && row.title.startsWith('1000'));
        }
        System.assert(accountFound, 'An account code matches by prefix without the search index.');
        System.assertNotEquals(null, byCode[0].companyName, 'Results name their company.');
        Boolean bankFound = false;
        for (SABAppShellController.SearchResult row : byBank) {
            bankFound = bankFound || (row.kind == 'bank' && row.workspace == 'bank');
        }
        System.assert(bankFound, 'Bank accounts are searchable by name.');
    }

    @IsTest
    static void searchIgnoresShortTermsAndEscapes() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            System.assertEquals(0, SABAppShellController.search('a').size(), 'One character is too short.');
            System.assertEquals(0, SABAppShellController.search(null).size(), 'Null is ignored.');
            Test.stopTest();
            System.assertEquals('INV\\-0001', SABAppShellController.escapeSosl('INV-0001'), 'Reserved characters are escaped.');
            System.assertEquals('a\\*b\\"', SABAppShellController.escapeSosl('a*b"'), 'Wildcards and quotes are escaped.');
        }
    }
}
