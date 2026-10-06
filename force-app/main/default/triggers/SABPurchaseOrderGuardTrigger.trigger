trigger SABPurchaseOrderGuardTrigger on Purchase_Order__c (before insert, before update, before delete) {
    SABPurchasingGuard.guardPurchaseOrders(Trigger.isDelete ? Trigger.old : Trigger.new,
        Trigger.isUpdate ? Trigger.oldMap : null, Trigger.isDelete);
}
