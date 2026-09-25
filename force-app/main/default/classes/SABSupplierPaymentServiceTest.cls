@IsTest
private class SABSupplierPaymentServiceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String APPROVE_PERMISSION_SET =
        'SAB_Approve_Financial_Document_Action';

    private static final String POST_PERMISSION_SET =
        'SAB_Post_Journal_Action';

    @TestSetup
    static void setupFixture() {
        User testUser =
            createUser(
                'SAB Payment User',
                'sabpay'
            );

        assignPermissionSets(
            testUser
        );

        System.runAs(testUser) {
            Accounting_Company__c company =
                createCompany();

            grantCompany(
                company.Id,
                testUser.Id
            );

            createPeriod(
                company.Id
            );

            GL_Account__c apControl =
                createAccount(
                    company.Id,
                    '2000',
                    'Accounts Payable',
                    'Liability',
                    'Credit',
                    true,
                    'AP',
                    false
                );

            GL_Account__c bankGL =
                createAccount(
                    company.Id,
                    '1100',
                    'Main Bank',
                    'Asset',
                    'Debit',
                    false,
                    'None',
                    true
                );

            Account supplier =
                new Account(
                    Name = 'G3C Supplier'
                );

            insert supplier;

            Party_Accounting_Profile__c profile =
                new Party_Accounting_Profile__c(
                    Company__c =
                        company.Id,
                    Account__c =
                        supplier.Id,
                    Profile_Key__c =
                        'G3C-SUPPLIER',
                    Is_Supplier__c =
                        true,
                    Is_Customer__c =
                        false,
                    Is_Active__c =
                        true,
                    AP_Control_Account__c =
                        apControl.Id
                );

            insert profile;

            Bank_Account__c bank =
                new Bank_Account__c(
                    Name =
                        'Main BDT Bank',
                    Company__c =
                        company.Id,
                    Bank_Name__c =
                        'Example Bank',
                    Currency__c =
                        'BDT',
                    GL_Account__c =
                        bankGL.Id,
                    Is_Active__c =
                        true
                );

            insert bank;

            insert new Accounting_Payment__c(
                Company__c =
                    company.Id,
                Party_Profile__c =
                    profile.Id,
                Bank_Account__c =
                    bank.Id,
                Direction__c =
                    'Disbursement',
                Method__c =
                    'Bank Transfer',
                Reference__c =
                    'SUP-PAY-001',
                Amount__c =
                    500,
                Transaction_Currency__c =
                    'BDT',
                Effective_Date__c =
                    Date.newInstance(
                        2026,
                        9,
                        15
                    ),
                Processing_State__c =
                    'Draft'
            );
        }
    }

    @IsTest
    static void validDraftAuthorizesAndSubmitsWithoutLedgerEffect() {
        User testUser =
            getUser();

        Accounting_Payment__c payment =
            getFixturePayment();

        System.runAs(testUser) {
            Test.startTest();

            SABSupplierPaymentService.ValidationResult validation =
                SABSupplierPaymentService.validateForAuthorization(
                    payment.Id
                );

            System.assertEquals(
                true,
                validation.isValid,
                String.join(
                    validation.errors,
                    ' | '
                )
            );

            SABSupplierPaymentService.TransitionResult authorized =
                SABSupplierPaymentService.authorize(
                    payment.Id,
                    'G3C-AUTH-001'
                );

            SABSupplierPaymentService.TransitionResult submitted =
                SABSupplierPaymentService.submitForExecution(
                    payment.Id,
                    'BANK-REQ-G3C-001',
                    'G3C-SUBMIT-001'
                );

            Test.stopTest();

            System.assertEquals(
                'Authorized',
                authorized.newState
            );

            System.assertEquals(
                'Submitted',
                submitted.newState
            );

            Accounting_Payment__c refreshed = [
                SELECT Processing_State__c,
                       Functional_Currency__c,
                       Exchange_Rate__c,
                       Provider_Request_Key__c,
                       Accounting_Event__c
                FROM Accounting_Payment__c
                WHERE Id = :payment.Id
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
                'BANK-REQ-G3C-001',
                refreshed.Provider_Request_Key__c
            );

            System.assertEquals(
                null,
                refreshed.Accounting_Event__c,
                'Submission to a bank/provider must not imply successful cash settlement.'
            );

            String paymentIdText =
                String.valueOf(
                    payment.Id
                );

            System.assertEquals(
                0,
                [
                    SELECT COUNT()
                    FROM Accounting_Event__c
                    WHERE Source_Type__c =
                        'Accounting_Payment__c'
                      AND Source_Record_Id__c =
                        :paymentIdText
                ]
            );
        }
    }

    @IsTest
    static void failedExecutionCanRetryWithoutSettlingCash() {
        User testUser =
            getUser();

        Accounting_Payment__c payment =
            getFixturePayment();

        System.runAs(testUser) {
            SABSupplierPaymentService.authorize(
                payment.Id,
                'G3C-AUTH-FAIL'
            );

            SABSupplierPaymentService.submitForExecution(
                payment.Id,
                'BANK-REQ-G3C-FAIL',
                'G3C-SUBMIT-FAIL'
            );

            Test.startTest();

            SABSupplierPaymentService.TransitionResult failed =
                SABSupplierPaymentService.markFailed(
                    payment.Id,
                    'G3C-FAIL-001',
                    'Provider rejected the instruction.'
                );

            SABSupplierPaymentService.TransitionResult retried =
                SABSupplierPaymentService.retryFailed(
                    payment.Id,
                    'G3C-RETRY-001'
                );

            Test.stopTest();

            System.assertEquals(
                'Failed',
                failed.newState
            );

            System.assertEquals(
                'Submitted',
                retried.newState
            );

            Accounting_Payment__c refreshed = [
                SELECT Processing_State__c,
                       Provider_Request_Key__c,
                       Accounting_Event__c
                FROM Accounting_Payment__c
                WHERE Id = :payment.Id
            ];

            System.assertEquals(
                'Submitted',
                refreshed.Processing_State__c
            );

            System.assertEquals(
                'BANK-REQ-G3C-FAIL',
                refreshed.Provider_Request_Key__c,
                'Retry must preserve the stable external request key.'
            );

            System.assertEquals(
                null,
                refreshed.Accounting_Event__c
            );

            String paymentIdText =
                String.valueOf(
                    payment.Id
                );

            System.assertEquals(
                0,
                [
                    SELECT COUNT()
                    FROM Accounting_Event__c
                    WHERE Source_Type__c =
                        'Accounting_Payment__c'
                      AND Source_Record_Id__c =
                        :paymentIdText
                ]
            );
        }
    }

    @IsTest
    static void foreignCurrencyIsBlockedUntilSettlementFxPolicyExists() {
        User testUser =
            getUser();

        Accounting_Payment__c payment =
            getFixturePayment();

        System.runAs(testUser) {
            payment.Transaction_Currency__c =
                'USD';
            payment.Exchange_Rate__c =
                Decimal.valueOf('110');

            update payment;

            Test.startTest();

            SABSupplierPaymentService.ValidationResult validation =
                SABSupplierPaymentService.validateForAuthorization(
                    payment.Id
                );

            Test.stopTest();

            System.assertEquals(
                false,
                validation.isValid
            );

            System.assert(
                containsError(
                    validation.errors,
                    'same-currency supplier disbursements only'
                ),
                String.join(
                    validation.errors,
                    ' | '
                )
            );
        }
    }

    @IsTest
    static void directStateAndProviderKeyChangesAreBlocked() {
        User testUser =
            getUser();

        Accounting_Payment__c payment =
            getFixturePayment();

        System.runAs(testUser) {
            payment.Processing_State__c =
                'Submitted';

            Boolean stateBlocked =
                false;

            Test.startTest();

            try {
                update payment;
            } catch (DmlException ex) {
                stateBlocked =
                    ex.getMessage().contains(
                        'controlled Supplier Payment service'
                    );
            }

            Test.stopTest();

            System.assertEquals(
                true,
                stateBlocked
            );

            Accounting_Payment__c fresh = [
                SELECT Id,
                       Provider_Request_Key__c
                FROM Accounting_Payment__c
                WHERE Id = :payment.Id
            ];

            fresh.Provider_Request_Key__c =
                'DIRECT-EDIT';

            Boolean providerKeyBlocked =
                false;

            try {
                update fresh;
            } catch (DmlException ex) {
                providerKeyBlocked =
                    ex.getMessage().contains(
                        'Provider Request Key is system-managed'
                    );
            }

            System.assertEquals(
                true,
                providerKeyBlocked
            );
        }
    }

    private static User createUser(
        String lastName,
        String aliasValue
    ) {
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
                Alias = aliasValue,
                Email =
                    aliasValue
                    + '.'
                    + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    lastName,
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    profileRecord.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    aliasValue
                    + '.'
                    + seed
                    + '@example.test'
            );

        insert testUser;
        return testUser;
    }

    private static void assignPermissionSets(
        User testUser
    ) {
        Map<String, Id> permissionSetIds =
            new Map<String, Id>();

        for (
            PermissionSet permissionSetRecord
            : [
                SELECT Id, Name
                FROM PermissionSet
                WHERE Name IN (
                    :ADMIN_PERMISSION_SET,
                    :APPROVE_PERMISSION_SET,
                    :POST_PERMISSION_SET
                )
            ]
        ) {
            permissionSetIds.put(
                permissionSetRecord.Name,
                permissionSetRecord.Id
            );
        }

        System.assertEquals(
            3,
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
                        APPROVE_PERMISSION_SET
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
    }

    private static Accounting_Company__c createCompany() {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    'G3C Company',
                Company_Key__c =
                    'G3C',
                Country_Code__c =
                    'BD',
                Functional_Currency__c =
                    'BDT',
                Fiscal_Calendar_Type__c =
                    'Calendar',
                Fiscal_Year_Start_Month__c =
                    1,
                Setup_Status__c =
                    'Active',
                Is_Active__c =
                    true
            );

        insert company;
        return company;
    }

    private static void grantCompany(
        Id companyId,
        Id userId
    ) {
        insert new Company_User_Access__c(
            Company__c =
                companyId,
            User__c =
                userId,
            Is_Active__c =
                true,
            Effective_From__c =
                Date.today(),
            Grant_Key__c =
                'G3C-ACCESS',
            Role__c =
                'Finance Manager'
        );
    }

    private static void createPeriod(
        Id companyId
    ) {
        insert new Accounting_Period__c(
            Name =
                'September 2026',
            Company__c =
                companyId,
            Company_Period_Key__c =
                'G3C-2026-09',
            Period_Key__c =
                '2026-09-G3C',
            Start_Date__c =
                Date.newInstance(
                    2026,
                    9,
                    1
                ),
            End_Date__c =
                Date.newInstance(
                    2026,
                    9,
                    30
                ),
            Fiscal_Year__c =
                2026,
            Fiscal_Quarter__c =
                3,
            Period_Number__c =
                9,
            Status__c =
                'Open'
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
        GL_Account__c accountRecord =
            new GL_Account__c(
                Name =
                    displayName,
                Company__c =
                    companyId,
                Company_Account_Key__c =
                    'G3C-'
                    + code,
                Account_Code__c =
                    code,
                Account_Type__c =
                    accountType,
                Normal_Balance__c =
                    normalBalance,
                Is_Active__c =
                    true,
                Is_Control_Account__c =
                    control,
                Control_Type__c =
                    controlType,
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
                'SAB Payment User'
            LIMIT 1
        ];
    }

    private static Accounting_Payment__c
        getFixturePayment()
    {
        return [
            SELECT Id,
                   Transaction_Currency__c,
                   Exchange_Rate__c,
                   Processing_State__c
            FROM Accounting_Payment__c
            WHERE Reference__c =
                'SUP-PAY-001'
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
                && errorMessage.contains(
                    token
                )
            ) {
                return true;
            }
        }

        return false;
    }
}
