/**
 * G20: Integration request log (Apex API for inbound and outbound integrations).
 *
 *   record          log a request (Pending), idempotent by request key. Only a SHA-256 hash of the payload is stored,
 *                   never the payload; an optional reference (for example a file id) may point to where it lives.
 *   markInFlight    Pending or Retry -> In Flight; counts the attempt
 *   markSucceeded   In Flight -> Succeeded with an optional response reference
 *   markFailed      In Flight -> Retry (backoff 2^attempt minutes, up to 5 attempts) or Failed; error codes are sanitized
 *   cancel          Pending or Retry -> Cancelled
 *   dueForRetry     Retry requests whose next attempt time has passed (for schedulers)
 *   getRequests     SAB_View_Integration_Log + company grant: recent requests of a company
 */
public with sharing class SABIntegrationLogService {
    public class IntegrationLogException extends Exception {}

    public static final Integer MAX_ATTEMPTS = 5;
    private static final String VIEW = 'SAB_View_Integration_Log';

    public class RequestLog {
        public Id companyId;
        public String direction;
        public String provider;
        public String operation;
        public String requestKey;
        public String payload;
        public String payloadReference;
    }

    public class LogView {
        @AuraEnabled public Id requestId;
        @AuraEnabled public String direction;
        @AuraEnabled public String provider;
        @AuraEnabled public String operation;
        @AuraEnabled public String state;
        @AuraEnabled public Decimal attempts;
        @AuraEnabled public Datetime nextAttemptAt;
        @AuraEnabled public String errorCode;
        @AuraEnabled public String responseReference;
    }

    public static Id record(RequestLog log) {
        if (log == null || String.isBlank(log.provider) || String.isBlank(log.operation) || String.isBlank(log.requestKey)) {
            throw new IntegrationLogException('Provider, operation and request key are required.');
        }
        String direction = String.isBlank(log.direction) ? 'Outbound' : log.direction;
        if (direction != 'Outbound' && direction != 'Inbound') {
            throw new IntegrationLogException('Direction must be Inbound or Outbound.');
        }
        if (log.provider.length() > 80 || log.operation.length() > 80 || log.requestKey.length() > 180
            || (log.payloadReference != null && log.payloadReference.length() > 255)) {
            throw new IntegrationLogException('Provider and operation allow 80 characters, request key 180 and payload reference 255.');
        }
        Store store = new Store();
        Integration_Request__c existing = store.byKey(log.requestKey);
        if (existing != null) {
            return existing.Id;
        }
        Integration_Request__c request = new Integration_Request__c(Company__c = log.companyId, Direction__c = direction, Provider__c = log.provider,
            Operation__c = log.operation, Request_Key__c = log.requestKey, Attempt_State__c = 'Pending', Attempt_Count__c = 0,
            Payload_Hash__c = log.payload == null ? null : EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(log.payload))),
            Payload_Reference__c = log.payloadReference);
        new Writer().save(request);
        return request.Id;
    }

    public static void markInFlight(Id requestId) {
        Integration_Request__c r = new Store().lockRequest(requestId);
        requireState(r, new Set<String>{'Pending', 'Retry'}, 'In Flight');
        new Writer().save(new Integration_Request__c(Id = r.Id, Attempt_State__c = 'In Flight',
            Attempt_Count__c = (r.Attempt_Count__c == null ? 0 : r.Attempt_Count__c) + 1, Next_Attempt_At__c = null));
    }

    public static void markSucceeded(Id requestId, String responseReference) {
        Integration_Request__c r = new Store().lockRequest(requestId);
        requireState(r, new Set<String>{'In Flight'}, 'Succeeded');
        new Writer().save(new Integration_Request__c(Id = r.Id, Attempt_State__c = 'Succeeded', Safe_Error_Code__c = null,
            Response_Reference__c = responseReference == null ? null : responseReference.left(255)));
    }

    /** Returns the new state: Retry while attempts remain and the error is retryable, otherwise Failed. */
    public static String markFailed(Id requestId, String errorCode, Boolean retryable) {
        Integration_Request__c r = new Store().lockRequest(requestId);
        requireState(r, new Set<String>{'In Flight'}, 'Retry or Failed');
        Integer attempts = r.Attempt_Count__c == null ? 1 : r.Attempt_Count__c.intValue();
        Boolean retry = retryable == true && attempts < MAX_ATTEMPTS;
        Integer backoffMinutes = 1;
        for (Integer i = 0; i < attempts; i++) {
            backoffMinutes *= 2;
        }
        new Writer().save(new Integration_Request__c(Id = r.Id, Attempt_State__c = retry ? 'Retry' : 'Failed', Safe_Error_Code__c = safeCode(errorCode),
            Next_Attempt_At__c = retry ? System.now().addMinutes(backoffMinutes) : null));
        return retry ? 'Retry' : 'Failed';
    }

    public static void cancel(Id requestId) {
        Integration_Request__c r = new Store().lockRequest(requestId);
        requireState(r, new Set<String>{'Pending', 'Retry'}, 'Cancelled');
        new Writer().save(new Integration_Request__c(Id = r.Id, Attempt_State__c = 'Cancelled', Next_Attempt_At__c = null));
    }

    public static List<Id> dueForRetry(Integer maxRows) {
        List<Id> ids = new List<Id>();
        for (Integration_Request__c r : new Store().due(maxRows == null || maxRows <= 0 ? 200 : Math.min(maxRows, 2000))) {
            ids.add(r.Id);
        }
        return ids;
    }

    @AuraEnabled
    public static List<LogView> getRequests(Id companyId, Integer maxRows) {
        SABPermissionService.assertPermission(VIEW, 'Integration log permission is required.');
        if (companyId == null) {
            throw new IntegrationLogException('Company is required.');
        }
        SABCompanyAccessService.assertCompanyAccess(companyId);
        List<LogView> views = new List<LogView>();
        for (Integration_Request__c r : new Store().forCompany(companyId, maxRows == null || maxRows <= 0 ? 100 : Math.min(maxRows, 500))) {
            LogView v = new LogView();
            v.requestId = r.Id;
            v.direction = r.Direction__c;
            v.provider = r.Provider__c;
            v.operation = r.Operation__c;
            v.state = r.Attempt_State__c;
            v.attempts = r.Attempt_Count__c;
            v.nextAttemptAt = r.Next_Attempt_At__c;
            v.errorCode = r.Safe_Error_Code__c;
            v.responseReference = r.Response_Reference__c;
            views.add(v);
        }
        return views;
    }

    /** Error codes are reduced to upper-case letters, digits and underscores so no message text or data leaks into the log. */
    @TestVisible
    private static String safeCode(String errorCode) {
        String cleaned = errorCode == null ? '' : errorCode.toUpperCase().replaceAll('[^A-Z0-9_]', '_').replaceAll('_+', '_');
        cleaned = cleaned.removeStart('_').removeEnd('_');
        return String.isBlank(cleaned) ? 'UNKNOWN_ERROR' : cleaned.left(80);
    }

    private static void requireState(Integration_Request__c r, Set<String> allowed, String target) {
        if (!allowed.contains(r.Attempt_State__c)) {
            throw new IntegrationLogException('A ' + r.Attempt_State__c + ' request cannot move to ' + target + '.');
        }
    }

    /** System reads: the log is written by trusted integration code; user reads go through getRequests' checks. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Integration_Request__c byKey(String key) {
            List<Integration_Request__c> rows = [SELECT Id FROM Integration_Request__c WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        Integration_Request__c lockRequest(Id requestId) {
            List<Integration_Request__c> rows = [SELECT Id, Attempt_State__c, Attempt_Count__c FROM Integration_Request__c WHERE Id = :requestId
                WITH SYSTEM_MODE FOR UPDATE];
            if (rows.isEmpty()) {
                throw new IntegrationLogException('Integration request not found.');
            }
            return rows[0];
        }
        List<Integration_Request__c> due(Integer maxRows) {
            Datetime now = System.now();
            return [SELECT Id FROM Integration_Request__c WHERE Attempt_State__c = 'Retry' AND Next_Attempt_At__c <= :now WITH SYSTEM_MODE
                ORDER BY Next_Attempt_At__c LIMIT :maxRows];
        }
        List<Integration_Request__c> forCompany(Id companyId, Integer maxRows) {
            return [SELECT Id, Direction__c, Provider__c, Operation__c, Attempt_State__c, Attempt_Count__c, Next_Attempt_At__c, Safe_Error_Code__c,
                Response_Reference__c FROM Integration_Request__c WHERE Company__c = :companyId WITH SYSTEM_MODE ORDER BY CreatedDate DESC
                LIMIT :maxRows];
        }
    }

    /** System writes inside the G20 guard scope (explicit system mode). */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void save(Integration_Request__c request) {
            SABImportGuard.beginWrite();
            try {
                if (request.Id == null) {
                    insert as system request;
                } else {
                    update as system request;
                }
            } finally {
                SABImportGuard.endWrite();
            }
        }
    }
}
