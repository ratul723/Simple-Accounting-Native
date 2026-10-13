@IsTest
private class SABEquityWorkspaceControllerTest {

    private static final String WORKSPACE_SET = 'SAB_Equity_Workspace_User';

    @TestSetup
    static void setupData() {
        SABEquityTestFixture.createFixture();
    }

    private static User workspaceUser(String lastName) {
        User user = SABEquityTestFixture.user(lastName);
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Id setId = [SELECT Id FROM PermissionSet WHERE Name = :WORKSPACE_SET WITH SYSTEM_MODE LIMIT 1].Id;
            insert as system new PermissionSetAssignment(AssigneeId = user.Id, PermissionSetId = setId);
        }
        return user;
    }

    @IsTest
    static void workspaceShowsRegisterTransactionsAndDistributions() {
        User manager = workspaceUser(SABEquityTestFixture.MANAGER);
        Id companyId = SABEquityTestFixture.companyId();
        SABEquityWorkspaceController.WorkspaceData data;
        System.runAs(manager) {
            Equity_Transaction__c draft = new Equity_Transaction__c(Company__c = companyId, Equity_Class__c = SABEquityTestFixture.classId(),
                Stakeholder__c = SABEquityTestFixture.stakeholderId('A'), Transaction_Type__c = 'Issue',
                Transaction_Date__c = Date.newInstance(2026, 2, 10), Units__c = 100, Value__c = 150, Currency__c = 'USD', Status__c = 'Draft');
            SABEquityGuard.beginWrite();
            try {
                insert as system draft;
            } finally {
                SABEquityGuard.endWrite();
            }
            SABEquityTestFixture.seedDeclared(new Set<String>{ 'A' });
            Test.startTest();
            data = SABEquityWorkspaceController.getWorkspace(companyId);
            Test.stopTest();
        }
        System.assertEquals('USD', data.currencyCode, 'Functional currency.');
        System.assert(data.canManage && !data.canApprove, 'Manager manages but cannot approve.');
        System.assertEquals(1, data.classes.size(), 'One share class.');
        System.assertEquals(1000, data.classes[0].unitsOutstanding, 'Posted issues only; the draft is excluded.');
        System.assertEquals(2, data.classes[0].holdings.size(), 'Two holders.');
        Map<String, Decimal> percentByHolder = new Map<String, Decimal>();
        for (SABEquityWorkspaceController.HoldingRow holding : data.classes[0].holdings) {
            percentByHolder.put(holding.stakeholderName, holding.percent);
        }
        System.assertEquals(60, percentByHolder.get('Alpha Holdings'), 'Alpha holds 60%.');
        System.assertEquals(1000, data.shareCapital, 'Units x par 1.00.');
        System.assertEquals(2, data.holderCount, 'Two shareholders.');
        System.assertEquals(2, data.stakeholders.size(), 'Both stakeholders listed.');
        System.assertEquals(3, data.transactions.size(), 'Two posted issues and one draft.');
        Boolean draftMine = false;
        for (SABEquityWorkspaceController.TransactionRow row : data.transactions) {
            draftMine = draftMine || (row.status == 'Draft' && row.createdByMe);
        }
        System.assert(draftMine, 'The manager created the draft.');
        System.assert(data.distributionsAvailable, 'Distributions are readable.');
        System.assertEquals(1, data.distributions.size(), 'One distribution.');
        System.assertEquals(2, data.distributions[0].lines.size(), 'Two entitlement lines.');
        System.assertEquals(1000, data.declaredThisYear, 'Declared in the fiscal year.');
        System.assertEquals(1000, data.unpaid, 'No effective settlements yet.');
        System.assertEquals(Date.newInstance(2026, 3, 1), data.nextPaymentDue, 'Payment due date.');
    }

    @IsTest
    static void formOptionsListAccounts() {
        User manager = workspaceUser(SABEquityTestFixture.MANAGER);
        Id companyId = SABEquityTestFixture.companyId();
        SABEquityWorkspaceController.FormOptions options;
        System.runAs(manager) {
            Test.startTest();
            options = SABEquityWorkspaceController.getFormOptions(companyId);
            Test.stopTest();
        }
        System.assertEquals(6, options.glAccounts.size(), 'Every active GL account.');
        System.assertEquals('1100 Bank', options.glAccounts[0].label, 'Code and name.');
        System.assertEquals(1, options.bankAccounts.size(), 'One bank account.');
        System.assertNotEquals(null, options.accounts, 'Accounts list is returned.');
    }

    @IsTest
    static void viewPermissionIsRequired() {
        User manager = SABEquityTestFixture.user(SABEquityTestFixture.MANAGER);
        Id companyId = SABEquityTestFixture.companyId();
        String message;
        System.runAs(manager) {
            Test.startTest();
            try {
                SABEquityWorkspaceController.getWorkspace(companyId);
            } catch (AuraHandledException ex) {
                message = ex.getMessage();
            }
            Test.stopTest();
        }
        System.assertEquals('You do not have permission to view Capital & equity.', message, 'SAB_View_Equity is required.');
    }

    @IsTest
    static void companyGrantIsRequired() {
        User outsider = workspaceUser(SABEquityTestFixture.OUTSIDER);
        Id companyId = SABEquityTestFixture.companyId();
        String grantMessage;
        String missingMessage;
        System.runAs(outsider) {
            Test.startTest();
            try {
                SABEquityWorkspaceController.getFormOptions(companyId);
            } catch (AuraHandledException ex) {
                grantMessage = ex.getMessage();
            }
            try {
                SABEquityWorkspaceController.getWorkspace(null);
            } catch (AuraHandledException ex) {
                missingMessage = ex.getMessage();
            }
            Test.stopTest();
        }
        System.assertEquals('You do not have active access to this Accounting Company.', grantMessage, 'A grant is required.');
        System.assertEquals('Accounting Company is required.', missingMessage, 'A company is required.');
    }

    @IsTest
    static void holdingsFollowTheServiceRules() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Id classId = SABEquityTestFixture.classId();
            Id holderA = SABEquityTestFixture.stakeholderId('A');
            Id holderB = SABEquityTestFixture.stakeholderId('B');
            Map<Id, Map<Id, Decimal>> units = new Map<Id, Map<Id, Decimal>>();
            Test.startTest();
            SABEquityWorkspaceController.applyHolding(units, new Equity_Transaction__c(Equity_Class__c = classId, Stakeholder__c = holderA,
                Transaction_Type__c = 'Issue', Units__c = 500));
            SABEquityWorkspaceController.applyHolding(units, new Equity_Transaction__c(Equity_Class__c = classId, Stakeholder__c = holderA,
                To_Stakeholder__c = holderB, Transaction_Type__c = 'Transfer', Units__c = 200));
            SABEquityWorkspaceController.applyHolding(units, new Equity_Transaction__c(Equity_Class__c = classId, Stakeholder__c = holderB,
                Transaction_Type__c = 'Redemption', Units__c = 50));
            SABEquityWorkspaceController.applyHolding(units, new Equity_Transaction__c(Equity_Class__c = classId, Stakeholder__c = holderB,
                Transaction_Type__c = 'Capital Contribution', Units__c = null));
            Test.stopTest();
            System.assertEquals(300, units.get(classId).get(holderA), 'Issue less transfer out.');
            System.assertEquals(150, units.get(classId).get(holderB), 'Transfer in less redemption.');
            System.assertEquals(Date.newInstance(2025, 7, 1),
                SABEquityWorkspaceController.fiscalYearStart(Date.newInstance(2026, 3, 1), 7), 'Fiscal year spans calendar years.');
            System.assertEquals(Date.newInstance(2026, 1, 1),
                SABEquityWorkspaceController.fiscalYearStart(Date.newInstance(2026, 3, 1), null), 'Defaults to January.');
        }
    }
}