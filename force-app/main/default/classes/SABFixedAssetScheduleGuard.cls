/**
 * G9B/G9C direct-DML protection for Asset Schedule Lines.
 */
public without sharing class SABFixedAssetScheduleGuard {

    private static Boolean trustedMutation() {
        return (
            SABFixedAssetScheduleService.isMutationInProgress()
            || SABFixedAssetDepreciationPostingService.isMutationInProgress()
            || SABFixedAssetMovementService.isMutationInProgress()
        );
    }

    public static void beforeInsert(
        List<Asset_Schedule_Line__c> rows
    ) {
        if (trustedMutation()) {
            return;
        }

        for (
            Asset_Schedule_Line__c row :
            rows
        ) {
            row.addError(
                'Asset Schedule Lines must be generated through the controlled Fixed Asset Schedule service.'
            );
        }
    }

    public static void beforeUpdate(
        List<Asset_Schedule_Line__c> rows
    ) {
        if (trustedMutation()) {
            return;
        }

        for (
            Asset_Schedule_Line__c row :
            rows
        ) {
            row.addError(
                'Asset Schedule Lines are system-managed and cannot be directly updated.'
            );
        }
    }

    public static void beforeDelete(
        List<Asset_Schedule_Line__c> rows
    ) {
        if (trustedMutation()) {
            return;
        }

        for (
            Asset_Schedule_Line__c row :
            rows
        ) {
            row.addError(
                'Asset Schedule Lines cannot be deleted directly. Use the controlled asset lifecycle.'
            );
        }
    }
}
