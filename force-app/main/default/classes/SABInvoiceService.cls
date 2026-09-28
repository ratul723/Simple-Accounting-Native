public with sharing class SABInvoiceService {
    public static Invoice__c submit(Id invoiceId) {
        Invoice__c invoice = loadInvoice(invoiceId);
        List<Invoice_Line__c> lines = loadLines(invoiceId);
        SABInvoiceValidationService.validateForSubmit(invoice, lines);
        invoice.Status__c = 'Submitted';
        update invoice;
        return invoice;
    }

    public static Invoice__c approve(Id invoiceId) {
        Invoice__c invoice = loadInvoice(invoiceId);
        List<Invoice_Line__c> lines = loadLines(invoiceId);
        SABInvoiceValidationService.validateForApproval(invoice, lines);
        invoice.Status__c = 'Approved';
        update invoice;
        return invoice;
    }

    public static Invoice__c issue(Id invoiceId) {
        Invoice__c invoice = loadInvoice(invoiceId);
        List<Invoice_Line__c> lines = loadLines(invoiceId);
        SABInvoiceValidationService.validateForPosting(invoice, lines);
        if (invoice.Status__c != 'Approved') {
            throw new SABInvoiceValidationService.ValidationException(
                'Only Approved invoices can be issued.'
            );
        }
        invoice.Status__c = 'Issued';
        update invoice;
        return invoice;
    }

    public static Invoice__c cancel(Id invoiceId) {
        Invoice__c invoice = loadInvoice(invoiceId);
        if (invoice.Status__c == 'Posted') {
            throw new SABInvoiceValidationService.ValidationException(
                'Posted invoices cannot be cancelled. Use a credit/reversal process.'
            );
        }
        if (invoice.Status__c == 'Cancelled') {
            return invoice;
        }
        invoice.Status__c = 'Cancelled';
        update invoice;
        return invoice;
    }

    public static Invoice__c loadInvoice(Id invoiceId) {
        if (invoiceId == null) {
            throw new SABInvoiceValidationService.ValidationException('Invoice Id is required.');
        }
        List<Invoice__c> rows = [
            SELECT Id, Company__c, Party_Profile__c, Document_Date__c, Accounting_Date__c,
                   Due_Date__c, Document_Type__c, Status__c, Transaction_Currency__c,
                   Functional_Currency__c, Exchange_Rate__c, Exchange_Rate_Date__c,
                   Original_Invoice__c, Subtotal__c, Tax_Total__c, Total__c,
                   Legal_Number__c, Accounting_Event__c
            FROM Invoice__c
            WHERE Id = :invoiceId
            LIMIT 1
            FOR UPDATE
        ];
        if (rows.isEmpty()) {
            throw new SABInvoiceValidationService.ValidationException('Invoice not found.');
        }
        return rows[0];
    }

    private static List<Invoice_Line__c> loadLines(Id invoiceId) {
        return [
            SELECT Id, Invoice__c, Line_Number__c, Description__c, Quantity__c,
                   Unit_Price__c, Discount_Amount__c, Net_Amount__c, Revenue_Account__c,
                   Tax_Code__c, Department__c, Cost_Center__c, Project__c,
                   Tax_Treatment_Snapshot__c
            FROM Invoice_Line__c
            WHERE Invoice__c = :invoiceId
            ORDER BY Line_Number__c ASC, CreatedDate ASC
        ];
    }
}
