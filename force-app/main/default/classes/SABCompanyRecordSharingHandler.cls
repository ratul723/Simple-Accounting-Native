/**
 * G12: generic trigger router for company-scoped record sharing, so sharing triggers stay one-line
 * (PMD AvoidLogicInTrigger). Same behaviour as the existing per-object sharing triggers.
 */
public with sharing class SABCompanyRecordSharingHandler {
    public static void route(System.TriggerOperation operation, List<SObject> newRows, List<SObject> oldRows) {
        if (operation == System.TriggerOperation.AFTER_INSERT) {
            SABCompanyRecordSharingService.afterInsert(newRows);
        } else if (operation == System.TriggerOperation.AFTER_UPDATE) {
            SABCompanyRecordSharingService.afterUpdate(newRows, new Map<Id, SObject>(oldRows));
        } else if (operation == System.TriggerOperation.AFTER_UNDELETE) {
            SABCompanyRecordSharingService.afterUndelete(newRows);
        }
    }
}
