trigger SABDistributionGuardTrigger on Distribution__c (before insert, before update, before delete) {
    SABEquityGuard.guardDistributions(Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null, Trigger.isDelete);
}
