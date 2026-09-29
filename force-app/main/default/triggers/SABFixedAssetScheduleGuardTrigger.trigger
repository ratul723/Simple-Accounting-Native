trigger SABFixedAssetScheduleGuardTrigger
on Asset_Schedule_Line__c (
    before insert,
    before update,
    before delete
) {
    if (Trigger.isInsert) {
        SABFixedAssetScheduleGuard.beforeInsert(
            Trigger.new
        );
    } else if (Trigger.isUpdate) {
        SABFixedAssetScheduleGuard.beforeUpdate(
            Trigger.new
        );
    } else if (Trigger.isDelete) {
        SABFixedAssetScheduleGuard.beforeDelete(
            Trigger.old
        );
    }
}
