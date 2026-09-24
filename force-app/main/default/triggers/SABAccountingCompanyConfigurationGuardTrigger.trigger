trigger SABAccountingCompanyConfigurationGuardTrigger
on Accounting_Company__c (before update, before delete) {
    if (Trigger.isUpdate) {
        SABAccountingConfigurationProtectionService.beforeCompanyUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    }

    if (Trigger.isDelete) {
        SABAccountingConfigurationProtectionService.beforeCompanyDelete(
            Trigger.old
        );
    }
}
