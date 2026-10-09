/**
 * G18: guard for intercompany transactions, consolidation runs and consolidation adjustments.
 *
 * Outside the G18 services' write scope:
 *  - Intercompany transactions and consolidation adjustments are system records: no direct insert, update or delete.
 *  - Consolidation runs may not be inserted directly; their status, hash and approval stamps change only through
 *    SABConsolidationService, and Published runs cannot be deleted.
 */
public with sharing class SABGroupAccountingGuard {
    private static Integer scopeDepth = 0;

    /** Opened only by SABIntercompanyService and SABConsolidationService around their own writes. */
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
            row.addError(label + ' records are created and maintained only by the group accounting services.');
        }
    }

    public static void guardRuns(List<Consolidation_Run__c> rows, Map<Id, Consolidation_Run__c> oldMap, Boolean isDelete) {
        if (inWriteScope()) {
            return;
        }
        for (Consolidation_Run__c row : rows) {
            Consolidation_Run__c old = oldMap == null ? null : oldMap.get(row.Id);
            String message;
            if (isDelete) {
                message = row.Status__c == 'Published' ? 'Published consolidation runs cannot be deleted.' : null;
            } else if (old == null) {
                message = 'Consolidation runs are created only by the consolidation service.';
            } else if (row.Status__c != old.Status__c || row.Result_Hash__c != old.Result_Hash__c || row.Approved_By__c != old.Approved_By__c
                    || row.Approved_At__c != old.Approved_At__c || row.As_Of_Date__c != old.As_Of_Date__c
                    || row.Consolidation_Group__c != old.Consolidation_Group__c) {
                message = 'Consolidation run status, date, group, hash and approval change only through the consolidation service.';
            }
            if (message != null) {
                row.addError(message);
            }
        }
    }
}
