/**
 * G10H: logic for the G10 sharing triggers, so each trigger is a single delegation (PMD AvoidLogicInTrigger).
 * Behaviour is unchanged: company record shares on insert, update and undelete, plus Employee sharing
 * maintenance for Employment changes.
 */
public with sharing class SABPayrollTriggerHandler {
    public static void companySharing(System.TriggerOperation operation, List<SObject> newRows, List<SObject> oldRows) {
        if (operation == System.TriggerOperation.AFTER_INSERT) {
            SABCompanyRecordSharingService.afterInsert(newRows);
        } else if (operation == System.TriggerOperation.AFTER_UPDATE) {
            SABCompanyRecordSharingService.afterUpdate(newRows, new Map<Id, SObject>(oldRows));
        } else if (operation == System.TriggerOperation.AFTER_UNDELETE) {
            SABCompanyRecordSharingService.afterUndelete(newRows);
        }
    }

    public static void employmentSharing(System.TriggerOperation operation, List<Employment__c> newRows, List<Employment__c> oldRows) {
        companySharing(operation, newRows, oldRows);
        SABEmployeeCompensationSharingService.afterEmploymentChange(newRows,
            operation == System.TriggerOperation.AFTER_UPDATE ? new Map<Id, Employment__c>(oldRows) : null);
    }
}
