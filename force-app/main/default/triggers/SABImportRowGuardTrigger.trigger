trigger SABImportRowGuardTrigger on Import_Row__c (before insert, before update, before delete) {
    SABImportGuard.guardSystemRecords(Trigger.isDelete ? Trigger.old : Trigger.new, 'Import row');
}
