@IsTest
private class SABCustomerReceiptServiceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';
    private static final String APPROVE_PERMISSION_SET =
        'SAB_Approve_Financial_Document_Action';
    private static final String POST_PERMISSION_SET =
        'SAB_Post_Journal_Action';

    @TestSetup
    static void setupFixture() {
        User testUser = createUser(
            'SAB Receipt User',
            'sabrcpt'
        );
        assignPermissionSets(testUser);

        System.runAs(testUser) {
            Accounting_Company__c company = createCompany();
            grantCompany(company.Id, testUser.Id);
            createPeriod(company.Id);

            GL_Account__c arControl = createAccount(
                company.Id,
                '1200',
                'Accounts Receivable',
                'Asset',
                'Debit',
                true,
                'AR',
                false
            );

            GL_Account__c bankGL = createAccount(
                company.Id,
                '1100',
                'Main Bank',
                'Asset',
                'Debit',
                false,
                'None',
                true
            );

            Account customer = new Account(
                Name = 'G4B Customer'
            );
            insert customer;

            Party_Accounting_Profile__c profile =
                new Party_Accounting_Profile__c(
                    Company__c = company.Id,
                    Account__c = customer.Id,
                    Profile_Key__c = 'G4B-CUSTOMER',
                    Is_Supplier__c = false,
                    Is_Customer__c = true,
                    Is_Active__c = true,
                    AR_Control_Account__c = arControl.Id
                );
            insert profile;

            Bank_Account__c bank = new Bank_Account__c(
                Name = 'Main BDT Receipt Bank',
                Company__c = company.Id,
                Bank_Name__c = 'Example Bank',
                Currency__c = 'BDT',
                GL_Account__c = bankGL.Id,
                Is_Active__c = true
            );
            insert bank;

            insert new Accounting_Payment__c(
                Company__c = company.Id,
                Party_Profile__c = profile.Id,
                Bank_Account__c = bank.Id,
                Direction__c = 'Receipt',
                Method__c = 'Bank Transfer',
                Reference__c = 'CUST-RCPT-001',
                Amount__c = 1000,
                Transaction_Currency__c = 'BDT',
                Effective_Date__c = Date.newInstance(2026, 9, 18),
                Processing_State__c = 'Draft'
            );
        }
    }

    @IsTest
    static void validDraftAuthorizesAndSubmitsWithoutLedgerEffect() {
        User testUser = getUser();
        Accounting_Payment__c receipt = getFixtureReceipt();

        System.runAs(testUser) {
            Test.startTest();

            SABCustomerReceiptService.ValidationResult validation =
                SABCustomerReceiptService.validateForAuthorization(
                    receipt.Id
                );

            System.assertEquals(
                true,
                validation.isValid,
                String.join(validation.errors, ' | ')
            );

            SABCustomerReceiptService.TransitionResult authorized =
                SABCustomerReceiptService.authorize(
                    receipt.Id,
                    'G4B-AUTH-001'
                );

            SABCustomerReceiptService.TransitionResult submitted =
                SABCustomerReceiptService.submitForProcessing(
                    receipt.Id,
                    'BANK-RCPT-G4B-001',
                    'G4B-SUBMIT-001'
                );

            Test.stopTest();

            System.assertEquals('Authorized', authorized.newState);
            System.assertEquals('Submitted', submitted.newState);

            Accounting_Payment__c refreshed = [
                SELECT Processing_State__c,
                       Functional_Currency__c,
                       Exchange_Rate__c,
                       Provider_Request_Key__c,
                       Accounting_Event__c
                FROM Accounting_Payment__c
                WHERE Id = :receipt.Id
            ];

            System.assertEquals(
                'Submitted',
                refreshed.Processing_State__c
            );
            System.assertEquals(
                'BDT',
                refreshed.Functional_Currency__c
            );
            System.assertEquals(
                Decimal.valueOf('1'),
                refreshed.Exchange_Rate__c
            );
            System.assertEquals(
                'BANK-RCPT-G4B-001',
                refreshed.Provider_Request_Key__c
            );
            System.assertEquals(
                null,
                refreshed.Accounting_Event__c,
                'Submitting a receipt must not imply successful settlement.'
            );

            String receiptIdText = String.valueOf(receipt.Id);
            System.assertEquals(
                0,
                [
                    SELECT COUNT()
                    FROM Accounting_Event__c
                    WHERE Source_Type__c = 'Accounting_Payment__c'
                      AND Source_Record_Id__c = :receiptIdText
                ]
            );
        }
    }

    @IsTest
    static void failedReceiptCanRetryWithoutLedgerEffect() {
        User testUser = getUser();
        Accounting_Payment__c receipt = getFixtureReceipt();

        System.runAs(testUser) {
            SABCustomerReceiptService.authorize(
                receipt.Id,
                'G4B-AUTH-FAIL'
            );
            SABCustomerReceiptService.submitForProcessing(
                receipt.Id,
                'BANK-RCPT-G4B-FAIL',
                'G4B-SUBMIT-FAIL'
            );

            Test.startTest();
            SABCustomerReceiptService.TransitionResult failed =
                SABCustomerReceiptService.markFailed(
                    receipt.Id,
                    'G4B-FAIL-001',
                    'Receipt provider rejected the transaction.'
                );
            SABCustomerReceiptService.TransitionResult retried =
                SABCustomerReceiptService.retryFailed(
                    receipt.Id,
                    'G4B-RETRY-001'
                );
            Test.stopTest();

            System.assertEquals('Failed', failed.newState);
            System.assertEquals('Submitted', retried.newState);

            Accounting_Payment__c refreshed = [
                SELECT Processing_State__c,
                       Provider_Request_Key__c,
                       Accounting_Event__c
                FROM Accounting_Payment__c
                WHERE Id = :receipt.Id
            ];

            System.assertEquals(
                'Submitted',
                refreshed.Processing_State__c
            );
            System.assertEquals(
                'BANK-RCPT-G4B-FAIL',
                refreshed.Provider_Request_Key__c,
                'Retry must preserve the stable provider key.'
            );
            System.assertEquals(null, refreshed.Accounting_Event__c);
        }
    }

    @IsTest
    static void foreignCurrencyReceiptIsBlockedForG4B() {
        User testUser = getUser();
        Accounting_Payment__c receipt = getFixtureReceipt();

        System.runAs(testUser) {
            receipt.Transaction_Currency__c = 'USD';
            receipt.Exchange_Rate__c = Decimal.valueOf('110');
            update receipt;

            Test.startTest();
            SABCustomerReceiptService.ValidationResult validation =
                SABCustomerReceiptService.validateForAuthorization(
                    receipt.Id
                );
            Test.stopTest();

            System.assertEquals(false, validation.isValid);
            System.assert(
                containsError(
                    validation.errors,
                    'same-currency customer receipts only'
                ),
                String.join(validation.errors, ' | ')
            );
        }
    }

    @IsTest
    static void nonCustomerProfileIsRejected() {
        User testUser = getUser();
        Accounting_Payment__c receipt = getFixtureReceipt();

        System.runAs(testUser) {
            GL_Account__c apControl = createAccount(
                receipt.Company__c,
                '2100',
                'Test AP Control',
                'Liability',
                'Credit',
                true,
                'AP',
                false
            );

            Party_Accounting_Profile__c profile = [
                SELECT Id, Is_Customer__c, Is_Supplier__c,
                       AP_Control_Account__c
                FROM Party_Accounting_Profile__c
                WHERE Id = :receipt.Party_Profile__c
            ];

            // Keep the record valid under Customer_Or_Supplier_Required and
            // Supplier_Requires_AP_Account while making it invalid for G4B.
            profile.Is_Customer__c = false;
            profile.Is_Supplier__c = true;
            profile.AP_Control_Account__c = apControl.Id;
            update profile;

            Test.startTest();
            SABCustomerReceiptService.ValidationResult validation =
                SABCustomerReceiptService.validateForAuthorization(
                    receipt.Id
                );
            Test.stopTest();

            System.assertEquals(false, validation.isValid);
            System.assert(
                containsError(validation.errors, 'enabled as a customer'),
                String.join(validation.errors, ' | ')
            );
        }
    }

    private static User createUser(String lastName, String aliasValue) {
        Profile profileRecord = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String seed = String.valueOf(DateTime.now().getTime());

        User testUser = new User(
            Alias = aliasValue,
            Email = aliasValue + '.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = lastName,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profileRecord.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = aliasValue + '.' + seed + '@example.test'
        );

        insert testUser;
        return testUser;
    }

    private static void assignPermissionSets(User testUser) {
        Map<String, Id> permissionSetIds = new Map<String, Id>();

        for (PermissionSet permissionSetRecord : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN (
                :ADMIN_PERMISSION_SET,
                :APPROVE_PERMISSION_SET,
                :POST_PERMISSION_SET
            )
        ]) {
            permissionSetIds.put(
                permissionSetRecord.Name,
                permissionSetRecord.Id
            );
        }

        System.assertEquals(3, permissionSetIds.size());

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId = permissionSetIds.get(ADMIN_PERMISSION_SET)
            ),
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId = permissionSetIds.get(APPROVE_PERMISSION_SET)
            ),
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId = permissionSetIds.get(POST_PERMISSION_SET)
            )
        };
    }

    private static Accounting_Company__c createCompany() {
        Accounting_Company__c company = new Accounting_Company__c(
            Name__c = 'G4B Receipt Company',
            Company_Key__c = 'G4R',
            Country_Code__c = 'BD',
            Functional_Currency__c = 'BDT',
            Fiscal_Calendar_Type__c = 'Calendar',
            Fiscal_Year_Start_Month__c = 1,
            Setup_Status__c = 'Active',
            Is_Active__c = true
        );
        insert company;
        return company;
    }

    private static void grantCompany(Id companyId, Id userId) {
        insert new Company_User_Access__c(
            Company__c = companyId,
            User__c = userId,
            Is_Active__c = true,
            Effective_From__c = Date.today(),
            Grant_Key__c = 'G4R-ACCESS',
            Role__c = 'Finance Manager'
        );
    }

    private static void createPeriod(Id companyId) {
        insert new Accounting_Period__c(
            Name = 'September 2026',
            Company__c = companyId,
            Company_Period_Key__c = 'G4R-2026-09',
            Period_Key__c = '2026-09-G4R',
            Start_Date__c = Date.newInstance(2026, 9, 1),
            End_Date__c = Date.newInstance(2026, 9, 30),
            Fiscal_Year__c = 2026,
            Fiscal_Quarter__c = 3,
            Period_Number__c = 9,
            Status__c = 'Open'
        );
    }

    private static GL_Account__c createAccount(
        Id companyId,
        String code,
        String displayName,
        String accountType,
        String normalBalance,
        Boolean control,
        String controlType,
        Boolean manualPostingAllowed
    ) {
        GL_Account__c accountRecord = new GL_Account__c(
            Name = displayName,
            Company__c = companyId,
            Company_Account_Key__c = 'G4R-' + code,
            Account_Code__c = code,
            Account_Type__c = accountType,
            Normal_Balance__c = normalBalance,
            Is_Active__c = true,
            Is_Control_Account__c = control,
            Control_Type__c = controlType,
            Manual_Posting_Allowed__c = manualPostingAllowed
        );
        insert accountRecord;
        return accountRecord;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB Receipt User'
            LIMIT 1
        ];
    }

    private static Accounting_Payment__c getFixtureReceipt() {
        return [
            SELECT Id, Company__c, Party_Profile__c,
                   Transaction_Currency__c,
                   Exchange_Rate__c,
                   Processing_State__c
            FROM Accounting_Payment__c
            WHERE Reference__c = 'CUST-RCPT-001'
            LIMIT 1
        ];
    }

    private static Boolean containsError(
        List<String> errors,
        String token
    ) {
        for (String errorMessage : errors) {
            if (
                errorMessage != null
                && errorMessage.contains(token)
            ) {
                return true;
            }
        }
        return false;
    }
}
