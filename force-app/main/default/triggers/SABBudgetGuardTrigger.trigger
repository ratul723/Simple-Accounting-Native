trigger SABBudgetGuardTrigger on Budget__c (before insert, before update, before delete) {
    SABBudgetGuard.guardBudgets(Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null, Trigger.isDelete);
}
