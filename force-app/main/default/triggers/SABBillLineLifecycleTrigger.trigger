trigger SABBillLineLifecycleTrigger
on Bill_Line__c (
    before insert,
    before update,
    before delete
) {
    if (Trigger.isInsert) {
        SABSupplierBillService.guardBillLinesBeforeInsert(
            Trigger.new
        );
    } else if (Trigger.isUpdate) {
        SABSupplierBillService.guardBillLinesBeforeUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    } else if (Trigger.isDelete) {
        SABSupplierBillService.guardBillLinesBeforeDelete(
            Trigger.old
        );
    }
}
