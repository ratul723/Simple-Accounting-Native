trigger SABExpenseClaimLineLifecycleTrigger on Expense_Claim_Line__c (
    before insert,
    before update,
    before delete
) {
    if (Trigger.isBefore && Trigger.isInsert) {
        SABExpenseClaimLifecycleGuard.beforeLineInsert(
            Trigger.new
        );
    }

    if (Trigger.isBefore && Trigger.isUpdate) {
        SABExpenseClaimLifecycleGuard.beforeLineUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    }

    if (Trigger.isBefore && Trigger.isDelete) {
        SABExpenseClaimLifecycleGuard.beforeLineDelete(
            Trigger.old
        );
    }
}
