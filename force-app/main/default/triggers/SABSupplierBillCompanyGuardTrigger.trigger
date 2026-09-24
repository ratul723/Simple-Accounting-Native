trigger SABSupplierBillCompanyGuardTrigger
on Supplier_Bill__c (before insert, before update) {
    SABCrossCompanyGuardService.validateSupplierBills(
        Trigger.new
    );
}
