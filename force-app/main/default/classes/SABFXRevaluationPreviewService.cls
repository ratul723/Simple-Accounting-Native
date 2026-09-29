/**
 * G7A - FX Revaluation Preview Foundation.
 *
 * Supported first-slice sources:
 * - Posted foreign-currency customer Invoices (AR)
 * - Posted foreign-currency Supplier Bills (AP)
 * - effective Payment_Allocation__c rows through period end
 * - posted customer Credit Notes linked to original Invoices
 *
 * Signed Adjustment_Amount__c:
 * positive = debit source AR/AP control account
 * negative = credit source AR/AP control account
 */
public without sharing class SABFXRevaluationPreviewService {

    public class FXRevaluationException extends Exception {}

    private static final Decimal ZERO = Decimal.valueOf('0');
    private static final String RATE_TYPE = 'Closing';
    private static final String STATUS_PREVIEW = 'Preview';
    private static final String PERMISSION = 'SAB_Run_FX_Revaluation';
    private static final Integer MAX_SOURCE_ROWS = 4000;

    public class PreviewRequest {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public Id accountingPeriodId { get; set; }
        @AuraEnabled public String runKey { get; set; }
        @AuraEnabled public String reversalPolicy { get; set; }
    }

    public class PreviewResult {
        @AuraEnabled public Id runId { get; private set; }
        @AuraEnabled public String runKey { get; private set; }
        @AuraEnabled public String status { get; private set; }
        @AuraEnabled public Id companyId { get; private set; }
        @AuraEnabled public Id accountingPeriodId { get; private set; }
        @AuraEnabled public Date asOfDate { get; private set; }
        @AuraEnabled public String functionalCurrency { get; private set; }
        @AuraEnabled public String rateSetKey { get; private set; }
        @AuraEnabled public Integer arLineCount { get; private set; }
        @AuraEnabled public Integer apLineCount { get; private set; }
        @AuraEnabled public Decimal arAdjustmentTotal { get; private set; }
        @AuraEnabled public Decimal apAdjustmentTotal { get; private set; }
        @AuraEnabled public Decimal signedAdjustmentTotal { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private PreviewResult() {
            arLineCount = 0;
            apLineCount = 0;
            arAdjustmentTotal = ZERO;
            apAdjustmentTotal = ZERO;
            signedAdjustmentTotal = ZERO;
            replay = false;
        }
    }

    private class Exposure {
        String sourceType;
        Id sourceRecordId;
        Id sourceGLAccountId;
        String transactionCurrency;
        Decimal outstandingDocumentAmount;
        Decimal carryingFunctionalAmount;
        Decimal revaluedFunctionalAmount;
        Decimal signedAdjustmentAmount;
        Decimal appliedRate;
        Id exchangeRateId;
        String rateIdentity;
    }

    private class AllocationBucket {
        Decimal documentAmount = ZERO;
        Decimal baseAmount = ZERO;
    }

    @AuraEnabled
    public static PreviewResult preview(
        PreviewRequest request
    ) {
        validateRequest(request);

        SABPermissionService.assertPermission(
            PERMISSION,
            'You do not have permission to run FX Revaluation.'
        );

        SABCompanyAccessService.assertCompanyAccess(request.companyId);

        Accounting_Company__c company = [
            SELECT Id, Functional_Currency__c
            FROM Accounting_Company__c
            WHERE Id = :request.companyId
            LIMIT 1
        ];

        Accounting_Period__c period = [
            SELECT Id, Company__c, Start_Date__c, End_Date__c, Status__c
            FROM Accounting_Period__c
            WHERE Id = :request.accountingPeriodId
            LIMIT 1
        ];

        if (period.Company__c != company.Id) {
            throw new FXRevaluationException(
                'Accounting Period must belong to the selected Accounting Company.'
            );
        }

        if (period.End_Date__c == null) {
            throw new FXRevaluationException(
                'Accounting Period End Date is required for FX revaluation.'
            );
        }

        List<FX_Revaluation_Run__c> existingRuns = [
            SELECT Id, Company__c, Accounting_Period__c, Rate_Set_Key__c,
                   Reversal_Policy__c, Run_Key__c, Status__c
            FROM FX_Revaluation_Run__c
            WHERE Run_Key__c = :request.runKey.trim()
            LIMIT 1
        ];

        if (!existingRuns.isEmpty()) {
            FX_Revaluation_Run__c existing = existingRuns[0];

            if (
                existing.Company__c != request.companyId
                || existing.Accounting_Period__c != request.accountingPeriodId
            ) {
                throw new FXRevaluationException(
                    'Run Key is already used by a different FX Revaluation scope.'
                );
            }

            if (existing.Status__c != STATUS_PREVIEW) {
                throw new FXRevaluationException(
                    'Run Key already belongs to a non-Preview FX Revaluation Run.'
                );
            }

            return buildReplayResult(
                existing,
                company.Functional_Currency__c,
                period.End_Date__c
            );
        }

        String functionalCurrency =
            SABMoneyService.normalizeCurrencyCode(
                company.Functional_Currency__c
            );

        List<Exposure> exposures = new List<Exposure>();

        exposures.addAll(
            loadARExposures(
                company.Id,
                period.End_Date__c,
                functionalCurrency
            )
        );

        exposures.addAll(
            loadAPExposures(
                company.Id,
                period.End_Date__c,
                functionalCurrency
            )
        );

        String rateSetKey =
            buildRateSetKey(
                company.Id,
                period.Id,
                period.End_Date__c,
                exposures
            );

        FX_Revaluation_Run__c run =
            new FX_Revaluation_Run__c(
                Company__c = company.Id,
                Accounting_Period__c = period.Id,
                Run_Key__c = request.runKey.trim(),
                Rate_Set_Key__c = rateSetKey,
                Reversal_Policy__c =
                    normalizeReversalPolicy(
                        request.reversalPolicy
                    ),
                Status__c = STATUS_PREVIEW
            );

        insert run;

        List<FX_Revaluation_Line__c> lines =
            new List<FX_Revaluation_Line__c>();

        PreviewResult result = new PreviewResult();

        result.runId = run.Id;
        result.runKey = run.Run_Key__c;
        result.status = run.Status__c;
        result.companyId = company.Id;
        result.accountingPeriodId = period.Id;
        result.asOfDate = period.End_Date__c;
        result.functionalCurrency = functionalCurrency;
        result.rateSetKey = rateSetKey;

        for (Exposure exposure : exposures) {
            if (
                exposure.outstandingDocumentAmount == ZERO
                || exposure.signedAdjustmentAmount == ZERO
            ) {
                continue;
            }

            lines.add(
                new FX_Revaluation_Line__c(
                    FX_Revaluation_Run__c = run.Id,
                    Source_Type__c = exposure.sourceType,
                    Source_Record_Id__c =
                        String.valueOf(exposure.sourceRecordId),
                    Source_GL_Account__c =
                        exposure.sourceGLAccountId,
                    Transaction_Currency__c =
                        exposure.transactionCurrency,
                    Outstanding_Amount__c =
                        exposure.outstandingDocumentAmount,
                    Carrying_Amount__c =
                        exposure.carryingFunctionalAmount,
                    Revalued_Amount__c =
                        exposure.revaluedFunctionalAmount,
                    Adjustment_Amount__c =
                        exposure.signedAdjustmentAmount,
                    Applied_Rate__c =
                        exposure.appliedRate,
                    Exchange_Rate__c =
                        exposure.exchangeRateId
                )
            );

            if (exposure.sourceType == 'Invoice__c') {
                result.arLineCount++;
                result.arAdjustmentTotal +=
                    exposure.signedAdjustmentAmount;
            } else if (
                exposure.sourceType == 'Supplier_Bill__c'
            ) {
                result.apLineCount++;
                result.apAdjustmentTotal +=
                    exposure.signedAdjustmentAmount;
            }

            result.signedAdjustmentTotal +=
                exposure.signedAdjustmentAmount;
        }

        if (!lines.isEmpty()) {
            insert lines;
        }

        normalizeResult(result);
        return result;
    }

    private static List<Exposure> loadARExposures(
        Id companyId,
        Date asOfDate,
        String functionalCurrency
    ) {
        List<Invoice__c> invoices = [
            SELECT Id, Company__c, Party_Profile__c,
                   Party_Profile__r.AR_Control_Account__c,
                   Party_Profile__r.AR_Control_Account__r.Company__c,
                   Party_Profile__r.AR_Control_Account__r.Is_Active__c,
                   Party_Profile__r.AR_Control_Account__r.Is_Control_Account__c,
                   Party_Profile__r.AR_Control_Account__r.Control_Type__c,
                   Document_Type__c, Status__c, Accounting_Date__c,
                   Total__c, Transaction_Currency__c,
                   Functional_Currency__c, Exchange_Rate__c
            FROM Invoice__c
            WHERE Company__c = :companyId
              AND Document_Type__c = 'Invoice'
              AND Status__c = 'Posted'
              AND Accounting_Date__c <= :asOfDate
            LIMIT :MAX_SOURCE_ROWS
        ];

        Set<Id> invoiceIds = new Set<Id>();
        for (Invoice__c row : invoices) {
            invoiceIds.add(row.Id);
        }

        Map<Id, AllocationBucket> allocations =
            loadAllocationBuckets(
                invoiceIds,
                new Set<Id>(),
                asOfDate
            );

        Map<Id, AllocationBucket> credits =
            loadCustomerCreditBuckets(
                invoiceIds,
                asOfDate
            );

        List<Exposure> result = new List<Exposure>();

        Map<String, SABExchangeRateService.RateSnapshot>
            closingRates =
                new Map<String, SABExchangeRateService.RateSnapshot>();

        for (Invoice__c invoice : invoices) {
            String transactionCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    invoice.Transaction_Currency__c
                );

            String documentFunctionalCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    invoice.Functional_Currency__c
                );

            if (documentFunctionalCurrency != functionalCurrency) {
                throw new FXRevaluationException(
                    'Posted Invoice Functional Currency does not match the Accounting Company Functional Currency.'
                );
            }

            if (transactionCurrency == functionalCurrency) {
                continue;
            }

            validateControlAccount(
                invoice.Party_Profile__r == null
                    ? null
                    : invoice.Party_Profile__r.AR_Control_Account__c,
                invoice.Party_Profile__r == null
                    ? null
                    : invoice.Party_Profile__r.AR_Control_Account__r,
                companyId,
                'AR'
            );

            SABMoneyService.ConversionResult original =
                SABMoneyService.convertToFunctional(
                    invoice.Total__c,
                    transactionCurrency,
                    functionalCurrency,
                    invoice.Exchange_Rate__c,
                    RoundingMode.HALF_UP
                );

            AllocationBucket allocation =
                allocations.containsKey(invoice.Id)
                    ? allocations.get(invoice.Id)
                    : new AllocationBucket();

            AllocationBucket credit =
                credits.containsKey(invoice.Id)
                    ? credits.get(invoice.Id)
                    : new AllocationBucket();

            Decimal outstandingDocument =
                normalizeTransaction(
                    original.transactionAmount
                    - allocation.documentAmount
                    - credit.documentAmount
                );

            Decimal carryingFunctional =
                normalizeLedger(
                    original.functionalAmount
                    - allocation.baseAmount
                    - credit.baseAmount
                );

            if (
                outstandingDocument <= ZERO
                || carryingFunctional <= ZERO
            ) {
                continue;
            }

            SABExchangeRateService.RateSnapshot closingRate =
                getClosingRate(
                    transactionCurrency,
                    functionalCurrency,
                    asOfDate,
                    closingRates
                );

            Decimal revalued =
                SABMoneyService.convertToFunctional(
                    outstandingDocument,
                    transactionCurrency,
                    functionalCurrency,
                    closingRate.rate,
                    RoundingMode.HALF_UP
                ).functionalAmount;

            Exposure exposure = new Exposure();

            exposure.sourceType = 'Invoice__c';
            exposure.sourceRecordId = invoice.Id;
            exposure.sourceGLAccountId =
                invoice.Party_Profile__r.AR_Control_Account__c;
            exposure.transactionCurrency = transactionCurrency;
            exposure.outstandingDocumentAmount =
                outstandingDocument;
            exposure.carryingFunctionalAmount =
                carryingFunctional;
            exposure.revaluedFunctionalAmount = revalued;
            exposure.signedAdjustmentAmount =
                normalizeLedger(
                    revalued - carryingFunctional
                );
            exposure.appliedRate = closingRate.rate;
            exposure.exchangeRateId =
                closingRate.exchangeRateId;
            exposure.rateIdentity =
                buildRateIdentity(closingRate);

            result.add(exposure);
        }

        return result;
    }

    private static List<Exposure> loadAPExposures(
        Id companyId,
        Date asOfDate,
        String functionalCurrency
    ) {
        List<Supplier_Bill__c> bills = [
            SELECT Id, Company__c, Supplier_Profile__c,
                   Supplier_Profile__r.AP_Control_Account__c,
                   Supplier_Profile__r.AP_Control_Account__r.Company__c,
                   Supplier_Profile__r.AP_Control_Account__r.Is_Active__c,
                   Supplier_Profile__r.AP_Control_Account__r.Is_Control_Account__c,
                   Supplier_Profile__r.AP_Control_Account__r.Control_Type__c,
                   Document_Type__c, Status__c, Accounting_Date__c,
                   Total__c, Transaction_Currency__c,
                   Functional_Currency__c, Exchange_Rate__c
            FROM Supplier_Bill__c
            WHERE Company__c = :companyId
              AND Document_Type__c = 'Bill'
              AND Status__c = 'Posted'
              AND Accounting_Date__c <= :asOfDate
            LIMIT :MAX_SOURCE_ROWS
        ];

        Set<Id> billIds = new Set<Id>();
        for (Supplier_Bill__c row : bills) {
            billIds.add(row.Id);
        }

        Map<Id, AllocationBucket> allocations =
            loadAllocationBuckets(
                new Set<Id>(),
                billIds,
                asOfDate
            );

        List<Exposure> result = new List<Exposure>();

        Map<String, SABExchangeRateService.RateSnapshot>
            closingRates =
                new Map<String, SABExchangeRateService.RateSnapshot>();

        for (Supplier_Bill__c bill : bills) {
            String transactionCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    bill.Transaction_Currency__c
                );

            String documentFunctionalCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    bill.Functional_Currency__c
                );

            if (documentFunctionalCurrency != functionalCurrency) {
                throw new FXRevaluationException(
                    'Posted Supplier Bill Functional Currency does not match the Accounting Company Functional Currency.'
                );
            }

            if (transactionCurrency == functionalCurrency) {
                continue;
            }

            validateControlAccount(
                bill.Supplier_Profile__r == null
                    ? null
                    : bill.Supplier_Profile__r.AP_Control_Account__c,
                bill.Supplier_Profile__r == null
                    ? null
                    : bill.Supplier_Profile__r.AP_Control_Account__r,
                companyId,
                'AP'
            );

            SABMoneyService.ConversionResult original =
                SABMoneyService.convertToFunctional(
                    bill.Total__c,
                    transactionCurrency,
                    functionalCurrency,
                    bill.Exchange_Rate__c,
                    RoundingMode.HALF_UP
                );

            AllocationBucket allocation =
                allocations.containsKey(bill.Id)
                    ? allocations.get(bill.Id)
                    : new AllocationBucket();

            Decimal outstandingDocument =
                normalizeTransaction(
                    original.transactionAmount
                    - allocation.documentAmount
                );

            Decimal carryingFunctional =
                normalizeLedger(
                    original.functionalAmount
                    - allocation.baseAmount
                );

            if (
                outstandingDocument <= ZERO
                || carryingFunctional <= ZERO
            ) {
                continue;
            }

            SABExchangeRateService.RateSnapshot closingRate =
                getClosingRate(
                    transactionCurrency,
                    functionalCurrency,
                    asOfDate,
                    closingRates
                );

            Decimal revalued =
                SABMoneyService.convertToFunctional(
                    outstandingDocument,
                    transactionCurrency,
                    functionalCurrency,
                    closingRate.rate,
                    RoundingMode.HALF_UP
                ).functionalAmount;

            Exposure exposure = new Exposure();

            exposure.sourceType = 'Supplier_Bill__c';
            exposure.sourceRecordId = bill.Id;
            exposure.sourceGLAccountId =
                bill.Supplier_Profile__r.AP_Control_Account__c;
            exposure.transactionCurrency = transactionCurrency;
            exposure.outstandingDocumentAmount =
                outstandingDocument;
            exposure.carryingFunctionalAmount =
                carryingFunctional;
            exposure.revaluedFunctionalAmount = revalued;

            // Liability convention:
            // positive = debit AP, negative = credit AP.
            exposure.signedAdjustmentAmount =
                normalizeLedger(
                    carryingFunctional - revalued
                );

            exposure.appliedRate = closingRate.rate;
            exposure.exchangeRateId =
                closingRate.exchangeRateId;
            exposure.rateIdentity =
                buildRateIdentity(closingRate);

            result.add(exposure);
        }

        return result;
    }

    private static Map<Id, AllocationBucket>
        loadAllocationBuckets(
            Set<Id> invoiceIds,
            Set<Id> billIds,
            Date asOfDate
        )
    {
        Map<Id, AllocationBucket> result =
            new Map<Id, AllocationBucket>();

        Boolean hasInvoices =
            invoiceIds != null
            && !invoiceIds.isEmpty();

        Boolean hasBills =
            billIds != null
            && !billIds.isEmpty();

        if (!hasInvoices && !hasBills) {
            return result;
        }

        List<Payment_Allocation__c> rows;

        if (hasInvoices) {
            rows = [
                SELECT Invoice__c, Supplier_Bill__c,
                       Document_Amount__c, Base_Amount__c,
                       Effective_Date__c, Allocation_Date__c,
                       Status__c
                FROM Payment_Allocation__c
                WHERE Invoice__c IN :invoiceIds
                  AND Status__c IN ('Allocated','Reversed')
                  AND (
                        Effective_Date__c <= :asOfDate
                        OR (
                            Effective_Date__c = NULL
                            AND Allocation_Date__c <= :asOfDate
                        )
                      )
            ];
        } else {
            rows = [
                SELECT Invoice__c, Supplier_Bill__c,
                       Document_Amount__c, Base_Amount__c,
                       Effective_Date__c, Allocation_Date__c,
                       Status__c
                FROM Payment_Allocation__c
                WHERE Supplier_Bill__c IN :billIds
                  AND Status__c IN ('Allocated','Reversed')
                  AND (
                        Effective_Date__c <= :asOfDate
                        OR (
                            Effective_Date__c = NULL
                            AND Allocation_Date__c <= :asOfDate
                        )
                      )
            ];
        }

        for (Payment_Allocation__c row : rows) {
            Id sourceId =
                row.Invoice__c != null
                    ? row.Invoice__c
                    : row.Supplier_Bill__c;

            if (sourceId == null) {
                continue;
            }

            AllocationBucket bucket =
                result.containsKey(sourceId)
                    ? result.get(sourceId)
                    : new AllocationBucket();

            bucket.documentAmount +=
                row.Document_Amount__c == null
                    ? ZERO
                    : row.Document_Amount__c;

            bucket.baseAmount +=
                row.Base_Amount__c == null
                    ? ZERO
                    : row.Base_Amount__c;

            result.put(sourceId, bucket);
        }

        return result;
    }

    private static Map<Id, AllocationBucket>
        loadCustomerCreditBuckets(
            Set<Id> invoiceIds,
            Date asOfDate
        )
    {
        Map<Id, AllocationBucket> result =
            new Map<Id, AllocationBucket>();

        if (
            invoiceIds == null
            || invoiceIds.isEmpty()
        ) {
            return result;
        }

        for (Invoice__c credit : [
            SELECT Original_Invoice__c, Total__c,
                   Transaction_Currency__c,
                   Functional_Currency__c,
                   Exchange_Rate__c
            FROM Invoice__c
            WHERE Original_Invoice__c IN :invoiceIds
              AND Document_Type__c = 'Credit Note'
              AND Status__c = 'Posted'
              AND Accounting_Date__c <= :asOfDate
        ]) {
            if (credit.Total__c == null) {
                continue;
            }

            SABMoneyService.ConversionResult converted =
                SABMoneyService.convertToFunctional(
                    credit.Total__c,
                    credit.Transaction_Currency__c,
                    credit.Functional_Currency__c,
                    credit.Exchange_Rate__c,
                    RoundingMode.HALF_UP
                );

            AllocationBucket bucket =
                result.containsKey(
                    credit.Original_Invoice__c
                )
                    ? result.get(
                        credit.Original_Invoice__c
                    )
                    : new AllocationBucket();

            bucket.documentAmount +=
                converted.transactionAmount;
            bucket.baseAmount +=
                converted.functionalAmount;

            result.put(
                credit.Original_Invoice__c,
                bucket
            );
        }

        return result;
    }

    private static SABExchangeRateService.RateSnapshot
        getClosingRate(
            String fromCurrency,
            String toCurrency,
            Date asOfDate,
            Map<String, SABExchangeRateService.RateSnapshot> cache
        )
    {
        String cacheKey =
            fromCurrency + '>' + toCurrency;

        if (cache.containsKey(cacheKey)) {
            return cache.get(cacheKey);
        }

        SABExchangeRateService.RateRequest request =
            new SABExchangeRateService.RateRequest();

        request.fromCurrency = fromCurrency;
        request.toCurrency = toCurrency;
        request.rateType = RATE_TYPE;
        request.effectiveAt =
            Datetime.newInstance(
                asOfDate,
                Time.newInstance(23, 59, 59, 999)
            );

        SABExchangeRateService.RateSnapshot snapshot =
            SABExchangeRateService.selectApprovedRate(
                request
            );

        cache.put(cacheKey, snapshot);
        return snapshot;
    }

    private static void validateControlAccount(
        Id accountId,
        GL_Account__c account,
        Id companyId,
        String expectedControlType
    ) {
        if (
            accountId == null
            || account == null
        ) {
            throw new FXRevaluationException(
                expectedControlType
                + ' Control Account is required for FX revaluation.'
            );
        }

        if (
            account.Company__c != companyId
            || account.Is_Active__c != true
            || account.Is_Control_Account__c != true
            || account.Control_Type__c != expectedControlType
        ) {
            throw new FXRevaluationException(
                expectedControlType
                + ' Control Account is invalid for FX revaluation.'
            );
        }
    }

    private static String buildRateSetKey(
        Id companyId,
        Id periodId,
        Date asOfDate,
        List<Exposure> exposures
    ) {
        Set<String> identities = new Set<String>();

        for (Exposure exposure : exposures) {
            if (!String.isBlank(exposure.rateIdentity)) {
                identities.add(exposure.rateIdentity);
            }
        }

        List<String> ordered =
            new List<String>(identities);
        ordered.sort();

        String payload =
            String.valueOf(companyId)
            + '|'
            + String.valueOf(periodId)
            + '|'
            + String.valueOf(asOfDate)
            + '|'
            + String.join(ordered, '|');

        return EncodingUtil.convertToHex(
            Crypto.generateDigest(
                'SHA-256',
                Blob.valueOf(payload)
            )
        );
    }

    private static String buildRateIdentity(
        SABExchangeRateService.RateSnapshot snapshot
    ) {
        return snapshot.fromCurrency
            + '>'
            + snapshot.toCurrency
            + '|'
            + snapshot.rateType
            + '|'
            + String.valueOf(snapshot.exchangeRateId)
            + '|'
            + String.valueOf(snapshot.rate)
            + '|'
            + String.valueOf(snapshot.effectiveDateTime);
    }

    private static String normalizeReversalPolicy(
        String value
    ) {
        if (String.isBlank(value)) {
            return 'No Automatic Reversal';
        }

        String requested = value.trim();

        for (
            Schema.PicklistEntry entry :
            FX_Revaluation_Run__c.Reversal_Policy__c
                .getDescribe()
                .getPicklistValues()
        ) {
            if (
                entry.isActive()
                && entry.getValue().toLowerCase()
                    == requested.toLowerCase()
            ) {
                return entry.getValue();
            }
        }

        throw new FXRevaluationException(
            'Reversal Policy is not an active FX Revaluation option.'
        );
    }

    private static PreviewResult buildReplayResult(
        FX_Revaluation_Run__c run,
        String functionalCurrency,
        Date asOfDate
    ) {
        List<FX_Revaluation_Line__c> lines = [
            SELECT Source_Type__c, Adjustment_Amount__c
            FROM FX_Revaluation_Line__c
            WHERE FX_Revaluation_Run__c = :run.Id
        ];

        PreviewResult result = new PreviewResult();

        result.runId = run.Id;
        result.runKey = run.Run_Key__c;
        result.status = run.Status__c;
        result.companyId = run.Company__c;
        result.accountingPeriodId =
            run.Accounting_Period__c;
        result.asOfDate = asOfDate;
        result.functionalCurrency =
            SABMoneyService.normalizeCurrencyCode(
                functionalCurrency
            );
        result.rateSetKey = run.Rate_Set_Key__c;
        result.replay = true;

        for (FX_Revaluation_Line__c line : lines) {
            Decimal adjustment =
                normalizeLedger(
                    line.Adjustment_Amount__c
                );

            if (line.Source_Type__c == 'Invoice__c') {
                result.arLineCount++;
                result.arAdjustmentTotal += adjustment;
            } else if (
                line.Source_Type__c == 'Supplier_Bill__c'
            ) {
                result.apLineCount++;
                result.apAdjustmentTotal += adjustment;
            }

            result.signedAdjustmentTotal += adjustment;
        }

        normalizeResult(result);
        return result;
    }

    private static void normalizeResult(
        PreviewResult result
    ) {
        result.arAdjustmentTotal =
            normalizeLedger(
                result.arAdjustmentTotal
            );

        result.apAdjustmentTotal =
            normalizeLedger(
                result.apAdjustmentTotal
            );

        result.signedAdjustmentTotal =
            normalizeLedger(
                result.signedAdjustmentTotal
            );
    }

    private static Decimal normalizeTransaction(
        Decimal amount
    ) {
        return SABMoneyService.normalizeTransactionAmount(
            amount == null ? ZERO : amount,
            RoundingMode.HALF_UP
        );
    }

    private static Decimal normalizeLedger(
        Decimal amount
    ) {
        return SABMoneyService.normalizeLedgerAmount(
            amount == null ? ZERO : amount,
            RoundingMode.HALF_UP
        );
    }

    private static void validateRequest(
        PreviewRequest request
    ) {
        if (request == null) {
            throw new FXRevaluationException(
                'FX Revaluation Preview request is required.'
            );
        }

        if (request.companyId == null) {
            throw new FXRevaluationException(
                'Accounting Company is required.'
            );
        }

        if (request.accountingPeriodId == null) {
            throw new FXRevaluationException(
                'Accounting Period is required.'
            );
        }

        if (String.isBlank(request.runKey)) {
            throw new FXRevaluationException(
                'Run Key is required.'
            );
        }

        Integer maxLength =
            FX_Revaluation_Run__c.Run_Key__c
                .getDescribe()
                .getLength();

        if (
            request.runKey.trim().length()
                > maxLength
        ) {
            throw new FXRevaluationException(
                'Run Key cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }
}
