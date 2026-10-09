@IsTest
private class SABIntercompanyServiceTest {

    @TestSetup
    static void setupData() {
        SABGroupAccountingTestFixture.createFixture();
    }

    private static Map<String, Decimal> netByAccount(Id journalId) {
        Map<String, Decimal> result = new Map<String, Decimal>();
        for (Journal_Entry_Line__c l : [SELECT GL_Account__r.Account_Code__c, Debit_Base__c, Credit_Base__c FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c = :journalId WITH SYSTEM_MODE]) {
            result.put(l.GL_Account__r.Account_Code__c, l.Debit_Base__c - l.Credit_Base__c);
        }
        return result;
    }

    @IsTest
    static void recordsAndPostsBothSides() {
        SABIntercompanyService.ActionResult recorded;
        SABIntercompanyService.ActionResult replay;
        System.runAs(SABGroupAccountingTestFixture.user(SABGroupAccountingTestFixture.MANAGER)) {
            SABTestGovernor.startTest();
            recorded = SABIntercompanyService.recordTransaction(SABGroupAccountingTestFixture.intercompanyRequest(1250), 'G18-IC-1');
            replay = SABIntercompanyService.recordTransaction(SABGroupAccountingTestFixture.intercompanyRequest(1250), 'G18-IC-1');
            SABTestGovernor.stopTest();
        }
        System.assertEquals('Matched', recorded.reconciliationState, 'Both sides post the agreed amount.');
        System.assertEquals(true, replay.replay, 'Same key replays.');
        System.assertEquals(recorded.transactionId, replay.transactionId, 'Replay returns the first transaction.');
        Map<String, Decimal> fromSide = netByAccount(recorded.fromJournalId);
        System.assertEquals(1250, fromSide.get('1400'), 'From company: Dr IC receivable.');
        System.assertEquals(-1250, fromSide.get('4100'), 'From company: Cr IC revenue.');
        Map<String, Decimal> toSide = netByAccount(recorded.toJournalId);
        System.assertEquals(1250, toSide.get('6100'), 'To company: Dr IC expense.');
        System.assertEquals(-1250, toSide.get('2400'), 'To company: Cr IC payable.');
        List<Journal_Entry__c> journals = [SELECT Company__c, Entry_Type__c, Status__c FROM Journal_Entry__c
            WHERE Id IN (:recorded.fromJournalId, :recorded.toJournalId) WITH SYSTEM_MODE];
        Set<Id> companies = new Set<Id>();
        for (Journal_Entry__c j : journals) {
            companies.add(j.Company__c);
            System.assertEquals('Subledger', j.Entry_Type__c, 'Subledger journals.');
            System.assertEquals('Posted', j.Status__c, 'Posted.');
        }
        System.assertEquals(new Set<Id>{SABGroupAccountingTestFixture.companyId('P'), SABGroupAccountingTestFixture.companyId('S')}, companies,
            'One journal in each company.');
    }

    @IsTest
    static void validatesCompaniesCurrencyAccountsAndAccess() {
        List<String> messages = new List<String>();
        Boolean outsiderDenied = false;
        Database.SaveResult direct;
        SABTestGovernor.startTest();
        System.runAs(SABGroupAccountingTestFixture.user(SABGroupAccountingTestFixture.MANAGER)) {
            SABIntercompanyService.IntercompanyRequest sameCompany = SABGroupAccountingTestFixture.intercompanyRequest(100);
            sameCompany.toCompanyId = sameCompany.fromCompanyId;
            SABIntercompanyService.IntercompanyRequest otherCurrency = SABGroupAccountingTestFixture.intercompanyRequest(100);
            otherCurrency.toCompanyId = SABGroupAccountingTestFixture.companyId('E');
            SABIntercompanyService.IntercompanyRequest wrongType = SABGroupAccountingTestFixture.intercompanyRequest(100);
            wrongType.fromReceivableAccountId = SABGroupAccountingTestFixture.accountId('P', '2400');
            SABIntercompanyService.IntercompanyRequest wrongCompany = SABGroupAccountingTestFixture.intercompanyRequest(100);
            wrongCompany.toPayableAccountId = SABGroupAccountingTestFixture.accountId('P', '2400');
            Integer n = 0;
            for (SABIntercompanyService.IntercompanyRequest r : new List<SABIntercompanyService.IntercompanyRequest>{sameCompany, otherCurrency, wrongType,
                    wrongCompany, SABGroupAccountingTestFixture.intercompanyRequest(0)}) {
                try {
                    SABIntercompanyService.recordTransaction(r, 'G18-BAD-' + n++);
                } catch (SABIntercompanyService.IntercompanyException ex) {
                    messages.add(ex.getMessage());
                }
            }
            direct = Database.insert(new Intercompany_Transaction__c(From_Company__c = SABGroupAccountingTestFixture.companyId('P'),
                To_Company__c = SABGroupAccountingTestFixture.companyId('S'), Transaction_Date__c = Date.newInstance(2026, 2, 1), Agreed_Amount__c = 1,
                Currency__c = 'USD'), false, AccessLevel.SYSTEM_MODE);
        }
        System.runAs(SABGroupAccountingTestFixture.user(SABGroupAccountingTestFixture.OUTSIDER)) {
            try {
                SABIntercompanyService.recordTransaction(SABGroupAccountingTestFixture.intercompanyRequest(100), 'G18-OUTSIDER');
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                outsiderDenied = true;
            }
        }
        SABTestGovernor.stopTest();
        List<String> fragments = new List<String>{'two different companies', 'same functional currency', 'From receivable account',
            'To payable account', 'greater than zero'};
        System.assertEquals(fragments.size(), messages.size(), 'Every invalid request was refused: ' + messages);
        for (Integer i = 0; i < fragments.size(); i++) {
            System.assert(messages[i].contains(fragments[i]), 'Expected "' + fragments[i] + '" but got: ' + messages[i]);
        }
        System.assertEquals(false, direct.isSuccess(), 'Intercompany transactions are system records.');
        System.assertEquals(true, outsiderDenied, 'A grant to both companies is required.');
    }
}
