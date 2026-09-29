@IsTest
private class SABFXRevaluationPreviewServiceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String FX_PERMISSION_SET =
        'SAB_Run_FX_Revaluation_Action';

    @TestSetup
    static void setupFixture() {
        User testUser = createUser();
        assignPermissions(testUser);

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c = 'G7A FX Company',
                    Company_Key__c = 'GFX',
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
                Grant_Key__c = 'G7A-FX-ACCESS',
                Role__c = 'Finance Manager'
            );

            Accounting_Period__c period =
                new Accounting_Period__c(
                    Name = 'September 2026',
                    Company__c = company.Id,
                    Company_Period_Key__c = 'GFX-2026-09',
                    Period_Key__c = 'GFX-2026-09',
                    Start_Date__c =
                        Date.newInstance(2026, 9, 1),
                    End_Date__c =
                        Date.newInstance(2026, 9, 30),
                    Fiscal_Year__c = 2026,
                    Fiscal_Quarter__c = 3,
                    Period_Number__c = 9,
                    Status__c = 'Open'
                );
            insert period;

            GL_Account__c ar =
                makeAccount(
                    company.Id,
                    '1200',
                    'Accounts Receivable',
                    'Asset',
                    'Debit',
                    true,
                    'AR'
                );

            GL_Account__c ap =
                makeAccount(
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
                    Name = 'G7A Customer'
                );
            insert customerAccount;

            Account supplierAccount =
                new Account(
                    Name = 'G7A Supplier'
                );
            insert supplierAccount;

            Party_Accounting_Profile__c customer =
                new Party_Accounting_Profile__c(
                    Account__c = customerAccount.Id,
                    Company__c = company.Id,
                    Profile_Key__c = 'G7A-CUSTOMER',
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
                    Profile_Key__c = 'G7A-SUPPLIER',
                    Is_Active__c = true,
                    Is_Customer__c = false,
                    Is_Supplier__c = true,
                    AP_Control_Account__c = ap.Id
                );
            insert supplier;

            createApprovedRate(
                'USD',
                'BDT',
                'Closing',
                110,
                Datetime.newInstance(
                    Date.newInstance(2026, 9, 30),
                    Time.newInstance(12, 0, 0, 0)
                ),
                'G7A-USD-BDT-CLOSE'
            );

            Invoice__c invoice =
                new Invoice__c(
                    Company__c = company.Id,
                    Party_Profile__c = customer.Id,
                    Document_Date__c =
                        Date.newInstance(2026, 9, 5),
                    Accounting_Date__c =
                        Date.newInstance(2026, 9, 5),
                    Due_Date__c =
                        Date.newInstance(2026, 10, 5),
                    Document_Type__c = 'Invoice',
                    Status__c = 'Draft',
                    Transaction_Currency__c = 'USD',
                    Functional_Currency__c = 'BDT',
                    Exchange_Rate__c = 100,
                    Exchange_Rate_Date__c =
                        Date.newInstance(2026, 9, 5),
                    Subtotal__c = 10,
                    Tax_Total__c = 0,
                    Total__c = 10
                );
            insert invoice;

            invoice.Status__c = 'Posted';
            update invoice;

            Supplier_Bill__c bill =
                new Supplier_Bill__c(
                    Company__c = company.Id,
                    Supplier_Profile__c = supplier.Id,
                    Document_Type__c = 'Bill',
                    Document_Date__c =
                        Date.newInstance(2026, 9, 6),
                    Accounting_Date__c =
                        Date.newInstance(2026, 9, 6),
                    Due_Date__c =
                        Date.newInstance(2026, 10, 6),
                    Vendor_Reference__c = 'G7A-FX-BILL',
                    Transaction_Currency__c = 'USD',
                    Functional_Currency__c = 'BDT',
                    Exchange_Rate__c = 100,
                    Status__c = 'Draft',
                    Subtotal__c = 8,
                    Tax_Total__c = 0,
                    Total__c = 8
                );
            insert bill;

            SABSupplierBillService.lifecycleMutationInProgress =
                true;

            try {
                bill.Status__c = 'Posted';
                update bill;
            } finally {
                SABSupplierBillService.lifecycleMutationInProgress =
                    false;
            }
        }
    }

    @IsTest
    static void previewBuildsSignedARAndAPAdjustments() {
        User testUser = getUser();

        System.runAs(testUser) {
            SABFXRevaluationPreviewService.PreviewRequest request =
                new SABFXRevaluationPreviewService.PreviewRequest();

            request.companyId = getCompany().Id;
            request.accountingPeriodId = getPeriod().Id;
            request.runKey = 'G7A-PREVIEW-001';
            request.reversalPolicy =
                'First Day of Next Period';

            Test.startTest();

            SABFXRevaluationPreviewService.PreviewResult result =
                SABFXRevaluationPreviewService.preview(
                    request
                );

            Test.stopTest();

            System.assertEquals(
                'Preview',
                result.status
            );

            System.assertEquals(
                1,
                result.arLineCount
            );

            System.assertEquals(
                1,
                result.apLineCount
            );

            // AR: 10 USD @ 100 = 1000 carrying,
            // closing @ 110 = 1100 => debit AR 100.
            System.assertEquals(
                Decimal.valueOf('100.0000'),
                result.arAdjustmentTotal
            );

            // AP: 8 USD @ 100 = 800 carrying,
            // closing @ 110 = 880 => credit AP 80.
            System.assertEquals(
                Decimal.valueOf('-80.0000'),
                result.apAdjustmentTotal
            );

            System.assertEquals(
                Decimal.valueOf('20.0000'),
                result.signedAdjustmentTotal
            );

            List<FX_Revaluation_Line__c> lines = [
                SELECT Source_Type__c,
                       Source_Record_Id__c,
                       Source_GL_Account__c,
                       Transaction_Currency__c,
                       Outstanding_Amount__c,
                       Carrying_Amount__c,
                       Revalued_Amount__c,
                       Adjustment_Amount__c,
                       Applied_Rate__c,
                       Exchange_Rate__c
                FROM FX_Revaluation_Line__c
                WHERE FX_Revaluation_Run__c =
                        :result.runId
                ORDER BY Source_Type__c
            ];

            System.assertEquals(
                2,
                lines.size()
            );

            for (
                FX_Revaluation_Line__c line :
                lines
            ) {
                System.assertEquals(
                    'USD',
                    line.Transaction_Currency__c
                );

                System.assertEquals(
                    Decimal.valueOf('110'),
                    line.Applied_Rate__c
                );

                System.assertNotEquals(
                    null,
                    line.Exchange_Rate__c
                );

                System.assertNotEquals(
                    null,
                    line.Source_GL_Account__c
                );
            }
        }
    }

    @IsTest
    static void previewRunKeyIsIdempotent() {
        User testUser = getUser();

        System.runAs(testUser) {
            SABFXRevaluationPreviewService.PreviewRequest request =
                new SABFXRevaluationPreviewService.PreviewRequest();

            request.companyId = getCompany().Id;
            request.accountingPeriodId = getPeriod().Id;
            request.runKey = 'G7A-PREVIEW-REPLAY';
            request.reversalPolicy =
                'No Automatic Reversal';

            SABFXRevaluationPreviewService.PreviewResult first =
                SABFXRevaluationPreviewService.preview(
                    request
                );

            Test.startTest();

            SABFXRevaluationPreviewService.PreviewResult second =
                SABFXRevaluationPreviewService.preview(
                    request
                );

            Test.stopTest();

            System.assertEquals(
                first.runId,
                second.runId
            );

            System.assertEquals(
                true,
                second.replay
            );

            Integer runCount = [
                SELECT COUNT()
                FROM FX_Revaluation_Run__c
                WHERE Run_Key__c =
                        'G7A-PREVIEW-REPLAY'
            ];

            System.assertEquals(
                1,
                runCount
            );
        }
    }

    @IsTest
    static void sameCurrencySourcesAreExcluded() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Company__c company =
                getCompany();

            Party_Accounting_Profile__c customer = [
                SELECT Id
                FROM Party_Accounting_Profile__c
                WHERE Profile_Key__c =
                        'G7A-CUSTOMER'
                LIMIT 1
            ];

            Invoice__c bdtInvoice =
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
                    Exchange_Rate_Date__c =
                        Date.newInstance(2026, 9, 10),
                    Subtotal__c = 500,
                    Tax_Total__c = 0,
                    Total__c = 500
                );
            insert bdtInvoice;

            bdtInvoice.Status__c = 'Posted';
            update bdtInvoice;

            SABFXRevaluationPreviewService.PreviewRequest request =
                new SABFXRevaluationPreviewService.PreviewRequest();

            request.companyId = company.Id;
            request.accountingPeriodId = getPeriod().Id;
            request.runKey = 'G7A-BDT-EXCLUDE';

            SABFXRevaluationPreviewService.PreviewResult result =
                SABFXRevaluationPreviewService.preview(
                    request
                );

            System.assertEquals(
                1,
                result.arLineCount,
                'Only the USD AR exposure should be included.'
            );
        }
    }

    private static Exchange_Rate__c createApprovedRate(
        String fromCurrency,
        String toCurrency,
        String rateType,
        Decimal rate,
        Datetime effectiveAt,
        String rateKey
    ) {
        Exchange_Rate__c row =
            new Exchange_Rate__c(
                From_Currency__c = fromCurrency,
                To_Currency__c = toCurrency,
                Rate_Type__c = rateType,
                Effective_Date_Time__c = effectiveAt,
                Rate__c = rate,
                Source__c = 'G7A Test',
                Approved__c = true,
                Approved_By__c = UserInfo.getUserId(),
                Rate_Key__c = rateKey
            );

        insert row;
        return row;
    }

    private static GL_Account__c makeAccount(
        Id companyId,
        String code,
        String displayName,
        String accountType,
        String normalBalance,
        Boolean isControl,
        String controlType
    ) {
        GL_Account__c row =
            new GL_Account__c(
                Name = displayName,
                Company__c = companyId,
                Company_Account_Key__c =
                    'GFX-' + code,
                Account_Code__c = code,
                Account_Type__c = accountType,
                Normal_Balance__c = normalBalance,
                Is_Active__c = true,
                Is_Control_Account__c = isControl,
                Control_Type__c = controlType,
                Manual_Posting_Allowed__c = false
            );

        insert row;
        return row;
    }

    private static User createUser() {
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

        User row =
            new User(
                Alias = 'g7afx',
                Email =
                    'g7afx.'
                    + seed
                    + '@example.test',
                EmailEncodingKey = 'UTF-8',
                LastName = 'G7A FX User',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = profileRecord.Id,
                TimeZoneSidKey = 'Asia/Dhaka',
                Username =
                    'g7afx.'
                    + seed
                    + '@example.test'
            );

        insert row;
        return row;
    }

    private static void assignPermissions(
        User testUser
    ) {
        Map<String, Id> ids =
            new Map<String, Id>();

        for (PermissionSet row : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN (
                :ADMIN_PERMISSION_SET,
                :FX_PERMISSION_SET
            )
        ]) {
            ids.put(
                row.Name,
                row.Id
            );
        }

        System.assertEquals(
            2,
            ids.size()
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId =
                    ids.get(
                        ADMIN_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId =
                    ids.get(
                        FX_PERMISSION_SET
                    )
            )
        };
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'G7A FX User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getCompany() {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c = 'GFX'
            LIMIT 1
        ];
    }

    private static Accounting_Period__c getPeriod() {
        return [
            SELECT Id
            FROM Accounting_Period__c
            WHERE Period_Key__c = 'GFX-2026-09'
            LIMIT 1
        ];
    }
}
