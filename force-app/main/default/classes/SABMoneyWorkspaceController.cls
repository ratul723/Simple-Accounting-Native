/**
 * G22G-3: read model for the redesigned Sales & receivables, Purchases & payables and Payments workspaces.
 *
 * Read only. Balances come from the services that own them: invoice outstanding from SABARAgingService, bill
 * outstanding from SABAccountsPayableWorkspaceController, payment allocations from Payment_Allocation__c rows in
 * Allocated status. Actions in the workspaces call the existing services directly and unchanged (invoice and bill
 * posting, bill submit/approve/return/cancel, receipt and supplier payment authorise/submit/fail/retry/post, receipt
 * allocation).
 *
 * Every read runs in user mode after the company grant check. A section the user cannot read is returned empty with
 * its available flag false.
 */
public with sharing class SABMoneyWorkspaceController {

    private static final Integer MAX_ROWS = 200;
    private static final String ALLOCATED = 'Allocated';

    public class SalesData {
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Boolean canPost { get; set; }
        @AuraEnabled public Boolean canApprove { get; set; }
        @AuraEnabled public Boolean agingAvailable { get; set; }
        @AuraEnabled public Decimal totalOutstanding { get; set; }
        @AuraEnabled public Decimal overdueAmount { get; set; }
        @AuraEnabled public Integer overdueCount { get; set; }
        @AuraEnabled public Integer openCount { get; set; }
        @AuraEnabled public Decimal collectedThisMonth { get; set; }
        @AuraEnabled public List<Decimal> buckets { get; set; }
        @AuraEnabled public List<DocumentRow> invoices { get; set; }
        @AuraEnabled public List<DocumentRow> credits { get; set; }
        @AuraEnabled public List<PartyRow> customers { get; set; }
    }

    public class DocumentRow {
        @AuraEnabled public Id documentId { get; set; }
        @AuraEnabled public String documentNumber { get; set; }
        @AuraEnabled public String documentType { get; set; }
        @AuraEnabled public Id partyProfileId { get; set; }
        @AuraEnabled public String partyName { get; set; }
        @AuraEnabled public Date documentDate { get; set; }
        @AuraEnabled public Date dueDate { get; set; }
        @AuraEnabled public Decimal total { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Decimal outstanding { get; set; }
        @AuraEnabled public Integer daysPastDue { get; set; }
        @AuraEnabled public String originalNumber { get; set; }
    }

    public class PartyRow {
        @AuraEnabled public Id partyProfileId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String taxRegistration { get; set; }
        @AuraEnabled public String paymentTerm { get; set; }
        @AuraEnabled public String paymentMethod { get; set; }
        @AuraEnabled public Decimal creditLimit { get; set; }
        @AuraEnabled public Decimal outstanding { get; set; }
        @AuraEnabled public Integer openDocuments { get; set; }
    }

    public class PaymentsData {
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Boolean canApprove { get; set; }
        @AuraEnabled public Boolean canPost { get; set; }
        @AuraEnabled public Boolean canEdit { get; set; }
        @AuraEnabled public Decimal receivedThisMonth { get; set; }
        @AuraEnabled public Decimal paidThisMonth { get; set; }
        @AuraEnabled public Decimal unallocatedReceipts { get; set; }
        @AuraEnabled public Integer unallocatedReceiptCount { get; set; }
        @AuraEnabled public Decimal awaitingRelease { get; set; }
        @AuraEnabled public Integer awaitingReleaseCount { get; set; }
        @AuraEnabled public List<PaymentRow> payments { get; set; }
        @AuraEnabled public List<DocumentRow> openInvoices { get; set; }
        /** Posted supplier bills with an amount still to pay, for allocating cleared supplier payments. */
        @AuraEnabled public List<DocumentRow> openBills { get; set; }
        @AuraEnabled public Boolean canAllocate { get; set; }
    }

    public class PaymentRow {
        @AuraEnabled public Id paymentId { get; set; }
        @AuraEnabled public String paymentNumber { get; set; }
        @AuraEnabled public String direction { get; set; }
        @AuraEnabled public Id partyProfileId { get; set; }
        @AuraEnabled public String partyName { get; set; }
        @AuraEnabled public Date effectiveDate { get; set; }
        @AuraEnabled public String bankName { get; set; }
        @AuraEnabled public String method { get; set; }
        @AuraEnabled public String reference { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public String state { get; set; }
        @AuraEnabled public Decimal allocated { get; set; }
        @AuraEnabled public String managedBy { get; set; }
        @AuraEnabled public List<AllocationRow> allocations { get; set; }
    }

    public class AllocationRow {
        @AuraEnabled public Id allocationId { get; set; }
        @AuraEnabled public String documentNumber { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public Date allocationDate { get; set; }
    }

    public class LineRow {
        @AuraEnabled public Integer lineNumber { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
        @AuraEnabled public Decimal unitPrice { get; set; }
        @AuraEnabled public Decimal netAmount { get; set; }
        @AuraEnabled public String accountCode { get; set; }
        @AuraEnabled public String accountName { get; set; }
        @AuraEnabled public String taxCode { get; set; }
    }

    public class DocumentDetail {
        @AuraEnabled public Decimal subtotal { get; set; }
        @AuraEnabled public Decimal taxTotal { get; set; }
        @AuraEnabled public Decimal total { get; set; }
        @AuraEnabled public List<LineRow> lines { get; set; }
        @AuraEnabled public List<AllocationRow> allocations { get; set; }
    }

    // ------------------------------------------------------------------ sales

    @AuraEnabled
    public static SalesData getSales(Id companyId) {
        assertCompany(companyId);
        try {
            SalesData data = new SalesData();
            data.currencyCode = currencyOf(companyId);
            data.canPost = SABPermissionService.hasPermission('SAB_Post_Journal');
            data.canApprove = SABPermissionService.hasPermission('SAB_Approve_Financial_Document');
            data.totalOutstanding = 0;
            data.overdueAmount = 0;
            data.overdueCount = 0;
            data.openCount = 0;
            data.buckets = new List<Decimal>{ 0, 0, 0, 0, 0 };
            Map<Id, SABARAgingService.ARAgingRow> aging = loadAging(companyId, data);
            data.invoices = new List<DocumentRow>();
            data.credits = new List<DocumentRow>();
            for (Invoice__c invoice : [
                SELECT Id, Name, Legal_Number__c, Document_Type__c, Party_Profile__c, Party_Profile__r.Account__r.Name, Document_Date__c,
                       Due_Date__c, Total__c, Transaction_Currency__c, Status__c, Original_Invoice__r.Legal_Number__c, Original_Invoice__r.Name
                FROM Invoice__c
                WHERE Company__c = :companyId
                WITH USER_MODE
                ORDER BY Document_Date__c DESC, Name DESC
                LIMIT :MAX_ROWS
            ]) {
                DocumentRow row = invoiceRow(invoice, aging.get(invoice.Id));
                if (invoice.Document_Type__c == 'Credit Note') {
                    data.credits.add(row);
                } else {
                    data.invoices.add(row);
                }
            }
            data.customers = parties(companyId, true, aging.values());
            data.collectedThisMonth = settledThisMonth(companyId, 'Receipt');
            return data;
        } catch (QueryException ex) {
            throw auraError('Sales could not be loaded: ' + ex.getMessage());
        }
    }

    private static Map<Id, SABARAgingService.ARAgingRow> loadAging(Id companyId, SalesData data) {
        Map<Id, SABARAgingService.ARAgingRow> rows = new Map<Id, SABARAgingService.ARAgingRow>();
        data.agingAvailable = false;
        try {
            SABARAgingService.ARAgingRequest request = new SABARAgingService.ARAgingRequest();
            request.companyId = companyId;
            request.asOfDate = Date.today();
            request.includeSettled = true;
            SABARAgingService.ARAgingResult result = SABARAgingService.getAging(request);
            data.agingAvailable = true;
            data.totalOutstanding = zero(result.totalOutstanding);
            data.openCount = result.openInvoiceCount == null ? 0 : result.openInvoiceCount;
            data.buckets = new List<Decimal>{ zero(result.currentAmount), zero(result.days1To30Amount), zero(result.days31To60Amount),
                zero(result.days61To90Amount), zero(result.days91PlusAmount) };
            for (SABARAgingService.ARAgingRow row : result.rows == null ? new List<SABARAgingService.ARAgingRow>() : result.rows) {
                rows.put(row.invoiceId, row);
                if (row.daysPastDue != null && row.daysPastDue > 0 && zero(row.outstandingBaseAmount) > 0) {
                    data.overdueCount++;
                    data.overdueAmount += row.outstandingBaseAmount;
                }
            }
        } catch (Exception ex) {
            data.agingAvailable = false;
        }
        return rows;
    }

    private static DocumentRow invoiceRow(Invoice__c invoice, SABARAgingService.ARAgingRow aging) {
        DocumentRow row = new DocumentRow();
        row.documentId = invoice.Id;
        row.documentNumber = String.isBlank(invoice.Legal_Number__c) ? invoice.Name : invoice.Legal_Number__c;
        row.documentType = invoice.Document_Type__c;
        row.partyProfileId = invoice.Party_Profile__c;
        row.partyName = invoice.Party_Profile__r == null || invoice.Party_Profile__r.Account__r == null ? null : invoice.Party_Profile__r.Account__r.Name;
        row.documentDate = invoice.Document_Date__c;
        row.dueDate = invoice.Due_Date__c;
        row.total = zero(invoice.Total__c);
        row.currencyCode = invoice.Transaction_Currency__c;
        row.status = invoice.Status__c;
        if (aging != null) {
            row.outstanding = zero(aging.outstandingDocumentAmount);
            row.daysPastDue = aging.daysPastDue;
        }
        if (invoice.Original_Invoice__r != null) {
            row.originalNumber = String.isBlank(invoice.Original_Invoice__r.Legal_Number__c)
                ? invoice.Original_Invoice__r.Name : invoice.Original_Invoice__r.Legal_Number__c;
        }
        return row;
    }

    // -------------------------------------------------------------- suppliers

    public class PurchaseExtras {
        @AuraEnabled public Boolean canApprove { get; set; }
        @AuraEnabled public Boolean canPost { get; set; }
        @AuraEnabled public Boolean canEdit { get; set; }
        @AuraEnabled public List<PartyRow> suppliers { get; set; }
    }

    /** Supplier profiles and the user's bill permissions; bills and their balances come from the AP workspace controller. */
    @AuraEnabled
    public static PurchaseExtras getPurchaseExtras(Id companyId) {
        assertCompany(companyId);
        try {
            PurchaseExtras extras = new PurchaseExtras();
            extras.canApprove = SABPermissionService.hasPermission('SAB_Approve_Financial_Document');
            extras.canPost = SABPermissionService.hasPermission('SAB_Post_Journal');
            extras.canEdit = Schema.SObjectType.Supplier_Bill__c.isUpdateable();
            extras.suppliers = parties(companyId, false, null);
            return extras;
        } catch (QueryException ex) {
            throw auraError('Suppliers could not be loaded: ' + ex.getMessage());
        }
    }

    private static List<PartyRow> parties(Id companyId, Boolean customers, List<SABARAgingService.ARAgingRow> agingRows) {
        List<PartyRow> rows = new List<PartyRow>();
        if (!Schema.SObjectType.Party_Accounting_Profile__c.isAccessible()) {
            return rows;
        }
        Map<Id, PartyRow> byId = new Map<Id, PartyRow>();
        for (Party_Accounting_Profile__c profile : [
            SELECT Id, Account__r.Name, Tax_Registration_Number__c, Payment_Term__r.Name, Preferred_Payment_Method__c, Credit_Limit__c,
                   Is_Customer__c, Is_Supplier__c
            FROM Party_Accounting_Profile__c
            WHERE Company__c = :companyId AND Is_Active__c = true
            WITH USER_MODE
            ORDER BY Account__r.Name
            LIMIT :MAX_ROWS
        ]) {
            if ((customers && profile.Is_Customer__c != true) || (!customers && profile.Is_Supplier__c != true)) {
                continue;
            }
            PartyRow row = new PartyRow();
            row.partyProfileId = profile.Id;
            row.name = profile.Account__r == null ? null : profile.Account__r.Name;
            row.taxRegistration = profile.Tax_Registration_Number__c;
            row.paymentTerm = profile.Payment_Term__r == null ? null : profile.Payment_Term__r.Name;
            row.paymentMethod = profile.Preferred_Payment_Method__c;
            row.creditLimit = profile.Credit_Limit__c;
            row.outstanding = 0;
            row.openDocuments = 0;
            byId.put(profile.Id, row);
            rows.add(row);
        }
        for (SABARAgingService.ARAgingRow aging : agingRows == null ? new List<SABARAgingService.ARAgingRow>() : agingRows) {
            PartyRow row = byId.get(aging.partyProfileId);
            if (row != null && zero(aging.outstandingBaseAmount) > 0) {
                row.outstanding += aging.outstandingBaseAmount;
                row.openDocuments++;
            }
        }
        return rows;
    }

    // --------------------------------------------------------------- payments

    @AuraEnabled
    public static PaymentsData getPayments(Id companyId) {
        assertCompany(companyId);
        try {
            PaymentsData data = new PaymentsData();
            data.currencyCode = currencyOf(companyId);
            data.canApprove = SABPermissionService.hasPermission('SAB_Approve_Financial_Document');
            data.canPost = SABPermissionService.hasPermission('SAB_Post_Journal');
            data.canEdit = Schema.SObjectType.Accounting_Payment__c.isUpdateable();
            data.payments = payments(companyId);
            data.receivedThisMonth = 0;
            data.paidThisMonth = 0;
            data.unallocatedReceipts = 0;
            data.unallocatedReceiptCount = 0;
            data.awaitingRelease = 0;
            data.awaitingReleaseCount = 0;
            Date monthStart = Date.today().toStartOfMonth();
            for (PaymentRow row : data.payments) {
                Boolean thisMonth = row.effectiveDate != null && row.effectiveDate >= monthStart;
                if (row.direction == 'Receipt' && row.state == 'Succeeded') {
                    data.receivedThisMonth += thisMonth ? row.amount : 0;
                    if (row.managedBy == null && row.amount - row.allocated > 0) {
                        data.unallocatedReceipts += row.amount - row.allocated;
                        data.unallocatedReceiptCount++;
                    }
                }
                if (row.direction == 'Disbursement' && thisMonth && (row.state == 'Succeeded' || row.state == 'Submitted')) {
                    data.paidThisMonth += row.amount;
                }
                if (row.state == 'Authorized') {
                    data.awaitingRelease += row.amount;
                    data.awaitingReleaseCount++;
                }
            }
            data.openInvoices = openInvoices(companyId);
            data.openBills = openBills(companyId);
            data.canAllocate = Schema.SObjectType.Payment_Allocation__c.isCreateable();
            return data;
        } catch (QueryException ex) {
            throw auraError('Payments could not be loaded: ' + ex.getMessage());
        }
    }

    private static List<PaymentRow> payments(Id companyId) {
        Map<Id, PaymentRow> byId = new Map<Id, PaymentRow>();
        List<PaymentRow> rows = new List<PaymentRow>();
        for (Accounting_Payment__c payment : [
            SELECT Id, Name, Direction__c, Party_Profile__c, Party_Profile__r.Account__r.Name, Effective_Date__c, Bank_Account__r.Name,
                   Method__c, Reference__c, Amount__c, Transaction_Currency__c, Processing_State__c, Payroll_Run__c, Distribution__c
            FROM Accounting_Payment__c
            WHERE Company__c = :companyId
            WITH USER_MODE
            ORDER BY Effective_Date__c DESC, Name DESC
            LIMIT :MAX_ROWS
        ]) {
            PaymentRow row = new PaymentRow();
            row.paymentId = payment.Id;
            row.paymentNumber = payment.Name;
            row.direction = payment.Direction__c;
            row.partyProfileId = payment.Party_Profile__c;
            row.partyName = payment.Party_Profile__r == null || payment.Party_Profile__r.Account__r == null ? null : payment.Party_Profile__r.Account__r.Name;
            row.effectiveDate = payment.Effective_Date__c;
            row.bankName = payment.Bank_Account__r == null ? null : payment.Bank_Account__r.Name;
            row.method = payment.Method__c;
            row.reference = payment.Reference__c;
            row.amount = zero(payment.Amount__c);
            row.currencyCode = payment.Transaction_Currency__c;
            row.state = payment.Processing_State__c;
            row.allocated = 0;
            row.managedBy = payment.Payroll_Run__c != null ? 'Payroll' : payment.Distribution__c != null ? 'Equity' : null;
            row.allocations = new List<AllocationRow>();
            byId.put(payment.Id, row);
            rows.add(row);
        }
        if (byId.isEmpty() || !Schema.SObjectType.Payment_Allocation__c.isAccessible()) {
            return rows;
        }
        Set<Id> paymentIds = byId.keySet();
        for (Payment_Allocation__c allocation : [
            SELECT Id, Payment__c, Payment_Amount__c, Allocated_Amount__c, Allocation_Date__c, Invoice__r.Legal_Number__c, Invoice__r.Name,
                   Supplier_Bill__r.Name
            FROM Payment_Allocation__c
            WHERE Payment__c IN :paymentIds AND Status__c = :ALLOCATED
            WITH USER_MODE
            ORDER BY Allocation_Date__c
            LIMIT 2000
        ]) {
            PaymentRow row = byId.get(allocation.Payment__c);
            AllocationRow item = allocationRow(allocation);
            item.amount = allocation.Payment_Amount__c == null ? zero(allocation.Allocated_Amount__c) : allocation.Payment_Amount__c;
            row.allocated += item.amount;
            row.allocations.add(item);
        }
        return rows;
    }

    private static AllocationRow allocationRow(Payment_Allocation__c allocation) {
        AllocationRow item = new AllocationRow();
        item.allocationId = allocation.Id;
        item.allocationDate = allocation.Allocation_Date__c;
        item.amount = zero(allocation.Allocated_Amount__c);
        if (allocation.Invoice__r != null) {
            item.documentNumber = String.isBlank(allocation.Invoice__r.Legal_Number__c) ? allocation.Invoice__r.Name : allocation.Invoice__r.Legal_Number__c;
        } else if (allocation.Supplier_Bill__r != null) {
            item.documentNumber = allocation.Supplier_Bill__r.Name;
        }
        return item;
    }

    private static List<DocumentRow> openBills(Id companyId) {
        List<DocumentRow> rows = new List<DocumentRow>();
        try {
            SABAccountsPayableWorkspaceController.WorkspaceDTO ap = SABAccountsPayableWorkspaceController.getWorkspace(companyId, Date.today(), null, null, false);
            for (SABAccountsPayableWorkspaceController.BillRowDTO bill : ap.bills) {
                if (bill.status != 'Posted' || bill.documentType == 'Supplier Credit' || zero(bill.outstandingAmount) <= 0) {
                    continue;
                }
                DocumentRow row = new DocumentRow();
                row.documentId = bill.billId;
                row.documentNumber = String.isBlank(bill.vendorReference) ? bill.billNumber : bill.billNumber + ' (' + bill.vendorReference + ')';
                row.partyProfileId = bill.supplierProfileId;
                row.partyName = bill.supplierName;
                row.dueDate = bill.dueDate;
                row.outstanding = bill.outstandingAmount;
                row.currencyCode = bill.transactionCurrency;
                row.status = bill.status;
                rows.add(row);
            }
        } catch (Exception ex) {
            // Users without payables access still see payments; they just cannot pick bills.
            return rows;
        }
        return rows;
    }

    private static List<DocumentRow> openInvoices(Id companyId) {
        List<DocumentRow> rows = new List<DocumentRow>();
        try {
            SABARAgingService.ARAgingRequest request = new SABARAgingService.ARAgingRequest();
            request.companyId = companyId;
            request.asOfDate = Date.today();
            request.includeSettled = false;
            for (SABARAgingService.ARAgingRow aging : SABARAgingService.getAging(request).rows) {
                if (zero(aging.outstandingDocumentAmount) <= 0) {
                    continue;
                }
                DocumentRow row = new DocumentRow();
                row.documentId = aging.invoiceId;
                row.documentNumber = aging.legalNumber;
                row.partyProfileId = aging.partyProfileId;
                row.partyName = aging.customerName;
                row.dueDate = aging.dueDate;
                row.outstanding = aging.outstandingDocumentAmount;
                row.currencyCode = aging.transactionCurrency;
                row.daysPastDue = aging.daysPastDue;
                rows.add(row);
            }
        } catch (Exception ex) {
            rows.clear();
        }
        return rows;
    }

    // ---------------------------------------------------------------- details

    @AuraEnabled
    public static DocumentDetail getDocumentDetail(Id companyId, Id documentId) {
        assertCompany(companyId);
        if (documentId == null) {
            throw auraError('A document is required.');
        }
        try {
            DocumentDetail detail = new DocumentDetail();
            detail.lines = new List<LineRow>();
            detail.allocations = new List<AllocationRow>();
            if (documentId.getSObjectType() == Invoice__c.SObjectType) {
                invoiceDetail(companyId, documentId, detail);
            } else if (documentId.getSObjectType() == Supplier_Bill__c.SObjectType) {
                billDetail(companyId, documentId, detail);
            } else {
                throw auraError('Only invoices and supplier bills have line details.');
            }
            return detail;
        } catch (QueryException ex) {
            throw auraError('The document could not be loaded: ' + ex.getMessage());
        }
    }

    private static void invoiceDetail(Id companyId, Id invoiceId, DocumentDetail detail) {
        Invoice__c invoice = [SELECT Company__c, Subtotal__c, Tax_Total__c, Total__c FROM Invoice__c WHERE Id = :invoiceId WITH USER_MODE LIMIT 1];
        assertBelongs(invoice.Company__c, companyId);
        detail.subtotal = zero(invoice.Subtotal__c);
        detail.taxTotal = zero(invoice.Tax_Total__c);
        detail.total = zero(invoice.Total__c);
        for (Invoice_Line__c line : [
            SELECT Line_Number__c, Description__c, Quantity__c, Unit_Price__c, Net_Amount__c, Revenue_Account__r.Account_Code__c,
                   Revenue_Account__r.Name, Tax_Code__r.Name
            FROM Invoice_Line__c
            WHERE Invoice__c = :invoiceId
            WITH USER_MODE
            ORDER BY Line_Number__c
            LIMIT 500
        ]) {
            LineRow row = lineRow(line.Line_Number__c, line.Description__c, line.Quantity__c, line.Unit_Price__c, line.Net_Amount__c);
            row.accountCode = line.Revenue_Account__r == null ? null : line.Revenue_Account__r.Account_Code__c;
            row.accountName = line.Revenue_Account__r == null ? null : line.Revenue_Account__r.Name;
            row.taxCode = line.Tax_Code__r == null ? null : line.Tax_Code__r.Name;
            detail.lines.add(row);
        }
        for (Payment_Allocation__c allocation : [
            SELECT Id, Allocated_Amount__c, Allocation_Date__c, Payment__r.Name, Invoice__r.Legal_Number__c, Invoice__r.Name, Supplier_Bill__r.Name
            FROM Payment_Allocation__c
            WHERE Invoice__c = :invoiceId AND Status__c = :ALLOCATED
            WITH USER_MODE
            ORDER BY Allocation_Date__c
            LIMIT 200
        ]) {
            AllocationRow row = allocationRow(allocation);
            row.documentNumber = allocation.Payment__r == null ? null : allocation.Payment__r.Name;
            detail.allocations.add(row);
        }
    }

    private static void billDetail(Id companyId, Id billId, DocumentDetail detail) {
        Supplier_Bill__c bill = [SELECT Company__c, Subtotal__c, Tax_Total__c, Total__c FROM Supplier_Bill__c WHERE Id = :billId WITH USER_MODE LIMIT 1];
        assertBelongs(bill.Company__c, companyId);
        detail.subtotal = zero(bill.Subtotal__c);
        detail.taxTotal = zero(bill.Tax_Total__c);
        detail.total = zero(bill.Total__c);
        for (Bill_Line__c line : [
            SELECT Line_Number__c, Description__c, Quantity__c, Unit_Price__c, Net_Amount__c, Expense_or_Asset_Account__r.Account_Code__c,
                   Expense_or_Asset_Account__r.Name, Tax_Code__r.Name
            FROM Bill_Line__c
            WHERE Supplier_Bill__c = :billId
            WITH USER_MODE
            ORDER BY Line_Number__c
            LIMIT 500
        ]) {
            LineRow row = lineRow(line.Line_Number__c, line.Description__c, line.Quantity__c, line.Unit_Price__c, line.Net_Amount__c);
            row.accountCode = line.Expense_or_Asset_Account__r == null ? null : line.Expense_or_Asset_Account__r.Account_Code__c;
            row.accountName = line.Expense_or_Asset_Account__r == null ? null : line.Expense_or_Asset_Account__r.Name;
            row.taxCode = line.Tax_Code__r == null ? null : line.Tax_Code__r.Name;
            detail.lines.add(row);
        }
        for (Payment_Allocation__c allocation : [
            SELECT Id, Allocated_Amount__c, Allocation_Date__c, Payment__r.Name, Invoice__r.Legal_Number__c, Invoice__r.Name, Supplier_Bill__r.Name
            FROM Payment_Allocation__c
            WHERE Supplier_Bill__c = :billId AND Status__c = :ALLOCATED
            WITH USER_MODE
            ORDER BY Allocation_Date__c
            LIMIT 200
        ]) {
            AllocationRow row = allocationRow(allocation);
            row.documentNumber = allocation.Payment__r == null ? null : allocation.Payment__r.Name;
            detail.allocations.add(row);
        }
    }

    private static LineRow lineRow(Decimal lineNumber, String description, Decimal quantity, Decimal unitPrice, Decimal netAmount) {
        LineRow row = new LineRow();
        row.lineNumber = lineNumber == null ? null : lineNumber.intValue();
        row.description = description;
        row.quantity = quantity;
        row.unitPrice = unitPrice;
        row.netAmount = zero(netAmount);
        return row;
    }

    // ---------------------------------------------------------------- helpers

    private static Decimal settledThisMonth(Id companyId, String direction) {
        if (!Schema.SObjectType.Accounting_Payment__c.isAccessible()) {
            return 0;
        }
        Date monthStart = Date.today().toStartOfMonth();
        AggregateResult row = [
            SELECT SUM(Amount__c) total
            FROM Accounting_Payment__c
            WHERE Company__c = :companyId AND Direction__c = :direction AND Processing_State__c = 'Succeeded'
              AND Effective_Date__c >= :monthStart
            WITH USER_MODE
        ];
        return zero((Decimal) row.get('total'));
    }

    private static String currencyOf(Id companyId) {
        return [SELECT Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH USER_MODE LIMIT 1].Functional_Currency__c;
    }

    private static void assertCompany(Id companyId) {
        if (companyId == null || !SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw auraError('You do not have active access to this Accounting Company.');
        }
    }

    private static void assertBelongs(Id recordCompanyId, Id companyId) {
        if (recordCompanyId != companyId) {
            throw auraError('The document does not belong to this Accounting Company.');
        }
    }

    private static Decimal zero(Decimal value) {
        return value == null ? 0 : value;
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}