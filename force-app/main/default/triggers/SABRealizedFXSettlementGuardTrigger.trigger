trigger SABRealizedFXSettlementGuardTrigger
on Payment_Allocation__c (
    before insert,
    before update,
    before delete
) {
    if (Trigger.isBefore && Trigger.isInsert) {
        SABRealizedFXSettlementGuard.beforeInsert(
            Trigger.new
        );
    }

    if (Trigger.isBefore && Trigger.isUpdate) {
        SABRealizedFXSettlementGuard.beforeUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    }

    if (Trigger.isBefore && Trigger.isDelete) {
        SABRealizedFXSettlementGuard.beforeDelete(
            Trigger.old
        );
    }
}
