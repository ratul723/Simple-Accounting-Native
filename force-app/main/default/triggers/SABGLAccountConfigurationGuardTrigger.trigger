trigger SABGLAccountConfigurationGuardTrigger
on GL_Account__c (before update, before delete) {
    if (Trigger.isUpdate) {
        SABAccountingConfigurationProtectionService.beforeGLAccountUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    }

    if (Trigger.isDelete) {
        SABAccountingConfigurationProtectionService.beforeGLAccountDelete(
            Trigger.old
        );
    }
}
