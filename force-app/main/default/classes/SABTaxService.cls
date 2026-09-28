/**
 * G6A - Tax Engine Foundation.
 *
 * Uses the already-deployed SAB tax configuration:
 * - Tax_Code__c
 * - Tax_Rate__c
 *
 * This stage deliberately does NOT persist Document_Tax_Line__c yet.
 * G6B will materialize document tax snapshots after the tax-account mapping
 * contract is finalized.
 *
 * Supported generic treatments in G6A:
 * - Standard
 * - Zero
 * - Exempt
 *
 * Country-specific treatments such as Reverse Charge / Withholding / Other
 * require an explicit country-rule adapter and are therefore not silently
 * approximated by the generic engine.
 */
public without sharing class SABTaxService {

    public class TaxException extends Exception {}

    public static final String SIDE_SALES =
        'Sales';

    public static final String SIDE_PURCHASE =
        'Purchase';

    public class TaxRequest {
        public Id companyId { get; set; }
        public Id taxCodeId { get; set; }
        public Date taxDate { get; set; }

        /**
         * For exclusive tax codes this is the net/taxable amount.
         * For inclusive tax codes this is the tax-inclusive line amount.
         */
        public Decimal lineAmount { get; set; }

        /**
         * Supported values: Sales / Purchase.
         * Recoverability is only meaningful for Purchase.
         */
        public String documentSide { get; set; }

        public RoundingMode roundingMode { get; set; }
    }

    public class TaxSnapshot {
        public Id companyId { get; private set; }
        public Id taxCodeId { get; private set; }
        public String taxCodeKey { get; private set; }
        public String jurisdiction { get; private set; }
        public String treatment { get; private set; }
        public Boolean inclusive { get; private set; }
        public String recoverability { get; private set; }
        public String supportedRuleKey { get; private set; }

        public Id taxRateId { get; private set; }
        public String rateKey { get; private set; }
        public Decimal taxRatePercent { get; private set; }
        public Decimal recoverablePercent { get; private set; }
        public String countryPackVersion { get; private set; }
        public Date effectiveFrom { get; private set; }
        public Date effectiveTo { get; private set; }

        public Decimal inputAmount { get; private set; }
        public Decimal taxableBase { get; private set; }
        public Decimal taxAmount { get; private set; }
        public Decimal recoverableAmount { get; private set; }
        public Decimal nonrecoverableAmount { get; private set; }
        public Decimal grossAmount { get; private set; }

        public String documentSide { get; private set; }
        public Date taxDate { get; private set; }

        private TaxSnapshot() {}
    }

    public static TaxSnapshot calculate(
        TaxRequest request
    ) {
        NormalizedRequest normalized =
            normalizeAndValidateRequest(
                request
            );

        Tax_Code__c taxCode = [
            SELECT Id,
                   Name,
                   Code__c,
                   Company__c,
                   Inclusive__c,
                   Is_Active__c,
                   Jurisdiction__c,
                   Recoverability__c,
                   Supported_Rule_Key__c,
                   Treatment__c
            FROM Tax_Code__c
            WHERE Id = :normalized.taxCodeId
            LIMIT 1
        ];

        validateTaxCode(
            taxCode,
            normalized
        );

        Tax_Rate__c taxRate =
            selectEffectiveRate(
                taxCode.Id,
                normalized.taxDate
            );

        validateTaxRate(
            taxRate,
            taxCode
        );

        Decimal inputAmount =
            SABMoneyService.normalizeTransactionAmount(
                normalized.lineAmount,
                normalized.roundingMode
            );

        Decimal ratePercent =
            taxRate.Rate__c == null
                ? Decimal.valueOf('0')
                : taxRate.Rate__c;

        Decimal taxableBase;
        Decimal taxAmount;
        Decimal grossAmount;

        if (
            taxCode.Treatment__c == 'Zero'
            || taxCode.Treatment__c == 'Exempt'
        ) {
            taxableBase =
                inputAmount;
            taxAmount =
                normalizeAmount(
                    Decimal.valueOf('0'),
                    normalized.roundingMode
                );
            grossAmount =
                inputAmount;
        } else if (
            taxCode.Inclusive__c == true
        ) {
            if (ratePercent == 0) {
                taxableBase =
                    inputAmount;
                taxAmount =
                    normalizeAmount(
                        Decimal.valueOf('0'),
                        normalized.roundingMode
                    );
            } else {
                Decimal divisor =
                    Decimal.valueOf('1')
                    + (
                        ratePercent
                        / Decimal.valueOf('100')
                    );

                taxableBase =
                    normalizeAmount(
                        inputAmount / divisor,
                        normalized.roundingMode
                    );

                taxAmount =
                    normalizeAmount(
                        inputAmount - taxableBase,
                        normalized.roundingMode
                    );
            }

            grossAmount =
                inputAmount;
        } else {
            taxableBase =
                inputAmount;

            taxAmount =
                normalizeAmount(
                    taxableBase
                    * ratePercent
                    / Decimal.valueOf('100'),
                    normalized.roundingMode
                );

            grossAmount =
                normalizeAmount(
                    taxableBase
                    + taxAmount,
                    normalized.roundingMode
                );
        }

        Decimal recoverablePercent =
            resolveRecoverablePercent(
                taxCode,
                taxRate,
                normalized.documentSide
            );

        Decimal recoverableAmount =
            normalizeAmount(
                taxAmount
                * recoverablePercent
                / Decimal.valueOf('100'),
                normalized.roundingMode
            );

        Decimal nonrecoverableAmount =
            normalizeAmount(
                taxAmount
                - recoverableAmount,
                normalized.roundingMode
            );

        TaxSnapshot snapshot =
            new TaxSnapshot();

        snapshot.companyId =
            normalized.companyId;
        snapshot.taxCodeId =
            taxCode.Id;
        snapshot.taxCodeKey =
            taxCode.Code__c;
        snapshot.jurisdiction =
            taxCode.Jurisdiction__c;
        snapshot.treatment =
            taxCode.Treatment__c;
        snapshot.inclusive =
            taxCode.Inclusive__c;
        snapshot.recoverability =
            taxCode.Recoverability__c;
        snapshot.supportedRuleKey =
            taxCode.Supported_Rule_Key__c;

        snapshot.taxRateId =
            taxRate.Id;
        snapshot.rateKey =
            taxRate.Rate_Key__c;
        snapshot.taxRatePercent =
            taxRate.Rate__c;
        snapshot.recoverablePercent =
            recoverablePercent;
        snapshot.countryPackVersion =
            taxRate.Country_Pack_Version__c;
        snapshot.effectiveFrom =
            taxRate.Effective_From__c;
        snapshot.effectiveTo =
            taxRate.Effective_To__c;

        snapshot.inputAmount =
            inputAmount;
        snapshot.taxableBase =
            taxableBase;
        snapshot.taxAmount =
            taxAmount;
        snapshot.recoverableAmount =
            recoverableAmount;
        snapshot.nonrecoverableAmount =
            nonrecoverableAmount;
        snapshot.grossAmount =
            grossAmount;

        snapshot.documentSide =
            normalized.documentSide;
        snapshot.taxDate =
            normalized.taxDate;

        return snapshot;
    }

    public static Tax_Rate__c selectEffectiveRate(
        Id taxCodeId,
        Date taxDate
    ) {
        if (taxCodeId == null) {
            throw new TaxException(
                'Tax Code Id is required.'
            );
        }

        if (taxDate == null) {
            throw new TaxException(
                'Tax Date is required.'
            );
        }

        List<Tax_Rate__c> rates = [
            SELECT Id,
                   Tax_Code__c,
                   Tax_Code__r.Company__c,
                   Tax_Code__r.Is_Active__c,
                   Effective_From__c,
                   Effective_To__c,
                   Rate_Key__c,
                   Rate__c,
                   Recoverable_Percent__c,
                   Country_Pack_Version__c
            FROM Tax_Rate__c
            WHERE Tax_Code__c =
                    :taxCodeId
              AND Effective_From__c
                    <= :taxDate
              AND (
                    Effective_To__c = NULL
                    OR Effective_To__c
                        >= :taxDate
              )
            ORDER BY Effective_From__c DESC,
                     CreatedDate DESC,
                     Id DESC
            LIMIT 1
        ];

        if (rates.isEmpty()) {
            throw new TaxException(
                'No effective Tax Rate exists for the selected Tax Code and Tax Date.'
            );
        }

        return rates[0];
    }

    private class NormalizedRequest {
        public Id companyId;
        public Id taxCodeId;
        public Date taxDate;
        public Decimal lineAmount;
        public String documentSide;
        public RoundingMode roundingMode;
    }

    private static NormalizedRequest
        normalizeAndValidateRequest(
            TaxRequest request
        )
    {
        if (request == null) {
            throw new TaxException(
                'Tax calculation request is required.'
            );
        }

        if (request.companyId == null) {
            throw new TaxException(
                'Accounting Company is required.'
            );
        }

        if (request.taxCodeId == null) {
            throw new TaxException(
                'Tax Code is required.'
            );
        }

        if (request.taxDate == null) {
            throw new TaxException(
                'Tax Date is required.'
            );
        }

        if (request.lineAmount == null) {
            throw new TaxException(
                'Tax line amount is required.'
            );
        }

        if (request.lineAmount < 0) {
            throw new TaxException(
                'G6A Tax Engine expects a non-negative line amount. Document sign/direction is handled by the calling document service.'
            );
        }

        if (request.roundingMode == null) {
            throw new TaxException(
                'Rounding mode is required.'
            );
        }

        String side =
            normalizeSide(
                request.documentSide
            );

        NormalizedRequest normalized =
            new NormalizedRequest();

        normalized.companyId =
            request.companyId;
        normalized.taxCodeId =
            request.taxCodeId;
        normalized.taxDate =
            request.taxDate;
        normalized.lineAmount =
            request.lineAmount;
        normalized.documentSide =
            side;
        normalized.roundingMode =
            request.roundingMode;

        return normalized;
    }

    private static String normalizeSide(
        String documentSide
    ) {
        if (String.isBlank(documentSide)) {
            throw new TaxException(
                'Document Side is required.'
            );
        }

        if (
            documentSide.trim()
                .equalsIgnoreCase(
                    SIDE_SALES
                )
        ) {
            return SIDE_SALES;
        }

        if (
            documentSide.trim()
                .equalsIgnoreCase(
                    SIDE_PURCHASE
                )
        ) {
            return SIDE_PURCHASE;
        }

        throw new TaxException(
            'Document Side must be Sales or Purchase.'
        );
    }

    private static void validateTaxCode(
        Tax_Code__c taxCode,
        NormalizedRequest request
    ) {
        if (taxCode == null) {
            throw new TaxException(
                'Tax Code is required.'
            );
        }

        if (taxCode.Company__c == null) {
            throw new TaxException(
                'Tax Code must belong to an Accounting Company.'
            );
        }

        if (
            taxCode.Company__c
            != request.companyId
        ) {
            throw new TaxException(
                'Tax Code must belong to the same Accounting Company as the document.'
            );
        }

        if (taxCode.Is_Active__c != true) {
            throw new TaxException(
                'Tax Code must be active.'
            );
        }

        if (String.isBlank(taxCode.Code__c)) {
            throw new TaxException(
                'Tax Code key is required.'
            );
        }

        if (
            String.isBlank(
                taxCode.Jurisdiction__c
            )
        ) {
            throw new TaxException(
                'Tax Code Jurisdiction is required.'
            );
        }

        Set<String> genericTreatments =
            new Set<String>{
                'Standard',
                'Zero',
                'Exempt'
            };

        if (
            !genericTreatments.contains(
                taxCode.Treatment__c
            )
        ) {
            throw new TaxException(
                'Tax Treatment '
                + taxCode.Treatment__c
                + ' requires a supported country-specific tax rule adapter and is not calculated by the generic G6A engine.'
            );
        }
    }

    private static void validateTaxRate(
        Tax_Rate__c taxRate,
        Tax_Code__c taxCode
    ) {
        if (
            taxRate == null
            || taxRate.Id == null
        ) {
            throw new TaxException(
                'Tax Rate is required.'
            );
        }

        if (
            taxRate.Tax_Code__c
            != taxCode.Id
        ) {
            throw new TaxException(
                'Tax Rate does not belong to the selected Tax Code.'
            );
        }

        if (taxRate.Rate__c == null) {
            throw new TaxException(
                'Tax Rate percent is required.'
            );
        }

        if (taxRate.Rate__c < 0) {
            throw new TaxException(
                'Tax Rate percent cannot be negative.'
            );
        }

        if (
            (
                taxCode.Treatment__c == 'Zero'
                || taxCode.Treatment__c
                    == 'Exempt'
            )
            && taxRate.Rate__c != 0
        ) {
            throw new TaxException(
                'Zero and Exempt Tax Codes must use a zero percent Tax Rate in the generic G6A engine.'
            );
        }

        if (
            taxRate.Recoverable_Percent__c
                != null
            && (
                taxRate.Recoverable_Percent__c
                    < 0
                || taxRate.Recoverable_Percent__c
                    > 100
            )
        ) {
            throw new TaxException(
                'Recoverable Percent must be between 0 and 100.'
            );
        }
    }

    private static Decimal resolveRecoverablePercent(
        Tax_Code__c taxCode,
        Tax_Rate__c taxRate,
        String documentSide
    ) {
        if (documentSide == SIDE_SALES) {
            return Decimal.valueOf('0');
        }

        if (
            taxCode.Recoverability__c
                == 'Full'
        ) {
            return Decimal.valueOf('100');
        }

        if (
            taxCode.Recoverability__c
                == 'None'
            || String.isBlank(
                taxCode.Recoverability__c
            )
        ) {
            return Decimal.valueOf('0');
        }

        if (
            taxCode.Recoverability__c
                == 'Partial'
        ) {
            if (
                taxRate.Recoverable_Percent__c
                    == null
            ) {
                throw new TaxException(
                    'Partial tax recoverability requires Recoverable Percent on the effective Tax Rate.'
                );
            }

            return taxRate.Recoverable_Percent__c;
        }

        throw new TaxException(
            'Unsupported Tax Code recoverability configuration.'
        );
    }

    private static Decimal normalizeAmount(
        Decimal amount,
        RoundingMode roundingMode
    ) {
        return SABMoneyService.normalizeTransactionAmount(
                amount,
                roundingMode
            );
    }
}
