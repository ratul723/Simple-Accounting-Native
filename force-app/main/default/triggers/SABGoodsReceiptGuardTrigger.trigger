trigger SABGoodsReceiptGuardTrigger on Goods_Receipt__c (before insert, before update, before delete) {
    SABPurchasingGuard.guardGoodsReceipts(Trigger.isDelete ? Trigger.old : Trigger.new,
        Trigger.isUpdate ? Trigger.oldMap : null, Trigger.isDelete);
}
