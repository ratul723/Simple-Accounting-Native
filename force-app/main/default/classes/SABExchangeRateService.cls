/**
 * Simple Accounting Books - Exchange Rate Service
 *
 * Step 4B: approved/effective FX-rate selection using the EXISTING
 * Exchange_Rate__c object.
 *
 * Verified existing fields:
 * - From_Currency__c       Text(3), Required
 * - To_Currency__c         Text(3), Required
 * - Rate_Type__c           Picklist, Required
 *                          Spot / Closing / Average / Custom
 * - Effective_Date_Time__c DateTime, Required
 * - Rate__c                Number(18,10), Required
 * - Source__c              Text(80), Required
 * - Approved__c            Checkbox
 * - Approved_By__c         Lookup(User)
 * - Rate_Key__c            Text(180), Unique
 *
 * Design decisions:
 * - Only Approved__c = true records can be selected for accounting use.
 * - Selection uses the most recent effective rate at or before the requested
 *   accounting timestamp.
 * - Future rates are never selected.
 * - Unapproved rates are never selected.
 * - Inverse rates are NOT calculated automatically. If USD->BDT is required,
 *   a BDT->USD record is not silently inverted.
 * - Same-currency conversion returns a synthetic rate of exactly 1 and does
 *   not require an Exchange_Rate__c record.
 * - The selected record's ID, effective timestamp, source and approver are
 *   returned so callers can persist a posting snapshot.
 *
 * Exchange_Rate__c currently has Private OWD and no Company__c field. This
 * class is an internal accounting configuration service and performs read-only
 * system-mode selection. User-facing entry points must still perform their
 * normal permission/company checks before calling accounting services.
 */
public without sharing class SABExchangeRateService {

    public class ExchangeRateException extends Exception {}

    public class RateRequest {
        public String fromCurrency { get; set; }
        public String toCurrency { get; set; }
        public String rateType { get; set; }
        public Datetime effectiveAt { get; set; }
    }

    public class RateSnapshot {
        public Id exchangeRateId { get; private set; }
        public String fromCurrency { get; private set; }
        public String toCurrency { get; private set; }
        public String rateType { get; private set; }
        public Datetime effectiveDateTime { get; private set; }
        public Decimal rate { get; private set; }
        public String source { get; private set; }
        public Id approvedById { get; private set; }
        public Boolean synthetic { get; private set; }

        private RateSnapshot() {}
    }

    public class ConversionSnapshot {
        public RateSnapshot rateSnapshot { get; private set; }
        public SABMoneyService.ConversionResult money {
            get;
            private set;
        }

        private ConversionSnapshot(
            RateSnapshot selectedRate,
            SABMoneyService.ConversionResult conversion
        ) {
            rateSnapshot = selectedRate;
            money = conversion;
        }
    }

    /**
     * Selects the latest approved rate effective at or before the requested
     * timestamp.
     */
    public static RateSnapshot selectApprovedRate(
        RateRequest request
    ) {
        NormalizedRequest normalized =
            normalizeAndValidateRequest(request);

        if (
            normalized.fromCurrency
            == normalized.toCurrency
        ) {
            return buildSameCurrencySnapshot(
                normalized
            );
        }

        List<Exchange_Rate__c> candidates = [
            SELECT Id,
                   From_Currency__c,
                   To_Currency__c,
                   Rate_Type__c,
                   Effective_Date_Time__c,
                   Rate__c,
                   Source__c,
                   Approved__c,
                   Approved_By__c,
                   Rate_Key__c
            FROM Exchange_Rate__c
            WHERE From_Currency__c =
                    :normalized.fromCurrency
              AND To_Currency__c =
                    :normalized.toCurrency
              AND Rate_Type__c =
                    :normalized.rateType
              AND Approved__c = true
              AND Effective_Date_Time__c
                    <= :normalized.effectiveAt
            ORDER BY Effective_Date_Time__c DESC,
                     CreatedDate DESC,
                     Id DESC
            LIMIT 1
        ];

        if (candidates.isEmpty()) {
            throw new ExchangeRateException(
                'No approved '
                + normalized.rateType
                + ' exchange rate exists for '
                + normalized.fromCurrency
                + ' to '
                + normalized.toCurrency
                + ' at or before '
                + String.valueOf(
                    normalized.effectiveAt
                )
                + '.'
            );
        }

        return snapshotFromRecord(
            candidates[0],
            normalized
        );
    }

    /**
     * Validates a specifically selected Exchange_Rate__c record against the
     * requested currency pair, rate type and accounting timestamp.
     *
     * This is useful for documents such as Invoice__c / Supplier_Bill__c that
     * retain the chosen Exchange_Rate__c lookup.
     */
    public static RateSnapshot validateApprovedRate(
        Id exchangeRateId,
        RateRequest request
    ) {
        if (exchangeRateId == null) {
            throw new ExchangeRateException(
                'Exchange Rate Id is required.'
            );
        }

        NormalizedRequest normalized =
            normalizeAndValidateRequest(request);

        if (
            normalized.fromCurrency
            == normalized.toCurrency
        ) {
            throw new ExchangeRateException(
                'Same-currency conversion does not require an Exchange Rate record.'
            );
        }

        Exchange_Rate__c rateRecord = [
            SELECT Id,
                   From_Currency__c,
                   To_Currency__c,
                   Rate_Type__c,
                   Effective_Date_Time__c,
                   Rate__c,
                   Source__c,
                   Approved__c,
                   Approved_By__c,
                   Rate_Key__c
            FROM Exchange_Rate__c
            WHERE Id = :exchangeRateId
            LIMIT 1
        ];

        if (rateRecord.Approved__c != true) {
            throw new ExchangeRateException(
                'The selected Exchange Rate is not approved.'
            );
        }

        if (
            SABMoneyService.normalizeCurrencyCode(
                rateRecord.From_Currency__c
            ) != normalized.fromCurrency
            || SABMoneyService.normalizeCurrencyCode(
                rateRecord.To_Currency__c
            ) != normalized.toCurrency
            || rateRecord.Rate_Type__c
                != normalized.rateType
        ) {
            throw new ExchangeRateException(
                'The selected Exchange Rate does not match the requested currency pair and rate type.'
            );
        }

        if (
            rateRecord.Effective_Date_Time__c
            > normalized.effectiveAt
        ) {
            throw new ExchangeRateException(
                'The selected Exchange Rate is not yet effective for the requested accounting timestamp.'
            );
        }

        return snapshotFromRecord(
            rateRecord,
            normalized
        );
    }

    /**
     * Convenience method that selects the approved rate and converts the
     * transaction amount through SABMoneyService.
     */
    public static ConversionSnapshot convertUsingApprovedRate(
        Decimal transactionAmount,
        RateRequest request,
        RoundingMode roundingMode
    ) {
        RateSnapshot rateSnapshot =
            selectApprovedRate(request);

        SABMoneyService.ConversionResult money =
            SABMoneyService.convertToFunctional(
                transactionAmount,
                rateSnapshot.fromCurrency,
                rateSnapshot.toCurrency,
                rateSnapshot.rate,
                roundingMode
            );

        return new ConversionSnapshot(
            rateSnapshot,
            money
        );
    }

    private class NormalizedRequest {
        public String fromCurrency;
        public String toCurrency;
        public String rateType;
        public Datetime effectiveAt;
    }

    private static NormalizedRequest
        normalizeAndValidateRequest(
            RateRequest request
        ) {
        if (request == null) {
            throw new ExchangeRateException(
                'Exchange rate request is required.'
            );
        }

        NormalizedRequest normalized =
            new NormalizedRequest();

        normalized.fromCurrency =
            SABMoneyService.normalizeCurrencyCode(
                request.fromCurrency
            );

        normalized.toCurrency =
            SABMoneyService.normalizeCurrencyCode(
                request.toCurrency
            );

        normalized.rateType =
            normalizeRateType(
                request.rateType
            );

        if (request.effectiveAt == null) {
            throw new ExchangeRateException(
                'Effective accounting timestamp is required.'
            );
        }

        normalized.effectiveAt =
            request.effectiveAt;

        return normalized;
    }

    private static String normalizeRateType(
        String rateType
    ) {
        if (String.isBlank(rateType)) {
            throw new ExchangeRateException(
                'Rate Type is required.'
            );
        }

        String requested =
            rateType.trim();

        for (
            Schema.PicklistEntry value :
            Exchange_Rate__c.Rate_Type__c
                .getDescribe()
                .getPicklistValues()
        ) {
            if (
                value.isActive()
                && value.getValue().toLowerCase()
                    == requested.toLowerCase()
            ) {
                return value.getValue();
            }
        }

        throw new ExchangeRateException(
            'Rate Type is not an active Exchange Rate type.'
        );
    }

    private static RateSnapshot buildSameCurrencySnapshot(
        NormalizedRequest normalized
    ) {
        RateSnapshot snapshot =
            new RateSnapshot();

        snapshot.exchangeRateId = null;
        snapshot.fromCurrency =
            normalized.fromCurrency;
        snapshot.toCurrency =
            normalized.toCurrency;
        snapshot.rateType =
            normalized.rateType;
        snapshot.effectiveDateTime =
            normalized.effectiveAt;
        snapshot.rate =
            Decimal.valueOf('1')
                .setScale(
                    SABMoneyService.exchangeRateScale(),
                    RoundingMode.HALF_UP
                );
        snapshot.source =
            'Same Currency';
        snapshot.approvedById =
            null;
        snapshot.synthetic =
            true;

        return snapshot;
    }

    private static RateSnapshot snapshotFromRecord(
        Exchange_Rate__c rateRecord,
        NormalizedRequest normalized
    ) {
        if (rateRecord == null) {
            throw new ExchangeRateException(
                'Exchange Rate record is required.'
            );
        }

        if (rateRecord.Approved__c != true) {
            throw new ExchangeRateException(
                'Exchange Rate must be approved.'
            );
        }

        if (
            rateRecord.Rate__c == null
            || rateRecord.Rate__c <= 0
        ) {
            throw new ExchangeRateException(
                'Exchange Rate must be greater than zero.'
            );
        }

        if (
            rateRecord.Effective_Date_Time__c
            > normalized.effectiveAt
        ) {
            throw new ExchangeRateException(
                'Exchange Rate is not effective for the requested accounting timestamp.'
            );
        }

        RateSnapshot snapshot =
            new RateSnapshot();

        snapshot.exchangeRateId =
            rateRecord.Id;
        snapshot.fromCurrency =
            normalized.fromCurrency;
        snapshot.toCurrency =
            normalized.toCurrency;
        snapshot.rateType =
            normalized.rateType;
        snapshot.effectiveDateTime =
            rateRecord.Effective_Date_Time__c;
        snapshot.rate =
            rateRecord.Rate__c;
        snapshot.source =
            rateRecord.Source__c;
        snapshot.approvedById =
            rateRecord.Approved_By__c;
        snapshot.synthetic =
            false;

        return snapshot;
    }
}
