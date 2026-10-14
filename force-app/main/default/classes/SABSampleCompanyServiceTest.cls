@IsTest
private class SABSampleCompanyServiceTest {

    private static final String LOADER = 'SAB G22H Loader';
    private static final String VIEWER = 'SAB G22H Viewer';

    @TestSetup
    static void setupData() {
        SABAppShellTestFixture.createUser('g22hld', LOADER, new List<String>{ 'SAB_App_User', 'SAB_Create_Accounting_Company_Action' });
        SABAppShellTestFixture.createUser('g22hvw', VIEWER, new List<String>{ 'SAB_App_User' });
        SABTestGovernor.assertSetupWithin(50);
    }

    private static User user(String lastName) {
        return [SELECT Id FROM User WHERE LastName = :lastName WITH SYSTEM_MODE LIMIT 1];
    }

    @IsTest
    static void startCreatesACompleteSampleCompany() {
        SABSampleCompanyService.StartResult result;
        SABSampleCompanyService.StartResult replay;
        SABSampleCompanyService.StatusView status;
        System.runAs(user(LOADER)) {
            Test.startTest();
            result = SABSampleCompanyService.startSampleCompany('G22H-SAMPLE-1');
            replay = SABSampleCompanyService.startSampleCompany('G22H-SAMPLE-1');
            status = SABSampleCompanyService.getStatus(result.runId);
            Test.stopTest();
        }
        Id companyId = result.companyId;
        System.assertEquals(companyId, replay.companyId, 'The same request key returns the same company.');
        System.assert(result.companyName.startsWith('Harbourline Trading (sample'), 'Sample name.');
        System.assertEquals('Active', [SELECT Setup_Status__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE].Setup_Status__c, 'Ready to post.');
        System.assertEquals(1, [SELECT COUNT() FROM Company_User_Access__c WHERE Company__c = :companyId AND User__c = :user(LOADER).Id WITH SYSTEM_MODE], 'Owner grant.');
        System.assertEquals(24, [SELECT COUNT() FROM Accounting_Period__c WHERE Company__c = :companyId WITH SYSTEM_MODE], 'Two years of periods.');
        System.assertEquals(18, [SELECT COUNT() FROM GL_Account__c WHERE Company__c = :companyId WITH SYSTEM_MODE], 'Chart of accounts.');
        System.assertEquals(6, [SELECT COUNT() FROM Party_Accounting_Profile__c WHERE Company__c = :companyId WITH SYSTEM_MODE], 'Customers and suppliers.');
        System.assertEquals(2, [SELECT COUNT() FROM Report_Definition__c WHERE Company__c = :companyId WITH SYSTEM_MODE], 'Statement definitions.');
        System.assertEquals(18, [SELECT COUNT() FROM Report_Mapping__c WHERE Report_Definition__r.Company__c = :companyId WITH SYSTEM_MODE], 'Every account mapped.');
        System.assertEquals('Queued', status.status, 'Steps queue after setup.');
        System.assertEquals(0, status.stepsDone, 'No steps yet.');
        System.assertEquals(SABSampleCompanyService.STEPS.size(), status.stepsTotal, 'Step count.');
    }

    @IsTest
    static void stepsRecordProgressAndFailures() {
        SABSampleCompanyService.StartResult result;
        Boolean more;
        SABSampleCompanyService.StatusView status;
        System.runAs(user(LOADER)) {
            result = SABSampleCompanyService.startSampleCompany('G22H-SAMPLE-2');
            Test.startTest();
            more = SABSampleCompanyService.runStep(result.runId, 0);
            Test.stopTest();
            status = SABSampleCompanyService.getStatus(result.runId);
        }
        System.assert(more, 'More steps follow the opening balances.');
        System.assertEquals(1, status.stepsDone, 'One step recorded.');
        System.assertEquals('Running', status.status, 'Still running.');
        System.assert(status.lastMessage.startsWith('Opening balances'), 'The step is named in the message.');
    }

    @IsTest
    static void lastStepCompletesTheRunThroughTheJob() {
        SABSampleCompanyService.StartResult result;
        SABSampleCompanyService.StatusView status;
        System.runAs(user(LOADER)) {
            result = SABSampleCompanyService.startSampleCompany('G22H-SAMPLE-3');
            Test.startTest();
            System.enqueueJob(new SABSampleCompanyJob(result.runId, SABSampleCompanyService.STEPS.size() - 1));
            Test.stopTest();
            status = SABSampleCompanyService.getStatus(result.runId);
        }
        System.assertEquals(1, status.stepsDone, 'The last step ran.');
        System.assert(status.status == 'Complete' || status.status == 'Failed', 'The run is finished.');
        System.assert(status.lastMessage.startsWith('Work to do'), 'Last step message.');
    }

    @IsTest
    static void permissionAndInputAreChecked() {
        List<String> messages = new List<String>();
        Id runId;
        System.runAs(user(LOADER)) {
            runId = SABSampleCompanyService.startSampleCompany('G22H-SAMPLE-4').runId;
            try {
                SABSampleCompanyService.startSampleCompany('');
            } catch (AuraHandledException ex) {
                messages.add(ex.getMessage());
            }
            try {
                SABSampleCompanyService.getStatus(null);
            } catch (AuraHandledException ex) {
                messages.add(ex.getMessage());
            }
        }
        System.runAs(user(VIEWER)) {
            Test.startTest();
            try {
                SABSampleCompanyService.startSampleCompany('G22H-SAMPLE-5');
            } catch (AuraHandledException ex) {
                messages.add(ex.getMessage());
            }
            try {
                SABSampleCompanyService.getStatus(runId);
            } catch (AuraHandledException ex) {
                messages.add(ex.getMessage());
            }
            Test.stopTest();
        }
        System.assertEquals('A request key of up to 160 characters is required.', messages[0], 'Request key.');
        System.assertEquals('A sample load is required.', messages[1], 'Run id.');
        System.assertEquals('You do not have permission to create Accounting Companies.', messages[2], 'Create permission.');
        System.assertEquals('The sample load was not found.', messages[3], 'Only the starter can follow the load.');
    }
}
