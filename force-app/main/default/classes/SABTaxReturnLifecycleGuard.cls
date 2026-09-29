/**
 * G6D server-side lifecycle guards.
 *
 * These guards prevent Setup/UI/API DML from bypassing the controlled
 * Tax Return lifecycle service after review.
 */
public without sharing class SABTaxReturnLifecycleGuard {

    private static final Set<String> LOCKED_STATUSES =
        new Set<String>{
            'Reviewed',
            'Submitted',
            'Accepted',
            'Rejected',
            'Amended'
        };

    public static void beforeUpdateReturns(
        List<Tax_Return__c> newRows,
        Map<Id, Tax_Return__c> oldMap
    ) {
        if (
            SABTaxReturnLifecycleService.isLifecycleMutationInProgress()
        ) {
            return;
        }

        for (Tax_Return__c current : newRows) {
            Tax_Return__c prior =
                oldMap.get(
                    current.Id
                );

            if (prior == null) {
                continue;
            }

            if (
                LOCKED_STATUSES.contains(
                    prior.Status__c
                )
            ) {
                current.addError(
                    'Reviewed/filed Tax Returns are locked. Use the Tax Return lifecycle service.'
                );
                continue;
            }

            if (
                current.Status__c
                    != prior.Status__c
                && !(
                    prior.Status__c == 'Draft'
                    && current.Status__c == 'Prepared'
                )
            ) {
                current.Status__c.addError(
                    'Tax Return status transitions must use the Tax Return lifecycle service.'
                );
            }

            if (
                current.Filing_Reference__c
                    != prior.Filing_Reference__c
                || current.Acknowledgement_Reference__c
                    != prior.Acknowledgement_Reference__c
                || current.Locked_Source_Hash__c
                    != prior.Locked_Source_Hash__c
                || current.Amends_Tax_Return__c
                    != prior.Amends_Tax_Return__c
            ) {
                current.addError(
                    'Tax Return filing, acknowledgement, lock and amendment fields are lifecycle-controlled.'
                );
            }

            if (
                prior.Status__c == 'Prepared'
                && (
                    current.Company__c
                        != prior.Company__c
                    || current.Tax_Registration__c
                        != prior.Tax_Registration__c
                    || current.Period_Start__c
                        != prior.Period_Start__c
                    || current.Period_End__c
                        != prior.Period_End__c
                    || current.Country_Pack_Version__c
                        != prior.Country_Pack_Version__c
                    || current.Return_Version__c
                        != prior.Return_Version__c
                )
            ) {
                current.addError(
                    'Prepared Tax Return identity and period fields are locked.'
                );
            }
        }
    }

    public static void beforeDeleteReturns(
        List<Tax_Return__c> oldRows
    ) {
        if (
            SABTaxReturnLifecycleService.isLifecycleMutationInProgress()
        ) {
            return;
        }

        for (Tax_Return__c row : oldRows) {
            if (row.Status__c != 'Draft') {
                row.addError(
                    'Only Draft Tax Returns can be deleted.'
                );
            }
        }
    }

    public static void guardLineMutation(
        List<Tax_Return_Line__c> candidateRows
    ) {
        if (
            SABTaxReturnLifecycleService.isLifecycleMutationInProgress()
        ) {
            return;
        }

        Set<Id> returnIds =
            new Set<Id>();

        for (
            Tax_Return_Line__c row :
            candidateRows
        ) {
            if (row.Tax_Return__c != null) {
                returnIds.add(
                    row.Tax_Return__c
                );
            }
        }

        if (returnIds.isEmpty()) {
            return;
        }

        Map<Id, Tax_Return__c> returns =
            new Map<Id, Tax_Return__c>([
                SELECT Id,
                       Status__c
                FROM Tax_Return__c
                WHERE Id IN :returnIds
            ]);

        for (
            Tax_Return_Line__c row :
            candidateRows
        ) {
            Tax_Return__c parent =
                returns.get(
                    row.Tax_Return__c
                );

            if (
                parent != null
                && LOCKED_STATUSES.contains(
                    parent.Status__c
                )
            ) {
                row.addError(
                    'Tax Return Lines are locked after review. Create a controlled amendment instead.'
                );
            }
        }
    }
}
