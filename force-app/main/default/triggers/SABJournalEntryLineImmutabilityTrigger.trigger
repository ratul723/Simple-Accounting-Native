trigger SABJournalEntryLineImmutabilityTrigger
on Journal_Entry_Line__c (
    before insert,
    before update,
    before delete
) {
    if (Trigger.isInsert) {
        SABJournalImmutabilityService.beforeLineInsert(
            Trigger.new
        );
    }

    if (Trigger.isUpdate) {
        SABJournalImmutabilityService.beforeLineUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    }

    if (Trigger.isDelete) {
        SABJournalImmutabilityService.beforeLineDelete(
            Trigger.old
        );
    }
}
