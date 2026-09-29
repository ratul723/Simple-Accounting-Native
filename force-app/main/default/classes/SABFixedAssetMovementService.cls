/**
 * G9D - Fixed Asset Transfer, Impairment, Disposal & Movement Lifecycle.
 *
 * Supported policies in this stage:
 *
 * Transfer:
 * - non-financial
 * - updates custody/location/dimensions
 * - creates immutable Asset_Movement__c audit evidence
 * - requires an Open Accounting Period so closed periods cannot be backdated
 *
 * Impairment:
 * - permanent write-down policy; no impairment reversal in G9D
 * - Dr Asset Category Disposal Gain/Loss Account (must be Expense)
 * - Cr Asset Account
 * - prior Posted depreciation remains immutable
 * - future Planned schedule lines are superseded and regenerated from the
 *   reduced carrying amount
 * - Fixed Asset becomes Impaired but can continue depreciation
 *
 * Disposal:
 * - derecognizes the remaining asset-account balance
 * - clears accumulated depreciation
 * - optionally records cash proceeds through a Bank Account
 * - gain/loss is posted to the category Disposal Gain/Loss Account
 * - future Planned schedule lines are superseded
 * - Fixed Asset becomes Disposed
 *
 * Asset_Movement__c.Movement_Key__c is the replay/idempotency key.
 */
public with sharing class SABFixedAssetMovementService {

    public class FixedAssetMovementException extends Exception {}

    private static final String PERMISSION =
        'SAB_Manage_Asset_Movements';
    private static final String STATUS_IN_SERVICE =
        'In Service';
    private static final String STATUS_IMPAIRED =
        'Impaired';
    private static final String STATUS_DISPOSED =
        'Disposed';
    private static final String MOVEMENT_TRANSFER =
        'Transfer';
    private static final String MOVEMENT_IMPAIRMENT =
        'Impairment';
    private static final String MOVEMENT_DISPOSAL =
        'Disposal';
    private static final String SCHEDULE_PLANNED =
        'Planned';
    private static final String SCHEDULE_POSTED =
        'Posted';
    private static final String SCHEDULE_SUPERSEDED =
        'Superseded';
    private static final String ENTRY_TYPE =
        'Subledger';
    private static final Decimal ZERO =
        Decimal.valueOf('0');

    @TestVisible
    private static Boolean mutationInProgress = false;

    public static Boolean isMutationInProgress() {
        return mutationInProgress;
    }

    public class TransferRequest {
        @AuraEnabled public Id fixedAssetId { get; set; }
        @AuraEnabled public String movementKey { get; set; }
        @AuraEnabled public String bookKey { get; set; }
        @AuraEnabled public Date movementDate { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public Id toDepartmentId { get; set; }
        @AuraEnabled public Id toCostCenterId { get; set; }
        @AuraEnabled public Id toCustodianId { get; set; }
        @AuraEnabled public String toLocation { get; set; }
        @AuraEnabled public String reason { get; set; }
    }

    public class ImpairmentRequest {
        @AuraEnabled public Id fixedAssetId { get; set; }
        @AuraEnabled public String movementKey { get; set; }
        @AuraEnabled public String bookKey { get; set; }
        @AuraEnabled public Date movementDate { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public Decimal impairmentAmount { get; set; }
        @AuraEnabled public String requestKey { get; set; }
        @AuraEnabled public String reason { get; set; }
    }

    public class DisposalRequest {
        @AuraEnabled public Id fixedAssetId { get; set; }
        @AuraEnabled public String movementKey { get; set; }
        @AuraEnabled public String bookKey { get; set; }
        @AuraEnabled public Date movementDate { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public Decimal proceeds { get; set; }
        @AuraEnabled public Id bankAccountId { get; set; }
        @AuraEnabled public String requestKey { get; set; }
        @AuraEnabled public String reason { get; set; }
    }

    public class MovementResult {
        @AuraEnabled public Id movementId { get; private set; }
        @AuraEnabled public Id fixedAssetId { get; private set; }
        @AuraEnabled public String movementType { get; private set; }
        @AuraEnabled public Decimal amount { get; private set; }
        @AuraEnabled public Decimal proceeds { get; private set; }
        @AuraEnabled public Id journalEntryId { get; private set; }
        @AuraEnabled public Id accountingEventId { get; private set; }
        @AuraEnabled public String assetStatus { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private MovementResult() {}
    }

    @AuraEnabled
    public static MovementResult transferAsset(
        TransferRequest request
    ) {
        assertPermission();
        validateCommonRequest(
            request == null ? null : request.fixedAssetId,
            request == null ? null : request.movementKey,
            request == null ? null : request.bookKey,
            request == null ? null : request.movementDate,
            request == null ? null : request.accountingDate
        );

        Asset_Movement__c existing =
            findMovementByKey(
                request.movementKey.trim()
            );

        if (existing != null) {
            assertReplayCompatible(
                existing,
                request.fixedAssetId,
                MOVEMENT_TRANSFER,
                request.bookKey
            );
            return buildMovementResult(
                existing,
                existing.Fixed_Asset__r.Status__c,
                true
            );
        }

        Fixed_Asset__c asset =
            loadAssetForUpdate(
                request.fixedAssetId
            );

        SABCompanyAccessService.assertCompanyAccess(
            asset.Company__c
        );

        validateActiveAsset(asset);

        Accounting_Period__c period =
            resolveAndLockOpenPeriod(
                asset.Company__c,
                request.accountingDate
            );

        validateTransferTargets(
            asset.Company__c,
            request.toDepartmentId,
            request.toCostCenterId,
            request.toCustodianId
        );

        String normalizedLocation =
            normalizeOptionalText(
                request.toLocation
            );

        Boolean changed =
            asset.Department__c != request.toDepartmentId
            || asset.Cost_Center__c != request.toCostCenterId
            || asset.Custodian__c != request.toCustodianId
            || normalizeOptionalText(asset.Location__c)
                != normalizedLocation;

        if (!changed) {
            throw new FixedAssetMovementException(
                'Transfer must change at least one Fixed Asset custody, location or reporting dimension.'
            );
        }

        Asset_Movement__c movement =
            new Asset_Movement__c(
                Fixed_Asset__c = asset.Id,
                Movement_Type__c = MOVEMENT_TRANSFER,
                Movement_Date__c = request.movementDate,
                Accounting_Date__c = request.accountingDate,
                Period__c = period.Id,
                Amount__c = ZERO,
                Book_Key__c = request.bookKey.trim(),
                Movement_Key__c = request.movementKey.trim(),
                From_Department__c = asset.Department__c,
                To_Department__c = request.toDepartmentId,
                From_Cost_Center__c = asset.Cost_Center__c,
                To_Cost_Center__c = request.toCostCenterId,
                From_Custodian__c = asset.Custodian__c,
                To_Custodian__c = request.toCustodianId,
                From_Location__c =
                    normalizeOptionalText(asset.Location__c),
                To_Location__c = normalizedLocation,
                Reason__c =
                    normalizeOptionalText(request.reason)
            );

        mutationInProgress = true;
        try {
            insert movement;

            asset.Department__c =
                request.toDepartmentId;
            asset.Cost_Center__c =
                request.toCostCenterId;
            asset.Custodian__c =
                request.toCustodianId;
            asset.Location__c =
                normalizedLocation;
            update asset;
        } finally {
            mutationInProgress = false;
        }

        return buildMovementResult(
            movement,
            asset.Status__c,
            false
        );
    }

    @AuraEnabled
    public static MovementResult recordImpairment(
        ImpairmentRequest request
    ) {
        assertPermission();

        if (request == null) {
            throw new FixedAssetMovementException(
                'Fixed Asset impairment request is required.'
            );
        }

        validateCommonRequest(
            request.fixedAssetId,
            request.movementKey,
            request.bookKey,
            request.movementDate,
            request.accountingDate
        );
        validateRequestKey(request.requestKey);

        Decimal impairmentAmount =
            SABMoneyService.normalizeLedgerAmount(
                request.impairmentAmount,
                RoundingMode.HALF_UP
            );

        if (impairmentAmount <= ZERO) {
            throw new FixedAssetMovementException(
                'Impairment Amount must be greater than zero.'
            );
        }

        Asset_Movement__c existing =
            findMovementByKey(
                request.movementKey.trim()
            );

        if (existing != null) {
            assertReplayCompatible(
                existing,
                request.fixedAssetId,
                MOVEMENT_IMPAIRMENT,
                request.bookKey
            );

            if (existing.Amount__c != impairmentAmount) {
                throw new FixedAssetMovementException(
                    'Movement Key already exists with a different impairment amount.'
                );
            }

            return resolveFinancialReplay(existing);
        }

        Savepoint savepointValue =
            Database.setSavepoint();

        try {
            Fixed_Asset__c asset =
                loadAssetForUpdate(
                    request.fixedAssetId
                );

            SABCompanyAccessService.assertCompanyAccess(
                asset.Company__c
            );

            validateActiveAsset(asset);
            validateImpairmentAccount(asset);

            Accounting_Period__c period =
                resolveAndLockOpenPeriod(
                    asset.Company__c,
                    request.accountingDate
                );

            assertNoDuePlannedDepreciation(
                asset.Id,
                request.bookKey.trim(),
                request.accountingDate
            );

            Decimal postedDepreciation =
                postedDepreciationTotal(
                    asset.Id,
                    request.bookKey.trim()
                );

            Decimal priorImpairment =
                postedImpairmentTotal(
                    asset.Id,
                    request.bookKey.trim()
                );

            Decimal carryingBefore =
                SABMoneyService.normalizeLedgerAmount(
                    asset.Functional_Currency_Cost__c
                    - postedDepreciation
                    - priorImpairment,
                    RoundingMode.HALF_UP
                );

            Decimal residual =
                asset.Residual_Value__c == null
                    ? ZERO
                    : asset.Residual_Value__c;

            Decimal maximumImpairment =
                SABMoneyService.normalizeLedgerAmount(
                    carryingBefore - residual,
                    RoundingMode.HALF_UP
                );

            if (
                maximumImpairment <= ZERO
                || impairmentAmount > maximumImpairment
            ) {
                throw new FixedAssetMovementException(
                    'Impairment Amount cannot reduce the Fixed Asset below its Residual Value.'
                );
            }

            Asset_Movement__c movement =
                createMovement(
                    asset,
                    MOVEMENT_IMPAIRMENT,
                    request.movementDate,
                    request.accountingDate,
                    period.Id,
                    impairmentAmount,
                    request.bookKey.trim(),
                    request.movementKey.trim(),
                    request.reason
                );

            SABPostingService.PostingResult posted =
                postFinancialMovement(
                    movement,
                    asset,
                    request.requestKey.trim(),
                    'Other',
                    'FIXED_ASSET_IMPAIRMENT',
                    impairmentJournalLines(
                        movement,
                        asset,
                        impairmentAmount
                    )
                );

            movement.Journal_Entry__c =
                posted.journalEntryId;
            movement.Accounting_Event__c =
                posted.accountingEventId;

            Decimal carryingAfter =
                SABMoneyService.normalizeLedgerAmount(
                    carryingBefore - impairmentAmount,
                    RoundingMode.HALF_UP
                );

            Decimal futureDepreciable =
                SABMoneyService.normalizeLedgerAmount(
                    carryingAfter - residual,
                    RoundingMode.HALF_UP
                );

            regenerateFutureSchedule(
                asset.Id,
                request.bookKey.trim(),
                request.accountingDate,
                futureDepreciable
            );

            asset.Status__c =
                STATUS_IMPAIRED;

            mutationInProgress = true;
            try {
                update movement;
                update asset;
            } finally {
                mutationInProgress = false;
            }

            return buildMovementResult(
                movement,
                asset.Status__c,
                false
            );
        } catch (Exception ex) {
            Database.rollback(savepointValue);
            throw ex;
        }
    }

    @AuraEnabled
    public static MovementResult disposeAsset(
        DisposalRequest request
    ) {
        assertPermission();

        if (request == null) {
            throw new FixedAssetMovementException(
                'Fixed Asset disposal request is required.'
            );
        }

        validateCommonRequest(
            request.fixedAssetId,
            request.movementKey,
            request.bookKey,
            request.movementDate,
            request.accountingDate
        );
        validateRequestKey(request.requestKey);

        Decimal proceeds =
            request.proceeds == null
                ? ZERO
                : SABMoneyService.normalizeLedgerAmount(
                    request.proceeds,
                    RoundingMode.HALF_UP
                );

        if (proceeds < ZERO) {
            throw new FixedAssetMovementException(
                'Disposal Proceeds cannot be negative.'
            );
        }

        Asset_Movement__c existing =
            findMovementByKey(
                request.movementKey.trim()
            );

        if (existing != null) {
            assertReplayCompatible(
                existing,
                request.fixedAssetId,
                MOVEMENT_DISPOSAL,
                request.bookKey
            );

            if (
                (existing.Disposal_Proceeds__c == null
                    ? ZERO
                    : existing.Disposal_Proceeds__c)
                != proceeds
            ) {
                throw new FixedAssetMovementException(
                    'Movement Key already exists with different disposal proceeds.'
                );
            }

            return resolveFinancialReplay(existing);
        }

        Savepoint savepointValue =
            Database.setSavepoint();

        try {
            Fixed_Asset__c asset =
                loadAssetForUpdate(
                    request.fixedAssetId
                );

            SABCompanyAccessService.assertCompanyAccess(
                asset.Company__c
            );

            validateActiveAsset(asset);
            validateDisposalAccounts(asset);

            Accounting_Period__c period =
                resolveAndLockOpenPeriod(
                    asset.Company__c,
                    request.accountingDate
                );

            assertNoDuePlannedDepreciation(
                asset.Id,
                request.bookKey.trim(),
                request.accountingDate
            );

            Decimal postedDepreciation =
                postedDepreciationTotal(
                    asset.Id,
                    request.bookKey.trim()
                );

            Decimal priorImpairment =
                postedImpairmentTotal(
                    asset.Id,
                    request.bookKey.trim()
                );

            Decimal assetAccountBalance =
                SABMoneyService.normalizeLedgerAmount(
                    asset.Functional_Currency_Cost__c
                    - priorImpairment,
                    RoundingMode.HALF_UP
                );

            Decimal carryingAmount =
                SABMoneyService.normalizeLedgerAmount(
                    assetAccountBalance
                    - postedDepreciation,
                    RoundingMode.HALF_UP
                );

            if (carryingAmount < ZERO) {
                throw new FixedAssetMovementException(
                    'Fixed Asset carrying amount cannot be negative.'
                );
            }

            Bank_Account__c bankAccount =
                validateDisposalBank(
                    asset,
                    proceeds,
                    request.bankAccountId
                );

            Asset_Movement__c movement =
                createMovement(
                    asset,
                    MOVEMENT_DISPOSAL,
                    request.movementDate,
                    request.accountingDate,
                    period.Id,
                    carryingAmount,
                    request.bookKey.trim(),
                    request.movementKey.trim(),
                    request.reason
                );

            movement.Disposal_Proceeds__c =
                proceeds;
            movement.Disposal_Bank_Account__c =
                bankAccount == null
                    ? null
                    : bankAccount.Id;

            mutationInProgress = true;
            try {
                update movement;
            } finally {
                mutationInProgress = false;
            }

            SABPostingService.PostingResult posted =
                postFinancialMovement(
                    movement,
                    asset,
                    request.requestKey.trim(),
                    'Asset Disposal',
                    'FIXED_ASSET_DISPOSAL',
                    disposalJournalLines(
                        movement,
                        asset,
                        bankAccount,
                        proceeds,
                        postedDepreciation,
                        assetAccountBalance,
                        carryingAmount
                    )
                );

            movement.Journal_Entry__c =
                posted.journalEntryId;
            movement.Accounting_Event__c =
                posted.accountingEventId;

            supersedeFutureSchedule(
                asset.Id,
                request.bookKey.trim(),
                request.accountingDate
            );

            asset.Status__c =
                STATUS_DISPOSED;

            mutationInProgress = true;
            try {
                update movement;
                update asset;
            } finally {
                mutationInProgress = false;
            }

            return buildMovementResult(
                movement,
                asset.Status__c,
                false
            );
        } catch (Exception ex) {
            Database.rollback(savepointValue);
            throw ex;
        }
    }

    private static Asset_Movement__c createMovement(
        Fixed_Asset__c asset,
        String movementType,
        Date movementDate,
        Date accountingDate,
        Id periodId,
        Decimal amount,
        String bookKey,
        String movementKey,
        String reason
    ) {
        Asset_Movement__c movement =
            new Asset_Movement__c(
                Fixed_Asset__c =
                    asset.Id,
                Movement_Type__c =
                    movementType,
                Movement_Date__c =
                    movementDate,
                Accounting_Date__c =
                    accountingDate,
                Period__c =
                    periodId,
                Amount__c =
                    amount,
                Book_Key__c =
                    bookKey,
                Movement_Key__c =
                    movementKey,
                Reason__c =
                    normalizeOptionalText(reason)
            );

        mutationInProgress = true;
        try {
            insert movement;
        } finally {
            mutationInProgress = false;
        }

        return movement;
    }

    private static SABPostingService.PostingResult
        postFinancialMovement(
            Asset_Movement__c movement,
            Fixed_Asset__c asset,
            String requestKey,
            String eventType,
            String adapterKey,
            List<Journal_Entry_Line__c> journalLines
        )
    {
        Journal_Entry__c journal =
            new Journal_Entry__c(
                Company__c =
                    asset.Company__c,
                Accounting_Period__c =
                    movement.Period__c,
                Accounting_Date__c =
                    movement.Accounting_Date__c,
                Entry_Type__c =
                    ENTRY_TYPE,
                Status__c =
                    'Draft',
                Description__c =
                    truncateText(
                        movement.Movement_Type__c
                        + ' - '
                        + asset.Name,
                        Journal_Entry__c.Description__c.getDescribe().getLength()
                    ),
                Version__c = 1
            );
        insert journal;

        Integer lineNumber = 1;

        for (
            Journal_Entry_Line__c journalLine :
            journalLines
        ) {
            journalLine.Journal_Entry__c =
                journal.Id;
            journalLine.Line_Number__c =
                lineNumber;
            lineNumber++;
        }

        insert journalLines;

        SABAccountingEventService.ReservationRequest
            eventRequest =
                new SABAccountingEventService.ReservationRequest();

        eventRequest.companyId =
            asset.Company__c;
        eventRequest.adapterKey =
            adapterKey;
        eventRequest.requestKey =
            requestKey;
        eventRequest.eventKey =
            buildEventKey(
                movement.Movement_Type__c,
                movement.Id
            );
        eventRequest.eventType =
            eventType;
        eventRequest.sourceBusinessKey =
            movement.Movement_Key__c;
        eventRequest.sourceRecordId =
            String.valueOf(
                movement.Id
            );
        eventRequest.sourceType =
            'Asset_Movement__c';
        eventRequest.sourceVersion =
            1;

        SABPostingService.PostingRequest
            postingRequest =
                new SABPostingService.PostingRequest();

        postingRequest.journalEntryId =
            journal.Id;
        postingRequest.postingKey =
            buildPostingKey(
                movement.Id
            );
        postingRequest.eventRequest =
            eventRequest;

        return SABPostingService.postDraftJournal(
            postingRequest
        );
    }

    private static List<Journal_Entry_Line__c>
        impairmentJournalLines(
            Asset_Movement__c movement,
            Fixed_Asset__c asset,
            Decimal amount
        )
    {
        String functionalCurrency =
            SABMoneyService.normalizeCurrencyCode(
                asset.Company__r.Functional_Currency__c
            );

        return new List<Journal_Entry_Line__c>{
            financialLine(
                asset.Asset_Category__r.Disposal_Gain_Loss_Account__c,
                amount,
                ZERO,
                'Fixed Asset impairment loss',
                functionalCurrency,
                movement.Accounting_Date__c,
                asset.Department__c,
                asset.Cost_Center__c,
                'FAIMP|'
                    + String.valueOf(movement.Id)
                    + '|LOSS'
            ),
            financialLine(
                asset.Asset_Category__r.Asset_Account__c,
                ZERO,
                amount,
                'Fixed Asset impairment write-down',
                functionalCurrency,
                movement.Accounting_Date__c,
                asset.Department__c,
                asset.Cost_Center__c,
                'FAIMP|'
                    + String.valueOf(movement.Id)
                    + '|ASSET'
            )
        };
    }

    private static List<Journal_Entry_Line__c>
        disposalJournalLines(
            Asset_Movement__c movement,
            Fixed_Asset__c asset,
            Bank_Account__c bankAccount,
            Decimal proceeds,
            Decimal postedDepreciation,
            Decimal assetAccountBalance,
            Decimal carryingAmount
        )
    {
        String functionalCurrency =
            SABMoneyService.normalizeCurrencyCode(
                asset.Company__r.Functional_Currency__c
            );

        List<Journal_Entry_Line__c> rows =
            new List<Journal_Entry_Line__c>();

        if (postedDepreciation > ZERO) {
            rows.add(
                financialLine(
                    asset.Asset_Category__r.Accumulated_Depreciation_Account__c,
                    postedDepreciation,
                    ZERO,
                    'Clear accumulated depreciation on disposal',
                    functionalCurrency,
                    movement.Accounting_Date__c,
                    asset.Department__c,
                    asset.Cost_Center__c,
                    'FADISP|'
                        + String.valueOf(movement.Id)
                        + '|ACCUM'
                )
            );
        }

        if (proceeds > ZERO) {
            rows.add(
                financialLine(
                    bankAccount.GL_Account__c,
                    proceeds,
                    ZERO,
                    'Fixed Asset disposal proceeds',
                    functionalCurrency,
                    movement.Accounting_Date__c,
                    asset.Department__c,
                    asset.Cost_Center__c,
                    'FADISP|'
                        + String.valueOf(movement.Id)
                        + '|BANK'
                )
            );
        }

        Decimal difference =
            SABMoneyService.normalizeLedgerAmount(
                carryingAmount - proceeds,
                RoundingMode.HALF_UP
            );

        if (difference > ZERO) {
            rows.add(
                financialLine(
                    asset.Asset_Category__r.Disposal_Gain_Loss_Account__c,
                    difference,
                    ZERO,
                    'Fixed Asset disposal loss',
                    functionalCurrency,
                    movement.Accounting_Date__c,
                    asset.Department__c,
                    asset.Cost_Center__c,
                    'FADISP|'
                        + String.valueOf(movement.Id)
                        + '|LOSS'
                )
            );
        } else if (difference < ZERO) {
            rows.add(
                financialLine(
                    asset.Asset_Category__r.Disposal_Gain_Loss_Account__c,
                    ZERO,
                    -difference,
                    'Fixed Asset disposal gain',
                    functionalCurrency,
                    movement.Accounting_Date__c,
                    asset.Department__c,
                    asset.Cost_Center__c,
                    'FADISP|'
                        + String.valueOf(movement.Id)
                        + '|GAIN'
                )
            );
        }

        rows.add(
            financialLine(
                asset.Asset_Category__r.Asset_Account__c,
                ZERO,
                assetAccountBalance,
                'Derecognize Fixed Asset cost basis',
                functionalCurrency,
                movement.Accounting_Date__c,
                asset.Department__c,
                asset.Cost_Center__c,
                'FADISP|'
                    + String.valueOf(movement.Id)
                    + '|ASSET'
            )
        );

        return rows;
    }

    private static Journal_Entry_Line__c financialLine(
        Id accountId,
        Decimal debit,
        Decimal credit,
        String explanation,
        String functionalCurrency,
        Date accountingDate,
        Id departmentId,
        Id costCenterId,
        String sourceLineKey
    ) {
        Decimal transactionAmount =
            debit > ZERO
                ? debit
                : credit;

        return new Journal_Entry_Line__c(
            GL_Account__c =
                accountId,
            Debit_Base__c =
                debit,
            Credit_Base__c =
                credit,
            Explanation__c =
                explanation,
            Transaction_Amount__c =
                transactionAmount,
            Transaction_Currency__c =
                functionalCurrency,
            Functional_Currency__c =
                functionalCurrency,
            Applied_Exchange_Rate__c =
                Decimal.valueOf('1'),
            Rate_Date__c =
                accountingDate,
            Rate_Source__c =
                'Fixed Asset Movement',
            Source_Line_Key__c =
                sourceLineKey,
            Department__c =
                departmentId,
            Cost_Center__c =
                costCenterId
        );
    }

    private static Fixed_Asset__c loadAssetForUpdate(
        Id assetId
    ) {
        List<Fixed_Asset__c> rows = [
            SELECT Id,
                   Name,
                   Company__c,
                   Company__r.Functional_Currency__c,
                   Company_Asset_Key__c,
                   Status__c,
                   Functional_Currency_Cost__c,
                   Residual_Value__c,
                   Department__c,
                   Cost_Center__c,
                   Custodian__c,
                   Location__c,
                   Asset_Category__c,
                   Asset_Category__r.Company__c,
                   Asset_Category__r.Asset_Account__c,
                   Asset_Category__r.Asset_Account__r.Company__c,
                   Asset_Category__r.Asset_Account__r.Is_Active__c,
                   Asset_Category__r.Asset_Account__r.Account_Type__c,
                   Asset_Category__r.Asset_Account__r.Is_Control_Account__c,
                   Asset_Category__r.Accumulated_Depreciation_Account__c,
                   Asset_Category__r.Accumulated_Depreciation_Account__r.Company__c,
                   Asset_Category__r.Accumulated_Depreciation_Account__r.Is_Active__c,
                   Asset_Category__r.Accumulated_Depreciation_Account__r.Account_Type__c,
                   Asset_Category__r.Accumulated_Depreciation_Account__r.Is_Control_Account__c,
                   Asset_Category__r.Disposal_Gain_Loss_Account__c,
                   Asset_Category__r.Disposal_Gain_Loss_Account__r.Company__c,
                   Asset_Category__r.Disposal_Gain_Loss_Account__r.Is_Active__c,
                   Asset_Category__r.Disposal_Gain_Loss_Account__r.Account_Type__c,
                   Asset_Category__r.Disposal_Gain_Loss_Account__r.Is_Control_Account__c
            FROM Fixed_Asset__c
            WHERE Id = :assetId
            LIMIT 1
            FOR UPDATE
        ];

        if (rows.isEmpty()) {
            throw new FixedAssetMovementException(
                'Fixed Asset was not found.'
            );
        }

        return rows[0];
    }

    private static void validateActiveAsset(
        Fixed_Asset__c asset
    ) {
        if (
            asset.Status__c != STATUS_IN_SERVICE
            && asset.Status__c != STATUS_IMPAIRED
        ) {
            throw new FixedAssetMovementException(
                'Fixed Asset must be In Service or Impaired for this movement.'
            );
        }

        if (
            asset.Asset_Category__r == null
            || asset.Asset_Category__r.Company__c
                != asset.Company__c
        ) {
            throw new FixedAssetMovementException(
                'Fixed Asset Category must belong to the same Accounting Company.'
            );
        }
    }

    private static void validateImpairmentAccount(
        Fixed_Asset__c asset
    ) {
        validateAssetAccount(asset);

        GL_Account__c account =
            asset.Asset_Category__r.Disposal_Gain_Loss_Account__r;

        if (
            account == null
            || account.Company__c != asset.Company__c
            || account.Is_Active__c != true
            || account.Account_Type__c != 'Expense'
            || account.Is_Control_Account__c == true
        ) {
            throw new FixedAssetMovementException(
                'G9D impairment policy requires the Asset Category Disposal Gain/Loss Account to be an active, non-control Expense account in the same Accounting Company.'
            );
        }
    }

    private static void validateDisposalAccounts(
        Fixed_Asset__c asset
    ) {
        validateAssetAccount(asset);

        GL_Account__c accumulated =
            asset.Asset_Category__r.Accumulated_Depreciation_Account__r;

        if (
            accumulated == null
            || accumulated.Company__c != asset.Company__c
            || accumulated.Is_Active__c != true
            || accumulated.Account_Type__c != 'Asset'
            || accumulated.Is_Control_Account__c == true
        ) {
            throw new FixedAssetMovementException(
                'Accumulated Depreciation Account must be an active, non-control Asset account in the same Accounting Company.'
            );
        }

        GL_Account__c gainLoss =
            asset.Asset_Category__r.Disposal_Gain_Loss_Account__r;

        if (
            gainLoss == null
            || gainLoss.Company__c != asset.Company__c
            || gainLoss.Is_Active__c != true
            || (
                gainLoss.Account_Type__c != 'Expense'
                && gainLoss.Account_Type__c != 'Revenue'
            )
            || gainLoss.Is_Control_Account__c == true
        ) {
            throw new FixedAssetMovementException(
                'Disposal Gain/Loss Account must be an active, non-control Expense or Revenue account in the same Accounting Company.'
            );
        }
    }

    private static void validateAssetAccount(
        Fixed_Asset__c asset
    ) {
        GL_Account__c account =
            asset.Asset_Category__r.Asset_Account__r;

        if (
            account == null
            || account.Company__c != asset.Company__c
            || account.Is_Active__c != true
            || account.Account_Type__c != 'Asset'
            || account.Is_Control_Account__c == true
        ) {
            throw new FixedAssetMovementException(
                'Asset Account must be an active, non-control Asset account in the same Accounting Company.'
            );
        }
    }

    private static Bank_Account__c validateDisposalBank(
        Fixed_Asset__c asset,
        Decimal proceeds,
        Id bankAccountId
    ) {
        if (proceeds == ZERO) {
            if (bankAccountId != null) {
                throw new FixedAssetMovementException(
                    'Disposal Bank Account must be blank when Disposal Proceeds are zero.'
                );
            }
            return null;
        }

        if (bankAccountId == null) {
            throw new FixedAssetMovementException(
                'Disposal Bank Account is required when Disposal Proceeds are greater than zero.'
            );
        }

        List<Bank_Account__c> rows = [
            SELECT Id,
                   Company__c,
                   Currency__c,
                   Is_Active__c,
                   GL_Account__c,
                   GL_Account__r.Company__c,
                   GL_Account__r.Is_Active__c,
                   GL_Account__r.Account_Type__c,
                   GL_Account__r.Is_Control_Account__c
            FROM Bank_Account__c
            WHERE Id = :bankAccountId
            LIMIT 1
        ];

        if (rows.isEmpty()) {
            throw new FixedAssetMovementException(
                'Disposal Bank Account was not found.'
            );
        }

        Bank_Account__c bank =
            rows[0];

        String companyCurrency =
            SABMoneyService.normalizeCurrencyCode(
                asset.Company__r.Functional_Currency__c
            );

        String bankCurrency =
            SABMoneyService.normalizeCurrencyCode(
                bank.Currency__c
            );

        if (
            bank.Company__c != asset.Company__c
            || bank.Is_Active__c != true
            || bankCurrency != companyCurrency
            || bank.GL_Account__c == null
            || bank.GL_Account__r.Company__c
                != asset.Company__c
            || bank.GL_Account__r.Is_Active__c
                != true
            || bank.GL_Account__r.Account_Type__c
                != 'Asset'
            || bank.GL_Account__r.Is_Control_Account__c
                == true
        ) {
            throw new FixedAssetMovementException(
                'Disposal Bank Account must be an active functional-currency bank with an active non-control Asset GL in the same Accounting Company.'
            );
        }

        return bank;
    }

    private static void validateTransferTargets(
        Id companyId,
        Id departmentId,
        Id costCenterId,
        Id custodianId
    ) {
        if (departmentId != null) {
            Department__c department = [
                SELECT Id, Company__c
                FROM Department__c
                WHERE Id = :departmentId
                LIMIT 1
            ];

            if (department.Company__c != companyId) {
                throw new FixedAssetMovementException(
                    'Transfer Department must belong to the same Accounting Company.'
                );
            }
        }

        if (costCenterId != null) {
            Cost_Center__c costCenter = [
                SELECT Id, Company__c
                FROM Cost_Center__c
                WHERE Id = :costCenterId
                LIMIT 1
            ];

            if (costCenter.Company__c != companyId) {
                throw new FixedAssetMovementException(
                    'Transfer Cost Center must belong to the same Accounting Company.'
                );
            }
        }

        if (custodianId != null) {
            Integer activeEmploymentCount = [
                SELECT COUNT()
                FROM Employment__c
                WHERE Employee__c = :custodianId
                  AND Company__c = :companyId
                  AND Employment_Status__c = 'Active'
            ];

            if (activeEmploymentCount == 0) {
                throw new FixedAssetMovementException(
                    'Transfer Custodian must have an active Employment in the same Accounting Company.'
                );
            }
        }
    }

    private static Accounting_Period__c
        resolveAndLockOpenPeriod(
            Id companyId,
            Date accountingDate
        )
    {
        List<Accounting_Period__c> periods = [
            SELECT Id,
                   Company__c,
                   Start_Date__c,
                   End_Date__c,
                   Status__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
              AND Start_Date__c <= :accountingDate
              AND End_Date__c >= :accountingDate
            LIMIT 2
            FOR UPDATE
        ];

        if (periods.isEmpty()) {
            throw new FixedAssetMovementException(
                'No Accounting Period contains the Asset Movement Accounting Date.'
            );
        }

        if (periods.size() > 1) {
            throw new FixedAssetMovementException(
                'More than one Accounting Period contains the Asset Movement Accounting Date.'
            );
        }

        if (periods[0].Status__c != 'Open') {
            throw new FixedAssetMovementException(
                'Asset Movement Accounting Period must be Open.'
            );
        }

        return periods[0];
    }

    private static void assertNoDuePlannedDepreciation(
        Id assetId,
        String bookKey,
        Date accountingDate
    ) {
        Integer dueCount = [
            SELECT COUNT()
            FROM Asset_Schedule_Line__c
            WHERE Fixed_Asset__c = :assetId
              AND Book_Key__c = :bookKey
              AND Status__c = :SCHEDULE_PLANNED
              AND Scheduled_Date__c <= :accountingDate
        ];

        if (dueCount > 0) {
            throw new FixedAssetMovementException(
                'All depreciation schedule lines due on or before the movement Accounting Date must be posted first.'
            );
        }
    }

    private static Decimal postedDepreciationTotal(
        Id assetId,
        String bookKey
    ) {
        AggregateResult row = [
            SELECT SUM(Planned_Depreciation__c) total
            FROM Asset_Schedule_Line__c
            WHERE Fixed_Asset__c = :assetId
              AND Book_Key__c = :bookKey
              AND Status__c = :SCHEDULE_POSTED
        ];

        Decimal amount =
            (Decimal) row.get('total');

        return SABMoneyService.normalizeLedgerAmount(
            amount == null ? ZERO : amount,
            RoundingMode.HALF_UP
        );
    }

    private static Decimal postedImpairmentTotal(
        Id assetId,
        String bookKey
    ) {
        AggregateResult row = [
            SELECT SUM(Amount__c) total
            FROM Asset_Movement__c
            WHERE Fixed_Asset__c = :assetId
              AND Book_Key__c = :bookKey
              AND Movement_Type__c = :MOVEMENT_IMPAIRMENT
              AND Accounting_Event__c != null
              AND Journal_Entry__c != null
        ];

        Decimal amount =
            (Decimal) row.get('total');

        return SABMoneyService.normalizeLedgerAmount(
            amount == null ? ZERO : amount,
            RoundingMode.HALF_UP
        );
    }

    private static void regenerateFutureSchedule(
        Id assetId,
        String bookKey,
        Date accountingDate,
        Decimal futureDepreciable
    ) {
        List<Asset_Schedule_Line__c> futureLines = [
            SELECT Id,
                   Period__c,
                   Scheduled_Date__c,
                   Planned_Depreciation__c,
                   Calculation_Version__c,
                   Status__c
            FROM Asset_Schedule_Line__c
            WHERE Fixed_Asset__c = :assetId
              AND Book_Key__c = :bookKey
              AND Status__c = :SCHEDULE_PLANNED
              AND Scheduled_Date__c > :accountingDate
            FOR UPDATE
        ];

        if (
            futureLines.isEmpty()
            && futureDepreciable > ZERO
        ) {
            throw new FixedAssetMovementException(
                'No future Planned depreciation schedule lines exist to regenerate after impairment.'
            );
        }

        if (futureLines.isEmpty()) {
            return;
        }

        Decimal maxVersion = ZERO;

        for (AggregateResult row : [
            SELECT MAX(Calculation_Version__c) maxVersion
            FROM Asset_Schedule_Line__c
            WHERE Fixed_Asset__c = :assetId
              AND Book_Key__c = :bookKey
        ]) {
            Decimal value =
                (Decimal) row.get('maxVersion');
            if (value != null) {
                maxVersion = value;
            }
        }

        Decimal newVersion =
            maxVersion + Decimal.valueOf('1');

        List<Asset_Schedule_Line__c> replacements =
            new List<Asset_Schedule_Line__c>();

        Decimal regularAmount =
            futureDepreciable == ZERO
                ? ZERO
                : SABMoneyService.normalizeLedgerAmount(
                    futureDepreciable
                    / Decimal.valueOf(
                        String.valueOf(
                            futureLines.size()
                        )
                    ),
                    RoundingMode.HALF_UP
                );

        Decimal scheduledBeforeFinal = ZERO;

        for (
            Integer index = 0;
            index < futureLines.size();
            index++
        ) {
            Asset_Schedule_Line__c oldLine =
                futureLines[index];

            oldLine.Status__c =
                SCHEDULE_SUPERSEDED;

            if (futureDepreciable > ZERO) {
                Decimal amount;

                if (
                    index
                    == futureLines.size() - 1
                ) {
                    amount =
                        SABMoneyService.normalizeLedgerAmount(
                            futureDepreciable
                            - scheduledBeforeFinal,
                            RoundingMode.HALF_UP
                        );
                } else {
                    amount = regularAmount;
                    scheduledBeforeFinal +=
                        amount;
                }

                replacements.add(
                    new Asset_Schedule_Line__c(
                        Fixed_Asset__c =
                            assetId,
                        Period__c =
                            oldLine.Period__c,
                        Scheduled_Date__c =
                            oldLine.Scheduled_Date__c,
                        Planned_Depreciation__c =
                            amount,
                        Book_Key__c =
                            bookKey,
                        Calculation_Version__c =
                            newVersion,
                        Status__c =
                            SCHEDULE_PLANNED
                    )
                );
            }
        }

        mutationInProgress = true;
        try {
            update futureLines;
            if (!replacements.isEmpty()) {
                insert replacements;
            }
        } finally {
            mutationInProgress = false;
        }
    }

    private static void supersedeFutureSchedule(
        Id assetId,
        String bookKey,
        Date accountingDate
    ) {
        List<Asset_Schedule_Line__c> futureLines = [
            SELECT Id, Status__c
            FROM Asset_Schedule_Line__c
            WHERE Fixed_Asset__c = :assetId
              AND Book_Key__c = :bookKey
              AND Status__c = :SCHEDULE_PLANNED
              AND Scheduled_Date__c > :accountingDate
            FOR UPDATE
        ];

        if (futureLines.isEmpty()) {
            return;
        }

        for (
            Asset_Schedule_Line__c line :
            futureLines
        ) {
            line.Status__c =
                SCHEDULE_SUPERSEDED;
        }

        mutationInProgress = true;
        try {
            update futureLines;
        } finally {
            mutationInProgress = false;
        }
    }

    private static Asset_Movement__c findMovementByKey(
        String movementKey
    ) {
        List<Asset_Movement__c> rows = [
            SELECT Id,
                   Fixed_Asset__c,
                   Fixed_Asset__r.Status__c,
                   Movement_Type__c,
                   Movement_Date__c,
                   Accounting_Date__c,
                   Period__c,
                   Amount__c,
                   Book_Key__c,
                   Movement_Key__c,
                   Journal_Entry__c,
                   Accounting_Event__c,
                   Disposal_Proceeds__c
            FROM Asset_Movement__c
            WHERE Movement_Key__c = :movementKey
            LIMIT 1
        ];

        return rows.isEmpty()
            ? null
            : rows[0];
    }

    private static void assertReplayCompatible(
        Asset_Movement__c movement,
        Id assetId,
        String movementType,
        String bookKey
    ) {
        if (
            movement.Fixed_Asset__c != assetId
            || movement.Movement_Type__c != movementType
            || movement.Book_Key__c != bookKey.trim()
        ) {
            throw new FixedAssetMovementException(
                'Movement Key has already been used for a different Fixed Asset movement.'
            );
        }
    }

    private static MovementResult resolveFinancialReplay(
        Asset_Movement__c movement
    ) {
        if (
            movement.Accounting_Event__c == null
            || movement.Journal_Entry__c == null
        ) {
            throw new FixedAssetMovementException(
                'Existing financial Asset Movement is incomplete.'
            );
        }

        Accounting_Event__c eventRecord = [
            SELECT Id,
                   Company__c,
                   State__c,
                   Journal_Entry__c,
                   Journal_Entry__r.Status__c,
                   Journal_Entry__r.Posting_Key__c
            FROM Accounting_Event__c
            WHERE Id = :movement.Accounting_Event__c
            LIMIT 1
        ];

        if (
            eventRecord.State__c != 'Posted'
            || eventRecord.Journal_Entry__c
                != movement.Journal_Entry__c
            || eventRecord.Journal_Entry__r.Status__c
                != 'Posted'
            || eventRecord.Journal_Entry__r.Posting_Key__c
                != buildPostingKey(
                    movement.Id
                )
        ) {
            throw new FixedAssetMovementException(
                'Existing financial Asset Movement does not have a consistent posted accounting chain.'
            );
        }

        return buildMovementResult(
            movement,
            movement.Fixed_Asset__r.Status__c,
            true
        );
    }

    private static MovementResult buildMovementResult(
        Asset_Movement__c movement,
        String assetStatus,
        Boolean replay
    ) {
        MovementResult result =
            new MovementResult();

        result.movementId =
            movement.Id;
        result.fixedAssetId =
            movement.Fixed_Asset__c;
        result.movementType =
            movement.Movement_Type__c;
        result.amount =
            movement.Amount__c;
        result.proceeds =
            movement.Disposal_Proceeds__c == null
                ? ZERO
                : movement.Disposal_Proceeds__c;
        result.journalEntryId =
            movement.Journal_Entry__c;
        result.accountingEventId =
            movement.Accounting_Event__c;
        result.assetStatus =
            assetStatus;
        result.replay =
            replay;

        return result;
    }

    private static void validateCommonRequest(
        Id assetId,
        String movementKey,
        String bookKey,
        Date movementDate,
        Date accountingDate
    ) {
        if (assetId == null) {
            throw new FixedAssetMovementException(
                'Fixed Asset Id is required.'
            );
        }

        requireText(
            movementKey,
            'Movement Key'
        );
        requireText(
            bookKey,
            'Book Key'
        );

        if (movementDate == null) {
            throw new FixedAssetMovementException(
                'Movement Date is required.'
            );
        }

        if (accountingDate == null) {
            throw new FixedAssetMovementException(
                'Accounting Date is required.'
            );
        }

        if (movementDate > accountingDate) {
            throw new FixedAssetMovementException(
                'Movement Date cannot be later than Accounting Date.'
            );
        }

        assertTextLength(
            movementKey,
            Asset_Movement__c.Movement_Key__c,
            'Movement Key'
        );
        assertTextLength(
            bookKey,
            Asset_Movement__c.Book_Key__c,
            'Book Key'
        );
    }

    private static void validateRequestKey(
        String requestKey
    ) {
        requireText(
            requestKey,
            'Request Key'
        );

        assertTextLength(
            requestKey,
            Accounting_Event__c.Created_Request_Key__c,
            'Request Key'
        );
    }

    private static void assertPermission() {
        SABPermissionService.assertPermission(
            PERMISSION,
            'You do not have permission to manage Fixed Asset movements.'
        );
    }

    private static String buildPostingKey(
        Id movementId
    ) {
        return 'FAMOVE|'
            + String.valueOf(movementId)
            + '|V1';
    }

    private static String buildEventKey(
        String movementType,
        Id movementId
    ) {
        return 'FIXED_ASSET_'
            + movementType.toUpperCase()
            + '|'
            + String.valueOf(movementId)
            + '|V1';
    }

    private static String normalizeOptionalText(
        String value
    ) {
        return String.isBlank(value)
            ? null
            : value.trim();
    }

    private static void requireText(
        String value,
        String label
    ) {
        if (String.isBlank(value)) {
            throw new FixedAssetMovementException(
                label + ' is required.'
            );
        }
    }

    private static void assertTextLength(
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
            throw new FixedAssetMovementException(
                label
                + ' cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static String truncateText(
        String value,
        Integer maxLength
    ) {
        if (
            String.isBlank(value)
            || maxLength == null
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
