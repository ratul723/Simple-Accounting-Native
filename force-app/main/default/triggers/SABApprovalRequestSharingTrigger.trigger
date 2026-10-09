trigger SABApprovalRequestSharingTrigger on Approval_Request__c (after insert, after update, after undelete) {
    SABCompanyRecordSharingHandler.route(Trigger.operationType, Trigger.new, Trigger.old);
}
