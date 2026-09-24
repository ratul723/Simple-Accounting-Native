/**
 * Simple Accounting Books - Controlled Document Numbering Service.
 *
 * Uses the existing Document_Sequence__c fields:
 * - Company__c
 * - Document_Type__c
 * - Fiscal_Series__c
 * - Prefix__c
 * - Minimum_Digits__c
 * - Next_Number__c
 * - Sequence_Key__c
 * - Is_Active__c
 *
 * Concurrency:
 * The selected sequence row is queried FOR UPDATE before the counter is read
 * and incremented. Competing transactions therefore serialize on that row.
 *
 * Transactional behavior:
 * The number reservation and caller's document issuance should happen in the
 * same Salesforce transaction. If the transaction rolls back, the counter
 * increment rolls back too.
 *
 * Idempotency boundary:
 * Document_Sequence__c currently has no request-key/issuance-history object.
 * Therefore this service does not pretend repeated independent calls are
 * idempotent. The issuing document must store its final legal number and must
 * not call this service again once that number has been committed.
 */
public without sharing class SABSequenceService {

    public class SequenceException extends Exception {}

    private static final Decimal MAX_SEQUENCE_NUMBER =
        Decimal.valueOf('999999999999999999');

    public class ReservationResult {
        public Id sequenceId { get; private set; }
        public Id companyId { get; private set; }
        public String documentType { get; private set; }
        public String fiscalSeries { get; private set; }
        public Decimal reservedNumber { get; private set; }
        public String formattedNumber { get; private set; }
        public Decimal nextNumber { get; private set; }

        private ReservationResult(
            Document_Sequence__c sequenceRecord,
            Decimal numberValue,
            String displayNumber
        ) {
            sequenceId = sequenceRecord.Id;
            companyId = sequenceRecord.Company__c;
            documentType = sequenceRecord.Document_Type__c;
            fiscalSeries = sequenceRecord.Fiscal_Series__c;
            reservedNumber = numberValue;
            formattedNumber = displayNumber;
            nextNumber = sequenceRecord.Next_Number__c;
        }
    }

    public static ReservationResult reserveNextNumber(
        Id companyId,
        String documentType,
        String fiscalSeries
    ) {
        if (companyId == null) {
            throw new SequenceException(
                'Accounting Company Id is required.'
            );
        }

        if (String.isBlank(documentType)) {
            throw new SequenceException(
                'Document Type is required.'
            );
        }

        if (String.isBlank(fiscalSeries)) {
            throw new SequenceException(
                'Fiscal Series is required.'
            );
        }

        SABCompanyAccessService.assertCompanyAccess(
            companyId
        );

        List<Document_Sequence__c> matching = [
            SELECT Id
            FROM Document_Sequence__c
            WHERE Company__c = :companyId
              AND Document_Type__c = :documentType
              AND Fiscal_Series__c = :fiscalSeries
              AND Is_Active__c = true
            LIMIT 2
        ];

        if (matching.isEmpty()) {
            throw new SequenceException(
                'No active Document Sequence exists for the requested company, document type and fiscal series.'
            );
        }

        if (matching.size() > 1) {
            throw new SequenceException(
                'Multiple active Document Sequences exist for the requested company, document type and fiscal series.'
            );
        }

        return reserveNextNumberById(
            matching[0].Id
        );
    }

    public static ReservationResult reserveNextNumberById(
        Id sequenceId
    ) {
        if (sequenceId == null) {
            throw new SequenceException(
                'Document Sequence Id is required.'
            );
        }

        Document_Sequence__c sequenceRecord = [
            SELECT Id,
                   Company__c,
                   Document_Type__c,
                   Fiscal_Series__c,
                   Prefix__c,
                   Minimum_Digits__c,
                   Next_Number__c,
                   Sequence_Key__c,
                   Is_Active__c
            FROM Document_Sequence__c
            WHERE Id = :sequenceId
            LIMIT 1
            FOR UPDATE
        ];

        SABCompanyAccessService.assertCompanyAccess(
            sequenceRecord.Company__c
        );

        validateSequence(sequenceRecord);

        Decimal reserved =
            sequenceRecord.Next_Number__c;

        String formatted =
            formatNumber(
                sequenceRecord.Prefix__c,
                reserved,
                sequenceRecord.Minimum_Digits__c
            );

        sequenceRecord.Next_Number__c =
            reserved + 1;

        SABSequenceMutationContext.beginReservation();

        try {
            update sequenceRecord;
        } finally {
            SABSequenceMutationContext.endReservation();
        }

        return new ReservationResult(
            sequenceRecord,
            reserved,
            formatted
        );
    }

    public static void validateSequence(
        Document_Sequence__c sequenceRecord
    ) {
        if (sequenceRecord == null) {
            throw new SequenceException(
                'Document Sequence is required.'
            );
        }

        if (sequenceRecord.Is_Active__c != true) {
            throw new SequenceException(
                'Document Sequence must be active.'
            );
        }

        if (sequenceRecord.Company__c == null) {
            throw new SequenceException(
                'Document Sequence Company is required.'
            );
        }

        if (String.isBlank(sequenceRecord.Document_Type__c)) {
            throw new SequenceException(
                'Document Sequence Document Type is required.'
            );
        }

        if (String.isBlank(sequenceRecord.Fiscal_Series__c)) {
            throw new SequenceException(
                'Document Sequence Fiscal Series is required.'
            );
        }

        if (String.isBlank(sequenceRecord.Sequence_Key__c)) {
            throw new SequenceException(
                'Document Sequence Key is required.'
            );
        }

        if (
            sequenceRecord.Next_Number__c == null
            || sequenceRecord.Next_Number__c < 1
        ) {
            throw new SequenceException(
                'Document Sequence Next Number must be at least 1.'
            );
        }

        if (
            sequenceRecord.Next_Number__c
            > MAX_SEQUENCE_NUMBER
        ) {
            throw new SequenceException(
                'Document Sequence has exceeded the supported Number(18,0) range.'
            );
        }

        Integer minimumDigits =
            sequenceRecord.Minimum_Digits__c == null
                ? 6
                : sequenceRecord.Minimum_Digits__c.intValue();

        if (
            minimumDigits < 1
            || minimumDigits > 18
        ) {
            throw new SequenceException(
                'Document Sequence Minimum Digits must be between 1 and 18.'
            );
        }
    }

    @TestVisible
    private static String formatNumber(
        String prefix,
        Decimal numberValue,
        Decimal minimumDigitsValue
    ) {
        if (
            numberValue == null
            || numberValue < 0
        ) {
            throw new SequenceException(
                'Sequence number must be zero or greater.'
            );
        }

        Integer minimumDigits =
            minimumDigitsValue == null
                ? 6
                : minimumDigitsValue.intValue();

        if (
            minimumDigits < 1
            || minimumDigits > 18
        ) {
            throw new SequenceException(
                'Minimum Digits must be between 1 and 18.'
            );
        }

        String digits =
            String.valueOf(
                numberValue.setScale(0)
            );

        while (digits.length() < minimumDigits) {
            digits = '0' + digits;
        }

        return (
            String.isBlank(prefix)
                ? ''
                : prefix
        ) + digits;
    }
}
