trigger SABLoanGuardTrigger on Loan__c (before insert, before update, before delete) {
    SABLoanInvestmentGuard.guardLoans(Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null, Trigger.isDelete);
}
