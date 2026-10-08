@IsTest
private class SABDistributionServiceTest {

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
    static void approvalSplitsByOwnershipAndPostsTheDeclaration() {
        Id distributionId;
        SABDistributionService.ActionResult approved;
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.MANAGER)) {
            distributionId = SABDistributionService.saveDraft(SABEquityTestFixture.distribution(1000.01));
        }
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.APPROVER)) {
            SABTestGovernor.startTest();
            approved = SABDistributionService.approve(distributionId, 'E17-DECLARE');
            SABTestGovernor.stopTest();
        }
        System.assertEquals('Posted Payable', approved.status, 'Declared and payable.');
        System.assertEquals(2, approved.lineCount, 'One line per holder.');
        Map<Id, Decimal> amounts = new Map<Id, Decimal>();
        for (Distribution_Line__c l : [SELECT Stakeholder__c, Entitled_Amount__c, Entitled_Units__c FROM Distribution_Line__c
                WHERE Distribution__c = :distributionId WITH SYSTEM_MODE]) {
            amounts.put(l.Stakeholder__c, l.Entitled_Amount__c);
        }
        System.assertEquals(600.01, amounts.get(SABEquityTestFixture.stakeholderId('A')), 'A: 600/1,000 plus the leftover cent.');
        System.assertEquals(400.00, amounts.get(SABEquityTestFixture.stakeholderId('B')), 'B: 400/1,000.');
        Map<String, Decimal> net = netByAccount(approved.journalEntryId);
        System.assertEquals(1000.01, net.get('3200'), 'Dr Retained earnings.');
        System.assertEquals(-1000.01, net.get('2600'), 'Cr Dividends payable.');
        System.assertNotEquals(null, [SELECT Ownership_Snapshot_Hash__c FROM Distribution__c WHERE Id = :distributionId WITH SYSTEM_MODE]
            .Ownership_Snapshot_Hash__c, 'The ownership snapshot is recorded.');
    }

    @IsTest
    static void partialSettlementPaysSelectedLinesWithATaggedPayment() {
        Id distributionId;
        SABDistributionService.ActionResult settled;
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.MANAGER)) {
            distributionId = SABEquityTestFixture.seedDeclared(new Set<String>());
        }
        Id lineA = [SELECT Id FROM Distribution_Line__c WHERE Distribution__c = :distributionId
            AND Stakeholder__c = :SABEquityTestFixture.stakeholderId('A') WITH SYSTEM_MODE].Id;
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.MANAGER)) {
            SABTestGovernor.startTest();
            settled = SABDistributionService.settle(distributionId, new List<Id>{lineA}, Date.newInstance(2026, 3, 1), 'E17-PAY-A');
            SABTestGovernor.stopTest();
        }
        System.assertEquals('Part Settled', settled.status, 'One holder still unpaid.');
        Accounting_Payment__c payment = [SELECT Amount__c, Direction__c, Processing_State__c, Distribution__c, Accounting_Event__c
            FROM Accounting_Payment__c WHERE Id = :settled.paymentId WITH SYSTEM_MODE];
        System.assertEquals(600, payment.Amount__c, 'Pays A only.');
        System.assertEquals('Disbursement', payment.Direction__c, 'Disbursement.');
        System.assertEquals('Succeeded', payment.Processing_State__c, 'Recorded as paid.');
        System.assertEquals(distributionId, payment.Distribution__c, 'Tagged with the distribution.');
        System.assertNotEquals(null, payment.Accounting_Event__c, 'Linked to its accounting event.');
        Map<String, Decimal> net = netByAccount(settled.journalEntryId);
        System.assertEquals(600, net.get('2600'), 'Dr Dividends payable.');
        System.assertEquals(-600, net.get('1100'), 'Cr Bank.');
        Distribution_Settlement__c s = [SELECT Allocated_Amount__c, Status__c, Payment__c FROM Distribution_Settlement__c
            WHERE Distribution_Line__c = :lineA WITH SYSTEM_MODE];
        System.assertEquals(600, s.Allocated_Amount__c, 'Settlement amount.');
        System.assertEquals('Effective', s.Status__c, 'Effective settlement.');
        System.assertEquals('Paid', [SELECT Settlement_State__c FROM Distribution_Line__c WHERE Id = :lineA WITH SYSTEM_MODE].Settlement_State__c,
            'Line A paid.');
        System.assertEquals('Unpaid', [SELECT Settlement_State__c FROM Distribution_Line__c WHERE Distribution__c = :distributionId
            AND Id != :lineA WITH SYSTEM_MODE].Settlement_State__c, 'Line B is untouched by a partial settlement.');
    }

    @IsTest
    static void finalSettlementCompletesTheDistribution() {
        Id distributionId;
        SABDistributionService.ActionResult settled;
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.MANAGER)) {
            distributionId = SABEquityTestFixture.seedDeclared(new Set<String>{'A'});
            SABTestGovernor.startTest();
            settled = SABDistributionService.settle(distributionId, null, Date.newInstance(2026, 3, 1), 'E17-PAY-REST');
            SABTestGovernor.stopTest();
        }
        System.assertEquals('Settled', settled.status, 'Every line paid.');
        System.assertEquals(1, settled.lineCount, 'Only the unpaid line is paid.');
        System.assertEquals(400, [SELECT Amount__c FROM Accounting_Payment__c WHERE Id = :settled.paymentId WITH SYSTEM_MODE].Amount__c,
            'Pays B only.');
    }

    @IsTest
    static void distributionPaymentsAreIsolatedFromOtherPaymentServices() {
        Id distributionId;
        Id paymentId;
        String allocationMessage;
        Database.SaveResult direct;
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.MANAGER)) {
            distributionId = SABEquityTestFixture.seedDeclared(new Set<String>());
            paymentId = SABEquityTestFixture.seedTaggedPayment(distributionId);
        }
        SABTestGovernor.startTest();
        SABPaymentAllocationService.PaymentAllocationRequest r = new SABPaymentAllocationService.PaymentAllocationRequest();
        r.allocatedAmount = 600;
        try {
            SABPaymentAllocationService.allocatePayment(paymentId, new List<SABPaymentAllocationService.PaymentAllocationRequest>{r});
        } catch (SABPaymentAllocationService.PaymentAllocationException ex) {
            allocationMessage = ex.getMessage();
        }
        direct = Database.update(new Accounting_Payment__c(Id = paymentId, Distribution__c = null), false, AccessLevel.SYSTEM_MODE);
        SABTestGovernor.stopTest();
        System.assert(allocationMessage != null && allocationMessage.contains('Distribution payments are processed only through distribution settlement'),
            'AP/AR allocation rejects distribution payments: ' + allocationMessage);
        System.assertEquals(false, direct.isSuccess(), 'The distribution tag cannot be removed directly.');
    }

    @IsTest
    static void validatesDistributionsAndSeparatesDuties() {
        List<String> messages = new List<String>();
        SABTestGovernor.startTest();
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.MANAGER)) {
            SABDistributionService.DistributionRequest lateRecord = SABEquityTestFixture.distribution(100);
            lateRecord.recordDate = Date.newInstance(2026, 2, 20);
            SABDistributionService.DistributionRequest badSource = SABEquityTestFixture.distribution(100);
            badSource.sourceAccountId = SABEquityTestFixture.accountId('4000');
            for (SABDistributionService.DistributionRequest r : new List<SABDistributionService.DistributionRequest>{lateRecord, badSource,
                    SABEquityTestFixture.distribution(0)}) {
                try {
                    SABDistributionService.saveDraft(r);
                } catch (SABDistributionService.DistributionException ex) {
                    messages.add(ex.getMessage());
                }
            }
            Id draft = SABDistributionService.saveDraft(SABEquityTestFixture.distribution(100));
            try {
                SABDistributionService.settle(draft, null, Date.newInstance(2026, 3, 1), 'E17-SETTLE-DRAFT');
            } catch (SABDistributionService.DistributionException ex) {
                messages.add(ex.getMessage());
            }
            SABDistributionService.cancel(draft, 'Board did not approve', 'E17-CANCEL-DIST');
        }
        System.runAs(SABEquityTestFixture.user(SABEquityTestFixture.APPROVER)) {
            Distribution__c own = new Distribution__c(Company__c = SABEquityTestFixture.companyId(), Equity_Class__c = SABEquityTestFixture.classId(),
                Distribution_Type__c = 'Dividend', Declaration_Date__c = Date.newInstance(2026, 2, 15), Record_Date__c = Date.newInstance(2026, 2, 10),
                Total_Amount__c = 100, Currency__c = 'USD', Source_Account__c = SABEquityTestFixture.accountId('3200'),
                Payable_Account__c = SABEquityTestFixture.accountId('2600'), Bank_Account__c = SABEquityTestFixture.bankAccountId());
            insert as system own;
            try {
                SABDistributionService.approve(own.Id, 'E17-OWN-DIST');
            } catch (SABDistributionService.DistributionException ex) {
                messages.add(ex.getMessage());
            }
        }
        SABTestGovernor.stopTest();
        List<String> fragments = new List<String>{'record date cannot be after', 'active Equity account', 'greater than zero',
            'declared, unsettled', 'creator of a distribution cannot approve'};
        System.assertEquals(fragments.size(), messages.size(), 'Every invalid request was refused.');
        for (Integer i = 0; i < fragments.size(); i++) {
            System.assert(messages[i].contains(fragments[i]), 'Expected "' + fragments[i] + '" but got: ' + messages[i]);
        }
        System.assertEquals(1, [SELECT COUNT() FROM Distribution__c WHERE Status__c = 'Cancelled' WITH SYSTEM_MODE], 'Draft cancelled.');
    }
}
