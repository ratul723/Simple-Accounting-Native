trigger CompanyUserAccessTrigger on Company_User_Access__c (
    after insert,
    after update,
    after delete,
    after undelete
) {
    // Revoke cached authorization before running the existing sharing handlers.
    SABCompanyAccessService.invalidateGrants(Trigger.old, Trigger.new);

    if (Trigger.isInsert) {
        SABCompanySharingService.afterInsert(Trigger.new);
    } else if (Trigger.isUpdate) {
        SABCompanySharingService.afterUpdate(
            Trigger.new,
            Trigger.oldMap
        );
    } else if (Trigger.isDelete) {
        SABCompanySharingService.afterDelete(Trigger.old);
    } else if (Trigger.isUndelete) {
        SABCompanySharingService.afterUndelete(Trigger.new);
    }
}
