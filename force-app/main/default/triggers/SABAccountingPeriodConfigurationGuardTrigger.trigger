trigger SABAccountingPeriodConfigurationGuardTrigger
on Accounting_Period__c (before update, before delete) {
    if (Trigger.isUpdate) {
        SABAccountingConfigurationProtectionService.beforePeriodUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    }

    if (Trigger.isDelete) {
        SABAccountingConfigurationProtectionService.beforePeriodDelete(
            Trigger.old
        );
    }
}
