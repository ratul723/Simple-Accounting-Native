@IsTest
private class SABEquityServiceTest {

    @TestSetup
    static void setupData() {
        SABEquityTestFixture.createFixture();
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
    static void issueAndContributionPostCapitalAndPremium() {
        Id issueId;
        Id contributionId;
        SABEquityService.ActionResult issue;
        SABEquityService.ActionResult replay;
        SABEquityService.ActionResult contribution;
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.MANAGER)) {
            issueId = SABEquityService.saveTransaction(SABEquityTestFixture.transaction('Issue', 'A', 100, 250));
            contributionId = SABEquityService.saveTransaction(SABEquityTestFixture.transaction('Capital Contribution', 'B', null, 1000));
        }
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.APPROVER)) {
            SABTestGovernor.startTest();
            issue = SABEquityService.approveTransaction(issueId, 'E17-ISSUE');
            replay = SABEquityService.approveTransaction(issueId, 'E17-ISSUE');
            contribution = SABEquityService.approveTransaction(contributionId, 'E17-CONTRIBUTION');
            SABTestGovernor.stopTest();
        }
        System.assertEquals('Posted', issue.status, 'Issue posted.');
        System.assertEquals(true, replay.replay, 'Same key replays.');
        Map<String, Decimal> issued = netByAccount(issue.journalEntryId);
        System.assertEquals(250, issued.get('1100'), 'Dr Bank for the issue value.');
        System.assertEquals(-100, issued.get('3000'), 'Cr Share capital: 100 units x par 1.');
        System.assertEquals(-150, issued.get('3100'), 'Cr Share premium for the rest.');
        Map<String, Decimal> contributed = netByAccount(contribution.journalEntryId);
        System.assertEquals(1000, contributed.get('1100'), 'Dr Bank.');
        System.assertEquals(-1000, contributed.get('3100'), 'Cr contributed capital.');
        System.assertEquals(null, contributed.get('3000'), 'A contribution issues no share capital.');
        System.assertEquals(700, SABEquityService.holdings(SABEquityTestFixture.classId(), Date.newInstance(2026, 2, 28))
            .get(SABEquityTestFixture.stakeholderId('A')), 'A now holds 600 + 100 units.');
    }

    @IsTest
    static void redemptionAndTransferMoveHoldings() {
        Id redemptionId;
        Id transferId;
        SABEquityService.ActionResult redeemed;
        SABEquityService.ActionResult transferred;
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.MANAGER)) {
            redemptionId = SABEquityService.saveTransaction(SABEquityTestFixture.transaction('Redemption', 'A', 100, 150));
            SABEquityService.TransactionRequest t = SABEquityTestFixture.transaction('Transfer', 'A', 200, 0);
            t.toStakeholderId = SABEquityTestFixture.stakeholderId('B');
            t.bankAccountId = null;
            transferId = SABEquityService.saveTransaction(t);
        }
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.APPROVER)) {
            SABTestGovernor.startTest();
            redeemed = SABEquityService.approveTransaction(redemptionId, 'E17-REDEEM');
            transferred = SABEquityService.approveTransaction(transferId, 'E17-TRANSFER');
            SABTestGovernor.stopTest();
        }
        Map<String, Decimal> net = netByAccount(redeemed.journalEntryId);
        System.assertEquals(100, net.get('3000'), 'Dr Share capital at par.');
        System.assertEquals(50, net.get('3100'), 'Dr premium for the amount paid above par.');
        System.assertEquals(-150, net.get('1100'), 'Cr Bank.');
        System.assertEquals(null, transferred.journalEntryId, 'Transfers move ownership without a journal.');
        Map<Id, Decimal> held = SABEquityService.holdings(SABEquityTestFixture.classId(), Date.newInstance(2026, 2, 28));
        System.assertEquals(300, held.get(SABEquityTestFixture.stakeholderId('A')), 'A: 600 - 100 redeemed - 200 transferred.');
        System.assertEquals(600, held.get(SABEquityTestFixture.stakeholderId('B')), 'B: 400 + 200 transferred.');
        System.assertEquals(true, SABEquityService.holdings(SABEquityTestFixture.classId(), Date.newInstance(2026, 1, 4)).isEmpty(),
            'Nobody held units before the first issue.');
    }

    @IsTest
    static void validatesTransactionsAndSeparatesDuties() {
        List<String> messages = new List<String>();
        String selfApproval;
        Database.SaveResult direct;
        SABTestGovernor.startTest();
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.MANAGER)) {
            SABEquityService.TransactionRequest toSelf = SABEquityTestFixture.transaction('Transfer', 'A', 10, 0);
            toSelf.toStakeholderId = SABEquityTestFixture.stakeholderId('A');
            List<SABEquityService.TransactionRequest> bad = new List<SABEquityService.TransactionRequest>{
                SABEquityTestFixture.transaction('Issue', 'A', 100, 50), SABEquityTestFixture.transaction('Redemption', 'B', 401, 401), toSelf,
                SABEquityTestFixture.transaction('Capital Contribution', 'A', 5, 100), SABEquityTestFixture.transaction('Issue', 'A', 0, 100)};
            for (SABEquityService.TransactionRequest r : bad) {
                try {
                    SABEquityService.saveTransaction(r);
                } catch (SABEquityService.EquityException ex) {
                    messages.add(ex.getMessage());
                }
            }
            Id draft = SABEquityService.saveTransaction(SABEquityTestFixture.transaction('Issue', 'B', 10, 10));
            try {
                SABEquityService.approveTransaction(draft, 'E17-SELF');
            } catch (SABPermissionService.PermissionDeniedException ex) {
                selfApproval = 'permission';
            }
            direct = Database.update(new Equity_Transaction__c(Id = draft, Status__c = 'Posted'), false, AccessLevel.SYSTEM_MODE);
            SABEquityService.cancelTransaction(draft, 'Entered twice', 'E17-CANCEL');
        }
        SABTestGovernor.stopTest();
        List<String> fragments = new List<String>{'below par', 'holds 400 units', 'different, active receiving stakeholder',
            'does not issue units', 'units greater than zero'};
        System.assertEquals(fragments.size(), messages.size(), 'Every invalid transaction was refused.');
        for (Integer i = 0; i < fragments.size(); i++) {
            System.assert(messages[i].contains(fragments[i]), 'Expected "' + fragments[i] + '" but got: ' + messages[i]);
        }
        System.assertEquals('permission', selfApproval, 'Managers without the approve permission cannot approve.');
        System.assertEquals(false, direct.isSuccess(), 'Status changes only through the service.');
        System.assertEquals('Cancelled', [SELECT Status__c FROM Equity_Transaction__c WHERE Transaction_Type__c = 'Issue' AND Units__c = 10
            WITH SYSTEM_MODE LIMIT 1].Status__c, 'Draft cancelled.');
    }

    @IsTest
    static void creatorCannotApproveAndMasterDataIsValidated() {
        List<String> messages = new List<String>();
        Boolean outsiderDenied = false;
        Id stakeholderId;
        SABTestGovernor.startTest();
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.APPROVER)) {
            Equity_Transaction__c own = new Equity_Transaction__c(Company__c = SABEquityTestFixture.companyId(), Equity_Class__c = SABEquityTestFixture.classId(),
                Stakeholder__c = SABEquityTestFixture.stakeholderId('A'), Transaction_Type__c = 'Issue', Transaction_Date__c = Date.newInstance(2026, 2, 10),
                Units__c = 1, Value__c = 1, Currency__c = 'USD', Bank_Account__c = SABEquityTestFixture.bankAccountId());
            insert as system own;
            try {
                SABEquityService.approveTransaction(own.Id, 'E17-OWN');
            } catch (SABEquityService.EquityException ex) {
                messages.add(ex.getMessage());
            }
        }
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.MANAGER)) {
            stakeholderId = SABEquityService.saveStakeholder(SABEquityTestFixture.companyId(), 'Gamma Trust', 'g', null);
            SABEquityService.ClassRequest badClass = new SABEquityService.ClassRequest();
            badClass.companyId = SABEquityTestFixture.companyId();
            badClass.name = 'Preference';
            badClass.classCode = 'pref';
            badClass.parValue = 1;
            badClass.capitalAccountId = SABEquityTestFixture.accountId('4000');
            badClass.premiumAccountId = SABEquityTestFixture.accountId('3100');
            try {
                SABEquityService.saveClass(badClass);
            } catch (SABEquityService.EquityException ex) {
                messages.add(ex.getMessage());
            }
            badClass.capitalAccountId = SABEquityTestFixture.accountId('3000');
            Id preference = SABEquityService.saveClass(badClass);
            System.assertEquals('PREF', [SELECT Class_Code__c FROM Equity_Class__c WHERE Id = :preference WITH SYSTEM_MODE].Class_Code__c,
                'Class codes are normalized.');
        }
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.OUTSIDER)) {
            try {
                SABEquityService.saveStakeholder(SABEquityTestFixture.companyId(), 'Intruder', 'X', null);
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                outsiderDenied = true;
            }
        }
        SABTestGovernor.stopTest();
        System.assert(messages[0].contains('creator of an equity transaction cannot approve'), messages[0]);
        System.assert(messages[1].contains('active Equity accounts'), messages[1]);
        System.assertEquals(SABEquityTestFixture.companyId() + '|G', [SELECT Stakeholder_Key__c FROM Stakeholder__c WHERE Id = :stakeholderId
            WITH SYSTEM_MODE].Stakeholder_Key__c, 'Stakeholder keys are company-scoped.');
        System.assertEquals(true, outsiderDenied, 'Users without a company grant cannot maintain stakeholders.');
    }
}
