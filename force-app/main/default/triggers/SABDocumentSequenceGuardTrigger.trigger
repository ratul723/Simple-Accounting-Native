trigger SABDocumentSequenceGuardTrigger
on Document_Sequence__c (before update, before delete) {
    if (Trigger.isUpdate) {
        SABDocumentSequenceGuardService.beforeUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    }

    if (Trigger.isDelete) {
        SABDocumentSequenceGuardService.beforeDelete(
            Trigger.old
        );
    }
}
