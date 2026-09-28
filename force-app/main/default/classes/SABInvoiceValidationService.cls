public with sharing class SABInvoiceValidationService {
    public class ValidationException extends Exception {}

    public static void validateForSubmit(Invoice__c invoice, List<Invoice_Line__c> lines) {
        validateHeader(invoice);
        validateLines(invoice, lines);
        if (invoice.Status__c != 'Draft') {
            throw new ValidationException('Only Draft invoices can be submitted.');
        }
    }

    public static void validateForApproval(Invoice__c invoice, List<Invoice_Line__c> lines) {
        validateHeader(invoice);
        validateLines(invoice, lines);
        if (invoice.Status__c != 'Submitted') {
            throw new ValidationException('Only Submitted invoices can be approved.');
        }
    }

    public static void validateForPosting(Invoice__c invoice, List<Invoice_Line__c> lines) {
        validateHeader(invoice);
        validateLines(invoice, lines);
        if (invoice.Status__c != 'Approved' && invoice.Status__c != 'Issued') {
            throw new ValidationException('Only Approved or Issued invoices can be posted.');
        }
    }

    public static void validateHeader(Invoice__c invoice) {
        if (invoice == null) throw new ValidationException('Invoice is required.');
        if (invoice.Company__c == null) throw new ValidationException('Company is required.');
        if (invoice.Party_Profile__c == null) throw new ValidationException('Party profile is required.');
        if (String.isBlank(invoice.Document_Type__c)) throw new ValidationException('Document type is required.');
        if (invoice.Document_Type__c != 'Invoice' && invoice.Document_Type__c != 'Credit Note') {
            throw new ValidationException('Document type must be Invoice or Credit Note.');
        }
        if (invoice.Document_Date__c == null) throw new ValidationException('Document date is required.');
        if (invoice.Accounting_Date__c == null) throw new ValidationException('Accounting date is required.');
        if (invoice.Due_Date__c == null) throw new ValidationException('Due date is required.');
        if (invoice.Due_Date__c < invoice.Document_Date__c) {
            throw new ValidationException('Due date cannot be before document date.');
        }
        if (String.isBlank(invoice.Transaction_Currency__c)) {
            throw new ValidationException('Transaction currency is required.');
        }
        if (String.isBlank(invoice.Functional_Currency__c)) {
            throw new ValidationException('Functional currency is required.');
        }
        if (invoice.Document_Type__c == 'Credit Note' && invoice.Original_Invoice__c == null) {
            throw new ValidationException('Credit Note must reference the original invoice.');
        }
        if (invoice.Original_Invoice__c != null && invoice.Id != null &&
            invoice.Original_Invoice__c == invoice.Id) {
            throw new ValidationException('Invoice cannot reference itself as the original invoice.');
        }
    }

    public static void validateLines(Invoice__c invoice, List<Invoice_Line__c> lines) {
        if (lines == null || lines.isEmpty()) {
            throw new ValidationException('Invoice must contain at least one invoice line.');
        }
        Integer expectedNumber = 1;
        for (Invoice_Line__c line : lines) {
            if (line == null) throw new ValidationException('Invoice contains an invalid line.');
            if (invoice.Id != null && line.Invoice__c != null && line.Invoice__c != invoice.Id) {
                throw new ValidationException('Invoice line belongs to a different invoice.');
            }
            if (line.Quantity__c == null || line.Quantity__c <= 0) {
                throw new ValidationException('Invoice line quantity must be greater than zero.');
            }
            if (line.Unit_Price__c == null || line.Unit_Price__c < 0) {
                throw new ValidationException('Invoice line unit price cannot be negative.');
            }
            if (line.Discount_Amount__c != null && line.Discount_Amount__c < 0) {
                throw new ValidationException('Invoice line discount cannot be negative.');
            }
            if (line.Revenue_Account__c == null) {
                throw new ValidationException('Revenue account is required on every invoice line.');
            }
            if (line.Line_Number__c != null && line.Line_Number__c != expectedNumber) {
                throw new ValidationException('Invoice line numbers must be sequential starting at 1.');
            }
            expectedNumber++;
        }
    }
}
