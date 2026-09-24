trigger SABCompanyConfigGuardTrigger
on Accounting_Company__c (before update, before delete) {
    if (Trigger.isUpdate) {
        SABConfigProtectionService.beforeCompanyUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    }

    if (Trigger.isDelete) {
        SABConfigProtectionService.beforeCompanyDelete(
            Trigger.old
        );
    }
}
