/**
 * Protects Document_Sequence__c from direct counter manipulation.
 *
 * Rules:
 * - Next_Number__c may only change inside SABSequenceService.
 * - Once a sequence is active, its numbering identity/format cannot be edited.
 *   Deactivate it and create a new sequence for a new numbering pattern.
 * - An active sequence cannot be deleted.
 */
public without sharing class SABDocumentSequenceGuardService {

    public static void beforeUpdate(
        List<Document_Sequence__c> newRecords,
        Map<Id, Document_Sequence__c> oldMap
    ) {
        for (Document_Sequence__c newRecord : newRecords) {
            Document_Sequence__c oldRecord =
                oldMap.get(newRecord.Id);

            if (oldRecord == null) {
                continue;
            }

            if (
                oldRecord.Next_Number__c
                    != newRecord.Next_Number__c
                && !SABSequenceMutationContext.isReservation()
            ) {
                newRecord.addError(
                    'Next Number is controlled by SABSequenceService and cannot be edited directly.'
                );
            }

            if (
                oldRecord.Is_Active__c == true
                && identityOrFormatChanged(
                    oldRecord,
                    newRecord
                )
            ) {
                newRecord.addError(
                    'An active Document Sequence cannot change company, document type, fiscal series, prefix, minimum digits or sequence key. Deactivate it and create a new sequence.'
                );
            }
        }
    }

    public static void beforeDelete(
        List<Document_Sequence__c> oldRecords
    ) {
        for (Document_Sequence__c oldRecord : oldRecords) {
            if (oldRecord.Is_Active__c == true) {
                oldRecord.addError(
                    'An active Document Sequence cannot be deleted. Deactivate it first.'
                );
            }
        }
    }

    @TestVisible
    private static Boolean identityOrFormatChanged(
        Document_Sequence__c oldRecord,
        Document_Sequence__c newRecord
    ) {
        return oldRecord.Company__c
                != newRecord.Company__c
            || oldRecord.Document_Type__c
                != newRecord.Document_Type__c
            || oldRecord.Fiscal_Series__c
                != newRecord.Fiscal_Series__c
            || oldRecord.Prefix__c
                != newRecord.Prefix__c
            || oldRecord.Minimum_Digits__c
                != newRecord.Minimum_Digits__c
            || oldRecord.Sequence_Key__c
                != newRecord.Sequence_Key__c;
    }
}
