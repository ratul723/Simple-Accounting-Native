trigger SABPayComponentSharingTrigger on Pay_Component__c (
    after insert,
    after update,
    after undelete
) {
    if (Trigger.isInsert) {
        SABCompanyRecordSharingService.afterInsert(Trigger.new);
    } else if (Trigger.isUpdate) {
        Map<Id, SObject> oldRecords = new Map<Id, SObject>();
        for (Pay_Component__c row : Trigger.old) oldRecords.put(row.Id, row);
        SABCompanyRecordSharingService.afterUpdate(Trigger.new, oldRecords);
    } else if (Trigger.isUndelete) {
        SABCompanyRecordSharingService.afterUndelete(Trigger.new);
    }
}
