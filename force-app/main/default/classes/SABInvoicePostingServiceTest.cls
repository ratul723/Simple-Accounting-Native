@IsTest
private class SABInvoicePostingServiceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String POST_PERMISSION_SET =
        'SAB_Post_Journal_Action';

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
                Alias = 'g6binv',
                Email =
                    'g6binv.'
                    + seed
                    + '@example.test',
                EmailEncodingKey = 'UTF-8',
                LastName = 'G6B Invoice Posting User',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = profileRecord.Id,
                TimeZoneSidKey = 'Asia/Dhaka',
                Username =
                    'g6binv.'
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
                :POST_PERMISSION_SET
            )
        ]) {
            permissionSetIds.put(
                row.Name,
                row.Id
            );
        }

        System.assertEquals(
            2,
            permissionSetIds.size()
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId =
                    testUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        ADMIN_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId =
                    testUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        POST_PERMISSION_SET
                    )
            )
        };

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c = 'G6B Invoice Company',
                    Company_Key__c = 'GIV',
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
                Grant_Key__c = 'G6B-INV-ACCESS',
                Role__c = 'Finance Manager'
            );

            insert new Accounting_Period__c(
                Name = 'September 2026',
                Company__c = company.Id,
                Company_Period_Key__c = 'GIV-2026-09',
                Period_Key__c = 'GIV-2026-09',
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

            Account customerAccount =
                new Account(
                    Name = 'G6B Invoice Customer'
                );
            insert customerAccount;

            Party_Accounting_Profile__c customer =
                new Party_Accounting_Profile__c(
                    Account__c = customerAccount.Id,
                    Company__c = company.Id,
                    Profile_Key__c = 'G6B-INV-CUSTOMER',
                    Is_Active__c = true,
                    Is_Customer__c = true,
                    Is_Supplier__c = false,
                    AR_Control_Account__c = ar.Id
                );
            insert customer;

            Tax_Code__c taxCode =
                new Tax_Code__c(
                    Name = 'G6B Sales VAT',
                    Code__c = 'G6B-SVAT',
                    Company__c = company.Id,
                    Inclusive__c = true,
                    Is_Active__c = true,
                    Jurisdiction__c = 'BD',
                    Recoverability__c = 'None',
                    Treatment__c = 'Standard',
                    Output_Tax_Account__c =
                        outputTax.Id
                );
            insert taxCode;

            insert new Tax_Rate__c(
                Tax_Code__c = taxCode.Id,
                Rate_Key__c = 'G6B-SVAT-2026',
                Rate__c = 15,
                Country_Pack_Version__c = 'GENERIC-1',
                Effective_From__c =
                    Date.newInstance(2026, 1, 1)
            );

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
                Description__c = 'Inclusive sale',
                Quantity__c = 1,
                Unit_Price__c = 115,
                Discount_Amount__c = 0,
                Net_Amount__c = 115,
                Revenue_Account__c = revenue.Id,
                Tax_Code__c = taxCode.Id
            );

            SABDocumentTaxService.materializeInvoiceTaxes(
                    invoice.Id
                );

            SABInvoiceService.submit(
                invoice.Id
            );

            SABInvoiceService.approve(
                invoice.Id
            );
        }
    }

    @IsTest
    static void taxedInvoicePostsRevenueTaxAndARExactlyOnce() {
        User testUser = getUser();

        System.runAs(testUser) {
            Invoice__c invoice = [
                SELECT Id
                FROM Invoice__c
                WHERE Company__r.Company_Key__c = 'GIV'
                LIMIT 1
            ];

            SABInvoicePostingService.PostingRequest
                request =
                    new SABInvoicePostingService.PostingRequest();

            request.invoiceId =
                invoice.Id;
            request.requestKey =
                'REQ-G6B-INV-001';

            Test.startTest();

            SABInvoicePostingService.PostingResult first =
                SABInvoicePostingService.postApprovedInvoice(
                        request
                    );

            SABInvoicePostingService.PostingResult replay =
                SABInvoicePostingService.postApprovedInvoice(
                        request
                    );

            Test.stopTest();

            System.assertEquals(
                false,
                first.replay
            );

            System.assertEquals(
                true,
                replay.replay
            );

            System.assertEquals(
                first.journalEntryId,
                replay.journalEntryId
            );

            Invoice__c posted = [
                SELECT Status__c,
                       Accounting_Event__c
                FROM Invoice__c
                WHERE Id = :invoice.Id
            ];

            System.assertEquals(
                'Posted',
                posted.Status__c
            );

            System.assertEquals(
                first.accountingEventId,
                posted.Accounting_Event__c
            );

            List<Journal_Entry_Line__c> lines = [
                SELECT GL_Account__r.Account_Code__c,
                       Debit_Base__c,
                       Credit_Base__c,
                       Transaction_Amount__c,
                       Source_Line_Key__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c =
                        :first.journalEntryId
                ORDER BY Line_Number__c
            ];

            System.assertEquals(
                3,
                lines.size()
            );

            System.assertEquals(
                '4100',
                lines[0].GL_Account__r.Account_Code__c
            );

            System.assertEquals(
                Decimal.valueOf('100'),
                lines[0].Credit_Base__c
            );

            System.assertEquals(
                '2201',
                lines[1].GL_Account__r.Account_Code__c
            );

            System.assertEquals(
                Decimal.valueOf('15'),
                lines[1].Credit_Base__c
            );

            System.assertEquals(
                '1200',
                lines[2].GL_Account__r.Account_Code__c
            );

            System.assertEquals(
                Decimal.valueOf('115'),
                lines[2].Debit_Base__c
            );

            Accounting_Event__c eventRecord = [
                SELECT Event_Type__c,
                       Source_Type__c,
                       Source_Record_Id__c,
                       State__c
                FROM Accounting_Event__c
                WHERE Id =
                        :first.accountingEventId
            ];

            System.assertEquals(
                'Invoice',
                eventRecord.Event_Type__c
            );

            System.assertEquals(
                'Invoice__c',
                eventRecord.Source_Type__c
            );

            System.assertEquals(
                'Posted',
                eventRecord.State__c
            );
        }
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                'G6B Invoice Posting User'
            LIMIT 1
        ];
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
                    'GIV-' + code,
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
