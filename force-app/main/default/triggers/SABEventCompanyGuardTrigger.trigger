trigger SABEventCompanyGuardTrigger
on Accounting_Event__c (before insert, before update) {
    SABCrossCompanyGuardService.validateEvents(
        Trigger.new
    );
}
