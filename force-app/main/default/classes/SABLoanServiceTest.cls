@IsTest
private class SABLoanServiceTest {

    @TestSetup
    static void setupData() {
        SABLoanInvestmentTestFixture.createFixture();
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
    static void approvalSchedulesAndPostsTheDrawdown() {
        Id loanId;
        SABLoanService.ActionResult approved;
        SABLoanService.ActionResult replay;
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.MANAGER)) {
            loanId = SABLoanService.saveDraft(SABLoanInvestmentTestFixture.loanRequest('Borrowing', 'Annuity'));
        }
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.APPROVER)) {
            SABTestGovernor.startTest();
            approved = SABLoanService.approve(loanId, 'L16-APPROVE');
            replay = SABLoanService.approve(loanId, 'L16-APPROVE');
            SABTestGovernor.stopTest();
        }
        System.assertEquals('Active', approved.status, 'Loan is Active.');
        System.assertEquals(true, replay.replay, 'Same key replays.');
        Loan__c loan = [SELECT Currency__c, Drawdown_Journal__c, Approved_By__c, Drawdown_Journal__r.Status__c, Drawdown_Journal__r.Entry_Type__c
            FROM Loan__c WHERE Id = :loanId WITH SYSTEM_MODE];
        System.assertEquals('USD', loan.Currency__c, 'Functional currency.');
        System.assertEquals('Posted', loan.Drawdown_Journal__r.Status__c, 'Drawdown posted through SABPostingService.');
        System.assertEquals('Subledger', loan.Drawdown_Journal__r.Entry_Type__c, 'Subledger journal.');
        Map<String, Decimal> net = netByAccount(loan.Drawdown_Journal__c);
        System.assertEquals(12000, net.get('1100'), 'Borrowing: Dr Bank.');
        System.assertEquals(-12000, net.get('2500'), 'Borrowing: Cr Loan payable.');
        List<Loan_Schedule_Line__c> lines = [SELECT Sequence__c, Principal_Due__c, Interest_Due__c, Status__c FROM Loan_Schedule_Line__c
            WHERE Loan__c = :loanId WITH SYSTEM_MODE ORDER BY Sequence__c];
        System.assertEquals(3, lines.size(), 'Three instalments.');
        System.assertEquals(3960.27, lines[0].Principal_Due__c, 'Annuity principal.');
        System.assertEquals('Planned', lines[0].Status__c, 'Lines start Planned.');
    }

    @IsTest
    static void lendingAccruesAndRepaysInOrder() {
        Id loanId;
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.MANAGER)) {
            // Two equal-principal instalments of 6,000; the second is already accrued so ordering can be tested.
            loanId = SABLoanInvestmentTestFixture.seedActiveLoan('Lending', 'Equal Principal', Date.newInstance(2026, 3, 1),
                new List<String>{'Planned', 'Due'});
        }
        List<Loan_Schedule_Line__c> lines = [SELECT Id FROM Loan_Schedule_Line__c WHERE Loan__c = :loanId WITH SYSTEM_MODE ORDER BY Sequence__c];
        SABLoanService.ActionResult accrued;
        SABLoanService.ActionResult repaid;
        String outOfOrder;
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.MANAGER)) {
            SABTestGovernor.startTest();
            accrued = SABLoanService.accrueInterest(lines[0].Id, 'L16-ACCRUE-1');
            try {
                SABLoanService.recordRepayment(lines[1].Id, 'L16-REPAY-2-EARLY');
            } catch (SABLoanService.LoanException ex) {
                outOfOrder = ex.getMessage();
            }
            repaid = SABLoanService.recordRepayment(lines[0].Id, 'L16-REPAY-1');
            SABTestGovernor.stopTest();
        }
        System.assert(outOfOrder != null && outOfOrder.contains('Earlier instalments'), 'Instalments are repaid in order: ' + outOfOrder);
        Map<String, Decimal> accrual = netByAccount(accrued.journalEntryId);
        System.assertEquals(120, accrual.get('1310'), 'Lending accrual: Dr Interest receivable.');
        System.assertEquals(-120, accrual.get('4700'), 'Lending accrual: Cr Interest income.');
        Map<String, Decimal> repayment = netByAccount(repaid.journalEntryId);
        System.assertEquals(6120, repayment.get('1100'), 'Lending repayment: Dr Bank for principal and interest.');
        System.assertEquals(-6000, repayment.get('1300'), 'Cr Loan receivable.');
        System.assertEquals(-120, repayment.get('1310'), 'Cr Interest receivable.');
        System.assertEquals('Paid', [SELECT Status__c FROM Loan_Schedule_Line__c WHERE Id = :lines[0].Id WITH SYSTEM_MODE].Status__c, 'Line paid.');
        System.assertEquals('Active', [SELECT Status__c FROM Loan__c WHERE Id = :loanId WITH SYSTEM_MODE].Status__c, 'One instalment left.');
    }

    @IsTest
    static void lastRepaymentClosesTheLoan() {
        Id loanId;
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.MANAGER)) {
            loanId = SABLoanInvestmentTestFixture.seedActiveLoan('Shareholder Loan', 'Annuity', Date.newInstance(2026, 2, 1),
                new List<String>{'Due'});
        }
        Id lineId = [SELECT Id FROM Loan_Schedule_Line__c WHERE Loan__c = :loanId WITH SYSTEM_MODE].Id;
        SABLoanService.ActionResult repaid;
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.MANAGER)) {
            SABTestGovernor.startTest();
            repaid = SABLoanService.recordRepayment(lineId, 'L16-ONE-REPAY');
            SABTestGovernor.stopTest();
        }
        System.assertEquals('Closed', [SELECT Status__c FROM Loan__c WHERE Id = :loanId WITH SYSTEM_MODE].Status__c, 'The last repayment closes the loan.');
        Map<String, Decimal> repayment = netByAccount(repaid.journalEntryId);
        System.assertEquals(12000, repayment.get('2500'), 'Shareholder loans post as borrowings: Dr Loan payable.');
        System.assertEquals(-12120, repayment.get('1100'), 'Cr Bank for principal and one month of interest.');
    }

    @IsTest
    static void validatesTermsAccountsAndSeparatesDuties() {
        List<String> messages = new List<String>();
        String selfApproval;
        SABTestGovernor.startTest();
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.MANAGER)) {
            List<SABLoanService.LoanRequest> bad = new List<SABLoanService.LoanRequest>();
            SABLoanService.LoanRequest wrongType = SABLoanInvestmentTestFixture.loanRequest('Borrowing', 'Annuity');
            wrongType.loanType = 'Mortgage';
            bad.add(wrongType);
            SABLoanService.LoanRequest offDate = SABLoanInvestmentTestFixture.loanRequest('Borrowing', 'Annuity');
            offDate.maturityDate = Date.newInstance(2026, 4, 15);
            bad.add(offDate);
            SABLoanService.LoanRequest wrongAccount = SABLoanInvestmentTestFixture.loanRequest('Borrowing', 'Annuity');
            wrongAccount.principalAccountId = SABLoanInvestmentTestFixture.accountId('1300');
            bad.add(wrongAccount);
            SABLoanService.LoanRequest sameAccount = SABLoanInvestmentTestFixture.loanRequest('Borrowing', 'Annuity');
            sameAccount.accruedInterestAccountId = sameAccount.principalAccountId;
            bad.add(sameAccount);
            for (SABLoanService.LoanRequest r : bad) {
                try {
                    SABLoanService.saveDraft(r);
                } catch (SABLoanService.LoanException ex) {
                    messages.add(ex.getMessage());
                }
            }
            Id draft = SABLoanService.saveDraft(SABLoanInvestmentTestFixture.loanRequest('Borrowing', 'Annuity'));
            try {
                SABLoanService.approve(draft, 'L16-SELF');
            } catch (SABPermissionService.PermissionDeniedException ex) {
                selfApproval = 'permission';
            }
        }
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.APPROVER)) {
            Id own = SABLoanInvestmentTestFixture.seedDraftLoan('Borrowing', 'Annuity', Date.newInstance(2026, 4, 1));
            try {
                SABLoanService.approve(own, 'L16-OWN');
            } catch (SABLoanService.LoanException ex) {
                messages.add(ex.getMessage());
            }
        }
        SABTestGovernor.stopTest();
        List<String> fragments = new List<String>{'Borrowing, Lending or Shareholder Loan', 'instalment date', 'Liability',
            'three different accounts', 'creator of a loan cannot approve'};
        System.assertEquals(fragments.size(), messages.size(), 'Every invalid request was refused.');
        for (Integer i = 0; i < fragments.size(); i++) {
            System.assert(messages[i].contains(fragments[i]), 'Expected "' + fragments[i] + '" but got: ' + messages[i]);
        }
        System.assertEquals('permission', selfApproval, 'Managers without the approve permission cannot approve.');
    }

    @IsTest
    static void guardsAndCompanyAccess() {
        Boolean outsiderDenied = false;
        List<Database.SaveResult> blocked;
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.MANAGER)) {
            Id draft = SABLoanInvestmentTestFixture.seedDraftLoan('Borrowing', 'Annuity', Date.newInstance(2026, 4, 1));
            SABTestGovernor.startTest();
            blocked = new List<Database.SaveResult>{
                Database.update(new Loan__c(Id = draft, Status__c = 'Active'), false, AccessLevel.SYSTEM_MODE),
                Database.insert(new Loan_Schedule_Line__c(Loan__c = draft, Due_Date__c = Date.newInstance(2026, 2, 1), Status__c = 'Paid'), false,
                    AccessLevel.SYSTEM_MODE)};
            SABTestGovernor.stopTest();
        }
        System.runAs(SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.OUTSIDER)) {
            try {
                SABLoanService.saveDraft(SABLoanInvestmentTestFixture.loanRequest('Borrowing', 'Annuity'));
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                outsiderDenied = true;
            }
        }
        System.assertEquals(false, blocked[0].isSuccess(), 'Loan status changes only through the service.');
        System.assertEquals(false, blocked[1].isSuccess(), 'Schedule lines are system records.');
        System.assertEquals(true, outsiderDenied, 'Users without a company grant cannot create loans.');
        System.assertEquals(true, SABLoanService.isAsset('Lending'), 'Lending is an asset.');
    }
}
