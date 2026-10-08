trigger SABAllocationRunSharingTrigger on Allocation_Run__c (after insert, after update, after undelete) {
    SABCompanyRecordSharingHandler.route(Trigger.operationType, Trigger.new, Trigger.old);
}
