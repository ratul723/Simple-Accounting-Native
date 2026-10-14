@IsTest
private class SABSetupActionServiceTest {

    @TestSetup
    static void setupData() {
        SABAppShellTestFixture.seed();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert as system new PermissionSetAssignment(AssigneeId = SABAppShellTestFixture.fixtureUser().Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'SAB_Manage_Company_Setup_Action' WITH SYSTEM_MODE LIMIT 1].Id);
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static Id companyId() {
        return SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
    }

    @IsTest
    static void periodPatternsProduceContiguousYears() {
        Date first = Date.newInstance(2027, 1, 4);
        List<Date[]> weekly;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            weekly = SABSetupActionService.ranges(first, '4-4-5 weeks');
        }
        System.assertEquals(12, weekly.size(), 'Twelve periods.');
        System.assertEquals(first.addDays(27), weekly[0][1], 'Four weeks.');
        System.assertEquals(first.addDays(363), weekly[11][1], '52 weeks in total.');
        System.assertEquals(13, SABSetupActionService.ranges(first, '13 periods of 4 weeks').size(), 'Thirteen periods.');
        List<Date[]> monthly = SABSetupActionService.ranges(Date.newInstance(2027, 1, 15), 'Monthly');
        System.assertEquals(Date.newInstance(2027, 2, 14), monthly[0][1], 'Mid-month start.');
        System.assertEquals(Date.newInstance(2028, 1, 14), monthly[11][1], 'Year end.');
        for (Integer i = 1; i < weekly.size(); i++) {
            System.assertEquals(weekly[i - 1][1].addDays(1), weekly[i][0], 'No gaps.');
        }
    }

    @IsTest
    static void generatesAFiscalYearAndRejectsOverlaps() {
        Id companyId = companyId();
        Integer count;
        String overlap;
        SABSetupActionService.Options options;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            SABSetupActionService.GenerateRequest request = new SABSetupActionService.GenerateRequest();
            request.companyId = companyId;
            request.firstDay = Date.newInstance(Date.today().year() + 1, 7, 1);
            request.pattern = '5-4-4 weeks';
            count = SABSetupActionService.generatePeriods(request, 'G22RT-GEN');
            try {
                SABSetupActionService.generatePeriods(request, 'G22RT-GEN-2');
            } catch (SABSetupActionService.SetupActionException ex) {
                overlap = ex.getMessage();
            }
            options = SABSetupActionService.getOptions(companyId);
            Test.stopTest();
        }
        System.assertEquals(12, count, 'Twelve periods generated.');
        System.assert(overlap.startsWith('Periods already exist'), overlap);
        Accounting_Period__c first = [SELECT Period_Key__c, Fiscal_Year__c, Fiscal_Quarter__c, End_Date__c FROM Accounting_Period__c
            WHERE Company__c = :companyId AND Period_Number__c = 1 AND Start_Date__c = :Date.newInstance(Date.today().year() + 1, 7, 1) WITH SYSTEM_MODE];
        System.assertEquals(Date.newInstance(Date.today().year() + 1, 7, 1).addDays(34), first.End_Date__c, 'Five weeks first.');
        System.assertEquals(Date.today().year() + 2, first.Fiscal_Year__c, 'Named for the year it ends.');
        System.assert(first.Period_Key__c.endsWith('-P01'), 'Period key.');
        System.assert(options.canManageSetup, 'Setup permission.');
        System.assertEquals(Date.newInstance(Date.today().year() + 1, 7, 1).addDays(364), options.nextPeriodStart, 'Next start follows the last period.');
        System.assertEquals(5, options.patterns.size(), 'Patterns.');
    }

    @IsTest
    static void savesFxAccountsCreatingMissingOnes() {
        Id companyId = companyId();
        String incomplete;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            SABSetupActionService.FxRequest request = new SABSetupActionService.FxRequest();
            request.companyId = companyId;
            try {
                SABSetupActionService.saveFxAccounts(request, 'G22RT-FX-0');
            } catch (SABSetupActionService.SetupActionException ex) {
                incomplete = ex.getMessage();
            }
            request.realizedLossAccountId = [SELECT Id FROM GL_Account__c WHERE Company__c = :companyId AND Account_Code__c = '6000' WITH SYSTEM_MODE].Id;
            request.createMissing = true;
            SABSetupActionService.saveFxAccounts(request, 'G22RT-FX-1');
            Test.stopTest();
        }
        Accounting_Company__c company = [SELECT Unrealized_FX_Gain_Account__r.Account_Code__c, Unrealized_FX_Loss_Account__r.Account_Code__c,
            Realized_FX_Gain_Account__r.Account_Code__c, Realized_FX_Loss_Account__r.Account_Code__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE];
        System.assertEquals('Choose all four FX accounts, or let the app create the missing ones.', incomplete, 'All four are needed.');
        System.assertEquals('4910', company.Unrealized_FX_Gain_Account__r.Account_Code__c, 'Created unrealized gain.');
        System.assertEquals('6910', company.Unrealized_FX_Loss_Account__r.Account_Code__c, 'Created unrealized loss.');
        System.assertEquals('4920', company.Realized_FX_Gain_Account__r.Account_Code__c, 'Created realized gain.');
        System.assertEquals('6000', company.Realized_FX_Loss_Account__r.Account_Code__c, 'Chosen realized loss.');
    }

    @IsTest
    static void savesRegistrationsAndParties() {
        Id companyId = companyId();
        Id registrationId;
        Id supplierId;
        List<String> messages = new List<String>();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert as system new GL_Account__c(Company__c = companyId, Account_Code__c = '2000', Name = 'Payables', Account_Type__c = 'Liability', Normal_Balance__c = 'Credit',
                Control_Type__c = 'AP', Is_Control_Account__c = true, Manual_Posting_Allowed__c = false, Is_Active__c = true,
                Company_Account_Key__c = SABAppShellTestFixture.ACTIVE_KEY + '-2000');
        }
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            SABSetupActionService.RegistrationRequest reg = new SABSetupActionService.RegistrationRequest();
            reg.companyId = companyId;
            reg.name = 'GST';
            reg.jurisdiction = 'AU';
            reg.identifier = '53 004 085 616';
            reg.countryPackVersion = 'AU-2026.1';
            registrationId = SABSetupActionService.saveTaxRegistration(reg, 'G22RT-REG');
            reg.registrationId = registrationId;
            reg.filingFrequency = 'Monthly';
            SABSetupActionService.saveTaxRegistration(reg, 'G22RT-REG-2');
            SABSetupActionService.PartyRequest party = new SABSetupActionService.PartyRequest();
            party.companyId = companyId;
            party.name = 'Fuel Co';
            party.isSupplier = true;
            supplierId = SABSetupActionService.saveParty(party, 'G22RT-PARTY');
            party.isSupplier = false;
            party.isCustomer = true;
            try {
                SABSetupActionService.saveParty(party, 'G22RT-PARTY-2');
            } catch (SABSetupActionService.SetupActionException ex) {
                messages.add(ex.getMessage());
            }
            party.isCustomer = false;
            try {
                SABSetupActionService.saveParty(party, 'G22RT-PARTY-3');
            } catch (SABSetupActionService.SetupActionException ex) {
                messages.add(ex.getMessage());
            }
            try {
                SABSetupActionService.getOptions(null);
            } catch (SABSetupActionService.SetupActionException ex) {
                messages.add(ex.getMessage());
            }
            Test.stopTest();
        }
        System.assertEquals('Monthly', [SELECT Filing_Frequency__c FROM Tax_Registration__c WHERE Id = :registrationId WITH SYSTEM_MODE].Filing_Frequency__c, 'Edited.');
        Party_Accounting_Profile__c profile = [SELECT Is_Supplier__c, AP_Control_Account__r.Account_Code__c, Account__r.Name FROM Party_Accounting_Profile__c
            WHERE Id = :supplierId WITH SYSTEM_MODE];
        System.assert(profile.Is_Supplier__c, 'Supplier.');
        System.assertEquals('2000', profile.AP_Control_Account__r.Account_Code__c, 'AP control.');
        System.assertEquals('Fuel Co', profile.Account__r.Name, 'Account name.');
        System.assertEquals('Add an active accounts receivable control account in Chart of accounts first.', messages[0], 'AR needed.');
        System.assertEquals('Choose customer, supplier or both.', messages[1], 'Type needed.');
        System.assertEquals('You do not have active access to this Accounting Company.', messages[2], 'Company grant.');
    }
}
