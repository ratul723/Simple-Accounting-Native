@IsTest
private class SABDocumentEntryServiceTest {

    private static final String KEY = 'G22DE';
    private static final String APPROVER = 'SAB G22DE Approver';

    @TestSetup
    static void setupData() {
        User approverUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            approverUser = new User(Username = 'g22deap.' + unique + '@example.invalid', Email = 'g22deap@example.invalid', LastName = APPROVER, Alias = 'g22deap',
                TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US', ProfileId = UserInfo.getProfileId());
            insert as system approverUser;
            Map<String, Id> sets = new Map<String, Id>();
            for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN ('SAB_Approve_Financial_Document_Action', 'SAB_Submit_Expense_Claim_Action') WITH SYSTEM_MODE]) {
                sets.put(p.Name, p.Id);
            }
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>{
                new PermissionSetAssignment(AssigneeId = approverUser.Id, PermissionSetId = sets.get('SAB_Approve_Financial_Document_Action')) };
            if (![SELECT Id FROM PermissionSetAssignment WHERE AssigneeId = :UserInfo.getUserId() AND PermissionSetId = :sets.get('SAB_Submit_Expense_Claim_Action') WITH SYSTEM_MODE].isEmpty()) {
                sets.remove('SAB_Submit_Expense_Claim_Action');
            } else {
                assignments.add(new PermissionSetAssignment(AssigneeId = UserInfo.getUserId(), PermissionSetId = sets.get('SAB_Submit_Expense_Claim_Action')));
            }
            insert as system assignments;
        }
        // A separate runAs block keeps the business fixture apart from the user and permission set DML above.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'Document Entry Co', Company_Key__c = KEY, Country_Code__c = 'BD', Functional_Currency__c = 'BDT',
                Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active', Is_Active__c = true);
            insert as system company;
            insert as system new List<Company_User_Access__c>{
                new Company_User_Access__c(Company__c = company.Id, User__c = UserInfo.getUserId(), Effective_From__c = Date.today(), Grant_Key__c = 'G22DE-ME', Is_Active__c = true,
                    Role__c = 'Finance Manager'),
                new Company_User_Access__c(Company__c = company.Id, User__c = approverUser.Id, Effective_From__c = Date.today(), Grant_Key__c = 'G22DE-APPROVER', Is_Active__c = true,
                    Role__c = 'Director') };
            Account customer = new Account(Name = 'G22DE Customer');
            Account supplier = new Account(Name = 'G22DE Supplier');
            insert as system new List<Account>{ customer, supplier };
            List<GL_Account__c> accounts = new List<GL_Account__c>{
                gl(company.Id, '1000', 'Bank', 'Asset', 'Debit', 'None', false), gl(company.Id, '1200', 'Receivables', 'Asset', 'Debit', 'AR', true),
                gl(company.Id, '2100', 'Payables', 'Liability', 'Credit', 'AP', true), gl(company.Id, '4000', 'Sales', 'Revenue', 'Credit', 'None', false),
                gl(company.Id, '6000', 'Office', 'Expense', 'Debit', 'None', false) };
            insert as system accounts;
            insert as system new List<Party_Accounting_Profile__c>{
                new Party_Accounting_Profile__c(Company__c = company.Id, Account__c = customer.Id, Profile_Key__c = 'G22DE-C', Is_Customer__c = true, Is_Supplier__c = false,
                    Is_Active__c = true, AR_Control_Account__c = accounts[1].Id),
                new Party_Accounting_Profile__c(Company__c = company.Id, Account__c = supplier.Id, Profile_Key__c = 'G22DE-S', Is_Customer__c = false, Is_Supplier__c = true,
                    Is_Active__c = true, AP_Control_Account__c = accounts[2].Id) };
            insert as system new Bank_Account__c(Name = 'G22DE Bank', Company__c = company.Id, Bank_Name__c = 'Test', Currency__c = 'BDT', GL_Account__c = accounts[0].Id, Is_Active__c = true);
            Employee__c employee = new Employee__c(Employee_Reference__c = 'G22DE-EMP', Status__c = 'Active', User__c = UserInfo.getUserId());
            insert as system employee;
            insert as system new Employment__c(Employee__c = employee.Id, Company__c = company.Id, Start_Date__c = Date.today().addYears(-1), Employment_Status__c = 'Active');
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static GL_Account__c gl(Id companyId, String code, String name, String type, String balance, String control, Boolean isControl) {
        return new GL_Account__c(Name = name, Company__c = companyId, Company_Account_Key__c = KEY + '-' + code, Account_Code__c = code, Account_Type__c = type,
            Normal_Balance__c = balance, Is_Active__c = true, Control_Type__c = control, Is_Control_Account__c = isControl, Manual_Posting_Allowed__c = !isControl);
    }

    private static Id companyId() {
        return [SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = :KEY WITH SYSTEM_MODE LIMIT 1].Id;
    }

    private static Id account(String code) {
        return [SELECT Id FROM GL_Account__c WHERE Company_Account_Key__c = :(KEY + '-' + code) WITH SYSTEM_MODE LIMIT 1].Id;
    }

    private static Id profile(String profileKey) {
        return [SELECT Id FROM Party_Accounting_Profile__c WHERE Profile_Key__c = :profileKey WITH SYSTEM_MODE LIMIT 1].Id;
    }

    private static SABDocumentEntryService.LineRequest line(String description, Decimal quantity, Decimal price, Id accountId) {
        SABDocumentEntryService.LineRequest l = new SABDocumentEntryService.LineRequest();
        l.description = description;
        l.quantity = quantity;
        l.unitPrice = price;
        l.amount = price;
        l.accountId = accountId;
        l.category = 'Travel';
        return l;
    }

    private static SABDocumentEntryService.DocumentRequest invoiceRequest(Id companyId) {
        SABDocumentEntryService.DocumentRequest r = new SABDocumentEntryService.DocumentRequest();
        r.companyId = companyId;
        r.partyProfileId = profile('G22DE-C');
        r.documentDate = Date.today();
        r.dueDate = Date.today().addDays(30);
        r.lines = new List<SABDocumentEntryService.LineRequest>{ line('Consulting', 2, 150, account('4000')), line('Travel', 1, 50, account('4000')) };
        return r;
    }

    @IsTest
    static void optionsListPartiesAccountsAndEmployment() {
        SABDocumentEntryService.EntryOptions o;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            o = SABDocumentEntryService.getEntryOptions(companyId());
            Test.stopTest();
        }
        System.assertEquals('BDT', o.currencyCode, 'Functional currency.');
        System.assertEquals(1, o.customers.size(), 'One customer.');
        System.assertEquals(1, o.suppliers.size(), 'One supplier.');
        System.assertEquals(1, o.revenueAccounts.size(), 'Revenue accounts exclude control accounts.');
        System.assertEquals(2, o.expenseAccounts.size(), 'Expense and asset accounts.');
        System.assertEquals(1, o.bankAccounts.size(), 'One bank account.');
        System.assertNotEquals(null, o.myEmploymentId, 'The running user has an employment.');
        System.assert(o.canCreateInvoice && o.canCreateClaim, 'The running user can enter documents.');
        System.assert(!o.methods.isEmpty(), 'Payment methods from the picklist.');
    }

    @IsTest
    static void invoicesAreSavedEditedSubmittedAndApprovedByAnotherUser() {
        Id companyId = companyId();
        Id invoiceId;
        Id replayId;
        String selfApproval;
        String status;
        SABDocumentEntryService.DraftView draft;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            invoiceId = SABDocumentEntryService.saveInvoice(invoiceRequest(companyId), 'G22DE-INV-1');
            replayId = SABDocumentEntryService.saveInvoice(invoiceRequest(companyId), 'G22DE-INV-1');
            SABDocumentEntryService.DocumentRequest edit = invoiceRequest(companyId);
            edit.recordId = invoiceId;
            edit.lines.remove(1);
            SABDocumentEntryService.saveInvoice(edit, 'G22DE-INV-2');
            draft = SABDocumentEntryService.getDraft(companyId, invoiceId);
            SABDocumentEntryService.submitInvoice(invoiceId, 'G22DE-INV-SUBMIT');
            try {
                SABDocumentEntryService.approveInvoice(invoiceId, 'G22DE-INV-SELF');
            } catch (Exception ex) {
                selfApproval = ex.getMessage();
            }
            Test.stopTest();
        }
        User approverUser = [SELECT Id FROM User WHERE LastName = :APPROVER WITH SYSTEM_MODE LIMIT 1];
        System.runAs(approverUser) {
            status = SABDocumentEntryService.approveInvoice(invoiceId, 'G22DE-INV-APPROVE');
        }
        Invoice__c invoice = [SELECT Status__c, Subtotal__c, Total__c, Transaction_Currency__c, Exchange_Rate__c FROM Invoice__c WHERE Id = :invoiceId WITH SYSTEM_MODE];
        System.assertEquals(invoiceId, replayId, 'The same request key returns the same invoice.');
        System.assertEquals(1, draft.document.lines.size(), 'Lines were replaced on edit.');
        System.assertEquals(300, invoice.Subtotal__c, 'Totals from the tax service.');
        System.assertEquals('BDT', invoice.Transaction_Currency__c, 'Functional currency by default.');
        System.assertEquals(1, invoice.Exchange_Rate__c, 'Rate 1 in functional currency.');
        System.assertEquals('An invoice must be approved by someone other than the person who created it.', selfApproval, 'Maker and checker differ.');
        System.assertEquals('Approved', status, 'Approved by the second user.');
        System.assertEquals('Approved', invoice.Status__c, 'Invoice approved.');
        System.assertEquals(4, [SELECT COUNT() FROM Business_Action__c WHERE Source_Record_Id__c = :String.valueOf(invoiceId) WITH SYSTEM_MODE], 'Saves and transitions audited.');
    }

    @IsTest
    static void invoiceInputIsValidated() {
        Id companyId = companyId();
        List<String> messages = new List<String>();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            SABDocumentEntryService.DocumentRequest credit = invoiceRequest(companyId);
            credit.documentType = 'Credit Note';
            messages.add(capture(credit, 'G22DE-V1'));
            SABDocumentEntryService.DocumentRequest noLines = invoiceRequest(companyId);
            noLines.lines.clear();
            messages.add(capture(noLines, 'G22DE-V2'));
            SABDocumentEntryService.DocumentRequest foreign = invoiceRequest(companyId);
            foreign.currencyCode = 'usd';
            messages.add(capture(foreign, 'G22DE-V3'));
            SABDocumentEntryService.DocumentRequest noAccount = invoiceRequest(companyId);
            noAccount.lines[0].accountId = null;
            messages.add(capture(noAccount, 'G22DE-V4'));
            SABDocumentEntryService.DocumentRequest wrongType = invoiceRequest(companyId);
            wrongType.documentType = 'Bill';
            messages.add(capture(wrongType, 'G22DE-V5'));
            messages.add(capture(invoiceRequest(companyId), ''));
            SABDocumentEntryService.DocumentRequest noCompany = invoiceRequest(companyId);
            noCompany.companyId = null;
            messages.add(capture(noCompany, 'G22DE-V6'));
            foreign.exchangeRate = 0.0092;
            messages.add(capture(foreign, 'G22DE-V7'));
            Test.stopTest();
        }
        System.assertEquals('Choose the invoice this credit note reduces.', messages[0], 'Credit notes need their invoice.');
        System.assertEquals('Add at least one line.', messages[1], 'Lines are required.');
        System.assertEquals('Enter the exchange rate for a foreign-currency document.', messages[2], 'Foreign currency needs a rate.');
        System.assertEquals('Revenue account is required.', messages[3], 'Revenue account is required.');
        System.assertEquals('Document type must be Invoice or Credit Note.', messages[4], 'Invoice types only.');
        System.assertEquals('A request key of up to 160 characters is required.', messages[5], 'Request key.');
        System.assertEquals('Accounting Company is required.', messages[6], 'Company.');
        System.assertEquals(null, messages[7], 'A foreign-currency invoice with a rate is saved.');
    }

    @IsTest
    static void billsPaymentsAndClaimsAreSaved() {
        Id companyId = companyId();
        Id billId;
        Id paymentId;
        Id claimId;
        String locked;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            SABDocumentEntryService.DocumentRequest bill = new SABDocumentEntryService.DocumentRequest();
            bill.companyId = companyId;
            bill.partyProfileId = profile('G22DE-S');
            bill.documentDate = Date.today();
            bill.reference = 'SUP-INV-9';
            bill.lines = new List<SABDocumentEntryService.LineRequest>{ line('Paper', 10, 5, account('6000')) };
            billId = SABDocumentEntryService.saveBill(bill, 'G22DE-BILL-1');
            bill.recordId = billId;
            bill.lines[0].quantity = 20;
            SABDocumentEntryService.saveBill(bill, 'G22DE-BILL-2');

            SABDocumentEntryService.PaymentRequest payment = new SABDocumentEntryService.PaymentRequest();
            payment.companyId = companyId;
            payment.direction = 'Receipt';
            payment.partyProfileId = profile('G22DE-C');
            payment.bankAccountId = [SELECT Id FROM Bank_Account__c WHERE Name = 'G22DE Bank' WITH SYSTEM_MODE LIMIT 1].Id;
            payment.amount = 300;
            payment.effectiveDate = Date.today();
            payment.method = 'Bank Transfer';
            paymentId = SABDocumentEntryService.savePayment(payment, 'G22DE-PAY-1');
            payment.recordId = paymentId;
            payment.amount = 350;
            SABDocumentEntryService.savePayment(payment, 'G22DE-PAY-2');

            SABDocumentEntryService.ClaimRequest claim = new SABDocumentEntryService.ClaimRequest();
            claim.companyId = companyId;
            claim.employmentId = [SELECT Id FROM Employment__c WHERE Company__c = :companyId WITH SYSTEM_MODE LIMIT 1].Id;
            claim.claimDate = Date.today();
            claim.lines = new List<SABDocumentEntryService.LineRequest>{ line('Taxi', null, 45, account('6000')) };
            claimId = SABDocumentEntryService.saveExpenseClaim(claim, 'G22DE-CLAIM-1');
            SABDocumentEntryService.DraftView claimDraft = SABDocumentEntryService.getDraft(companyId, claimId);
            System.assertEquals(1, claimDraft.claim.lines.size(), 'Claim line read back.');
            System.assertEquals(350, SABDocumentEntryService.getDraft(companyId, paymentId).payment.amount, 'Payment read back.');
            System.assertEquals(200, SABDocumentEntryService.getDraft(companyId, billId).document.lines[0].quantity * 10, 'Bill read back.');
            try {
                SABDocumentEntryService.getDraft(companyId, companyId);
            } catch (AuraHandledException ex) {
                locked = ex.getMessage();
            }
            Test.stopTest();
        }
        Supplier_Bill__c saved = [SELECT Status__c, Subtotal__c, Vendor_Reference__c FROM Supplier_Bill__c WHERE Id = :billId WITH SYSTEM_MODE];
        System.assertEquals('Draft', saved.Status__c, 'Bills start in Draft.');
        System.assertEquals(100, saved.Subtotal__c, 'Totals from the edited line.');
        System.assertEquals('SUP-INV-9', saved.Vendor_Reference__c, 'Supplier reference.');
        Accounting_Payment__c pay = [SELECT Processing_State__c, Amount__c, Direction__c FROM Accounting_Payment__c WHERE Id = :paymentId WITH SYSTEM_MODE];
        System.assertEquals('Draft', pay.Processing_State__c, 'Payments start in Draft.');
        System.assertEquals(350, pay.Amount__c, 'Edited amount.');
        System.assertEquals('Draft', [SELECT Status__c FROM Expense_Claim__c WHERE Id = :claimId WITH SYSTEM_MODE].Status__c, 'Claims start in Draft.');
        System.assertEquals('This document cannot be edited here.', locked, 'Only documents can be read as drafts.');
    }

    @IsTest
    static void paymentAndClaimInputIsValidated() {
        Id companyId = companyId();
        List<String> messages = new List<String>();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Test.startTest();
            SABDocumentEntryService.PaymentRequest payment = new SABDocumentEntryService.PaymentRequest();
            payment.companyId = companyId;
            payment.direction = 'Sideways';
            messages.add(capturePayment(payment));
            payment.direction = 'Disbursement';
            payment.amount = 0;
            messages.add(capturePayment(payment));
            payment.amount = 10;
            messages.add(capturePayment(payment));
            SABDocumentEntryService.ClaimRequest claim = new SABDocumentEntryService.ClaimRequest();
            claim.companyId = companyId;
            claim.claimDate = Date.today();
            claim.lines = new List<SABDocumentEntryService.LineRequest>{ line('Taxi', null, 0, account('6000')) };
            claim.employmentId = [SELECT Id FROM Employment__c WHERE Company__c = :companyId WITH SYSTEM_MODE LIMIT 1].Id;
            try {
                SABDocumentEntryService.saveExpenseClaim(claim, 'G22DE-CLAIM-BAD');
            } catch (Exception ex) {
                messages.add(ex.getMessage());
            }
            try {
                SABDocumentEntryService.getEntryOptions(null);
            } catch (Exception ex) {
                messages.add(ex.getMessage());
            }
            Test.stopTest();
        }
        System.assertEquals('Direction must be Receipt or Disbursement.', messages[0], 'Direction.');
        System.assertEquals('Amount must be greater than zero.', messages[1], 'Amount.');
        System.assertEquals('Supplier is required.', messages[2], 'Party.');
        System.assertEquals('Expense amounts must be greater than zero.', messages[3], 'Claim amounts.');
        System.assertEquals('You do not have active access to this Accounting Company.', messages[4], 'Company grant.');
    }

    private static String capture(SABDocumentEntryService.DocumentRequest request, String requestKey) {
        try {
            SABDocumentEntryService.saveInvoice(request, requestKey);
        } catch (Exception ex) {
            return ex.getMessage();
        }
        return null;
    }

    private static String capturePayment(SABDocumentEntryService.PaymentRequest request) {
        try {
            SABDocumentEntryService.savePayment(request, 'G22DE-PAY-BAD-' + Crypto.getRandomInteger());
        } catch (Exception ex) {
            return ex.getMessage();
        }
        return null;
    }
}
