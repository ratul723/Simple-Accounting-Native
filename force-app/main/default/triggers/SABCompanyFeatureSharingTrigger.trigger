trigger SABCompanyFeatureSharingTrigger on Company_Feature__c (after insert, after update, after undelete) {
    SABCompanyRecordSharingHandler.route(Trigger.operationType, Trigger.new, Trigger.old);
}
