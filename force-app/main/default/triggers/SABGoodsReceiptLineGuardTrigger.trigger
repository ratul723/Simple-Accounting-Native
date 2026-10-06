trigger SABGoodsReceiptLineGuardTrigger on Goods_Receipt_Line__c (before insert, before update, before delete) {
    SABPurchasingGuard.guardGoodsReceiptLines(Trigger.isDelete ? Trigger.old : Trigger.new);
}
