/**
 * G9B - Fixed Asset Depreciation Schedule Generation.
 *
 * Current supported schedule policy:
 * - Straight Line only
 * - one schedule line per Accounting Period
 * - first line belongs to the period containing In Service Date
 * - equal 4-decimal planned depreciation
 * - final line absorbs storage-scale rounding
 * - schedule generation does not post journals
 * - active schedule generation is idempotent
 *
 * "Other Supported" remains unavailable until a separately-approved
 * depreciation policy is implemented.
 */
public with sharing class SABFixedAssetScheduleService {

    public class FixedAssetScheduleException extends Exception {}

    private static final String PERMISSION =
        'SAB_Generate_Asset_Schedule';
    private static final String STATUS_PLANNED = 'Planned';
    private static final String STATUS_POSTED = 'Posted';
    private static final String STATUS_SUPERSEDED = 'Superseded';
    private static final String METHOD_STRAIGHT_LINE =
        'Straight Line';
    private static final Decimal ZERO =
        Decimal.valueOf('0');

    @TestVisible
    private static Boolean mutationInProgress = false;

    public static Boolean isMutationInProgress() {
        return mutationInProgress;
    }

    public class ScheduleRequest {
        @AuraEnabled public Id fixedAssetId { get; set; }
        @AuraEnabled public String bookKey { get; set; }
    }

    public class ScheduleResult {
        @AuraEnabled public Id fixedAssetId { get; private set; }
        @AuraEnabled public String bookKey { get; private set; }
        @AuraEnabled public Integer calculationVersion { get; private set; }
        @AuraEnabled public Integer lineCount { get; private set; }
        @AuraEnabled public Integer plannedCount { get; private set; }
        @AuraEnabled public Integer postedCount { get; private set; }
        @AuraEnabled public Decimal depreciableBase { get; private set; }
        @AuraEnabled public Decimal scheduledTotal { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }
        @AuraEnabled public List<Id> scheduleLineIds { get; private set; }

        private ScheduleResult() {
            scheduleLineIds = new List<Id>();
        }
    }

    @AuraEnabled
    public static ScheduleResult generateSchedule(
        ScheduleRequest request
    ) {
        SABPermissionService.assertPermission(
            PERMISSION,
            'You do not have permission to generate Fixed Asset depreciation schedules.'
        );

        validateRequest(request);

        String normalizedBookKey =
            request.bookKey.trim();

        Fixed_Asset__c asset = loadAndLockAsset(
            request.fixedAssetId
        );

        SABCompanyAccessService.assertCompanyAccess(
            asset.Company__c
        );

        validateAsset(asset);

        Decimal depreciableBase =
            SABMoneyService.normalizeLedgerAmount(
                asset.Functional_Currency_Cost__c
                - (
                    asset.Residual_Value__c == null
                        ? ZERO
                        : asset.Residual_Value__c
                ),
                RoundingMode.HALF_UP
            );

        if (depreciableBase < ZERO) {
            throw new FixedAssetScheduleException(
                'Fixed Asset Residual Value cannot exceed Functional Currency Cost.'
            );
        }

        List<Asset_Schedule_Line__c> activeLines =
            loadActiveSchedule(
                asset.Id,
                normalizedBookKey
            );

        if (!activeLines.isEmpty()) {
            return buildReplayResult(
                asset,
                normalizedBookKey,
                depreciableBase,
                activeLines
            );
        }

        Integer calculationVersion =
            nextCalculationVersion(
                asset.Id,
                normalizedBookKey
            );

        List<Accounting_Period__c> periods =
            resolveSchedulePeriods(
                asset.Company__c,
                asset.In_Service_Date__c,
                Integer.valueOf(
                    asset.Useful_Life_Months__c
                )
            );

        Integer usefulLife =
            Integer.valueOf(
                asset.Useful_Life_Months__c
            );

        Decimal regularAmount =
            usefulLife == 0
                ? ZERO
                : SABMoneyService.normalizeLedgerAmount(
                    depreciableBase
                        / Decimal.valueOf(
                            String.valueOf(usefulLife)
                        ),
                    RoundingMode.HALF_UP
                );

        List<Asset_Schedule_Line__c> rows =
            new List<Asset_Schedule_Line__c>();

        Decimal scheduledBeforeFinal = ZERO;

        for (
            Integer index = 0;
            index < usefulLife;
            index++
        ) {
            Decimal amount;

            if (index == usefulLife - 1) {
                amount =
                    SABMoneyService.normalizeLedgerAmount(
                        depreciableBase
                        - scheduledBeforeFinal,
                        RoundingMode.HALF_UP
                    );
            } else {
                amount = regularAmount;
                scheduledBeforeFinal += amount;
            }

            Accounting_Period__c period =
                periods[index];

            rows.add(
                new Asset_Schedule_Line__c(
                    Fixed_Asset__c = asset.Id,
                    Period__c = period.Id,
                    Scheduled_Date__c =
                        period.End_Date__c,
                    Planned_Depreciation__c =
                        amount,
                    Book_Key__c =
                        normalizedBookKey,
                    Calculation_Version__c =
                        calculationVersion,
                    Status__c =
                        STATUS_PLANNED
                )
            );
        }

        mutationInProgress = true;

        try {
            insert rows;
        } finally {
            mutationInProgress = false;
        }

        return buildResult(
            asset,
            normalizedBookKey,
            calculationVersion,
            depreciableBase,
            rows,
            false
        );
    }

    private static void validateRequest(
        ScheduleRequest request
    ) {
        if (request == null) {
            throw new FixedAssetScheduleException(
                'Depreciation Schedule request is required.'
            );
        }

        if (request.fixedAssetId == null) {
            throw new FixedAssetScheduleException(
                'Fixed Asset Id is required.'
            );
        }

        if (String.isBlank(request.bookKey)) {
            throw new FixedAssetScheduleException(
                'Book Key is required.'
            );
        }

        Integer maxLength =
            Asset_Schedule_Line__c.Book_Key__c.getDescribe().getLength();

        if (
            maxLength > 0
            && request.bookKey.trim().length()
                > maxLength
        ) {
            throw new FixedAssetScheduleException(
                'Book Key cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static Fixed_Asset__c loadAndLockAsset(
        Id assetId
    ) {
        List<Fixed_Asset__c> rows = [
            SELECT Id,
                   Company__c,
                   Company_Asset_Key__c,
                   Status__c,
                   In_Service_Date__c,
                   Functional_Currency_Cost__c,
                   Residual_Value__c,
                   Useful_Life_Months__c,
                   Depreciation_Method__c
            FROM Fixed_Asset__c
            WHERE Id = :assetId
            LIMIT 1
            FOR UPDATE
        ];

        if (rows.isEmpty()) {
            throw new FixedAssetScheduleException(
                'Fixed Asset was not found.'
            );
        }

        return rows[0];
    }

    private static void validateAsset(
        Fixed_Asset__c asset
    ) {
        if (
            asset.Status__c != 'Planned'
            && asset.Status__c != 'In Service'
        ) {
            throw new FixedAssetScheduleException(
                'Depreciation Schedule can be generated only for Planned or In Service Fixed Assets.'
            );
        }

        if (asset.In_Service_Date__c == null) {
            throw new FixedAssetScheduleException(
                'Fixed Asset In Service Date is required.'
            );
        }

        if (
            asset.Functional_Currency_Cost__c == null
            || asset.Functional_Currency_Cost__c <= ZERO
        ) {
            throw new FixedAssetScheduleException(
                'Fixed Asset Functional Currency Cost must be greater than zero.'
            );
        }

        if (
            asset.Useful_Life_Months__c == null
            || asset.Useful_Life_Months__c <= ZERO
        ) {
            throw new FixedAssetScheduleException(
                'Fixed Asset Useful Life Months must be greater than zero.'
            );
        }

        if (
            asset.Depreciation_Method__c
                != METHOD_STRAIGHT_LINE
        ) {
            throw new FixedAssetScheduleException(
                'G9B currently supports Straight Line depreciation only.'
            );
        }
    }

    private static List<Asset_Schedule_Line__c>
        loadActiveSchedule(
            Id assetId,
            String bookKey
        )
    {
        return [
            SELECT Id,
                   Fixed_Asset__c,
                   Period__c,
                   Scheduled_Date__c,
                   Planned_Depreciation__c,
                   Book_Key__c,
                   Calculation_Version__c,
                   Status__c
            FROM Asset_Schedule_Line__c
            WHERE Fixed_Asset__c = :assetId
              AND Book_Key__c = :bookKey
              AND Status__c IN :new Set<String>{
                  STATUS_PLANNED,
                  STATUS_POSTED
              }
            ORDER BY Calculation_Version__c DESC,
                     Scheduled_Date__c ASC,
                     Id ASC
        ];
    }

    private static ScheduleResult buildReplayResult(
        Fixed_Asset__c asset,
        String bookKey,
        Decimal depreciableBase,
        List<Asset_Schedule_Line__c> activeLines
    ) {
        Decimal versionDecimal =
            activeLines[0].Calculation_Version__c;

        Integer activeVersion =
            Integer.valueOf(
                String.valueOf(
                    versionDecimal.setScale(0)
                )
            );

        List<Asset_Schedule_Line__c> currentVersion =
            new List<Asset_Schedule_Line__c>();

        for (
            Asset_Schedule_Line__c line :
            activeLines
        ) {
            if (
                line.Calculation_Version__c
                    == versionDecimal
            ) {
                currentVersion.add(line);
            } else {
                throw new FixedAssetScheduleException(
                    'More than one active depreciation schedule version exists for this Fixed Asset and Book Key.'
                );
            }
        }

        Integer usefulLife =
            Integer.valueOf(
                asset.Useful_Life_Months__c
            );

        if (currentVersion.size() != usefulLife) {
            throw new FixedAssetScheduleException(
                'Existing active depreciation schedule is incomplete. Use a controlled asset lifecycle correction instead of generating duplicate lines.'
            );
        }

        Decimal scheduledTotal = ZERO;

        for (
            Asset_Schedule_Line__c line :
            currentVersion
        ) {
            scheduledTotal +=
                line.Planned_Depreciation__c;
        }

        scheduledTotal =
            SABMoneyService.normalizeLedgerAmount(
                scheduledTotal,
                RoundingMode.HALF_UP
            );

        if (scheduledTotal != depreciableBase) {
            throw new FixedAssetScheduleException(
                'Existing active depreciation schedule does not reconcile to the Fixed Asset depreciable base.'
            );
        }

        return buildResult(
            asset,
            bookKey,
            activeVersion,
            depreciableBase,
            currentVersion,
            true
        );
    }

    private static Integer nextCalculationVersion(
        Id assetId,
        String bookKey
    ) {
        AggregateResult row = [
            SELECT MAX(Calculation_Version__c) maxVersion
            FROM Asset_Schedule_Line__c
            WHERE Fixed_Asset__c = :assetId
              AND Book_Key__c = :bookKey
        ];

        Decimal maxVersion =
            (Decimal) row.get('maxVersion');

        if (maxVersion == null) {
            return 1;
        }

        return Integer.valueOf(
            String.valueOf(
                maxVersion.setScale(0)
            )
        ) + 1;
    }

    private static List<Accounting_Period__c>
        resolveSchedulePeriods(
            Id companyId,
            Date inServiceDate,
            Integer usefulLife
        )
    {
        List<Accounting_Period__c> startPeriods = [
            SELECT Id,
                   Start_Date__c,
                   End_Date__c,
                   Status__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
              AND Start_Date__c <= :inServiceDate
              AND End_Date__c >= :inServiceDate
            ORDER BY Start_Date__c
            LIMIT 2
        ];

        if (startPeriods.isEmpty()) {
            throw new FixedAssetScheduleException(
                'No Accounting Period contains the Fixed Asset In Service Date.'
            );
        }

        if (startPeriods.size() > 1) {
            throw new FixedAssetScheduleException(
                'More than one Accounting Period contains the Fixed Asset In Service Date.'
            );
        }

        Accounting_Period__c startPeriod =
            startPeriods[0];

        List<Accounting_Period__c> candidatePeriods = [
            SELECT Id,
                   Start_Date__c,
                   End_Date__c,
                   Status__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
              AND Start_Date__c >=
                    :startPeriod.Start_Date__c
            ORDER BY Start_Date__c ASC,
                     End_Date__c ASC
        ];

        if (
            candidatePeriods.size()
                < usefulLife
        ) {
            throw new FixedAssetScheduleException(
                'Not enough Accounting Periods exist to cover the Fixed Asset Useful Life.'
            );
        }

        List<Accounting_Period__c> selected =
            new List<Accounting_Period__c>();

        for (
            Integer index = 0;
            index < usefulLife;
            index++
        ) {
            Accounting_Period__c current =
                candidatePeriods[index];

            if (index > 0) {
                Accounting_Period__c prior =
                    candidatePeriods[index - 1];

                if (
                    current.Start_Date__c
                        != prior.End_Date__c.addDays(1)
                ) {
                    throw new FixedAssetScheduleException(
                        'Accounting Period coverage contains a gap or overlap and cannot support a depreciation schedule.'
                    );
                }
            }

            selected.add(current);
        }

        return selected;
    }

    private static ScheduleResult buildResult(
        Fixed_Asset__c asset,
        String bookKey,
        Integer calculationVersion,
        Decimal depreciableBase,
        List<Asset_Schedule_Line__c> rows,
        Boolean replay
    ) {
        ScheduleResult result =
            new ScheduleResult();

        result.fixedAssetId = asset.Id;
        result.bookKey = bookKey;
        result.calculationVersion =
            calculationVersion;
        result.lineCount = rows.size();
        result.plannedCount = 0;
        result.postedCount = 0;
        result.depreciableBase =
            depreciableBase;
        result.scheduledTotal = ZERO;
        result.replay = replay;

        for (
            Asset_Schedule_Line__c row :
            rows
        ) {
            result.scheduleLineIds.add(row.Id);

            result.scheduledTotal +=
                row.Planned_Depreciation__c;

            if (row.Status__c == STATUS_PLANNED) {
                result.plannedCount++;
            } else if (
                row.Status__c == STATUS_POSTED
            ) {
                result.postedCount++;
            }
        }

        result.scheduledTotal =
            SABMoneyService.normalizeLedgerAmount(
                result.scheduledTotal,
                RoundingMode.HALF_UP
            );

        return result;
    }
}
