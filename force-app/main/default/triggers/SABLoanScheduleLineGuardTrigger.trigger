trigger SABLoanScheduleLineGuardTrigger on Loan_Schedule_Line__c (before insert, before update, before delete) {
    SABLoanInvestmentGuard.guardSystemRecords(Trigger.isDelete ? Trigger.old : Trigger.new, 'Loan schedule line');
}
