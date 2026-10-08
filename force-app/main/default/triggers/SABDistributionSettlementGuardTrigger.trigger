trigger SABDistributionSettlementGuardTrigger on Distribution_Settlement__c (before insert, before update, before delete) {
    SABEquityGuard.guardSystemRecords(Trigger.isDelete ? Trigger.old : Trigger.new, 'Distribution settlement');
}
