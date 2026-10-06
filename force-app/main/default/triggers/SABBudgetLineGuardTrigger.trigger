trigger SABBudgetLineGuardTrigger on Budget_Line__c (before insert, before update, before delete) {
    SABBudgetGuard.guardBudgetLines(Trigger.isDelete ? Trigger.old : Trigger.new);
}
