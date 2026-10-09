/**
 * G19: guard for approval requests, approval steps and close tasks.
 *
 * Outside the G19 services' write scope:
 *  - Approval requests and steps are system records: no direct insert, update or delete.
 *  - Close tasks are created only by checklist generation; their status, completion stamps, keys, evidence and blocked
 *    reason change only through SABCloseTaskService, and completed tasks cannot be deleted. Name, due date and
 *    assignee may be edited on the record.
 */
public with sharing class SABApprovalCloseGuard {
    private static Integer scopeDepth = 0;

    /** Opened only by SABApprovalService and SABCloseTaskService around their own writes. */
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
            row.addError(label + ' records are created and maintained only by the approval service.');
        }
    }

    public static void guardCloseTasks(List<Close_Task__c> rows, Map<Id, Close_Task__c> oldMap, Boolean isDelete) {
        if (inWriteScope()) {
            return;
        }
        for (Close_Task__c row : rows) {
            Close_Task__c old = oldMap == null ? null : oldMap.get(row.Id);
            String message;
            if (isDelete) {
                message = row.Status__c == 'Complete' ? 'Completed close tasks cannot be deleted.' : null;
            } else if (old == null) {
                message = 'Close tasks are created by generating the period checklist.';
            } else if (row.Status__c != old.Status__c || row.Completed_By__c != old.Completed_By__c || row.Completed_At__c != old.Completed_At__c
                    || row.Task_Key__c != old.Task_Key__c || row.Close_Task_Key__c != old.Close_Task_Key__c
                    || row.Evidence_Reference__c != old.Evidence_Reference__c || row.Blocked_Reason__c != old.Blocked_Reason__c
                    || row.Accounting_Period__c != old.Accounting_Period__c || row.Company__c != old.Company__c
                    || row.Evidence_Required__c != old.Evidence_Required__c) {
                message = 'Close task status, evidence, keys and period change only through the close task service.';
            }
            if (message != null) {
                row.addError(message);
            }
        }
    }
}
