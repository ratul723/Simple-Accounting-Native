/**
 * G6B - Tax posting integration contract.
 *
 * This service does NOT post a journal independently. Instead it converts
 * materialized Document_Tax_Line__c snapshots into deterministic posting
 * instructions/journal-line bundles that the already-established Invoice and
 * Supplier Bill posting adapters can add before SABPostingService is called.
 *
 * Sales:
 * - Invoice:        Cr Output Tax
 * - Credit Note:    Dr Output Tax
 *
 * Purchase recoverable tax:
 * - Supplier Bill:  Dr Input Tax
 * - Supplier Credit:Cr Input Tax
 *
 * Nonrecoverable purchase tax remains part of the Expense/Asset line cost.
 */
public without sharing class SABTaxPostingIntegrationService {

    public class TaxPostingException extends Exception {}

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    public class PostingInstruction {
        public Id documentTaxLineId { get; private set; }
        public Id taxAccountId { get; private set; }
        public Decimal transactionAmount { get; private set; }
        public Boolean debit { get; private set; }
        public String sourceLineKey { get; private set; }
        public String explanation { get; private set; }

        private PostingInstruction() {}
    }

    public class JournalTaxBundle {
        public List<Journal_Entry_Line__c> lines { get; private set; }
        public Decimal functionalMagnitude { get; private set; }
        public Decimal nextLineNumber { get; private set; }

        private JournalTaxBundle() {
            lines =
                new List<Journal_Entry_Line__c>();
            functionalMagnitude =
                ZERO;
        }
    }

    public static List<PostingInstruction> getInvoiceInstructions(
        Id invoiceId
    ) {
        if (invoiceId == null) {
            throw new TaxPostingException(
                'Invoice Id is required.'
            );
        }

        Invoice__c invoice = [
            SELECT Id,
                   Company__c,
                   Document_Type__c,
                   Tax_Total__c
            FROM Invoice__c
            WHERE Id = :invoiceId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(
            invoice.Company__c
        );

        List<Document_Tax_Line__c> taxRows = [
            SELECT Id,
                   Company__c,
                   Invoice_Line__c,
                   Taxable_Base__c,
                   Tax_Amount__c,
                   Recoverable_Amount__c,
                   Tax_Account__c,
                   Tax_Account__r.Company__c,
                   Tax_Account__r.Is_Active__c,
                   Tax_Account__r.Is_Control_Account__c,
                   Tax_Account__r.Control_Type__c,
                   Tax_Rate__c,
                   Tax_Code_Key__c,
                   Jurisdiction__c,
                   Calculation_Version__c
            FROM Document_Tax_Line__c
            WHERE Invoice_Line__r.Invoice__c =
                    :invoice.Id
            ORDER BY Invoice_Line__c ASC, Id ASC
        ];

        Decimal snapshotTaxTotal = ZERO;

        List<PostingInstruction> result =
            new List<PostingInstruction>();

        for (Document_Tax_Line__c row : taxRows) {
            validateSnapshot(
                row,
                invoice.Company__c
            );

            Decimal taxAmount =
                normalizeAmount(
                    row.Tax_Amount__c
                );

            snapshotTaxTotal +=
                taxAmount;

            if (taxAmount == ZERO) {
                continue;
            }

            PostingInstruction instruction =
                new PostingInstruction();

            instruction.documentTaxLineId =
                row.Id;
            instruction.taxAccountId =
                row.Tax_Account__c;
            instruction.transactionAmount =
                taxAmount;
            instruction.debit =
                invoice.Document_Type__c
                    == 'Credit Note';
            instruction.sourceLineKey =
                'INV|'
                + String.valueOf(
                    invoice.Id
                )
                + '|TAX|'
                + String.valueOf(
                    row.Id
                );
            instruction.explanation =
                'Output Tax - '
                + row.Tax_Code_Key__c;

            result.add(
                instruction
            );
        }

        assertTotalsEqual(
            invoice.Tax_Total__c,
            snapshotTaxTotal,
            'Invoice Tax Total does not match materialized Document Tax Lines.'
        );

        return result;
    }

    public static List<PostingInstruction> getSupplierBillInstructions(
        Id supplierBillId
    ) {
        if (supplierBillId == null) {
            throw new TaxPostingException(
                'Supplier Bill Id is required.'
            );
        }

        Supplier_Bill__c bill = [
            SELECT Id,
                   Company__c,
                   Document_Type__c,
                   Tax_Total__c
            FROM Supplier_Bill__c
            WHERE Id = :supplierBillId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(
            bill.Company__c
        );

        List<Document_Tax_Line__c> taxRows = [
            SELECT Id,
                   Company__c,
                   Bill_Line__c,
                   Bill_Line__r.Recoverable_Tax_Amount__c,
                   Taxable_Base__c,
                   Tax_Amount__c,
                   Recoverable_Amount__c,
                   Tax_Account__c,
                   Tax_Account__r.Company__c,
                   Tax_Account__r.Is_Active__c,
                   Tax_Account__r.Is_Control_Account__c,
                   Tax_Account__r.Control_Type__c,
                   Tax_Rate__c,
                   Tax_Code_Key__c,
                   Jurisdiction__c,
                   Calculation_Version__c
            FROM Document_Tax_Line__c
            WHERE Bill_Line__r.Supplier_Bill__c =
                    :bill.Id
            ORDER BY Bill_Line__c ASC, Id ASC
        ];

        Decimal snapshotTaxTotal =
            ZERO;

        List<PostingInstruction> result =
            new List<PostingInstruction>();

        for (Document_Tax_Line__c row : taxRows) {
            validateSnapshot(
                row,
                bill.Company__c
            );

            Decimal fullTax =
                normalizeAmount(
                    row.Tax_Amount__c
                );

            Decimal recoverable =
                normalizeAmount(
                    row.Recoverable_Amount__c
                );

            snapshotTaxTotal +=
                fullTax;

            Decimal lineRecoverable =
                row.Bill_Line__r == null
                    ? ZERO
                    : normalizeAmount(
                        row.Bill_Line__r
                            .Recoverable_Tax_Amount__c
                    );

            if (recoverable != lineRecoverable) {
                throw new TaxPostingException(
                    'Supplier Bill recoverable tax snapshot does not match its Bill Line.'
                );
            }

            if (recoverable == ZERO) {
                continue;
            }

            PostingInstruction instruction =
                new PostingInstruction();

            instruction.documentTaxLineId =
                row.Id;
            instruction.taxAccountId =
                row.Tax_Account__c;
            instruction.transactionAmount =
                recoverable;
            instruction.debit =
                bill.Document_Type__c
                    == 'Bill';
            instruction.sourceLineKey =
                'SB|'
                + String.valueOf(
                    bill.Id
                )
                + '|TAX|'
                + String.valueOf(
                    row.Id
                );
            instruction.explanation =
                'Recoverable Input Tax - '
                + row.Tax_Code_Key__c;

            result.add(
                instruction
            );
        }

        assertTotalsEqual(
            bill.Tax_Total__c,
            snapshotTaxTotal,
            'Supplier Bill Tax Total does not match materialized Document Tax Lines.'
        );

        return result;
    }

    public static JournalTaxBundle buildInvoiceJournalTaxLines(
        Id invoiceId,
        Id journalEntryId,
        Decimal firstLineNumber,
        String transactionCurrency,
        String functionalCurrency,
        Decimal exchangeRate,
        Date rateDate
    ) {
        return buildJournalTaxLines(
            getInvoiceInstructions(
                invoiceId
            ),
            journalEntryId,
            firstLineNumber,
            transactionCurrency,
            functionalCurrency,
            exchangeRate,
            rateDate,
            'Invoice Tax Snapshot'
        );
    }

    public static JournalTaxBundle buildSupplierBillJournalTaxLines(
        Id supplierBillId,
        Id journalEntryId,
        Decimal firstLineNumber,
        String transactionCurrency,
        String functionalCurrency,
        Decimal exchangeRate,
        Date rateDate
    ) {
        return buildJournalTaxLines(
            getSupplierBillInstructions(
                supplierBillId
            ),
            journalEntryId,
            firstLineNumber,
            transactionCurrency,
            functionalCurrency,
            exchangeRate,
            rateDate,
            'Supplier Bill Tax Snapshot'
        );
    }

    private static JournalTaxBundle buildJournalTaxLines(
        List<PostingInstruction> instructions,
        Id journalEntryId,
        Decimal firstLineNumber,
        String transactionCurrency,
        String functionalCurrency,
        Decimal exchangeRate,
        Date rateDate,
        String rateSource
    ) {
        if (journalEntryId == null) {
            throw new TaxPostingException(
                'Journal Entry Id is required.'
            );
        }

        Decimal nextLine =
            firstLineNumber == null
                ? Decimal.valueOf('1')
                : firstLineNumber;

        if (nextLine <= 0) {
            throw new TaxPostingException(
                'First tax journal Line Number must be greater than zero.'
            );
        }

        JournalTaxBundle bundle =
            new JournalTaxBundle();

        for (PostingInstruction instruction : instructions) {
            SABMoneyService.ConversionResult conversion =
                SABMoneyService.convertToFunctional(
                    instruction.transactionAmount,
                    transactionCurrency,
                    functionalCurrency,
                    exchangeRate,
                    RoundingMode.HALF_UP
                );

            bundle.lines.add(
                new Journal_Entry_Line__c(
                    Journal_Entry__c =
                        journalEntryId,
                    GL_Account__c =
                        instruction.taxAccountId,
                    Line_Number__c =
                        nextLine,
                    Debit_Base__c =
                        instruction.debit
                            ? conversion.functionalAmount
                            : ZERO,
                    Credit_Base__c =
                        instruction.debit
                            ? ZERO
                            : conversion.functionalAmount,
                    Explanation__c =
                        truncateText(
                            instruction.explanation,
                            Journal_Entry_Line__c.Explanation__c
                                .getDescribe()
                                .getLength()
                        ),
                    Transaction_Amount__c =
                        conversion.transactionAmount,
                    Transaction_Currency__c =
                        conversion.transactionCurrency,
                    Functional_Currency__c =
                        conversion.functionalCurrency,
                    Applied_Exchange_Rate__c =
                        conversion.appliedExchangeRate,
                    Rate_Date__c =
                        rateDate,
                    Rate_Source__c =
                        rateSource,
                    Source_Line_Key__c =
                        instruction.sourceLineKey
                )
            );

            bundle.functionalMagnitude +=
                conversion.functionalAmount;

            nextLine++;
        }

        bundle.functionalMagnitude =
            normalizeAmount(
                bundle.functionalMagnitude
            );

        bundle.nextLineNumber =
            nextLine;

        return bundle;
    }

    private static void validateSnapshot(
        Document_Tax_Line__c row,
        Id companyId
    ) {
        if (row.Company__c != companyId) {
            throw new TaxPostingException(
                'Document Tax Line must belong to the same Accounting Company as the source document.'
            );
        }

        if (row.Tax_Account__c == null) {
            throw new TaxPostingException(
                'Document Tax Line requires a Tax Account.'
            );
        }

        if (
            row.Tax_Account__r == null
            || row.Tax_Account__r.Company__c
                != companyId
            || row.Tax_Account__r.Is_Active__c
                != true
            || row.Tax_Account__r.Is_Control_Account__c
                != true
            || row.Tax_Account__r.Control_Type__c
                != 'Tax'
        ) {
            throw new TaxPostingException(
                'Document Tax Line Tax Account must be an active Tax control account in the source Accounting Company.'
            );
        }

        if (String.isBlank(row.Tax_Code_Key__c)) {
            throw new TaxPostingException(
                'Document Tax Line requires a Tax Code snapshot key.'
            );
        }

        if (String.isBlank(row.Jurisdiction__c)) {
            throw new TaxPostingException(
                'Document Tax Line requires a Jurisdiction snapshot.'
            );
        }

        if (String.isBlank(row.Calculation_Version__c)) {
            throw new TaxPostingException(
                'Document Tax Line requires a Calculation Version snapshot.'
            );
        }

        if (
            row.Tax_Amount__c == null
            || row.Tax_Amount__c < ZERO
        ) {
            throw new TaxPostingException(
                'Document Tax Line Tax Amount must be zero or positive.'
            );
        }

        if (
            row.Recoverable_Amount__c != null
            && (
                row.Recoverable_Amount__c < ZERO
                || row.Recoverable_Amount__c
                    > row.Tax_Amount__c
            )
        ) {
            throw new TaxPostingException(
                'Document Tax Line Recoverable Amount must be between zero and Tax Amount.'
            );
        }
    }

    private static void assertTotalsEqual(
        Decimal documentTaxTotal,
        Decimal snapshotTaxTotal,
        String message
    ) {
        Decimal expected =
            normalizeAmount(
                documentTaxTotal
            );

        Decimal actual =
            normalizeAmount(
                snapshotTaxTotal
            );

        if (expected != actual) {
            throw new TaxPostingException(
                message
            );
        }
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
