@IsTest
private class SABIntegrationLogServiceTest {

    @TestSetup
    static void setupData() {
        SABImportTestFixture.createFixture();
    }

    private static SABIntegrationLogService.RequestLog log(String key) {
        SABIntegrationLogService.RequestLog l = new SABIntegrationLogService.RequestLog();
        l.companyId = SABImportTestFixture.companyId();
        l.direction = 'Outbound';
        l.provider = 'BankFeed';
        l.operation = 'POST /payments';
        l.requestKey = key;
        l.payload = '{"iban":"GB00TEST","amount":100}';
        l.payloadReference = 'ContentVersion/069000000000001';
        return l;
    }

    @IsTest
    static void retriesThenSucceedsAndNeverStoresThePayload() {
        Id requestId;
        Id replayId;
        String afterFirstFailure;
        List<Id> dueNow;
        List<SABIntegrationLogService.LogView> views;
        System.runAs(SABImportTestFixture.user(SABImportTestFixture.IMPORTER)) {
            SABTestGovernor.startTest();
            requestId = SABIntegrationLogService.record(log('I20-OUT-1'));
            replayId = SABIntegrationLogService.record(log('I20-OUT-1'));
            SABIntegrationLogService.markInFlight(requestId);
            afterFirstFailure = SABIntegrationLogService.markFailed(requestId, 'HTTP 503: upstream unavailable', true);
            dueNow = SABIntegrationLogService.dueForRetry(10);
            SABIntegrationLogService.markInFlight(requestId);
            SABIntegrationLogService.markSucceeded(requestId, 'BANK-REF-77');
            views = SABIntegrationLogService.getRequests(SABImportTestFixture.companyId(), 10);
            SABTestGovernor.stopTest();
        }
        System.assertEquals(requestId, replayId, 'The same request key replays.');
        System.assertEquals('Retry', afterFirstFailure, 'Retryable failures retry.');
        System.assertEquals(0, dueNow.size(), 'The retry is scheduled in the future.');
        Integration_Request__c r = [SELECT Attempt_State__c, Attempt_Count__c, Payload_Hash__c, Payload_Reference__c, Response_Reference__c,
            Safe_Error_Code__c FROM Integration_Request__c WHERE Id = :requestId WITH SYSTEM_MODE];
        System.assertEquals('Succeeded', r.Attempt_State__c, 'Succeeded on the second attempt.');
        System.assertEquals(2, r.Attempt_Count__c, 'Two attempts counted.');
        System.assertEquals(64, r.Payload_Hash__c.length(), 'Only a SHA-256 hash of the payload is stored.');
        System.assert(!r.Payload_Hash__c.contains('GB00TEST'), 'The payload itself is never stored.');
        System.assertEquals('BANK-REF-77', r.Response_Reference__c, 'Response reference kept.');
        System.assertEquals(1, views.size(), 'The log shows the request.');
        System.assertEquals('Succeeded', views[0].state, 'Current state.');
    }

    @IsTest
    static void exhaustsRetriesCancelsAndGuardsTheLog() {
        String finalState;
        List<String> messages = new List<String>();
        Boolean outsiderDenied = false;
        Database.SaveResult direct;
        SABTestGovernor.startTest();
        System.runAs(SABImportTestFixture.user(SABImportTestFixture.IMPORTER)) {
            Id failing = SABIntegrationLogService.record(log('I20-OUT-FAIL'));
            for (Integer i = 0; i < SABIntegrationLogService.MAX_ATTEMPTS; i++) {
                SABIntegrationLogService.markInFlight(failing);
                finalState = SABIntegrationLogService.markFailed(failing, 'timeout', true);
            }
            Id cancelled = SABIntegrationLogService.record(log('I20-OUT-CANCEL'));
            SABIntegrationLogService.cancel(cancelled);
            for (Integer i = 0; i < 3; i++) {
                try {
                    if (i == 0) {
                        SABIntegrationLogService.markSucceeded(cancelled, null);
                    } else if (i == 1) {
                        SABIntegrationLogService.record(new SABIntegrationLogService.RequestLog());
                    } else {
                        SABIntegrationLogService.RequestLog sideways = log('I20-SIDEWAYS');
                        sideways.direction = 'Sideways';
                        SABIntegrationLogService.record(sideways);
                    }
                } catch (SABIntegrationLogService.IntegrationLogException ex) {
                    messages.add(ex.getMessage());
                }
            }
            direct = Database.insert(new Integration_Request__c(Provider__c = 'X', Operation__c = 'Y', Request_Key__c = 'I20-DIRECT'), false,
                AccessLevel.SYSTEM_MODE);
        }
        System.runAs(SABImportTestFixture.user(SABImportTestFixture.OUTSIDER)) {
            try {
                SABIntegrationLogService.getRequests(SABImportTestFixture.companyId(), 10);
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                outsiderDenied = true;
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals('Failed', finalState, 'Retries stop after the maximum attempts.');
        List<String> fragments = new List<String>{'Cancelled request cannot move to Succeeded', 'are required', 'Inbound or Outbound'};
        System.assertEquals(fragments.size(), messages.size(), 'Every invalid call was refused: ' + messages);
        for (Integer i = 0; i < fragments.size(); i++) {
            System.assert(messages[i].contains(fragments[i]), 'Expected "' + fragments[i] + '" but got: ' + messages[i]);
        }
        System.assertEquals(false, direct.isSuccess(), 'Integration requests are system records.');
        System.assertEquals(true, outsiderDenied, 'Users without a company grant cannot read the log.');
        System.assertEquals('HTTP_503_UPSTREAM_UNAVAILABLE', SABIntegrationLogService.safeCode('HTTP 503: upstream unavailable'), 'Codes are sanitized.');
        System.assertEquals('UNKNOWN_ERROR', SABIntegrationLogService.safeCode('***'), 'Unusable codes become UNKNOWN_ERROR.');
    }
}
