@IsTest
private class SABMoneyWorkspaceControllerTest {

    private static final String KEY = 'G22M';

    @TestSetup
    static void setupData() {
        Accounting_Company__c company = new Accounting_Company__c(Name__c = 'Money Test Co', Company_Key__c = KEY, Country_Code__c = 'BD',
            Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active',
            Is_Active__c = true);
        insert as system company;
        insert as system new Company_User_Access__c(Company__c = company.Id, User__c = UserInfo.getUserId(), Effective_From__c = Date.today(),
            Grant_Key__c = 'G22M-ACCESS', Is_Active__c = true, Role__c = 'Finance Manager');
        Account customer = new Account(Name = 'G22M Customer');
        Account supplier = new Account(Name = 'G22M Supplier');
        insert as system new List<Account>{ customer, supplier };
        List<GL_Account__c> accounts = new List<GL_Account__c>{
            new GL_Account__c(Name = 'Accounts Receivable', Company__c = company.Id, Company_Account_Key__c = 'G22M-1200', Account_Code__c = '1200',
                Account_Type__c = 'Asset', Normal_Balance__c = 'Debit', Is_Active__c = true, Is_Control_Account__c = true, Control_Type__c = 'AR',
                Manual_Posting_Allowed__c = false),
            new GL_Account__c(Name = 'Accounts Payable', Company__c = company.Id, Company_Account_Key__c = 'G22M-2100', Account_Code__c = '2100',
                Account_Type__c = 'Liability', Normal_Balance__c = 'Credit', Is_Active__c = true, Is_Control_Account__c = true, Control_Type__c = 'AP',
                Manual_Posting_Allowed__c = false),
            new GL_Account__c(Name = 'Operating bank', Company__c = company.Id, Company_Account_Key__c = 'G22M-1000', Account_Code__c = '1000',
                Account_Type__c = 'Asset', Normal_Balance__c = 'Debit', Is_Active__c = true, Control_Type__c = 'None', Manual_Posting_Allowed__c = true),
            new GL_Account__c(Name = 'Sales', Company__c = company.Id, Company_Account_Key__c = 'G22M-4000', Account_Code__c = '4000',
                Account_Type__c = 'Revenue', Normal_Balance__c = 'Credit', Is_Active__c = true, Control_Type__c = 'None', Manual_Posting_Allowed__c = true)
        };
        insert as system accounts;
        insert as system new List<Party_Accounting_Profile__c>{
            new Party_Accounting_Profile__c(Company__c = company.Id, Account__c = customer.Id, Profile_Key__c = 'G22M-CUSTOMER', Is_Customer__c = true,
                Is_Supplier__c = false, Is_Active__c = true, AR_Control_Account__c = accounts[0].Id, Credit_Limit__c = 1000),
            new Party_Accounting_Profile__c(Company__c = company.Id, Account__c = supplier.Id, Profile_Key__c = 'G22M-SUPPLIER', Is_Customer__c = false,
                Is_Supplier__c = true, Is_Active__c = true, AP_Control_Account__c = accounts[1].Id)
        };
        SABTestGovernor.assertSetupWithin(50);
    }

    private static Id companyId() {
        return [SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = :KEY WITH SYSTEM_MODE LIMIT 1].Id;
    }

    private static Id customerProfileId() {
        return [SELECT Id FROM Party_Accounting_Profile__c WHERE Profile_Key__c = 'G22M-CUSTOMER' WITH SYSTEM_MODE LIMIT 1].Id;
    }

    private static Invoice__c invoice(Id companyId, Id profileId, String legalNumber, String documentType, Date dueDate, Decimal total) {
        return new Invoice__c(Company__c = companyId, Party_Profile__c = profileId, Document_Type__c = documentType,
            Document_Date__c = Date.today().addDays(-60), Accounting_Date__c = Date.today().addDays(-60), Due_Date__c = dueDate,
            Status__c = 'Posted', Transaction_Currency__c = 'BDT', Functional_Currency__c = 'BDT', Exchange_Rate__c = 1, Subtotal__c = total,
            Tax_Total__c = 0, Total__c = total, Legal_Number__c = legalNumber);
    }

    @IsTest
    static void salesShowsInvoicesCreditsCustomersAndAging() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Id companyId = companyId();
            Id profileId = customerProfileId();
            Invoice__c overdue = invoice(companyId, profileId, 'G22M-INV-1', 'Invoice', Date.today().addDays(-10), 300);
            Invoice__c current = invoice(companyId, profileId, 'G22M-INV-2', 'Invoice', Date.today().addDays(20), 200);
            insert as system new List<Invoice__c>{ overdue, current };
            Invoice__c credit = invoice(companyId, profileId, 'G22M-CN-1', 'Credit Note', Date.today(), -50);
            credit.Original_Invoice__c = current.Id;
            insert as system credit;
            insert as system new Payment_Allocation__c(Company__c = companyId, Invoice__c = overdue.Id, Allocated_Amount__c = 100, Payment_Amount__c = 100,
                Document_Amount__c = 100, Base_Amount__c = 100, Transaction_Currency__c = 'BDT', Exchange_Rate__c = 1, Allocation_Date__c = Date.today().addDays(-5),
                Effective_Date__c = Date.today().addDays(-5), Status__c = 'Allocated');
            SABMoneyWorkspaceController.SalesData data;
            SABMoneyWorkspaceController.DocumentDetail detail;
            Test.startTest();
            data = SABMoneyWorkspaceController.getSales(companyId);
            detail = SABMoneyWorkspaceController.getDocumentDetail(companyId, overdue.Id);
            Test.stopTest();
            System.assertEquals('BDT', data.currencyCode, 'Functional currency.');
            System.assert(data.agingAvailable, 'Aging is readable.');
            System.assertEquals(2, data.invoices.size(), 'Two invoices.');
            System.assertEquals(1, data.credits.size(), 'One credit note.');
            System.assertEquals('G22M-INV-2', data.credits[0].originalNumber, 'Credit note points at its invoice.');
            System.assertEquals(1, data.overdueCount, 'One overdue invoice.');
            System.assertEquals(200, data.overdueAmount, 'Overdue after the allocation.');
            System.assertEquals(5, data.buckets.size(), 'Five aging buckets.');
            System.assertEquals(1, data.customers.size(), 'One customer.');
            System.assertEquals('G22M Customer', data.customers[0].name, 'Customer name from the Account.');
            System.assert(data.customers[0].outstanding > 0, 'Customer outstanding from aging.');
            Map<String, SABMoneyWorkspaceController.DocumentRow> byNumber = new Map<String, SABMoneyWorkspaceController.DocumentRow>();
            for (SABMoneyWorkspaceController.DocumentRow row : data.invoices) {
                byNumber.put(row.documentNumber, row);
            }
            System.assertEquals(200, byNumber.get('G22M-INV-1').outstanding, 'Outstanding after allocation.');
            System.assert(byNumber.get('G22M-INV-1').daysPastDue > 0, 'Days past due.');
            System.assertEquals(300, detail.total, 'Invoice total.');
            System.assertEquals(1, detail.allocations.size(), 'One allocation.');
        }
    }

    @IsTest
    static void paymentsAndSuppliersAreListed() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Id companyId = companyId();
            Id bankGl = [SELECT Id FROM GL_Account__c WHERE Account_Code__c = '1000' AND Company__c = :companyId WITH SYSTEM_MODE LIMIT 1].Id;
            Bank_Account__c bank = new Bank_Account__c(Name = 'Operating', Company__c = companyId, Bank_Name__c = 'Test Bank', Currency__c = 'BDT',
                GL_Account__c = bankGl, Is_Active__c = true);
            insert as system bank;
            insert as system new Accounting_Payment__c(Company__c = companyId, Direction__c = 'Receipt', Party_Profile__c = customerProfileId(),
                Effective_Date__c = Date.today(), Bank_Account__c = bank.Id, Amount__c = 120, Transaction_Currency__c = 'BDT',
                Method__c = 'Bank Transfer', Processing_State__c = 'Draft', Reference__c = 'G22M-RCPT');
            SABMoneyWorkspaceController.PaymentsData data;
            SABMoneyWorkspaceController.PurchaseExtras extras;
            Test.startTest();
            data = SABMoneyWorkspaceController.getPayments(companyId);
            extras = SABMoneyWorkspaceController.getPurchaseExtras(companyId);
            Test.stopTest();
            System.assertEquals(1, data.payments.size(), 'One payment.');
        System.assertNotEquals(null, data.openBills, 'Open bills are listed for supplier allocations.');
            System.assertEquals('Draft', data.payments[0].state, 'Draft payment.');
            System.assertEquals('Receipt', data.payments[0].direction, 'Receipt.');
            System.assertEquals('G22M Customer', data.payments[0].partyName, 'Party name.');
            System.assertEquals(0, data.payments[0].allocated, 'Nothing allocated.');
            System.assertEquals(null, data.payments[0].managedBy, 'Not a payroll or equity payment.');
            System.assertEquals(0, data.awaitingReleaseCount, 'Nothing authorised.');
            System.assertNotEquals(null, data.openInvoices, 'Open invoices list.');
            System.assertEquals(1, extras.suppliers.size(), 'One supplier.');
            System.assertEquals('G22M Supplier', extras.suppliers[0].name, 'Supplier name.');
            System.assertNotEquals(null, extras.canApprove, 'Permission flags are returned.');
        }
    }

    @IsTest
    static void accessAndInputRulesAreEnforced() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Id companyId = companyId();
            Accounting_Company__c other = new Accounting_Company__c(Name__c = 'Other Money Co', Company_Key__c = 'G22N', Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active',
                Is_Active__c = true);
            insert as system other;
            List<String> messages = new List<String>();
            Test.startTest();
            for (Integer i = 0; i < 4; i++) {
                try {
                    if (i == 0) {
                        SABMoneyWorkspaceController.getSales(other.Id);
                    } else if (i == 1) {
                        SABMoneyWorkspaceController.getDocumentDetail(companyId, null);
                    } else if (i == 2) {
                        SABMoneyWorkspaceController.getDocumentDetail(companyId, companyId);
                    } else {
                        SABMoneyWorkspaceController.getPayments(null);
                    }
                } catch (AuraHandledException ex) {
                    messages.add(ex.getMessage());
                }
            }
            Test.stopTest();
            System.assertEquals('You do not have active access to this Accounting Company.', messages[0], 'A grant is required.');
            System.assertEquals('A document is required.', messages[1], 'A document is required.');
            System.assertEquals('Only invoices and supplier bills have line details.', messages[2], 'Only documents have lines.');
            System.assertEquals('You do not have active access to this Accounting Company.', messages[3], 'A company is required.');
        }
    }
}