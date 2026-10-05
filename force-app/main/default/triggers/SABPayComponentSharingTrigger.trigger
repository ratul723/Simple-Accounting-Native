trigger SABPayComponentSharingTrigger on Pay_Component__c (after insert, after update, after undelete) {
    SABPayrollTriggerHandler.companySharing(Trigger.operationType, Trigger.new, Trigger.old);
}
