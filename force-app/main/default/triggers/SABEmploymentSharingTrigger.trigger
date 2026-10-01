trigger SABEmploymentSharingTrigger on Employment__c (
    after insert,
    after update,
    after undelete
) {
    // Employment has its own Company__c and requires its own record shares.
    // The compensation sharing service below maintains the related Employee.
    if (Trigger.isInsert) {
        SABCompanyRecordSharingService.afterInsert(Trigger.new);
    } else if (Trigger.isUpdate) {
        Map<Id, SObject> oldRecords = new Map<Id, SObject>();
        for (Employment__c row : Trigger.old) oldRecords.put(row.Id, row);
        SABCompanyRecordSharingService.afterUpdate(Trigger.new, oldRecords);
    } else if (Trigger.isUndelete) {
        SABCompanyRecordSharingService.afterUndelete(Trigger.new);
    }

    SABEmployeeCompensationSharingService.afterEmploymentChange(
        Trigger.new,
        Trigger.isUpdate ? new Map<Id, Employment__c>(Trigger.old) : null
    );
}
