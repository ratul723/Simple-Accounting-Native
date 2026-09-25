trigger SABSupplierBillLifecycleTrigger
on Supplier_Bill__c (
    before insert,
    before update,
    before delete
) {
    if (Trigger.isInsert) {
        SABSupplierBillService.guardBeforeSupplierBillInsert(
            Trigger.new
        );
    } else if (Trigger.isUpdate) {
        SABSupplierBillService.guardBeforeSupplierBillUpdate(
            Trigger.oldMap,
            Trigger.new
        );
    } else if (Trigger.isDelete) {
        SABSupplierBillService.guardBeforeSupplierBillDelete(
            Trigger.old
        );
    }
}
