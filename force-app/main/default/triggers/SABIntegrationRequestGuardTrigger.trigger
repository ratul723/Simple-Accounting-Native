trigger SABIntegrationRequestGuardTrigger on Integration_Request__c (before insert, before update, before delete) {
    SABImportGuard.guardSystemRecords(Trigger.isDelete ? Trigger.old : Trigger.new, 'Integration request');
}
