/**
 * Creates an editable correction Draft from a reversed Manual Journal.
 *
 * The original and its posted reversal remain immutable. Subledger/system journals are intentionally
 * excluded because their source transaction must be corrected in the owning module instead of by
 * creating an unrelated manual ledger entry.
 */
public with sharing class SABJournalCorrectionService {
    public class CorrectionException extends Exception {}

    private static final String REVERSE_PERMISSION = 'SAB_Reverse_Journal';

    public class ReversedJournalDTO {
        @AuraEnabled public Id journalId { get; set; }
        @AuraEnabled public String journalName { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public String entryType { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<ReversedJournalDTO> getReversedJournals(Id companyId) {
        if (companyId == null) {
            throw new AuraHandledException('Select an Accounting Company first.');
        }
        try {
            SABPermissionService.assertPermission(
                REVERSE_PERMISSION,
                'You do not have permission to review reversed Journals.'
            );
            SABCompanyAccessService.assertCompanyAccess(companyId);
            SABAccessControlService.assertReadable(
                Journal_Entry__c.SObjectType,
                new List<Schema.SObjectField>{
                    Journal_Entry__c.Name,
                    Journal_Entry__c.Accounting_Date__c,
                    Journal_Entry__c.Description__c,
                    Journal_Entry__c.Entry_Type__c,
                    Journal_Entry__c.Status__c,
                    Journal_Entry__c.Reversal_Of__c
                }
            );

            List<ReversedJournalDTO> result = new List<ReversedJournalDTO>();
            for (Journal_Entry__c journal : [
                SELECT Id, Name, Accounting_Date__c, Description__c, Entry_Type__c
                FROM Journal_Entry__c
                WHERE Company__c = :companyId
                  AND Status__c = 'Reversed'
                  AND Reversal_Of__c = null
                WITH USER_MODE
                ORDER BY Accounting_Date__c DESC, LastModifiedDate DESC
                LIMIT 100
            ]) {
                ReversedJournalDTO row = new ReversedJournalDTO();
                row.journalId = journal.Id;
                row.journalName = journal.Name;
                row.accountingDate = journal.Accounting_Date__c;
                row.description = journal.Description__c;
                row.entryType = journal.Entry_Type__c;
                result.add(row);
            }
            return result;
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static SABJournalWorkspaceController.JournalDTO createCorrectedDraft(Id originalJournalId) {
        if (originalJournalId == null) {
            throw new AuraHandledException('Select a Reversed Manual Journal first.');
        }

        try {
            SABPermissionService.assertPermission(
                REVERSE_PERMISSION,
                'You do not have permission to create a corrected Journal from a reversal.'
            );

            Journal_Entry__c original = [
                SELECT Id, Name, Company__c, Accounting_Period__c, Accounting_Date__c,
                       Entry_Type__c, Status__c, Description__c, Reversal_Journal__c, Reversal_Of__c
                FROM Journal_Entry__c
                WHERE Id = :originalJournalId
                WITH USER_MODE
                LIMIT 1
            ];

            SABCompanyAccessService.assertCompanyAccess(original.Company__c);
            SABAccessControlService.assertRecordReadAccess(original.Id);
            assertCorrectionReadAccess();

            if (original.Status__c != 'Reversed') {
                throw new CorrectionException('Only a Reversed Journal can be used to create a corrected Draft.');
            }
            if (original.Entry_Type__c != 'Manual') {
                throw new CorrectionException(
                    'Only reversed Manual Journals can be copied into a corrected Draft. Correct subledger and system-generated journals in their source module.'
                );
            }
            if (original.Reversal_Of__c != null) {
                throw new CorrectionException('A reversal journal itself cannot be used as the correction source.');
            }
            if (original.Reversal_Journal__c == null) {
                throw new CorrectionException('The Reversed Journal does not reference its Reversal Journal.');
            }

            Journal_Entry__c reversal = [
                SELECT Id, Company__c, Status__c, Reversal_Of__c
                FROM Journal_Entry__c
                WHERE Id = :original.Reversal_Journal__c
                WITH USER_MODE
                LIMIT 1
            ];
            if (reversal.Company__c != original.Company__c
                || reversal.Status__c != 'Posted'
                || reversal.Reversal_Of__c != original.Id) {
                throw new CorrectionException('The linked Reversal Journal is not a valid posted reversal of this Journal.');
            }

            List<Journal_Entry_Line__c> sourceLines = [
                SELECT Id, GL_Account__c, Debit_Base__c, Credit_Base__c, Explanation__c,
                       Department__c, Cost_Center__c, Project__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c = :original.Id
                WITH USER_MODE
                ORDER BY Line_Number__c ASC, Id ASC
            ];
            if (sourceLines.isEmpty()) {
                throw new CorrectionException('The original Journal has no financial lines to copy.');
            }

            Accounting_Period__c originalPeriod = [
                SELECT Id, Company__c, Start_Date__c, End_Date__c, Status__c
                FROM Accounting_Period__c
                WHERE Id = :original.Accounting_Period__c
                WITH USER_MODE
                LIMIT 1
            ];

            Accounting_Period__c targetPeriod;
            Date targetDate;
            if (originalPeriod.Status__c == 'Open') {
                targetPeriod = originalPeriod;
                targetDate = original.Accounting_Date__c;
            } else {
                List<Accounting_Period__c> openPeriods = [
                    SELECT Id, Company__c, Start_Date__c, End_Date__c, Status__c
                    FROM Accounting_Period__c
                    WHERE Company__c = :original.Company__c
                      AND Status__c = 'Open'
                      AND End_Date__c >= :original.Accounting_Date__c
                    WITH USER_MODE
                    ORDER BY Start_Date__c ASC
                ];
                if (openPeriods.isEmpty()) {
                    throw new CorrectionException(
                        'No Open Accounting Period is available on or after the original Accounting Date. Open a valid period before creating the correction.'
                    );
                }
                Date todayValue = Date.today();
                targetPeriod = openPeriods[0];
                for (Accounting_Period__c candidate : openPeriods) {
                    if (todayValue >= candidate.Start_Date__c && todayValue <= candidate.End_Date__c) {
                        targetPeriod = candidate;
                        break;
                    }
                }
                if (todayValue < targetPeriod.Start_Date__c) {
                    targetDate = targetPeriod.Start_Date__c;
                } else if (todayValue > targetPeriod.End_Date__c) {
                    targetDate = targetPeriod.End_Date__c;
                } else {
                    targetDate = todayValue;
                }
            }

            SABJournalWorkspaceController.DraftSaveRequest request =
                new SABJournalWorkspaceController.DraftSaveRequest();
            request.companyId = original.Company__c;
            request.periodId = targetPeriod.Id;
            request.accountingDate = targetDate;

            String correctionDescription = 'Correction of ' + original.Name;
            if (!String.isBlank(original.Description__c)) {
                correctionDescription += ': ' + original.Description__c.trim();
            }
            Integer maxDescriptionLength = Journal_Entry__c.Description__c.getDescribe().getLength();
            if (maxDescriptionLength > 0 && correctionDescription.length() > maxDescriptionLength) {
                correctionDescription = correctionDescription.substring(0, maxDescriptionLength);
            }
            request.description = correctionDescription;
            request.lines = new List<SABJournalWorkspaceController.DraftLineInput>();

            for (Journal_Entry_Line__c sourceLine : sourceLines) {
                SABJournalWorkspaceController.DraftLineInput input =
                    new SABJournalWorkspaceController.DraftLineInput();
                input.glAccountId = sourceLine.GL_Account__c;
                input.debit = sourceLine.Debit_Base__c == null ? 0 : sourceLine.Debit_Base__c;
                input.credit = sourceLine.Credit_Base__c == null ? 0 : sourceLine.Credit_Base__c;
                input.explanation = sourceLine.Explanation__c;
                input.departmentId = sourceLine.Department__c;
                input.costCenterId = sourceLine.Cost_Center__c;
                input.projectId = sourceLine.Project__c;
                request.lines.add(input);
            }

            return SABJournalWorkspaceController.saveDraft(request);
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    private static void assertCorrectionReadAccess() {
        SABAccessControlService.assertReadable(
            Journal_Entry__c.SObjectType,
            new List<Schema.SObjectField>{
                Journal_Entry__c.Name,
                Journal_Entry__c.Company__c,
                Journal_Entry__c.Accounting_Period__c,
                Journal_Entry__c.Accounting_Date__c,
                Journal_Entry__c.Entry_Type__c,
                Journal_Entry__c.Status__c,
                Journal_Entry__c.Description__c,
                Journal_Entry__c.Reversal_Journal__c,
                Journal_Entry__c.Reversal_Of__c
            }
        );
        SABAccessControlService.assertReadable(
            Journal_Entry_Line__c.SObjectType,
            new List<Schema.SObjectField>{
                Journal_Entry_Line__c.Journal_Entry__c,
                Journal_Entry_Line__c.Line_Number__c,
                Journal_Entry_Line__c.GL_Account__c,
                Journal_Entry_Line__c.Debit_Base__c,
                Journal_Entry_Line__c.Credit_Base__c,
                Journal_Entry_Line__c.Explanation__c,
                Journal_Entry_Line__c.Department__c,
                Journal_Entry_Line__c.Cost_Center__c,
                Journal_Entry_Line__c.Project__c
            }
        );
        SABAccessControlService.assertReadable(
            Accounting_Period__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Period__c.Company__c,
                Accounting_Period__c.Start_Date__c,
                Accounting_Period__c.End_Date__c,
                Accounting_Period__c.Status__c
            }
        );
    }
}
