trigger SABTaxReturnLifecycleTrigger on Tax_Return__c (
    before update,
    before delete
) {
    if (Trigger.isBefore && Trigger.isUpdate) {
        SABTaxReturnLifecycleGuard.beforeUpdateReturns(
            Trigger.new,
            Trigger.oldMap
        );
    }

    if (Trigger.isBefore && Trigger.isDelete) {
        SABTaxReturnLifecycleGuard.beforeDeleteReturns(
            Trigger.old
        );
    }
}
