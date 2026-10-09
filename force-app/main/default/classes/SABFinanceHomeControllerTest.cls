@IsTest
private class SABFinanceHomeControllerTest {

    @TestSetup
    static void setupData() {
        SABAppShellTestFixture.seed();
        SABTestGovernor.assertSetupWithin(50);
    }

    @IsTest
    static void activeCompanyHomeShowsFiguresAndAttention() {
        Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
        SABFinanceHomeService.HomeData data;
        Test.startTest();
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            data = SABFinanceHomeController.getHome(companyId);
        }
        Test.stopTest();
        System.assert(data.companyActive, 'Fixture company is active.');
        System.assertEquals('AUD', data.currencyCode, 'Functional currency is returned.');
        System.assert(data.cash.available, 'Bank accounts are readable.');
        System.assertEquals(1, data.cash.count, 'One active bank account.');
        System.assertEquals(0, data.cash.amount, 'Draft journals do not move cash.');
        System.assertEquals(13, data.cashTrend.size(), 'Thirteen weekly points.');
        System.assert(!data.monthly.isEmpty(), 'Fiscal months to date are listed.');
        Boolean draftsFlagged = false;
        for (SABFinanceHomeService.AttentionItem item : data.attention) {
            draftsFlagged = draftsFlagged || item.key == 'drafts';
        }
        System.assert(draftsFlagged, 'Draft journals in the period need attention.');
        System.assertEquals('drafts', data.roleCard.kind, 'Bookkeeper sees their drafts.');
        System.assertEquals(1, data.roleCard.items.size(), 'The fixture draft belongs to the user.');
        System.assert(data.recent.isEmpty(), 'Nothing is posted yet.');
        System.assert(data.approvals.isEmpty(), 'No approvals are pending.');
    }

    @IsTest
    static void postedJournalMovesCashAndProfit() {
        Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
        Journal_Entry__c journal = [SELECT Id, Company__c, Entry_Type__c FROM Journal_Entry__c WHERE Company__c = :companyId WITH SYSTEM_MODE LIMIT 1];
        SABFinanceHomeService.HomeData data;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            SABTestGovernor.startTest();
            SABPostingService.postDraftJournal(postingRequest(journal));
            SABTestGovernor.requireHeadroom(45, 'load Finance home after posting');
            data = SABFinanceHomeController.getHome(companyId);
            SABTestGovernor.stopTest();
        }
        System.assertEquals(500, data.cash.amount, 'Posted debit to the bank account is cash.');
        System.assertEquals(500, data.cashTrend[data.cashTrend.size() - 1].balance, 'The last trend point is today.');
        System.assertEquals(500, data.profit.amount, 'Posted revenue is year-to-date profit.');
        System.assertEquals(500, data.monthly[data.monthly.size() - 1].income, 'Revenue shows as income this month.');
        System.assertEquals(1, data.recent.size(), 'The posting is listed as recent.');
    }

    @IsTest
    static void setupCompanyReturnsSetupSummary() {
        Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.SETUP_KEY);
        SABFinanceHomeService.HomeData data;
        Test.startTest();
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            data = SABFinanceHomeController.getHome(companyId);
        }
        Test.stopTest();
        System.assert(!data.companyActive, 'Company is still in setup.');
        System.assertNotEquals(null, data.setup, 'Setup summary is returned.');
        System.assertEquals(0, data.setup.accountCount, 'No accounts yet.');
        System.assertEquals(null, data.cash, 'Figures are not built for companies in setup.');
    }

    @IsTest
    static void userWithoutHomePermissionIsRefused() {
        User outsider = SABAppShellTestFixture.createUser('sabhno', 'SAB Home Outsider', new List<String>());
        Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
        Boolean refused = false;
        Test.startTest();
        System.runAs(outsider) {
            try {
                SABFinanceHomeController.getHome(companyId);
            } catch (AuraHandledException ex) {
                refused = ex.getMessage().contains('Finance home');
            }
        }
        Test.stopTest();
        System.assert(refused, 'SAB_View_Finance_Home is required.');
    }

    @IsTest
    static void missingCompanyIsRefused() {
        Boolean refused = false;
        Test.startTest();
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            try {
                SABFinanceHomeController.getHome(null);
            } catch (AuraHandledException ex) {
                refused = true;
            }
        }
        Test.stopTest();
        System.assert(refused, 'A company is required.');
    }

    @IsTest
    static void roleCardsFollowPersona() {
        Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
        Map<String, SABFinanceHomeService.RoleCard> cards = new Map<String, SABFinanceHomeService.RoleCard>();
        Test.startTest();
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            for (String key : new List<String>{ SABPersonaService.FINANCE_MANAGER, SABPersonaService.TREASURY,
                    SABPersonaService.HR, SABPersonaService.DIRECTOR, SABPersonaService.AUDITOR }) {
                cards.put(key, SABFinanceHomeService.roleCardFor(companyId, key));
            }
        }
        Test.stopTest();
        System.assertEquals('close', cards.get(SABPersonaService.FINANCE_MANAGER).kind, 'Finance Manager sees close progress.');
        System.assertEquals('No close tasks yet', cards.get(SABPersonaService.FINANCE_MANAGER).valueText, 'No tasks seeded.');
        System.assert(cards.get(SABPersonaService.TREASURY).isMoney, 'Treasury sees an amount to release.');
        System.assertEquals('payroll', cards.get(SABPersonaService.HR).kind, 'HR sees payroll.');
        System.assertEquals('0 approvals', cards.get(SABPersonaService.DIRECTOR).valueText, 'Director sees pending approvals.');
        System.assertEquals('audit', cards.get(SABPersonaService.AUDITOR).kind, 'Auditor sees audit activity.');
    }

    @IsTest
    static void helpersFormatLikeTheDemo() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            System.assertEquals('1 approval', SABFinanceHomeService.plural(1, 'approval'), 'Singular.');
            System.assertEquals('3 approvals', SABFinanceHomeService.plural(3, 'approval'), 'Plural.');
            System.assertEquals(33, SABFinanceHomeService.percent(1, 3), 'Rounded percentage.');
            System.assertEquals(0, SABFinanceHomeService.percent(0, 0), 'No tasks is zero percent.');
            System.assertEquals('25 Sep', SABFinanceHomeService.shortDate(Date.newInstance(2026, 9, 25)), 'Short date.');
            System.assertEquals('September', SABFinanceHomeService.fullMonth(Date.newInstance(2026, 9, 1)), 'Month name.');
            Map<Date, Decimal> movements = new Map<Date, Decimal>{ Date.newInstance(2026, 7, 10) => 100 };
            List<SABFinanceHomeService.TrendPoint> points = SABFinanceHomeService.trend(Date.newInstance(2026, 7, 3), 50, movements);
            System.assertEquals(50, points[0].balance, 'Opening balance at the first point.');
            System.assertEquals(150, points[1].balance, 'Movement lands in its week.');
        }
    }

    private static SABPostingService.PostingRequest postingRequest(Journal_Entry__c journal) {
        SABAccountingEventService.ReservationRequest eventRequest = new SABAccountingEventService.ReservationRequest();
        eventRequest.companyId = journal.Company__c;
        eventRequest.adapterKey = 'MANUAL_JOURNAL';
        eventRequest.requestKey = 'REQ-G22A-HOME';
        eventRequest.eventKey = 'EVENT-G22A-HOME';
        eventRequest.eventType = 'Manual Journal';
        eventRequest.sourceBusinessKey = 'POST-G22A-HOME';
        eventRequest.sourceRecordId = String.valueOf(journal.Id);
        eventRequest.sourceType = 'Journal_Entry__c';
        eventRequest.sourceVersion = 1;
        SABPostingService.PostingRequest request = new SABPostingService.PostingRequest();
        request.journalEntryId = journal.Id;
        request.postingKey = 'POST-G22A-HOME';
        request.eventRequest = eventRequest;
        return request;
    }
}
