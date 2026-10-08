@IsTest
private class SABInvestmentServiceTest {

    @TestSetup
    static void setupData() {
        SABLoanInvestmentTestFixture.createFixture();
    }

    private static SABInvestmentService.TransactionRequest tx(Id investmentId, String type, Integer day, Decimal amount, Decimal quantity) {
        SABInvestmentService.TransactionRequest r = new SABInvestmentService.TransactionRequest();
        r.investmentId = investmentId;
        r.transactionType = type;
        r.transactionDate = Date.newInstance(2026, 2, day);
        r.amount = amount;
        r.quantity = quantity;
        return r;
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
    static void acquiresAndRevaluesThroughTheLedger() {
        Id investmentId;
        SABInvestmentService.ActionResult acquired;
        SABInvestmentService.ActionResult valued;
        SABInvestmentService.ActionResult replay;
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.MANAGER)) {
            investmentId = SABInvestmentService.saveInvestment(SABLoanInvestmentTestFixture.investmentRequest('fvtpl'));
            SABTestGovernor.startTest();
            acquired = SABInvestmentService.recordTransaction(tx(investmentId, 'Acquisition', 2, 10000, 100), 'L16-BUY');
            replay = SABInvestmentService.recordTransaction(tx(investmentId, 'Acquisition', 2, 10000, 100), 'L16-BUY');
            valued = SABInvestmentService.recordTransaction(tx(investmentId, 'Valuation', 28, -250, null), 'L16-VALUE');
            SABTestGovernor.stopTest();
        }
        System.assertEquals(true, replay.replay, 'Same key replays.');
        System.assertEquals(acquired.transactionId, replay.transactionId, 'Replay returns the first transaction.');
        Map<String, Decimal> buy = netByAccount(acquired.journalEntryId);
        System.assertEquals(10000, buy.get('1500'), 'Dr Investments.');
        System.assertEquals(-10000, buy.get('1100'), 'Cr Bank.');
        Map<String, Decimal> loss = netByAccount(valued.journalEntryId);
        System.assertEquals(-250, loss.get('1500'), 'A fair value loss reduces the investment.');
        System.assertEquals(250, loss.get('4900'), 'Dr Gain/Loss.');
        SABInvestmentService.Holding h;
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.MANAGER)) {
            h = SABInvestmentService.getHolding(investmentId);
        }
        System.assertEquals(100, h.quantity, 'Units held.');
        System.assertEquals(9750, h.carryingAmount, 'Cost plus fair value changes.');
        Investment_Transaction__c posted = [SELECT Journal_Entry__r.Entry_Type__c, Accounting_Event__c FROM Investment_Transaction__c
            WHERE Id = :acquired.transactionId WITH SYSTEM_MODE];
        System.assertEquals('Subledger', posted.Journal_Entry__r.Entry_Type__c, 'Subledger journal.');
        System.assertNotEquals(null, posted.Accounting_Event__c, 'The event is linked to the transaction.');
    }

    @IsTest
    static void disposalsRelieveAverageCarryingAmountAndCloseTheHolding() {
        Id investmentId;
        SABInvestmentService.ActionResult partial;
        SABInvestmentService.ActionResult full;
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.MANAGER)) {
            investmentId = SABLoanInvestmentTestFixture.seedHolding('FVTPL');
            SABTestGovernor.startTest();
            partial = SABInvestmentService.recordTransaction(tx(investmentId, 'Disposal', 10, 4500, 40), 'L16-SELL-40');
            full = SABInvestmentService.recordTransaction(tx(investmentId, 'Disposal', 20, 6000, 60), 'L16-SELL-60');
            SABTestGovernor.stopTest();
        }
        System.assertEquals(4200, partial.carryingAmountRelieved, '40 of 100 units of a 10,500 carrying amount.');
        System.assertEquals(300, partial.realizedGainLoss, 'Proceeds 4,500 less 4,200.');
        Map<String, Decimal> sale = netByAccount(partial.journalEntryId);
        System.assertEquals(4500, sale.get('1100'), 'Dr Bank proceeds.');
        System.assertEquals(-4200, sale.get('1500'), 'Cr Investments carrying amount.');
        System.assertEquals(-300, sale.get('4900'), 'Cr realized gain.');
        System.assertEquals(6300, full.carryingAmountRelieved, 'The rest of the carrying amount.');
        System.assertEquals(-300, full.realizedGainLoss, 'Realized loss on the remainder.');
        System.assertEquals(300, netByAccount(full.journalEntryId).get('4900'), 'Dr realized loss.');
        System.assertEquals('Disposed', full.investmentStatus, 'A full disposal closes the holding.');
        System.assertEquals('Disposed', [SELECT Status__c FROM Investment__c WHERE Id = :investmentId WITH SYSTEM_MODE].Status__c, 'Status updated.');
    }

    @IsTest
    static void incomeAndFeesPostAndCostPolicyRefusesValuation() {
        Id investmentId;
        SABInvestmentService.ActionResult income;
        SABInvestmentService.ActionResult fee;
        List<String> messages = new List<String>();
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.MANAGER)) {
            investmentId = SABLoanInvestmentTestFixture.seedHolding('COST');
            // Refusals run before the governor window, which is kept for the two postings.
            List<SABInvestmentService.TransactionRequest> bad = new List<SABInvestmentService.TransactionRequest>{
                tx(investmentId, 'Valuation', 17, 100, null), tx(investmentId, 'Disposal', 18, 1000, 101),
                tx(investmentId, 'Acquisition', 19, 100, 0), tx(investmentId, 'Gift', 20, 100, 1)};
            Integer n = 0;
            for (SABInvestmentService.TransactionRequest r : bad) {
                try {
                    SABInvestmentService.recordTransaction(r, 'L16-BAD-' + n++);
                } catch (SABInvestmentService.InvestmentException ex) {
                    messages.add(ex.getMessage());
                }
            }
            try {
                SABInvestmentService.saveInvestment(investmentRequestFor(investmentId));
            } catch (SABInvestmentService.InvestmentException ex) {
                messages.add(ex.getMessage());
            }
            SABTestGovernor.startTest();
            income = SABInvestmentService.recordTransaction(tx(investmentId, 'Income', 15, 320, null), 'L16-DIVIDEND');
            fee = SABInvestmentService.recordTransaction(tx(investmentId, 'Fee', 16, 25, null), 'L16-FEE');
            SABTestGovernor.stopTest();
        }
        System.assertEquals(320, netByAccount(income.journalEntryId).get('1100'), 'Income: Dr Bank.');
        System.assertEquals(-320, netByAccount(income.journalEntryId).get('4800'), 'Income: Cr Investment income.');
        System.assertEquals(25, netByAccount(fee.journalEntryId).get('6900'), 'Fee: Dr Fees.');
        List<String> fragments = new List<String>{'only for FVTPL', 'Cannot dispose of 101 units; 100 are held', 'quantity must be greater than zero',
            'are required', 'cannot change'};
        System.assertEquals(fragments.size(), messages.size(), 'Every invalid request was refused.');
        for (Integer i = 0; i < fragments.size(); i++) {
            System.assert(messages[i].contains(fragments[i]), 'Expected "' + fragments[i] + '" but got: ' + messages[i]);
        }
    }

    private static SABInvestmentService.InvestmentRequest investmentRequestFor(Id investmentId) {
        SABInvestmentService.InvestmentRequest r = SABLoanInvestmentTestFixture.investmentRequest('FVTPL');
        r.investmentId = investmentId;
        return r;
    }

    @IsTest
    static void validatesInvestmentSetupGuardsAndAccess() {
        List<String> messages = new List<String>();
        Boolean outsiderDenied = false;
        Database.SaveResult directTx;
        Database.SaveResult directStatus;
        SABTestGovernor.startTest();
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.MANAGER)) {
            SABInvestmentService.InvestmentRequest badPolicy = SABLoanInvestmentTestFixture.investmentRequest('MARK-TO-MODEL');
            SABInvestmentService.InvestmentRequest badAccount = SABLoanInvestmentTestFixture.investmentRequest('COST');
            badAccount.investmentAccountId = SABLoanInvestmentTestFixture.accountId('4800');
            for (SABInvestmentService.InvestmentRequest r : new List<SABInvestmentService.InvestmentRequest>{badPolicy, badAccount}) {
                try {
                    SABInvestmentService.saveInvestment(r);
                } catch (SABInvestmentService.InvestmentException ex) {
                    messages.add(ex.getMessage());
                }
            }
            Id investmentId = SABInvestmentService.saveInvestment(SABLoanInvestmentTestFixture.investmentRequest('COST'));
            directTx = Database.insert(new Investment_Transaction__c(Investment__c = investmentId, Transaction_Type__c = 'Income',
                Transaction_Date__c = Date.newInstance(2026, 2, 1), Accounting_Date__c = Date.newInstance(2026, 2, 1), Amount__c = 1,
                Currency__c = 'USD'), false, AccessLevel.SYSTEM_MODE);
            directStatus = Database.update(new Investment__c(Id = investmentId, Status__c = 'Closed'), false, AccessLevel.SYSTEM_MODE);
        }
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.OUTSIDER)) {
            try {
                SABInvestmentService.saveInvestment(SABLoanInvestmentTestFixture.investmentRequest('COST'));
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                outsiderDenied = true;
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals(2, messages.size(), 'Both invalid investments were refused: ' + messages);
        System.assert(messages[0].contains('COST or FVTPL'), messages[0]);
        System.assert(messages[1].contains('investment Asset'), messages[1]);
        System.assertEquals(false, directTx.isSuccess(), 'Investment transactions are system records.');
        System.assertEquals(false, directStatus.isSuccess(), 'Investment status changes only through the service.');
        System.assertEquals(true, outsiderDenied, 'Users without a company grant cannot create investments.');
    }
}
