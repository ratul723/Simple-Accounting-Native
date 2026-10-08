trigger SABAllocationRunGuardTrigger on Allocation_Run__c (before insert, before update, before delete) {
    SABAllocationGuard.guardRuns(Trigger.isDelete ? Trigger.old : Trigger.new);
}
