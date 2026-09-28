/**
 * G6C - Tax Return Preparation.
 *
 * Generic, country-neutral preparation layer over the G6A/G6B tax snapshots.
 *
 * Source of truth:
 * - only materialized Document_Tax_Line__c rows
 * - only source documents in Posted status
 * - source document Document_Date__c must fall inside the return period
 * - source jurisdiction must match the selected Tax Registration
 *
 * Generic internal return boxes:
 * - OUTPUT_TAXABLE_BASE
 * - OUTPUT_TAX
 * - INPUT_TAXABLE_BASE
 * - INPUT_TAX_RECOVERABLE
 * - NET_TAX_DUE
 *
 * Country-specific authority form mapping / submission is intentionally left
 * to the next country-pack / filing stage.
 */
public without sharing class SABTaxReturnService {

    public class TaxReturnException extends Exception {}

    private static final String PREPARE_PERMISSION =
        'SAB_Prepare_Tax_Return';

    private static final String STATUS_DRAFT =
        'Draft';

    private static final String STATUS_PREPARED =
        'Prepared';

    private static final String BOX_OUTPUT_BASE =
        'OUTPUT_TAXABLE_BASE';

    private static final String BOX_OUTPUT_TAX =
        'OUTPUT_TAX';

    private static final String BOX_INPUT_BASE =
        'INPUT_TAXABLE_BASE';

    private static final String BOX_INPUT_RECOVERABLE =
        'INPUT_TAX_RECOVERABLE';

    private static final String BOX_NET_DUE =
        'NET_TAX_DUE';

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    public class PreparedReturnResult {
        public Id taxReturnId { get; private set; }
        public Id taxRegistrationId { get; private set; }
        public Id companyId { get; private set; }
        public Date periodStart { get; private set; }
        public Date periodEnd { get; private set; }
        public Decimal returnVersion { get; private set; }
        public String status { get; private set; }
        public String countryPackVersion { get; private set; }
        public Integer returnLineCount { get; private set; }
        public Integer outputSourceCount { get; private set; }
        public Integer inputSourceCount { get; private set; }
        public Decimal outputTaxableBase { get; private set; }
        public Decimal outputTax { get; private set; }
        public Decimal inputTaxableBase { get; private set; }
        public Decimal recoverableInputTax { get; private set; }
        public Decimal netTaxDue { get; private set; }
        public Boolean rebuiltExistingReturn { get; private set; }

        private PreparedReturnResult() {}
    }

    private class ReturnComputation {
        public Decimal outputTaxableBase = ZERO;
        public Decimal outputTax = ZERO;
        public Decimal inputTaxableBase = ZERO;
        public Decimal recoverableInputTax = ZERO;
        public List<String> outputSourceIds =
            new List<String>();
        public List<String> inputSourceIds =
            new List<String>();
    }

    /**
     * Prepares or rebuilds the latest Draft/Prepared return for one exact
     * registration + period. Reviewed/submitted/accepted/rejected/amended
     * returns are treated as locked; a future amendment workflow must create a
     * new version rather than mutating them.
     */
    public static PreparedReturnResult prepareReturn(
        Id taxRegistrationId,
        Date periodStart,
        Date periodEnd
    ) {
        SABPermissionService.assertPermission(
            PREPARE_PERMISSION,
            'You do not have permission to prepare Tax Returns.'
        );

        validatePeriod(
            periodStart,
            periodEnd
        );

        Tax_Registration__c registration =
            loadAndValidateRegistration(
                taxRegistrationId,
                periodStart,
                periodEnd
            );

        SABCompanyAccessService.assertCompanyAccess(
            registration.Company__c
        );

        List<Tax_Return__c> existingReturns = [
            SELECT Id,
                   Company__c,
                   Tax_Registration__c,
                   Period_Start__c,
                   Period_End__c,
                   Country_Pack_Version__c,
                   Return_Version__c,
                   Status__c,
                   CreatedDate
            FROM Tax_Return__c
            WHERE Tax_Registration__c =
                    :registration.Id
              AND Period_Start__c =
                    :periodStart
              AND Period_End__c =
                    :periodEnd
            FOR UPDATE
        ];

        Tax_Return__c taxReturn;
        Boolean rebuiltExisting =
            false;

        if (existingReturns.isEmpty()) {
            taxReturn =
                new Tax_Return__c(
                    Company__c =
                        registration.Company__c,
                    Tax_Registration__c =
                        registration.Id,
                    Period_Start__c =
                        periodStart,
                    Period_End__c =
                        periodEnd,
                    Country_Pack_Version__c =
                        registration.Country_Pack_Version__c,
                    Return_Version__c =
                        1,
                    Status__c =
                        STATUS_DRAFT
                );

            insert taxReturn;
        } else {
            taxReturn =
                selectLatestReturn(
                    existingReturns
                );

            if (
                taxReturn.Status__c
                    != STATUS_DRAFT
                && taxReturn.Status__c
                    != STATUS_PREPARED
            ) {
                throw new TaxReturnException(
                    'A locked Tax Return already exists for this Tax Registration and period. Use the amendment workflow instead of rebuilding it.'
                );
            }

            if (
                taxReturn.Company__c
                    != registration.Company__c
            ) {
                throw new TaxReturnException(
                    'Existing Tax Return belongs to a different Accounting Company.'
                );
            }

            if (
                taxReturn.Country_Pack_Version__c
                    != registration.Country_Pack_Version__c
            ) {
                throw new TaxReturnException(
                    'Tax Registration Country Pack Version changed after this Tax Return was created. Create a controlled amendment/version instead of silently changing the prepared return.'
                );
            }

            rebuiltExisting =
                true;
        }

        Map<String, Decimal> priorAdjustments =
            loadPriorAdjustments(
                taxReturn.Id
            );

        ReturnComputation computation =
            computeReturn(
                registration,
                periodStart,
                periodEnd
            );

        List<Tax_Return_Line__c> existingLines = [
            SELECT Id
            FROM Tax_Return_Line__c
            WHERE Tax_Return__c =
                    :taxReturn.Id
        ];

        if (!existingLines.isEmpty()) {
            delete existingLines;
        }

        Decimal netDue =
            normalizeAmount(
                computation.outputTax
                - computation.recoverableInputTax
            );

        List<Tax_Return_Line__c> newLines =
            new List<Tax_Return_Line__c>{
                buildReturnLine(
                    taxReturn.Id,
                    BOX_OUTPUT_BASE,
                    'Output Taxable Base',
                    computation.outputTaxableBase,
                    getAdjustment(
                        priorAdjustments,
                        BOX_OUTPUT_BASE
                    ),
                    buildSourceHash(
                        'OUTPUT_BASE',
                        computation.outputSourceIds
                    )
                ),
                buildReturnLine(
                    taxReturn.Id,
                    BOX_OUTPUT_TAX,
                    'Output Tax',
                    computation.outputTax,
                    getAdjustment(
                        priorAdjustments,
                        BOX_OUTPUT_TAX
                    ),
                    buildSourceHash(
                        'OUTPUT_TAX',
                        computation.outputSourceIds
                    )
                ),
                buildReturnLine(
                    taxReturn.Id,
                    BOX_INPUT_BASE,
                    'Input Taxable Base',
                    computation.inputTaxableBase,
                    getAdjustment(
                        priorAdjustments,
                        BOX_INPUT_BASE
                    ),
                    buildSourceHash(
                        'INPUT_BASE',
                        computation.inputSourceIds
                    )
                ),
                buildReturnLine(
                    taxReturn.Id,
                    BOX_INPUT_RECOVERABLE,
                    'Recoverable Input Tax',
                    computation.recoverableInputTax,
                    getAdjustment(
                        priorAdjustments,
                        BOX_INPUT_RECOVERABLE
                    ),
                    buildSourceHash(
                        'INPUT_RECOVERABLE',
                        computation.inputSourceIds
                    )
                ),
                buildReturnLine(
                    taxReturn.Id,
                    BOX_NET_DUE,
                    'Net Tax Due',
                    netDue,
                    getAdjustment(
                        priorAdjustments,
                        BOX_NET_DUE
                    ),
                    buildSourceHash(
                        'NET_DUE',
                        combineIds(
                            computation.outputSourceIds,
                            computation.inputSourceIds
                        )
                    )
                )
            };

        insert newLines;

        taxReturn.Status__c =
            STATUS_PREPARED;

        update taxReturn;

        PreparedReturnResult result =
            new PreparedReturnResult();

        result.taxReturnId =
            taxReturn.Id;
        result.taxRegistrationId =
            registration.Id;
        result.companyId =
            registration.Company__c;
        result.periodStart =
            periodStart;
        result.periodEnd =
            periodEnd;
        result.returnVersion =
            taxReturn.Return_Version__c;
        result.status =
            STATUS_PREPARED;
        result.countryPackVersion =
            registration.Country_Pack_Version__c;
        result.returnLineCount =
            newLines.size();
        result.outputSourceCount =
            computation.outputSourceIds.size();
        result.inputSourceCount =
            computation.inputSourceIds.size();
        result.outputTaxableBase =
            normalizeAmount(
                computation.outputTaxableBase
            );
        result.outputTax =
            normalizeAmount(
                computation.outputTax
            );
        result.inputTaxableBase =
            normalizeAmount(
                computation.inputTaxableBase
            );
        result.recoverableInputTax =
            normalizeAmount(
                computation.recoverableInputTax
            );
        result.netTaxDue =
            netDue;
        result.rebuiltExistingReturn =
            rebuiltExisting;

        return result;
    }

    /**
     * Manual adjustment support for a prepared internal return box.
     * Re-preparing the same Draft/Prepared return preserves these adjustments.
     */
    public static Tax_Return_Line__c setAdjustment(
        Id taxReturnId,
        String boxKey,
        Decimal adjustmentAmount
    ) {
        SABPermissionService.assertPermission(
            PREPARE_PERMISSION,
            'You do not have permission to adjust prepared Tax Returns.'
        );

        if (taxReturnId == null) {
            throw new TaxReturnException(
                'Tax Return Id is required.'
            );
        }

        if (String.isBlank(boxKey)) {
            throw new TaxReturnException(
                'Tax Return Box Key is required.'
            );
        }

        Tax_Return__c taxReturn = [
            SELECT Id,
                   Company__c,
                   Status__c
            FROM Tax_Return__c
            WHERE Id = :taxReturnId
            LIMIT 1
            FOR UPDATE
        ];

        SABCompanyAccessService.assertCompanyAccess(
            taxReturn.Company__c
        );

        if (
            taxReturn.Status__c
                != STATUS_DRAFT
            && taxReturn.Status__c
                != STATUS_PREPARED
        ) {
            throw new TaxReturnException(
                'Only Draft or Prepared Tax Returns can be adjusted.'
            );
        }

        List<Tax_Return_Line__c> lines = [
            SELECT Id,
                   Tax_Return__c,
                   Box_Key__c,
                   Calculated_Amount__c,
                   Adjustment_Amount__c,
                   Final_Amount__c
            FROM Tax_Return_Line__c
            WHERE Tax_Return__c =
                    :taxReturn.Id
              AND Box_Key__c =
                    :boxKey.trim()
            LIMIT 2
            FOR UPDATE
        ];

        if (lines.isEmpty()) {
            throw new TaxReturnException(
                'Tax Return Box was not found.'
            );
        }

        if (lines.size() > 1) {
            throw new TaxReturnException(
                'Duplicate Tax Return Box rows were found.'
            );
        }

        Tax_Return_Line__c line =
            lines[0];

        Decimal adjustment =
            normalizeAmount(
                adjustmentAmount
            );

        line.Adjustment_Amount__c =
            adjustment;

        line.Final_Amount__c =
            normalizeAmount(
                nullToZero(
                    line.Calculated_Amount__c
                )
                + adjustment
            );

        update line;

        return line;
    }

    private static ReturnComputation computeReturn(
        Tax_Registration__c registration,
        Date periodStart,
        Date periodEnd
    ) {
        ReturnComputation result =
            new ReturnComputation();

        List<Document_Tax_Line__c> outputRows = [
            SELECT Id,
                   Taxable_Base__c,
                   Tax_Amount__c,
                   Invoice_Line__c,
                   Invoice_Line__r.Invoice__c,
                   Invoice_Line__r.Invoice__r.Document_Type__c,
                   Invoice_Line__r.Invoice__r.Status__c,
                   Invoice_Line__r.Invoice__r.Document_Date__c
            FROM Document_Tax_Line__c
            WHERE Company__c =
                    :registration.Company__c
              AND Jurisdiction__c =
                    :registration.Jurisdiction__c
              AND Invoice_Line__c != NULL
              AND Invoice_Line__r.Invoice__r.Status__c =
                    'Posted'
              AND Invoice_Line__r.Invoice__r.Document_Date__c
                    >= :periodStart
              AND Invoice_Line__r.Invoice__r.Document_Date__c
                    <= :periodEnd
        ];

        for (
            Document_Tax_Line__c row :
            outputRows
        ) {
            Decimal sign =
                row.Invoice_Line__r
                    .Invoice__r
                    .Document_Type__c
                    == 'Credit Note'
                        ? Decimal.valueOf('-1')
                        : Decimal.valueOf('1');

            result.outputTaxableBase +=
                sign
                * nullToZero(
                    row.Taxable_Base__c
                );

            result.outputTax +=
                sign
                * nullToZero(
                    row.Tax_Amount__c
                );

            result.outputSourceIds.add(
                String.valueOf(
                    row.Id
                )
            );
        }

        List<Document_Tax_Line__c> inputRows = [
            SELECT Id,
                   Taxable_Base__c,
                   Tax_Amount__c,
                   Recoverable_Amount__c,
                   Bill_Line__c,
                   Bill_Line__r.Supplier_Bill__c,
                   Bill_Line__r.Supplier_Bill__r.Document_Type__c,
                   Bill_Line__r.Supplier_Bill__r.Status__c,
                   Bill_Line__r.Supplier_Bill__r.Document_Date__c
            FROM Document_Tax_Line__c
            WHERE Company__c =
                    :registration.Company__c
              AND Jurisdiction__c =
                    :registration.Jurisdiction__c
              AND Bill_Line__c != NULL
              AND Bill_Line__r.Supplier_Bill__r.Status__c =
                    'Posted'
              AND Bill_Line__r.Supplier_Bill__r.Document_Date__c
                    >= :periodStart
              AND Bill_Line__r.Supplier_Bill__r.Document_Date__c
                    <= :periodEnd
        ];

        for (
            Document_Tax_Line__c row :
            inputRows
        ) {
            Decimal sign =
                row.Bill_Line__r
                    .Supplier_Bill__r
                    .Document_Type__c
                    == 'Supplier Credit'
                        ? Decimal.valueOf('-1')
                        : Decimal.valueOf('1');

            result.inputTaxableBase +=
                sign
                * nullToZero(
                    row.Taxable_Base__c
                );

            result.recoverableInputTax +=
                sign
                * nullToZero(
                    row.Recoverable_Amount__c
                );

            result.inputSourceIds.add(
                String.valueOf(
                    row.Id
                )
            );
        }

        result.outputTaxableBase =
            normalizeAmount(
                result.outputTaxableBase
            );

        result.outputTax =
            normalizeAmount(
                result.outputTax
            );

        result.inputTaxableBase =
            normalizeAmount(
                result.inputTaxableBase
            );

        result.recoverableInputTax =
            normalizeAmount(
                result.recoverableInputTax
            );

        return result;
    }

    private static Tax_Registration__c
        loadAndValidateRegistration(
            Id taxRegistrationId,
            Date periodStart,
            Date periodEnd
        )
    {
        if (taxRegistrationId == null) {
            throw new TaxReturnException(
                'Tax Registration is required.'
            );
        }

        Tax_Registration__c registration = [
            SELECT Id,
                   Name,
                   Company__c,
                   Country_Pack_Version__c,
                   Effective_From__c,
                   Effective_To__c,
                   Filing_Frequency__c,
                   Is_Active__c,
                   Jurisdiction__c,
                   Registration_Identifier__c
            FROM Tax_Registration__c
            WHERE Id = :taxRegistrationId
            LIMIT 1
        ];

        if (
            registration.Is_Active__c
                != true
        ) {
            throw new TaxReturnException(
                'Tax Registration must be active.'
            );
        }

        if (
            registration.Effective_From__c
                == null
            || registration.Effective_From__c
                > periodStart
        ) {
            throw new TaxReturnException(
                'Tax Return period starts before the Tax Registration becomes effective.'
            );
        }

        if (
            registration.Effective_To__c
                != null
            && registration.Effective_To__c
                < periodEnd
        ) {
            throw new TaxReturnException(
                'Tax Return period ends after the Tax Registration expires.'
            );
        }

        if (
            String.isBlank(
                registration.Jurisdiction__c
            )
        ) {
            throw new TaxReturnException(
                'Tax Registration Jurisdiction is required.'
            );
        }

        if (
            String.isBlank(
                registration.Country_Pack_Version__c
            )
        ) {
            throw new TaxReturnException(
                'Tax Registration Country Pack Version is required.'
            );
        }

        if (
            String.isBlank(
                registration.Registration_Identifier__c
            )
        ) {
            throw new TaxReturnException(
                'Tax Registration Identifier is required.'
            );
        }

        return registration;
    }

    private static void validatePeriod(
        Date periodStart,
        Date periodEnd
    ) {
        if (
            periodStart == null
            || periodEnd == null
        ) {
            throw new TaxReturnException(
                'Tax Return Period Start and Period End are required.'
            );
        }

        if (periodStart > periodEnd) {
            throw new TaxReturnException(
                'Tax Return Period Start cannot be after Period End.'
            );
        }
    }

    private static Tax_Return__c selectLatestReturn(
        List<Tax_Return__c> returns
    ) {
        if (
            returns == null
            || returns.isEmpty()
        ) {
            return null;
        }

        Tax_Return__c latest;

        for (Tax_Return__c candidate : returns) {
            if (latest == null) {
                latest = candidate;
                continue;
            }

            Decimal candidateVersion =
                candidate.Return_Version__c == null
                    ? ZERO
                    : candidate.Return_Version__c;

            Decimal latestVersion =
                latest.Return_Version__c == null
                    ? ZERO
                    : latest.Return_Version__c;

            if (
                candidateVersion > latestVersion
                || (
                    candidateVersion == latestVersion
                    && candidate.CreatedDate > latest.CreatedDate
                )
            ) {
                latest = candidate;
            }
        }

        return latest;
    }

    private static Map<String, Decimal>
        loadPriorAdjustments(
            Id taxReturnId
        )
    {
        Map<String, Decimal> result =
            new Map<String, Decimal>();

        if (taxReturnId == null) {
            return result;
        }

        for (Tax_Return_Line__c line : [
            SELECT Box_Key__c,
                   Adjustment_Amount__c
            FROM Tax_Return_Line__c
            WHERE Tax_Return__c =
                    :taxReturnId
        ]) {
            if (
                !String.isBlank(
                    line.Box_Key__c
                )
            ) {
                result.put(
                    line.Box_Key__c,
                    nullToZero(
                        line.Adjustment_Amount__c
                    )
                );
            }
        }

        return result;
    }

    private static Tax_Return_Line__c buildReturnLine(
        Id taxReturnId,
        String boxKey,
        String label,
        Decimal calculatedAmount,
        Decimal adjustmentAmount,
        String sourceHash
    ) {
        Decimal calculated =
            normalizeAmount(
                calculatedAmount
            );

        Decimal adjustment =
            normalizeAmount(
                adjustmentAmount
            );

        return new Tax_Return_Line__c(
            Tax_Return__c =
                taxReturnId,
            Box_Key__c =
                boxKey,
            Label__c =
                label,
            Calculated_Amount__c =
                calculated,
            Adjustment_Amount__c =
                adjustment,
            Final_Amount__c =
                normalizeAmount(
                    calculated
                    + adjustment
                ),
            Source_Inclusion_Hash__c =
                sourceHash
        );
    }

    private static Decimal getAdjustment(
        Map<String, Decimal> adjustments,
        String boxKey
    ) {
        if (
            adjustments == null
            || !adjustments.containsKey(
                boxKey
            )
        ) {
            return ZERO;
        }

        return nullToZero(
            adjustments.get(
                boxKey
            )
        );
    }

    private static String buildSourceHash(
        String boxKey,
        List<String> sourceIds
    ) {
        List<String> values =
            sourceIds == null
                ? new List<String>()
                : new List<String>(
                    sourceIds
                );

        values.sort();

        String payload =
            boxKey
            + '|'
            + String.join(
                values,
                '|'
            );

        return EncodingUtil.convertToHex(
            Crypto.generateDigest(
                'SHA-256',
                Blob.valueOf(
                    payload
                )
            )
        );
    }

    private static List<String> combineIds(
        List<String> firstList,
        List<String> secondList
    ) {
        List<String> result =
            new List<String>();

        if (firstList != null) {
            result.addAll(
                firstList
            );
        }

        if (secondList != null) {
            result.addAll(
                secondList
            );
        }

        return result;
    }

    private static Decimal normalizeAmount(
        Decimal amount
    ) {
        return SABMoneyService.normalizeTransactionAmount(
            amount == null
                ? ZERO
                : amount,
            RoundingMode.HALF_UP
        );
    }

    private static Decimal nullToZero(
        Decimal amount
    ) {
        return amount == null
            ? ZERO
            : amount;
    }
}
