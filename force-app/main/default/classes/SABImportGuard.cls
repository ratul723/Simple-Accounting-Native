/**
 * G20: guard for import jobs, import rows and integration requests.
 *
 * Outside the G20 services' write scope:
 *  - Import rows and integration requests are system records: no direct insert, update or delete.
 *  - Import jobs are created only by staging; their status, counts, hash and type change only through SABImportService,
 *    and committed jobs cannot be deleted.
 */
public with sharing class SABImportGuard {
    private static Integer scopeDepth = 0;

    /** Opened only by SABImportService and SABIntegrationLogService around their own writes. */
    public static void beginWrite() {
        scopeDepth++;
    }

    public static void endWrite() {
        scopeDepth = scopeDepth > 0 ? scopeDepth - 1 : 0;
    }

    public static Boolean inWriteScope() {
        return scopeDepth > 0;
    }

    public static void guardSystemRecords(List<SObject> rows, String label) {
        if (inWriteScope()) {
            return;
        }
        for (SObject row : rows) {
            row.addError(label + ' records are created and maintained only by the import and integration services.');
        }
    }

    public static void guardJobs(List<Import_Job__c> rows, Map<Id, Import_Job__c> oldMap, Boolean isDelete) {
        if (inWriteScope()) {
            return;
        }
        for (Import_Job__c row : rows) {
            Import_Job__c old = oldMap == null ? null : oldMap.get(row.Id);
            String message;
            if (isDelete) {
                message = row.Status__c == 'Committed' || row.Status__c == 'Part Failed' ? 'Committed import jobs cannot be deleted.' : null;
            } else if (old == null) {
                message = 'Import jobs are created by staging a file through the import service.';
            } else if (row.Status__c != old.Status__c || row.File_Hash__c != old.File_Hash__c || row.Import_Type__c != old.Import_Type__c
                    || row.Row_Count__c != old.Row_Count__c || row.Valid_Row_Count__c != old.Valid_Row_Count__c
                    || row.Error_Row_Count__c != old.Error_Row_Count__c || row.Company__c != old.Company__c) {
                message = 'Import job status, counts, hash, type and company change only through the import service.';
            }
            if (message != null) {
                row.addError(message);
            }
        }
    }
}
