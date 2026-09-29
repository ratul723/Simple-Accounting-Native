trigger SABExpenseClaimSettlementGuardTrigger
on Claim_Settlement__c (
    before insert,
    before update,
    before delete
) {
    if (Trigger.isInsert) {
        SABExpenseClaimSettlementGuard.beforeInsert(
            Trigger.new
        );
    } else if (Trigger.isUpdate) {
        SABExpenseClaimSettlementGuard.beforeUpdate(
            Trigger.new
        );
    } else if (Trigger.isDelete) {
        SABExpenseClaimSettlementGuard.beforeDelete(
            Trigger.old
        );
    }
}
