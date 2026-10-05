trigger SABPayrollRunSharingTrigger on Payroll_Run__c (after insert, after update, after undelete) {
    SABPayrollTriggerHandler.companySharing(Trigger.operationType, Trigger.new, Trigger.old);
}
