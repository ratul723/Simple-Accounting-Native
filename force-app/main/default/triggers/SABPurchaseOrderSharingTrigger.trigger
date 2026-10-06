trigger SABPurchaseOrderSharingTrigger on Purchase_Order__c (after insert, after update, after undelete) {
    SABCompanyRecordSharingHandler.route(Trigger.operationType, Trigger.new, Trigger.old);
}
