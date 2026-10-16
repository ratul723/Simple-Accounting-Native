@IsTest
private class SABReportMappingServiceTest {

    @TestSetup
    static void setupData() {
        SABAppShellTestFixture.seed();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert as system new PermissionSetAssignment(AssigneeId = SABAppShellTestFixture.fixtureUser().Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'SAB_Manage_Company_Setup_Action' WITH SYSTEM_MODE LIMIT 1].Id);
            Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
            Report_Definition__c bs = new Report_Definition__c(Company__c = companyId, Definition_Key__c = 'RMS-BS-1', Report_Type__c = 'Balance Sheet', Version__c = 1,
                Status__c = 'Active', Effective_From__c = Date.newInstance(2026, 1, 1));
            Report_Definition__c pl = new Report_Definition__c(Company__c = companyId, Definition_Key__c = 'RMS-PL-1', Report_Type__c = 'P&L', Version__c = 1,
                Status__c = 'Active', Effective_From__c = Date.newInstance(2026, 1, 1));
            insert as system new List<Report_Definition__c>{ bs, pl };
            Id cash = [SELECT Id FROM GL_Account__c WHERE Company__c = :companyId AND Account_Code__c = '1000' WITH SYSTEM_MODE].Id;
            insert as system new Report_Mapping__c(Report_Definition__c = bs.Id, GL_Account__c = cash, Group_Key__c = 'ASSETS', Row_Key__c = 'CASH',
                Display_Order__c = 10, Sign_Multiplier__c = 1, Effective_From__c = bs.Effective_From__c);
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static Id companyId() {
        return SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
    }

    private static SABSetupRecordService.AccountRequest account(String code, String name, String type, String balance) {
        SABSetupRecordService.AccountRequest r = new SABSetupRecordService.AccountRequest();
        r.companyId = companyId();
        r.code = code;
        r.name = name;
        r.accountType = type;
        r.normalBalance = balance;
        r.controlType = 'None';
        r.isActive = true;
        r.manualPostingAllowed = true;
        return r;
    }

    private static SABReportMappingService.MappingChoice choice(String groupKey, String rowKey) {
        SABReportMappingService.MappingChoice c = new SABReportMappingService.MappingChoice();
        c.groupKey = groupKey;
        c.rowKey = rowKey;
        return c;
    }

    @IsTest
    static void newAccountsMustChooseARowAndAreMappedOnSave() {
        String missing;
        Id assetId;
        Id loanId;
        SABReportMappingService.Options options;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            try {
                SABReportMappingService.saveAccountWithMapping(account('1100', 'Receivables', 'Asset', 'Debit'), null, 'RMS-A0');
            } catch (SABReportMappingService.ReportMappingException ex) {
                missing = ex.getMessage();
            }
            assetId = SABReportMappingService.saveAccountWithMapping(account('1100', 'Receivables', 'Asset', 'Debit'), choice(null, 'CASH'), 'RMS-A1');
            loanId = SABReportMappingService.saveAccountWithMapping(account('2500', 'Bank loan', 'Liability', 'Credit'), choice('Liabilities', 'Bank loans'), 'RMS-A2');
            options = SABReportMappingService.getOptions(companyId());
            Test.stopTest();
        }
        System.assertEquals('Choose where this account appears on the Balance Sheet / P&L.', missing, 'A row is required.');
        Report_Mapping__c asset = [SELECT Group_Key__c, Row_Key__c, Sign_Multiplier__c, Effective_From__c FROM Report_Mapping__c WHERE GL_Account__c = :assetId WITH SYSTEM_MODE];
        System.assertEquals('ASSETS', asset.Group_Key__c, 'Section from the existing row.');
        System.assertEquals(1, asset.Sign_Multiplier__c, 'Debit accounts carry +1.');
        System.assertEquals(Date.newInstance(2026, 1, 1), asset.Effective_From__c, 'Effective from the definition start.');
        Report_Mapping__c loan = [SELECT Group_Key__c, Row_Key__c, Sign_Multiplier__c FROM Report_Mapping__c WHERE GL_Account__c = :loanId WITH SYSTEM_MODE];
        System.assertEquals('BANK_LOANS', loan.Row_Key__c, 'A new row is keyed from its name.');
        System.assertEquals('LIABILITIES', loan.Group_Key__c, 'New row section.');
        System.assertEquals(-1, loan.Sign_Multiplier__c, 'Credit accounts carry -1.');
        System.assertEquals(2, options.definitions.size(), 'Both active definitions.');
        System.assertEquals(3, options.mappings.size(), 'Three mappings.');
        System.assert(options.canManage, 'Setup permission.');
        System.assertEquals(0, options.unmapped.size(), 'No posted accounts without a mapping.');
    }

    @IsTest
    static void accountsMoveBetweenRowsAndDefinitionsAreVersioned() {
        Id companyId = companyId();
        Id cash = [SELECT Id FROM GL_Account__c WHERE Company__c = :companyId AND Account_Code__c = '1000' WITH SYSTEM_MODE].Id;
        Id sales = [SELECT Id FROM GL_Account__c WHERE Company__c = :companyId AND Account_Code__c = '4000' WITH SYSTEM_MODE].Id;
        Id bsId = [SELECT Id FROM Report_Definition__c WHERE Definition_Key__c = 'RMS-BS-1' WITH SYSTEM_MODE].Id;
        String wrongStatement;
        Id versionId;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            SABReportMappingService.MappingChoice toBank = choice('ASSETS', 'Bank');
            toBank.definitionId = bsId;
            SABReportMappingService.moveAccount(companyId, cash, toBank, 'RMS-M1');
            try {
                SABReportMappingService.moveAccount(companyId, sales, toBank, 'RMS-M2');
            } catch (SABReportMappingService.ReportMappingException ex) {
                wrongStatement = ex.getMessage();
            }
            versionId = SABReportMappingService.createVersion(companyId, bsId, 'RMS-V2');
            SABReportMappingService.activateVersion(companyId, versionId, 'RMS-ACT');
            Test.stopTest();
        }
        System.assertEquals('BANK', [SELECT Row_Key__c FROM Report_Mapping__c WHERE GL_Account__c = :cash AND Report_Definition__c = :bsId WITH SYSTEM_MODE].Row_Key__c,
            'Moved to the new row.');
        System.assert(wrongStatement.contains('belong on the P&L'), wrongStatement);
        Report_Definition__c v2 = [SELECT Version__c, Status__c FROM Report_Definition__c WHERE Id = :versionId WITH SYSTEM_MODE];
        System.assertEquals(2, v2.Version__c, 'Next version.');
        System.assertEquals('Active', v2.Status__c, 'Activated.');
        System.assertEquals('Retired', [SELECT Status__c FROM Report_Definition__c WHERE Id = :bsId WITH SYSTEM_MODE].Status__c, 'Previous version retired.');
        System.assertEquals(1, [SELECT COUNT() FROM Report_Mapping__c WHERE Report_Definition__c = :versionId WITH SYSTEM_MODE], 'Mappings copied.');
    }

    @IsTest
    static void onlyDraftVersionsCanBeDeleted() {
        Id companyId = companyId();
        Id bsId = [SELECT Id FROM Report_Definition__c WHERE Definition_Key__c = 'RMS-BS-1' WITH SYSTEM_MODE].Id;
        String activeRefused;
        Id draftId;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            draftId = SABReportMappingService.createVersion(companyId, bsId, 'RMS-DV');
            try {
                SABReportMappingService.deleteDraftVersion(companyId, bsId, 'RMS-DEL-1');
            } catch (SABReportMappingService.ReportMappingException ex) {
                activeRefused = ex.getMessage();
            }
            SABReportMappingService.deleteDraftVersion(companyId, draftId, 'RMS-DEL-2');
            SABReportMappingService.deleteDraftVersion(companyId, draftId, 'RMS-DEL-2');
            Test.stopTest();
        }
        System.assert(activeRefused.startsWith('Only a Draft version can be deleted.'), activeRefused);
        System.assertEquals(0, [SELECT COUNT() FROM Report_Definition__c WHERE Id = :draftId WITH SYSTEM_MODE], 'Draft deleted.');
        System.assertEquals(0, [SELECT COUNT() FROM Report_Mapping__c WHERE Report_Definition__c = :draftId WITH SYSTEM_MODE], 'Its mappings deleted.');
        System.assertEquals(1, [SELECT COUNT() FROM Report_Definition__c WHERE Id = :bsId WITH SYSTEM_MODE], 'Active version kept.');
    }

    @IsTest
    static void permissionAndCompanyAreChecked() {
        List<String> messages = new List<String>();
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            try {
                SABReportMappingService.getOptions(null);
            } catch (SABReportMappingService.ReportMappingException ex) {
                messages.add(ex.getMessage());
            }
            try {
                SABReportMappingService.moveAccount(companyId(), null, null, 'RMS-X');
            } catch (SABReportMappingService.ReportMappingException ex) {
                messages.add(ex.getMessage());
            }
            Test.stopTest();
        }
        System.assertEquals('You do not have active access to this Accounting Company.', messages[0], 'Grant required.');
        System.assertEquals('Choose an account and a statement row.', messages[1], 'Row required.');
    }
}
