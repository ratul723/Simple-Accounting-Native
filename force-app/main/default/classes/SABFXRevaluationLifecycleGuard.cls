/**
 * G7B/G7C lifecycle guards for FX Revaluation Run and Line records.
 *
 * G7C adds the trusted reversal mutation context so SABReversalService can
 * reverse the G7B journal while the run remains protected from direct DML.
 */
public without sharing class SABFXRevaluationLifecycleGuard {

    private static final Set<String> LOCKED_STATUSES =
        new Set<String>{
            'Approved',
            'Posted',
            'Reversed'
        };

    private static Boolean isTrustedMutation() {
        return (
            SABFXRevaluationPostingService.isLifecycleMutationInProgress()
            || SABFXRevaluationReversalService.isLifecycleMutationInProgress()
        );
    }

    public static void beforeRunInsert(
        List<FX_Revaluation_Run__c> newRows
    ) {
        if (isTrustedMutation()) {
            return;
        }

        for (FX_Revaluation_Run__c row : newRows) {
            if (row.Status__c != 'Preview') {
                row.Status__c.addError(
                    'FX Revaluation Runs must be created in Preview status. Approval, posting and reversal must use the FX lifecycle services.'
                );
            }

            if (
                row.Journal_Entry__c != null
                || row.Approved_Snapshot_Hash__c != null
                || row.Approved_By__c != null
                || row.Approved_At__c != null
                || row.Posted_At__c != null
                || row.Reversal_Journal_Entry__c != null
                || row.Reversal_Accounting_Event__c != null
                || row.Reversed_At__c != null
            ) {
                row.addError(
                    'FX Revaluation approval, posting and reversal audit fields are system-managed and cannot be supplied on direct insert.'
                );
            }
        }
    }

    public static void beforeRunUpdate(
        List<FX_Revaluation_Run__c> newRows,
        Map<Id, FX_Revaluation_Run__c> oldMap
    ) {
        if (isTrustedMutation()) {
            return;
        }

        for (FX_Revaluation_Run__c current : newRows) {
            FX_Revaluation_Run__c prior =
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
                    'Approved/posted/reversed FX Revaluation Runs are locked. Use the FX Revaluation lifecycle service.'
                );
                continue;
            }

            if (
                current.Status__c
                    != prior.Status__c
            ) {
                current.Status__c.addError(
                    'FX Revaluation status transitions must use the FX Revaluation lifecycle service.'
                );
            }

            if (
                current.Company__c
                    != prior.Company__c
                || current.Accounting_Period__c
                    != prior.Accounting_Period__c
                || current.Rate_Set_Key__c
                    != prior.Rate_Set_Key__c
                || current.Run_Key__c
                    != prior.Run_Key__c
                || current.Journal_Entry__c
                    != prior.Journal_Entry__c
                || current.Approved_Snapshot_Hash__c
                    != prior.Approved_Snapshot_Hash__c
                || current.Approved_By__c
                    != prior.Approved_By__c
                || current.Approved_At__c
                    != prior.Approved_At__c
                || current.Posted_At__c
                    != prior.Posted_At__c
                || current.Reversal_Journal_Entry__c
                    != prior.Reversal_Journal_Entry__c
                || current.Reversal_Accounting_Event__c
                    != prior.Reversal_Accounting_Event__c
                || current.Reversed_At__c
                    != prior.Reversed_At__c
            ) {
                current.addError(
                    'FX Revaluation identity, approval, posting and reversal fields are lifecycle-controlled.'
                );
            }
        }
    }

    public static void beforeRunDelete(
        List<FX_Revaluation_Run__c> oldRows
    ) {
        if (isTrustedMutation()) {
            return;
        }

        for (FX_Revaluation_Run__c row : oldRows) {
            if (row.Status__c != 'Preview') {
                row.addError(
                    'Only Preview FX Revaluation Runs can be deleted.'
                );
            }
        }
    }

    public static void guardLineMutation(
        List<FX_Revaluation_Line__c> rows
    ) {
        if (isTrustedMutation()) {
            return;
        }

        Set<Id> runIds =
            new Set<Id>();

        for (FX_Revaluation_Line__c row : rows) {
            if (row.FX_Revaluation_Run__c != null) {
                runIds.add(
                    row.FX_Revaluation_Run__c
                );
            }
        }

        if (runIds.isEmpty()) {
            return;
        }

        Map<Id, FX_Revaluation_Run__c> runs =
            new Map<Id, FX_Revaluation_Run__c>([
                SELECT Id,
                       Status__c
                FROM FX_Revaluation_Run__c
                WHERE Id IN :runIds
            ]);

        for (FX_Revaluation_Line__c row : rows) {
            FX_Revaluation_Run__c parent =
                runs.get(
                    row.FX_Revaluation_Run__c
                );

            if (
                parent != null
                && LOCKED_STATUSES.contains(
                    parent.Status__c
                )
            ) {
                row.addError(
                    'FX Revaluation Lines are locked after approval. Create a new Preview run instead.'
                );
            }
        }
    }
}
