trigger SABFXRevaluationLifecycleTrigger on FX_Revaluation_Run__c (
    before insert,
    before update,
    before delete
) {
    if (Trigger.isBefore && Trigger.isInsert) {
        SABFXRevaluationLifecycleGuard.beforeRunInsert(
            Trigger.new
        );
    }

    if (Trigger.isBefore && Trigger.isUpdate) {
        SABFXRevaluationLifecycleGuard.beforeRunUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    }

    if (Trigger.isBefore && Trigger.isDelete) {
        SABFXRevaluationLifecycleGuard.beforeRunDelete(
            Trigger.old
        );
    }
}
