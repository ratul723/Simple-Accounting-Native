trigger SABPayrollComponentGuard on Payroll_Component_Line__c (before insert, before update, before delete) {
    SABPayrollCalculationService.guard(Trigger.isDelete ? Trigger.old : Trigger.new);
}
