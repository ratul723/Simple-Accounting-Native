trigger SABInvoiceCompanyGuardTrigger
on Invoice__c (before insert, before update) {
    SABCrossCompanyGuardService.validateInvoices(
        Trigger.new
    );
}
