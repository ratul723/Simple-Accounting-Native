trigger SABProjectPolicyTrigger on Project__c (before insert, before update, before delete, after undelete) {
    SABProjectPolicy.handleTrigger();
}
