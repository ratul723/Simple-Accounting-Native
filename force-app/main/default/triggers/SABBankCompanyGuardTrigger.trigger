trigger SABBankCompanyGuardTrigger
on Bank_Account__c (before insert, before update) {
    SABCrossCompanyGuardService.validateBankAccounts(
        Trigger.new
    );
}
