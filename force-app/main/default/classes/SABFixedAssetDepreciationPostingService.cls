/**
 * G9C - Fixed Asset Depreciation Posting.
 *
 * Posts one Planned Asset_Schedule_Line__c through the existing
 * SABAccountingEventService + SABPostingService accounting pipeline.
 *
 * Journal:
 *   Dr Depreciation Expense
 *   Cr Accumulated Depreciation
 *
 * Posting is idempotent by schedule-line accounting identity.
 */
public with sharing class SABFixedAssetDepreciationPostingService {

    public class FixedAssetDepreciationPostingException extends Exception {}

    private static final String PERMISSION =
        'SAB_Post_Asset_Depreciation';
    private static final String STATUS_PLANNED =
        'Planned';
    private static final String STATUS_POSTED =
        'Posted';
    private static final String ENTRY_TYPE =
        'Subledger';
    private static final String EVENT_TYPE =
        'Depreciation';
    private static final String SOURCE_TYPE =
        'Asset_Schedule_Line__c';
    private static final String ADAPTER_KEY =
        'FIXED_ASSET_DEPRECIATION';
    private static final Decimal ZERO =
        Decimal.valueOf('0');

    @TestVisible
    private static Boolean mutationInProgress =
        false;

    public static Boolean isMutationInProgress() {
        return mutationInProgress;
    }

    public class PostingRequest {
        @AuraEnabled public Id scheduleLineId { get; set; }
        @AuraEnabled public String requestKey { get; set; }
    }

    public class PostingResult {
        @AuraEnabled public Id scheduleLineId { get; private set; }
        @AuraEnabled public Id fixedAssetId { get; private set; }
        @AuraEnabled public Id journalEntryId { get; private set; }
        @AuraEnabled public Id accountingEventId { get; private set; }
        @AuraEnabled public String postingKey { get; private set; }
        @AuraEnabled public Decimal depreciationAmount { get; private set; }
        @AuraEnabled public Datetime postedAt { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private PostingResult() {}
    }

    @AuraEnabled
    public static PostingResult postDepreciation(
        PostingRequest request
    ) {
        SABPermissionService.assertPermission(
            PERMISSION,
            'You do not have permission to post Fixed Asset depreciation.'
        );

        validateRequest(request);

        Asset_Schedule_Line__c initialLine =
            loadScheduleLine(
                request.scheduleLineId,
                false
            );

        SABCompanyAccessService.assertCompanyAccess(
            initialLine.Fixed_Asset__r.Company__c
        );

        if (initialLine.Status__c == STATUS_POSTED) {
            return resolvePostedReplay(
                initialLine
            );
        }

        if (initialLine.Status__c != STATUS_PLANNED) {
            throw new FixedAssetDepreciationPostingException(
                'Only a Planned Asset Schedule Line can be posted.'
            );
        }

        Savepoint savepointValue =
            Database.setSavepoint();

        try {
            Asset_Schedule_Line__c scheduleLine =
                loadScheduleLine(
                    request.scheduleLineId,
                    true
                );

            SABCompanyAccessService.assertCompanyAccess(
                scheduleLine.Fixed_Asset__r.Company__c
            );

            if (
                scheduleLine.Status__c
                    == STATUS_POSTED
            ) {
                return resolvePostedReplay(
                    scheduleLine
                );
            }

            if (
                scheduleLine.Status__c
                    != STATUS_PLANNED
            ) {
                throw new FixedAssetDepreciationPostingException(
                    'Asset Schedule Line changed while posting. Retry the request.'
                );
            }

            validatePostingBasis(
                scheduleLine
            );

            Accounting_Period__c period =
                loadAndValidateOpenPeriod(
                    scheduleLine
                );

            Decimal amount =
                SABMoneyService.normalizeLedgerAmount(
                    scheduleLine.Planned_Depreciation__c,
                    RoundingMode.HALF_UP
                );

            if (amount <= ZERO) {
                throw new FixedAssetDepreciationPostingException(
                    'Planned Depreciation must be greater than zero before posting.'
                );
            }

            String functionalCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    scheduleLine.Fixed_Asset__r.Company__r.Functional_Currency__c
                );

            Journal_Entry__c journal =
                new Journal_Entry__c(
                    Company__c =
                        scheduleLine.Fixed_Asset__r.Company__c,
                    Accounting_Period__c =
                        period.Id,
                    Accounting_Date__c =
                        scheduleLine.Scheduled_Date__c,
                    Entry_Type__c =
                        ENTRY_TYPE,
                    Status__c =
                        'Draft',
                    Description__c =
                        truncateText(
                            'Fixed Asset Depreciation - '
                            + scheduleLine.Fixed_Asset__r.Name
                            + ' - '
                            + String.valueOf(
                                scheduleLine.Scheduled_Date__c
                            ),
                            Journal_Entry__c.Description__c.getDescribe().getLength()
                        ),
                    Version__c = 1
                );
            insert journal;

            Id departmentId =
                scheduleLine.Fixed_Asset__r.Department__c;
            Id costCenterId =
                scheduleLine.Fixed_Asset__r.Cost_Center__c;

            insert new List<Journal_Entry_Line__c>{
                new Journal_Entry_Line__c(
                    Journal_Entry__c =
                        journal.Id,
                    GL_Account__c =
                        scheduleLine.Fixed_Asset__r.Asset_Category__r.Depreciation_Expense_Account__c,
                    Line_Number__c = 1,
                    Debit_Base__c = amount,
                    Credit_Base__c = ZERO,
                    Explanation__c =
                        'Fixed Asset depreciation expense',
                    Transaction_Amount__c =
                        amount,
                    Transaction_Currency__c =
                        functionalCurrency,
                    Functional_Currency__c =
                        functionalCurrency,
                    Applied_Exchange_Rate__c =
                        Decimal.valueOf('1'),
                    Rate_Date__c =
                        scheduleLine.Scheduled_Date__c,
                    Rate_Source__c =
                        'Fixed Asset Depreciation',
                    Source_Line_Key__c =
                        'FADEP|'
                        + String.valueOf(
                            scheduleLine.Id
                        )
                        + '|EXPENSE',
                    Department__c =
                        departmentId,
                    Cost_Center__c =
                        costCenterId
                ),
                new Journal_Entry_Line__c(
                    Journal_Entry__c =
                        journal.Id,
                    GL_Account__c =
                        scheduleLine.Fixed_Asset__r.Asset_Category__r.Accumulated_Depreciation_Account__c,
                    Line_Number__c = 2,
                    Debit_Base__c = ZERO,
                    Credit_Base__c = amount,
                    Explanation__c =
                        'Fixed Asset accumulated depreciation',
                    Transaction_Amount__c =
                        amount,
                    Transaction_Currency__c =
                        functionalCurrency,
                    Functional_Currency__c =
                        functionalCurrency,
                    Applied_Exchange_Rate__c =
                        Decimal.valueOf('1'),
                    Rate_Date__c =
                        scheduleLine.Scheduled_Date__c,
                    Rate_Source__c =
                        'Fixed Asset Depreciation',
                    Source_Line_Key__c =
                        'FADEP|'
                        + String.valueOf(
                            scheduleLine.Id
                        )
                        + '|ACCUM',
                    Department__c =
                        departmentId,
                    Cost_Center__c =
                        costCenterId
                )
            };

            Integer sourceVersion =
                versionAsInteger(
                    scheduleLine.Calculation_Version__c
                );

            SABAccountingEventService.ReservationRequest eventRequest =
                    new SABAccountingEventService.ReservationRequest();

            eventRequest.companyId =
                scheduleLine.Fixed_Asset__r.Company__c;
            eventRequest.adapterKey =
                ADAPTER_KEY;
            eventRequest.requestKey =
                request.requestKey.trim();
            eventRequest.eventKey =
                buildEventKey(
                    scheduleLine.Id,
                    sourceVersion
                );
            eventRequest.eventType =
                EVENT_TYPE;
            eventRequest.sourceBusinessKey =
                buildSourceBusinessKey(
                    scheduleLine
                );
            eventRequest.sourceRecordId =
                String.valueOf(
                    scheduleLine.Id
                );
            eventRequest.sourceType =
                SOURCE_TYPE;
            eventRequest.sourceVersion =
                sourceVersion;

            SABPostingService.PostingRequest
                postingRequest =
                    new SABPostingService.PostingRequest();

            postingRequest.journalEntryId =
                journal.Id;
            postingRequest.postingKey =
                buildPostingKey(
                    scheduleLine.Id,
                    sourceVersion
                );
            postingRequest.eventRequest =
                eventRequest;

            SABPostingService.PostingResult
                posted =
                    SABPostingService.postDraftJournal(
                            postingRequest
                        );

            scheduleLine.Status__c =
                STATUS_POSTED;

            Asset_Movement__c depreciationMovement =
                new Asset_Movement__c(
                    Fixed_Asset__c =
                        scheduleLine.Fixed_Asset__c,
                    Movement_Type__c =
                        'Depreciation',
                    Movement_Date__c =
                        scheduleLine.Scheduled_Date__c,
                    Accounting_Date__c =
                        scheduleLine.Scheduled_Date__c,
                    Period__c =
                        scheduleLine.Period__c,
                    Amount__c =
                        amount,
                    Book_Key__c =
                        scheduleLine.Book_Key__c,
                    Movement_Key__c =
                        'DEP|'
                        + String.valueOf(scheduleLine.Id)
                        + '|V'
                        + String.valueOf(sourceVersion),
                    Journal_Entry__c =
                        posted.journalEntryId,
                    Accounting_Event__c =
                        posted.accountingEventId,
                    Reason__c =
                        'Scheduled depreciation posting'
                );

            mutationInProgress = true;
            try {
                update scheduleLine;
                insert depreciationMovement;
            } finally {
                mutationInProgress = false;
            }

            return buildResult(
                scheduleLine,
                posted.journalEntryId,
                posted.accountingEventId,
                posted.postingKey,
                amount,
                posted.postedAt,
                posted.replay
            );
        } catch (Exception ex) {
            Database.rollback(savepointValue);
            throw ex;
        }
    }

    private static Asset_Schedule_Line__c loadScheduleLine(
        Id scheduleLineId,
        Boolean lockRow
    ) {
        if (scheduleLineId == null) {
            throw new FixedAssetDepreciationPostingException(
                'Asset Schedule Line Id is required.'
            );
        }

        List<Asset_Schedule_Line__c> rows;

        if (lockRow) {
            rows = [
                SELECT Id,
                       Fixed_Asset__c,
                       Period__c,
                       Scheduled_Date__c,
                       Planned_Depreciation__c,
                       Book_Key__c,
                       Calculation_Version__c,
                       Status__c,
                       Fixed_Asset__r.Name,
                       Fixed_Asset__r.Company__c,
                       Fixed_Asset__r.Company__r.Functional_Currency__c,
                       Fixed_Asset__r.Company_Asset_Key__c,
                       Fixed_Asset__r.Status__c,
                       Fixed_Asset__r.Department__c,
                       Fixed_Asset__r.Cost_Center__c,
                       Fixed_Asset__r.Asset_Category__c,
                       Fixed_Asset__r.Asset_Category__r.Company__c,
                       Fixed_Asset__r.Asset_Category__r.Depreciation_Expense_Account__c,
                       Fixed_Asset__r.Asset_Category__r.Depreciation_Expense_Account__r.Company__c,
                       Fixed_Asset__r.Asset_Category__r.Depreciation_Expense_Account__r.Is_Active__c,
                       Fixed_Asset__r.Asset_Category__r.Depreciation_Expense_Account__r.Account_Type__c,
                       Fixed_Asset__r.Asset_Category__r.Depreciation_Expense_Account__r.Normal_Balance__c,
                       Fixed_Asset__r.Asset_Category__r.Depreciation_Expense_Account__r.Is_Control_Account__c,
                       Fixed_Asset__r.Asset_Category__r.Accumulated_Depreciation_Account__c,
                       Fixed_Asset__r.Asset_Category__r.Accumulated_Depreciation_Account__r.Company__c,
                       Fixed_Asset__r.Asset_Category__r.Accumulated_Depreciation_Account__r.Is_Active__c,
                       Fixed_Asset__r.Asset_Category__r.Accumulated_Depreciation_Account__r.Account_Type__c,
                       Fixed_Asset__r.Asset_Category__r.Accumulated_Depreciation_Account__r.Normal_Balance__c,
                       Fixed_Asset__r.Asset_Category__r.Accumulated_Depreciation_Account__r.Is_Control_Account__c
                FROM Asset_Schedule_Line__c
                WHERE Id = :scheduleLineId
                LIMIT 1
                FOR UPDATE
            ];
        } else {
            rows = [
                SELECT Id,
                       Fixed_Asset__c,
                       Period__c,
                       Scheduled_Date__c,
                       Planned_Depreciation__c,
                       Book_Key__c,
                       Calculation_Version__c,
                       Status__c,
                       Fixed_Asset__r.Name,
                       Fixed_Asset__r.Company__c,
                       Fixed_Asset__r.Company__r.Functional_Currency__c,
                       Fixed_Asset__r.Company_Asset_Key__c,
                       Fixed_Asset__r.Status__c,
                       Fixed_Asset__r.Department__c,
                       Fixed_Asset__r.Cost_Center__c,
                       Fixed_Asset__r.Asset_Category__c,
                       Fixed_Asset__r.Asset_Category__r.Company__c,
                       Fixed_Asset__r.Asset_Category__r.Depreciation_Expense_Account__c,
                       Fixed_Asset__r.Asset_Category__r.Depreciation_Expense_Account__r.Company__c,
                       Fixed_Asset__r.Asset_Category__r.Depreciation_Expense_Account__r.Is_Active__c,
                       Fixed_Asset__r.Asset_Category__r.Depreciation_Expense_Account__r.Account_Type__c,
                       Fixed_Asset__r.Asset_Category__r.Depreciation_Expense_Account__r.Normal_Balance__c,
                       Fixed_Asset__r.Asset_Category__r.Depreciation_Expense_Account__r.Is_Control_Account__c,
                       Fixed_Asset__r.Asset_Category__r.Accumulated_Depreciation_Account__c,
                       Fixed_Asset__r.Asset_Category__r.Accumulated_Depreciation_Account__r.Company__c,
                       Fixed_Asset__r.Asset_Category__r.Accumulated_Depreciation_Account__r.Is_Active__c,
                       Fixed_Asset__r.Asset_Category__r.Accumulated_Depreciation_Account__r.Account_Type__c,
                       Fixed_Asset__r.Asset_Category__r.Accumulated_Depreciation_Account__r.Normal_Balance__c,
                       Fixed_Asset__r.Asset_Category__r.Accumulated_Depreciation_Account__r.Is_Control_Account__c
                FROM Asset_Schedule_Line__c
                WHERE Id = :scheduleLineId
                LIMIT 1
            ];
        }

        if (rows.isEmpty()) {
            throw new FixedAssetDepreciationPostingException(
                'Asset Schedule Line was not found.'
            );
        }

        return rows[0];
    }

    private static void validatePostingBasis(
        Asset_Schedule_Line__c line
    ) {
        if (
            line.Fixed_Asset__r.Status__c
                != 'In Service'
            && line.Fixed_Asset__r.Status__c
                != 'Impaired'
        ) {
            throw new FixedAssetDepreciationPostingException(
                'Fixed Asset must be In Service or Impaired before depreciation can be posted.'
            );
        }

        if (
            line.Fixed_Asset__r.Asset_Category__r
                == null
            || line.Fixed_Asset__r.Asset_Category__r.Company__c
                != line.Fixed_Asset__r.Company__c
        ) {
            throw new FixedAssetDepreciationPostingException(
                'Fixed Asset Category must belong to the same Accounting Company.'
            );
        }

        validateDepreciationExpenseAccount(
            line
        );
        validateAccumulatedDepreciationAccount(
            line
        );
    }

    private static void validateDepreciationExpenseAccount(
        Asset_Schedule_Line__c line
    ) {
        GL_Account__c account =
            line.Fixed_Asset__r.Asset_Category__r.Depreciation_Expense_Account__r;

        if (
            account == null
            || account.Company__c
                != line.Fixed_Asset__r.Company__c
            || account.Is_Active__c != true
            || account.Account_Type__c
                != 'Expense'
            || account.Normal_Balance__c
                != 'Debit'
            || account.Is_Control_Account__c
                == true
        ) {
            throw new FixedAssetDepreciationPostingException(
                'Depreciation Expense Account must be an active, non-control Expense account with Debit normal balance in the same Accounting Company.'
            );
        }
    }

    private static void validateAccumulatedDepreciationAccount(
        Asset_Schedule_Line__c line
    ) {
        GL_Account__c account =
            line.Fixed_Asset__r.Asset_Category__r.Accumulated_Depreciation_Account__r;

        if (
            account == null
            || account.Company__c
                != line.Fixed_Asset__r.Company__c
            || account.Is_Active__c != true
            || account.Account_Type__c
                != 'Asset'
            || account.Normal_Balance__c
                != 'Credit'
            || account.Is_Control_Account__c
                == true
        ) {
            throw new FixedAssetDepreciationPostingException(
                'Accumulated Depreciation Account must be an active, non-control Asset account with Credit normal balance in the same Accounting Company.'
            );
        }
    }

    private static Accounting_Period__c
        loadAndValidateOpenPeriod(
            Asset_Schedule_Line__c line
        )
    {
        List<Accounting_Period__c> periods = [
            SELECT Id,
                   Company__c,
                   Start_Date__c,
                   End_Date__c,
                   Status__c
            FROM Accounting_Period__c
            WHERE Id = :line.Period__c
            LIMIT 1
            FOR UPDATE
        ];

        if (periods.isEmpty()) {
            throw new FixedAssetDepreciationPostingException(
                'Asset Schedule Line Accounting Period was not found.'
            );
        }

        Accounting_Period__c period =
            periods[0];

        if (
            period.Company__c
                != line.Fixed_Asset__r.Company__c
        ) {
            throw new FixedAssetDepreciationPostingException(
                'Asset Schedule Line Accounting Period must belong to the Fixed Asset Accounting Company.'
            );
        }

        if (
            line.Scheduled_Date__c
                < period.Start_Date__c
            || line.Scheduled_Date__c
                > period.End_Date__c
        ) {
            throw new FixedAssetDepreciationPostingException(
                'Asset Schedule Line Scheduled Date must fall inside its Accounting Period.'
            );
        }

        if (period.Status__c != 'Open') {
            throw new FixedAssetDepreciationPostingException(
                'Fixed Asset depreciation Accounting Period must be Open.'
            );
        }

        return period;
    }

    private static PostingResult resolvePostedReplay(
        Asset_Schedule_Line__c line
    ) {
        Integer sourceVersion =
            versionAsInteger(
                line.Calculation_Version__c
            );

        String eventKey =
            buildEventKey(
                line.Id,
                sourceVersion
            );

        List<Accounting_Event__c> events = [
            SELECT Id,
                   Company__c,
                   Event_Key__c,
                   Event_Type__c,
                   Source_Type__c,
                   Source_Record_Id__c,
                   Source_Version__c,
                   State__c,
                   Journal_Entry__c,
                   Journal_Entry__r.Status__c,
                   Journal_Entry__r.Entry_Type__c,
                   Journal_Entry__r.Posting_Key__c,
                   Journal_Entry__r.Posted_At__c
            FROM Accounting_Event__c
            WHERE Event_Key__c = :eventKey
            LIMIT 1
        ];

        if (events.isEmpty()) {
            throw new FixedAssetDepreciationPostingException(
                'Posted Asset Schedule Line is missing its Accounting Event.'
            );
        }

        Accounting_Event__c eventRecord =
            events[0];

        if (
            eventRecord.Company__c
                != line.Fixed_Asset__r.Company__c
            || eventRecord.Event_Type__c
                != EVENT_TYPE
            || eventRecord.Source_Type__c
                != SOURCE_TYPE
            || eventRecord.Source_Record_Id__c
                != String.valueOf(line.Id)
            || eventRecord.Source_Version__c
                != sourceVersion
            || eventRecord.State__c
                != 'Posted'
            || eventRecord.Journal_Entry__c
                == null
            || eventRecord.Journal_Entry__r.Status__c
                != 'Posted'
            || eventRecord.Journal_Entry__r.Entry_Type__c
                != ENTRY_TYPE
            || eventRecord.Journal_Entry__r.Posting_Key__c
                != buildPostingKey(
                    line.Id,
                    sourceVersion
                )
        ) {
            throw new FixedAssetDepreciationPostingException(
                'Posted Asset Schedule Line does not have a consistent depreciation posting chain.'
            );
        }

        return buildResult(
            line,
            eventRecord.Journal_Entry__c,
            eventRecord.Id,
            eventRecord.Journal_Entry__r.Posting_Key__c,
            SABMoneyService.normalizeLedgerAmount(
                line.Planned_Depreciation__c,
                RoundingMode.HALF_UP
            ),
            eventRecord.Journal_Entry__r.Posted_At__c,
            true
        );
    }

    private static PostingResult buildResult(
        Asset_Schedule_Line__c line,
        Id journalEntryId,
        Id accountingEventId,
        String postingKey,
        Decimal amount,
        Datetime postedAt,
        Boolean replay
    ) {
        PostingResult result =
            new PostingResult();

        result.scheduleLineId =
            line.Id;
        result.fixedAssetId =
            line.Fixed_Asset__c;
        result.journalEntryId =
            journalEntryId;
        result.accountingEventId =
            accountingEventId;
        result.postingKey =
            postingKey;
        result.depreciationAmount =
            amount;
        result.postedAt =
            postedAt;
        result.replay =
            replay;

        return result;
    }

    private static String buildPostingKey(
        Id scheduleLineId,
        Integer sourceVersion
    ) {
        return 'FADEP|'
            + String.valueOf(
                scheduleLineId
            )
            + '|V'
            + String.valueOf(
                sourceVersion
            );
    }

    private static String buildEventKey(
        Id scheduleLineId,
        Integer sourceVersion
    ) {
        return 'FIXED_ASSET_DEPRECIATION|'
            + String.valueOf(
                scheduleLineId
            )
            + '|V'
            + String.valueOf(
                sourceVersion
            );
    }

    private static String buildSourceBusinessKey(
        Asset_Schedule_Line__c line
    ) {
        return truncateText(
            line.Fixed_Asset__r.Company_Asset_Key__c
            + '|'
            + line.Book_Key__c
            + '|'
            + String.valueOf(
                line.Scheduled_Date__c
            ),
            Accounting_Event__c.Source_Business_Key__c.getDescribe().getLength()
        );
    }

    private static Integer versionAsInteger(
        Decimal value
    ) {
        if (value == null) {
            throw new FixedAssetDepreciationPostingException(
                'Asset Schedule Line Calculation Version is required.'
            );
        }

        return Integer.valueOf(
            String.valueOf(
                value.setScale(0)
            )
        );
    }

    private static void validateRequest(
        PostingRequest request
    ) {
        if (request == null) {
            throw new FixedAssetDepreciationPostingException(
                'Fixed Asset depreciation posting request is required.'
            );
        }

        if (request.scheduleLineId == null) {
            throw new FixedAssetDepreciationPostingException(
                'Asset Schedule Line Id is required.'
            );
        }

        if (String.isBlank(request.requestKey)) {
            throw new FixedAssetDepreciationPostingException(
                'Request Key is required.'
            );
        }

        Integer maxLength =
            Accounting_Event__c.Created_Request_Key__c.getDescribe().getLength();

        if (
            maxLength > 0
            && request.requestKey.trim().length()
                > maxLength
        ) {
            throw new FixedAssetDepreciationPostingException(
                'Request Key cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static String truncateText(
        String value,
        Integer maxLength
    ) {
        if (String.isBlank(value)) {
            return value;
        }

        if (
            maxLength == null
            || maxLength <= 0
            || value.length() <= maxLength
        ) {
            return value;
        }

        return value.substring(
            0,
            maxLength
        );
    }
}
