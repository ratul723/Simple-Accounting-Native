/**
 * G13: guard for budgets and budget lines.
 *
 * Outside the budget service's write scope:
 *  - Budgets may be inserted only as Draft (a blank status becomes Draft), edited only while Draft without touching
 *    status, version, key, company, fiscal year, currency or submission/approval stamps, and deleted only while Draft.
 *  - Budget lines may change only while their budget is Draft.
 * The service re-validates every line on submit, so direct Draft edits cannot bypass the rules.
 */
public with sharing class SABBudgetGuard {
    private static final String DRAFT = 'Draft';
    private static Integer scopeDepth = 0;

    /** Opened only by SABBudgetService around its own writes. */
    public static void beginWrite() {
        scopeDepth++;
    }

    public static void endWrite() {
        scopeDepth = scopeDepth > 0 ? scopeDepth - 1 : 0;
    }

    public static Boolean inWriteScope() {
        return scopeDepth > 0;
    }

    public static void guardBudgets(List<Budget__c> rows, Map<Id, Budget__c> oldMap, Boolean isDelete) {
        // Status is not required and has no picklist default: a new budget without one starts as Draft.
        if (!isDelete && oldMap == null) {
            for (Budget__c row : rows) {
                row.Status__c = row.Status__c == null ? DRAFT : row.Status__c;
            }
        }
        if (inWriteScope()) {
            return;
        }
        for (Budget__c row : rows) {
            Budget__c old = oldMap == null ? null : oldMap.get(row.Id);
            String message;
            if (isDelete) {
                message = row.Status__c == DRAFT ? null : 'Only Draft budgets can be deleted.';
            } else if (old == null) {
                message = row.Status__c != DRAFT || row.Approved_By__c != null || row.Submitted_By__c != null
                    ? 'Budgets start as Draft; submit and approve them through the budget service.' : null;
            } else if (old.Status__c != DRAFT) {
                message = 'Only Draft budgets can be edited; revise an approved budget through the budget service.';
            } else if (row.Status__c != old.Status__c || row.Version__c != old.Version__c || row.Budget_Key__c != old.Budget_Key__c
                    || row.Company__c != old.Company__c || row.Fiscal_Year__c != old.Fiscal_Year__c || row.Currency__c != old.Currency__c
                    || row.Submitted_By__c != old.Submitted_By__c || row.Approved_By__c != old.Approved_By__c
                    || row.Submitted_At__c != old.Submitted_At__c || row.Approved_At__c != old.Approved_At__c) {
                message = 'Budget status, version, company, fiscal year, currency and approval fields change only through the budget service.';
            }
            if (message != null) {
                row.addError(message);
            }
        }
    }

    public static void guardBudgetLines(List<Budget_Line__c> rows) {
        if (inWriteScope()) {
            return;
        }
        Set<Id> budgetIds = new Set<Id>();
        for (Budget_Line__c row : rows) {
            budgetIds.add(row.Budget__c);
        }
        Map<Id, String> statuses = new Store().statuses(budgetIds);
        for (Budget_Line__c row : rows) {
            if (statuses.get(row.Budget__c) != DRAFT) {
                row.addError('Budget lines can change only while the budget is Draft.');
            }
        }
    }

    // Parent statuses are read completely, whatever the running user's sharing, so the guard cannot be bypassed.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Map<Id, String> statuses(Set<Id> ids) {
            Map<Id, String> result = new Map<Id, String>();
            for (Budget__c row : [SELECT Id, Status__c FROM Budget__c WHERE Id IN :ids WITH SYSTEM_MODE]) {
                result.put(row.Id, row.Status__c);
            }
            return result;
        }
    }
}
