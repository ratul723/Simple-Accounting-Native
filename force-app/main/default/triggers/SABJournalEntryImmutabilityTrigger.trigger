trigger SABJournalEntryImmutabilityTrigger
on Journal_Entry__c (
    before update,
    before delete
) {
    if (Trigger.isUpdate) {
        SABJournalImmutabilityService.beforeJournalUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    }

    if (Trigger.isDelete) {
        SABJournalImmutabilityService.beforeJournalDelete(
            Trigger.old
        );
    }
}
