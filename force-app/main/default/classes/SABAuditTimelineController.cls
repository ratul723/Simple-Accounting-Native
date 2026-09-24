/**
 * Stage 8F - Audit / Action History UI controller.
 *
 * Read-only company-scoped timeline assembled from authoritative records:
 * - Business_Action__c
 * - Accounting_Period_Action__c
 * - Journal_Entry__c posting/reversal lineage
 * - Accounting_Event__c lifecycle
 *
 * This controller does NOT create audit data and does NOT replace the
 * authoritative accounting services. It presents existing immutable/history
 * records and ledger/event lineage in one company-scoped timeline.
 */
public with sharing class SABAuditTimelineController {

    public class TimelineItemDTO {
        @AuraEnabled public String itemKey { get; set; }
        @AuraEnabled public String category { get; set; }
        @AuraEnabled public Datetime occurredAt { get; set; }
        @AuraEnabled public String title { get; set; }
        @AuraEnabled public String detail { get; set; }
        @AuraEnabled public String actorName { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String requestKey { get; set; }
        @AuraEnabled public String sourceType { get; set; }
        @AuraEnabled public String sourceRecordId { get; set; }
        @AuraEnabled public Decimal sourceVersion { get; set; }
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public String recordApiName { get; set; }
        @AuraEnabled public Id relatedRecordId { get; set; }
        @AuraEnabled public String relatedApiName { get; set; }
    }

    public class TimelineDTO {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public List<TimelineItemDTO> items { get; set; }
        @AuraEnabled public Integer businessActionCount { get; set; }
        @AuraEnabled public Integer periodActionCount { get; set; }
        @AuraEnabled public Integer journalActionCount { get; set; }
        @AuraEnabled public Integer accountingEventCount { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static TimelineDTO getTimeline(
        Id companyId
    ) {
        if (companyId == null) {
            throw new AuraHandledException(
                'Select an Accounting Company before viewing audit history.'
            );
        }

        SABCompanyAccessService.assertCompanyAccess(
            companyId
        );

        assertReadAccess();

        TimelineDTO result =
            new TimelineDTO();

        result.companyId =
            companyId;
        result.items =
            new List<TimelineItemDTO>();
        result.businessActionCount =
            0;
        result.periodActionCount =
            0;
        result.journalActionCount =
            0;
        result.accountingEventCount =
            0;

        addBusinessActions(
            companyId,
            result
        );

        addPeriodActions(
            companyId,
            result
        );

        addJournalActions(
            companyId,
            result
        );

        addAccountingEvents(
            companyId,
            result
        );

        sortNewestFirst(
            result.items
        );

        return result;
    }

    private static void addBusinessActions(
        Id companyId,
        TimelineDTO result
    ) {
        for (Business_Action__c actionRecord : [
            SELECT Id,
                   Name,
                   Action__c,
                   Actor__r.Name,
                   Action_At__c,
                   Reason__c,
                   Request_Key__c,
                   Source_Type__c,
                   Source_Record_Id__c,
                   Source_Version__c
            FROM Business_Action__c
            WHERE Company__c = :companyId
            ORDER BY Action_At__c DESC,
                     CreatedDate DESC
            LIMIT 100
        ]) {
            TimelineItemDTO item =
                new TimelineItemDTO();

            item.itemKey =
                'BUSINESS-' + actionRecord.Id;
            item.category =
                'BUSINESS';
            item.occurredAt =
                actionRecord.Action_At__c;
            item.title =
                actionRecord.Action__c;
            item.detail =
                actionRecord.Reason__c;
            item.actorName =
                actionRecord.Actor__r == null
                    ? null
                    : actionRecord.Actor__r.Name;
            item.requestKey =
                actionRecord.Request_Key__c;
            item.sourceType =
                actionRecord.Source_Type__c;
            item.sourceRecordId =
                actionRecord.Source_Record_Id__c;
            item.sourceVersion =
                actionRecord.Source_Version__c;
            item.recordId =
                actionRecord.Id;
            item.recordApiName =
                'Business_Action__c';

            result.items.add(
                item
            );

            result.businessActionCount++;
        }
    }

    private static void addPeriodActions(
        Id companyId,
        TimelineDTO result
    ) {
        for (
            Accounting_Period_Action__c actionRecord
            : [
                SELECT Id,
                       Period__c,
                       Period__r.Name,
                       Previous_Status__c,
                       New_Status__c,
                       Performed_By__r.Name,
                       Performed_At__c,
                       Reason__c,
                       Request_Key__c
                FROM Accounting_Period_Action__c
                WHERE Period__r.Company__c = :companyId
                ORDER BY Performed_At__c DESC,
                         CreatedDate DESC,
                         Id DESC
                LIMIT 100
            ]
        ) {
            TimelineItemDTO item =
                new TimelineItemDTO();

            item.itemKey =
                'PERIOD-' + actionRecord.Id;
            item.category =
                'PERIOD';
            item.occurredAt =
                actionRecord.Performed_At__c;
            item.title =
                'Period '
                + actionRecord.Previous_Status__c
                + ' → '
                + actionRecord.New_Status__c;
            item.detail =
                actionRecord.Period__r.Name
                + (
                    String.isBlank(
                        actionRecord.Reason__c
                    )
                        ? ''
                        : ' · ' + actionRecord.Reason__c
                );
            item.actorName =
                actionRecord.Performed_By__r == null
                    ? null
                    : actionRecord.Performed_By__r.Name;
            item.status =
                actionRecord.New_Status__c;
            item.requestKey =
                actionRecord.Request_Key__c;
            item.sourceType =
                'Accounting_Period__c';
            item.sourceRecordId =
                String.valueOf(
                    actionRecord.Period__c
                );
            item.recordId =
                actionRecord.Id;
            item.recordApiName =
                'Accounting_Period_Action__c';
            item.relatedRecordId =
                actionRecord.Period__c;
            item.relatedApiName =
                'Accounting_Period__c';

            result.items.add(
                item
            );

            result.periodActionCount++;
        }
    }

    private static void addJournalActions(
        Id companyId,
        TimelineDTO result
    ) {
        for (Journal_Entry__c journal : [
            SELECT Id,
                   Name,
                   Accounting_Date__c,
                   Entry_Type__c,
                   Status__c,
                   Posting_Key__c,
                   Description__c,
                   Posted_By__r.Name,
                   Posted_At__c,
                   Accounting_Event__c,
                   Reversal_Of__c,
                   Reversal_Journal__c,
                   Reversal_Journal__r.Name,
                   Reversal_Journal__r.Posted_At__c,
                   Reversal_Journal__r.Posted_By__r.Name,
                   Version__c
            FROM Journal_Entry__c
            WHERE Company__c = :companyId
              AND Status__c IN ('Posted', 'Reversed')
            ORDER BY Posted_At__c DESC,
                     CreatedDate DESC
            LIMIT 100
        ]) {
            if (journal.Posted_At__c != null) {
                TimelineItemDTO posted =
                    new TimelineItemDTO();

                posted.itemKey =
                    'JOURNAL-POSTED-' + journal.Id;
                posted.category =
                    'JOURNAL';
                posted.occurredAt =
                    journal.Posted_At__c;
                posted.title =
                    'Journal Posted · ' + journal.Name;
                posted.detail =
                    buildJournalDetail(
                        journal
                    );
                posted.actorName =
                    journal.Posted_By__r == null
                        ? null
                        : journal.Posted_By__r.Name;
                posted.status =
                    journal.Status__c;
                posted.requestKey =
                    journal.Posting_Key__c;
                posted.sourceType =
                    'Journal_Entry__c';
                posted.sourceRecordId =
                    String.valueOf(
                        journal.Id
                    );
                posted.sourceVersion =
                    journal.Version__c;
                posted.recordId =
                    journal.Id;
                posted.recordApiName =
                    'Journal_Entry__c';
                posted.relatedRecordId =
                    journal.Accounting_Event__c;
                posted.relatedApiName =
                    journal.Accounting_Event__c == null
                        ? null
                        : 'Accounting_Event__c';

                result.items.add(
                    posted
                );

                result.journalActionCount++;
            }

            if (
                journal.Status__c == 'Reversed'
                && journal.Reversal_Journal__c != null
                && journal.Reversal_Journal__r != null
                && journal.Reversal_Journal__r.Posted_At__c != null
            ) {
                TimelineItemDTO reversed =
                    new TimelineItemDTO();

                reversed.itemKey =
                    'JOURNAL-REVERSED-' + journal.Id;
                reversed.category =
                    'JOURNAL';
                reversed.occurredAt =
                    journal.Reversal_Journal__r.Posted_At__c;
                reversed.title =
                    'Journal Reversed · ' + journal.Name;
                reversed.detail =
                    'Reversal Journal: '
                    + journal.Reversal_Journal__r.Name;
                reversed.actorName =
                    journal.Reversal_Journal__r.Posted_By__r == null
                        ? null
                        : journal.Reversal_Journal__r.Posted_By__r.Name;
                reversed.status =
                    'Reversed';
                reversed.sourceType =
                    'Journal_Entry__c';
                reversed.sourceRecordId =
                    String.valueOf(
                        journal.Id
                    );
                reversed.sourceVersion =
                    journal.Version__c;
                reversed.recordId =
                    journal.Id;
                reversed.recordApiName =
                    'Journal_Entry__c';
                reversed.relatedRecordId =
                    journal.Reversal_Journal__c;
                reversed.relatedApiName =
                    'Journal_Entry__c';

                result.items.add(
                    reversed
                );

                result.journalActionCount++;
            }
        }
    }

    private static String buildJournalDetail(
        Journal_Entry__c journal
    ) {
        List<String> parts =
            new List<String>();

        if (
            journal.Accounting_Date__c
            != null
        ) {
            parts.add(
                'Accounting Date '
                + String.valueOf(
                    journal.Accounting_Date__c
                )
            );
        }

        if (
            !String.isBlank(
                journal.Entry_Type__c
            )
        ) {
            parts.add(
                journal.Entry_Type__c
            );
        }

        if (
            !String.isBlank(
                journal.Description__c
            )
        ) {
            parts.add(
                journal.Description__c
            );
        }

        return String.join(
            parts,
            ' · '
        );
    }

    private static void addAccountingEvents(
        Id companyId,
        TimelineDTO result
    ) {
        for (Accounting_Event__c eventRecord : [
            SELECT Id,
                   Name,
                   Event_Key__c,
                   Event_Type__c,
                   Adapter_Key__c,
                   State__c,
                   Source_Type__c,
                   Source_Record_Id__c,
                   Source_Version__c,
                   Source_Business_Key__c,
                   Created_Request_Key__c,
                   Journal_Entry__c,
                   Reversal_Event__c,
                   CreatedDate
            FROM Accounting_Event__c
            WHERE Company__c = :companyId
            ORDER BY CreatedDate DESC
            LIMIT 100
        ]) {
            TimelineItemDTO item =
                new TimelineItemDTO();

            item.itemKey =
                'EVENT-' + eventRecord.Id;
            item.category =
                'EVENT';
            item.occurredAt =
                eventRecord.CreatedDate;
            item.title =
                'Accounting Event · '
                + eventRecord.Event_Type__c;
            item.detail =
                eventRecord.Event_Key__c
                + ' · '
                + eventRecord.Adapter_Key__c;
            item.status =
                eventRecord.State__c;
            item.requestKey =
                eventRecord.Created_Request_Key__c;
            item.sourceType =
                eventRecord.Source_Type__c;
            item.sourceRecordId =
                eventRecord.Source_Record_Id__c;
            item.sourceVersion =
                eventRecord.Source_Version__c;
            item.recordId =
                eventRecord.Id;
            item.recordApiName =
                'Accounting_Event__c';
            item.relatedRecordId =
                eventRecord.Journal_Entry__c;
            item.relatedApiName =
                eventRecord.Journal_Entry__c == null
                    ? null
                    : 'Journal_Entry__c';

            result.items.add(
                item
            );

            result.accountingEventCount++;
        }
    }

    private static void sortNewestFirst(
        List<TimelineItemDTO> items
    ) {
        Integer sizeValue =
            items.size();

        for (
            Integer outerIndex = 0;
            outerIndex < sizeValue;
            outerIndex++
        ) {
            Integer newestIndex =
                outerIndex;

            for (
                Integer innerIndex =
                    outerIndex + 1;
                innerIndex < sizeValue;
                innerIndex++
            ) {
                Datetime candidate =
                    items[innerIndex].occurredAt;

                Datetime current =
                    items[newestIndex].occurredAt;

                Boolean candidateIsNewer =
                    (
                        candidate != null
                        && (
                            current == null
                            || candidate.getTime()
                                > current.getTime()
                        )
                    );

                if (candidateIsNewer) {
                    newestIndex =
                        innerIndex;
                }
            }

            if (
                newestIndex
                != outerIndex
            ) {
                TimelineItemDTO temporary =
                    items[outerIndex];

                items[outerIndex] =
                    items[newestIndex];

                items[newestIndex] =
                    temporary;
            }
        }
    }

    private static void assertReadAccess() {
        SABAccessControlService.assertReadable(
            Business_Action__c.SObjectType,
            new List<Schema.SObjectField>{
                Business_Action__c.Company__c,
                Business_Action__c.Action__c,
                Business_Action__c.Actor__c,
                Business_Action__c.Action_At__c,
                Business_Action__c.Reason__c,
                Business_Action__c.Request_Key__c,
                Business_Action__c.Source_Type__c,
                Business_Action__c.Source_Record_Id__c,
                Business_Action__c.Source_Version__c
            }
        );

        SABAccessControlService.assertReadable(
            Accounting_Period_Action__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Period_Action__c.Period__c,
                Accounting_Period_Action__c.Previous_Status__c,
                Accounting_Period_Action__c.New_Status__c,
                Accounting_Period_Action__c.Performed_By__c,
                Accounting_Period_Action__c.Performed_At__c,
                Accounting_Period_Action__c.Reason__c,
                Accounting_Period_Action__c.Request_Key__c
            }
        );

        SABAccessControlService.assertReadable(
            Journal_Entry__c.SObjectType,
            new List<Schema.SObjectField>{
                Journal_Entry__c.Company__c,
                Journal_Entry__c.Accounting_Date__c,
                Journal_Entry__c.Entry_Type__c,
                Journal_Entry__c.Status__c,
                Journal_Entry__c.Posting_Key__c,
                Journal_Entry__c.Description__c,
                Journal_Entry__c.Posted_By__c,
                Journal_Entry__c.Posted_At__c,
                Journal_Entry__c.Accounting_Event__c,
                Journal_Entry__c.Reversal_Of__c,
                Journal_Entry__c.Reversal_Journal__c,
                Journal_Entry__c.Version__c
            }
        );

        SABAccessControlService.assertReadable(
            Accounting_Event__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Event__c.Company__c,
                Accounting_Event__c.Event_Key__c,
                Accounting_Event__c.Event_Type__c,
                Accounting_Event__c.Adapter_Key__c,
                Accounting_Event__c.State__c,
                Accounting_Event__c.Source_Type__c,
                Accounting_Event__c.Source_Record_Id__c,
                Accounting_Event__c.Source_Version__c,
                Accounting_Event__c.Source_Business_Key__c,
                Accounting_Event__c.Created_Request_Key__c,
                Accounting_Event__c.Journal_Entry__c,
                Accounting_Event__c.Reversal_Event__c
            }
        );
    }
}
