trigger SABEmployeePayComponentSharingTrigger on Employee_Pay_Component__c (
    after insert,
    after update,
    after undelete
) {
    SABEmployeeCompensationSharingService.afterPayComponentChange(
        Trigger.new,
        Trigger.isUpdate ? new Map<Id, Employee_Pay_Component__c>(Trigger.old) : null
    );
}
