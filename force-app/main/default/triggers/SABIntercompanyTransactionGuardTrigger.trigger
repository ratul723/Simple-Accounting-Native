trigger SABIntercompanyTransactionGuardTrigger on Intercompany_Transaction__c (before insert, before update, before delete) {
    SABGroupAccountingGuard.guardSystemRecords(Trigger.isDelete ? Trigger.old : Trigger.new, 'Intercompany transaction');
}
