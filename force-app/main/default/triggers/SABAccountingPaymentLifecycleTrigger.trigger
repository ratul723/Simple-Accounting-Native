trigger SABAccountingPaymentLifecycleTrigger
on Accounting_Payment__c (
    before insert,
    before update,
    before delete
) {
    if (Trigger.isInsert) {
        SABSupplierPaymentService.guardBeforeInsert(
            Trigger.new
        );
    } else if (Trigger.isUpdate) {
        SABSupplierPaymentService.guardBeforeUpdate(
            Trigger.oldMap,
            Trigger.new
        );
    } else if (Trigger.isDelete) {
        SABSupplierPaymentService.guardBeforeDelete(
            Trigger.old
        );
    }
}
