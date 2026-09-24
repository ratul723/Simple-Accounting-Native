/**
 * Simple Accounting Books - Money Service
 *
 * Step 4A: shared money/currency primitives using the CURRENT SAB schema.
 *
 * Existing metadata used as the storage contract:
 * - Journal_Entry_Line__c.Transaction_Amount__c   Number(18,4)
 * - Journal_Entry_Line__c.Debit_Base__c           Number(18,4)
 * - Journal_Entry_Line__c.Credit_Base__c          Number(18,4)
 * - Journal_Entry_Line__c.Applied_Exchange_Rate__c Number(18,10)
 * - Journal_Entry_Line__c.Transaction_Currency__c Text(3)
 * - Journal_Entry_Line__c.Functional_Currency__c  Text(3)
 * - Accounting_Company__c.Functional_Currency__c  Text(3)
 * - Exchange_Rate__c.Rate__c                      Number(18,10)
 *
 * Important design decision:
 * The product plan requires zero-, two- and three-minor-unit currency testing,
 * but the current metadata does NOT define an authoritative currency->minor-unit
 * mapping and does NOT define one mandatory rounding mode.
 *
 * Therefore this service DOES NOT silently invent either policy:
 * - callers supply minorUnits (0..3) when rounding a display/document amount;
 * - callers supply System.RoundingMode for business-sensitive rounding.
 *
 * Internal SAB ledger/base storage remains 4 decimal places and stored FX rates
 * remain 10 decimal places because those are the deployed field contracts.
 */
public class SABMoneyService {

    public class MoneyException extends Exception {}

    @TestVisible
    private static final Integer LEDGER_SCALE =
        Journal_Entry_Line__c.Debit_Base__c
            .getDescribe()
            .getScale();

    @TestVisible
    private static final Integer TRANSACTION_SCALE =
        Journal_Entry_Line__c.Transaction_Amount__c
            .getDescribe()
            .getScale();

    @TestVisible
    private static final Integer EXCHANGE_RATE_SCALE =
        Journal_Entry_Line__c.Applied_Exchange_Rate__c
            .getDescribe()
            .getScale();

    @TestVisible
    private static final Integer CURRENCY_CODE_LENGTH =
        Accounting_Company__c.Functional_Currency__c
            .getDescribe()
            .getLength();

    public class ConversionResult {
        public Decimal transactionAmount { get; private set; }
        public String transactionCurrency { get; private set; }
        public String functionalCurrency { get; private set; }
        public Decimal appliedExchangeRate { get; private set; }
        public Decimal functionalAmount { get; private set; }

        private ConversionResult(
            Decimal normalizedTransactionAmount,
            String normalizedTransactionCurrency,
            String normalizedFunctionalCurrency,
            Decimal normalizedExchangeRate,
            Decimal normalizedFunctionalAmount
        ) {
            transactionAmount = normalizedTransactionAmount;
            transactionCurrency = normalizedTransactionCurrency;
            functionalCurrency = normalizedFunctionalCurrency;
            appliedExchangeRate = normalizedExchangeRate;
            functionalAmount = normalizedFunctionalAmount;
        }
    }

    /**
     * Normalizes and validates the 3-character currency code used by the
     * existing SAB Text(3) currency fields.
     *
     * This validates the technical storage contract only. It intentionally
     * does not claim that every 3-letter code is a supported launch currency.
     */
    public static String normalizeCurrencyCode(String currencyCode) {
        if (String.isBlank(currencyCode)) {
            throw new MoneyException(
                'Currency code is required.'
            );
        }

        String normalized =
            currencyCode.trim().toUpperCase();

        if (
            normalized.length() != CURRENCY_CODE_LENGTH
            || normalized.replaceAll('[A-Z]', '') != ''
        ) {
            throw new MoneyException(
                'Currency code must contain exactly '
                + CURRENCY_CODE_LENGTH
                + ' letters.'
            );
        }

        return normalized;
    }

    /**
     * Normalizes an amount to the current SAB transaction storage scale.
     */
    public static Decimal normalizeTransactionAmount(
        Decimal amount,
        RoundingMode roundingMode
    ) {
        requireAmount(amount);
        requireRoundingMode(roundingMode);

        return amount.setScale(
            TRANSACTION_SCALE,
            roundingMode
        );
    }

    /**
     * Normalizes a debit/credit/base ledger amount to the current SAB
     * Number(18,4) storage scale.
     */
    public static Decimal normalizeLedgerAmount(
        Decimal amount,
        RoundingMode roundingMode
    ) {
        requireAmount(amount);
        requireRoundingMode(roundingMode);

        return amount.setScale(
            LEDGER_SCALE,
            roundingMode
        );
    }

    /**
     * Normalizes an FX rate to the current SAB Number(18,10) storage scale.
     */
    public static Decimal normalizeExchangeRate(
        Decimal exchangeRate,
        RoundingMode roundingMode
    ) {
        if (exchangeRate == null) {
            throw new MoneyException(
                'Exchange rate is required.'
            );
        }

        if (exchangeRate <= 0) {
            throw new MoneyException(
                'Exchange rate must be greater than zero.'
            );
        }

        requireRoundingMode(roundingMode);

        return exchangeRate.setScale(
            EXCHANGE_RATE_SCALE,
            roundingMode
        );
    }

    /**
     * Rounds a document/display amount to the explicitly supplied currency
     * minor-unit count.
     *
     * Step 4A intentionally accepts only the 0/1/2/3 range. The product plan
     * explicitly requires testing 0-, 2- and 3-decimal currencies; the final
     * supported-currency catalog will own the actual mapping.
     */
    public static Decimal roundForMinorUnits(
        Decimal amount,
        Integer minorUnits,
        RoundingMode roundingMode
    ) {
        requireAmount(amount);
        validateMinorUnits(minorUnits);
        requireRoundingMode(roundingMode);

        return amount.setScale(
            minorUnits,
            roundingMode
        );
    }

    /**
     * Converts a transaction amount into the company's functional/base
     * currency using a posting snapshot rate.
     *
     * Same-currency:
     * - effective rate = 1.0000000000
     * - a supplied non-1 rate is rejected.
     *
     * Foreign-currency:
     * - a positive rate is mandatory.
     *
     * Negative transaction amounts are allowed because credits/refunds are
     * valid accounting cases.
     */
    public static ConversionResult convertToFunctional(
        Decimal transactionAmount,
        String transactionCurrency,
        String functionalCurrency,
        Decimal exchangeRate,
        RoundingMode roundingMode
    ) {
        requireAmount(transactionAmount);
        requireRoundingMode(roundingMode);

        String normalizedTransactionCurrency =
            normalizeCurrencyCode(
                transactionCurrency
            );

        String normalizedFunctionalCurrency =
            normalizeCurrencyCode(
                functionalCurrency
            );

        Decimal storedTransactionAmount =
            normalizeTransactionAmount(
                transactionAmount,
                roundingMode
            );

        Decimal normalizedRate;

        if (
            normalizedTransactionCurrency
            == normalizedFunctionalCurrency
        ) {
            if (
                exchangeRate != null
                && exchangeRate != 1
            ) {
                throw new MoneyException(
                    'Same-currency conversion must use an exchange rate of 1.'
                );
            }

            normalizedRate =
                Decimal.valueOf('1')
                    .setScale(
                        EXCHANGE_RATE_SCALE,
                        roundingMode
                    );
        } else {
            normalizedRate =
                normalizeExchangeRate(
                    exchangeRate,
                    roundingMode
                );
        }

        Decimal functionalAmount =
            normalizeLedgerAmount(
                storedTransactionAmount
                    * normalizedRate,
                roundingMode
            );

        return new ConversionResult(
            storedTransactionAmount,
            normalizedTransactionCurrency,
            normalizedFunctionalCurrency,
            normalizedRate,
            functionalAmount
        );
    }

    /**
     * Compares ledger values only after applying the authoritative SAB ledger
     * storage scale.
     */
    public static Boolean ledgerAmountsEqual(
        Decimal leftAmount,
        Decimal rightAmount,
        RoundingMode roundingMode
    ) {
        requireAmount(leftAmount);
        requireAmount(rightAmount);
        requireRoundingMode(roundingMode);

        return normalizeLedgerAmount(
                leftAmount,
                roundingMode
            )
            == normalizeLedgerAmount(
                rightAmount,
                roundingMode
            );
    }

    /**
     * Returns the normalized ledger-scale difference between expected and
     * actual amounts. The caller decides whether that difference should be
     * allocated to a configured rounding account.
     */
    public static Decimal roundingDifference(
        Decimal expectedAmount,
        Decimal actualAmount,
        RoundingMode roundingMode
    ) {
        requireAmount(expectedAmount);
        requireAmount(actualAmount);
        requireRoundingMode(roundingMode);

        return normalizeLedgerAmount(
            expectedAmount - actualAmount,
            roundingMode
        );
    }

    /**
     * Verifies that the configured default rounding account belongs to the
     * same Accounting Company.
     *
     * Null is allowed because the current company metadata does not make
     * Default_Rounding_Account__c schema-required. Callers that require a
     * rounding account for a particular transaction can enforce that policy
     * separately.
     */
    public static void assertRoundingAccountBelongsToCompany(
        Accounting_Company__c company
    ) {
        if (company == null || company.Id == null) {
            throw new MoneyException(
                'Accounting Company is required.'
            );
        }

        Accounting_Company__c storedCompany = [
            SELECT Id,
                   Default_Rounding_Account__c,
                   Default_Rounding_Account__r.Company__c
            FROM Accounting_Company__c
            WHERE Id = :company.Id
            LIMIT 1
        ];

        if (
            storedCompany.Default_Rounding_Account__c != null
        ) {
            assertSameCompany(
                storedCompany.Id,
                storedCompany.Default_Rounding_Account__r.Company__c
            );
        }
    }

    @TestVisible
    private static void assertSameCompany(
        Id companyId,
        Id relatedCompanyId
    ) {
        if (
            companyId == null
            || relatedCompanyId == null
            || companyId != relatedCompanyId
        ) {
            throw new MoneyException(
                'Default Rounding Account must belong to the same Accounting Company.'
            );
        }
    }

    /**
     * Exposes current deployed precision contracts for regression tests and
     * other SAB services without duplicating magic numbers.
     */
    public static Integer ledgerScale() {
        return LEDGER_SCALE;
    }

    public static Integer transactionScale() {
        return TRANSACTION_SCALE;
    }

    public static Integer exchangeRateScale() {
        return EXCHANGE_RATE_SCALE;
    }

    private static void requireAmount(Decimal amount) {
        if (amount == null) {
            throw new MoneyException(
                'Amount is required.'
            );
        }
    }

    private static void requireRoundingMode(
        RoundingMode roundingMode
    ) {
        if (roundingMode == null) {
            throw new MoneyException(
                'Rounding mode is required.'
            );
        }
    }

    private static void validateMinorUnits(
        Integer minorUnits
    ) {
        if (
            minorUnits == null
            || minorUnits < 0
            || minorUnits > 3
        ) {
            throw new MoneyException(
                'Minor units must be between 0 and 3 for the current supported design.'
            );
        }
    }
}
