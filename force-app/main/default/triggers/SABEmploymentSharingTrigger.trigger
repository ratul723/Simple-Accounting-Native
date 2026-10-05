trigger SABEmploymentSharingTrigger on Employment__c (after insert, after update, after undelete) {
    // Employment has its own Company__c shares; the compensation sharing service also maintains the Employee.
    SABPayrollTriggerHandler.employmentSharing(Trigger.operationType, Trigger.new, Trigger.old);
}
