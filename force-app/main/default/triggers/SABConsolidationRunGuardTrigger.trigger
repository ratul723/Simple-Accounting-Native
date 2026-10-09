trigger SABConsolidationRunGuardTrigger on Consolidation_Run__c (before insert, before update, before delete) {
    SABGroupAccountingGuard.guardRuns(Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null, Trigger.isDelete);
}
