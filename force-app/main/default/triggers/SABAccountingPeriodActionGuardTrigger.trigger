/**
 * Accounting_Period_Action__c is immutable audit history.
 * Period actions are created by SABPeriodService and cannot be edited/deleted.
 */
trigger SABAccountingPeriodActionGuardTrigger
on Accounting_Period_Action__c (
    before update,
    before delete
) {
    if (Trigger.isUpdate || Trigger.isDelete) {
        for (Accounting_Period_Action__c actionRecord : Trigger.old) {
            actionRecord.addError(
                'Accounting Period Action history is immutable and cannot be changed or deleted.'
            );
        }
    }
}
