trigger SABDistributionLineGuardTrigger on Distribution_Line__c (before insert, before update, before delete) {
    SABEquityGuard.guardSystemRecords(Trigger.isDelete ? Trigger.old : Trigger.new, 'Distribution line');
}
