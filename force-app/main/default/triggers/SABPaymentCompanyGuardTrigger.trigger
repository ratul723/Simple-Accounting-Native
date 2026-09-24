trigger SABPaymentCompanyGuardTrigger
on Accounting_Payment__c (before insert, before update) {
    SABCrossCompanyGuardService.validatePayments(
        Trigger.new
    );
}
