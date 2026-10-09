trigger SABApprovalRequestGuardTrigger on Approval_Request__c (before insert, before update, before delete) {
    SABApprovalCloseGuard.guardSystemRecords(Trigger.isDelete ? Trigger.old : Trigger.new, 'Approval request');
}
