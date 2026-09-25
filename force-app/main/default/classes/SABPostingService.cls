/**
 * Simple Accounting Books - Posting Service.
 *
 * Sequential ledger step after:
 * - SABCompanyAccessService
 * - SABPermissionService
 * - SABAccountingEventService
 * - SABJournalValidationService
 *
 * Current scope:
 * Posts an already-persisted Draft Journal_Entry__c atomically.
 *
 * Exact Journal_Entry__c fields used:
 * - Company__c
 * - Accounting_Period__c
 * - Accounting_Date__c
 * - Status__c
 * - Posting_Key__c
 * - Accounting_Event__c
 * - Posted_By__c
 * - Posted_At__c
 * - Version__c
 *
 * The next subledger phase can add proposal-based journal creation on top of
 * this same protected posting contract.
 */
public without sharing class SABPostingService {

    public class PostingException extends Exception {}

    private static final String POST_PERMISSION = 'SAB_Post_Journal';
    private static final String STATUS_DRAFT = 'Draft';
    private static final String STATUS_POSTED = 'Posted';
    private static final String EVENT_STATE_RESERVED = 'Reserved';
    private static final String EVENT_STATE_POSTED = 'Posted';

    public class PostingRequest {
        public Id journalEntryId { get; set; }
        public String postingKey { get; set; }
        public SABAccountingEventService.ReservationRequest eventRequest {
            get;
            set;
        }
    }

    public class PostingResult {
        public Id journalEntryId { get; private set; }
        public Id accountingEventId { get; private set; }
        public String postingKey { get; private set; }
        public Datetime postedAt { get; private set; }
        public Boolean replay { get; private set; }

        private PostingResult(
            Journal_Entry__c journal,
            Id eventId,
            Boolean wasReplay
        ) {
            journalEntryId = journal.Id;
            accountingEventId = eventId;
            postingKey = journal.Posting_Key__c;
            postedAt = journal.Posted_At__c;
            replay = wasReplay;
        }
    }

    /**
     * Posts one existing Draft Journal Entry.
     *
     * Transaction contract:
     * 1. Require SAB_Post_Journal.
     * 2. Assert current-user company access.
     * 3. Lock the Accounting Period, then the Journal Entry.
     * 4. Reserve/replay the Accounting Event.
     * 5. Re-run journal validation while locks are held.
     * 6. Mark the journal Posted.
     * 7. Link/complete the Accounting Event.
     *
     * A savepoint guarantees that callers cannot accidentally retain a
     * Reserved event or partially-posted journal if they catch an exception.
     */
    public static PostingResult postDraftJournal(
        PostingRequest request
    ) {
        validateRequestShape(request);

        SABPermissionService.assertPermission(
            POST_PERMISSION,
            'You do not have permission to post accounting transactions.'
        );

        assertJournalUpdateAccess();

        Journal_Entry__c initialJournal = [
            SELECT Id,
                   Company__c,
                   Accounting_Period__c,
                   Accounting_Date__c,
                   Entry_Type__c,
                   Status__c,
                   Posting_Key__c,
                   Accounting_Event__c,
                   Posted_By__c,
                   Posted_At__c,
                   Version__c
            FROM Journal_Entry__c
            WHERE Id = :request.journalEntryId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(
            initialJournal.Company__c
        );

        validatePostingKeyLength(request.postingKey);

        if (initialJournal.Status__c == STATUS_POSTED) {
            return resolvePostedReplay(
                initialJournal,
                request
            );
        }

        if (initialJournal.Status__c != STATUS_DRAFT) {
            throw new PostingException(
                'Only a Draft Journal Entry can be posted.'
            );
        }

        Savepoint savepointValue = Database.setSavepoint();

        try {
            if (initialJournal.Accounting_Period__c != null) {
                // Period lock protects posting against a concurrent close.
                Accounting_Period__c lockedPeriod = [
                    SELECT Id
                    FROM Accounting_Period__c
                    WHERE Id = :initialJournal.Accounting_Period__c
                    LIMIT 1
                    FOR UPDATE
                ];
            }

            Journal_Entry__c journal = [
                SELECT Id,
                       Company__c,
                       Accounting_Period__c,
                       Accounting_Date__c,
                       Entry_Type__c,
                       Status__c,
                       Posting_Key__c,
                       Accounting_Event__c,
                       Posted_By__c,
                       Posted_At__c,
                       Version__c
                FROM Journal_Entry__c
                WHERE Id = :request.journalEntryId
                LIMIT 1
                FOR UPDATE
            ];

            if (
                journal.Accounting_Period__c
                != initialJournal.Accounting_Period__c
            ) {
                throw new PostingException(
                    'Journal Entry changed while posting. Retry the posting request.'
                );
            }

            SABCompanyAccessService.assertCompanyAccess(
                journal.Company__c
            );

            if (journal.Status__c == STATUS_POSTED) {
                return resolvePostedReplay(
                    journal,
                    request
                );
            }

            if (journal.Status__c != STATUS_DRAFT) {
                throw new PostingException(
                    'Only a Draft Journal Entry can be posted.'
                );
            }

            if (
                !String.isBlank(journal.Posting_Key__c)
                && journal.Posting_Key__c
                    != request.postingKey.trim()
            ) {
                throw new PostingException(
                    'Journal Entry already contains a different Posting Key.'
                );
            }

            assertControlAccountPostingPolicy(
                journal
            );

            SABAccountingEventService.ReservationRequest
                normalizedEventRequest =
                    normalizeEventRequest(
                        request.eventRequest,
                        journal
                    );

            SABAccountingEventService.EventResult eventResult =
                SABAccountingEventService.reserveForPosting(
                    normalizedEventRequest
                );

            if (eventResult.state == EVENT_STATE_POSTED) {
                if (
                    eventResult.journalEntryId == journal.Id
                    && journal.Status__c == STATUS_POSTED
                ) {
                    return new PostingResult(
                        journal,
                        eventResult.accountingEventId,
                        true
                    );
                }

                throw new PostingException(
                    'The Accounting Event is already posted to another Journal Entry.'
                );
            }

            if (eventResult.state != EVENT_STATE_RESERVED) {
                throw new PostingException(
                    'Accounting Event must be Reserved before posting.'
                );
            }

            if (
                journal.Accounting_Event__c != null
                && journal.Accounting_Event__c
                    != eventResult.accountingEventId
            ) {
                throw new PostingException(
                    'Journal Entry is already linked to a different Accounting Event.'
                );
            }

            // Recheck all accounting invariants while period/journal locks
            // are held.
            SABJournalValidationService.assertValidForPosting(
                journal.Id
            );

            Datetime postedTimestamp = System.now();

            journal.Status__c = STATUS_POSTED;
            journal.Posting_Key__c =
                request.postingKey.trim();
            journal.Accounting_Event__c =
                eventResult.accountingEventId;
            journal.Posted_By__c =
                UserInfo.getUserId();
            journal.Posted_At__c =
                postedTimestamp;

            SABLedgerMutationContext.beginPosting();

            try {
                update journal;
            } finally {
                SABLedgerMutationContext.endPosting();
            }

            SABAccountingEventService.EventResult completedEvent =
                SABAccountingEventService.attachPostedJournal(
                    eventResult.accountingEventId,
                    journal.Id
                );

            // Return values from the same committed in-memory journal.
            journal.Posted_At__c = postedTimestamp;

            return new PostingResult(
                journal,
                completedEvent.accountingEventId,
                eventResult.replay
            );
        } catch (Exception ex) {
            Database.rollback(savepointValue);
            throw ex;
        }
    }

    private static PostingResult resolvePostedReplay(
        Journal_Entry__c journal,
        PostingRequest request
    ) {
        if (
            journal.Posting_Key__c
            != request.postingKey.trim()
        ) {
            throw new PostingException(
                'Journal Entry is already Posted using a different Posting Key.'
            );
        }

        if (journal.Accounting_Event__c == null) {
            throw new PostingException(
                'Posted Journal Entry is missing its Accounting Event link.'
            );
        }

        Accounting_Event__c eventRecord = [
            SELECT Id,
                   Company__c,
                   Event_Key__c,
                   Source_Type__c,
                   Source_Record_Id__c,
                   State__c,
                   Journal_Entry__c
            FROM Accounting_Event__c
            WHERE Id = :journal.Accounting_Event__c
            LIMIT 1
        ];

        if (
            eventRecord.Company__c != journal.Company__c
            || eventRecord.Event_Key__c
                != request.eventRequest.eventKey.trim()
            || eventRecord.Source_Type__c
                != request.eventRequest.sourceType.trim()
            || (
                !String.isBlank(request.eventRequest.sourceRecordId)
                && eventRecord.Source_Record_Id__c
                    != request.eventRequest.sourceRecordId.trim()
            )
            || eventRecord.State__c != EVENT_STATE_POSTED
            || eventRecord.Journal_Entry__c != journal.Id
        ) {
            throw new PostingException(
                'Posted Journal Entry does not match the supplied accounting event request.'
            );
        }

        return new PostingResult(
            journal,
            eventRecord.Id,
            true
        );
    }

    /**
     * G3B hardening:
     * - Manual/Opening style posting must not use protected control accounts.
     * - Trusted Subledger journals are allowed to use configured control
     *   accounts and are still validated by SABJournalValidationService.
     *
     * This guard is intentionally explicit in SABPostingService so adding
     * subledger support cannot accidentally weaken the existing manual
     * control-account rule.
     */
    private static void assertControlAccountPostingPolicy(
        Journal_Entry__c journal
    ) {
        if (journal.Entry_Type__c == 'Subledger') {
            return;
        }

        List<Journal_Entry_Line__c> blockedLines = [
            SELECT Id,
                   GL_Account__c,
                   GL_Account__r.Account_Code__c,
                   GL_Account__r.Name
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__c = :journal.Id
              AND GL_Account__r.Is_Control_Account__c = true
              AND GL_Account__r.Manual_Posting_Allowed__c = false
            LIMIT 1
        ];

        if (blockedLines.isEmpty()) {
            return;
        }

        Journal_Entry_Line__c blockedLine =
            blockedLines[0];

        String accountLabel =
            String.isBlank(
                blockedLine.GL_Account__r.Account_Code__c
            )
                ? blockedLine.GL_Account__r.Name
                : blockedLine.GL_Account__r.Account_Code__c
                    + ' - '
                    + blockedLine.GL_Account__r.Name;

        throw new PostingException(
            'GL Account '
            + accountLabel
            + ' is a control account and does not allow manual/opening posting.'
        );
    }

    private static SABAccountingEventService.ReservationRequest
        normalizeEventRequest(
            SABAccountingEventService.ReservationRequest sourceRequest,
            Journal_Entry__c journal
        ) {

        if (sourceRequest.companyId != journal.Company__c) {
            throw new PostingException(
                'Accounting Event Company must match the Journal Entry Company.'
            );
        }

        String journalIdText = String.valueOf(journal.Id);
        String normalizedSourceRecordId;

        if (journal.Entry_Type__c == 'Subledger') {
            if (String.isBlank(sourceRequest.sourceRecordId)) {
                throw new PostingException(
                    'Subledger posting requires the Accounting Event Source Record Id.'
                );
            }

            normalizedSourceRecordId =
                sourceRequest.sourceRecordId.trim();
        } else {
            if (
                !String.isBlank(sourceRequest.sourceRecordId)
                && sourceRequest.sourceRecordId.trim()
                    != journalIdText
            ) {
                throw new PostingException(
                    'Accounting Event Source Record Id must match the Journal Entry for non-subledger posting.'
                );
            }

            normalizedSourceRecordId =
                journalIdText;
        }

        SABAccountingEventService.ReservationRequest normalized =
            new SABAccountingEventService.ReservationRequest();

        normalized.companyId =
            sourceRequest.companyId;
        normalized.adapterKey =
            sourceRequest.adapterKey;
        normalized.requestKey =
            sourceRequest.requestKey;
        normalized.eventKey =
            sourceRequest.eventKey;
        normalized.eventType =
            sourceRequest.eventType;
        normalized.sourceBusinessKey =
            sourceRequest.sourceBusinessKey;
        normalized.sourceRecordId =
            normalizedSourceRecordId;
        normalized.sourceType =
            sourceRequest.sourceType;
        normalized.sourceVersion =
            sourceRequest.sourceVersion;

        return normalized;
    }

    private static void validateRequestShape(
        PostingRequest request
    ) {
        if (request == null) {
            throw new PostingException(
                'Posting request is required.'
            );
        }

        if (request.journalEntryId == null) {
            throw new PostingException(
                'Journal Entry Id is required.'
            );
        }

        if (String.isBlank(request.postingKey)) {
            throw new PostingException(
                'Posting Key is required.'
            );
        }

        if (request.eventRequest == null) {
            throw new PostingException(
                'Accounting Event request is required.'
            );
        }

        if (String.isBlank(request.eventRequest.eventKey)) {
            throw new PostingException(
                'Accounting Event Key is required.'
            );
        }
    }

    private static void validatePostingKeyLength(
        String postingKey
    ) {
        Integer maxLength =
            Journal_Entry__c.Posting_Key__c.getDescribe().getLength();

        if (
            postingKey != null
            && maxLength > 0
            && postingKey.trim().length() > maxLength
        ) {
            throw new PostingException(
                'Posting Key cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static void assertJournalUpdateAccess() {
        Schema.DescribeSObjectResult objectDescribe =
            Journal_Entry__c.SObjectType.getDescribe();

        if (
            !objectDescribe.isAccessible()
            || !objectDescribe.isUpdateable()
        ) {
            throw new PostingException(
                'You do not have required access to post Journal Entries.'
            );
        }

        assertReadableUpdateable(
            Journal_Entry__c.Status__c,
            'Journal Entry Status'
        );
        assertReadableUpdateable(
            Journal_Entry__c.Posting_Key__c,
            'Journal Entry Posting Key'
        );
        assertReadableUpdateable(
            Journal_Entry__c.Accounting_Event__c,
            'Journal Entry Accounting Event'
        );
        assertReadableUpdateable(
            Journal_Entry__c.Posted_By__c,
            'Journal Entry Posted By'
        );
        assertReadableUpdateable(
            Journal_Entry__c.Posted_At__c,
            'Journal Entry Posted At'
        );
    }

    private static void assertReadableUpdateable(
        Schema.SObjectField fieldToken,
        String fieldLabel
    ) {
        Schema.DescribeFieldResult fieldDescribe =
            fieldToken.getDescribe();

        if (
            !fieldDescribe.isAccessible()
            || !fieldDescribe.isUpdateable()
        ) {
            throw new PostingException(
                'You do not have required field access to '
                + fieldLabel
                + '.'
            );
        }
    }
}
