/**
 * Protects the financial ledger after posting.
 *
 * Rules:
 * - Draft journal headers may be edited normally.
 * - Draft -> Posted is allowed only inside SABPostingService.
 * - Posted -> Reversed is allowed only inside SABReversalService and only the
 *   reversal-link/status fields may change.
 * - Posted/Reversed journal headers cannot otherwise be edited or deleted.
 * - Financial lines may only be inserted/edited/deleted while their parent
 *   journal is Draft.
 */
public without sharing class SABJournalImmutabilityService {

    private static final String STATUS_DRAFT = 'Draft';
    private static final String STATUS_POSTED = 'Posted';
    private static final String STATUS_REVERSED = 'Reversed';

    public static void beforeJournalUpdate(
        List<Journal_Entry__c> newRecords,
        Map<Id, Journal_Entry__c> oldMap
    ) {
        for (Journal_Entry__c newRecord : newRecords) {
            Journal_Entry__c oldRecord =
                oldMap.get(newRecord.Id);

            if (oldRecord == null) {
                continue;
            }

            if (oldRecord.Status__c == STATUS_REVERSED) {
                newRecord.addError(
                    'Reversed Journal Entries are immutable.'
                );
                continue;
            }

            if (oldRecord.Status__c == STATUS_POSTED) {
                if (!SABLedgerMutationContext.isReversal()) {
                    newRecord.addError(
                        'Posted Journal Entries are immutable. Use the reversal process to correct a posted journal.'
                    );
                    continue;
                }

                if (
                    newRecord.Status__c != STATUS_REVERSED
                    || newRecord.Reversal_Journal__c == null
                    || financialHeaderChanged(
                        oldRecord,
                        newRecord
                    )
                ) {
                    newRecord.addError(
                        'A reversal may only change the posted journal to Reversed and link its Reversal Journal.'
                    );
                }

                continue;
            }

            if (
                oldRecord.Status__c == STATUS_DRAFT
                && newRecord.Status__c == STATUS_POSTED
                && !SABLedgerMutationContext.isPosting()
            ) {
                newRecord.addError(
                    'A Journal Entry can only be posted through SABPostingService.'
                );
                continue;
            }

            if (
                newRecord.Status__c == STATUS_REVERSED
                && !SABLedgerMutationContext.isReversal()
            ) {
                newRecord.addError(
                    'A Journal Entry can only be reversed through SABReversalService.'
                );
            }
        }
    }

    public static void beforeJournalDelete(
        List<Journal_Entry__c> oldRecords
    ) {
        for (Journal_Entry__c oldRecord : oldRecords) {
            if (
                oldRecord.Status__c == STATUS_POSTED
                || oldRecord.Status__c == STATUS_REVERSED
            ) {
                oldRecord.addError(
                    'Posted or Reversed Journal Entries cannot be deleted.'
                );
            }
        }
    }

    public static void beforeLineInsert(
        List<Journal_Entry_Line__c> newRecords
    ) {
        validateLineParents(
            newRecords,
            null,
            'insert'
        );
    }

    public static void beforeLineUpdate(
        List<Journal_Entry_Line__c> newRecords,
        Map<Id, Journal_Entry_Line__c> oldMap
    ) {
        validateLineParents(
            newRecords,
            oldMap,
            'update'
        );
    }

    public static void beforeLineDelete(
        List<Journal_Entry_Line__c> oldRecords
    ) {
        validateLineParents(
            oldRecords,
            null,
            'delete'
        );
    }

    private static void validateLineParents(
        List<Journal_Entry_Line__c> records,
        Map<Id, Journal_Entry_Line__c> oldMap,
        String operationName
    ) {
        Set<Id> journalIds = new Set<Id>();

        for (Journal_Entry_Line__c line : records) {
            if (line.Journal_Entry__c != null) {
                journalIds.add(line.Journal_Entry__c);
            }

            if (
                oldMap != null
                && oldMap.containsKey(line.Id)
                && oldMap.get(line.Id).Journal_Entry__c != null
            ) {
                journalIds.add(
                    oldMap.get(line.Id).Journal_Entry__c
                );
            }
        }

        if (journalIds.isEmpty()) {
            return;
        }

        Map<Id, Journal_Entry__c> journals =
            new Map<Id, Journal_Entry__c>([
                SELECT Id, Status__c
                FROM Journal_Entry__c
                WHERE Id IN :journalIds
            ]);

        for (Journal_Entry_Line__c line : records) {
            Id currentJournalId =
                line.Journal_Entry__c;

            Id oldJournalId =
                (
                    oldMap != null
                    && oldMap.containsKey(line.Id)
                )
                    ? oldMap.get(line.Id).Journal_Entry__c
                    : null;

            if (
                parentIsProtected(
                    currentJournalId,
                    journals
                )
                || parentIsProtected(
                    oldJournalId,
                    journals
                )
            ) {
                line.addError(
                    'Journal Entry Lines are immutable after posting. You cannot '
                    + operationName
                    + ' a financial line for a Posted or Reversed Journal Entry.'
                );
            }
        }
    }

    private static Boolean parentIsProtected(
        Id journalId,
        Map<Id, Journal_Entry__c> journals
    ) {
        if (
            journalId == null
            || !journals.containsKey(journalId)
        ) {
            return false;
        }

        String statusValue =
            journals.get(journalId).Status__c;

        return statusValue == STATUS_POSTED
            || statusValue == STATUS_REVERSED;
    }

    /**
     * On the original posted journal, reversal is only allowed to change:
     * - Status__c: Posted -> Reversed
     * - Reversal_Journal__c: null -> reversal journal
     *
     * All accounting identity, amounts/source links and posting audit values
     * remain frozen.
     */
    private static Boolean financialHeaderChanged(
        Journal_Entry__c oldRecord,
        Journal_Entry__c newRecord
    ) {
        return oldRecord.Company__c
                != newRecord.Company__c
            || oldRecord.Accounting_Period__c
                != newRecord.Accounting_Period__c
            || oldRecord.Accounting_Date__c
                != newRecord.Accounting_Date__c
            || oldRecord.Entry_Type__c
                != newRecord.Entry_Type__c
            || oldRecord.Posting_Key__c
                != newRecord.Posting_Key__c
            || oldRecord.Description__c
                != newRecord.Description__c
            || oldRecord.Posted_By__c
                != newRecord.Posted_By__c
            || oldRecord.Posted_At__c
                != newRecord.Posted_At__c
            || oldRecord.Accounting_Event__c
                != newRecord.Accounting_Event__c
            || oldRecord.Reversal_Of__c
                != newRecord.Reversal_Of__c
            || oldRecord.Version__c
                != newRecord.Version__c;
    }
}
