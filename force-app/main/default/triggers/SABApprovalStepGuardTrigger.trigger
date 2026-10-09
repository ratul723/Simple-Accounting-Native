trigger SABApprovalStepGuardTrigger on Approval_Step__c (before insert, before update, before delete) {
    SABApprovalCloseGuard.guardSystemRecords(Trigger.isDelete ? Trigger.old : Trigger.new, 'Approval step');
}
