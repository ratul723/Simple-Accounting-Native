@IsTest
private class SABBankLedgerLinesControllerTest {

    @TestSetup
    static void setupData() {
        SABAppShellTestFixture.seed();
        SABTestGovernor.assertSetupWithin(50);
    }

    private static Id statementFor(Id companyId) {
        Bank_Account__c bank = [SELECT Id FROM Bank_Account__c WHERE Company__c = :companyId WITH SYSTEM_MODE LIMIT 1];
        Bank_Statement__c statement = new Bank_Statement__c(Company__c = companyId, Bank_Account__c = bank.Id, Opening_Amount__c = 0,
            Closing_Amount__c = 500, Currency__c = 'AUD', Import_Fingerprint__c = 'G22G4-STATEMENT', Statement_Start_Date__c = Date.today().toStartOfMonth(),
            Statement_End_Date__c = Date.today(), Status__c = 'Imported');
        insert as system statement;
        return statement.Id;
    }

    @IsTest
    static void postedBankLinesAreListedWithRemainingAmounts() {
        Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
        List<SABBankLedgerLinesController.LedgerLine> lines;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Journal_Entry__c journal = SABAppShellTestFixture.seedDraftJournal();
            Id statementId = statementFor(companyId);
            SABTestGovernor.startTest();
            SABPostingService.postDraftJournal(postingRequest(journal));
            SABTestGovernor.requireHeadroom(10, 'read ledger lines after posting');
            lines = SABBankLedgerLinesController.getLedgerLines(companyId, statementId);
            SABTestGovernor.stopTest();
        }
        System.assertEquals(1, lines.size(), 'The posted debit to the bank account.');
        System.assertEquals(500, lines[0].amount, 'Debit minus credit.');
        System.assertEquals(500, lines[0].remainingAmount, 'Nothing matched yet.');
        System.assertEquals(false, lines[0].matchedHere, 'Not matched to this statement.');
        System.assertEquals('Fixture draft journal', lines[0].description, 'Journal description when the line has no explanation.');
    }

    @IsTest
    static void accessAndInputRulesAreEnforced() {
        Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
        List<String> messages = new List<String>();
        List<SABBankLedgerLinesController.LedgerLine> empty;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Id statementId = statementFor(companyId);
            Test.startTest();
            empty = SABBankLedgerLinesController.getLedgerLines(companyId, statementId);
            for (Integer i = 0; i < 2; i++) {
                try {
                    if (i == 0) {
                        SABBankLedgerLinesController.getLedgerLines(null, statementId);
                    } else {
                        SABBankLedgerLinesController.getLedgerLines(companyId, null);
                    }
                } catch (AuraHandledException ex) {
                    messages.add(ex.getMessage());
                }
            }
            Test.stopTest();
        }
        System.assertEquals(0, empty.size(), 'No posted lines yet.');
        System.assertEquals('You do not have active access to this Accounting Company.', messages[0], 'A company is required.');
        System.assertEquals('A bank statement is required.', messages[1], 'A statement is required.');
    }

    @IsTest
    static void remainingKeepsTheSign() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            Decimal debit = SABBankLedgerLinesController.remaining(500, 200);
            Decimal credit = SABBankLedgerLinesController.remaining(-500, -200);
            Decimal done = SABBankLedgerLinesController.remaining(500, 500);
            Test.stopTest();
            System.assertEquals(300, debit, 'Debit remainder.');
            System.assertEquals(-300, credit, 'Credit remainder.');
            System.assertEquals(0, done, 'Fully matched.');
        }
    }

    private static SABPostingService.PostingRequest postingRequest(Journal_Entry__c journal) {
        SABAccountingEventService.ReservationRequest eventRequest = new SABAccountingEventService.ReservationRequest();
        eventRequest.companyId = journal.Company__c;
        eventRequest.adapterKey = 'MANUAL_JOURNAL';
        eventRequest.requestKey = 'REQ-G22G4-BANK';
        eventRequest.eventKey = 'EVENT-G22G4-BANK';
        eventRequest.eventType = 'Manual Journal';
        eventRequest.sourceBusinessKey = 'POST-G22G4-BANK';
        eventRequest.sourceRecordId = String.valueOf(journal.Id);
        eventRequest.sourceType = 'Journal_Entry__c';
        eventRequest.sourceVersion = 1;
        SABPostingService.PostingRequest request = new SABPostingService.PostingRequest();
        request.journalEntryId = journal.Id;
        request.postingKey = 'POST-G22G4-BANK';
        request.eventRequest = eventRequest;
        return request;
    }
}
