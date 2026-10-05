trigger SABPayrollSettlementGuardTrigger on Payroll_Settlement__c (before insert, before update, before delete) {
    SABPayrollSettlementService.guardSettlements(Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.isDelete);
}
