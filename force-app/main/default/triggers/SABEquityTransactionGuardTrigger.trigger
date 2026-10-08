trigger SABEquityTransactionGuardTrigger on Equity_Transaction__c (before insert, before update, before delete) {
    SABEquityGuard.guardTransactions(Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null, Trigger.isDelete);
}
