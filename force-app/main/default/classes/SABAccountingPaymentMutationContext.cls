/**
 * Internal mutation context for controlled Accounting_Payment__c lifecycle updates.
 *
 * G3C originally used a service-local flag inside SABSupplierPaymentService.
 * G4B adds a second controlled lifecycle service for Customer Receipts, so a
 * shared context is required to let trusted application services update the
 * system-managed lifecycle fields without weakening direct-user protections.
 */
public class SABAccountingPaymentMutationContext {
    @TestVisible
    private static Integer depth = 0;

    public static void beginMutation() {
        depth++;
    }

    public static void endMutation() {
        if (depth > 0) {
            depth--;
        }
    }

    public static Boolean isMutationInProgress() {
        return depth > 0;
    }
}
