/**
 * G7B - FX Revaluation Approval & Journal Posting.
 *
 * G7A produces Preview runs and immutable-style FX_Revaluation_Line__c
 * snapshots. G7B:
 * - approves and locks that snapshot,
 * - validates Unrealized FX Gain/Loss configuration,
 * - creates a balanced system-generated subledger journal,
 * - posts through SABPostingService,
 * - reserves/completes Accounting_Event__c with Event Type = FX Revaluation,
 * - links FX_Revaluation_Run__c.Journal_Entry__c,
 * - records Business_Action__c audit events,
 * - provides request-key idempotency.
 *
 * Note: Journal Entry Type is intentionally Subledger because the central
 * SABPostingService currently permits protected AR/AP control-account posting
 * only for trusted Subledger journals. The Accounting Event remains
 * "FX Revaluation", preserving the business-event identity without weakening
 * control-account protection.
 */
public without sharing class SABFXRevaluationPostingService {

    public class FXPostingException extends Exception {}

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    private static final String STATUS_PREVIEW =
        'Preview';

    private static final String STATUS_APPROVED =
        'Approved';

    private static final String STATUS_POSTED =
        'Posted';

    private static final String APPROVE_PERMISSION =
        'SAB_Approve_FX_Revaluation';

    private static final String POST_PERMISSION =
        'SAB_Post_FX_Revaluation';

    private static final String SOURCE_TYPE =
        'FX_Revaluation_Run__c';

    @TestVisible
    private static Boolean lifecycleMutationInProgress =
        false;

    public class LifecycleResult {
        @AuraEnabled public Id runId { get; private set; }
        @AuraEnabled public String status { get; private set; }
        @AuraEnabled public Id journalEntryId { get; private set; }
        @AuraEnabled public Id accountingEventId { get; private set; }
        @AuraEnabled public String approvedSnapshotHash { get; private set; }
        @AuraEnabled public Datetime approvedAt { get; private set; }
        @AuraEnabled public Datetime postedAt { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private LifecycleResult() {}
    }

    public static Boolean isLifecycleMutationInProgress() {
        return lifecycleMutationInProgress;
    }

    @AuraEnabled
    public static LifecycleResult approveRun(
        Id runId,
        String requestKey,
        String reason
    ) {
        SABPermissionService.assertPermission(
            APPROVE_PERMISSION,
            'You do not have permission to approve FX Revaluation runs.'
        );

        validateRequestKey(requestKey);

        LifecycleResult replay =
            findReplay(
                runId,
                requestKey,
                'FX Revaluation Approved'
            );

        if (replay != null) {
            return replay;
        }

        FX_Revaluation_Run__c run =
            lockRun(runId);

        SABCompanyAccessService.assertCompanyAccess(
            run.Company__c
        );

        if (run.Status__c != STATUS_PREVIEW) {
            throw new FXPostingException(
                'Only a Preview FX Revaluation Run can be approved.'
            );
        }

        List<FX_Revaluation_Line__c> lines =
            loadAndValidatePreviewLines(
                run
            );

        String snapshotHash =
            calculateSnapshotHash(
                run,
                lines
            );

        beginMutation();

        try {
            run.Status__c =
                STATUS_APPROVED;
            run.Approved_Snapshot_Hash__c =
                snapshotHash;
            run.Approved_By__c =
                UserInfo.getUserId();
            run.Approved_At__c =
                System.now();

            update run;
        } finally {
            endMutation();
        }

        logAction(
            run,
            'FX Revaluation Approved',
            requestKey,
            reason
        );

        return buildResult(
            run.Id,
            false,
            null
        );
    }

    @AuraEnabled
    public static LifecycleResult postApprovedRun(
        Id runId,
        String requestKey,
        String reason
    ) {
        SABPermissionService.assertPermission(
            POST_PERMISSION,
            'You do not have permission to post FX Revaluation runs.'
        );

        validateRequestKey(requestKey);

        LifecycleResult replay =
            findReplay(
                runId,
                requestKey,
                'FX Revaluation Posted'
            );

        if (replay != null) {
            return replay;
        }

        Savepoint sp =
            Database.setSavepoint();

        try {
            FX_Revaluation_Run__c run =
                lockRun(runId);

            SABCompanyAccessService.assertCompanyAccess(
                run.Company__c
            );

            if (run.Status__c != STATUS_APPROVED) {
                throw new FXPostingException(
                    'Only an Approved FX Revaluation Run can be posted.'
                );
            }

            if (
                String.isBlank(
                    run.Approved_Snapshot_Hash__c
                )
            ) {
                throw new FXPostingException(
                    'Approved FX Revaluation Run is missing its approved snapshot hash.'
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
                        :run.Accounting_Period__c
                LIMIT 1
            ];

            if (
                period.Company__c
                    != run.Company__c
            ) {
                throw new FXPostingException(
                    'FX Revaluation Accounting Period belongs to a different Accounting Company.'
                );
            }

            if (period.Status__c != 'Open') {
                throw new FXPostingException(
                    'FX Revaluation Accounting Period must be Open before posting.'
                );
            }

            if (period.End_Date__c == null) {
                throw new FXPostingException(
                    'FX Revaluation Accounting Period End Date is required.'
                );
            }

            List<FX_Revaluation_Line__c> lines =
                loadAndValidatePreviewLines(
                    run
                );

            String currentHash =
                calculateSnapshotHash(
                    run,
                    lines
                );

            if (
                currentHash
                    != run.Approved_Snapshot_Hash__c
            ) {
                throw new FXPostingException(
                    'FX Revaluation preview changed after approval. Rebuild and approve a controlled preview before posting.'
                );
            }

            Accounting_Company__c company = [
                SELECT Id,
                       Functional_Currency__c,
                       Unrealized_FX_Gain_Account__c,
                       Unrealized_FX_Loss_Account__c
                FROM Accounting_Company__c
                WHERE Id = :run.Company__c
                LIMIT 1
            ];

            validateFXAccounts(
                company
            );

            Journal_Entry__c journal =
                new Journal_Entry__c(
                    Company__c =
                        run.Company__c,
                    Accounting_Period__c =
                        run.Accounting_Period__c,
                    Accounting_Date__c =
                        period.End_Date__c,
                    Entry_Type__c =
                        'Subledger',
                    Status__c =
                        'Draft',
                    Description__c =
                        truncate(
                            'FX Revaluation '
                            + run.Run_Key__c,
                            Journal_Entry__c.Description__c
                                .getDescribe()
                                .getLength()
                        ),
                    Version__c =
                        1
                );

            insert journal;

            insert buildJournalLines(
                journal.Id,
                company,
                lines,
                period.End_Date__c
            );

            String identityHash =
                digest(
                    String.valueOf(
                        run.Id
                    )
                    + '|'
                    + run.Run_Key__c
                    + '|'
                    + run.Approved_Snapshot_Hash__c
                );

            SABAccountingEventService.ReservationRequest eventRequest =
                new SABAccountingEventService.ReservationRequest();

            eventRequest.companyId =
                run.Company__c;
            eventRequest.adapterKey =
                'FX_REVALUATION';
            eventRequest.requestKey =
                requestKey.trim();
            eventRequest.eventKey =
                'FXREV-EVENT-'
                + identityHash;
            eventRequest.eventType =
                'FX Revaluation';
            eventRequest.sourceBusinessKey =
                truncate(
                    run.Run_Key__c,
                    Accounting_Event__c.Source_Business_Key__c
                        .getDescribe()
                        .getLength()
                );
            eventRequest.sourceRecordId =
                String.valueOf(
                    run.Id
                );
            eventRequest.sourceType =
                SOURCE_TYPE;
            eventRequest.sourceVersion =
                1;

            SABPostingService.PostingRequest postingRequest =
                new SABPostingService.PostingRequest();

            postingRequest.journalEntryId =
                journal.Id;
            postingRequest.postingKey =
                'FXREV-POST-'
                + identityHash;
            postingRequest.eventRequest =
                eventRequest;

            SABPostingService.PostingResult postingResult =
                SABPostingService.postDraftJournal(
                    postingRequest
                );

            beginMutation();

            try {
                run.Journal_Entry__c =
                    postingResult.journalEntryId;
                run.Posted_At__c =
                    System.now();
                run.Status__c =
                    STATUS_POSTED;

                update run;
            } finally {
                endMutation();
            }

            logAction(
                run,
                'FX Revaluation Posted',
                requestKey,
                reason
            );

            return buildResult(
                run.Id,
                false,
                postingResult.accountingEventId
            );
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
    }

    private static FX_Revaluation_Run__c lockRun(
        Id runId
    ) {
        if (runId == null) {
            throw new FXPostingException(
                'FX Revaluation Run Id is required.'
            );
        }

        return [
            SELECT Id,
                   Name,
                   Company__c,
                   Accounting_Period__c,
                   Journal_Entry__c,
                   Rate_Set_Key__c,
                   Reversal_Policy__c,
                   Run_Key__c,
                   Status__c,
                   Approved_Snapshot_Hash__c,
                   Approved_By__c,
                   Approved_At__c,
                   Posted_At__c
            FROM FX_Revaluation_Run__c
            WHERE Id = :runId
            LIMIT 1
            FOR UPDATE
        ];
    }

    private static List<FX_Revaluation_Line__c>
        loadAndValidatePreviewLines(
            FX_Revaluation_Run__c run
        )
    {
        List<FX_Revaluation_Line__c> lines = [
            SELECT Id,
                   Source_Type__c,
                   Source_Record_Id__c,
                   Source_GL_Account__c,
                   Source_GL_Account__r.Company__c,
                   Source_GL_Account__r.Is_Active__c,
                   Source_GL_Account__r.Is_Control_Account__c,
                   Source_GL_Account__r.Control_Type__c,
                   Transaction_Currency__c,
                   Outstanding_Amount__c,
                   Carrying_Amount__c,
                   Revalued_Amount__c,
                   Adjustment_Amount__c,
                   Applied_Rate__c,
                   Exchange_Rate__c
            FROM FX_Revaluation_Line__c
            WHERE FX_Revaluation_Run__c =
                    :run.Id
            ORDER BY Source_Type__c,
                     Source_Record_Id__c,
                     Id
        ];

        if (lines.isEmpty()) {
            throw new FXPostingException(
                'FX Revaluation Run has no non-zero preview lines to approve or post.'
            );
        }

        for (FX_Revaluation_Line__c line : lines) {
            if (
                String.isBlank(
                    line.Source_Type__c
                )
                || String.isBlank(
                    line.Source_Record_Id__c
                )
            ) {
                throw new FXPostingException(
                    'Every FX Revaluation Line requires source identity.'
                );
            }

            if (
                line.Source_Type__c
                    != 'Invoice__c'
                && line.Source_Type__c
                    != 'Supplier_Bill__c'
            ) {
                throw new FXPostingException(
                    'G7B supports Invoice__c and Supplier_Bill__c FX sources only.'
                );
            }

            if (
                line.Source_GL_Account__c
                    == null
                || line.Source_GL_Account__r
                    == null
                || line.Source_GL_Account__r.Company__c
                    != run.Company__c
                || line.Source_GL_Account__r.Is_Active__c
                    != true
                || line.Source_GL_Account__r.Is_Control_Account__c
                    != true
            ) {
                throw new FXPostingException(
                    'FX Revaluation source GL Account must be an active control account in the selected Accounting Company.'
                );
            }

            if (
                line.Source_Type__c
                    == 'Invoice__c'
                && line.Source_GL_Account__r.Control_Type__c
                    != 'AR'
            ) {
                throw new FXPostingException(
                    'Invoice FX Revaluation source account must be an AR control account.'
                );
            }

            if (
                line.Source_Type__c
                    == 'Supplier_Bill__c'
                && line.Source_GL_Account__r.Control_Type__c
                    != 'AP'
            ) {
                throw new FXPostingException(
                    'Supplier Bill FX Revaluation source account must be an AP control account.'
                );
            }

            if (
                String.isBlank(
                    line.Transaction_Currency__c
                )
                || line.Outstanding_Amount__c
                    == null
                || line.Outstanding_Amount__c
                    <= ZERO
                || line.Carrying_Amount__c
                    == null
                || line.Carrying_Amount__c
                    <= ZERO
                || line.Revalued_Amount__c
                    == null
                || line.Revalued_Amount__c
                    <= ZERO
                || line.Adjustment_Amount__c
                    == null
                || line.Adjustment_Amount__c
                    == ZERO
                || line.Applied_Rate__c
                    == null
                || line.Applied_Rate__c
                    <= ZERO
                || line.Exchange_Rate__c
                    == null
            ) {
                throw new FXPostingException(
                    'FX Revaluation Line contains an incomplete or invalid approved-rate snapshot.'
                );
            }
        }

        return lines;
    }

    private static void validateFXAccounts(
        Accounting_Company__c company
    ) {
        if (
            company.Unrealized_FX_Gain_Account__c
                == null
            || company.Unrealized_FX_Loss_Account__c
                == null
        ) {
            throw new FXPostingException(
                'Accounting Company requires both Unrealized FX Gain and Unrealized FX Loss accounts before posting.'
            );
        }

        if (
            company.Unrealized_FX_Gain_Account__c
                == company.Unrealized_FX_Loss_Account__c
        ) {
            throw new FXPostingException(
                'Unrealized FX Gain and Unrealized FX Loss accounts must be different GL Accounts.'
            );
        }

        Map<Id, GL_Account__c> accounts =
            new Map<Id, GL_Account__c>([
                SELECT Id,
                       Company__c,
                       Account_Type__c,
                       Is_Active__c,
                       Is_Control_Account__c
                FROM GL_Account__c
                WHERE Id IN :new Set<Id>{
                    company.Unrealized_FX_Gain_Account__c,
                    company.Unrealized_FX_Loss_Account__c
                }
            ]);

        GL_Account__c gain =
            accounts.get(
                company.Unrealized_FX_Gain_Account__c
            );

        GL_Account__c loss =
            accounts.get(
                company.Unrealized_FX_Loss_Account__c
            );

        if (
            gain == null
            || gain.Company__c
                != company.Id
            || gain.Is_Active__c
                != true
            || gain.Is_Control_Account__c
                == true
            || gain.Account_Type__c
                != 'Revenue'
        ) {
            throw new FXPostingException(
                'Unrealized FX Gain Account must be an active non-control Revenue account in the Accounting Company.'
            );
        }

        if (
            loss == null
            || loss.Company__c
                != company.Id
            || loss.Is_Active__c
                != true
            || loss.Is_Control_Account__c
                == true
            || loss.Account_Type__c
                != 'Expense'
        ) {
            throw new FXPostingException(
                'Unrealized FX Loss Account must be an active non-control Expense account in the Accounting Company.'
            );
        }
    }

    private static List<Journal_Entry_Line__c>
        buildJournalLines(
            Id journalId,
            Accounting_Company__c company,
            List<FX_Revaluation_Line__c> sourceLines,
            Date accountingDate
        )
    {
        List<Journal_Entry_Line__c> result =
            new List<Journal_Entry_Line__c>();

        Decimal gainCredit =
            ZERO;

        Decimal lossDebit =
            ZERO;

        Integer lineNumber =
            1;

        String functionalCurrency =
            SABMoneyService.normalizeCurrencyCode(
                company.Functional_Currency__c
            );

        for (FX_Revaluation_Line__c source : sourceLines) {
            Decimal adjustment =
                SABMoneyService.normalizeLedgerAmount(
                    source.Adjustment_Amount__c,
                    RoundingMode.HALF_UP
                );

            if (adjustment == ZERO) {
                continue;
            }

            Decimal magnitude =
                adjustment.abs();

            Journal_Entry_Line__c journalLine =
                new Journal_Entry_Line__c(
                    Journal_Entry__c =
                        journalId,
                    Line_Number__c =
                        lineNumber,
                    GL_Account__c =
                        source.Source_GL_Account__c,
                    Debit_Base__c =
                        adjustment > ZERO
                            ? magnitude
                            : ZERO,
                    Credit_Base__c =
                        adjustment < ZERO
                            ? magnitude
                            : ZERO,
                    Functional_Currency__c =
                        functionalCurrency,
                    Explanation__c =
                        truncate(
                            'FX revaluation '
                            + source.Source_Type__c
                            + ' '
                            + source.Source_Record_Id__c,
                            Journal_Entry_Line__c.Explanation__c
                                .getDescribe()
                                .getLength()
                        ),
                    Source_Line_Key__c =
                        truncate(
                            'FXSRC:'
                            + String.valueOf(
                                source.Id
                            ),
                            Journal_Entry_Line__c.Source_Line_Key__c
                                .getDescribe()
                                .getLength()
                        )
                );

            result.add(
                journalLine
            );

            if (adjustment > ZERO) {
                gainCredit +=
                    magnitude;
            } else {
                lossDebit +=
                    magnitude;
            }

            lineNumber++;
        }

        gainCredit =
            SABMoneyService.normalizeLedgerAmount(
                gainCredit,
                RoundingMode.HALF_UP
            );

        lossDebit =
            SABMoneyService.normalizeLedgerAmount(
                lossDebit,
                RoundingMode.HALF_UP
            );

        if (gainCredit > ZERO) {
            result.add(
                new Journal_Entry_Line__c(
                    Journal_Entry__c =
                        journalId,
                    Line_Number__c =
                        lineNumber,
                    GL_Account__c =
                        company.Unrealized_FX_Gain_Account__c,
                    Debit_Base__c =
                        ZERO,
                    Credit_Base__c =
                        gainCredit,
                    Functional_Currency__c =
                        functionalCurrency,
                    Explanation__c =
                        'Unrealized FX gain',
                    Source_Line_Key__c =
                        'FX:UNREALIZED:GAIN'
                )
            );

            lineNumber++;
        }

        if (lossDebit > ZERO) {
            result.add(
                new Journal_Entry_Line__c(
                    Journal_Entry__c =
                        journalId,
                    Line_Number__c =
                        lineNumber,
                    GL_Account__c =
                        company.Unrealized_FX_Loss_Account__c,
                    Debit_Base__c =
                        lossDebit,
                    Credit_Base__c =
                        ZERO,
                    Functional_Currency__c =
                        functionalCurrency,
                    Explanation__c =
                        'Unrealized FX loss',
                    Source_Line_Key__c =
                        'FX:UNREALIZED:LOSS'
                )
            );
        }

        if (result.size() < 2) {
            throw new FXPostingException(
                'FX Revaluation did not produce a postable balanced journal.'
            );
        }

        return result;
    }

    private static String calculateSnapshotHash(
        FX_Revaluation_Run__c run,
        List<FX_Revaluation_Line__c> lines
    ) {
        List<String> values =
            new List<String>();

        values.add(
            'RUN='
            + String.valueOf(
                run.Id
            )
        );

        values.add(
            'COMPANY='
            + String.valueOf(
                run.Company__c
            )
        );

        values.add(
            'PERIOD='
            + String.valueOf(
                run.Accounting_Period__c
            )
        );

        values.add(
            'RATESET='
            + String.valueOf(
                run.Rate_Set_Key__c
            )
        );

        for (FX_Revaluation_Line__c line : lines) {
            values.add(
                String.valueOf(
                    line.Id
                )
                + '|'
                + String.valueOf(
                    line.Source_Type__c
                )
                + '|'
                + String.valueOf(
                    line.Source_Record_Id__c
                )
                + '|'
                + String.valueOf(
                    line.Source_GL_Account__c
                )
                + '|'
                + String.valueOf(
                    line.Transaction_Currency__c
                )
                + '|'
                + decimalText(
                    line.Outstanding_Amount__c
                )
                + '|'
                + decimalText(
                    line.Carrying_Amount__c
                )
                + '|'
                + decimalText(
                    line.Revalued_Amount__c
                )
                + '|'
                + decimalText(
                    line.Adjustment_Amount__c
                )
                + '|'
                + String.valueOf(
                    line.Applied_Rate__c
                )
                + '|'
                + String.valueOf(
                    line.Exchange_Rate__c
                )
            );
        }

        return digest(
            String.join(
                values,
                '\n'
            )
        );
    }

    private static LifecycleResult findReplay(
        Id runId,
        String requestKey,
        String actionName
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
                != actionName
            || action.Source_Type__c
                != SOURCE_TYPE
            || action.Source_Record_Id__c
                != String.valueOf(
                    runId
                )
        ) {
            throw new FXPostingException(
                'Request Key was already used for a different FX Revaluation action.'
            );
        }

        return buildResult(
            runId,
            true,
            null
        );
    }

    private static void logAction(
        FX_Revaluation_Run__c run,
        String actionName,
        String requestKey,
        String reason
    ) {
        insert new Business_Action__c(
            Company__c =
                run.Company__c,
            Action__c =
                actionName,
            Actor__c =
                UserInfo.getUserId(),
            Action_At__c =
                System.now(),
            Reason__c =
                reason,
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

    private static LifecycleResult buildResult(
        Id runId,
        Boolean replay,
        Id explicitEventId
    ) {
        FX_Revaluation_Run__c run = [
            SELECT Id,
                   Status__c,
                   Journal_Entry__c,
                   Approved_Snapshot_Hash__c,
                   Approved_At__c,
                   Posted_At__c
            FROM FX_Revaluation_Run__c
            WHERE Id = :runId
            LIMIT 1
        ];

        Id eventId =
            explicitEventId;

        if (
            eventId == null
            && run.Journal_Entry__c
                != null
        ) {
            List<Journal_Entry__c> journals = [
                SELECT Accounting_Event__c
                FROM Journal_Entry__c
                WHERE Id =
                        :run.Journal_Entry__c
                LIMIT 1
            ];

            if (!journals.isEmpty()) {
                eventId =
                    journals[0].Accounting_Event__c;
            }
        }

        LifecycleResult result =
            new LifecycleResult();

        result.runId =
            run.Id;
        result.status =
            run.Status__c;
        result.journalEntryId =
            run.Journal_Entry__c;
        result.accountingEventId =
            eventId;
        result.approvedSnapshotHash =
            run.Approved_Snapshot_Hash__c;
        result.approvedAt =
            run.Approved_At__c;
        result.postedAt =
            run.Posted_At__c;
        result.replay =
            replay;

        return result;
    }

    private static void validateRequestKey(
        String requestKey
    ) {
        if (String.isBlank(requestKey)) {
            throw new FXPostingException(
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
            throw new FXPostingException(
                'Request Key cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static String decimalText(
        Decimal value
    ) {
        Decimal normalized =
            (value == null
                ? ZERO
                : value)
            .setScale(
                4,
                RoundingMode.HALF_UP
            );

        return String.valueOf(
            normalized
        );
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

    private static String truncate(
        String value,
        Integer maxLength
    ) {
        if (
            value == null
            || maxLength <= 0
            || value.length()
                <= maxLength
        ) {
            return value;
        }

        return value.substring(
            0,
            maxLength
        );
    }

    private static void beginMutation() {
        lifecycleMutationInProgress =
            true;
    }

    private static void endMutation() {
        lifecycleMutationInProgress =
            false;
    }
}
