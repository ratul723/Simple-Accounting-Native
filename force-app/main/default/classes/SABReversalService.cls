/**
 * Simple Accounting Books - Reversal Service.
 *
 * Corrections never edit posted financial lines. This service creates and
 * posts a new reversing Journal Entry whose debits/credits are the exact
 * opposite of the original posted Journal Entry.
 *
 * Security:
 * - requires SAB_Reverse_Journal
 * - SABPostingService also requires SAB_Post_Journal
 * - requires SABCompanyAccessService access to the original company
 *
 * Traceability:
 * Original Journal.Reversal_Journal__c -> reversal journal
 * Reversal Journal.Reversal_Of__c      -> original journal
 * Original Event.Reversal_Event__c     -> reversal accounting event
 * Original Event.State__c              -> Reversed
 * Original Journal.Status__c           -> Reversed
 */
public without sharing class SABReversalService {

    public class ReversalException extends Exception {}

    private static final String REVERSE_PERMISSION =
        'SAB_Reverse_Journal';

    private static final String STATUS_POSTED = 'Posted';
    private static final String STATUS_REVERSED = 'Reversed';
    private static final String PERIOD_OPEN = 'Open';

    public class ReversalRequest {
        public Id originalJournalEntryId { get; set; }
        public Id reversalAccountingPeriodId { get; set; }
        public Date reversalAccountingDate { get; set; }
        public String postingKey { get; set; }
        public String eventKey { get; set; }
        public String requestKey { get; set; }
        public String reason { get; set; }
    }

    public class ReversalResult {
        public Id originalJournalEntryId { get; private set; }
        public Id reversalJournalEntryId { get; private set; }
        public Id reversalAccountingEventId { get; private set; }
        public Boolean replay { get; private set; }

        private ReversalResult(
            Id originalJournalId,
            Id reversalJournalId,
            Id reversalEventId,
            Boolean wasReplay
        ) {
            originalJournalEntryId = originalJournalId;
            reversalJournalEntryId = reversalJournalId;
            reversalAccountingEventId = reversalEventId;
            replay = wasReplay;
        }
    }

    public static ReversalResult reversePostedJournal(
        ReversalRequest request
    ) {
        validateRequest(request);

        SABPermissionService.assertPermission(
            REVERSE_PERMISSION,
            'You do not have permission to reverse Journal Entries.'
        );

        assertRequiredAccess();

        // Keep lock order consistent with posting: period first, then journal.
        Accounting_Period__c reversalPeriod = [
            SELECT Id,
                   Company__c,
                   Start_Date__c,
                   End_Date__c,
                   Status__c
            FROM Accounting_Period__c
            WHERE Id = :request.reversalAccountingPeriodId
            LIMIT 1
            FOR UPDATE
        ];

        Journal_Entry__c originalJournal = [
            SELECT Id,
                   Company__c,
                   Accounting_Period__c,
                   Accounting_Date__c,
                   Entry_Type__c,
                   Status__c,
                   Posting_Key__c,
                   Description__c,
                   Accounting_Event__c,
                   Reversal_Of__c,
                   Reversal_Journal__c,
                   Version__c
            FROM Journal_Entry__c
            WHERE Id = :request.originalJournalEntryId
            LIMIT 1
            FOR UPDATE
        ];

        SABCompanyAccessService.assertCompanyAccess(
            originalJournal.Company__c
        );

        if (originalJournal.Status__c == STATUS_REVERSED) {
            return resolveExistingReversal(
                originalJournal,
                request
            );
        }

        if (originalJournal.Status__c != STATUS_POSTED) {
            throw new ReversalException(
                'Only a Posted Journal Entry can be reversed.'
            );
        }

        if (originalJournal.Reversal_Of__c != null) {
            throw new ReversalException(
                'A reversal journal cannot be reversed by this service. Reverse the replacement/correction event instead.'
            );
        }

        if (originalJournal.Reversal_Journal__c != null) {
            throw new ReversalException(
                'Journal Entry already references a reversal journal but is not marked Reversed.'
            );
        }

        if (originalJournal.Accounting_Event__c == null) {
            throw new ReversalException(
                'Posted Journal Entry must have an Accounting Event before it can be reversed.'
            );
        }

        validateReversalPeriod(
            originalJournal,
            reversalPeriod,
            request.reversalAccountingDate
        );

        Accounting_Event__c originalEvent = [
            SELECT Id,
                   Company__c,
                   Event_Key__c,
                   State__c,
                   Reversal_Event__c
            FROM Accounting_Event__c
            WHERE Id = :originalJournal.Accounting_Event__c
            LIMIT 1
            FOR UPDATE
        ];

        if (originalEvent.Company__c != originalJournal.Company__c) {
            throw new ReversalException(
                'Original Accounting Event must belong to the same Accounting Company as the Journal Entry.'
            );
        }

        if (originalEvent.State__c != STATUS_POSTED) {
            throw new ReversalException(
                'Original Accounting Event must be Posted before reversal.'
            );
        }

        if (originalEvent.Reversal_Event__c != null) {
            throw new ReversalException(
                'Original Accounting Event already references a reversal event.'
            );
        }

        List<Journal_Entry_Line__c> originalLines = [
            SELECT Id,
                   Line_Number__c,
                   GL_Account__c,
                   Debit_Base__c,
                   Credit_Base__c,
                   Explanation__c,
                   Functional_Currency__c,
                   Transaction_Currency__c,
                   Transaction_Amount__c,
                   Applied_Exchange_Rate__c,
                   Rate_Date__c,
                   Rate_Source__c,
                   Department__c,
                   Cost_Center__c,
                   Project__c,
                   Dimension_Snapshot__c,
                   Source_Line_Key__c
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__c = :originalJournal.Id
            ORDER BY Line_Number__c ASC, Id ASC
        ];

        if (originalLines.isEmpty()) {
            throw new ReversalException(
                'Posted Journal Entry has no financial lines to reverse.'
            );
        }

        Savepoint sp = Database.setSavepoint();

        try {
            Journal_Entry__c reversalJournal =
                createReversalJournal(
                    originalJournal,
                    request
                );

            insert reversalJournal;

            insert buildReversalLines(
                reversalJournal.Id,
                originalLines
            );

            SABPostingService.PostingRequest postingRequest =
                buildPostingRequest(
                    originalJournal,
                    reversalJournal,
                    request
                );

            SABPostingService.PostingResult postingResult =
                SABPostingService.postDraftJournal(
                    postingRequest
                );

            originalJournal.Status__c =
                STATUS_REVERSED;
            originalJournal.Reversal_Journal__c =
                postingResult.journalEntryId;

            SABLedgerMutationContext.beginReversal();

            try {
                update originalJournal;
            } finally {
                SABLedgerMutationContext.endReversal();
            }

            originalEvent.State__c =
                STATUS_REVERSED;
            originalEvent.Reversal_Event__c =
                postingResult.accountingEventId;

            update originalEvent;

            return new ReversalResult(
                originalJournal.Id,
                postingResult.journalEntryId,
                postingResult.accountingEventId,
                false
            );
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
    }

    private static Journal_Entry__c createReversalJournal(
        Journal_Entry__c originalJournal,
        ReversalRequest request
    ) {
        String description =
            'Reversal of '
            + (
                String.isBlank(originalJournal.Posting_Key__c)
                    ? String.valueOf(originalJournal.Id)
                    : originalJournal.Posting_Key__c
            );

        if (!String.isBlank(request.reason)) {
            description += ': ' + request.reason.trim();
        }

        description = truncate(
            description,
            Journal_Entry__c.Description__c
                .getDescribe()
                .getLength()
        );

        return new Journal_Entry__c(
            Company__c =
                originalJournal.Company__c,
            Accounting_Period__c =
                request.reversalAccountingPeriodId,
            Accounting_Date__c =
                request.reversalAccountingDate,
            Entry_Type__c =
                'Reversal',
            Status__c =
                'Draft',
            Description__c =
                description,
            Reversal_Of__c =
                originalJournal.Id,
            Version__c =
                1
        );
    }

    private static List<Journal_Entry_Line__c>
        buildReversalLines(
            Id reversalJournalId,
            List<Journal_Entry_Line__c> originalLines
        ) {

        List<Journal_Entry_Line__c> reversalLines =
            new List<Journal_Entry_Line__c>();

        for (Journal_Entry_Line__c originalLine : originalLines) {
            Decimal transactionAmount =
                originalLine.Transaction_Amount__c;

            reversalLines.add(
                new Journal_Entry_Line__c(
                    Journal_Entry__c =
                        reversalJournalId,
                    Line_Number__c =
                        originalLine.Line_Number__c,
                    GL_Account__c =
                        originalLine.GL_Account__c,
                    Debit_Base__c =
                        originalLine.Credit_Base__c,
                    Credit_Base__c =
                        originalLine.Debit_Base__c,
                    Explanation__c =
                        truncate(
                            'Reversal: '
                            + (
                                originalLine.Explanation__c == null
                                    ? ''
                                    : originalLine.Explanation__c
                            ),
                            Journal_Entry_Line__c.Explanation__c
                                .getDescribe()
                                .getLength()
                        ),
                    Functional_Currency__c =
                        originalLine.Functional_Currency__c,
                    Transaction_Currency__c =
                        originalLine.Transaction_Currency__c,
                    Transaction_Amount__c =
                        transactionAmount == null
                            ? null
                            : -transactionAmount,
                    Applied_Exchange_Rate__c =
                        originalLine.Applied_Exchange_Rate__c,
                    Rate_Date__c =
                        originalLine.Rate_Date__c,
                    Rate_Source__c =
                        originalLine.Rate_Source__c,
                    Department__c =
                        originalLine.Department__c,
                    Cost_Center__c =
                        originalLine.Cost_Center__c,
                    Project__c =
                        originalLine.Project__c,
                    Dimension_Snapshot__c =
                        originalLine.Dimension_Snapshot__c,
                    Source_Line_Key__c =
                        'REV:' + String.valueOf(originalLine.Id)
                )
            );
        }

        return reversalLines;
    }

    private static SABPostingService.PostingRequest
        buildPostingRequest(
            Journal_Entry__c originalJournal,
            Journal_Entry__c reversalJournal,
            ReversalRequest request
        ) {

        SABAccountingEventService.ReservationRequest eventRequest =
            new SABAccountingEventService.ReservationRequest();

        eventRequest.companyId =
            originalJournal.Company__c;
        eventRequest.adapterKey =
            'JOURNAL_REVERSAL';
        eventRequest.requestKey =
            request.requestKey;
        eventRequest.eventKey =
            request.eventKey.trim();
        eventRequest.eventType =
            'Reversal';
        eventRequest.sourceBusinessKey =
            request.postingKey.trim();
        eventRequest.sourceRecordId =
            String.valueOf(reversalJournal.Id);
        eventRequest.sourceType =
            'Journal_Entry__c';
        eventRequest.sourceVersion =
            1;

        SABPostingService.PostingRequest postingRequest =
            new SABPostingService.PostingRequest();

        postingRequest.journalEntryId =
            reversalJournal.Id;
        postingRequest.postingKey =
            request.postingKey.trim();
        postingRequest.eventRequest =
            eventRequest;

        return postingRequest;
    }

    private static ReversalResult resolveExistingReversal(
        Journal_Entry__c originalJournal,
        ReversalRequest request
    ) {
        if (originalJournal.Reversal_Journal__c == null) {
            throw new ReversalException(
                'Journal Entry is marked Reversed but has no Reversal Journal.'
            );
        }

        Journal_Entry__c reversalJournal = [
            SELECT Id,
                   Company__c,
                   Status__c,
                   Posting_Key__c,
                   Accounting_Event__c,
                   Reversal_Of__c
            FROM Journal_Entry__c
            WHERE Id = :originalJournal.Reversal_Journal__c
            LIMIT 1
        ];

        if (
            reversalJournal.Company__c
                != originalJournal.Company__c
            || reversalJournal.Status__c
                != STATUS_POSTED
            || reversalJournal.Posting_Key__c
                != request.postingKey.trim()
            || reversalJournal.Reversal_Of__c
                != originalJournal.Id
            || reversalJournal.Accounting_Event__c
                == null
        ) {
            throw new ReversalException(
                'Existing reversal does not match this reversal request.'
            );
        }

        Accounting_Event__c reversalEvent = [
            SELECT Id,
                   Event_Key__c,
                   State__c,
                   Journal_Entry__c
            FROM Accounting_Event__c
            WHERE Id = :reversalJournal.Accounting_Event__c
            LIMIT 1
        ];

        if (
            reversalEvent.Event_Key__c
                != request.eventKey.trim()
            || reversalEvent.State__c
                != STATUS_POSTED
            || reversalEvent.Journal_Entry__c
                != reversalJournal.Id
        ) {
            throw new ReversalException(
                'Existing reversal Accounting Event does not match this reversal request.'
            );
        }

        return new ReversalResult(
            originalJournal.Id,
            reversalJournal.Id,
            reversalEvent.Id,
            true
        );
    }

    private static void validateReversalPeriod(
        Journal_Entry__c originalJournal,
        Accounting_Period__c reversalPeriod,
        Date reversalDate
    ) {
        if (
            reversalPeriod.Company__c
                != originalJournal.Company__c
        ) {
            throw new ReversalException(
                'Reversal Accounting Period must belong to the same Accounting Company.'
            );
        }

        if (reversalPeriod.Status__c != PERIOD_OPEN) {
            throw new ReversalException(
                'Reversal Accounting Period must be Open.'
            );
        }

        if (
            reversalDate
                < reversalPeriod.Start_Date__c
            || reversalDate
                > reversalPeriod.End_Date__c
        ) {
            throw new ReversalException(
                'Reversal Accounting Date must fall within the selected Accounting Period.'
            );
        }
    }

    private static void validateRequest(
        ReversalRequest request
    ) {
        if (request == null) {
            throw new ReversalException(
                'Reversal request is required.'
            );
        }

        if (request.originalJournalEntryId == null) {
            throw new ReversalException(
                'Original Journal Entry Id is required.'
            );
        }

        if (request.reversalAccountingPeriodId == null) {
            throw new ReversalException(
                'Reversal Accounting Period Id is required.'
            );
        }

        if (request.reversalAccountingDate == null) {
            throw new ReversalException(
                'Reversal Accounting Date is required.'
            );
        }

        if (String.isBlank(request.postingKey)) {
            throw new ReversalException(
                'Reversal Posting Key is required.'
            );
        }

        if (String.isBlank(request.eventKey)) {
            throw new ReversalException(
                'Reversal Event Key is required.'
            );
        }

        assertLength(
            request.postingKey,
            Journal_Entry__c.Posting_Key__c,
            'Reversal Posting Key'
        );

        assertLength(
            request.eventKey,
            Accounting_Event__c.Event_Key__c,
            'Reversal Event Key'
        );

        assertLength(
            request.requestKey,
            Accounting_Event__c.Created_Request_Key__c,
            'Reversal Request Key'
        );
    }

    private static void assertRequiredAccess() {
        Schema.DescribeSObjectResult journalDescribe =
            Journal_Entry__c.SObjectType.getDescribe();

        Schema.DescribeSObjectResult lineDescribe =
            Journal_Entry_Line__c.SObjectType.getDescribe();

        Schema.DescribeSObjectResult eventDescribe =
            Accounting_Event__c.SObjectType.getDescribe();

        if (
            !journalDescribe.isAccessible()
            || !journalDescribe.isCreateable()
            || !journalDescribe.isUpdateable()
        ) {
            throw new ReversalException(
                'You do not have required Journal Entry access for reversal.'
            );
        }

        if (
            !lineDescribe.isAccessible()
            || !lineDescribe.isCreateable()
        ) {
            throw new ReversalException(
                'You do not have required Journal Entry Line access for reversal.'
            );
        }

        if (
            !eventDescribe.isAccessible()
            || !eventDescribe.isUpdateable()
        ) {
            throw new ReversalException(
                'You do not have required Accounting Event access for reversal.'
            );
        }
    }

    private static void assertLength(
        String value,
        Schema.SObjectField fieldToken,
        String label
    ) {
        if (value == null) {
            return;
        }

        Integer maxLength =
            fieldToken.getDescribe().getLength();

        if (
            maxLength > 0
            && value.trim().length() > maxLength
        ) {
            throw new ReversalException(
                label
                + ' cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static String truncate(
        String value,
        Integer maxLength
    ) {
        if (
            value == null
            || maxLength <= 0
            || value.length() <= maxLength
        ) {
            return value;
        }

        return value.substring(0, maxLength);
    }
}
