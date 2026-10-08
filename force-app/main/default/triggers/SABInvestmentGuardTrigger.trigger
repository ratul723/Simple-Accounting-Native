trigger SABInvestmentGuardTrigger on Investment__c (before insert, before update) {
    SABLoanInvestmentGuard.guardInvestments(Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null);
}
