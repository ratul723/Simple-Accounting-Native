/**
 * Simple Accounting Books - Accounting Event Service.
 *
 * Exact Accounting_Event__c fields used:
 * - Company__c
 * - Adapter_Key__c
 * - Created_Request_Key__c
 * - Event_Key__c
 * - Event_Type__c
 * - Journal_Entry__c
 * - Source_Business_Key__c
 * - Source_Record_Id__c
 * - Source_Type__c
 * - Source_Version__c
 * - State__c
 *
 * Step 3A integration:
 * - SABPermissionService / SAB_Post_Journal
 * - SABCompanyAccessService
 *
 * This service owns the accounting-event envelope and idempotency contract.
 * It does NOT create journal lines or perform debit/credit validation.
 * Those responsibilities belong to SABJournalValidationService and
 * SABPostingService in the next steps.
 */
public without sharing class SABAccountingEventService {

    public class AccountingEventException extends Exception {}

    private static final String POST_PERMISSION = 'SAB_Post_Journal';
    private static final String STATE_RESERVED = 'Reserved';
    private static final String STATE_POSTED = 'Posted';

    public class ReservationRequest {
        public Id companyId { get; set; }
        public String adapterKey { get; set; }
        public String requestKey { get; set; }
        public String eventKey { get; set; }
        public String eventType { get; set; }
        public String sourceBusinessKey { get; set; }
        public String sourceRecordId { get; set; }
        public String sourceType { get; set; }
        public Integer sourceVersion { get; set; }
    }

    public class EventResult {
        public Id accountingEventId { get; private set; }
        public Id journalEntryId { get; private set; }
        public String eventKey { get; private set; }
        public String state { get; private set; }
        public Boolean replay { get; private set; }

        private EventResult(
            Accounting_Event__c eventRecord,
            Boolean wasReplay
        ) {
            accountingEventId = eventRecord.Id;
            journalEntryId = eventRecord.Journal_Entry__c;
            eventKey = eventRecord.Event_Key__c;
            state = eventRecord.State__c;
            replay = wasReplay;
        }
    }

    /**
     * Reserves a unique Accounting_Event__c before posting.
     *
     * If the same compatible Event_Key__c already exists, this method returns
     * the original event with replay=true instead of creating a duplicate.
     */
    public static EventResult reserveForPosting(
        ReservationRequest request
    ) {
        assertPostPermission();
        validateReservationRequest(request);
        SABCompanyAccessService.assertCompanyAccess(request.companyId);
        assertEventCreateAccess();

        Accounting_Event__c existing =
            loadByEventKeyForUpdate(request.eventKey);

        if (existing != null) {
            assertReplayCompatible(existing, request);
            return new EventResult(existing, true);
        }

        Accounting_Event__c eventRecord = new Accounting_Event__c(
            Company__c = request.companyId,
            Adapter_Key__c = request.adapterKey.trim(),
            Created_Request_Key__c =
                trimToNull(request.requestKey),
            Event_Key__c = request.eventKey.trim(),
            Event_Type__c = request.eventType.trim(),
            Source_Business_Key__c =
                trimToNull(request.sourceBusinessKey),
            Source_Record_Id__c =
                trimToNull(request.sourceRecordId),
            Source_Type__c = request.sourceType.trim(),
            Source_Version__c = request.sourceVersion,
            State__c = STATE_RESERVED
        );

        Database.SaveResult result =
            Database.insert(eventRecord, false);

        if (result.isSuccess()) {
            return new EventResult(eventRecord, false);
        }

        Boolean duplicateKey = false;
        Database.Error firstError;

        for (Database.Error errorValue : result.getErrors()) {
            if (firstError == null) {
                firstError = errorValue;
            }

            if (
                errorValue.getStatusCode()
                == StatusCode.DUPLICATE_VALUE
            ) {
                duplicateKey = true;
            }
        }

        // Handles a concurrent transaction that inserted the same unique
        // Event_Key__c after our first lookup.
        if (duplicateKey) {
            Accounting_Event__c concurrentEvent =
                loadByEventKeyForUpdate(request.eventKey);

            if (concurrentEvent != null) {
                assertReplayCompatible(
                    concurrentEvent,
                    request
                );

                return new EventResult(
                    concurrentEvent,
                    true
                );
            }
        }

        throw new AccountingEventException(
            'Unable to reserve Accounting Event.'
            + (
                firstError == null
                    ? ''
                    : ' '
                        + firstError.getStatusCode()
                        + ': '
                        + firstError.getMessage()
            )
        );
    }

    /**
     * Called by SABPostingService after it has created a complete Posted
     * Journal_Entry__c linked to this Accounting Event.
     */
    public static EventResult attachPostedJournal(
        Id accountingEventId,
        Id journalEntryId
    ) {
        assertPostPermission();

        if (accountingEventId == null) {
            throw new AccountingEventException(
                'Accounting Event Id is required.'
            );
        }

        if (journalEntryId == null) {
            throw new AccountingEventException(
                'Journal Entry Id is required.'
            );
        }

        assertEventUpdateAccess();
        assertJournalReadAccess();

        Accounting_Event__c eventRecord = [
            SELECT Id,
                   Company__c,
                   Event_Key__c,
                   State__c,
                   Journal_Entry__c
            FROM Accounting_Event__c
            WHERE Id = :accountingEventId
            LIMIT 1
            FOR UPDATE
        ];

        SABCompanyAccessService.assertCompanyAccess(
            eventRecord.Company__c
        );

        Journal_Entry__c journal = [
            SELECT Id,
                   Company__c,
                   Status__c,
                   Accounting_Event__c
            FROM Journal_Entry__c
            WHERE Id = :journalEntryId
            LIMIT 1
            FOR UPDATE
        ];

        if (journal.Company__c != eventRecord.Company__c) {
            throw new AccountingEventException(
                'Journal Entry and Accounting Event must belong to the same Accounting Company.'
            );
        }

        if (journal.Status__c != STATE_POSTED) {
            throw new AccountingEventException(
                'Journal Entry must be Posted before the Accounting Event is completed.'
            );
        }

        if (journal.Accounting_Event__c != eventRecord.Id) {
            throw new AccountingEventException(
                'Journal Entry must reference this Accounting Event.'
            );
        }

        if (eventRecord.State__c == STATE_POSTED) {
            if (eventRecord.Journal_Entry__c == journal.Id) {
                return new EventResult(
                    eventRecord,
                    true
                );
            }

            throw new AccountingEventException(
                'Accounting Event is already linked to a different posted Journal Entry.'
            );
        }

        if (eventRecord.State__c != STATE_RESERVED) {
            throw new AccountingEventException(
                'Only a Reserved Accounting Event can transition to Posted.'
            );
        }

        eventRecord.Journal_Entry__c = journal.Id;
        eventRecord.State__c = STATE_POSTED;
        update eventRecord;

        return new EventResult(
            eventRecord,
            false
        );
    }

    private static void assertPostPermission() {
        SABPermissionService.assertPermission(
            POST_PERMISSION,
            'You do not have permission to post accounting transactions.'
        );
    }

    private static void validateReservationRequest(
        ReservationRequest request
    ) {
        if (request == null) {
            throw new AccountingEventException(
                'Reservation request is required.'
            );
        }

        if (request.companyId == null) {
            throw new AccountingEventException(
                'Accounting Company Id is required.'
            );
        }

        requireText(request.adapterKey, 'Adapter Key');
        requireText(request.eventKey, 'Event Key');
        requireText(request.eventType, 'Event Type');
        requireText(request.sourceType, 'Source Type');

        if (request.sourceVersion == null) {
            throw new AccountingEventException(
                'Source Version is required.'
            );
        }

        assertFieldLength(
            request.adapterKey,
            Accounting_Event__c.Adapter_Key__c,
            'Adapter Key'
        );

        assertFieldLength(
            request.requestKey,
            Accounting_Event__c.Created_Request_Key__c,
            'Created Request Key'
        );

        assertFieldLength(
            request.eventKey,
            Accounting_Event__c.Event_Key__c,
            'Event Key'
        );

        assertFieldLength(
            request.sourceBusinessKey,
            Accounting_Event__c.Source_Business_Key__c,
            'Source Business Key'
        );

        assertFieldLength(
            request.sourceRecordId,
            Accounting_Event__c.Source_Record_Id__c,
            'Source Record Id'
        );

        assertFieldLength(
            request.sourceType,
            Accounting_Event__c.Source_Type__c,
            'Source Type'
        );

        if (
            !activeEventTypeValues().contains(
                request.eventType.trim()
            )
        ) {
            throw new AccountingEventException(
                'Event Type is not an active Accounting Event type.'
            );
        }
    }

    private static Accounting_Event__c loadByEventKeyForUpdate(
        String eventKey
    ) {
        List<Accounting_Event__c> events = [
            SELECT Id,
                   Company__c,
                   Adapter_Key__c,
                   Created_Request_Key__c,
                   Event_Key__c,
                   Event_Type__c,
                   Journal_Entry__c,
                   Source_Business_Key__c,
                   Source_Record_Id__c,
                   Source_Type__c,
                   Source_Version__c,
                   State__c
            FROM Accounting_Event__c
            WHERE Event_Key__c = :eventKey
            LIMIT 1
            FOR UPDATE
        ];

        return events.isEmpty()
            ? null
            : events[0];
    }

    private static void assertReplayCompatible(
        Accounting_Event__c existing,
        ReservationRequest request
    ) {
        Boolean compatible =
            existing.Company__c == request.companyId
            && sameRequiredText(
                existing.Adapter_Key__c,
                request.adapterKey
            )
            && sameRequiredText(
                existing.Event_Type__c,
                request.eventType
            )
            && sameRequiredText(
                existing.Source_Type__c,
                request.sourceType
            )
            && existing.Source_Version__c
                == request.sourceVersion
            && sameOptionalText(
                existing.Source_Business_Key__c,
                request.sourceBusinessKey
            )
            && sameOptionalText(
                existing.Source_Record_Id__c,
                request.sourceRecordId
            );

        if (!compatible) {
            throw new AccountingEventException(
                'Event Key already exists for different accounting-event identity data.'
            );
        }
    }

    private static Set<String> activeEventTypeValues() {
        Set<String> activeValues = new Set<String>();

        for (
            Schema.PicklistEntry value :
            Accounting_Event__c.Event_Type__c
                .getDescribe()
                .getPicklistValues()
        ) {
            if (value.isActive()) {
                activeValues.add(value.getValue());
            }
        }

        return activeValues;
    }

    private static void assertEventCreateAccess() {
        Schema.DescribeSObjectResult objectDescribe =
            Accounting_Event__c.SObjectType.getDescribe();

        if (
            !objectDescribe.isAccessible()
            || !objectDescribe.isCreateable()
        ) {
            throw new AccountingEventException(
                'You do not have required access to Accounting Events.'
            );
        }

        assertReadableCreateable(
            Accounting_Event__c.Company__c,
            'Accounting Event Company'
        );
        assertReadableCreateable(
            Accounting_Event__c.Adapter_Key__c,
            'Adapter Key'
        );
        assertReadableCreateable(
            Accounting_Event__c.Created_Request_Key__c,
            'Created Request Key'
        );
        assertReadableCreateable(
            Accounting_Event__c.Event_Key__c,
            'Event Key'
        );
        assertReadableCreateable(
            Accounting_Event__c.Event_Type__c,
            'Event Type'
        );
        assertReadableCreateable(
            Accounting_Event__c.Source_Business_Key__c,
            'Source Business Key'
        );
        assertReadableCreateable(
            Accounting_Event__c.Source_Record_Id__c,
            'Source Record Id'
        );
        assertReadableCreateable(
            Accounting_Event__c.Source_Type__c,
            'Source Type'
        );
        assertReadableCreateable(
            Accounting_Event__c.Source_Version__c,
            'Source Version'
        );
        assertReadableCreateable(
            Accounting_Event__c.State__c,
            'Accounting Event State'
        );
    }

    private static void assertEventUpdateAccess() {
        Schema.DescribeSObjectResult objectDescribe =
            Accounting_Event__c.SObjectType.getDescribe();

        if (
            !objectDescribe.isAccessible()
            || !objectDescribe.isUpdateable()
        ) {
            throw new AccountingEventException(
                'You do not have required update access to Accounting Events.'
            );
        }

        assertReadable(
            Accounting_Event__c.Company__c,
            'Accounting Event Company'
        );
        assertReadableUpdateable(
            Accounting_Event__c.Journal_Entry__c,
            'Accounting Event Journal Entry'
        );
        assertReadableUpdateable(
            Accounting_Event__c.State__c,
            'Accounting Event State'
        );
    }

    private static void assertJournalReadAccess() {
        if (
            !Journal_Entry__c.SObjectType
                .getDescribe()
                .isAccessible()
        ) {
            throw new AccountingEventException(
                'You do not have read access to Journal Entries.'
            );
        }

        assertReadable(
            Journal_Entry__c.Company__c,
            'Journal Entry Company'
        );
        assertReadable(
            Journal_Entry__c.Status__c,
            'Journal Entry Status'
        );
        assertReadable(
            Journal_Entry__c.Accounting_Event__c,
            'Journal Entry Accounting Event'
        );
    }

    private static void assertReadable(
        Schema.SObjectField fieldToken,
        String fieldLabel
    ) {
        if (!fieldToken.getDescribe().isAccessible()) {
            throw new AccountingEventException(
                'You do not have read access to '
                + fieldLabel
                + '.'
            );
        }
    }

    private static void assertReadableCreateable(
        Schema.SObjectField fieldToken,
        String fieldLabel
    ) {
        Schema.DescribeFieldResult fieldDescribe =
            fieldToken.getDescribe();

        if (
            !fieldDescribe.isAccessible()
            || !fieldDescribe.isCreateable()
        ) {
            throw new AccountingEventException(
                'You do not have required field access to '
                + fieldLabel
                + '.'
            );
        }
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
            throw new AccountingEventException(
                'You do not have required field access to '
                + fieldLabel
                + '.'
            );
        }
    }

    private static void assertFieldLength(
        String value,
        Schema.SObjectField fieldToken,
        String fieldLabel
    ) {
        if (value == null) {
            return;
        }

        Integer maxLength =
            fieldToken.getDescribe().getLength();

        if (
            maxLength > 0
            && value.length() > maxLength
        ) {
            throw new AccountingEventException(
                fieldLabel
                + ' cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static void requireText(
        String value,
        String fieldLabel
    ) {
        if (String.isBlank(value)) {
            throw new AccountingEventException(
                fieldLabel + ' is required.'
            );
        }
    }

    private static String trimToNull(String value) {
        return String.isBlank(value)
            ? null
            : value.trim();
    }

    private static Boolean sameRequiredText(
        String storedValue,
        String requestedValue
    ) {
        return storedValue
            == (
                requestedValue == null
                    ? null
                    : requestedValue.trim()
            );
    }

    private static Boolean sameOptionalText(
        String storedValue,
        String requestedValue
    ) {
        return trimToNull(storedValue)
            == trimToNull(requestedValue);
    }
}
