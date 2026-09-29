trigger SABFixedAssetMovementGuardTrigger
on Asset_Movement__c (
    before insert,
    before update,
    before delete
) {
    if (Trigger.isInsert) {
        SABFixedAssetMovementGuard.beforeInsert(
            Trigger.new
        );
    } else if (Trigger.isUpdate) {
        SABFixedAssetMovementGuard.beforeUpdate(
            Trigger.new
        );
    } else if (Trigger.isDelete) {
        SABFixedAssetMovementGuard.beforeDelete(
            Trigger.old
        );
    }
}
