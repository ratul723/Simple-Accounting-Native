trigger SABPurchaseOrderLineGuardTrigger on Purchase_Order_Line__c (before insert, before update, before delete) {
    SABPurchasingGuard.guardPurchaseOrderLines(Trigger.isDelete ? Trigger.old : Trigger.new,
        Trigger.isUpdate ? Trigger.oldMap : null);
}
