trigger SABConsolidationAdjustmentGuardTrigger on Consolidation_Adjustment__c (before insert, before update, before delete) {
    SABGroupAccountingGuard.guardSystemRecords(Trigger.isDelete ? Trigger.old : Trigger.new, 'Consolidation adjustment');
}
