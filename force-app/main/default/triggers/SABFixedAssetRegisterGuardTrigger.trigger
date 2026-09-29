trigger SABFixedAssetRegisterGuardTrigger
on Fixed_Asset__c (
    before insert,
    before update,
    before delete
) {
    if (Trigger.isInsert) {
        SABFixedAssetRegisterGuard.beforeInsert(
            Trigger.new
        );
    } else if (Trigger.isUpdate) {
        SABFixedAssetRegisterGuard.beforeUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    } else if (Trigger.isDelete) {
        SABFixedAssetRegisterGuard.beforeDelete(
            Trigger.old
        );
    }
}
