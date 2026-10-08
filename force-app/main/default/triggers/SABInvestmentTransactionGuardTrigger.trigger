trigger SABInvestmentTransactionGuardTrigger on Investment_Transaction__c (before insert, before update, before delete) {
    SABLoanInvestmentGuard.guardSystemRecords(Trigger.isDelete ? Trigger.old : Trigger.new, 'Investment transaction');
}
