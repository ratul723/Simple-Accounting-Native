@IsTest
private class SABDocumentTaxServiceTest {

    @TestSetup
    static void setupFixture() {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c = 'G6B Company',
                Company_Key__c = 'G6B',
                Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT',
                Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active',
                Is_Active__c = true
            );
        insert company;

        insert new Company_User_Access__c(
            Company__c = company.Id,
            User__c = UserInfo.getUserId(),
            Is_Active__c = true,
            Effective_From__c = Date.today(),
            Grant_Key__c = 'G6B-CURRENT-USER',
            Role__c = 'Finance Manager'
        );

        GL_Account__c outputTax =
            createGL(
                company.Id,
                '2201',
                'Output Tax',
                'Liability',
                'Credit',
                true,
                'Tax'
            );

        GL_Account__c inputTax =
            createGL(
                company.Id,
                '1301',
                'Input Tax',
                'Asset',
                'Debit',
                true,
                'Tax'
            );

        GL_Account__c revenue =
            createGL(
                company.Id,
                '4100',
                'Revenue',
                'Revenue',
                'Credit',
                false,
                'None'
            );

        GL_Account__c expense =
            createGL(
                company.Id,
                '5100',
                'Expense',
                'Expense',
                'Debit',
                false,
                'None'
            );

        GL_Account__c arControl =
            createGL(
                company.Id,
                '1200',
                'Accounts Receivable',
                'Asset',
                'Debit',
                true,
                'AR'
            );

        GL_Account__c apControl =
            createGL(
                company.Id,
                '2100',
                'Accounts Payable',
                'Liability',
                'Credit',
                true,
                'AP'
            );

        Account customerAccount =
            new Account(
                Name = 'G6B Customer Account'
            );
        insert customerAccount;

        Account supplierAccount =
            new Account(
                Name = 'G6B Supplier Account'
            );
        insert supplierAccount;

        Party_Accounting_Profile__c customer =
            new Party_Accounting_Profile__c(
                Account__c = customerAccount.Id,
                Company__c = company.Id,
                Profile_Key__c = 'G6B-CUSTOMER',
                Is_Active__c = true,
                Is_Customer__c = true,
                AR_Control_Account__c = arControl.Id
            );
        insert customer;

        Party_Accounting_Profile__c supplier =
            new Party_Accounting_Profile__c(
                Account__c = supplierAccount.Id,
                Company__c = company.Id,
                Profile_Key__c = 'G6B-SUPPLIER',
                Is_Active__c = true,
                Is_Supplier__c = true,
                AP_Control_Account__c = apControl.Id
            );
        insert supplier;

        Tax_Code__c salesTax =
            new Tax_Code__c(
                Name = 'Sales VAT 15 Inclusive',
                Code__c = 'SVAT15I',
                Company__c = company.Id,
                Inclusive__c = true,
                Is_Active__c = true,
                Jurisdiction__c = 'BD',
                Recoverability__c = 'None',
                Treatment__c = 'Standard',
                Output_Tax_Account__c = outputTax.Id
            );

        Tax_Code__c purchaseTax =
            new Tax_Code__c(
                Name = 'Purchase VAT 10',
                Code__c = 'PVAT10',
                Company__c = company.Id,
                Inclusive__c = false,
                Is_Active__c = true,
                Jurisdiction__c = 'BD',
                Recoverability__c = 'Partial',
                Treatment__c = 'Standard',
                Input_Tax_Account__c = inputTax.Id
            );

        insert new List<Tax_Code__c>{
            salesTax,
            purchaseTax
        };

        insert new List<Tax_Rate__c>{
            new Tax_Rate__c(
                Tax_Code__c = salesTax.Id,
                Rate_Key__c = 'SVAT15I-2026',
                Rate__c = 15,
                Country_Pack_Version__c = 'GENERIC-1',
                Effective_From__c = Date.newInstance(2026, 1, 1)
            ),
            new Tax_Rate__c(
                Tax_Code__c = purchaseTax.Id,
                Rate_Key__c = 'PVAT10-2026',
                Rate__c = 10,
                Recoverable_Percent__c = 60,
                Country_Pack_Version__c = 'GENERIC-1',
                Effective_From__c = Date.newInstance(2026, 1, 1)
            )
        };

        Invoice__c invoice =
            new Invoice__c(
                Company__c = company.Id,
                Party_Profile__c = customer.Id,
                Document_Date__c = Date.newInstance(2026, 9, 28),
                Accounting_Date__c = Date.newInstance(2026, 9, 28),
                Due_Date__c = Date.newInstance(2026, 10, 28),
                Document_Type__c = 'Invoice',
                Status__c = 'Draft',
                Transaction_Currency__c = 'BDT',
                Functional_Currency__c = 'BDT',
                Subtotal__c = 0,
                Tax_Total__c = 0,
                Total__c = 0
            );
        insert invoice;

        insert new Invoice_Line__c(
            Invoice__c = invoice.Id,
            Line_Number__c = 1,
            Description__c = 'Inclusive taxable sale',
            Quantity__c = 1,
            Unit_Price__c = 115,
            Discount_Amount__c = 0,
            Net_Amount__c = 115,
            Revenue_Account__c = revenue.Id,
            Tax_Code__c = salesTax.Id
        );

        Supplier_Bill__c bill =
            new Supplier_Bill__c(
                Company__c = company.Id,
                Supplier_Profile__c = supplier.Id,
                Document_Type__c = 'Bill',
                Document_Date__c = Date.newInstance(2026, 9, 28),
                Accounting_Date__c = Date.newInstance(2026, 9, 28),
                Due_Date__c = Date.newInstance(2026, 10, 28),
                Vendor_Reference__c = 'G6B-V-1',
                Transaction_Currency__c = 'BDT',
                Functional_Currency__c = 'BDT',
                Exchange_Rate__c = 1,
                Status__c = 'Draft',
                Subtotal__c = 0,
                Tax_Total__c = 0,
                Total__c = 0
            );
        insert bill;

        insert new Bill_Line__c(
            Supplier_Bill__c = bill.Id,
            Line_Number__c = 1,
            Description__c = 'Exclusive taxable purchase',
            Quantity__c = 1,
            Unit_Price__c = 100,
            Net_Amount__c = 100,
            Expense_or_Asset_Account__c = expense.Id,
            Tax_Code__c = purchaseTax.Id
        );
    }

    @IsTest
    static void invoiceInclusiveTaxIsMaterialized() {
        Invoice__c invoice = [
            SELECT Id
            FROM Invoice__c
            WHERE Status__c = 'Draft'
            LIMIT 1
        ];

        Test.startTest();

        SABDocumentTaxService.MaterializationResult result =
            SABDocumentTaxService.materializeInvoiceTaxes(
                invoice.Id
            );

        Test.stopTest();

        System.assertEquals(
            Decimal.valueOf('100.0000'),
            result.subtotal
        );
        System.assertEquals(
            Decimal.valueOf('15.0000'),
            result.taxTotal
        );
        System.assertEquals(
            Decimal.valueOf('115.0000'),
            result.total
        );
        System.assertEquals(
            1,
            result.taxLineCount
        );

        Invoice_Line__c line = [
            SELECT Net_Amount__c,
                   Tax_Treatment_Snapshot__c
            FROM Invoice_Line__c
            WHERE Invoice__c = :invoice.Id
            LIMIT 1
        ];

        System.assertEquals(
            Decimal.valueOf('100.0000'),
            line.Net_Amount__c
        );
        System.assertNotEquals(
            null,
            line.Tax_Treatment_Snapshot__c
        );

        Document_Tax_Line__c taxLine = [
            SELECT Taxable_Base__c,
                   Tax_Amount__c,
                   Recoverable_Amount__c,
                   Tax_Account__r.Control_Type__c,
                   Tax_Code_Key__c,
                   Calculation_Version__c
            FROM Document_Tax_Line__c
            WHERE Invoice_Line__r.Invoice__c =
                    :invoice.Id
            LIMIT 1
        ];

        System.assertEquals(
            Decimal.valueOf('100.0000'),
            taxLine.Taxable_Base__c
        );
        System.assertEquals(
            Decimal.valueOf('15.0000'),
            taxLine.Tax_Amount__c
        );
        System.assertEquals(
            'Tax',
            taxLine.Tax_Account__r.Control_Type__c
        );
        System.assertEquals(
            'SVAT15I',
            taxLine.Tax_Code_Key__c
        );
        System.assertEquals(
            'G6B-DOC-TAX-1',
            taxLine.Calculation_Version__c
        );
    }

    @IsTest
    static void supplierBillPartialRecoverabilityIsMaterialized() {
        Supplier_Bill__c bill = [
            SELECT Id
            FROM Supplier_Bill__c
            WHERE Vendor_Reference__c = 'G6B-V-1'
            LIMIT 1
        ];

        SABDocumentTaxService.MaterializationResult result =
            SABDocumentTaxService.materializeSupplierBillTaxes(
                bill.Id
            );

        System.assertEquals(
            Decimal.valueOf('100.0000'),
            result.subtotal
        );
        System.assertEquals(
            Decimal.valueOf('10.0000'),
            result.taxTotal
        );
        System.assertEquals(
            Decimal.valueOf('110.0000'),
            result.total
        );

        Bill_Line__c line = [
            SELECT Net_Amount__c,
                   Recoverable_Tax_Amount__c,
                   Nonrecoverable_Tax_Amount__c
            FROM Bill_Line__c
            WHERE Supplier_Bill__c =
                    :bill.Id
            LIMIT 1
        ];

        System.assertEquals(
            Decimal.valueOf('6.0000'),
            line.Recoverable_Tax_Amount__c
        );
        System.assertEquals(
            Decimal.valueOf('4.0000'),
            line.Nonrecoverable_Tax_Amount__c
        );

        Document_Tax_Line__c taxLine = [
            SELECT Tax_Amount__c,
                   Recoverable_Amount__c,
                   Tax_Account__r.Control_Type__c
            FROM Document_Tax_Line__c
            WHERE Bill_Line__r.Supplier_Bill__c =
                    :bill.Id
            LIMIT 1
        ];

        System.assertEquals(
            Decimal.valueOf('10.0000'),
            taxLine.Tax_Amount__c
        );
        System.assertEquals(
            Decimal.valueOf('6.0000'),
            taxLine.Recoverable_Amount__c
        );
        System.assertEquals(
            'Tax',
            taxLine.Tax_Account__r.Control_Type__c
        );
    }

    @IsTest
    static void rematerializationIsIdempotentWhileDraft() {
        Invoice__c invoice = [
            SELECT Id
            FROM Invoice__c
            WHERE Status__c = 'Draft'
            LIMIT 1
        ];

        SABDocumentTaxService.materializeInvoiceTaxes(
            invoice.Id
        );

        SABDocumentTaxService.materializeInvoiceTaxes(
            invoice.Id
        );

        Integer countRows = [
            SELECT COUNT()
            FROM Document_Tax_Line__c
            WHERE Invoice_Line__r.Invoice__c =
                    :invoice.Id
        ];

        System.assertEquals(
            1,
            countRows
        );
    }

    private static GL_Account__c createGL(
        Id companyId,
        String code,
        String nameValue,
        String accountType,
        String normalBalance,
        Boolean controlAccount,
        String controlType
    ) {
        GL_Account__c row =
            new GL_Account__c(
                Name = nameValue,
                Company__c = companyId,
                Company_Account_Key__c =
                    'G6B-' + code,
                Account_Code__c = code,
                Account_Type__c = accountType,
                Normal_Balance__c = normalBalance,
                Is_Active__c = true,
                Is_Control_Account__c = controlAccount,
                Control_Type__c = controlType,
                Manual_Posting_Allowed__c =
                    !controlAccount
            );

        insert row;
        return row;
    }
}
