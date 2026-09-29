/**
 * G8C - Claim Settlement direct-DML protection.
 *
 * Claim Settlement rows are system-managed financial allocation records.
 */
public without sharing class SABExpenseClaimSettlementGuard {

    private static Boolean trustedMutation() {
        return SABExpenseClaimSettlementService.isSettlementMutationInProgress();
    }

    public static void beforeInsert(
        List<Claim_Settlement__c> rows
    ) {
        if (trustedMutation()) {
            return;
        }

        for (Claim_Settlement__c row : rows) {
            row.addError(
                'Claim Settlements must be created through the Expense Claim Settlement service.'
            );
        }
    }

    public static void beforeUpdate(
        List<Claim_Settlement__c> rows
    ) {
        if (trustedMutation()) {
            return;
        }

        for (Claim_Settlement__c row : rows) {
            row.addError(
                'Claim Settlements are immutable outside the controlled settlement service.'
            );
        }
    }

    public static void beforeDelete(
        List<Claim_Settlement__c> rows
    ) {
        if (trustedMutation()) {
            return;
        }

        for (Claim_Settlement__c row : rows) {
            row.addError(
                'Claim Settlements cannot be deleted. Reverse them through the controlled settlement service.'
            );
        }
    }
}
