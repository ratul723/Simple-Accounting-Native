/**
 * Simple Accounting Books - Currency/Rounding Guard Service
 *
 * Step 4C.
 *
 * This is the shared posting-time guard for the currency snapshot stored on
 * Journal_Entry_Line__c.
 *
 * Existing fields enforced:
 * - Transaction_Currency__c
 * - Transaction_Amount__c
 * - Functional_Currency__c
 * - Applied_Exchange_Rate__c
 * - Rate_Date__c
 * - Rate_Source__c
 * - Debit_Base__c / Credit_Base__c
 *
 * Important design boundary:
 * - The current SAB schema stores ledger and transaction amounts at 4 decimals.
 * - FX rates are stored at 10 decimals.
 * - SABMoneyService supports explicit 0/1/2/3 minor-unit rounding.
 * - This guard does NOT invent one global commercial/document rounding mode.
 *   Document/subledger services will pass their approved policy into
 *   SABMoneyService when they calculate values.
 */
public class SABCurrencyGuardService {

    public class CurrencyGuardException extends Exception {}

    public class ValidationResult {
        public Boolean isValid { get; private set; }
        public List<String> errors { get; private set; }

        private ValidationResult() {
            isValid = true;
            errors = new List<String>();
        }

        private void addError(String message) {
            isValid = false;
            errors.add(message);
        }
    }

    /**
     * Validates the immutable currency/FX snapshot that will be posted on one
     * journal line.
     *
     * Backward-compatible single-currency rule:
     * If Transaction_Currency__c is blank, all transaction/FX snapshot fields
     * must also be blank. Existing manual journals may therefore continue to
     * use only Functional_Currency__c plus Debit/Credit base amounts.
     *
     * If Transaction_Currency__c is populated, a complete snapshot is
     * required. Foreign-currency lines require amount, positive rate, rate
     * date and source. Same-currency lines may omit the rate; if supplied it
     * must equal 1.
     */
    public static ValidationResult validateJournalLineSnapshot(
        Journal_Entry_Line__c line,
        String companyFunctionalCurrency
    ) {
        ValidationResult result =
            new ValidationResult();

        if (line == null) {
            result.addError(
                'Journal Entry Line is required.'
            );
            return result;
        }

        String companyCurrency =
            normalizeCode(
                companyFunctionalCurrency,
                'Accounting Company Functional Currency',
                result
            );

        String lineFunctionalCurrency =
            normalizeCode(
                line.Functional_Currency__c,
                'Functional Currency',
                result
            );

        if (
            lineFunctionalCurrency != null
            && line.Functional_Currency__c != null
            && !Pattern.matches('[A-Z]{3}', line.Functional_Currency__c.trim())
        ) {
            result.addError(
                'Functional Currency must be stored as a 3-letter uppercase code.'
            );
        }

        if (
            companyCurrency != null
            && lineFunctionalCurrency != null
            && companyCurrency
                != lineFunctionalCurrency
        ) {
            result.addError(
                'Functional Currency must match the Accounting Company functional currency.'
            );
        }

        Boolean transactionCurrencyBlank =
            String.isBlank(
                line.Transaction_Currency__c
            );

        Boolean hasTransactionSnapshotData =
            line.Transaction_Amount__c != null
            || line.Applied_Exchange_Rate__c != null
            || line.Rate_Date__c != null
            || !String.isBlank(line.Rate_Source__c);

        if (transactionCurrencyBlank) {
            if (hasTransactionSnapshotData) {
                result.addError(
                    'Transaction Currency is required when transaction amount or FX snapshot data is populated.'
                );
            }

            return result;
        }

        String transactionCurrency =
            normalizeCode(
                line.Transaction_Currency__c,
                'Transaction Currency',
                result
            );

        if (
            transactionCurrency != null
            && !Pattern.matches('[A-Z]{3}', line.Transaction_Currency__c.trim())
        ) {
            result.addError(
                'Transaction Currency must be stored as a 3-letter uppercase code.'
            );
        }

        if (line.Transaction_Amount__c == null) {
            result.addError(
                'Transaction Amount is required when Transaction Currency is populated.'
            );
        }

        if (
            transactionCurrency == null
            || lineFunctionalCurrency == null
        ) {
            return result;
        }

        Decimal debit =
            line.Debit_Base__c == null
                ? 0
                : line.Debit_Base__c;

        Decimal credit =
            line.Credit_Base__c == null
                ? 0
                : line.Credit_Base__c;

        Decimal baseMagnitude =
            debit.abs() + credit.abs();

        if (
            transactionCurrency
            == lineFunctionalCurrency
        ) {
            if (
                line.Applied_Exchange_Rate__c != null
                && line.Applied_Exchange_Rate__c
                    != 1
            ) {
                result.addError(
                    'Same-currency journal lines must use an Applied Exchange Rate of 1 when a rate is stored.'
                );
            }

            if (
                line.Transaction_Amount__c != null
                && baseMagnitude > 0
                && line.Transaction_Amount__c.abs()
                    != baseMagnitude
            ) {
                result.addError(
                    'For a same-currency journal line, the absolute Transaction Amount must equal the base Debit/Credit amount.'
                );
            }

            return result;
        }

        if (
            line.Applied_Exchange_Rate__c == null
            || line.Applied_Exchange_Rate__c <= 0
        ) {
            result.addError(
                'A positive Applied Exchange Rate is required for a foreign-currency journal line.'
            );
        }

        if (line.Rate_Date__c == null) {
            result.addError(
                'Rate Date is required for a foreign-currency journal line.'
            );
        }

        if (String.isBlank(line.Rate_Source__c)) {
            result.addError(
                'Rate Source is required for a foreign-currency journal line.'
            );
        }

        return result;
    }

    /**
     * Guard used by future document/subledger services before a rounding
     * adjustment is posted.
     *
     * A non-zero rounding difference requires the company to have a configured
     * Default_Rounding_Account__c. Same-company ownership is additionally
     * enforced by the existing Accounting Company validation rule and
     * SABMoneyService.
     */
    public static void assertRoundingConfiguration(
        Id companyId,
        Decimal roundingDifference
    ) {
        if (companyId == null) {
            throw new CurrencyGuardException(
                'Accounting Company Id is required.'
            );
        }

        if (roundingDifference == null) {
            throw new CurrencyGuardException(
                'Rounding Difference is required.'
            );
        }

        Decimal normalizedDifference =
            SABMoneyService.normalizeLedgerAmount(
                roundingDifference,
                RoundingMode.HALF_UP
            );

        if (normalizedDifference == 0) {
            return;
        }

        Accounting_Company__c company = [
            SELECT Id,
                   Default_Rounding_Account__c
            FROM Accounting_Company__c
            WHERE Id = :companyId
            LIMIT 1
        ];

        if (
            company.Default_Rounding_Account__c
            == null
        ) {
            throw new CurrencyGuardException(
                'A Default Rounding Account is required before posting a non-zero rounding difference.'
            );
        }

        SABMoneyService.assertRoundingAccountBelongsToCompany(
                company
            );
    }

    private static String normalizeCode(
        String value,
        String label,
        ValidationResult result
    ) {
        try {
            return SABMoneyService.normalizeCurrencyCode(value);
        } catch (
            SABMoneyService.MoneyException ex
        ) {
            result.addError(
                label
                + ' must be a valid 3-letter currency code.'
            );
            return null;
        }
    }
}
