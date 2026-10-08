/**
 * G14: guard for allocation rules, rule lines and allocation runs.
 *
 * Outside the allocation services' write scope:
 *  - Rules may be inserted only as Draft (a blank status becomes Draft), edited only while Draft without touching status,
 *    version, key, company or approval stamps, and deleted only while Draft. Rule lines change only while the rule is Draft.
 *  - Runs are created, approved, posted and discarded only by SABAllocationRunService; they are never deleted.
 */
public with sharing class SABAllocationGuard {
    private static final String DRAFT = 'Draft';
    private static Integer scopeDepth = 0;

    /** Opened only by SABAllocationRuleService and SABAllocationRunService around their own writes. */
    public static void beginWrite() {
        scopeDepth++;
    }

    public static void endWrite() {
        scopeDepth = scopeDepth > 0 ? scopeDepth - 1 : 0;
    }

    public static Boolean inWriteScope() {
        return scopeDepth > 0;
    }

    public static void guardRules(List<Allocation_Rule__c> rows, Map<Id, Allocation_Rule__c> oldMap, Boolean isDelete) {
        if (!isDelete && oldMap == null) {
            for (Allocation_Rule__c row : rows) {
                row.Status__c = row.Status__c == null ? DRAFT : row.Status__c;
            }
        }
        if (inWriteScope()) {
            return;
        }
        for (Allocation_Rule__c row : rows) {
            Allocation_Rule__c old = oldMap == null ? null : oldMap.get(row.Id);
            String message;
            if (isDelete) {
                message = row.Status__c == DRAFT ? null : 'Only Draft allocation rules can be deleted.';
            } else if (old == null) {
                message = row.Status__c != DRAFT || row.Approved_By__c != null
                    ? 'Allocation rules start as Draft; approve them through the allocation rule service.' : null;
            } else if (old.Status__c != DRAFT) {
                message = 'Only Draft allocation rules can be edited; revise an approved rule through the allocation rule service.';
            } else if (row.Status__c != old.Status__c || row.Version__c != old.Version__c || row.Rule_Key__c != old.Rule_Key__c
                    || row.Company__c != old.Company__c || row.Approved_By__c != old.Approved_By__c || row.Approved_At__c != old.Approved_At__c) {
                message = 'Allocation rule status, version, key, company and approval fields change only through the allocation rule service.';
            }
            if (message != null) {
                row.addError(message);
            }
        }
    }

    public static void guardRuleLines(List<Allocation_Rule_Line__c> rows) {
        if (inWriteScope()) {
            return;
        }
        Set<Id> ruleIds = new Set<Id>();
        for (Allocation_Rule_Line__c row : rows) {
            ruleIds.add(row.Allocation_Rule__c);
        }
        Map<Id, String> statuses = new Store().ruleStatuses(ruleIds);
        for (Allocation_Rule_Line__c row : rows) {
            if (statuses.get(row.Allocation_Rule__c) != DRAFT) {
                row.addError('Allocation rule lines can change only while the rule is Draft.');
            }
        }
    }

    public static void guardRuns(List<Allocation_Run__c> rows) {
        if (inWriteScope()) {
            return;
        }
        for (Allocation_Run__c row : rows) {
            row.addError('Allocation runs are created, approved, posted and discarded only by the allocation run service.');
        }
    }

    // Parent statuses are read completely, whatever the running user's sharing, so the guard cannot be bypassed.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Map<Id, String> ruleStatuses(Set<Id> ids) {
            Map<Id, String> result = new Map<Id, String>();
            for (Allocation_Rule__c row : [SELECT Id, Status__c FROM Allocation_Rule__c WHERE Id IN :ids WITH SYSTEM_MODE]) {
                result.put(row.Id, row.Status__c);
            }
            return result;
        }
    }
}
