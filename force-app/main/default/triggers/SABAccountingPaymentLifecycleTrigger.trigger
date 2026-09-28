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
        // G3C Supplier Payment updates continue to use the existing service-local
        // guard bypass. G4B Customer Receipt updates use the shared mutation
        // context so that direct edits remain blocked while trusted lifecycle
        // services can move the Payment through its controlled state machine.
        if (!SABAccountingPaymentMutationContext.isMutationInProgress()) {
            SABSupplierPaymentService.guardBeforeUpdate(
                Trigger.oldMap,
                Trigger.new
            );
        }
    } else if (Trigger.isDelete) {
        SABSupplierPaymentService.guardBeforeDelete(
            Trigger.old
        );
    }
}
