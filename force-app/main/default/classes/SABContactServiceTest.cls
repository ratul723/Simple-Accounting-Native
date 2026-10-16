@IsTest
private class SABContactServiceTest {

    @TestSetup
    static void setupData() {
        SABAppShellTestFixture.seed();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert as system new PermissionSetAssignment(AssigneeId = SABAppShellTestFixture.fixtureUser().Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'SAB_Manage_Contacts_Action' WITH SYSTEM_MODE LIMIT 1].Id);
            Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
            insert as system new List<GL_Account__c>{
                control(companyId, '1100', 'Receivables', 'Asset', 'Debit', 'AR'),
                control(companyId, '2000', 'Payables', 'Liability', 'Credit', 'AP') };
            insert as system new List<Payment_Term__c>{
                new Payment_Term__c(Company__c = companyId, Name = 'Net 14', Due_Days__c = 14, Rule_Type__c = 'Net Days', Is_Active__c = true, Term_Key__c = 'CST-N14'),
                new Payment_Term__c(Company__c = companyId, Name = 'Net 30', Due_Days__c = 30, Rule_Type__c = 'Net Days', Is_Active__c = true, Term_Key__c = 'CST-N30') };
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static GL_Account__c control(Id companyId, String code, String name, String type, String balance, String controlType) {
        return new GL_Account__c(Company__c = companyId, Account_Code__c = code, Name = name, Account_Type__c = type, Normal_Balance__c = balance,
            Control_Type__c = controlType, Is_Control_Account__c = true, Manual_Posting_Allowed__c = false, Is_Active__c = true,
            Company_Account_Key__c = SABAppShellTestFixture.ACTIVE_KEY + '-' + code);
    }

    private static Id companyId() {
        return SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
    }

    private static SABContactService.ContactRequest supplier(String name) {
        SABContactService.ContactRequest r = new SABContactService.ContactRequest();
        r.companyId = companyId();
        r.name = name;
        r.email = 'accounts@fuel.example';
        r.phone = '+61 2 5550 1000';
        r.billingCity = 'Sydney';
        r.isSupplier = true;
        r.taxNumber = '53 004 085 616';
        r.paymentMethod = 'Bank Transfer';
        r.bankAccountName = 'Fuel Co Pty Ltd';
        r.bankAccountNumber = '123456789';
        r.bankRoutingCode = '062-000';
        return r;
    }

    @IsTest
    static void createsEditsAndAuditsBankChanges() {
        SABContactService.SaveResult created;
        SABContactService.SaveResult duplicate;
        SABContactService.SaveResult confirmed;
        SABContactService.ContactList contactView;
        SABContactService.ContactDetail detail;
        SABContactService.FormOptions options;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            options = SABContactService.getFormOptions(companyId());
            created = SABContactService.saveContact(supplier('Fuel Co'), false, 'CST-1');
            duplicate = SABContactService.saveContact(supplier('fuel co'), false, 'CST-2');
            SABContactService.ContactRequest edit = supplier('Fuel Co');
            edit.profileId = created.profileId;
            edit.isCustomer = true;
            edit.bankAccountNumber = '987654321';
            // An edit sends the whole form, including the term it was created with; a blank term means None.
            edit.paymentTermId = options.defaultPaymentTermId;
            confirmed = SABContactService.saveContact(edit, false, 'CST-3');
            contactView = SABContactService.getContacts(companyId(), 'supplier');
            detail = SABContactService.getContact(created.profileId);
            Test.stopTest();
        }
        System.assertEquals(1, options.arControls.size(), 'AR controls.');
        System.assertEquals('Net 30', [SELECT Name FROM Payment_Term__c WHERE Id = :options.defaultPaymentTermId WITH SYSTEM_MODE].Name, 'Net 30 by default.');
        System.assertNotEquals(null, created.profileId, 'Created.');
        System.assertEquals(null, duplicate.profileId, 'A duplicate is not saved without confirmation.');
        System.assert(duplicate.duplicateWarning.startsWith('A supplier called Fuel Co already exists.'), duplicate.duplicateWarning);
        System.assertEquals(created.profileId, confirmed.profileId, 'Edited in place.');
        Party_Accounting_Profile__c p = [SELECT Is_Customer__c, Is_Supplier__c, AR_Control_Account__r.Account_Code__c, AP_Control_Account__r.Account_Code__c,
            Payment_Term__r.Name, Bank_Account_Number__c, Email__c, Account__r.BillingCity FROM Party_Accounting_Profile__c WHERE Id = :created.profileId WITH SYSTEM_MODE];
        System.assert(p.Is_Customer__c && p.Is_Supplier__c, 'One contact can be both.');
        System.assertEquals('1100', p.AR_Control_Account__r.Account_Code__c, 'AR control defaulted.');
        System.assertEquals('2000', p.AP_Control_Account__r.Account_Code__c, 'AP control defaulted.');
        System.assertEquals('Net 30', p.Payment_Term__r.Name, 'Payment term defaulted.');
        System.assertEquals('987654321', p.Bank_Account_Number__c, 'Bank details saved.');
        System.assertEquals('Sydney', p.Account__r.BillingCity, 'Address on the account.');
        System.assertEquals(2, [SELECT COUNT() FROM Business_Action__c WHERE Action__c = 'CONTACT_BANK_DETAILS_CHANGED' WITH SYSTEM_MODE],
            'Setting and changing bank details are both audited.');
        System.assertEquals(1, contactView.rows.size(), 'One supplier.');
        System.assertEquals(0, contactView.rows[0].outstanding, 'Nothing outstanding.');
        System.assertEquals('987654321', detail.contact.bankAccountNumber, 'Managers see the full number.');
        System.assertEquals(0, detail.documents.size(), 'No documents yet.');
    }

    @IsTest
    static void quickAddDeactivateAndPermissions() {
        SABContactService.SaveResult quick;
        List<String> messages = new List<String>();
        SABContactService.ContactList customers;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            quick = SABContactService.quickAdd(companyId(), 'Greenfield Produce', 'ap@greenfield.example', true, false, false, 'CST-Q');
            SABContactService.setActive(quick.profileId, false, 'CST-OFF');
            customers = SABContactService.getContacts(companyId(), 'customer');
            try {
                SABContactService.quickAdd(companyId(), ' ', null, true, false, false, 'CST-Q2');
            } catch (SABContactService.ContactException ex) {
                messages.add(ex.getMessage());
            }
            try {
                SABContactService.quickAdd(companyId(), 'Nobody', null, false, false, false, 'CST-Q3');
            } catch (SABContactService.ContactException ex) {
                messages.add(ex.getMessage());
            }
            try {
                SABContactService.getContacts(null, 'customer');
            } catch (SABContactService.ContactException ex) {
                messages.add(ex.getMessage());
            }
            Test.stopTest();
        }
        System.assertEquals(1, customers.rows.size(), 'Inactive contacts stay in the contactView.');
        System.assertEquals(false, customers.rows[0].active, 'Deactivated.');
        System.assertEquals('ap@greenfield.example', customers.rows[0].email, 'Quick add keeps the email.');
        System.assertEquals('Name is required.', messages[0], 'Name required.');
        System.assertEquals('Choose customer, supplier or both.', messages[1], 'Role required.');
        System.assertEquals('You do not have active access to this Accounting Company.', messages[2], 'Company grant.');
    }

    @IsTest
    static void statementRunsOldestFirstAndNumbersAreMasked() {
        List<SABContactService.StatementRow> rows = new List<SABContactService.StatementRow>();
        SABContactService.StatementRow later = new SABContactService.StatementRow();
        later.entryDate = Date.newInstance(2026, 10, 2);
        later.charge = 0;
        later.paid = 40;
        SABContactService.StatementRow first = new SABContactService.StatementRow();
        first.entryDate = Date.newInstance(2026, 10, 1);
        first.charge = 100;
        first.paid = 0;
        rows.add(later);
        rows.add(first);
        List<SABContactService.StatementRow> result;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            result = SABContactService.runningBalance(rows);
        }
        System.assertEquals(100, result[0].balance, 'Invoice first.');
        System.assertEquals(60, result[1].balance, 'Then the receipt.');
        System.assertEquals('****6789', SABContactService.mask('123456789'), 'Last four digits.');
        System.assertEquals('****', SABContactService.mask('12'), 'Short numbers fully masked.');
    }
}
