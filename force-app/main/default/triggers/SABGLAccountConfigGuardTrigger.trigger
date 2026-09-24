trigger SABGLAccountConfigGuardTrigger
on GL_Account__c (before update, before delete) {
    if (Trigger.isUpdate) {
        SABConfigProtectionService.beforeGLAccountUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    }

    if (Trigger.isDelete) {
        SABConfigProtectionService.beforeGLAccountDelete(
            Trigger.old
        );
    }
}
