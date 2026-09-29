trigger SABFXRevaluationLineLockTrigger on FX_Revaluation_Line__c (
    before insert,
    before update,
    before delete
) {
    if (Trigger.isBefore && Trigger.isInsert) {
        SABFXRevaluationLifecycleGuard.guardLineMutation(
            Trigger.new
        );
    }

    if (Trigger.isBefore && Trigger.isUpdate) {
        SABFXRevaluationLifecycleGuard.guardLineMutation(
            Trigger.new
        );
    }

    if (Trigger.isBefore && Trigger.isDelete) {
        SABFXRevaluationLifecycleGuard.guardLineMutation(
            Trigger.old
        );
    }
}
