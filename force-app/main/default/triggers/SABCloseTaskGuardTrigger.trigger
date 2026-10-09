trigger SABCloseTaskGuardTrigger on Close_Task__c (before insert, before update, before delete) {
    SABApprovalCloseGuard.guardCloseTasks(Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null, Trigger.isDelete);
}
