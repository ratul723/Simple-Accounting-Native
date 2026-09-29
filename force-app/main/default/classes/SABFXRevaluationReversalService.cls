/**
 * G7C - FX Revaluation Reversal.
 *
 * Reverses the posted G7B FX revaluation journal through SABReversalService.
 *
 * Reversal policy:
 * - First Day of Next Period: use the immediately following open period,
 *   on that period's first day.
 * - Next Open Period: use the earliest later open period, on its first day.
 * - No Automatic Reversal: the caller must provide an explicit open period
 *   and date. This supports a controlled manual reversal without interpreting
 *   "No Automatic Reversal" as "never reverse".
 */
public without sharing class SABFXRevaluationReversalService {

    public class FXRevaluationReversalException extends Exception {}

    private static final String STATUS_POSTED =
        'Posted';

    private static final String STATUS_REVERSED =
        'Reversed';

    private static final String POLICY_FIRST_DAY =
        'First Day of Next Period';

    private static final String POLICY_NEXT_OPEN =
        'Next Open Period';

    private static final String POLICY_MANUAL =
        'No Automatic Reversal';

    private static final String PERMISSION =
        'SAB_Reverse_FX_Revaluation';

    private static final String SOURCE_TYPE =
        'FX_Revaluation_Run__c';

    @TestVisible
    private static Boolean lifecycleMutationInProgress =
        false;

    public class ReversalResult {
        @AuraEnabled public Id runId { get; private set; }
        @AuraEnabled public String status { get; private set; }
        @AuraEnabled public Id originalJournalEntryId { get; private set; }
        @AuraEnabled public Id reversalJournalEntryId { get; private set; }
        @AuraEnabled public Id reversalAccountingEventId { get; private set; }
        @AuraEnabled public Id reversalAccountingPeriodId { get; private set; }
        @AuraEnabled public Date reversalAccountingDate { get; private set; }
        @AuraEnabled public Datetime reversedAt { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private ReversalResult() {}
    }

    private class ReversalTarget {
        Id accountingPeriodId;
        Date accountingDate;
    }

    public static Boolean isLifecycleMutationInProgress() {
        return lifecycleMutationInProgress;
    }

    @AuraEnabled
    public static ReversalResult reversePostedRun(
        Id runId,
        Id requestedReversalPeriodId,
        Date requestedReversalDate,
        String requestKey,
        String reason
    ) {
        SABPermissionService.assertPermission(
            PERMISSION,
            'You do not have permission to reverse FX Revaluation runs.'
        );

        validateRequestKey(
            requestKey
        );

        if (String.isBlank(reason)) {
            throw new FXRevaluationReversalException(
                'Reversal Reason is required.'
            );
        }

        ReversalResult replay =
            findReplay(
                runId,
                requestKey
            );

        if (replay != null) {
            return replay;
        }

        Savepoint sp =
            Database.setSavepoint();

        try {
            FX_Revaluation_Run__c run =
                lockRun(
                    runId
                );

            SABCompanyAccessService.assertCompanyAccess(
                run.Company__c
            );

            if (run.Status__c != STATUS_POSTED) {
                throw new FXRevaluationReversalException(
                    'Only a Posted FX Revaluation Run can be reversed.'
                );
            }

            if (run.Journal_Entry__c == null) {
                throw new FXRevaluationReversalException(
                    'Posted FX Revaluation Run must reference its posted Journal Entry.'
                );
            }

            if (
                run.Reversal_Journal_Entry__c != null
                || run.Reversal_Accounting_Event__c != null
                || run.Reversed_At__c != null
            ) {
                throw new FXRevaluationReversalException(
                    'FX Revaluation Run already contains reversal references but is not marked Reversed.'
                );
            }

            Accounting_Period__c originalPeriod = [
                SELECT Id,
                       Company__c,
                       Start_Date__c,
                       End_Date__c,
                       Status__c
                FROM Accounting_Period__c
                WHERE Id =
                        :run.Accounting_Period__c
                LIMIT 1
            ];

            if (originalPeriod.Company__c != run.Company__c) {
                throw new FXRevaluationReversalException(
                    'FX Revaluation Accounting Period belongs to a different Accounting Company.'
                );
            }

            if (originalPeriod.End_Date__c == null) {
                throw new FXRevaluationReversalException(
                    'Original FX Revaluation Accounting Period requires an End Date.'
                );
            }

            ReversalTarget target =
                resolveReversalTarget(
                    run,
                    originalPeriod,
                    requestedReversalPeriodId,
                    requestedReversalDate
                );

            String identity =
                digest(
                    String.valueOf(
                        run.Id
                    )
                    + '|'
                    + run.Run_Key__c
                    + '|'
                    + String.valueOf(
                        run.Journal_Entry__c
                    )
                    + '|'
                    + String.valueOf(
                        target.accountingPeriodId
                    )
                    + '|'
                    + String.valueOf(
                        target.accountingDate
                    )
                );

            SABReversalService.ReversalRequest reversalRequest =
                new SABReversalService.ReversalRequest();

            reversalRequest.originalJournalEntryId =
                run.Journal_Entry__c;
            reversalRequest.reversalAccountingPeriodId =
                target.accountingPeriodId;
            reversalRequest.reversalAccountingDate =
                target.accountingDate;
            reversalRequest.postingKey =
                'FXREV-RV-POST-'
                + identity;
            reversalRequest.eventKey =
                'FXREV-RV-EVENT-'
                + identity;
            reversalRequest.requestKey =
                'FXREV-RV-REQ-'
                + identity;
            reversalRequest.reason =
                reason.trim();

            SABReversalService.ReversalResult reversalResult =
                SABReversalService.reversePostedJournal(
                    reversalRequest
                );

            lifecycleMutationInProgress =
                true;

            try {
                run.Status__c =
                    STATUS_REVERSED;
                run.Reversal_Journal_Entry__c =
                    reversalResult.reversalJournalEntryId;
                run.Reversal_Accounting_Event__c =
                    reversalResult.reversalAccountingEventId;
                run.Reversed_At__c =
                    System.now();

                update run;
            } finally {
                lifecycleMutationInProgress =
                    false;
            }

            logAction(
                run,
                requestKey,
                reason
            );

            return buildResult(
                run.Id,
                target.accountingPeriodId,
                target.accountingDate,
                false
            );
        } catch (Exception ex) {
            Database.rollback(
                sp
            );
            throw ex;
        }
    }

    private static ReversalTarget resolveReversalTarget(
        FX_Revaluation_Run__c run,
        Accounting_Period__c originalPeriod,
        Id requestedPeriodId,
        Date requestedDate
    ) {
        if (
            run.Reversal_Policy__c
                == POLICY_FIRST_DAY
        ) {
            Date nextDate =
                originalPeriod.End_Date__c.addDays(
                    1
                );

            List<Accounting_Period__c> periods = [
                SELECT Id,
                       Start_Date__c,
                       End_Date__c,
                       Status__c
                FROM Accounting_Period__c
                WHERE Company__c =
                        :run.Company__c
                  AND Start_Date__c =
                        :nextDate
                LIMIT 2
            ];

            if (periods.size() != 1) {
                throw new FXRevaluationReversalException(
                    'First Day of Next Period policy requires exactly one immediately following Accounting Period.'
                );
            }

            Accounting_Period__c period =
                periods[0];

            assertOpenPeriod(
                period,
                nextDate
            );

            if (
                requestedPeriodId != null
                && requestedPeriodId != period.Id
            ) {
                throw new FXRevaluationReversalException(
                    'Requested reversal period does not match the First Day of Next Period policy.'
                );
            }

            if (
                requestedDate != null
                && requestedDate != nextDate
            ) {
                throw new FXRevaluationReversalException(
                    'Requested reversal date does not match the First Day of Next Period policy.'
                );
            }

            return target(
                period.Id,
                nextDate
            );
        }

        if (
            run.Reversal_Policy__c
                == POLICY_NEXT_OPEN
        ) {
            List<Accounting_Period__c> periods = [
                SELECT Id,
                       Start_Date__c,
                       End_Date__c,
                       Status__c
                FROM Accounting_Period__c
                WHERE Company__c =
                        :run.Company__c
                  AND Start_Date__c >
                        :originalPeriod.End_Date__c
                  AND Status__c =
                        'Open'
                ORDER BY Start_Date__c ASC
                LIMIT 1
            ];

            if (periods.isEmpty()) {
                throw new FXRevaluationReversalException(
                    'Next Open Period policy could not find a later Open Accounting Period.'
                );
            }

            Accounting_Period__c period =
                periods[0];

            Date reversalDate =
                period.Start_Date__c;

            assertOpenPeriod(
                period,
                reversalDate
            );

            if (
                requestedPeriodId != null
                && requestedPeriodId != period.Id
            ) {
                throw new FXRevaluationReversalException(
                    'Requested reversal period does not match the Next Open Period policy.'
                );
            }

            if (
                requestedDate != null
                && requestedDate != reversalDate
            ) {
                throw new FXRevaluationReversalException(
                    'Requested reversal date does not match the Next Open Period policy.'
                );
            }

            return target(
                period.Id,
                reversalDate
            );
        }

        if (
            run.Reversal_Policy__c
                == POLICY_MANUAL
        ) {
            if (
                requestedPeriodId == null
                || requestedDate == null
            ) {
                throw new FXRevaluationReversalException(
                    'No Automatic Reversal policy requires an explicit reversal Accounting Period and Date.'
                );
            }

            Accounting_Period__c period = [
                SELECT Id,
                       Company__c,
                       Start_Date__c,
                       End_Date__c,
                       Status__c
                FROM Accounting_Period__c
                WHERE Id =
                        :requestedPeriodId
                LIMIT 1
            ];

            if (period.Company__c != run.Company__c) {
                throw new FXRevaluationReversalException(
                    'Manual reversal Accounting Period must belong to the FX Revaluation Accounting Company.'
                );
            }

            if (
                requestedDate
                    <= originalPeriod.End_Date__c
            ) {
                throw new FXRevaluationReversalException(
                    'Manual FX Revaluation reversal must be dated after the original revaluation period.'
                );
            }

            assertOpenPeriod(
                period,
                requestedDate
            );

            return target(
                period.Id,
                requestedDate
            );
        }

        throw new FXRevaluationReversalException(
            'FX Revaluation Run has an unsupported Reversal Policy.'
        );
    }

    private static void assertOpenPeriod(
        Accounting_Period__c period,
        Date accountingDate
    ) {
        if (period.Status__c != 'Open') {
            throw new FXRevaluationReversalException(
                'FX Revaluation reversal requires an Open Accounting Period.'
            );
        }

        if (
            accountingDate < period.Start_Date__c
            || accountingDate > period.End_Date__c
        ) {
            throw new FXRevaluationReversalException(
                'FX Revaluation reversal date must fall inside the selected Accounting Period.'
            );
        }
    }

    private static ReversalTarget target(
        Id periodId,
        Date accountingDate
    ) {
        ReversalTarget value =
            new ReversalTarget();

        value.accountingPeriodId =
            periodId;
        value.accountingDate =
            accountingDate;

        return value;
    }

    private static FX_Revaluation_Run__c lockRun(
        Id runId
    ) {
        if (runId == null) {
            throw new FXRevaluationReversalException(
                'FX Revaluation Run Id is required.'
            );
        }

        return [
            SELECT Id,
                   Company__c,
                   Accounting_Period__c,
                   Journal_Entry__c,
                   Rate_Set_Key__c,
                   Reversal_Policy__c,
                   Run_Key__c,
                   Status__c,
                   Approved_Snapshot_Hash__c,
                   Reversal_Journal_Entry__c,
                   Reversal_Accounting_Event__c,
                   Reversed_At__c
            FROM FX_Revaluation_Run__c
            WHERE Id = :runId
            LIMIT 1
            FOR UPDATE
        ];
    }

    private static ReversalResult findReplay(
        Id runId,
        String requestKey
    ) {
        if (
            runId == null
            || String.isBlank(
                requestKey
            )
        ) {
            return null;
        }

        List<Business_Action__c> actions = [
            SELECT Id,
                   Action__c,
                   Source_Type__c,
                   Source_Record_Id__c
            FROM Business_Action__c
            WHERE Request_Key__c =
                    :requestKey.trim()
            LIMIT 1
        ];

        if (actions.isEmpty()) {
            return null;
        }

        Business_Action__c action =
            actions[0];

        if (
            action.Action__c
                != 'FX Revaluation Reversed'
            || action.Source_Type__c
                != SOURCE_TYPE
            || action.Source_Record_Id__c
                != String.valueOf(
                    runId
                )
        ) {
            throw new FXRevaluationReversalException(
                'Request Key was already used for a different FX Revaluation action.'
            );
        }

        FX_Revaluation_Run__c run = [
            SELECT Id,
                   Accounting_Period__c,
                   Journal_Entry__c,
                   Reversal_Journal_Entry__c,
                   Reversal_Accounting_Event__c,
                   Reversed_At__c,
                   Status__c
            FROM FX_Revaluation_Run__c
            WHERE Id = :runId
            LIMIT 1
        ];

        if (
            run.Status__c
                != STATUS_REVERSED
            || run.Reversal_Journal_Entry__c
                == null
        ) {
            throw new FXRevaluationReversalException(
                'Reversal request was previously processed, but the FX Revaluation Run is not in the expected Reversed state.'
            );
        }

        Journal_Entry__c reversalJournal = [
            SELECT Accounting_Period__c,
                   Accounting_Date__c
            FROM Journal_Entry__c
            WHERE Id =
                    :run.Reversal_Journal_Entry__c
            LIMIT 1
        ];

        return buildResult(
            run.Id,
            reversalJournal.Accounting_Period__c,
            reversalJournal.Accounting_Date__c,
            true
        );
    }

    private static void logAction(
        FX_Revaluation_Run__c run,
        String requestKey,
        String reason
    ) {
        insert new Business_Action__c(
            Company__c =
                run.Company__c,
            Action__c =
                'FX Revaluation Reversed',
            Actor__c =
                UserInfo.getUserId(),
            Action_At__c =
                System.now(),
            Reason__c =
                reason.trim(),
            Request_Key__c =
                requestKey.trim(),
            Source_Type__c =
                SOURCE_TYPE,
            Source_Record_Id__c =
                String.valueOf(
                    run.Id
                ),
            Source_Version__c =
                1
        );
    }

    private static ReversalResult buildResult(
        Id runId,
        Id reversalPeriodId,
        Date reversalDate,
        Boolean replay
    ) {
        FX_Revaluation_Run__c run = [
            SELECT Id,
                   Status__c,
                   Journal_Entry__c,
                   Reversal_Journal_Entry__c,
                   Reversal_Accounting_Event__c,
                   Reversed_At__c
            FROM FX_Revaluation_Run__c
            WHERE Id = :runId
            LIMIT 1
        ];

        ReversalResult result =
            new ReversalResult();

        result.runId =
            run.Id;
        result.status =
            run.Status__c;
        result.originalJournalEntryId =
            run.Journal_Entry__c;
        result.reversalJournalEntryId =
            run.Reversal_Journal_Entry__c;
        result.reversalAccountingEventId =
            run.Reversal_Accounting_Event__c;
        result.reversalAccountingPeriodId =
            reversalPeriodId;
        result.reversalAccountingDate =
            reversalDate;
        result.reversedAt =
            run.Reversed_At__c;
        result.replay =
            replay;

        return result;
    }

    private static void validateRequestKey(
        String requestKey
    ) {
        if (String.isBlank(requestKey)) {
            throw new FXRevaluationReversalException(
                'Request Key is required.'
            );
        }

        Integer maxLength =
            Business_Action__c.Request_Key__c
                .getDescribe()
                .getLength();

        if (
            requestKey.trim().length()
                > maxLength
        ) {
            throw new FXRevaluationReversalException(
                'Request Key cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static String digest(
        String value
    ) {
        return EncodingUtil.convertToHex(
            Crypto.generateDigest(
                'SHA-256',
                Blob.valueOf(
                    value == null
                        ? ''
                        : value
                )
            )
        );
    }
}
