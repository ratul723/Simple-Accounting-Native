/**
 * G22G-3b: document entry for the redesigned workspaces.
 *
 * Creates and edits Draft invoices and credit notes, supplier bills and supplier credits, customer receipts and supplier
 * payments, and expense claims, header and lines, so New invoice, New bill, Record receipt, New payment and New expense
 * claim work in the app. Everything after Draft stays with the existing lifecycle services; this class only adds invoice
 * submit and approve, which had no callable action before (SABInvoiceService.submit / approve, unchanged).
 *
 * Rules:
 * - Company grant first; documents are written in user mode, so object and field access and every guard trigger apply.
 * - Only Draft documents can be edited; lines are replaced as a set on every save.
 * - Invoice and bill tax is materialized by SABDocumentTaxService, which also sets the document totals.
 * - Invoice approval needs SAB_Approve_Financial_Document and a different user from the one who created the invoice.
 * - Every save and transition is idempotent by request key and audited in Business_Action__c.
 */
public with sharing class SABDocumentEntryService {
    public class DocumentEntryException extends Exception {}

    private static final String APPROVE_PERMISSION = 'SAB_Approve_Financial_Document';
    private static final String CLAIM_PERMISSION = 'SAB_Submit_Expense_Claim';
    private static final String DRAFT = 'Draft';
    private static final String SOURCE_TYPE = 'DocumentEntry';
    private static final Integer MAX_LINES = 200;

    public class LineRequest {
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
        @AuraEnabled public Decimal unitPrice { get; set; }
        @AuraEnabled public Decimal discount { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public Id taxCodeId { get; set; }
        @AuraEnabled public Id departmentId { get; set; }
        @AuraEnabled public Id costCenterId { get; set; }
        @AuraEnabled public Id projectId { get; set; }
        @AuraEnabled public String category { get; set; }
        @AuraEnabled public Date expenseDate { get; set; }
    }

    public class DocumentRequest {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String documentType { get; set; }
        @AuraEnabled public Id partyProfileId { get; set; }
        @AuraEnabled public Date documentDate { get; set; }
        @AuraEnabled public Date dueDate { get; set; }
        @AuraEnabled public String reference { get; set; }
        @AuraEnabled public Id originalInvoiceId { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Decimal exchangeRate { get; set; }
        @AuraEnabled public List<LineRequest> lines { get; set; }
    }

    public class PaymentRequest {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String direction { get; set; }
        @AuraEnabled public Id partyProfileId { get; set; }
        @AuraEnabled public Id bankAccountId { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public Date effectiveDate { get; set; }
        @AuraEnabled public String method { get; set; }
        @AuraEnabled public String reference { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Decimal exchangeRate { get; set; }
    }

    public class ClaimRequest {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public Id employmentId { get; set; }
        @AuraEnabled public Date claimDate { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public List<LineRequest> lines { get; set; }
    }

    public class Option {
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public String label { get; set; }

        Option(String value, String label) {
            this.value = value;
            this.label = label;
        }
    }

    public class EntryOptions {
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Boolean canCreateInvoice { get; set; }
        @AuraEnabled public Boolean canApproveInvoice { get; set; }
        @AuraEnabled public Boolean canCreateBill { get; set; }
        @AuraEnabled public Boolean canCreatePayment { get; set; }
        @AuraEnabled public Boolean canCreateClaim { get; set; }
        @AuraEnabled public List<Option> customers { get; set; }
        @AuraEnabled public List<Option> suppliers { get; set; }
        @AuraEnabled public List<Option> revenueAccounts { get; set; }
        @AuraEnabled public List<Option> expenseAccounts { get; set; }
        @AuraEnabled public List<Option> taxCodes { get; set; }
        @AuraEnabled public List<Option> bankAccounts { get; set; }
        @AuraEnabled public List<Option> departments { get; set; }
        @AuraEnabled public List<Option> costCenters { get; set; }
        @AuraEnabled public List<Option> projects { get; set; }
        @AuraEnabled public List<Option> methods { get; set; }
        @AuraEnabled public List<Option> employments { get; set; }
        @AuraEnabled public Id myEmploymentId { get; set; }
        @AuraEnabled public List<Option> creditableInvoices { get; set; }
    }

    // ---------------------------------------------------------------- options

    @AuraEnabled
    public static EntryOptions getEntryOptions(Id companyId) {
        assertCompany(companyId);
        try {
            EntryOptions o = new EntryOptions();
            o.currencyCode = functionalCurrency(companyId);
            o.canCreateInvoice = Schema.SObjectType.Invoice__c.isCreateable();
            o.canApproveInvoice = SABPermissionService.hasPermission(APPROVE_PERMISSION);
            o.canCreateBill = Schema.SObjectType.Supplier_Bill__c.isCreateable();
            o.canCreatePayment = Schema.SObjectType.Accounting_Payment__c.isCreateable();
            o.canCreateClaim = SABPermissionService.hasPermission(CLAIM_PERMISSION) && Schema.SObjectType.Expense_Claim__c.isCreateable();
            o.customers = new List<Option>();
            o.suppliers = new List<Option>();
            for (Party_Accounting_Profile__c p : [
                SELECT Id, Account__r.Name, Is_Customer__c, Is_Supplier__c FROM Party_Accounting_Profile__c
                WHERE Company__c = :companyId AND Is_Active__c = true WITH USER_MODE ORDER BY Account__r.Name LIMIT 500
            ]) {
                String name = p.Account__r == null ? String.valueOf(p.Id) : p.Account__r.Name;
                if (p.Is_Customer__c == true) {
                    o.customers.add(new Option(p.Id, name));
                }
                if (p.Is_Supplier__c == true) {
                    o.suppliers.add(new Option(p.Id, name));
                }
            }
            o.revenueAccounts = new List<Option>();
            o.expenseAccounts = new List<Option>();
            for (GL_Account__c a : [
                SELECT Id, Account_Code__c, Name, Account_Type__c FROM GL_Account__c
                WHERE Company__c = :companyId AND Is_Active__c = true AND Is_Control_Account__c = false WITH USER_MODE ORDER BY Account_Code__c LIMIT 1000
            ]) {
                Option option = new Option(a.Id, a.Account_Code__c + ' ' + a.Name);
                if (a.Account_Type__c == 'Revenue') {
                    o.revenueAccounts.add(option);
                } else if (a.Account_Type__c == 'Expense' || a.Account_Type__c == 'Asset') {
                    o.expenseAccounts.add(option);
                }
            }
            o.taxCodes = new List<Option>();
            for (Tax_Code__c t : [SELECT Id, Code__c, Name FROM Tax_Code__c WHERE Company__c = :companyId AND Is_Active__c = true WITH USER_MODE ORDER BY Code__c LIMIT 200]) {
                o.taxCodes.add(new Option(t.Id, t.Code__c == null ? t.Name : t.Code__c + ' ' + t.Name));
            }
            o.bankAccounts = new List<Option>();
            for (Bank_Account__c b : [SELECT Id, Name FROM Bank_Account__c WHERE Company__c = :companyId AND Is_Active__c = true WITH USER_MODE ORDER BY Name LIMIT 200]) {
                o.bankAccounts.add(new Option(b.Id, b.Name));
            }
            o.departments = new List<Option>();
            for (Department__c d : [SELECT Id, Name FROM Department__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Name LIMIT 500]) {
                o.departments.add(new Option(d.Id, d.Name));
            }
            o.costCenters = new List<Option>();
            for (Cost_Center__c c : [SELECT Id, Name FROM Cost_Center__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Name LIMIT 500]) {
                o.costCenters.add(new Option(c.Id, c.Name));
            }
            o.projects = new List<Option>();
            if (Schema.SObjectType.Project__c.isAccessible()) {
                for (Project__c p : [SELECT Id, Project_Code__c, Name FROM Project__c WHERE Company__c = :companyId AND Status__c IN ('Planned', 'Active')
                        WITH USER_MODE ORDER BY Project_Code__c LIMIT 500]) {
                    o.projects.add(new Option(p.Id, p.Project_Code__c + ' ' + p.Name));
                }
            }
            o.methods = new List<Option>();
            for (Schema.PicklistEntry e : Accounting_Payment__c.Method__c.getDescribe().getPicklistValues()) {
                if (e.isActive()) {
                    o.methods.add(new Option(e.getValue(), e.getLabel()));
                }
            }
            loadEmployments(companyId, o);
            o.creditableInvoices = new List<Option>();
            for (Invoice__c i : [
                SELECT Id, Name, Legal_Number__c, Party_Profile__c, Total__c FROM Invoice__c
                WHERE Company__c = :companyId AND Document_Type__c = 'Invoice' AND Status__c IN ('Approved', 'Issued', 'Posted')
                WITH USER_MODE ORDER BY Document_Date__c DESC LIMIT 200
            ]) {
                o.creditableInvoices.add(new Option(i.Id, (String.isBlank(i.Legal_Number__c) ? i.Name : i.Legal_Number__c) + '|' + i.Party_Profile__c));
            }
            return o;
        } catch (QueryException ex) {
            throw auraError('Document options could not be loaded: ' + ex.getMessage());
        }
    }

    private static void loadEmployments(Id companyId, EntryOptions o) {
        o.employments = new List<Option>();
        if (!Schema.SObjectType.Employment__c.isAccessible()) {
            return;
        }
        Id userId = UserInfo.getUserId();
        for (Employment__c e : [
            SELECT Id, Employee__r.Employee_Reference__c, Employee__r.User__c, Employee__r.User__r.Name FROM Employment__c
            WHERE Company__c = :companyId AND Employment_Status__c = 'Active' WITH USER_MODE ORDER BY Employee__r.Employee_Reference__c LIMIT 500
        ]) {
            String label = e.Employee__r == null ? String.valueOf(e.Id)
                : (e.Employee__r.User__r == null ? e.Employee__r.Employee_Reference__c : e.Employee__r.User__r.Name + ' (' + e.Employee__r.Employee_Reference__c + ')');
            o.employments.add(new Option(e.Id, label));
            if (e.Employee__r != null && e.Employee__r.User__c == userId) {
                o.myEmploymentId = e.Id;
            }
        }
    }

    // ---------------------------------------------------------------- drafts

    public class DraftView {
        @AuraEnabled public DocumentRequest document { get; set; }
        @AuraEnabled public PaymentRequest payment { get; set; }
        @AuraEnabled public ClaimRequest claim { get; set; }
    }

    /** A Draft document as a request the entry form can edit. */
    @AuraEnabled
    public static DraftView getDraft(Id companyId, Id recordId) {
        assertCompany(companyId);
        if (recordId == null) {
            throw auraError('A document is required.');
        }
        try {
            DraftView view = new DraftView();
            Schema.SObjectType type = recordId.getSObjectType();
            if (type == Invoice__c.SObjectType) {
                view.document = invoiceDraft(companyId, recordId);
            } else if (type == Supplier_Bill__c.SObjectType) {
                view.document = billDraft(companyId, recordId);
            } else if (type == Accounting_Payment__c.SObjectType) {
                view.payment = paymentDraft(companyId, recordId);
            } else if (type == Expense_Claim__c.SObjectType) {
                view.claim = claimDraft(companyId, recordId);
            } else {
                throw auraError('This document cannot be edited here.');
            }
            return view;
        } catch (QueryException ex) {
            throw auraError('The draft could not be loaded: ' + ex.getMessage());
        }
    }

    private static DocumentRequest invoiceDraft(Id companyId, Id invoiceId) {
        Invoice__c i = [
            SELECT Id, Company__c, Status__c, Document_Type__c, Party_Profile__c, Document_Date__c, Due_Date__c, Original_Invoice__c, Transaction_Currency__c, Exchange_Rate__c,
                   (SELECT Description__c, Quantity__c, Unit_Price__c, Discount_Amount__c, Revenue_Account__c, Tax_Code__c, Department__c, Cost_Center__c, Project__c
                    FROM Invoice_Line_Invoice__r ORDER BY Line_Number__c)
            FROM Invoice__c WHERE Id = :invoiceId WITH USER_MODE LIMIT 1
        ];
        assertDraft(i.Company__c, companyId, i.Status__c);
        DocumentRequest r = header(i.Id, companyId, i.Document_Type__c, i.Party_Profile__c, i.Document_Date__c, i.Due_Date__c, null, i.Transaction_Currency__c, i.Exchange_Rate__c);
        r.originalInvoiceId = i.Original_Invoice__c;
        for (Invoice_Line__c l : i.Invoice_Line_Invoice__r) {
            r.lines.add(withProject(line(l.Description__c, l.Quantity__c, l.Unit_Price__c, l.Discount_Amount__c, l.Revenue_Account__c, l.Tax_Code__c, l.Department__c, l.Cost_Center__c), l.Project__c));
        }
        return r;
    }

    private static DocumentRequest billDraft(Id companyId, Id billId) {
        Supplier_Bill__c b = [
            SELECT Id, Company__c, Status__c, Document_Type__c, Supplier_Profile__c, Document_Date__c, Due_Date__c, Vendor_Reference__c, Transaction_Currency__c, Exchange_Rate__c,
                   (SELECT Description__c, Quantity__c, Unit_Price__c, Expense_or_Asset_Account__c, Tax_Code__c, Department__c, Cost_Center__c, Project__c FROM Bill_Line_Supplier_Bill__r ORDER BY Line_Number__c)
            FROM Supplier_Bill__c WHERE Id = :billId WITH USER_MODE LIMIT 1
        ];
        assertDraft(b.Company__c, companyId, b.Status__c);
        DocumentRequest r = header(b.Id, companyId, b.Document_Type__c, b.Supplier_Profile__c, b.Document_Date__c, b.Due_Date__c, b.Vendor_Reference__c, b.Transaction_Currency__c,
            b.Exchange_Rate__c);
        for (Bill_Line__c l : b.Bill_Line_Supplier_Bill__r) {
            r.lines.add(withProject(line(l.Description__c, l.Quantity__c, l.Unit_Price__c, null, l.Expense_or_Asset_Account__c, l.Tax_Code__c, l.Department__c, l.Cost_Center__c), l.Project__c));
        }
        return r;
    }

    private static PaymentRequest paymentDraft(Id companyId, Id paymentId) {
        Accounting_Payment__c p = [
            SELECT Id, Company__c, Processing_State__c, Direction__c, Party_Profile__c, Bank_Account__c, Amount__c, Effective_Date__c, Method__c, Reference__c,
                   Transaction_Currency__c, Exchange_Rate__c
            FROM Accounting_Payment__c WHERE Id = :paymentId WITH USER_MODE LIMIT 1
        ];
        assertDraft(p.Company__c, companyId, p.Processing_State__c);
        PaymentRequest r = new PaymentRequest();
        r.recordId = p.Id;
        r.companyId = companyId;
        r.direction = p.Direction__c;
        r.partyProfileId = p.Party_Profile__c;
        r.bankAccountId = p.Bank_Account__c;
        r.amount = p.Amount__c;
        r.effectiveDate = p.Effective_Date__c;
        r.method = p.Method__c;
        r.reference = p.Reference__c;
        r.currencyCode = p.Transaction_Currency__c;
        r.exchangeRate = p.Exchange_Rate__c;
        return r;
    }

    private static ClaimRequest claimDraft(Id companyId, Id claimId) {
        Expense_Claim__c c = [
            SELECT Id, Company__c, Status__c, Claimant_Employment__c, Claim_Date__c, Currency__c,
                   (SELECT Expense_Date__c, Category__c, Description__c, Amount__c, Expense_Account__c, Tax_Code__c, Department__c, Project__c FROM Expense_Claim_Line_Expense_Claim__r ORDER BY CreatedDate)
            FROM Expense_Claim__c WHERE Id = :claimId WITH USER_MODE LIMIT 1
        ];
        assertDraft(c.Company__c, companyId, c.Status__c);
        ClaimRequest r = new ClaimRequest();
        r.recordId = c.Id;
        r.companyId = companyId;
        r.employmentId = c.Claimant_Employment__c;
        r.claimDate = c.Claim_Date__c;
        r.currencyCode = c.Currency__c;
        r.lines = new List<LineRequest>();
        for (Expense_Claim_Line__c l : c.Expense_Claim_Line_Expense_Claim__r) {
            LineRequest lr = withProject(line(l.Description__c, null, null, null, l.Expense_Account__c, l.Tax_Code__c, l.Department__c, null), l.Project__c);
            lr.amount = l.Amount__c;
            lr.category = l.Category__c;
            lr.expenseDate = l.Expense_Date__c;
            r.lines.add(lr);
        }
        return r;
    }

    // ---------------------------------------------------------------- invoices

    @AuraEnabled
    public static Id saveInvoice(DocumentRequest request, String requestKey) {
        String key = requireKey(requestKey);
        DocumentRequest r = requireDocument(request);
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replay(prior, 'INVOICE_SAVED');
        }
        String type = String.isBlank(r.documentType) ? 'Invoice' : r.documentType;
        if (type != 'Invoice' && type != 'Credit Note') {
            throw new DocumentEntryException('Document type must be Invoice or Credit Note.');
        }
        if (type == 'Credit Note' && r.originalInvoiceId == null) {
            throw new DocumentEntryException('Choose the invoice this credit note reduces.');
        }
        List<LineRequest> lines = requireLines(r.lines);
        String functional = functionalCurrency(r.companyId);
        Invoice__c invoice = new Invoice__c(Id = r.recordId, Company__c = r.companyId, Party_Profile__c = requireId(r.partyProfileId, 'Customer'), Document_Type__c = type,
            Document_Date__c = requireDate(r.documentDate, 'Invoice date'), Accounting_Date__c = r.documentDate,
            Due_Date__c = r.dueDate == null ? r.documentDate : r.dueDate, Original_Invoice__c = type == 'Credit Note' ? r.originalInvoiceId : null,
            Transaction_Currency__c = currencyOf(r.currencyCode, functional), Functional_Currency__c = functional, Exchange_Rate__c = rateOf(r.currencyCode, functional, r.exchangeRate),
            Exchange_Rate_Date__c = r.documentDate);
        if (r.recordId == null) {
            invoice.Status__c = DRAFT;
        } else {
            assertExistingDraft(Invoice__c.SObjectType, r.recordId, r.companyId);
        }
        SABInvoiceValidationService.validateHeader(invoice);
        Savepoint sp = Database.setSavepoint();
        try {
            upsertAsUser(invoice);
            List<Invoice_Line__c> rows = new List<Invoice_Line__c>();
            Integer n = 1;
            for (LineRequest l : lines) {
                Decimal qty = l.quantity == null ? 1 : l.quantity;
                Decimal price = requireAmount(l.unitPrice, 'Unit price');
                Decimal discount = l.discount == null ? 0 : l.discount;
                rows.add(new Invoice_Line__c(Invoice__c = invoice.Id, Line_Number__c = n++, Description__c = requireText(l.description, 'Line description'),
                    Quantity__c = qty, Unit_Price__c = price, Discount_Amount__c = discount, Net_Amount__c = qty * price - discount,
                    Revenue_Account__c = requireId(l.accountId, 'Revenue account'), Tax_Code__c = l.taxCodeId, Department__c = l.departmentId, Cost_Center__c = l.costCenterId,
                    Project__c = l.projectId));
            }
            replaceLines([SELECT Id FROM Invoice_Line__c WHERE Invoice__c = :invoice.Id WITH USER_MODE], rows);
            SABInvoiceValidationService.validateLines(invoice, rows);
            SABDocumentTaxService.materializeInvoiceTaxes(invoice.Id);
            new Writer().audit(r.companyId, 'INVOICE_SAVED', key, invoice.Id, type + ' draft saved');
        } catch (Exception ex) {
            Database.rollback(sp);
            throw asEntryException(ex);
        }
        return invoice.Id;
    }

    /** Draft to Submitted, through SABInvoiceService.submit. */
    @AuraEnabled
    public static String submitInvoice(Id invoiceId, String requestKey) {
        return transitionInvoice(invoiceId, requestKey, false);
    }

    /** Submitted to Approved, through SABInvoiceService.approve, by someone other than the creator. */
    @AuraEnabled
    public static String approveInvoice(Id invoiceId, String requestKey) {
        return transitionInvoice(invoiceId, requestKey, true);
    }

    private static String transitionInvoice(Id invoiceId, String requestKey, Boolean approve) {
        String key = requireKey(requestKey);
        if (invoiceId == null) {
            throw new DocumentEntryException('An invoice is required.');
        }
        Invoice__c current = [SELECT Id, Company__c, Status__c, CreatedById FROM Invoice__c WHERE Id = :invoiceId WITH USER_MODE LIMIT 1];
        assertCompany(current.Company__c);
        String actionName = approve ? 'INVOICE_APPROVED' : 'INVOICE_SUBMITTED';
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            replay(prior, actionName);
            return approve ? 'Approved' : 'Submitted';
        }
        if (approve) {
            SABPermissionService.assertPermission(APPROVE_PERMISSION, 'You do not have permission to approve invoices.');
            if (current.CreatedById == UserInfo.getUserId()) {
                throw new DocumentEntryException('An invoice must be approved by someone other than the person who created it.');
            }
        } else if (!Schema.SObjectType.Invoice__c.isUpdateable()) {
            throw new DocumentEntryException('You do not have permission to submit invoices.');
        }
        Invoice__c result;
        try {
            result = approve ? SABInvoiceService.approve(invoiceId) : SABInvoiceService.submit(invoiceId);
        } catch (SABInvoiceValidationService.ValidationException ex) {
            throw new DocumentEntryException(ex.getMessage());
        }
        new Writer().audit(current.Company__c, actionName, key, invoiceId, approve ? 'Invoice approved' : 'Invoice submitted');
        return result.Status__c;
    }

    // ---------------------------------------------------------------- bills

    @AuraEnabled
    public static Id saveBill(DocumentRequest request, String requestKey) {
        String key = requireKey(requestKey);
        DocumentRequest r = requireDocument(request);
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replay(prior, 'BILL_SAVED');
        }
        String type = String.isBlank(r.documentType) ? 'Bill' : r.documentType;
        if (type != 'Bill' && type != 'Supplier Credit') {
            throw new DocumentEntryException('Document type must be Bill or Supplier Credit.');
        }
        List<LineRequest> lines = requireLines(r.lines);
        String functional = functionalCurrency(r.companyId);
        Date documentDate = requireDate(r.documentDate, 'Bill date');
        Supplier_Bill__c bill = new Supplier_Bill__c(Id = r.recordId, Company__c = r.companyId, Supplier_Profile__c = requireId(r.partyProfileId, 'Supplier'),
            Document_Type__c = type, Document_Date__c = documentDate, Accounting_Date__c = documentDate, Due_Date__c = r.dueDate == null ? documentDate : r.dueDate,
            Vendor_Reference__c = String.isBlank(r.reference) ? null : r.reference.trim(), Transaction_Currency__c = currencyOf(r.currencyCode, functional),
            Functional_Currency__c = functional, Exchange_Rate__c = rateOf(r.currencyCode, functional, r.exchangeRate));
        if (bill.Due_Date__c < documentDate) {
            throw new DocumentEntryException('Due date cannot be before the bill date.');
        }
        if (r.recordId == null) {
            bill.Status__c = DRAFT;
        } else {
            assertExistingDraft(Supplier_Bill__c.SObjectType, r.recordId, r.companyId);
        }
        Savepoint sp = Database.setSavepoint();
        try {
            upsertAsUser(bill);
            List<Bill_Line__c> rows = new List<Bill_Line__c>();
            Integer n = 1;
            for (LineRequest l : lines) {
                Decimal qty = l.quantity == null ? 1 : l.quantity;
                if (qty <= 0) {
                    throw new DocumentEntryException('Line quantity must be greater than zero.');
                }
                Decimal price = requireAmount(l.unitPrice, 'Unit price');
                rows.add(new Bill_Line__c(Supplier_Bill__c = bill.Id, Line_Number__c = n++, Description__c = requireText(l.description, 'Line description'),
                    Quantity__c = qty, Unit_Price__c = price, Net_Amount__c = qty * price, Expense_or_Asset_Account__c = requireId(l.accountId, 'Expense or asset account'),
                    Tax_Code__c = l.taxCodeId, Department__c = l.departmentId, Cost_Center__c = l.costCenterId, Project__c = l.projectId));
            }
            replaceLines([SELECT Id FROM Bill_Line__c WHERE Supplier_Bill__c = :bill.Id WITH USER_MODE], rows);
            SABDocumentTaxService.materializeSupplierBillTaxes(bill.Id);
            new Writer().audit(r.companyId, 'BILL_SAVED', key, bill.Id, type + ' draft saved');
        } catch (Exception ex) {
            Database.rollback(sp);
            throw asEntryException(ex);
        }
        return bill.Id;
    }

    // ---------------------------------------------------------------- payments

    @AuraEnabled
    public static Id savePayment(PaymentRequest request, String requestKey) {
        String key = requireKey(requestKey);
        if (request == null || request.companyId == null) {
            throw new DocumentEntryException('Accounting Company is required.');
        }
        assertCompany(request.companyId);
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replay(prior, 'PAYMENT_SAVED');
        }
        if (request.direction != 'Receipt' && request.direction != 'Disbursement') {
            throw new DocumentEntryException('Direction must be Receipt or Disbursement.');
        }
        if (request.amount == null || request.amount <= 0) {
            throw new DocumentEntryException('Amount must be greater than zero.');
        }
        String functional = functionalCurrency(request.companyId);
        Accounting_Payment__c payment = new Accounting_Payment__c(Id = request.recordId, Company__c = request.companyId, Direction__c = request.direction,
            Party_Profile__c = requireId(request.partyProfileId, request.direction == 'Receipt' ? 'Customer' : 'Supplier'),
            Bank_Account__c = requireId(request.bankAccountId, 'Bank account'), Amount__c = request.amount,
            Effective_Date__c = requireDate(request.effectiveDate, 'Value date'), Method__c = String.isBlank(request.method) ? null : request.method,
            Reference__c = String.isBlank(request.reference) ? null : request.reference.trim(), Transaction_Currency__c = currencyOf(request.currencyCode, functional),
            Functional_Currency__c = functional, Exchange_Rate__c = paymentRate(request.currencyCode, functional, request.exchangeRate));
        if (request.recordId == null) {
            payment.Processing_State__c = DRAFT;
        } else {
            assertExistingDraft(Accounting_Payment__c.SObjectType, request.recordId, request.companyId);
        }
        Savepoint sp = Database.setSavepoint();
        try {
            upsertAsUser(payment);
            new Writer().audit(request.companyId, 'PAYMENT_SAVED', key, payment.Id, (request.direction == 'Receipt' ? 'Receipt' : 'Payment') + ' draft saved');
        } catch (Exception ex) {
            Database.rollback(sp);
            throw asEntryException(ex);
        }
        return payment.Id;
    }

    // ---------------------------------------------------------------- expense claims

    @AuraEnabled
    public static Id saveExpenseClaim(ClaimRequest request, String requestKey) {
        String key = requireKey(requestKey);
        if (request == null || request.companyId == null) {
            throw new DocumentEntryException('Accounting Company is required.');
        }
        assertCompany(request.companyId);
        SABPermissionService.assertPermission(CLAIM_PERMISSION, 'You do not have permission to create expense claims.');
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replay(prior, 'CLAIM_SAVED');
        }
        List<LineRequest> lines = requireLines(request.lines);
        Date claimDate = requireDate(request.claimDate, 'Claim date');
        Expense_Claim__c claim = new Expense_Claim__c(Id = request.recordId, Company__c = request.companyId,
            Claimant_Employment__c = requireId(request.employmentId, 'Claimant'), Claim_Date__c = claimDate,
            Currency__c = currencyOf(request.currencyCode, functionalCurrency(request.companyId)));
        if (request.recordId == null) {
            claim.Status__c = DRAFT;
        } else {
            assertExistingDraft(Expense_Claim__c.SObjectType, request.recordId, request.companyId);
        }
        Savepoint sp = Database.setSavepoint();
        try {
            upsertAsUser(claim);
            List<Expense_Claim_Line__c> rows = new List<Expense_Claim_Line__c>();
            for (LineRequest l : lines) {
                Decimal amount = requireAmount(l.amount, 'Amount');
                if (amount <= 0) {
                    throw new DocumentEntryException('Expense amounts must be greater than zero.');
                }
                rows.add(new Expense_Claim_Line__c(Expense_Claim__c = claim.Id, Expense_Date__c = l.expenseDate == null ? claimDate : l.expenseDate,
                    Category__c = requireText(l.category, 'Category'), Description__c = requireText(l.description, 'Line description'), Amount__c = amount,
                    Expense_Account__c = requireId(l.accountId, 'Expense account'), Tax_Code__c = l.taxCodeId, Department__c = l.departmentId,
                    Project__c = l.projectId));
            }
            replaceLines([SELECT Id FROM Expense_Claim_Line__c WHERE Expense_Claim__c = :claim.Id WITH USER_MODE], rows);
            new Writer().audit(request.companyId, 'CLAIM_SAVED', key, claim.Id, 'Expense claim draft saved');
        } catch (Exception ex) {
            Database.rollback(sp);
            throw asEntryException(ex);
        }
        return claim.Id;
    }

    // ---------------------------------------------------------------- helpers

    private static DocumentRequest requireDocument(DocumentRequest request) {
        if (request == null || request.companyId == null) {
            throw new DocumentEntryException('Accounting Company is required.');
        }
        assertCompany(request.companyId);
        return request;
    }

    private static List<LineRequest> requireLines(List<LineRequest> lines) {
        if (lines == null || lines.isEmpty()) {
            throw new DocumentEntryException('Add at least one line.');
        }
        if (lines.size() > MAX_LINES) {
            throw new DocumentEntryException('Documents are limited to ' + MAX_LINES + ' lines.');
        }
        return lines;
    }

    private static void replaceLines(List<SObject> existing, List<SObject> rows) {
        if (!existing.isEmpty()) {
            delete as user existing;
        }
        insert as user rows;
    }

    private static void upsertAsUser(SObject record) {
        if (record.Id == null) {
            insert as user record;
        } else {
            update as user record;
        }
    }

    private static void assertExistingDraft(Schema.SObjectType type, Id recordId, Id companyId) {
        String objectName = type.getDescribe(SObjectDescribeOptions.DEFERRED).getName();
        String stateField = type == Accounting_Payment__c.SObjectType ? 'Processing_State__c' : 'Status__c';
        List<SObject> rows = Database.queryWithBinds('SELECT Company__c, ' + stateField + ' FROM ' + objectName + ' WHERE Id = :recordId LIMIT 1',
            new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE);
        if (rows.isEmpty()) {
            throw new DocumentEntryException('The document was not found or is not accessible.');
        }
        assertDraft((Id) rows[0].get('Company__c'), companyId, (String) rows[0].get(stateField));
    }

    private static void assertDraft(Id recordCompanyId, Id companyId, String status) {
        if (recordCompanyId != companyId) {
            throw new DocumentEntryException('The document belongs to a different Accounting Company.');
        }
        if (status != DRAFT) {
            throw new DocumentEntryException('Only Draft documents can be edited.');
        }
    }

    private static DocumentRequest header(Id recordId, Id companyId, String type, Id partyId, Date documentDate, Date dueDate, String reference, String currencyCode,
            Decimal exchangeRate) {
        DocumentRequest r = new DocumentRequest();
        r.recordId = recordId;
        r.companyId = companyId;
        r.documentType = type;
        r.partyProfileId = partyId;
        r.documentDate = documentDate;
        r.dueDate = dueDate;
        r.reference = reference;
        r.currencyCode = currencyCode;
        r.exchangeRate = exchangeRate;
        r.lines = new List<LineRequest>();
        return r;
    }

    private static LineRequest line(String description, Decimal quantity, Decimal unitPrice, Decimal discount, Id accountId, Id taxCodeId, Id departmentId, Id costCenterId) {
        LineRequest l = new LineRequest();
        l.description = description;
        l.quantity = quantity;
        l.unitPrice = unitPrice;
        l.discount = discount;
        l.accountId = accountId;
        l.taxCodeId = taxCodeId;
        l.departmentId = departmentId;
        l.costCenterId = costCenterId;
        return l;
    }

    private static LineRequest withProject(LineRequest l, Id projectId) {
        l.projectId = projectId;
        return l;
    }

    private static String currencyOf(String requested, String functional) {
        String value = String.isBlank(requested) ? functional : requested.trim().toUpperCase();
        if (!Pattern.matches('[A-Z]{3}', value)) {
            throw new DocumentEntryException('Currency must be a three-letter code.');
        }
        return value;
    }

    /** Foreign-currency payments take the approved Spot rate when they are authorised, so a rate is optional here. */
    private static Decimal paymentRate(String requested, String functional, Decimal rate) {
        if (String.isBlank(requested) || requested.trim().toUpperCase() == functional) {
            return 1;
        }
        return rate != null && rate > 0 ? rate : null;
    }

    private static Decimal rateOf(String requested, String functional, Decimal rate) {
        if (String.isBlank(requested) || requested.trim().toUpperCase() == functional) {
            return 1;
        }
        if (rate == null || rate <= 0) {
            throw new DocumentEntryException('Enter the exchange rate for a foreign-currency document.');
        }
        return rate;
    }

    private static Id requireId(Id value, String label) {
        if (value == null) {
            throw new DocumentEntryException(label + ' is required.');
        }
        return value;
    }

    private static Date requireDate(Date value, String label) {
        if (value == null) {
            throw new DocumentEntryException(label + ' is required.');
        }
        return value;
    }

    private static String requireText(String value, String label) {
        if (String.isBlank(value)) {
            throw new DocumentEntryException(label + ' is required.');
        }
        return value.trim();
    }

    private static Decimal requireAmount(Decimal value, String label) {
        if (value == null || value < 0) {
            throw new DocumentEntryException(label + ' is required and cannot be negative.');
        }
        return value;
    }

    private static String requireKey(String requestKey) {
        if (String.isBlank(requestKey) || requestKey.trim().length() > 160) {
            throw new DocumentEntryException('A request key of up to 160 characters is required.');
        }
        return requestKey.trim();
    }

    private static Id replay(Business_Action__c prior, String actionName) {
        if (prior.Action__c != actionName) {
            throw new DocumentEntryException('Request key has already been used for a different action.');
        }
        return Id.valueOf(prior.Source_Record_Id__c);
    }

    private static String functionalCurrency(Id companyId) {
        return [SELECT Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH USER_MODE LIMIT 1].Functional_Currency__c;
    }

    private static void assertCompany(Id companyId) {
        if (companyId == null || !SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw new DocumentEntryException('You do not have active access to this Accounting Company.');
        }
        try {
            SABCompanyAccessService.assertCompanyActive(companyId);
        } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
            throw new DocumentEntryException(ex.getMessage());
        }
    }

    private static DocumentEntryException asEntryException(Exception ex) {
        if (ex instanceof DocumentEntryException) {
            return (DocumentEntryException) ex;
        }
        String message = ex.getMessage();
        if (ex instanceof DmlException && ((DmlException) ex).getNumDml() > 0) {
            message = ((DmlException) ex).getDmlMessage(0);
        }
        return new DocumentEntryException(message);
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }

    // System read of the request-key audit row: replay must be found even when sharing would hide the row.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c FROM Business_Action__c WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
    }

    // System write of the audit row after the permission and company checks above.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void audit(Id companyId, String actionName, String key, Id recordId, String reason) {
            insert as system new Business_Action__c(Company__c = companyId, Action__c = actionName, Actor__c = UserInfo.getUserId(), Action_At__c = System.now(),
                Reason__c = reason, Request_Key__c = key, Source_Type__c = SOURCE_TYPE, Source_Record_Id__c = String.valueOf(recordId), Source_Version__c = 1);
        }
    }
}
