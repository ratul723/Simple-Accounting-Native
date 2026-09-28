@IsTest
private class SABTaxReturnServiceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String PREPARE_PERMISSION_SET =
        'SAB_Prepare_Tax_Return_Action';

    @TestSetup
    static void setupFixture() {
        Profile profileRecord = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String seed =
            String.valueOf(
                DateTime.now().getTime()
            );

        User testUser =
            new User(
                Alias = 'g6ctax',
                Email =
                    'g6ctax.'
                    + seed
                    + '@example.test',
                EmailEncodingKey = 'UTF-8',
                LastName = 'G6C Tax Return User',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = profileRecord.Id,
                TimeZoneSidKey = 'Asia/Dhaka',
                Username =
                    'g6ctax.'
                    + seed
                    + '@example.test'
            );

        insert testUser;

        Map<String, Id> permissionSetIds =
            new Map<String, Id>();

        for (PermissionSet row : [
            SELECT Id,
                   Name
            FROM PermissionSet
            WHERE Name IN (
                :ADMIN_PERMISSION_SET,
                :PREPARE_PERMISSION_SET
            )
        ]) {
            permissionSetIds.put(
                row.Name,
                row.Id
            );
        }

        System.assertEquals(
            2,
            permissionSetIds.size(),
            'G6C dependency permission sets must exist.'
        );

        List<PermissionSetAssignment> assignments =
            new List<PermissionSetAssignment>();

        for (
            String permissionSetName :
            permissionSetIds.keySet()
        ) {
            assignments.add(
                new PermissionSetAssignment(
                    AssigneeId =
                        testUser.Id,
                    PermissionSetId =
                        permissionSetIds.get(
                            permissionSetName
                        )
                )
            );
        }

        insert assignments;

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c = 'G6C Tax Company',
                    Company_Key__c = 'GTC',
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
                User__c = testUser.Id,
                Is_Active__c = true,
                Effective_From__c = Date.today(),
                Grant_Key__c = 'G6C-TAX-ACCESS',
                Role__c = 'Finance Manager'
            );

            insert new Accounting_Period__c(
                Name = 'September 2026',
                Company__c = company.Id,
                Company_Period_Key__c = 'GTC-2026-09',
                Period_Key__c = 'GTC-2026-09',
                Start_Date__c = Date.newInstance(2026, 9, 1),
                End_Date__c = Date.newInstance(2026, 9, 30),
                Fiscal_Year__c = 2026,
                Fiscal_Quarter__c = 3,
                Period_Number__c = 9,
                Status__c = 'Open'
            );

            GL_Account__c ar =
                makeAccount(
                    company.Id,
                    '1200',
                    'Accounts Receivable',
                    'Asset',
                    'Debit',
                    true,
                    'AR',
                    false
                );

            GL_Account__c ap =
                makeAccount(
                    company.Id,
                    '2100',
                    'Accounts Payable',
                    'Liability',
                    'Credit',
                    true,
                    'AP',
                    false
                );

            GL_Account__c revenue =
                makeAccount(
                    company.Id,
                    '4100',
                    'Revenue',
                    'Revenue',
                    'Credit',
                    false,
                    'None',
                    true
                );

            GL_Account__c expense =
                makeAccount(
                    company.Id,
                    '5100',
                    'Expense',
                    'Expense',
                    'Debit',
                    false,
                    'None',
                    true
                );

            GL_Account__c outputTax =
                makeAccount(
                    company.Id,
                    '2201',
                    'Output Tax',
                    'Liability',
                    'Credit',
                    true,
                    'Tax',
                    false
                );

            GL_Account__c inputTax =
                makeAccount(
                    company.Id,
                    '1301',
                    'Input Tax',
                    'Asset',
                    'Debit',
                    true,
                    'Tax',
                    false
                );

            Account customerAccount =
                new Account(
                    Name = 'G6C Customer'
                );
            insert customerAccount;

            Account supplierAccount =
                new Account(
                    Name = 'G6C Supplier'
                );
            insert supplierAccount;

            Party_Accounting_Profile__c customer =
                new Party_Accounting_Profile__c(
                    Account__c = customerAccount.Id,
                    Company__c = company.Id,
                    Profile_Key__c = 'G6C-CUSTOMER',
                    Is_Active__c = true,
                    Is_Customer__c = true,
                    Is_Supplier__c = false,
                    AR_Control_Account__c = ar.Id
                );
            insert customer;

            Party_Accounting_Profile__c supplier =
                new Party_Accounting_Profile__c(
                    Account__c = supplierAccount.Id,
                    Company__c = company.Id,
                    Profile_Key__c = 'G6C-SUPPLIER',
                    Is_Active__c = true,
                    Is_Customer__c = false,
                    Is_Supplier__c = true,
                    AP_Control_Account__c = ap.Id
                );
            insert supplier;

            Tax_Registration__c registration =
                new Tax_Registration__c(
                    Name = 'G6C VAT Registration',
                    Company__c = company.Id,
                    Country_Pack_Version__c = 'GENERIC-1',
                    Effective_From__c =
                        Date.newInstance(2026, 1, 1),
                    Filing_Frequency__c = 'Monthly',
                    Is_Active__c = true,
                    Jurisdiction__c = 'BD',
                    Registration_Identifier__c =
                        'G6C-BD-VAT-001'
                );
            insert registration;

            Tax_Code__c salesTax =
                new Tax_Code__c(
                    Name = 'G6C Sales VAT 15',
                    Code__c = 'G6C-SVAT',
                    Company__c = company.Id,
                    Inclusive__c = true,
                    Is_Active__c = true,
                    Jurisdiction__c = 'BD',
                    Recoverability__c = 'None',
                    Treatment__c = 'Standard',
                    Output_Tax_Account__c =
                        outputTax.Id
                );

            Tax_Code__c purchaseTax =
                new Tax_Code__c(
                    Name = 'G6C Purchase VAT 10',
                    Code__c = 'G6C-PVAT',
                    Company__c = company.Id,
                    Inclusive__c = false,
                    Is_Active__c = true,
                    Jurisdiction__c = 'BD',
                    Recoverability__c = 'Partial',
                    Treatment__c = 'Standard',
                    Input_Tax_Account__c =
                        inputTax.Id
                );

            insert new List<Tax_Code__c>{
                salesTax,
                purchaseTax
            };

            insert new List<Tax_Rate__c>{
                new Tax_Rate__c(
                    Tax_Code__c = salesTax.Id,
                    Rate_Key__c = 'G6C-SVAT-2026',
                    Rate__c = 15,
                    Country_Pack_Version__c = 'GENERIC-1',
                    Effective_From__c =
                        Date.newInstance(2026, 1, 1)
                ),
                new Tax_Rate__c(
                    Tax_Code__c = purchaseTax.Id,
                    Rate_Key__c = 'G6C-PVAT-2026',
                    Rate__c = 10,
                    Recoverable_Percent__c = 60,
                    Country_Pack_Version__c = 'GENERIC-1',
                    Effective_From__c =
                        Date.newInstance(2026, 1, 1)
                )
            };

            createAndPostInvoice(
                company,
                customer,
                revenue,
                salesTax,
                115,
                'G6C-INV-POST'
            );

            createAndPostSupplierBill(
                company,
                supplier,
                expense,
                purchaseTax,
                100,
                'G6C-BILL-POST'
            );
        }
    }

    @IsTest
    static void preparesGenericReturnFromPostedTaxSnapshots() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Tax_Registration__c registration =
                getRegistration();

            Test.startTest();

            SABTaxReturnService.PreparedReturnResult result =
                SABTaxReturnService.prepareReturn(
                    registration.Id,
                    Date.newInstance(2026, 9, 1),
                    Date.newInstance(2026, 9, 30)
                );

            Test.stopTest();

            System.assertEquals(
                'Prepared',
                result.status
            );

            System.assertEquals(
                Decimal.valueOf('100.0000'),
                result.outputTaxableBase
            );

            System.assertEquals(
                Decimal.valueOf('15.0000'),
                result.outputTax
            );

            System.assertEquals(
                Decimal.valueOf('100.0000'),
                result.inputTaxableBase
            );

            System.assertEquals(
                Decimal.valueOf('6.0000'),
                result.recoverableInputTax
            );

            System.assertEquals(
                Decimal.valueOf('9.0000'),
                result.netTaxDue
            );

            System.assertEquals(
                1,
                result.outputSourceCount
            );

            System.assertEquals(
                1,
                result.inputSourceCount
            );

            System.assertEquals(
                5,
                result.returnLineCount
            );

            List<Tax_Return_Line__c> lines = [
                SELECT Box_Key__c,
                       Calculated_Amount__c,
                       Adjustment_Amount__c,
                       Final_Amount__c,
                       Source_Inclusion_Hash__c
                FROM Tax_Return_Line__c
                WHERE Tax_Return__c =
                        :result.taxReturnId
                ORDER BY Box_Key__c
            ];

            System.assertEquals(
                5,
                lines.size()
            );

            for (
                Tax_Return_Line__c line :
                lines
            ) {
                System.assertNotEquals(
                    null,
                    line.Source_Inclusion_Hash__c
                );

                System.assertEquals(
                    64,
                    line.Source_Inclusion_Hash__c.length()
                );
            }
        }
    }

    @IsTest
    static void repreparationIsIdempotentAndPreservesAdjustment() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Tax_Registration__c registration =
                getRegistration();

            SABTaxReturnService.PreparedReturnResult first =
                SABTaxReturnService.prepareReturn(
                    registration.Id,
                    Date.newInstance(2026, 9, 1),
                    Date.newInstance(2026, 9, 30)
                );

            SABTaxReturnService.setAdjustment(
                first.taxReturnId,
                'NET_TAX_DUE',
                Decimal.valueOf('1.25')
            );

            Test.startTest();

            SABTaxReturnService.PreparedReturnResult second =
                SABTaxReturnService.prepareReturn(
                    registration.Id,
                    Date.newInstance(2026, 9, 1),
                    Date.newInstance(2026, 9, 30)
                );

            Test.stopTest();

            System.assertEquals(
                first.taxReturnId,
                second.taxReturnId
            );

            System.assertEquals(
                true,
                second.rebuiltExistingReturn
            );

            Integer lineCount = [
                SELECT COUNT()
                FROM Tax_Return_Line__c
                WHERE Tax_Return__c =
                        :second.taxReturnId
            ];

            System.assertEquals(
                5,
                lineCount
            );

            Tax_Return_Line__c netLine = [
                SELECT Calculated_Amount__c,
                       Adjustment_Amount__c,
                       Final_Amount__c
                FROM Tax_Return_Line__c
                WHERE Tax_Return__c =
                        :second.taxReturnId
                  AND Box_Key__c =
                        'NET_TAX_DUE'
                LIMIT 1
            ];

            System.assertEquals(
                Decimal.valueOf('9.0000'),
                netLine.Calculated_Amount__c
            );

            System.assertEquals(
                Decimal.valueOf('1.2500'),
                netLine.Adjustment_Amount__c
            );

            System.assertEquals(
                Decimal.valueOf('10.2500'),
                netLine.Final_Amount__c
            );
        }
    }

    @IsTest
    static void draftTaxSnapshotsAreExcluded() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Accounting_Company__c company =
                getCompany();

            Party_Accounting_Profile__c customer = [
                SELECT Id
                FROM Party_Accounting_Profile__c
                WHERE Profile_Key__c =
                        'G6C-CUSTOMER'
                LIMIT 1
            ];

            GL_Account__c revenue = [
                SELECT Id
                FROM GL_Account__c
                WHERE Company__c =
                        :company.Id
                  AND Account_Code__c =
                        '4100'
                LIMIT 1
            ];

            Tax_Code__c taxCode = [
                SELECT Id
                FROM Tax_Code__c
                WHERE Company__c =
                        :company.Id
                  AND Code__c =
                        'G6C-SVAT'
                LIMIT 1
            ];

            Invoice__c draftInvoice =
                new Invoice__c(
                    Company__c = company.Id,
                    Party_Profile__c = customer.Id,
                    Document_Date__c =
                        Date.newInstance(2026, 9, 20),
                    Accounting_Date__c =
                        Date.newInstance(2026, 9, 20),
                    Due_Date__c =
                        Date.newInstance(2026, 10, 20),
                    Document_Type__c = 'Invoice',
                    Status__c = 'Draft',
                    Transaction_Currency__c = 'BDT',
                    Functional_Currency__c = 'BDT',
                    Exchange_Rate__c = 1,
                    Subtotal__c = 0,
                    Tax_Total__c = 0,
                    Total__c = 0
                );
            insert draftInvoice;

            insert new Invoice_Line__c(
                Invoice__c = draftInvoice.Id,
                Line_Number__c = 1,
                Description__c = 'Draft taxable sale',
                Quantity__c = 1,
                Unit_Price__c = 230,
                Discount_Amount__c = 0,
                Net_Amount__c = 230,
                Revenue_Account__c = revenue.Id,
                Tax_Code__c = taxCode.Id
            );

            SABDocumentTaxService.materializeInvoiceTaxes(
                    draftInvoice.Id
                );

            Tax_Registration__c registration =
                getRegistration();

            SABTaxReturnService.PreparedReturnResult result =
                SABTaxReturnService.prepareReturn(
                    registration.Id,
                    Date.newInstance(2026, 9, 1),
                    Date.newInstance(2026, 9, 30)
                );

            System.assertEquals(
                Decimal.valueOf('15.0000'),
                result.outputTax
            );

            System.assertEquals(
                1,
                result.outputSourceCount
            );
        }
    }

    private static void createAndPostInvoice(
        Accounting_Company__c company,
        Party_Accounting_Profile__c customer,
        GL_Account__c revenue,
        Tax_Code__c salesTax,
        Decimal grossAmount,
        String requestKey
    ) {
        Invoice__c invoice =
            new Invoice__c(
                Company__c = company.Id,
                Party_Profile__c = customer.Id,
                Document_Date__c =
                    Date.newInstance(2026, 9, 10),
                Accounting_Date__c =
                    Date.newInstance(2026, 9, 10),
                Due_Date__c =
                    Date.newInstance(2026, 10, 10),
                Document_Type__c = 'Invoice',
                Status__c = 'Draft',
                Transaction_Currency__c = 'BDT',
                Functional_Currency__c = 'BDT',
                Exchange_Rate__c = 1,
                Subtotal__c = 0,
                Tax_Total__c = 0,
                Total__c = 0
            );
        insert invoice;

        insert new Invoice_Line__c(
            Invoice__c = invoice.Id,
            Line_Number__c = 1,
            Description__c = 'G6C taxable sale',
            Quantity__c = 1,
            Unit_Price__c = grossAmount,
            Discount_Amount__c = 0,
            Net_Amount__c = grossAmount,
            Revenue_Account__c = revenue.Id,
            Tax_Code__c = salesTax.Id
        );

        SABDocumentTaxService.materializeInvoiceTaxes(
            invoice.Id
        );

        // Focused G6C fixture: G6B posting is covered by its own regression.
        // We only need a Posted source document backed by real tax snapshots.
        invoice.Status__c =
            'Posted';

        update invoice;
    }

    private static void createAndPostSupplierBill(
        Accounting_Company__c company,
        Party_Accounting_Profile__c supplier,
        GL_Account__c expense,
        Tax_Code__c purchaseTax,
        Decimal netAmount,
        String requestKey
    ) {
        Supplier_Bill__c bill =
            new Supplier_Bill__c(
                Company__c = company.Id,
                Supplier_Profile__c = supplier.Id,
                Document_Type__c = 'Bill',
                Document_Date__c =
                    Date.newInstance(2026, 9, 12),
                Accounting_Date__c =
                    Date.newInstance(2026, 9, 12),
                Due_Date__c =
                    Date.newInstance(2026, 10, 12),
                Vendor_Reference__c =
                    'G6C-BILL-001',
                Transaction_Currency__c =
                    'BDT',
                Functional_Currency__c =
                    'BDT',
                Exchange_Rate__c =
                    1,
                Status__c =
                    'Draft'
            );
        insert bill;

        insert new Bill_Line__c(
            Supplier_Bill__c =
                bill.Id,
            Line_Number__c =
                1,
            Description__c =
                'G6C taxable purchase',
            Quantity__c =
                1,
            Unit_Price__c =
                netAmount,
            Net_Amount__c =
                netAmount,
            Expense_or_Asset_Account__c =
                expense.Id,
            Tax_Code__c =
                purchaseTax.Id
        );

        SABDocumentTaxService.materializeSupplierBillTaxes(
            bill.Id
        );

        // Focused G6C fixture: avoid re-running the full AP posting stack in
        // @TestSetup. The service already exposes this flag as @TestVisible.
        SABSupplierBillService.lifecycleMutationInProgress =
            true;

        try {
            bill.Status__c =
                'Posted';
            update bill;
        } finally {
            SABSupplierBillService.lifecycleMutationInProgress =
                false;
        }
    }

    private static GL_Account__c makeAccount(
        Id companyId,
        String code,
        String displayName,
        String accountType,
        String normalBalance,
        Boolean isControl,
        String controlType,
        Boolean manualPostingAllowed
    ) {
        GL_Account__c accountRecord =
            new GL_Account__c(
                Name = displayName,
                Company__c = companyId,
                Company_Account_Key__c =
                    'GTC-' + code,
                Account_Code__c = code,
                Account_Type__c = accountType,
                Normal_Balance__c = normalBalance,
                Is_Active__c = true,
                Is_Control_Account__c = isControl,
                Control_Type__c = controlType,
                Manual_Posting_Allowed__c =
                    manualPostingAllowed
            );

        insert accountRecord;

        return accountRecord;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                'G6C Tax Return User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getCompany() {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c =
                'GTC'
            LIMIT 1
        ];
    }

    private static Tax_Registration__c getRegistration() {
        return [
            SELECT Id
            FROM Tax_Registration__c
            WHERE Registration_Identifier__c =
                'G6C-BD-VAT-001'
            LIMIT 1
        ];
    }
}
