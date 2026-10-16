/**
 * Customers and suppliers (contacts) for the Customers and Suppliers workspaces, document quick add and imports.
 *
 * A contact is an Account plus a Party Accounting Profile for one accounting company. One profile can be both a
 * customer and a supplier. Contacts are never deleted here: they are deactivated, which removes them from document
 * dropdowns while they stay on old documents and in reports.
 *
 *   getContacts      list with outstanding and overdue balances (from AR aging and AP)
 *   getContact       detail with documents, payments and a running statement
 *   getFormOptions   control, revenue and expense accounts, tax codes, payment terms and company defaults
 *   saveContact      full form create or edit, with duplicate warning and an audited bank-detail change
 *   quickAdd         name and optional email from a document; everything else from company defaults
 *   setActive        deactivate or reactivate
 *
 * Writes need SAB_Manage_Contacts and the company grant, are idempotent by request key and audited.
 */
public with sharing class SABContactService {
    public class ContactException extends Exception {}

    public static final String MANAGE_PERMISSION = 'SAB_Manage_Contacts';
    private static final Integer MAX_ROWS = 2000;

    public class Option {
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public String label { get; set; }

        Option(String value, String label) {
            this.value = value;
            this.label = label;
        }
    }

    public class ContactRow {
        @AuraEnabled public Id profileId { get; set; }
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String displayName { get; set; }
        @AuraEnabled public String email { get; set; }
        @AuraEnabled public String phone { get; set; }
        @AuraEnabled public Boolean isCustomer { get; set; }
        @AuraEnabled public Boolean isSupplier { get; set; }
        @AuraEnabled public Boolean active { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Decimal outstanding { get; set; }
        @AuraEnabled public Decimal overdue { get; set; }
    }

    public class ContactList {
        @AuraEnabled public Boolean canManage { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public List<ContactRow> rows { get; set; }
        @AuraEnabled public String balanceNote { get; set; }
    }

    public class ContactRequest {
        @AuraEnabled public Id profileId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String displayName { get; set; }
        @AuraEnabled public String email { get; set; }
        @AuraEnabled public String phone { get; set; }
        @AuraEnabled public String billingStreet { get; set; }
        @AuraEnabled public String billingCity { get; set; }
        @AuraEnabled public String billingState { get; set; }
        @AuraEnabled public String billingPostalCode { get; set; }
        @AuraEnabled public String billingCountry { get; set; }
        @AuraEnabled public String shippingStreet { get; set; }
        @AuraEnabled public String shippingCity { get; set; }
        @AuraEnabled public String shippingState { get; set; }
        @AuraEnabled public String shippingPostalCode { get; set; }
        @AuraEnabled public String shippingCountry { get; set; }
        @AuraEnabled public String taxNumber { get; set; }
        @AuraEnabled public Id taxCodeId { get; set; }
        @AuraEnabled public Id paymentTermId { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Decimal creditLimit { get; set; }
        @AuraEnabled public Boolean isCustomer { get; set; }
        @AuraEnabled public Boolean isSupplier { get; set; }
        @AuraEnabled public Id arControlId { get; set; }
        @AuraEnabled public Id apControlId { get; set; }
        @AuraEnabled public Id revenueAccountId { get; set; }
        @AuraEnabled public Id expenseAccountId { get; set; }
        @AuraEnabled public String paymentMethod { get; set; }
        @AuraEnabled public String bankAccountName { get; set; }
        @AuraEnabled public String bankAccountNumber { get; set; }
        @AuraEnabled public String bankRoutingCode { get; set; }
    }

    public class SaveResult {
        @AuraEnabled public Id profileId { get; set; }
        /** Set when a similar contact exists and the save was not confirmed; nothing was saved. */
        @AuraEnabled public String duplicateWarning { get; set; }
    }

    public class DocumentRow {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public String reference { get; set; }
        @AuraEnabled public String kind { get; set; }
        @AuraEnabled public Date documentDate { get; set; }
        @AuraEnabled public Date dueDate { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String status { get; set; }
    }

    public class StatementRow {
        @AuraEnabled public Date entryDate { get; set; }
        @AuraEnabled public String reference { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Decimal charge { get; set; }
        @AuraEnabled public Decimal paid { get; set; }
        @AuraEnabled public Decimal balance { get; set; }
    }

    public class ContactDetail {
        @AuraEnabled public ContactRequest contact { get; set; }
        @AuraEnabled public Boolean active { get; set; }
        @AuraEnabled public Boolean canManage { get; set; }
        @AuraEnabled public String paymentTermName { get; set; }
        @AuraEnabled public String taxCodeName { get; set; }
        @AuraEnabled public List<DocumentRow> documents { get; set; }
        @AuraEnabled public List<DocumentRow> payments { get; set; }
        @AuraEnabled public List<StatementRow> statement { get; set; }
    }

    public class FormOptions {
        @AuraEnabled public Boolean canManage { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public List<Option> arControls { get; set; }
        @AuraEnabled public List<Option> apControls { get; set; }
        @AuraEnabled public List<Option> revenueAccounts { get; set; }
        @AuraEnabled public List<Option> expenseAccounts { get; set; }
        @AuraEnabled public List<Option> taxCodes { get; set; }
        @AuraEnabled public List<Option> paymentTerms { get; set; }
        @AuraEnabled public List<String> paymentMethods { get; set; }
        @AuraEnabled public Id defaultArControlId { get; set; }
        @AuraEnabled public Id defaultApControlId { get; set; }
        @AuraEnabled public Id defaultPaymentTermId { get; set; }
    }

    // ------------------------------------------------------------------ reads

    @AuraEnabled
    public static ContactList getContacts(Id companyId, String kind) {
        assertCompany(companyId);
        Boolean customers = kind != 'supplier';
        Store store = new Store();
        ContactList contactView = new ContactList();
        contactView.canManage = canManage();
        contactView.functionalCurrency = store.company(companyId).Functional_Currency__c;
        contactView.rows = new List<ContactRow>();
        Map<Id, Decimal[]> balances = customers ? receivableBalances(companyId, contactView) : payableBalances(companyId, contactView);
        for (Party_Accounting_Profile__c p : store.profiles(companyId, customers)) {
            ContactRow row = new ContactRow();
            row.profileId = p.Id;
            row.accountId = p.Account__c;
            row.name = p.Account__r == null ? null : p.Account__r.Name;
            row.displayName = p.Display_Name__c;
            row.email = p.Email__c;
            row.phone = String.isNotBlank(p.Phone__c) ? p.Phone__c : (p.Account__r == null ? null : p.Account__r.Phone);
            row.isCustomer = p.Is_Customer__c == true;
            row.isSupplier = p.Is_Supplier__c == true;
            row.active = p.Is_Active__c == true;
            row.currencyCode = String.isBlank(p.Currency__c) ? contactView.functionalCurrency : p.Currency__c;
            Decimal[] b = balances.get(p.Id);
            row.outstanding = b == null ? 0 : b[0];
            row.overdue = b == null ? 0 : b[1];
            contactView.rows.add(row);
        }
        return contactView;
    }

    // Balances come from the aging views, so a user without AR or AP access still gets the contactView, without balances.
    private static Map<Id, Decimal[]> receivableBalances(Id companyId, ContactList contactView) {
        Map<Id, Decimal[]> result = new Map<Id, Decimal[]>();
        try {
            SABARAgingService.ARAgingRequest request = new SABARAgingService.ARAgingRequest();
            request.companyId = companyId;
            request.asOfDate = Date.today();
            request.includeSettled = false;
            for (SABARAgingService.ARAgingRow row : SABARAgingService.getAging(request).rows) {
                add(result, row.partyProfileId, row.outstandingBaseAmount, row.daysPastDue);
            }
        } catch (Exception ex) {
            contactView.balanceNote = 'Balances are not shown: ' + ex.getMessage();
        }
        return result;
    }

    private static Map<Id, Decimal[]> payableBalances(Id companyId, ContactList contactView) {
        Map<Id, Decimal[]> result = new Map<Id, Decimal[]>();
        try {
            SABAccountsPayableWorkspaceController.WorkspaceDTO ap = SABAccountsPayableWorkspaceController.getWorkspace(companyId, Date.today(), null, null, false);
            for (SABAccountsPayableWorkspaceController.BillRowDTO bill : ap.bills) {
                if (bill.status == 'Posted') {
                    add(result, bill.supplierProfileId, bill.outstandingAmount, bill.daysPastDue);
                }
            }
        } catch (Exception ex) {
            contactView.balanceNote = 'Balances are not shown: ' + ex.getMessage();
        }
        return result;
    }

    private static void add(Map<Id, Decimal[]> result, Id profileId, Decimal amount, Integer daysPastDue) {
        if (profileId == null || amount == null) {
            return;
        }
        Decimal[] b = result.containsKey(profileId) ? result.get(profileId) : new Decimal[]{ 0, 0 };
        b[0] += amount;
        if (daysPastDue != null && daysPastDue > 0) {
            b[1] += amount;
        }
        result.put(profileId, b);
    }

    @AuraEnabled
    public static ContactDetail getContact(Id profileId) {
        Store store = new Store();
        Party_Accounting_Profile__c p = store.profile(profileId);
        assertCompany(p.Company__c);
        ContactDetail detail = new ContactDetail();
        detail.canManage = canManage();
        detail.active = p.Is_Active__c == true;
        detail.contact = toRequest(p, detail.canManage);
        detail.paymentTermName = p.Payment_Term__r == null ? null : p.Payment_Term__r.Name;
        detail.taxCodeName = p.Default_Tax_Code__r == null ? null : p.Default_Tax_Code__r.Code__c;
        detail.documents = new List<DocumentRow>();
        detail.payments = new List<DocumentRow>();
        detail.statement = new List<StatementRow>();
        List<StatementRow> entries = new List<StatementRow>();
        if (p.Is_Customer__c && Schema.SObjectType.Invoice__c.isAccessible()) {
            for (Invoice__c i : [SELECT Id, Name, Legal_Number__c, Document_Type__c, Document_Date__c, Due_Date__c, Total__c, Status__c FROM Invoice__c
                    WHERE Party_Profile__c = :profileId WITH USER_MODE ORDER BY Document_Date__c DESC LIMIT 200]) {
                Boolean credit = i.Document_Type__c == 'Credit Note';
                detail.documents.add(doc(i.Id, String.isBlank(i.Legal_Number__c) ? i.Name : i.Legal_Number__c, credit ? 'Credit note' : 'Invoice',
                    i.Document_Date__c, i.Due_Date__c, i.Total__c, i.Status__c));
                if (i.Status__c == 'Posted' || i.Status__c == 'Paid' || i.Status__c == 'Part Paid') {
                    entries.add(entry(i.Document_Date__c, String.isBlank(i.Legal_Number__c) ? i.Name : i.Legal_Number__c, credit ? 'Credit note' : 'Invoice',
                        credit ? 0 : i.Total__c, credit ? i.Total__c : 0));
                }
            }
        }
        if (p.Is_Supplier__c && Schema.SObjectType.Supplier_Bill__c.isAccessible()) {
            for (Supplier_Bill__c b : [SELECT Id, Name, Vendor_Reference__c, Document_Date__c, Due_Date__c, Total__c, Status__c FROM Supplier_Bill__c
                    WHERE Supplier_Profile__c = :profileId WITH USER_MODE ORDER BY Document_Date__c DESC LIMIT 200]) {
                String reference = String.isBlank(b.Vendor_Reference__c) ? b.Name : b.Name + ' (' + b.Vendor_Reference__c + ')';
                detail.documents.add(doc(b.Id, reference, 'Bill', b.Document_Date__c, b.Due_Date__c, b.Total__c, b.Status__c));
                if (b.Status__c == 'Posted' || b.Status__c == 'Paid' || b.Status__c == 'Part Paid') {
                    entries.add(entry(b.Document_Date__c, reference, 'Bill', b.Total__c, 0));
                }
            }
        }
        if (Schema.SObjectType.Accounting_Payment__c.isAccessible()) {
            for (Accounting_Payment__c pay : [SELECT Id, Name, Direction__c, Effective_Date__c, Amount__c, Processing_State__c FROM Accounting_Payment__c
                    WHERE Party_Profile__c = :profileId WITH USER_MODE ORDER BY Effective_Date__c DESC LIMIT 200]) {
                detail.payments.add(doc(pay.Id, pay.Name, pay.Direction__c, pay.Effective_Date__c, null, pay.Amount__c, pay.Processing_State__c));
                if (pay.Processing_State__c == 'Succeeded') {
                    entries.add(entry(pay.Effective_Date__c, pay.Name, pay.Direction__c == 'Receipt' ? 'Receipt' : 'Payment', 0, pay.Amount__c));
                }
            }
        }
        detail.statement = runningBalance(entries);
        return detail;
    }

    /** Oldest first with a running balance: charges (invoices or bills) add, receipts, payments and credits reduce. */
    @TestVisible
    private static List<StatementRow> runningBalance(List<StatementRow> entries) {
        List<StatementRow> sorted = new List<StatementRow>();
        List<String> keys = new List<String>();
        Map<String, StatementRow> byKey = new Map<String, StatementRow>();
        for (Integer i = 0; i < entries.size(); i++) {
            StatementRow e = entries[i];
            String k = (e.entryDate == null ? '0000-00-00' : String.valueOf(e.entryDate)) + '|' + String.valueOf(10000 + i);
            keys.add(k);
            byKey.put(k, e);
        }
        keys.sort();
        Decimal balance = 0;
        for (String k : keys) {
            StatementRow e = byKey.get(k);
            balance += zero(e.charge) - zero(e.paid);
            e.balance = balance;
            sorted.add(e);
        }
        return sorted;
    }

    @AuraEnabled
    public static FormOptions getFormOptions(Id companyId) {
        assertCompany(companyId);
        Store store = new Store();
        FormOptions o = new FormOptions();
        o.canManage = canManage();
        o.functionalCurrency = store.company(companyId).Functional_Currency__c;
        o.arControls = new List<Option>();
        o.apControls = new List<Option>();
        o.revenueAccounts = new List<Option>();
        o.expenseAccounts = new List<Option>();
        for (GL_Account__c a : store.accounts(companyId)) {
            Option option = new Option(a.Id, a.Account_Code__c + ' ' + a.Name);
            if (a.Control_Type__c == 'AR') {
                o.arControls.add(option);
            } else if (a.Control_Type__c == 'AP') {
                o.apControls.add(option);
            } else if (!a.Is_Control_Account__c && a.Account_Type__c == 'Revenue') {
                o.revenueAccounts.add(option);
            } else if (!a.Is_Control_Account__c && a.Account_Type__c == 'Expense') {
                o.expenseAccounts.add(option);
            }
        }
        o.defaultArControlId = o.arControls.isEmpty() ? null : Id.valueOf(o.arControls[0].value);
        o.defaultApControlId = o.apControls.isEmpty() ? null : Id.valueOf(o.apControls[0].value);
        o.taxCodes = new List<Option>();
        for (Tax_Code__c t : store.taxCodes(companyId)) {
            o.taxCodes.add(new Option(t.Id, t.Code__c + (String.isBlank(t.Name) || t.Name == t.Code__c ? '' : ' ' + t.Name)));
        }
        o.paymentTerms = new List<Option>();
        for (Payment_Term__c t : store.terms(companyId)) {
            o.paymentTerms.add(new Option(t.Id, t.Name + (t.Due_Days__c == null ? '' : ' (' + t.Due_Days__c.intValue() + ' days)')));
            if (o.defaultPaymentTermId == null && t.Due_Days__c == 30) {
                o.defaultPaymentTermId = t.Id;
            }
        }
        if (o.defaultPaymentTermId == null && !o.paymentTerms.isEmpty()) {
            o.defaultPaymentTermId = Id.valueOf(o.paymentTerms[0].value);
        }
        o.paymentMethods = new List<String>();
        for (Schema.PicklistEntry e : Party_Accounting_Profile__c.Preferred_Payment_Method__c.getDescribe().getPicklistValues()) {
            if (e.isActive()) {
                o.paymentMethods.add(e.getValue());
            }
        }
        return o;
    }

    // ----------------------------------------------------------------- writes

    @AuraEnabled
    public static SaveResult saveContact(ContactRequest request, Boolean confirmDuplicate, String requestKey) {
        String key = requireKey(requestKey);
        if (request == null) {
            throw new ContactException('Contact details are required.');
        }
        Store store = new Store();
        Party_Accounting_Profile__c existing = request.profileId == null ? null : store.profile(request.profileId);
        Id companyId = existing == null ? request.companyId : existing.Company__c;
        assertManage(companyId);
        SaveResult result = new SaveResult();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            result.profileId = Id.valueOf(prior.Source_Record_Id__c);
            return result;
        }
        Boolean customer = request.isCustomer == true;
        Boolean supplier = request.isSupplier == true;
        if (!customer && !supplier) {
            throw new ContactException('Choose customer, supplier or both.');
        }
        String name = requireText(request.name, 'Name');
        if (confirmDuplicate != true) {
            String warning = store.duplicateWarning(companyId, name, request.taxNumber, request.profileId, customer);
            if (warning != null) {
                result.duplicateWarning = warning;
                return result;
            }
        }
        FormOptions options = getFormOptions(companyId);
        Id arControl = customer ? pick(request.arControlId, options.defaultArControlId, options.arControls,
            'Add an active accounts receivable control account in Chart of accounts first.', 'The AR control account must be an AR control account of this company.') : null;
        Id apControl = supplier ? pick(request.apControlId, options.defaultApControlId, options.apControls,
            'Add an active accounts payable control account in Chart of accounts first.', 'The AP control account must be an AP control account of this company.') : null;
        assertIn(request.revenueAccountId, options.revenueAccounts, 'The default revenue account must be an active revenue account of this company.');
        assertIn(request.expenseAccountId, options.expenseAccounts, 'The default expense account must be an active expense account of this company.');
        assertIn(request.taxCodeId, options.taxCodes, 'The tax code must be an active tax code of this company.');
        Id termId = request.paymentTermId == null && existing == null ? options.defaultPaymentTermId : request.paymentTermId;
        assertIn(termId, options.paymentTerms, 'The payment term must be an active payment term of this company.');
        String currencyCode = String.isBlank(request.currencyCode) ? null : request.currencyCode.trim().toUpperCase();
        if (currencyCode != null && !Pattern.matches('[A-Z]{3}', currencyCode)) {
            throw new ContactException('Currency must be a three-letter code.');
        }
        if (request.creditLimit != null && request.creditLimit < 0) {
            throw new ContactException('The credit limit cannot be negative.');
        }
        Account account = new Account(Id = existing == null ? null : existing.Account__c, Name = name.left(255), Phone = blank(request.phone),
            BillingStreet = blank(request.billingStreet), BillingCity = blank(request.billingCity), BillingState = blank(request.billingState),
            BillingPostalCode = blank(request.billingPostalCode), BillingCountry = blank(request.billingCountry),
            ShippingStreet = customer ? blank(request.shippingStreet) : null, ShippingCity = customer ? blank(request.shippingCity) : null,
            ShippingState = customer ? blank(request.shippingState) : null, ShippingPostalCode = customer ? blank(request.shippingPostalCode) : null,
            ShippingCountry = customer ? blank(request.shippingCountry) : null);
        Party_Accounting_Profile__c profile = new Party_Accounting_Profile__c(Id = existing == null ? null : existing.Id, Is_Customer__c = customer, Is_Supplier__c = supplier,
            Display_Name__c = blank(request.displayName), Email__c = blank(request.email), Phone__c = blank(request.phone),
            Tax_Registration_Number__c = blank(request.taxNumber), Default_Tax_Code__c = request.taxCodeId, Payment_Term__c = termId, Currency__c = currencyCode,
            Credit_Limit__c = customer ? request.creditLimit : null, AR_Control_Account__c = arControl, AP_Control_Account__c = apControl,
            Default_Revenue_Account__c = customer ? request.revenueAccountId : null, Default_Expense_Account__c = supplier ? request.expenseAccountId : null,
            Preferred_Payment_Method__c = blank(request.paymentMethod),
            Bank_Account_Name__c = supplier ? blank(request.bankAccountName) : null, Bank_Account_Number__c = supplier ? blank(request.bankAccountNumber) : null,
            Bank_Routing_Code__c = supplier ? blank(request.bankRoutingCode) : null);
        if (existing == null) {
            profile.Company__c = companyId;
            profile.Is_Active__c = true;
        }
        List<Business_Action__c> audits = new List<Business_Action__c>{
            audit(companyId, existing == null ? 'CONTACT_CREATED' : 'CONTACT_UPDATED', key, (existing == null ? 'Created ' : 'Updated ') + name) };
        String bankChange = bankChange(existing, profile);
        if (bankChange != null) {
            audits.add(audit(companyId, 'CONTACT_BANK_DETAILS_CHANGED', key + '-BANK', name + ': ' + bankChange));
        }
        new Writer().save(account, profile, store.companyKey(companyId), audits);
        result.profileId = profile.Id;
        return result;
    }

    @AuraEnabled
    public static SaveResult quickAdd(Id companyId, String name, String email, Boolean isCustomer, Boolean isSupplier, Boolean confirmDuplicate, String requestKey) {
        ContactRequest request = new ContactRequest();
        request.companyId = companyId;
        request.name = name;
        request.email = email;
        request.isCustomer = isCustomer == true;
        request.isSupplier = isSupplier == true;
        return saveContact(request, confirmDuplicate, requestKey);
    }

    @AuraEnabled
    public static Id setActive(Id profileId, Boolean active, String requestKey) {
        String key = requireKey(requestKey);
        Store store = new Store();
        Party_Accounting_Profile__c p = store.profile(profileId);
        assertManage(p.Company__c);
        if (store.action(key) != null) {
            return profileId;
        }
        String name = p.Account__r == null ? '' : p.Account__r.Name;
        new Writer().setActive(new Party_Accounting_Profile__c(Id = profileId, Is_Active__c = active == true),
            audit(p.Company__c, active == true ? 'CONTACT_REACTIVATED' : 'CONTACT_DEACTIVATED', key, (active == true ? 'Reactivated ' : 'Deactivated ') + name));
        return profileId;
    }

    // ---------------------------------------------------------------- helpers

    public static Boolean canManage() {
        return SABPermissionService.hasPermission(MANAGE_PERMISSION);
    }

    private static ContactRequest toRequest(Party_Accounting_Profile__c p, Boolean showBank) {
        ContactRequest r = new ContactRequest();
        r.profileId = p.Id;
        r.companyId = p.Company__c;
        r.name = p.Account__r == null ? null : p.Account__r.Name;
        r.displayName = p.Display_Name__c;
        r.email = p.Email__c;
        r.phone = String.isNotBlank(p.Phone__c) ? p.Phone__c : (p.Account__r == null ? null : p.Account__r.Phone);
        if (p.Account__r != null) {
            r.billingStreet = p.Account__r.BillingStreet;
            r.billingCity = p.Account__r.BillingCity;
            r.billingState = p.Account__r.BillingState;
            r.billingPostalCode = p.Account__r.BillingPostalCode;
            r.billingCountry = p.Account__r.BillingCountry;
            r.shippingStreet = p.Account__r.ShippingStreet;
            r.shippingCity = p.Account__r.ShippingCity;
            r.shippingState = p.Account__r.ShippingState;
            r.shippingPostalCode = p.Account__r.ShippingPostalCode;
            r.shippingCountry = p.Account__r.ShippingCountry;
        }
        r.taxNumber = p.Tax_Registration_Number__c;
        r.taxCodeId = p.Default_Tax_Code__c;
        r.paymentTermId = p.Payment_Term__c;
        r.currencyCode = p.Currency__c;
        r.creditLimit = p.Credit_Limit__c;
        r.isCustomer = p.Is_Customer__c == true;
        r.isSupplier = p.Is_Supplier__c == true;
        r.arControlId = p.AR_Control_Account__c;
        r.apControlId = p.AP_Control_Account__c;
        r.revenueAccountId = p.Default_Revenue_Account__c;
        r.expenseAccountId = p.Default_Expense_Account__c;
        r.paymentMethod = p.Preferred_Payment_Method__c;
        r.bankAccountName = p.Bank_Account_Name__c;
        // Only people who can manage contacts see the full account number; everyone else sees the last four digits.
        r.bankAccountNumber = showBank ? p.Bank_Account_Number__c : mask(p.Bank_Account_Number__c);
        r.bankRoutingCode = p.Bank_Routing_Code__c;
        return r;
    }

    @TestVisible
    private static String mask(String value) {
        if (String.isBlank(value)) {
            return value;
        }
        return value.length() <= 4 ? '****' : '****' + value.right(4);
    }

    private static String bankChange(Party_Accounting_Profile__c existing, Party_Accounting_Profile__c next) {
        String before = existing == null ? '' : String.join(new List<String>{ s(existing.Bank_Account_Name__c), s(existing.Bank_Account_Number__c), s(existing.Bank_Routing_Code__c) }, '|');
        String after = String.join(new List<String>{ s(next.Bank_Account_Name__c), s(next.Bank_Account_Number__c), s(next.Bank_Routing_Code__c) }, '|');
        if (before == after || (existing == null && after == '||')) {
            return null;
        }
        return 'bank details changed from ' + (existing == null || String.isBlank(existing.Bank_Account_Number__c) ? 'none' : mask(existing.Bank_Account_Number__c))
            + ' to ' + (String.isBlank(next.Bank_Account_Number__c) ? 'none' : mask(next.Bank_Account_Number__c));
    }

    private static Id pick(Id requested, Id fallback, List<Option> allowed, String missing, String invalid) {
        Id chosen = requested == null ? fallback : requested;
        if (chosen == null) {
            throw new ContactException(missing);
        }
        assertIn(chosen, allowed, invalid);
        return chosen;
    }

    private static void assertIn(Id value, List<Option> allowed, String message) {
        if (value == null) {
            return;
        }
        for (Option o : allowed) {
            if (o.value == String.valueOf(value)) {
                return;
            }
        }
        throw new ContactException(message);
    }

    private static DocumentRow doc(Id recordId, String reference, String kind, Date documentDate, Date dueDate, Decimal amount, String status) {
        DocumentRow row = new DocumentRow();
        row.recordId = recordId;
        row.reference = reference;
        row.kind = kind;
        row.documentDate = documentDate;
        row.dueDate = dueDate;
        row.amount = amount;
        row.status = status;
        return row;
    }

    private static StatementRow entry(Date entryDate, String reference, String description, Decimal charge, Decimal paid) {
        StatementRow row = new StatementRow();
        row.entryDate = entryDate;
        row.reference = reference;
        row.description = description;
        row.charge = zero(charge);
        row.paid = zero(paid);
        return row;
    }

    private static void assertCompany(Id companyId) {
        if (companyId == null || !SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw new ContactException('You do not have active access to this Accounting Company.');
        }
    }

    private static void assertManage(Id companyId) {
        assertCompany(companyId);
        if (!canManage()) {
            throw new ContactException('You do not have permission to manage customers and suppliers. Ask for the SAB Manage Contacts Action permission set.');
        }
    }

    private static String requireText(String value, String label) {
        if (String.isBlank(value)) {
            throw new ContactException(label + ' is required.');
        }
        return value.trim();
    }

    private static String requireKey(String requestKey) {
        if (String.isBlank(requestKey) || requestKey.trim().length() > 150) {
            throw new ContactException('A request key of up to 150 characters is required.');
        }
        return requestKey.trim();
    }

    private static String blank(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    private static String s(String value) {
        return value == null ? '' : value;
    }

    private static Decimal zero(Decimal value) {
        return value == null ? 0 : value;
    }

    private static Business_Action__c audit(Id companyId, String actionName, String key, String reason) {
        return new Business_Action__c(Company__c = companyId, Action__c = actionName, Actor__c = UserInfo.getUserId(), Action_At__c = System.now(),
            Reason__c = reason.left(255), Request_Key__c = key.left(160), Source_Type__c = 'Party_Accounting_Profile__c', Source_Version__c = 1);
    }

    // System reads after the company and permission checks.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Source_Record_Id__c FROM Business_Action__c WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }

        Accounting_Company__c company(Id companyId) {
            return [SELECT Id, Functional_Currency__c, Company_Key__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE LIMIT 1];
        }

        String companyKey(Id companyId) {
            return company(companyId).Company_Key__c;
        }

        List<Party_Accounting_Profile__c> profiles(Id companyId, Boolean customers) {
            Boolean suppliers = !customers;
            return [SELECT Id, Account__c, Account__r.Name, Account__r.Phone, Display_Name__c, Email__c, Phone__c, Is_Customer__c, Is_Supplier__c,
                    Is_Active__c, Currency__c FROM Party_Accounting_Profile__c
                WHERE Company__c = :companyId AND ((Is_Customer__c = true AND Is_Customer__c = :customers) OR (Is_Supplier__c = true AND Is_Supplier__c = :suppliers))
                WITH SYSTEM_MODE ORDER BY Account__r.Name LIMIT :MAX_ROWS];
        }

        Party_Accounting_Profile__c profile(Id profileId) {
            List<Party_Accounting_Profile__c> rows = [SELECT Id, Company__c, Account__c, Account__r.Name, Account__r.Phone, Account__r.BillingStreet,
                    Account__r.BillingCity, Account__r.BillingState, Account__r.BillingPostalCode, Account__r.BillingCountry, Account__r.ShippingStreet,
                    Account__r.ShippingCity, Account__r.ShippingState, Account__r.ShippingPostalCode, Account__r.ShippingCountry, Display_Name__c, Email__c,
                    Phone__c, Is_Customer__c, Is_Supplier__c, Is_Active__c, Currency__c, Tax_Registration_Number__c, Default_Tax_Code__c,
                    Default_Tax_Code__r.Code__c, Payment_Term__c, Payment_Term__r.Name, Credit_Limit__c, AR_Control_Account__c, AP_Control_Account__c,
                    Default_Revenue_Account__c, Default_Expense_Account__c, Preferred_Payment_Method__c, Bank_Account_Name__c, Bank_Account_Number__c,
                    Bank_Routing_Code__c
                FROM Party_Accounting_Profile__c WHERE Id = :profileId WITH SYSTEM_MODE LIMIT 1];
            if (rows.isEmpty()) {
                throw new ContactException('The customer or supplier was not found.');
            }
            return rows[0];
        }

        String duplicateWarning(Id companyId, String name, String taxNumber, Id selfId, Boolean customer) {
            String tax = String.isBlank(taxNumber) ? null : taxNumber.trim();
            for (Party_Accounting_Profile__c p : [SELECT Id, Account__r.Name, Tax_Registration_Number__c, Is_Customer__c FROM Party_Accounting_Profile__c
                    WHERE Company__c = :companyId AND Id != :selfId AND (Account__r.Name = :name OR (Tax_Registration_Number__c != null AND Tax_Registration_Number__c = :tax))
                    WITH SYSTEM_MODE LIMIT 1]) {
                String noun = p.Is_Customer__c ? 'customer' : 'supplier';
                if (p.Account__r != null && p.Account__r.Name != null && p.Account__r.Name.equalsIgnoreCase(name)) {
                    return 'A ' + noun + ' called ' + p.Account__r.Name + ' already exists. If it is the same business, edit it and tick both customer and supplier instead.';
                }
                return 'A ' + noun + ' with tax number ' + p.Tax_Registration_Number__c + ' already exists: ' + (p.Account__r == null ? '' : p.Account__r.Name) + '.';
            }
            return null;
        }

        List<GL_Account__c> accounts(Id companyId) {
            return [SELECT Id, Account_Code__c, Name, Account_Type__c, Control_Type__c, Is_Control_Account__c FROM GL_Account__c
                WHERE Company__c = :companyId AND Is_Active__c = true WITH SYSTEM_MODE ORDER BY Account_Code__c LIMIT 2000];
        }

        List<Tax_Code__c> taxCodes(Id companyId) {
            return [SELECT Id, Code__c, Name FROM Tax_Code__c WHERE Company__c = :companyId AND Is_Active__c = true WITH SYSTEM_MODE ORDER BY Code__c LIMIT 500];
        }

        List<Payment_Term__c> terms(Id companyId) {
            return [SELECT Id, Name, Due_Days__c FROM Payment_Term__c WHERE Company__c = :companyId AND Is_Active__c = true WITH SYSTEM_MODE ORDER BY Due_Days__c, Name LIMIT 200];
        }
    }

    // System writes after the company and permission checks.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void save(Account account, Party_Accounting_Profile__c profile, String companyKey, List<Business_Action__c> audits) {
            Savepoint sp = Database.setSavepoint();
            try {
                upsert as system account;
                if (profile.Id == null) {
                    profile.Account__c = account.Id;
                    profile.Profile_Key__c = (companyKey + '-' + account.Id).left(180);
                    insert as system profile;
                } else {
                    update as system profile;
                }
                for (Business_Action__c a : audits) {
                    a.Source_Record_Id__c = String.valueOf(profile.Id);
                }
                insert as system audits;
            } catch (DmlException ex) {
                Database.rollback(sp);
                throw new ContactException(ex.getDmlMessage(0));
            }
        }

        void setActive(Party_Accounting_Profile__c profile, Business_Action__c entry) {
            update as system profile;
            entry.Source_Record_Id__c = String.valueOf(profile.Id);
            insert as system entry;
        }
    }
}