trigger SABPeriodConfigGuardTrigger
on Accounting_Period__c (before update, before delete) {
    if (Trigger.isUpdate) {
        SABConfigProtectionService.beforePeriodUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    }

    if (Trigger.isDelete) {
        SABConfigProtectionService.beforePeriodDelete(
            Trigger.old
        );
    }
}
