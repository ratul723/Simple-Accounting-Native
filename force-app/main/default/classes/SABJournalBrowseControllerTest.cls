@IsTest
private class SABJournalBrowseControllerTest {

    @TestSetup
    static void setupData() {
        SABAppShellTestFixture.seed();
        SABTestGovernor.assertSetupWithin(50);
    }

    @IsTest
    static void browseDataListsJournalsAccountsAndPeriods() {
        Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
        SABJournalBrowseController.BrowseData data;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            SABAppShellTestFixture.seedDraftJournal();
            Test.startTest();
            data = SABJournalBrowseController.getBrowseData(companyId);
            Test.stopTest();
        }
        System.assertEquals(1, data.journals.size(), 'The draft journal is listed.');
        System.assertEquals('Draft', data.journals[0].status, 'Status.');
        System.assertEquals('Manual', data.journals[0].entryType, 'Entry type.');
        System.assertEquals(500, data.journals[0].totalDebit, 'Debit total from the lines.');
        System.assertNotEquals(null, data.journals[0].periodKey, 'Period key.');
        System.assertEquals(3, data.accounts.size(), 'Three fixture accounts.');
        System.assertEquals('1000', data.accounts[0].code, 'Ordered by code.');
        System.assert(data.accounts[0].manualPostingAllowed, 'Manual posting flag.');
        System.assertEquals(1, data.periods.size(), 'The current period.');
        System.assertEquals('Open', data.periods[0].status, 'Open period.');
    }

    @IsTest
    static void emptyCompanyAndAccessRules() {
        SABJournalBrowseController.BrowseData data;
        String missing;
        String noGrant;
        Accounting_Company__c other = new Accounting_Company__c(Name__c = 'No Grant Journals', Company_Key__c = 'G22J',
            Country_Code__c = 'AU', Functional_Currency__c = 'AUD', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1,
            Setup_Status__c = 'Active', Is_Active__c = true);
        insert as system other;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            data = SABJournalBrowseController.getBrowseData(SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY));
            try {
                SABJournalBrowseController.getBrowseData(null);
            } catch (AuraHandledException ex) {
                missing = ex.getMessage();
            }
            try {
                SABJournalBrowseController.getBrowseData(other.Id);
            } catch (AuraHandledException ex) {
                noGrant = ex.getMessage();
            }
            Test.stopTest();
        }
        System.assertEquals(0, data.journals.size(), 'No journals yet.');
        System.assertEquals('You do not have active access to this Accounting Company.', missing, 'A company is required.');
        System.assertEquals('You do not have active access to this Accounting Company.', noGrant, 'A grant is required.');
    }
}