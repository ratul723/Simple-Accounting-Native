@IsTest
private class SABCustomerReceiptAllocationTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';
    private static final String APPROVE_PERMISSION_SET =
        'SAB_Approve_Financial_Document_Action';
    private static final String POST_PERMISSION_SET =
        'SAB_Post_Journal_Action';
    private static final String ALLOCATION_PERMISSION_SET =
        'SAB_Payment_Allocation_User';

    @TestSetup
    static void setupFixture() {
        User testUser = createUser();
        assignPermissionSets(testUser);

        System.runAs(testUser) {
            Accounting_Company__c company =
                createCompany(
                    'G4C Company',
                    'G4C'
                );

            grantCompany(
                company.Id,
                testUser.Id,
                'G4C-ACCESS'
            );

            createPeriod(
                company.Id,
                'G4C-2026-09',
                '2026-09-G4C'
            );

            GL_Account__c arControl =
                createAccount(
                    company.Id,
                    '1200',
                    'Accounts Receivable',
                    'Asset',
                    'Debit',
                    true,
                    'AR',
                    false,
                    'G4C-1200'
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
                    true,
                    'G4C-1100'
                );

            Account customer =
                new Account(
                    Name = 'G4C Customer'
                );
            insert customer;

            Party_Accounting_Profile__c customerProfile =
                new Party_Accounting_Profile__c(
                    Company__c =
                        company.Id,
                    Account__c =
                        customer.Id,
                    Profile_Key__c =
                        'G4C-CUSTOMER',
                    Is_Customer__c =
                        true,
                    Is_Supplier__c =
                        false,
                    Is_Active__c =
                        true,
                    AR_Control_Account__c =
                        arControl.Id
                );
            insert customerProfile;

            Account otherCustomer =
                new Account(
                    Name = 'G4C Other Customer'
                );
            insert otherCustomer;

            Party_Accounting_Profile__c otherProfile =
                new Party_Accounting_Profile__c(
                    Company__c =
                        company.Id,
                    Account__c =
                        otherCustomer.Id,
                    Profile_Key__c =
                        'G4C-OTHER-CUSTOMER',
                    Is_Customer__c =
                        true,
                    Is_Supplier__c =
                        false,
                    Is_Active__c =
                        true,
                    AR_Control_Account__c =
                        arControl.Id
                );
            insert otherProfile;

            Bank_Account__c bank =
                new Bank_Account__c(
                    Name =
                        'G4C BDT Bank',
                    Company__c =
                        company.Id,
                    Bank_Name__c =
                        'G4C Bank',
                    Currency__c =
                        'BDT',
                    GL_Account__c =
                        bankGL.Id,
                    Is_Active__c =
                        true
                );
            insert bank;

            Accounting_Payment__c succeededReceipt =
                new Accounting_Payment__c(
                    Company__c =
                        company.Id,
                    Party_Profile__c =
                        customerProfile.Id,
                    Bank_Account__c =
                        bank.Id,
                    Direction__c =
                        'Receipt',
                    Method__c =
                        'Bank Transfer',
                    Reference__c =
                        'G4C-RCPT-001',
                    Amount__c =
                        900,
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

            Accounting_Payment__c draftReceipt =
                new Accounting_Payment__c(
                    Company__c =
                        company.Id,
                    Party_Profile__c =
                        customerProfile.Id,
                    Bank_Account__c =
                        bank.Id,
                    Direction__c =
                        'Receipt',
                    Method__c =
                        'Bank Transfer',
                    Reference__c =
                        'G4C-RCPT-DRAFT',
                    Amount__c =
                        900,
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

            insert new List<Accounting_Payment__c>{
                succeededReceipt,
                draftReceipt
            };

            createSucceededReceiptFixture(
                succeededReceipt,
                company.Id
            );

            insert new List<Invoice__c>{
                buildInvoice(
                    company.Id,
                    customerProfile.Id,
                    'G4C-INV-001',
                    500,
                    'Posted'
                ),
                buildInvoice(
                    company.Id,
                    customerProfile.Id,
                    'G4C-INV-002',
                    600,
                    'Posted'
                ),
                buildInvoice(
                    company.Id,
                    otherProfile.Id,
                    'G4C-INV-OTHER',
                    300,
                    'Posted'
                ),
                buildInvoice(
                    company.Id,
                    customerProfile.Id,
                    'G4C-INV-DRAFT',
                    300,
                    'Approved'
                )
            };
        }
    }

    @IsTest
    static void successfulReceiptAllocatesAcrossInvoicesWithoutLedgerEffect() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Payment__c receipt =
                getReceipt();


            Integer journalsBefore = [
                SELECT COUNT()
                FROM Journal_Entry__c
                WHERE Company__c =
                    :receipt.Company__c
            ];

            Integer eventsBefore = [
                SELECT COUNT()
                FROM Accounting_Event__c
                WHERE Company__c =
                    :receipt.Company__c
            ];

            Invoice__c firstInvoice =
                getInvoice('G4C-INV-001');
            Invoice__c secondInvoice =
                getInvoice('G4C-INV-002');

            SABCustomerReceiptAllocationService.ReceiptAllocationRequest firstRequest =
                new SABCustomerReceiptAllocationService.ReceiptAllocationRequest();
            firstRequest.invoiceId =
                firstInvoice.Id;
            firstRequest.allocatedAmount =
                300;
            firstRequest.effectiveDate =
                Date.newInstance(
                    2026,
                    9,
                    20
                );

            SABCustomerReceiptAllocationService.ReceiptAllocationRequest secondRequest =
                new SABCustomerReceiptAllocationService.ReceiptAllocationRequest();
            secondRequest.invoiceId =
                secondInvoice.Id;
            secondRequest.allocatedAmount =
                400;
            secondRequest.effectiveDate =
                Date.newInstance(
                    2026,
                    9,
                    20
                );

            Test.startTest();

            List<SABCustomerReceiptAllocationService.ReceiptAllocationResult> results =
                SABCustomerReceiptAllocationService.allocateToInvoices(
                    receipt.Id,
                    new List<SABCustomerReceiptAllocationService.ReceiptAllocationRequest>{
                        firstRequest,
                        secondRequest
                    }
                );

            Test.stopTest();

            System.assertEquals(
                2,
                results.size()
            );

            List<Payment_Allocation__c> allocations = [
                SELECT Payment__c,
                       Company__c,
                       Invoice__c,
                       Supplier_Bill__c,
                       Allocated_Amount__c,
                       Payment_Amount__c,
                       Document_Amount__c,
                       Base_Amount__c,
                       Transaction_Currency__c,
                       Exchange_Rate__c,
                       Status__c
                FROM Payment_Allocation__c
                WHERE Payment__c =
                    :receipt.Id
                ORDER BY Invoice__c
            ];

            System.assertEquals(
                2,
                allocations.size()
            );

            Decimal totalApplied = 0;

            for (
                Payment_Allocation__c allocation :
                allocations
            ) {
                System.assertEquals(
                    null,
                    allocation.Supplier_Bill__c
                );
                System.assertEquals(
                    'Allocated',
                    allocation.Status__c
                );
                System.assertEquals(
                    'BDT',
                    allocation.Transaction_Currency__c
                );
                System.assertEquals(
                    Decimal.valueOf('1'),
                    allocation.Exchange_Rate__c
                );
                System.assertEquals(
                    allocation.Payment_Amount__c,
                    allocation.Document_Amount__c
                );
                System.assertEquals(
                    allocation.Payment_Amount__c,
                    allocation.Base_Amount__c
                );

                totalApplied +=
                    allocation.Payment_Amount__c;
            }

            System.assertEquals(
                Decimal.valueOf('700'),
                totalApplied
            );

            System.assertEquals(
                Decimal.valueOf('200'),
                SABCustomerReceiptAllocationService.getInvoiceOutstanding(
                    firstInvoice.Id
                )
            );

            System.assertEquals(
                Decimal.valueOf('200'),
                SABCustomerReceiptAllocationService.getInvoiceOutstanding(
                    secondInvoice.Id
                )
            );

            System.assertEquals(
                Decimal.valueOf('200'),
                SABCustomerReceiptAllocationService.getReceiptUnallocatedAmount(
                    receipt.Id
                )
            );

            System.assertEquals(
                journalsBefore,
                [
                    SELECT COUNT()
                    FROM Journal_Entry__c
                    WHERE Company__c =
                        :receipt.Company__c
                ],
                'G4C must not create another Journal Entry.'
            );

            System.assertEquals(
                eventsBefore,
                [
                    SELECT COUNT()
                    FROM Accounting_Event__c
                    WHERE Company__c =
                        :receipt.Company__c
                ],
                'G4C must not create another Accounting Event.'
            );
        }
    }

    @IsTest
    static void invoiceOverAllocationIsBlocked() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Payment__c receipt =
                getReceipt();


            Invoice__c invoice =
                getInvoice('G4C-INV-001');

            SABCustomerReceiptAllocationService.ReceiptAllocationRequest request =
                new SABCustomerReceiptAllocationService.ReceiptAllocationRequest();

            request.invoiceId =
                invoice.Id;
            request.allocatedAmount =
                501;

            Boolean blocked = false;

            Test.startTest();

            try {
                SABCustomerReceiptAllocationService.allocateToInvoices(
                    receipt.Id,
                    new List<SABCustomerReceiptAllocationService.ReceiptAllocationRequest>{
                        request
                    }
                );
            } catch (
                SABCustomerReceiptAllocationService.ReceiptAllocationException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'remaining Invoice amount'
                    );
            }

            Test.stopTest();

            System.assertEquals(
                true,
                blocked
            );
        }
    }

    @IsTest
    static void differentCustomerInvoiceIsBlocked() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Payment__c receipt =
                getReceipt();


            Invoice__c invoice =
                getInvoice('G4C-INV-OTHER');

            SABCustomerReceiptAllocationService.ReceiptAllocationRequest request =
                new SABCustomerReceiptAllocationService.ReceiptAllocationRequest();

            request.invoiceId =
                invoice.Id;
            request.allocatedAmount =
                100;

            Boolean blocked = false;

            Test.startTest();

            try {
                SABCustomerReceiptAllocationService.allocateToInvoices(
                    receipt.Id,
                    new List<SABCustomerReceiptAllocationService.ReceiptAllocationRequest>{
                        request
                    }
                );
            } catch (
                SABCustomerReceiptAllocationService.ReceiptAllocationException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'same customer Party Accounting Profile'
                    );
            }

            Test.stopTest();

            System.assertEquals(
                true,
                blocked
            );
        }
    }

    @IsTest
    static void invoiceMustBePosted() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Payment__c receipt =
                getReceipt();


            Invoice__c invoice =
                getInvoice('G4C-INV-DRAFT');

            SABCustomerReceiptAllocationService.ReceiptAllocationRequest request =
                new SABCustomerReceiptAllocationService.ReceiptAllocationRequest();

            request.invoiceId =
                invoice.Id;
            request.allocatedAmount =
                100;

            Boolean blocked = false;

            Test.startTest();

            try {
                SABCustomerReceiptAllocationService.allocateToInvoices(
                    receipt.Id,
                    new List<SABCustomerReceiptAllocationService.ReceiptAllocationRequest>{
                        request
                    }
                );
            } catch (
                SABCustomerReceiptAllocationService.ReceiptAllocationException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'must be Posted'
                    );
            }

            Test.stopTest();

            System.assertEquals(
                true,
                blocked
            );
        }
    }

    @IsTest
    static void onlySucceededReceiptCanBeAllocated() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Payment__c receipt =
                getDraftReceipt();

            Invoice__c invoice =
                getInvoice('G4C-INV-001');

            SABCustomerReceiptAllocationService.ReceiptAllocationRequest request =
                new SABCustomerReceiptAllocationService.ReceiptAllocationRequest();

            request.invoiceId =
                invoice.Id;
            request.allocatedAmount =
                100;

            Boolean blocked = false;

            Test.startTest();

            try {
                SABCustomerReceiptAllocationService.allocateToInvoices(
                    receipt.Id,
                    new List<SABCustomerReceiptAllocationService.ReceiptAllocationRequest>{
                        request
                    }
                );
            } catch (
                SABCustomerReceiptAllocationService.ReceiptAllocationException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'Succeeded Customer Receipt'
                    );
            }

            Test.stopTest();

            System.assertEquals(
                true,
                blocked
            );
        }
    }

    @IsTest
    static void reversalRestoresInvoiceAndReceiptOutstanding() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Payment__c receipt =
                getReceipt();


            Invoice__c invoice =
                getInvoice('G4C-INV-001');

            SABCustomerReceiptAllocationService.ReceiptAllocationRequest request =
                new SABCustomerReceiptAllocationService.ReceiptAllocationRequest();

            request.invoiceId =
                invoice.Id;
            request.allocatedAmount =
                250;

            List<SABCustomerReceiptAllocationService.ReceiptAllocationResult> results =
                SABCustomerReceiptAllocationService.allocateToInvoices(
                    receipt.Id,
                    new List<SABCustomerReceiptAllocationService.ReceiptAllocationRequest>{
                        request
                    }
                );

            System.assertEquals(
                Decimal.valueOf('250'),
                SABCustomerReceiptAllocationService.getInvoiceOutstanding(
                    invoice.Id
                )
            );

            System.assertEquals(
                Decimal.valueOf('650'),
                SABCustomerReceiptAllocationService.getReceiptUnallocatedAmount(
                    receipt.Id
                )
            );

            Test.startTest();

            Payment_Allocation__c reversal =
                SABCustomerReceiptAllocationService.reverseAllocation(
                    results[0].allocationId,
                    'Customer remittance was applied to the wrong invoice.'
                );

            Test.stopTest();

            Payment_Allocation__c original = [
                SELECT Status__c
                FROM Payment_Allocation__c
                WHERE Id =
                    :results[0].allocationId
            ];

            System.assertEquals(
                'Reversed',
                original.Status__c
            );

            System.assertEquals(
                'Reversed',
                reversal.Status__c
            );

            System.assertEquals(
                results[0].allocationId,
                reversal.Reversal_Of__c
            );

            System.assertEquals(
                Decimal.valueOf('-250'),
                reversal.Payment_Amount__c
            );

            System.assertEquals(
                Decimal.valueOf('500'),
                SABCustomerReceiptAllocationService.getInvoiceOutstanding(
                    invoice.Id
                )
            );

            System.assertEquals(
                Decimal.valueOf('900'),
                SABCustomerReceiptAllocationService.getReceiptUnallocatedAmount(
                    receipt.Id
                )
            );
        }
    }

    /**
     * G4C is tested against the contract produced by G4B, not by executing the
     * entire G4B posting transaction inside every G4C test method. G4B has its
     * own focused posting tests. Re-running that heavy posting path here caused
     * unrelated G4C tests to consume the 100-query transaction limit before
     * the allocation service was reached.
     *
     * This fixture creates only the persisted preconditions G4C requires:
     * - Receipt direction
     * - Succeeded processing state
     * - same-currency snapshots
     * - linked Posted Payment Receipt accounting event
     */
    private static void createSucceededReceiptFixture(
        Accounting_Payment__c receipt,
        Id companyId
    ) {
        Accounting_Event__c eventRecord =
            new Accounting_Event__c(
                Company__c =
                    companyId,
                Adapter_Key__c =
                    'CUSTOMER_RECEIPT',
                Created_Request_Key__c =
                    'G4C-FIXTURE-'
                    + String.valueOf(
                        receipt.Id
                    ),
                Event_Key__c =
                    'G4C-PAYMENT-RECEIPT|'
                    + String.valueOf(
                        receipt.Id
                    )
                    + '|V1',
                Event_Type__c =
                    'Payment Receipt',
                Source_Business_Key__c =
                    'G4C-RCPT-001',
                Source_Record_Id__c =
                    String.valueOf(
                        receipt.Id
                    ),
                Source_Type__c =
                    'Accounting_Payment__c',
                Source_Version__c =
                    1,
                State__c =
                    'Posted'
            );

        insert eventRecord;

        receipt.Functional_Currency__c =
            'BDT';
        receipt.Exchange_Rate__c =
            Decimal.valueOf('1');
        receipt.Provider_Request_Key__c =
            'G4C-FIXTURE-PROVIDER';
        receipt.Accounting_Event__c =
            eventRecord.Id;
        receipt.Processing_State__c =
            'Succeeded';

        SABAccountingPaymentMutationContext.beginMutation();

        try {
            update receipt;
        } finally {
            SABAccountingPaymentMutationContext.endMutation();
        }
    }

    private static Invoice__c buildInvoice(
        Id companyId,
        Id partyProfileId,
        String legalNumber,
        Decimal total,
        String status
    ) {
        return new Invoice__c(
            Company__c =
                companyId,
            Party_Profile__c =
                partyProfileId,
            Document_Type__c =
                'Invoice',
            Document_Date__c =
                Date.newInstance(
                    2026,
                    9,
                    10
                ),
            Accounting_Date__c =
                Date.newInstance(
                    2026,
                    9,
                    10
                ),
            Due_Date__c =
                Date.newInstance(
                    2026,
                    10,
                    10
                ),
            Status__c =
                status,
            Transaction_Currency__c =
                'BDT',
            Functional_Currency__c =
                'BDT',
            Exchange_Rate__c =
                Decimal.valueOf('1'),
            Subtotal__c =
                total,
            Tax_Total__c =
                0,
            Total__c =
                total,
            Legal_Number__c =
                legalNumber
        );
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

        User testUser =
            new User(
                Alias =
                    'g4calloc',
                Email =
                    'g4calloc.'
                    + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    'G4C Allocation User',
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    profileRecord.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    'g4calloc.'
                    + seed
                    + '@example.test'
            );

        insert testUser;
        return testUser;
    }

    private static void assignPermissionSets(
        User testUser
    ) {
        Set<String> names =
            new Set<String>{
                ADMIN_PERMISSION_SET,
                APPROVE_PERMISSION_SET,
                POST_PERMISSION_SET,
                ALLOCATION_PERMISSION_SET
            };

        Map<String, Id> permissionSetIds =
            new Map<String, Id>();

        for (
            PermissionSet permissionSetRecord :
            [
                SELECT Id, Name
                FROM PermissionSet
                WHERE Name IN :names
            ]
        ) {
            permissionSetIds.put(
                permissionSetRecord.Name,
                permissionSetRecord.Id
            );
        }

        System.assertEquals(
            4,
            permissionSetIds.size(),
            'All G4C test permission sets must exist.'
        );

        List<PermissionSetAssignment> assignments =
            new List<PermissionSetAssignment>();

        for (String nameValue : names) {
            assignments.add(
                new PermissionSetAssignment(
                    AssigneeId =
                        testUser.Id,
                    PermissionSetId =
                        permissionSetIds.get(
                            nameValue
                        )
                )
            );
        }

        insert assignments;
    }

    private static Accounting_Company__c createCompany(
        String companyName,
        String companyKey
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    companyName,
                Company_Key__c =
                    companyKey,
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
        Id userId,
        String keyValue
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
                keyValue,
            Role__c =
                'Finance Manager'
        );
    }

    private static void createPeriod(
        Id companyId,
        String companyPeriodKey,
        String periodKey
    ) {
        insert new Accounting_Period__c(
            Name =
                'September 2026',
            Company__c =
                companyId,
            Company_Period_Key__c =
                companyPeriodKey,
            Period_Key__c =
                periodKey,
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
        Boolean manualPostingAllowed,
        String companyAccountKey
    ) {
        GL_Account__c accountRecord =
            new GL_Account__c(
                Name =
                    displayName,
                Company__c =
                    companyId,
                Company_Account_Key__c =
                    companyAccountKey,
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
                'G4C Allocation User'
            LIMIT 1
        ];
    }

    private static Accounting_Payment__c getReceipt() {
        return [
            SELECT Id, Company__c
            FROM Accounting_Payment__c
            WHERE Reference__c =
                'G4C-RCPT-001'
            LIMIT 1
        ];
    }

    private static Accounting_Payment__c getDraftReceipt() {
        return [
            SELECT Id, Company__c
            FROM Accounting_Payment__c
            WHERE Reference__c =
                'G4C-RCPT-DRAFT'
            LIMIT 1
        ];
    }

    private static Invoice__c getInvoice(
        String legalNumber
    ) {
        return [
            SELECT Id, Company__c,
                   Party_Profile__c,
                   Status__c,
                   Total__c
            FROM Invoice__c
            WHERE Legal_Number__c =
                :legalNumber
            LIMIT 1
        ];
    }
}
