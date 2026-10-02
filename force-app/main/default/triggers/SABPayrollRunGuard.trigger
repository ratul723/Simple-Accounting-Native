trigger SABPayrollRunGuard on Payroll_Run__c (before insert, before update, before delete) {
    SABPayrollCalculationService.guard(Trigger.isDelete ? Trigger.old : Trigger.new);
}
