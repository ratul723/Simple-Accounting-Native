public with sharing class SABInvoiceCalculationService {
    public class CalculationResult {
        public Decimal subtotal;
        public Decimal taxTotal;
        public Decimal total;

        public CalculationResult(Decimal subtotal, Decimal taxTotal, Decimal total) {
            this.subtotal = subtotal == null ? 0 : subtotal;
            this.taxTotal = taxTotal == null ? 0 : taxTotal;
            this.total = total == null ? 0 : total;
        }
    }

    public static CalculationResult calculate(
        Invoice__c invoice,
        List<Invoice_Line__c> lines,
        List<Document_Tax_Line__c> taxLines
    ) {
        Decimal subtotal = 0;
        for (Invoice_Line__c line : lines) {
            Decimal quantity = line.Quantity__c == null ? 0 : line.Quantity__c;
            Decimal unitPrice = line.Unit_Price__c == null ? 0 : line.Unit_Price__c;
            Decimal discount = line.Discount_Amount__c == null ? 0 : line.Discount_Amount__c;
            Decimal net = (quantity * unitPrice) - discount;
            if (net < 0) {
                throw new SABInvoiceValidationService.ValidationException(
                    'Invoice line net amount cannot be negative.'
                );
            }
            subtotal += net;
        }

        Decimal taxTotal = 0;
        if (taxLines != null) {
            for (Document_Tax_Line__c taxLine : taxLines) {
                if (taxLine == null) continue;
                taxTotal += taxLine.Tax_Amount__c == null ? 0 : taxLine.Tax_Amount__c;
            }
        }

        return new CalculationResult(subtotal, taxTotal, subtotal + taxTotal);
    }

    public static void applyCalculatedTotals(
        Invoice__c invoice,
        List<Invoice_Line__c> lines,
        List<Document_Tax_Line__c> taxLines
    ) {
        CalculationResult result = calculate(invoice, lines, taxLines);
        invoice.Subtotal__c = result.subtotal;
        invoice.Tax_Total__c = result.taxTotal;
        invoice.Total__c = result.total;
    }
}
