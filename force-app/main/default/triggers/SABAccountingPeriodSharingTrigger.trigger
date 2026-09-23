trigger SABAccountingPeriodSharingTrigger on Accounting_Period__c (
    after insert,
    after update,
    after undelete
) {
    if (Trigger.isInsert) {
        SABCompanyRecordSharingService.afterInsert(Trigger.new);
    } else if (Trigger.isUpdate) {
        Map<Id, SObject> oldRecords = new Map<Id, SObject>();
        for (Accounting_Period__c oldRecord : Trigger.old) {
            oldRecords.put(oldRecord.Id, oldRecord);
        }

        SABCompanyRecordSharingService.afterUpdate(
            Trigger.new,
            oldRecords
        );
    } else if (Trigger.isUndelete) {
        SABCompanyRecordSharingService.afterUndelete(Trigger.new);
    }
}
