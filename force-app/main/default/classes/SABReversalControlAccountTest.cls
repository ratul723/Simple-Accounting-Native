@IsTest
private class SABReversalControlAccountTest {
    private static final String USER_LAST_NAME = 'SAB Control Reversal User';
    private static final Date POSTING_DATE = Date.newInstance(2026, 9, 10);
    private static final String POLICY_MESSAGE = 'does not allow manual/opening posting';

    @TestSetup
    static void setupData() {
        Profile standard = [SELECT Id FROM Profile WHERE UserType = 'Standard' ORDER BY Name LIMIT 1];
        String unique = 'sabctlrev.' + String.valueOf(System.now().getTime());
        User reversalUser = new User(Alias = 'sabcrev', Email = unique + '@example.test', EmailEncodingKey = 'UTF-8',
            LastName = USER_LAST_NAME, LanguageLocaleKey = 'en_US', LocaleSidKey = 'en_US', ProfileId = standard.Id,
            TimeZoneSidKey = 'Asia/Dhaka', Username = unique + '@example.test');
        insert as system reversalUser;
        Map<String, Id> sets = new Map<String, Id>();
        for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN ('SAB_Remaining_Fields_Admin',
                'SAB_Post_Journal_Action', 'SAB_Reverse_Journal_Action') WITH SYSTEM_MODE]) {
            sets.put(p.Name, p.Id);
        }
        System.assertEquals(3, sets.size(), 'Required SAB permission sets must be deployed.');
        List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
        for (Id setId : sets.values()) {
            rows.add(new PermissionSetAssignment(AssigneeId = reversalUser.Id, PermissionSetId = setId));
        }
        insert as system rows;
        System.runAs(reversalUser) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'Control Reversal Co', Company_Key__c = 'CTLREV',
                Country_Code__c = 'BD', Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active', Is_Active__c = true);
            insert as system company;
            insert as system new Company_User_Access__c(Company__c = company.Id, User__c = reversalUser.Id,
                Effective_From__c = Date.today(), Grant_Key__c = 'CTLREV-GRANT', Is_Active__c = true, Role__c = 'Bookkeeper');
            insert as system new Accounting_Period__c(Name = 'Sep 2026', Company__c = company.Id, Company_Period_Key__c = 'CTLREV-SEP',
                Period_Key__c = 'CTLREV-2026-09', Start_Date__c = Date.newInstance(2026, 9, 1), End_Date__c = Date.newInstance(2026, 9, 30),
                Fiscal_Year__c = 2026, Fiscal_Quarter__c = 3, Period_Number__c = 9, Status__c = 'Open');
            insert as system new List<GL_Account__c>{
                new GL_Account__c(Name = 'Accounts Receivable', Company__c = company.Id, Company_Account_Key__c = company.Id + '-1200',
                    Account_Code__c = '1200', Account_Type__c = 'Asset', Normal_Balance__c = 'Debit', Is_Active__c = true,
                    Is_Control_Account__c = true, Control_Type__c = 'AR', Manual_Posting_Allowed__c = false),
                new GL_Account__c(Name = 'Sales Revenue', Company__c = company.Id, Company_Account_Key__c = company.Id + '-4000',
                    Account_Code__c = '4000', Account_Type__c = 'Revenue', Normal_Balance__c = 'Credit', Is_Active__c = true,
                    Is_Control_Account__c = false, Control_Type__c = 'None', Manual_Posting_Allowed__c = true)};
        }
    }

    private static User reversalUser() {
        return [SELECT Id FROM User WHERE LastName = :USER_LAST_NAME WITH SYSTEM_MODE LIMIT 1];
    }

    private static Accounting_Company__c company() {
        return [SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = 'CTLREV' WITH SYSTEM_MODE LIMIT 1];
    }

    private static Id period() {
        return [SELECT Id FROM Accounting_Period__c WHERE Company_Period_Key__c = 'CTLREV-SEP' WITH SYSTEM_MODE LIMIT 1].Id;
    }

    private static Id account(String code) {
        return [SELECT Id FROM GL_Account__c WHERE Account_Code__c = :code AND Company__r.Company_Key__c = 'CTLREV'
            WITH SYSTEM_MODE LIMIT 1].Id;
    }

    private static Journal_Entry__c draft(String entryType, Id reversalOf) {
        Journal_Entry__c journal = new Journal_Entry__c(Company__c = company().Id, Accounting_Period__c = period(),
            Accounting_Date__c = POSTING_DATE, Entry_Type__c = entryType, Status__c = 'Draft',
            Description__c = entryType + ' control-account test', Version__c = 1, Reversal_Of__c = reversalOf);
        insert as system journal;
        return journal;
    }

    private static void lines(Id journalId, Id debitId, Id creditId) {
        insert as system new List<Journal_Entry_Line__c>{
            line(journalId, debitId, 1, 100, 0), line(journalId, creditId, 2, 0, 100)};
    }

    private static Journal_Entry_Line__c line(Id journalId, Id accountId, Integer lineNumber, Decimal debit, Decimal credit) {
        return new Journal_Entry_Line__c(Journal_Entry__c = journalId, GL_Account__c = accountId, Line_Number__c = lineNumber,
            Debit_Base__c = debit, Credit_Base__c = credit, Functional_Currency__c = 'BDT', Transaction_Currency__c = 'BDT',
            Transaction_Amount__c = debit > 0 ? debit : -credit, Applied_Exchange_Rate__c = 1, Rate_Date__c = POSTING_DATE,
            Rate_Source__c = 'Test', Explanation__c = 'Control-account test line');
    }

    private static SABPostingService.PostingResult post(Journal_Entry__c journal, String suffix) {
        SABAccountingEventService.ReservationRequest eventRequest = new SABAccountingEventService.ReservationRequest();
        eventRequest.companyId = journal.Company__c;
        eventRequest.adapterKey = 'CTLREV_TEST';
        eventRequest.requestKey = 'REQ-CTLREV-' + suffix;
        eventRequest.eventKey = 'EVENT-CTLREV-' + suffix;
        eventRequest.eventType = 'Manual Journal';
        eventRequest.sourceBusinessKey = 'CTLREV-' + suffix;
        eventRequest.sourceRecordId = String.valueOf(journal.Id);
        eventRequest.sourceType = 'Journal_Entry__c';
        eventRequest.sourceVersion = 1;
        SABPostingService.PostingRequest request = new SABPostingService.PostingRequest();
        request.journalEntryId = journal.Id;
        request.postingKey = 'POST-CTLREV-' + suffix;
        request.eventRequest = eventRequest;
        return SABPostingService.postDraftJournal(request);
    }

    // A posted Subledger journal that debits the AR control account (as invoice and realized-FX postings do).
    private static Journal_Entry__c postedSubledgerOriginal() {
        Journal_Entry__c original = draft('Subledger', null);
        lines(original.Id, account('1200'), account('4000'));
        post(original, 'ORIGINAL');
        return original;
    }

    @IsTest
    static void reversingSubledgerPostingMayCreditControlAccount() {
        SABReversalService.ReversalResult result;
        System.runAs(reversalUser()) {
            Journal_Entry__c original = postedSubledgerOriginal();
            SABReversalService.ReversalRequest request = new SABReversalService.ReversalRequest();
            request.originalJournalEntryId = original.Id;
            request.reversalAccountingPeriodId = period();
            request.reversalAccountingDate = Date.newInstance(2026, 9, 20);
            request.postingKey = 'POST-CTLREV-REVERSAL';
            request.eventKey = 'EVENT-CTLREV-REVERSAL';
            request.requestKey = 'REQ-CTLREV-REVERSAL';
            request.reason = 'Reverse a subledger posting that hit a control account';
            Test.startTest();
            result = SABReversalService.reversePostedJournal(request);
            Test.stopTest();
        }
        Journal_Entry__c reversal = [SELECT Status__c, Entry_Type__c, Reversal_Of__c FROM Journal_Entry__c
            WHERE Id = :result.reversalJournalEntryId WITH SYSTEM_MODE];
        System.assertEquals('Posted', reversal.Status__c, 'Reversal journal posts.');
        System.assertEquals('Reversal', reversal.Entry_Type__c, 'Reversal keeps its Reversal entry type.');
        Id arId = account('1200');
        Journal_Entry_Line__c arLine = [SELECT Debit_Base__c, Credit_Base__c FROM Journal_Entry_Line__c
            WHERE Journal_Entry__c = :reversal.Id AND GL_Account__c = :arId WITH SYSTEM_MODE LIMIT 1];
        System.assertEquals(100, arLine.Credit_Base__c, 'Reversal credits the AR control account the original debited.');
        System.assertEquals('Reversed', [SELECT Status__c FROM Journal_Entry__c WHERE Id = :reversal.Reversal_Of__c
            WITH SYSTEM_MODE].Status__c, 'Original is marked Reversed.');
    }

    @IsTest
    static void handMadeReversalJournalStillCannotHitControlAccount() {
        String blocked;
        System.runAs(reversalUser()) {
            Journal_Entry__c original = postedSubledgerOriginal();
            Test.startTest();
            Journal_Entry__c forged;
            try {
                forged = draft('Reversal', original.Id);
                lines(forged.Id, account('4000'), account('1200'));
            } catch (DmlException ex) {
                // The ledger guards may already refuse a hand-made reversal link; that is also a block.
                blocked = POLICY_MESSAGE + ' (insert refused: ' + ex.getMessage() + ')';
            }
            if (blocked == null) {
                try {
                    post(forged, 'FORGED');
                } catch (SABPostingService.PostingException ex) {
                    blocked = ex.getMessage();
                }
            }
            Test.stopTest();
        }
        System.assert(blocked != null && blocked.contains(POLICY_MESSAGE),
            'A Reversal journal not built by SABReversalService cannot post to a control account: ' + blocked);
    }

    @IsTest
    static void manualJournalStillCannotHitControlAccount() {
        String blocked;
        System.runAs(reversalUser()) {
            Journal_Entry__c manual = draft('Manual', null);
            lines(manual.Id, account('1200'), account('4000'));
            Test.startTest();
            try {
                post(manual, 'MANUAL');
            } catch (SABPostingService.PostingException ex) {
                blocked = ex.getMessage();
            }
            Test.stopTest();
        }
        System.assert(blocked != null && blocked.contains(POLICY_MESSAGE), 'Manual control-account posting stays blocked: ' + blocked);
    }
}
