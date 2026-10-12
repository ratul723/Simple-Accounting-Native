@IsTest
private class SABLoansInvestmentsWorkspaceCtrlTest {

    private static final String WORKSPACE_SET = 'SAB_Loans_Investments_Workspace_User';

    @TestSetup
    static void setupData() {
        SABLoanInvestmentTestFixture.createFixture();
    }

    private static User workspaceUser(String lastName) {
        User user = SABLoanInvestmentTestFixture.user(lastName);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Id setId = [SELECT Id FROM PermissionSet WHERE Name = :WORKSPACE_SET WITH SYSTEM_MODE LIMIT 1].Id;
            insert as system new PermissionSetAssignment(AssigneeId = user.Id, PermissionSetId = setId);
        }
        return user;
    }

    @IsTest
    static void workspaceListsLoansSchedulesHoldingsAndFigures() {
        User manager = workspaceUser(SABLoanInvestmentTestFixture.MANAGER);
        Id companyId = SABLoanInvestmentTestFixture.companyId();
        SABLoansInvestmentsWorkspaceController.WorkspaceData data;
        Id activeId;
        System.runAs(manager) {
            activeId = SABLoanInvestmentTestFixture.seedActiveLoan('Borrowing', 'Equal Principal', Date.newInstance(2026, 4, 1),
                new List<String>{ 'Paid', 'Due', 'Planned' });
            SABLoanInvestmentTestFixture.seedDraftLoan('Lending', 'Annuity', Date.newInstance(2026, 4, 1));
            SABLoanInvestmentTestFixture.seedHolding('FVTPL');
            Test.startTest();
            data = SABLoansInvestmentsWorkspaceController.getWorkspace(companyId);
            Test.stopTest();
        }
        System.assertEquals('USD', data.currencyCode, 'Functional currency is returned.');
        System.assert(data.canManageLoans && data.canManageInvestments, 'Manager holds the manage permissions.');
        System.assert(!data.canApproveLoans, 'Manager cannot approve loans.');
        System.assertEquals(2, data.loans.size(), 'Both loans are listed.');
        SABLoansInvestmentsWorkspaceController.LoanRow active;
        SABLoansInvestmentsWorkspaceController.LoanRow draft;
        for (SABLoansInvestmentsWorkspaceController.LoanRow row : data.loans) {
            if (row.loanId == activeId) {
                active = row;
            } else {
                draft = row;
            }
        }
        System.assertEquals(3, active.lines.size(), 'Three monthly instalments.');
        System.assertEquals(8000, active.balance, 'Balance after the first equal-principal instalment.');
        System.assertEquals(4000, active.repaid, 'Repaid principal.');
        System.assertEquals('repay', active.nextAction, 'The Due line is repaid next.');
        System.assertEquals(active.lines[1].lineId, active.nextLineId, 'Second instalment is next.');
        System.assertEquals(active.lines[1].principalDue + active.lines[1].interest, active.nextPayment, 'Payment is principal plus interest.');
        System.assertEquals(8000, data.borrowings, 'Active borrowings use the outstanding balance.');
        System.assertEquals(1, data.borrowingCount, 'One active borrowing.');
        System.assertEquals('Draft', draft.status, 'Draft loan is listed.');
        System.assert(draft.createdByMe, 'Creator is flagged so approval is refused in the UI.');
        System.assertEquals(null, draft.nextAction, 'Draft loans have no schedule action.');
        System.assertEquals(1, data.investments.size(), 'One investment.');
        System.assertEquals(10500, data.investments[0].carryingAmount, 'Acquisition plus valuation.');
        System.assertEquals(100, data.investments[0].quantity, 'Units held.');
        System.assertEquals(10000, data.investments[0].cost, 'Cost of acquisitions.');
        System.assertEquals(10500, data.investmentsTotal, 'Investments figure is the carrying amount.');
        System.assertEquals(2, data.transactions.size(), 'Both transactions are listed.');
        System.assert(data.transactions[0].posted, 'Seeded transactions are posted.');
    }

    @IsTest
    static void formOptionsListAccountsBanksAndCounterparties() {
        User manager = workspaceUser(SABLoanInvestmentTestFixture.MANAGER);
        Id companyId = SABLoanInvestmentTestFixture.companyId();
        SABLoansInvestmentsWorkspaceController.FormOptions options;
        System.runAs(manager) {
            Test.startTest();
            options = SABLoansInvestmentsWorkspaceController.getFormOptions(companyId);
            Test.stopTest();
        }
        System.assertEquals(11, options.glAccounts.size(), 'Every active GL account of the company.');
        System.assertEquals('1100 Bank', options.glAccounts[0].label, 'Code and name, ordered by code.');
        System.assertEquals('Asset', options.glAccounts[0].kind, 'Account type is carried for filtering.');
        System.assertEquals(1, options.bankAccounts.size(), 'One active bank account.');
        Boolean counterpartyListed = false;
        for (SABLoansInvestmentsWorkspaceController.Option option : options.counterparties) {
            counterpartyListed = counterpartyListed || option.label == 'L16 Counterparty Bank';
        }
        System.assert(counterpartyListed, 'Counterparty accounts are listed.');
    }

    @IsTest
    static void viewPermissionIsRequired() {
        User manager = SABLoanInvestmentTestFixture.user(SABLoanInvestmentTestFixture.MANAGER);
        Id companyId = SABLoanInvestmentTestFixture.companyId();
        String message;
        System.runAs(manager) {
            Test.startTest();
            try {
                SABLoansInvestmentsWorkspaceController.getWorkspace(companyId);
            } catch (AuraHandledException ex) {
                message = ex.getMessage();
            }
            Test.stopTest();
        }
        System.assertEquals('You do not have permission to view Investments & loans.', message, 'SAB_View_Loans_Investments is required.');
    }

    @IsTest
    static void companyGrantIsRequired() {
        User outsider = workspaceUser(SABLoanInvestmentTestFixture.OUTSIDER);
        Id companyId = SABLoanInvestmentTestFixture.companyId();
        String grantMessage;
        String missingMessage;
        System.runAs(outsider) {
            Test.startTest();
            try {
                SABLoansInvestmentsWorkspaceController.getFormOptions(companyId);
            } catch (AuraHandledException ex) {
                grantMessage = ex.getMessage();
            }
            try {
                SABLoansInvestmentsWorkspaceController.getWorkspace(null);
            } catch (AuraHandledException ex) {
                missingMessage = ex.getMessage();
            }
            Test.stopTest();
        }
        System.assertEquals('You do not have active access to this Accounting Company.', grantMessage, 'A grant is required.');
        System.assertEquals('Accounting Company is required.', missingMessage, 'A company is required.');
    }

    @IsTest
    static void helpersFollowTheServiceRules() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            System.assertEquals(Date.newInstance(2026, 7, 1),
                SABLoansInvestmentsWorkspaceController.fiscalYearStart(Date.newInstance(2026, 10, 12), 7), 'Same calendar year.');
            System.assertEquals(Date.newInstance(2025, 7, 1),
                SABLoansInvestmentsWorkspaceController.fiscalYearStart(Date.newInstance(2026, 3, 1), 7), 'Previous calendar year.');
            System.assertEquals(Date.newInstance(2026, 1, 1),
                SABLoansInvestmentsWorkspaceController.fiscalYearStart(Date.newInstance(2026, 3, 1), null), 'Defaults to January.');
            SABLoansInvestmentsWorkspaceController.InvestmentRow row = new SABLoansInvestmentsWorkspaceController.InvestmentRow();
            row.quantity = 100;
            row.carryingAmount = 10000;
            row.cost = 10000;
            row.incomeYearToDate = 0;
            Date fyStart = Date.newInstance(2026, 1, 1);
            SABLoansInvestmentsWorkspaceController.applyTransaction(row, new Investment_Transaction__c(Transaction_Type__c = 'Disposal',
                Amount__c = 6000, Quantity__c = 40, Carrying_Amount_Relieved__c = 4000), fyStart);
            SABLoansInvestmentsWorkspaceController.applyTransaction(row, new Investment_Transaction__c(Transaction_Type__c = 'Income',
                Amount__c = 120, Transaction_Date__c = Date.newInstance(2026, 2, 1)), fyStart);
            SABLoansInvestmentsWorkspaceController.applyTransaction(row, new Investment_Transaction__c(Transaction_Type__c = 'Income',
                Amount__c = 80, Transaction_Date__c = Date.newInstance(2025, 12, 1)), fyStart);
            SABLoansInvestmentsWorkspaceController.applyTransaction(row, new Investment_Transaction__c(Transaction_Type__c = 'Fee',
                Amount__c = 25), fyStart);
            Test.stopTest();
            System.assertEquals(60, row.quantity, 'Disposal relieves quantity.');
            System.assertEquals(6000, row.carryingAmount, 'Disposal relieves the carrying amount, fees do not.');
            System.assertEquals(120, row.incomeYearToDate, 'Only income in the fiscal year counts.');
        }
    }
}
