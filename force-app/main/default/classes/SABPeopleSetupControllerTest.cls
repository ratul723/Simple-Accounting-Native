@IsTest
private class SABPeopleSetupControllerTest {

    @TestSetup
    static void setupData() {
        SABAppShellTestFixture.seed();
        SABTestGovernor.assertSetupWithin(50);
    }

    @IsTest
    static void optionsListComponentsAndAccounts() {
        Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
        Id expenseId = [SELECT Id FROM GL_Account__c WHERE Company__c = :companyId AND Account_Code__c = '6000' WITH SYSTEM_MODE].Id;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert as system new Pay_Component__c(Name = 'Basic salary', Company__c = companyId, Component_Key__c = 'BASIC', Category__c = 'Basic Salary',
                Expense_Account__c = expenseId, Is_Active__c = true);
        }
        SABPeopleSetupController.Options options;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            options = SABPeopleSetupController.getOptions(companyId);
            Test.stopTest();
        }
        System.assertEquals(1, options.payComponents.size(), 'One pay component.');
        System.assertEquals('Basic Salary', options.payComponents[0].detail, 'Category.');
        System.assertEquals(1, options.expenseAccounts.size(), 'Expense accounts.');
        System.assertEquals('AUD', options.currencyCode, 'Currency.');
        System.assert(!options.categories.isEmpty(), 'Categories.');
        System.assertNotEquals(null, options.canManage, 'Permission flags.');
    }

    @IsTest
    static void companyAccessIsRequired() {
        String message;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            try {
                SABPeopleSetupController.getOptions(null);
            } catch (AuraHandledException ex) {
                message = ex.getMessage();
            }
            Test.stopTest();
        }
        System.assertEquals('You do not have active access to this Accounting Company.', message, 'Grant required.');
    }
}
