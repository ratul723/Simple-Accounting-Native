trigger SABPayrollPaymentGuardTrigger on Accounting_Payment__c (before insert, before update, before delete) {
    SABPayrollSettlementService.guardPayments(Trigger.isDelete ? Trigger.old : Trigger.new,
        Trigger.isUpdate ? Trigger.oldMap : null, Trigger.isDelete);
}
