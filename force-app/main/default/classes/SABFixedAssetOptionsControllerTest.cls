@IsTest
private class SABFixedAssetOptionsControllerTest {

    @TestSetup
    static void setupData() {
        SABAppShellTestFixture.seed();
        SABTestGovernor.assertSetupWithin(50);
    }

    @IsTest
    static void optionsListCategoriesAndBanks() {
        Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
        List<GL_Account__c> accounts = [SELECT Id FROM GL_Account__c WHERE Company__c = :companyId WITH SYSTEM_MODE ORDER BY Account_Code__c LIMIT 3];
        insert as system new Asset_Category__c(Name = 'Equipment', Company__c = companyId, Category_Key__c = 'G22G6-EQUIP', Asset_Account__c = accounts[0].Id,
            Accumulated_Depreciation_Account__c = accounts[1].Id, Depreciation_Expense_Account__c = accounts[2].Id,
            Disposal_Gain_Loss_Account__c = accounts[2].Id, Default_Useful_Life_Months__c = 60, Allowed_Methods__c = 'Straight Line', Is_Active__c = true);
        SABFixedAssetOptionsController.Options options;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            options = SABFixedAssetOptionsController.getOptions(companyId);
            Test.stopTest();
        }
        System.assertEquals(1, options.categories.size(), 'One category.');
        System.assertEquals(60, options.categories[0].defaultLifeMonths, 'Default life.');
        System.assertEquals('Straight Line', options.categories[0].allowedMethods, 'Allowed methods.');
        System.assertEquals(1, options.bankAccounts.size(), 'The fixture bank account.');
        System.assertNotEquals(null, options.departments, 'Departments list.');
        System.assertNotEquals(null, options.costCenters, 'Cost centers list.');
        System.assertNotEquals(null, options.canRegister, 'Permission flags are returned.');
    }

    @IsTest
    static void companyAccessIsRequired() {
        String message;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            try {
                SABFixedAssetOptionsController.getOptions(null);
            } catch (AuraHandledException ex) {
                message = ex.getMessage();
            }
            Test.stopTest();
        }
        System.assertEquals('You do not have active access to this Accounting Company.', message, 'A grant is required.');
    }
}