trigger SABBenefitAwardPayrollGuardTrigger on Benefit_Award__c (before insert, before update, before delete) {
    SABPayrollBenefitAwardService.guardAwards(Trigger.isDelete ? Trigger.old : Trigger.new,
        Trigger.isUpdate ? Trigger.oldMap : null, Trigger.isDelete);
}
