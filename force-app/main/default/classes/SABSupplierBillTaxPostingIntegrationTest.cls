@IsTest
private class SABSupplierBillTaxPostingIntegrationTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String APPROVE_PERMISSION_SET =
        'SAB_Approve_Financial_Document_Action';

    private static final String POST_PERMISSION_SET =
        'SAB_Post_Journal_Action';

    @IsTest
    static void materializedRecoverableTaxPostsToInputTaxAccount() {
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
                Alias = 'g6bsbt',
                Email =
                    'g6bsbt.'
                    + seed
                    + '@example.test',
                EmailEncodingKey = 'UTF-8',
                LastName = 'G6B Supplier Tax User',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = profileRecord.Id,
                TimeZoneSidKey = 'Asia/Dhaka',
                Username =
                    'g6bsbt.'
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
                :APPROVE_PERMISSION_SET,
                :POST_PERMISSION_SET
            )
        ]) {
            permissionSetIds.put(
                row.Name,
                row.Id
            );
        }

        System.assertEquals(
            3,
            permissionSetIds.size()
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        ADMIN_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        APPROVE_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        POST_PERMISSION_SET
                    )
            )
        };

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c = 'G6B Supplier Tax Company',
                    Company_Key__c = 'GST',
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
                Grant_Key__c = 'G6B-SB-TAX-ACCESS',
                Role__c = 'Finance Manager'
            );

            insert new Accounting_Period__c(
                Name = 'September 2026',
                Company__c = company.Id,
                Company_Period_Key__c = 'GST-2026-09',
                Period_Key__c = 'GST-2026-09',
                Start_Date__c = Date.newInstance(2026, 9, 1),
                End_Date__c = Date.newInstance(2026, 9, 30),
                Fiscal_Year__c = 2026,
                Fiscal_Quarter__c = 3,
                Period_Number__c = 9,
                Status__c = 'Open'
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

            Account supplierAccount =
                new Account(
                    Name = 'G6B Tax Supplier'
                );
            insert supplierAccount;

            Party_Accounting_Profile__c supplier =
                new Party_Accounting_Profile__c(
                    Account__c = supplierAccount.Id,
                    Company__c = company.Id,
                    Profile_Key__c = 'G6B-TAX-SUPPLIER',
                    Is_Active__c = true,
                    Is_Supplier__c = true,
                    Is_Customer__c = false,
                    AP_Control_Account__c = ap.Id
                );
            insert supplier;

            Tax_Code__c taxCode =
                new Tax_Code__c(
                    Name = 'Purchase VAT 10',
                    Code__c = 'G6B-PVAT',
                    Company__c = company.Id,
                    Inclusive__c = false,
                    Is_Active__c = true,
                    Jurisdiction__c = 'BD',
                    Recoverability__c = 'Partial',
                    Treatment__c = 'Standard',
                    Input_Tax_Account__c =
                        inputTax.Id
                );
            insert taxCode;

            insert new Tax_Rate__c(
                Tax_Code__c = taxCode.Id,
                Rate_Key__c = 'G6B-PVAT-2026',
                Rate__c = 10,
                Recoverable_Percent__c = 60,
                Country_Pack_Version__c = 'GENERIC-1',
                Effective_From__c =
                    Date.newInstance(2026, 1, 1)
            );

            Supplier_Bill__c bill =
                new Supplier_Bill__c(
                    Company__c = company.Id,
                    Supplier_Profile__c = supplier.Id,
                    Document_Type__c = 'Bill',
                    Document_Date__c =
                        Date.newInstance(2026, 9, 10),
                    Accounting_Date__c =
                        Date.newInstance(2026, 9, 10),
                    Due_Date__c =
                        Date.newInstance(2026, 10, 10),
                    Vendor_Reference__c =
                        'G6B-TAX-BILL-001',
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
                Supplier_Bill__c = bill.Id,
                Line_Number__c = 1,
                Description__c = 'Taxed purchase',
                Quantity__c = 1,
                Unit_Price__c = 100,
                Net_Amount__c = 100,
                Expense_or_Asset_Account__c =
                    expense.Id,
                Tax_Code__c = taxCode.Id
            );

            SABDocumentTaxService.materializeSupplierBillTaxes(
                    bill.Id
                );

            SABSupplierBillService.submit(
                bill.Id,
                'G6B-SB-SUBMIT'
            );

            SABSupplierBillService.approve(
                bill.Id,
                'G6B-SB-APPROVE',
                'Approved for G6B tax posting.'
            );

            SABSupplierBillPostingService.PostingRequest
                request =
                    new SABSupplierBillPostingService.PostingRequest();

            request.supplierBillId =
                bill.Id;
            request.requestKey =
                'G6B-SB-POST';

            Test.startTest();

            SABSupplierBillPostingService.PostingResult result =
                SABSupplierBillPostingService.postApprovedBill(
                        request
                    );

            Test.stopTest();

            List<Journal_Entry_Line__c> lines = [
                SELECT GL_Account__r.Account_Code__c,
                       Debit_Base__c,
                       Credit_Base__c,
                       Transaction_Amount__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c =
                        :result.journalEntryId
                ORDER BY Line_Number__c
            ];

            System.assertEquals(
                3,
                lines.size()
            );

            System.assertEquals(
                '5100',
                lines[0].GL_Account__r.Account_Code__c
            );

            System.assertEquals(
                Decimal.valueOf('104'),
                lines[0].Debit_Base__c
            );

            System.assertEquals(
                '1301',
                lines[1].GL_Account__r.Account_Code__c
            );

            System.assertEquals(
                Decimal.valueOf('6'),
                lines[1].Debit_Base__c
            );

            System.assertEquals(
                '2100',
                lines[2].GL_Account__r.Account_Code__c
            );

            System.assertEquals(
                Decimal.valueOf('110'),
                lines[2].Credit_Base__c
            );
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
                    'GST-' + code,
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
}
