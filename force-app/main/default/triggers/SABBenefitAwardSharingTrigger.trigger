trigger SABBenefitAwardSharingTrigger on Benefit_Award__c (
    after insert,
    after update,
    after undelete
) {
    SABEmployeeCompensationSharingService.afterBenefitAwardChange(
        Trigger.new,
        Trigger.isUpdate ? new Map<Id, Benefit_Award__c>(Trigger.old) : null
    );
}
