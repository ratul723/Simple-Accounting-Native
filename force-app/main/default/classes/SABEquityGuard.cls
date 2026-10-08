/**
 * G17: guard for equity transactions, distributions, distribution lines and settlements, and distribution payments.
 *
 * Outside the G17 services' write scope:
 *  - Equity transactions and distributions may be inserted only as Draft (a blank status becomes Draft), edited only
 *    while Draft without touching status, approval stamps, journal links or the ownership snapshot, and deleted only while Draft.
 *  - Distribution lines and settlements are system records: no direct insert, update or delete.
 *  - Payments tagged with a distribution (Accounting_Payment__c.Distribution__c) change only through SABDistributionService,
 *    and the tag can never be set or removed directly.
 */
public with sharing class SABEquityGuard {
    private static Integer scopeDepth = 0;

    /** Opened only by SABEquityService and SABDistributionService around their own writes. */
    public static void beginWrite() {
        scopeDepth++;
    }

    public static void endWrite() {
        scopeDepth = scopeDepth > 0 ? scopeDepth - 1 : 0;
    }

    public static Boolean inWriteScope() {
        return scopeDepth > 0;
    }

    public static void guardTransactions(List<Equity_Transaction__c> rows, Map<Id, Equity_Transaction__c> oldMap, Boolean isDelete) {
        if (!isDelete && oldMap == null) {
            for (Equity_Transaction__c row : rows) {
                row.Status__c = row.Status__c == null ? 'Draft' : row.Status__c;
            }
        }
        if (inWriteScope()) {
            return;
        }
        for (Equity_Transaction__c row : rows) {
            Equity_Transaction__c old = oldMap == null ? null : oldMap.get(row.Id);
            String message = lifecycleMessage(isDelete, row.Status__c, old == null ? null : old.Status__c,
                old != null && (row.Approved_By__c != old.Approved_By__c || row.Approved_At__c != old.Approved_At__c
                    || row.Journal_Entry__c != old.Journal_Entry__c || row.Accounting_Event__c != old.Accounting_Event__c),
                old == null && (row.Approved_By__c != null || row.Journal_Entry__c != null), 'equity transactions');
            if (message != null) {
                row.addError(message);
            }
        }
    }

    public static void guardDistributions(List<Distribution__c> rows, Map<Id, Distribution__c> oldMap, Boolean isDelete) {
        if (!isDelete && oldMap == null) {
            for (Distribution__c row : rows) {
                row.Status__c = row.Status__c == null ? 'Draft' : row.Status__c;
            }
        }
        if (inWriteScope()) {
            return;
        }
        for (Distribution__c row : rows) {
            Distribution__c old = oldMap == null ? null : oldMap.get(row.Id);
            String message = lifecycleMessage(isDelete, row.Status__c, old == null ? null : old.Status__c,
                old != null && (row.Approved_By__c != old.Approved_By__c || row.Approved_At__c != old.Approved_At__c
                    || row.Journal_Entry__c != old.Journal_Entry__c || row.Ownership_Snapshot_Hash__c != old.Ownership_Snapshot_Hash__c),
                old == null && (row.Approved_By__c != null || row.Journal_Entry__c != null || row.Ownership_Snapshot_Hash__c != null),
                'distributions');
            if (message != null) {
                row.addError(message);
            }
        }
    }

    public static void guardSystemRecords(List<SObject> rows, String label) {
        if (inWriteScope()) {
            return;
        }
        for (SObject row : rows) {
            row.addError(label + ' records are created and maintained only by the distribution service.');
        }
    }

    public static void guardPayments(List<Accounting_Payment__c> rows, Map<Id, Accounting_Payment__c> oldMap, Boolean isDelete) {
        if (inWriteScope()) {
            return;
        }
        for (Accounting_Payment__c row : rows) {
            Accounting_Payment__c old = oldMap == null ? null : oldMap.get(row.Id);
            if (row.Distribution__c != null || (old != null && old.Distribution__c != null)) {
                row.addError('Distribution payments are processed only through distribution settlement.');
            }
        }
    }

    private static String lifecycleMessage(Boolean isDelete, String status, String oldStatus, Boolean stampsChanged, Boolean stampsOnInsert,
            String label) {
        if (isDelete) {
            return status == 'Draft' ? null : 'Only Draft ' + label + ' can be deleted.';
        }
        if (oldStatus == null) {
            return status != 'Draft' || stampsOnInsert ? 'New ' + label + ' start as Draft; approve them through the equity services.' : null;
        }
        if (oldStatus != 'Draft') {
            return 'Only Draft ' + label + ' can be edited; use the equity services for later changes.';
        }
        return status != oldStatus || stampsChanged
            ? 'Status, approval, journal and snapshot fields of ' + label + ' change only through the equity services.' : null;
    }
}
