trigger SABAllocationRuleGuardTrigger on Allocation_Rule__c (before insert, before update, before delete) {
    SABAllocationGuard.guardRules(Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null, Trigger.isDelete);
}
