trigger SABCloseTaskSharingTrigger on Close_Task__c (after insert, after update, after undelete) {
    SABCompanyRecordSharingHandler.route(Trigger.operationType, Trigger.new, Trigger.old);
}
