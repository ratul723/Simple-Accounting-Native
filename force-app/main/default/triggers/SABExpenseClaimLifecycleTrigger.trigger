trigger SABExpenseClaimLifecycleTrigger on Expense_Claim__c (
    before insert,
    before update,
    before delete
) {
    if (Trigger.isBefore && Trigger.isInsert) {
        SABExpenseClaimLifecycleGuard.beforeClaimInsert(
            Trigger.new
        );
    }

    if (Trigger.isBefore && Trigger.isUpdate) {
        SABExpenseClaimLifecycleGuard.beforeClaimUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    }

    if (Trigger.isBefore && Trigger.isDelete) {
        SABExpenseClaimLifecycleGuard.beforeClaimDelete(
            Trigger.old
        );
    }
}
