/**
 * G9D - Asset Movement immutability and direct-DML protection.
 */
public without sharing class SABFixedAssetMovementGuard {

    private static Boolean trustedMutation() {
        return (
            SABFixedAssetMovementService.isMutationInProgress()
            || SABFixedAssetDepreciationPostingService.isMutationInProgress()
        );
    }

    public static void beforeInsert(
        List<Asset_Movement__c> rows
    ) {
        if (trustedMutation()) {
            return;
        }

        for (Asset_Movement__c row : rows) {
            row.addError(
                'Asset Movements must be created through controlled Fixed Asset lifecycle services.'
            );
        }
    }

    public static void beforeUpdate(
        List<Asset_Movement__c> rows
    ) {
        if (trustedMutation()) {
            return;
        }

        for (Asset_Movement__c row : rows) {
            row.addError(
                'Asset Movements are immutable outside controlled Fixed Asset lifecycle services.'
            );
        }
    }

    public static void beforeDelete(
        List<Asset_Movement__c> rows
    ) {
        if (trustedMutation()) {
            return;
        }

        for (Asset_Movement__c row : rows) {
            row.addError(
                'Asset Movements cannot be deleted.'
            );
        }
    }
}
