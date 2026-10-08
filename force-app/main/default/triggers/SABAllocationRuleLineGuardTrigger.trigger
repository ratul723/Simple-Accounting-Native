trigger SABAllocationRuleLineGuardTrigger on Allocation_Rule_Line__c (before insert, before update, before delete) {
    SABAllocationGuard.guardRuleLines(Trigger.isDelete ? Trigger.old : Trigger.new);
}
