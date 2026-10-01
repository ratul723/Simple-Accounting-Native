trigger SABEmploymentSharingTrigger on Employment__c (
    after insert,
    after update,
    after undelete
) {
    SABEmployeeCompensationSharingService.afterEmploymentChange(
        Trigger.new,
        Trigger.isUpdate ? new Map<Id, Employment__c>(Trigger.old) : null
    );
}
