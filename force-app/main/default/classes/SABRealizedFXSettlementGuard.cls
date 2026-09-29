/**
 * Protects the system-managed realized FX snapshot on Payment_Allocation__c.
 *
 * A Payment Allocation with a Posted realized-FX journal cannot be reversed
 * by the older allocation-only reversal path, because doing so would leave the
 * realized-FX journal in the ledger. A later integration slice will coordinate
 * allocation reversal + realized-FX journal reversal in one transaction.
 *
 * Calculated zero-difference allocations may still be reversed normally.
 */
public without sharing class SABRealizedFXSettlementGuard {

    private static Boolean isTrustedMutation() {
        return (
            SABRealizedFXSettlementService.isMutationInProgress()
            || SABForeignCurrencySettlementService.isLifecycleMutationInProgress()
        );
    }

    private static final Set<String> PROTECTED_STATES =
        new Set<String>{
            'Calculated',
            'Posted',
            'Reversed'
        };

    public static void beforeInsert(
        List<Payment_Allocation__c> newRows
    ) {
        if (isTrustedMutation()) {
            return;
        }

        for (Payment_Allocation__c row : newRows) {
            Boolean hasSystemManagedFXValue =
                row.Historical_Carrying_Base__c != null
                || row.Settlement_Base_Amount__c != null
                || row.Realized_FX_Amount__c != null
                || (
                    !String.isBlank(
                        row.Realized_FX_State__c
                    )
                    && row.Realized_FX_State__c != 'None'
                )
                || row.Realized_FX_Source_GL_Account__c != null
                || row.Realized_FX_Journal__c != null
                || row.Realized_FX_Accounting_Event__c != null
                || row.Realized_FX_Reversal_Journal__c != null
                || row.Realized_FX_Reversal_Event__c != null
                || row.Realized_FX_Reversed_At__c != null;

            if (hasSystemManagedFXValue) {
                row.addError(
                    'Realized FX snapshot fields are system-managed and cannot be supplied on direct Payment Allocation insert.'
                );
            }
        }
    }

    public static void beforeUpdate(
        List<Payment_Allocation__c> newRows,
        Map<Id, Payment_Allocation__c> oldMap
    ) {
        if (isTrustedMutation()) {
            return;
        }

        for (Payment_Allocation__c current : newRows) {
            Payment_Allocation__c prior =
                oldMap.get(
                    current.Id
                );

            if (prior == null) {
                continue;
            }

            if (
                current.Historical_Carrying_Base__c
                    != prior.Historical_Carrying_Base__c
                || current.Settlement_Base_Amount__c
                    != prior.Settlement_Base_Amount__c
                || current.Realized_FX_Amount__c
                    != prior.Realized_FX_Amount__c
                || current.Realized_FX_State__c
                    != prior.Realized_FX_State__c
                || current.Realized_FX_Source_GL_Account__c
                    != prior.Realized_FX_Source_GL_Account__c
                || current.Realized_FX_Journal__c
                    != prior.Realized_FX_Journal__c
                || current.Realized_FX_Accounting_Event__c
                    != prior.Realized_FX_Accounting_Event__c
                || current.Realized_FX_Reversal_Journal__c
                    != prior.Realized_FX_Reversal_Journal__c
                || current.Realized_FX_Reversal_Event__c
                    != prior.Realized_FX_Reversal_Event__c
                || current.Realized_FX_Reversed_At__c
                    != prior.Realized_FX_Reversed_At__c
            ) {
                current.addError(
                    'Realized FX fields are system-managed. Use the Realized FX Settlement service.'
                );
                continue;
            }

            if (
                prior.Realized_FX_State__c
                    == 'Posted'
                && current.Status__c
                    != prior.Status__c
            ) {
                current.addError(
                    'Payment Allocation with posted Realized FX cannot change status until its Realized FX journal is reversed through the coordinated FX settlement reversal flow.'
                );
                continue;
            }

            if (
                PROTECTED_STATES.contains(
                    prior.Realized_FX_State__c
                )
                && (
                    current.Payment__c
                        != prior.Payment__c
                    || current.Invoice__c
                        != prior.Invoice__c
                    || current.Supplier_Bill__c
                        != prior.Supplier_Bill__c
                    || current.Allocated_Amount__c
                        != prior.Allocated_Amount__c
                    || current.Payment_Amount__c
                        != prior.Payment_Amount__c
                    || current.Document_Amount__c
                        != prior.Document_Amount__c
                    || current.Base_Amount__c
                        != prior.Base_Amount__c
                    || current.Transaction_Currency__c
                        != prior.Transaction_Currency__c
                    || current.Exchange_Rate__c
                        != prior.Exchange_Rate__c
                    || current.Effective_Date__c
                        != prior.Effective_Date__c
                )
            ) {
                current.addError(
                    'Payment Allocation financial source fields are locked after realized FX processing.'
                );
            }
        }
    }

    public static void beforeDelete(
        List<Payment_Allocation__c> oldRows
    ) {
        if (isTrustedMutation()) {
            return;
        }

        for (Payment_Allocation__c row : oldRows) {
            if (
                PROTECTED_STATES.contains(
                    row.Realized_FX_State__c
                )
            ) {
                row.addError(
                    'Payment Allocation cannot be deleted after realized FX processing.'
                );
            }
        }
    }
}
