/**
 * Simple Accounting Books
 * Step 3B-2D: scheduled company-sharing reconciliation.
 *
 * Purpose:
 * Company_User_Access__c uses effective dates. A trigger does not fire merely
 * because the calendar date changes, so this batch periodically re-runs the
 * existing SABCompanySharingService logic for every user/company grant.
 *
 * Prerequisite:
 * Step 3B-2B SABCompanySharingService is already deployed.
 */
public without sharing class SABCompanySharingReconciliationBatch
    implements Database.Batchable<SObject> {

    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator([
            SELECT Id,
                   Company__c,
                   User__c,
                   Is_Active__c,
                   Effective_From__c,
                   Effective_To__c
            FROM Company_User_Access__c
            WHERE Company__c != null
              AND User__c != null
        ]);
    }

    public void execute(
        Database.BatchableContext context,
        List<Company_User_Access__c> scope
    ) {
        if (scope == null || scope.isEmpty()) {
            return;
        }

        // Reuse the tested Step 3B sharing engine.
        // afterInsert() only derives affected User + Company pairs and
        // reconciles their current effective access; it does not depend on
        // the records having actually been inserted in this transaction.
        SABCompanySharingService.afterInsert(scope);
    }

    public void finish(Database.BatchableContext context) {
        // Intentionally no financial or sensitive data is logged here.
    }
}
