trigger SABImportJobGuardTrigger on Import_Job__c (before insert, before update, before delete) {
    SABImportGuard.guardJobs(Trigger.isDelete ? Trigger.old : Trigger.new, Trigger.isUpdate ? Trigger.oldMap : null, Trigger.isDelete);
}
