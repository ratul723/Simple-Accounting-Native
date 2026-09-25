@IsTest
private class SABSupplierPaymentPostingServiceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String APPROVE_PERMISSION_SET =
        'SAB_Approve_Financial_Document_Action';

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
                Alias =
                    'sabpayp',
                Email =
                    'sabpayp.'
                    + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    'SAB Payment Posting User',
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    profileRecord.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    'sabpayp.'
                    + seed
                    + '@example.test'
            );

        insert testUser;

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

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c =
                        'G3C Posting Company',
                    Company_Key__c =
                        'G3P',
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

            insert new Company_User_Access__c(
                Company__c =
                    company.Id,
                User__c =
                    testUser.Id,
                Is_Active__c =
                    true,
                Effective_From__c =
                    Date.today(),
                Grant_Key__c =
                    'G3P-ACCESS',
                Role__c =
                    'Finance Manager'
            );

            insert new Accounting_Period__c(
                Name =
                    'September 2026',
                Company__c =
                    company.Id,
                Company_Period_Key__c =
                    'G3P-2026-09',
                Period_Key__c =
                    '2026-09-G3P',
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

            GL_Account__c apControl =
                account(
                    company.Id,
                    '2100',
                    'AP Control',
                    'Liability',
                    'Credit',
                    true,
                    'AP',
                    false
                );

            GL_Account__c bankGL =
                account(
                    company.Id,
                    '1110',
                    'Settlement Bank',
                    'Asset',
                    'Debit',
                    false,
                    'None',
                    true
                );

            Account supplier =
                new Account(
                    Name =
                        'Posting Supplier'
                );

            insert supplier;

            Party_Accounting_Profile__c profile =
                new Party_Accounting_Profile__c(
                    Company__c =
                        company.Id,
                    Account__c =
                        supplier.Id,
                    Profile_Key__c =
                        'G3P-SUPPLIER',
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
                        'Settlement BDT Bank',
                    Company__c =
                        company.Id,
                    Bank_Name__c =
                        'Example Settlement Bank',
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
                    'POST-PAY-001',
                Amount__c =
                    750,
                Transaction_Currency__c =
                    'BDT',
                Effective_Date__c =
                    Date.newInstance(
                        2026,
                        9,
                        20
                    ),
                Processing_State__c =
                    'Draft'
            );
        }
    }

    @IsTest
    static void successfulDisbursementPostsAPAndBankExactlyOnce() {
        User testUser =
            getUser();

        Accounting_Payment__c payment =
            getPayment();

        System.runAs(testUser) {
            SABSupplierPaymentService.authorize(
                payment.Id,
                'G3P-AUTH-001'
            );

            SABSupplierPaymentService.submitForExecution(
                payment.Id,
                'BANK-G3P-001',
                'G3P-SUBMIT-001'
            );

            Test.startTest();

            SABSupplierPaymentPostingService.PostingRequest request =
                new SABSupplierPaymentPostingService.PostingRequest();

            request.paymentId =
                payment.Id;
            request.requestKey =
                'G3P-SUCCESS-001';

            SABSupplierPaymentPostingService.PostingResult firstResult =
                SABSupplierPaymentPostingService.recordSucceededAndPost(
                    request
                );

            SABSupplierPaymentPostingService.PostingResult replayResult =
                SABSupplierPaymentPostingService.recordSucceededAndPost(
                    request
                );

            Test.stopTest();

            System.assertEquals(
                false,
                firstResult.replay
            );

            System.assertEquals(
                true,
                replayResult.replay
            );

            System.assertEquals(
                firstResult.journalEntryId,
                replayResult.journalEntryId
            );

            System.assertEquals(
                firstResult.accountingEventId,
                replayResult.accountingEventId
            );

            Accounting_Payment__c succeeded = [
                SELECT Processing_State__c,
                       Accounting_Event__c,
                       Provider_Request_Key__c
                FROM Accounting_Payment__c
                WHERE Id = :payment.Id
            ];

            System.assertEquals(
                'Succeeded',
                succeeded.Processing_State__c
            );

            System.assertEquals(
                firstResult.accountingEventId,
                succeeded.Accounting_Event__c
            );

            Accounting_Event__c eventRecord = [
                SELECT Event_Type__c,
                       Source_Type__c,
                       Source_Record_Id__c,
                       State__c,
                       Journal_Entry__c
                FROM Accounting_Event__c
                WHERE Id =
                    :firstResult.accountingEventId
            ];

            System.assertEquals(
                'Payment Disbursement',
                eventRecord.Event_Type__c
            );

            System.assertEquals(
                'Accounting_Payment__c',
                eventRecord.Source_Type__c
            );

            System.assertEquals(
                String.valueOf(
                    payment.Id
                ),
                eventRecord.Source_Record_Id__c
            );

            System.assertEquals(
                'Posted',
                eventRecord.State__c
            );

            Journal_Entry__c journal = [
                SELECT Status__c,
                       Entry_Type__c,
                       Posting_Key__c,
                       Accounting_Event__c
                FROM Journal_Entry__c
                WHERE Id =
                    :firstResult.journalEntryId
            ];

            System.assertEquals(
                'Posted',
                journal.Status__c
            );

            System.assertEquals(
                'Subledger',
                journal.Entry_Type__c
            );

            System.assertEquals(
                firstResult.accountingEventId,
                journal.Accounting_Event__c
            );

            List<Journal_Entry_Line__c> lines = [
                SELECT GL_Account__r.Account_Code__c,
                       GL_Account__r.Account_Type__c,
                       Debit_Base__c,
                       Credit_Base__c,
                       Transaction_Amount__c,
                       Transaction_Currency__c,
                       Source_Line_Key__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c =
                    :journal.Id
                ORDER BY Line_Number__c
            ];

            System.assertEquals(
                2,
                lines.size(),
                'Supplier Payment must post exactly one AP line and one Bank line.'
            );

            System.assertEquals(
                'Liability',
                lines[0].GL_Account__r.Account_Type__c
            );

            System.assertEquals(
                Decimal.valueOf('750'),
                lines[0].Debit_Base__c
            );

            System.assertEquals(
                Decimal.valueOf('0'),
                lines[0].Credit_Base__c
            );

            System.assertEquals(
                'Asset',
                lines[1].GL_Account__r.Account_Type__c
            );

            System.assertEquals(
                Decimal.valueOf('0'),
                lines[1].Debit_Base__c
            );

            System.assertEquals(
                Decimal.valueOf('750'),
                lines[1].Credit_Base__c
            );

            System.assertEquals(
                0,
                [
                    SELECT COUNT()
                    FROM Payment_Allocation__c
                    WHERE Payment__c =
                        :payment.Id
                ],
                'G3C must not invent allocations; G3D owns bill allocation.'
            );

            String paymentIdText =
                String.valueOf(
                    payment.Id
                );

            System.assertEquals(
                1,
                [
                    SELECT COUNT()
                    FROM Accounting_Event__c
                    WHERE Source_Type__c =
                        'Accounting_Payment__c'
                      AND Source_Record_Id__c =
                        :paymentIdText
                ],
                'Successful replay must not duplicate the accounting event.'
            );
        }
    }

    @IsTest
    static void submittedPaymentIsNotPostedUntilSuccessIsRecorded() {
        User testUser =
            getUser();

        Accounting_Payment__c payment =
            getPayment();

        System.runAs(testUser) {
            SABSupplierPaymentService.authorize(
                payment.Id,
                'G3P-AUTH-PENDING'
            );

            SABSupplierPaymentService.submitForExecution(
                payment.Id,
                'BANK-G3P-PENDING',
                'G3P-SUBMIT-PENDING'
            );

            Test.startTest();

            Accounting_Payment__c pending = [
                SELECT Processing_State__c,
                       Accounting_Event__c
                FROM Accounting_Payment__c
                WHERE Id = :payment.Id
            ];

            String paymentIdText =
                String.valueOf(
                    payment.Id
                );

            Integer eventCount = [
                SELECT COUNT()
                FROM Accounting_Event__c
                WHERE Source_Type__c =
                    'Accounting_Payment__c'
                  AND Source_Record_Id__c =
                    :paymentIdText
            ];

            Test.stopTest();

            System.assertEquals(
                'Submitted',
                pending.Processing_State__c
            );

            System.assertEquals(
                null,
                pending.Accounting_Event__c
            );

            System.assertEquals(
                0,
                eventCount
            );
        }
    }

    private static GL_Account__c account(
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
                    'G3P-'
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
                'SAB Payment Posting User'
            LIMIT 1
        ];
    }

    private static Accounting_Payment__c getPayment() {
        return [
            SELECT Id
            FROM Accounting_Payment__c
            WHERE Reference__c =
                'POST-PAY-001'
            LIMIT 1
        ];
    }
}
