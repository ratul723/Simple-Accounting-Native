trigger SABImportJobSharingTrigger on Import_Job__c (after insert, after update, after undelete) {
    SABCompanyRecordSharingHandler.route(Trigger.operationType, Trigger.new, Trigger.old);
}
