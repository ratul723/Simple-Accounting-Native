trigger SABTaxReturnLineLockTrigger on Tax_Return_Line__c (
    before insert,
    before update,
    before delete
) {
    if (Trigger.isBefore && Trigger.isInsert) {
        SABTaxReturnLifecycleGuard.guardLineMutation(
            Trigger.new
        );
    }

    if (Trigger.isBefore && Trigger.isUpdate) {
        SABTaxReturnLifecycleGuard.guardLineMutation(
            Trigger.new
        );
    }

    if (Trigger.isBefore && Trigger.isDelete) {
        SABTaxReturnLifecycleGuard.guardLineMutation(
            Trigger.old
        );
    }
}
