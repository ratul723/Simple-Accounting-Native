/**
 * G6B - Document Tax Materialization.
 *
 * This service turns the G6A tax calculation result into an immutable-style
 * document snapshot in Document_Tax_Line__c while the source document is Draft.
 *
 * Design:
 * - Invoice Tax Code -> Output_Tax_Account__c
 * - Supplier Bill Tax Code -> Input_Tax_Account__c
 * - Materialization is repeatable while Draft: prior snapshots are deleted
 *   and rebuilt from the current Draft lines/configuration.
 * - Once the document leaves Draft, this service refuses to rematerialize it.
 * - The selected Tax Rate, Tax Code key, jurisdiction, taxable base and
 *   recoverable amount are stored so later posting/reporting does not silently
 *   change when current tax configuration changes.
 *
 * This is an internal accounting service, not a direct Aura/LWC entry point.
 * User-facing document services remain responsible for CRUD/FLS/action checks.
 */
public without sharing class SABDocumentTaxService {

    public class DocumentTaxException extends Exception {}

    private static final String STATUS_DRAFT = 'Draft';
    private static final String CALCULATION_VERSION = 'G6B-DOC-TAX-1';
    private static final Decimal ZERO = Decimal.valueOf('0');

    public class MaterializationResult {
        public Id documentId { get; private set; }
        public String documentType { get; private set; }
        public Integer lineCount { get; private set; }
        public Integer taxLineCount { get; private set; }
        public Decimal subtotal { get; private set; }
        public Decimal taxTotal { get; private set; }
        public Decimal total { get; private set; }

        private MaterializationResult() {
            lineCount = 0;
            taxLineCount = 0;
            subtotal = ZERO;
            taxTotal = ZERO;
            total = ZERO;
        }
    }

    public static MaterializationResult materializeInvoiceTaxes(
        Id invoiceId
    ) {
        if (invoiceId == null) {
            throw new DocumentTaxException(
                'Invoice Id is required.'
            );
        }

        Invoice__c invoice = [
            SELECT Id,
                   Company__c,
                   Document_Date__c,
                   Document_Type__c,
                   Status__c,
                   Subtotal__c,
                   Tax_Total__c,
                   Total__c
            FROM Invoice__c
            WHERE Id = :invoiceId
            LIMIT 1
            FOR UPDATE
        ];

        SABCompanyAccessService.assertCompanyAccess(
            invoice.Company__c
        );

        if (invoice.Status__c != STATUS_DRAFT) {
            throw new DocumentTaxException(
                'Invoice tax can only be materialized while the Invoice is Draft.'
            );
        }

        if (invoice.Document_Date__c == null) {
            throw new DocumentTaxException(
                'Invoice Document Date is required for tax-rate selection.'
            );
        }

        List<Invoice_Line__c> lines = [
            SELECT Id,
                   Invoice__c,
                   Quantity__c,
                   Unit_Price__c,
                   Discount_Amount__c,
                   Net_Amount__c,
                   Tax_Code__c,
                   Tax_Code__r.Company__c,
                   Tax_Code__r.Is_Active__c,
                   Tax_Code__r.Inclusive__c,
                   Tax_Code__r.Output_Tax_Account__c,
                   Tax_Code__r.Output_Tax_Account__r.Company__c,
                   Tax_Code__r.Output_Tax_Account__r.Is_Active__c,
                   Tax_Code__r.Output_Tax_Account__r.Is_Control_Account__c,
                   Tax_Code__r.Output_Tax_Account__r.Control_Type__c,
                   Tax_Treatment_Snapshot__c
            FROM Invoice_Line__c
            WHERE Invoice__c = :invoice.Id
            ORDER BY Line_Number__c ASC, CreatedDate ASC
        ];

        if (lines.isEmpty()) {
            throw new DocumentTaxException(
                'Invoice must contain at least one Invoice Line before tax materialization.'
            );
        }

        deleteExistingInvoiceSnapshots(
            new Map<Id, Invoice_Line__c>(lines).keySet()
        );

        MaterializationResult result =
            new MaterializationResult();

        result.documentId = invoice.Id;
        result.documentType = 'Invoice';
        result.lineCount = lines.size();

        List<Document_Tax_Line__c> taxRows =
            new List<Document_Tax_Line__c>();

        List<Invoice_Line__c> lineUpdates =
            new List<Invoice_Line__c>();

        for (Invoice_Line__c line : lines) {
            Decimal quantity =
                line.Quantity__c == null
                    ? Decimal.valueOf('1')
                    : line.Quantity__c;

            Decimal unitPrice =
                line.Unit_Price__c == null
                    ? ZERO
                    : line.Unit_Price__c;

            Decimal discount =
                line.Discount_Amount__c == null
                    ? ZERO
                    : line.Discount_Amount__c;

            Decimal inputAmount =
                normalizeAmount(
                    (quantity * unitPrice)
                    - discount
                );

            if (inputAmount < ZERO) {
                throw new DocumentTaxException(
                    'Invoice line amount cannot be negative after discount.'
                );
            }

            Invoice_Line__c lineUpdate =
                new Invoice_Line__c(
                    Id = line.Id
                );

            if (line.Tax_Code__c == null) {
                lineUpdate.Net_Amount__c =
                    inputAmount;
                lineUpdate.Tax_Treatment_Snapshot__c =
                    null;

                result.subtotal += inputAmount;
                result.total += inputAmount;
                lineUpdates.add(lineUpdate);
                continue;
            }

            SABTaxService.TaxSnapshot snapshot =
                calculateTax(
                    invoice.Company__c,
                    line.Tax_Code__c,
                    invoice.Document_Date__c,
                    inputAmount,
                    SABTaxService.SIDE_SALES
                );

            Id taxAccountId =
                line.Tax_Code__r.Output_Tax_Account__c;

            validateTaxAccount(
                taxAccountId,
                line.Tax_Code__r.Output_Tax_Account__r,
                invoice.Company__c,
                'Output Tax Account'
            );

            taxRows.add(
                new Document_Tax_Line__c(
                    Invoice_Line__c =
                        line.Id,
                    Company__c =
                        invoice.Company__c,
                    Taxable_Base__c =
                        snapshot.taxableBase,
                    Tax_Amount__c =
                        snapshot.taxAmount,
                    Recoverable_Amount__c =
                        ZERO,
                    Tax_Account__c =
                        taxAccountId,
                    Tax_Rate__c =
                        snapshot.taxRatePercent,
                    Tax_Code_Key__c =
                        snapshot.taxCodeKey,
                    Jurisdiction__c =
                        snapshot.jurisdiction,
                    Calculation_Version__c =
                        CALCULATION_VERSION
                )
            );

            lineUpdate.Net_Amount__c =
                snapshot.taxableBase;
            lineUpdate.Tax_Treatment_Snapshot__c =
                buildTreatmentSnapshot(
                    snapshot
                );

            lineUpdates.add(
                lineUpdate
            );

            result.taxLineCount++;
            result.subtotal +=
                snapshot.taxableBase;
            result.taxTotal +=
                snapshot.taxAmount;
            result.total +=
                snapshot.grossAmount;
        }

        normalizeResult(result);

        update lineUpdates;

        if (!taxRows.isEmpty()) {
            insert taxRows;
        }

        invoice.Subtotal__c =
            result.subtotal;
        invoice.Tax_Total__c =
            result.taxTotal;
        invoice.Total__c =
            result.total;

        update invoice;

        return result;
    }

    public static MaterializationResult materializeSupplierBillTaxes(
        Id supplierBillId
    ) {
        if (supplierBillId == null) {
            throw new DocumentTaxException(
                'Supplier Bill Id is required.'
            );
        }

        Supplier_Bill__c bill = [
            SELECT Id,
                   Company__c,
                   Document_Date__c,
                   Document_Type__c,
                   Status__c,
                   Subtotal__c,
                   Tax_Total__c,
                   Total__c
            FROM Supplier_Bill__c
            WHERE Id = :supplierBillId
            LIMIT 1
            FOR UPDATE
        ];

        SABCompanyAccessService.assertCompanyAccess(
            bill.Company__c
        );

        if (bill.Status__c != STATUS_DRAFT) {
            throw new DocumentTaxException(
                'Supplier Bill tax can only be materialized while the Supplier Bill is Draft.'
            );
        }

        if (bill.Document_Date__c == null) {
            throw new DocumentTaxException(
                'Supplier Bill Document Date is required for tax-rate selection.'
            );
        }

        List<Bill_Line__c> lines = [
            SELECT Id,
                   Supplier_Bill__c,
                   Quantity__c,
                   Unit_Price__c,
                   Net_Amount__c,
                   Recoverable_Tax_Amount__c,
                   Nonrecoverable_Tax_Amount__c,
                   Tax_Code__c,
                   Tax_Code__r.Company__c,
                   Tax_Code__r.Is_Active__c,
                   Tax_Code__r.Inclusive__c,
                   Tax_Code__r.Input_Tax_Account__c,
                   Tax_Code__r.Input_Tax_Account__r.Company__c,
                   Tax_Code__r.Input_Tax_Account__r.Is_Active__c,
                   Tax_Code__r.Input_Tax_Account__r.Is_Control_Account__c,
                   Tax_Code__r.Input_Tax_Account__r.Control_Type__c
            FROM Bill_Line__c
            WHERE Supplier_Bill__c = :bill.Id
            ORDER BY Line_Number__c ASC, CreatedDate ASC
        ];

        if (lines.isEmpty()) {
            throw new DocumentTaxException(
                'Supplier Bill must contain at least one Bill Line before tax materialization.'
            );
        }

        deleteExistingBillSnapshots(
            new Map<Id, Bill_Line__c>(lines).keySet()
        );

        MaterializationResult result =
            new MaterializationResult();

        result.documentId = bill.Id;
        result.documentType = 'Supplier Bill';
        result.lineCount = lines.size();

        List<Document_Tax_Line__c> taxRows =
            new List<Document_Tax_Line__c>();

        List<Bill_Line__c> lineUpdates =
            new List<Bill_Line__c>();

        for (Bill_Line__c line : lines) {
            Decimal quantity =
                line.Quantity__c == null
                    ? Decimal.valueOf('1')
                    : line.Quantity__c;

            Decimal unitPrice =
                line.Unit_Price__c == null
                    ? ZERO
                    : line.Unit_Price__c;

            Decimal inputAmount =
                normalizeAmount(
                    quantity * unitPrice
                );

            Bill_Line__c lineUpdate =
                new Bill_Line__c(
                    Id = line.Id
                );

            if (line.Tax_Code__c == null) {
                lineUpdate.Net_Amount__c =
                    inputAmount;
                lineUpdate.Recoverable_Tax_Amount__c =
                    ZERO;
                lineUpdate.Nonrecoverable_Tax_Amount__c =
                    ZERO;

                result.subtotal +=
                    inputAmount;
                result.total +=
                    inputAmount;
                lineUpdates.add(
                    lineUpdate
                );
                continue;
            }

            SABTaxService.TaxSnapshot snapshot =
                calculateTax(
                    bill.Company__c,
                    line.Tax_Code__c,
                    bill.Document_Date__c,
                    inputAmount,
                    SABTaxService.SIDE_PURCHASE
                );

            Id taxAccountId =
                line.Tax_Code__r.Input_Tax_Account__c;

            validateTaxAccount(
                taxAccountId,
                line.Tax_Code__r.Input_Tax_Account__r,
                bill.Company__c,
                'Input Tax Account'
            );

            taxRows.add(
                new Document_Tax_Line__c(
                    Bill_Line__c =
                        line.Id,
                    Company__c =
                        bill.Company__c,
                    Taxable_Base__c =
                        snapshot.taxableBase,
                    Tax_Amount__c =
                        snapshot.taxAmount,
                    Recoverable_Amount__c =
                        snapshot.recoverableAmount,
                    Tax_Account__c =
                        taxAccountId,
                    Tax_Rate__c =
                        snapshot.taxRatePercent,
                    Tax_Code_Key__c =
                        snapshot.taxCodeKey,
                    Jurisdiction__c =
                        snapshot.jurisdiction,
                    Calculation_Version__c =
                        CALCULATION_VERSION
                )
            );

            lineUpdate.Net_Amount__c =
                snapshot.taxableBase;
            lineUpdate.Recoverable_Tax_Amount__c =
                snapshot.recoverableAmount;
            lineUpdate.Nonrecoverable_Tax_Amount__c =
                snapshot.nonrecoverableAmount;

            lineUpdates.add(
                lineUpdate
            );

            result.taxLineCount++;
            result.subtotal +=
                snapshot.taxableBase;
            result.taxTotal +=
                snapshot.taxAmount;
            result.total +=
                snapshot.grossAmount;
        }

        normalizeResult(result);

        update lineUpdates;

        if (!taxRows.isEmpty()) {
            insert taxRows;
        }

        bill.Subtotal__c =
            result.subtotal;
        bill.Tax_Total__c =
            result.taxTotal;
        bill.Total__c =
            result.total;

        update bill;

        return result;
    }

    private static SABTaxService.TaxSnapshot calculateTax(
        Id companyId,
        Id taxCodeId,
        Date taxDate,
        Decimal lineAmount,
        String documentSide
    ) {
        SABTaxService.TaxRequest request =
            new SABTaxService.TaxRequest();

        request.companyId =
            companyId;
        request.taxCodeId =
            taxCodeId;
        request.taxDate =
            taxDate;
        request.lineAmount =
            lineAmount;
        request.documentSide =
            documentSide;
        request.roundingMode =
            RoundingMode.HALF_UP;

        return SABTaxService.calculate(
            request
        );
    }

    private static void validateTaxAccount(
        Id taxAccountId,
        GL_Account__c taxAccount,
        Id companyId,
        String accountLabel
    ) {
        if (
            taxAccountId == null
            || taxAccount == null
        ) {
            throw new DocumentTaxException(
                accountLabel
                + ' is required on the Tax Code before document tax can be materialized.'
            );
        }

        if (taxAccount.Company__c != companyId) {
            throw new DocumentTaxException(
                accountLabel
                + ' must belong to the same Accounting Company as the document.'
            );
        }

        if (taxAccount.Is_Active__c != true) {
            throw new DocumentTaxException(
                accountLabel
                + ' must be active.'
            );
        }

        if (
            taxAccount.Is_Control_Account__c != true
            || taxAccount.Control_Type__c != 'Tax'
        ) {
            throw new DocumentTaxException(
                accountLabel
                + ' must be configured as a Tax control account.'
            );
        }
    }

    private static String buildTreatmentSnapshot(
        SABTaxService.TaxSnapshot snapshot
    ) {
        Map<String, Object> payload =
            new Map<String, Object>{
                'calculationVersion' =>
                    CALCULATION_VERSION,
                'taxCodeKey' =>
                    snapshot.taxCodeKey,
                'taxRatePercent' =>
                    snapshot.taxRatePercent,
                'jurisdiction' =>
                    snapshot.jurisdiction,
                'treatment' =>
                    snapshot.treatment,
                'inclusive' =>
                    snapshot.inclusive,
                'recoverability' =>
                    snapshot.recoverability,
                'countryPackVersion' =>
                    snapshot.countryPackVersion,
                'rateKey' =>
                    snapshot.rateKey,
                'taxableBase' =>
                    snapshot.taxableBase,
                'taxAmount' =>
                    snapshot.taxAmount
            };

        return JSON.serialize(
            payload
        );
    }

    private static void deleteExistingInvoiceSnapshots(
        Set<Id> invoiceLineIds
    ) {
        if (
            invoiceLineIds == null
            || invoiceLineIds.isEmpty()
        ) {
            return;
        }

        List<Document_Tax_Line__c> existing = [
            SELECT Id
            FROM Document_Tax_Line__c
            WHERE Invoice_Line__c IN :invoiceLineIds
        ];

        if (!existing.isEmpty()) {
            delete existing;
        }
    }

    private static void deleteExistingBillSnapshots(
        Set<Id> billLineIds
    ) {
        if (
            billLineIds == null
            || billLineIds.isEmpty()
        ) {
            return;
        }

        List<Document_Tax_Line__c> existing = [
            SELECT Id
            FROM Document_Tax_Line__c
            WHERE Bill_Line__c IN :billLineIds
        ];

        if (!existing.isEmpty()) {
            delete existing;
        }
    }

    private static void normalizeResult(
        MaterializationResult result
    ) {
        result.subtotal =
            normalizeAmount(
                result.subtotal
            );

        result.taxTotal =
            normalizeAmount(
                result.taxTotal
            );

        result.total =
            normalizeAmount(
                result.total
            );
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
}
