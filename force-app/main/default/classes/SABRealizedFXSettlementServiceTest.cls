@IsTest
private class SABRealizedFXSettlementServiceTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Remaining_Fields_Admin',
            'SAB_Post_Journal_Action',
            'SAB_Post_Realized_FX_Action'
        };

    @TestSetup
    static void setupFixture() {
        User testUser =
            createUser();

        assignPermissionSets(
            testUser
        );

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c =
                        'G7C Realized FX Company',
                    Company_Key__c =
                        'G7S',
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
                    'G7C-SETTLE-ACCESS',
                Role__c =
                    'Finance Manager'
            );

            Accounting_Period__c period =
                new Accounting_Period__c(
                    Name =
                        'September 2026',
                    Company__c =
                        company.Id,
                    Company_Period_Key__c =
                        'G7S-2026-09',
                    Period_Key__c =
                        'G7S-2026-09',
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
            insert period;

            GL_Account__c ar =
                account(
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
                account(
                    company.Id,
                    '2100',
                    'Accounts Payable',
                    'Liability',
                    'Credit',
                    true,
                    'AP',
                    false
                );

            GL_Account__c bankGL =
                account(
                    company.Id,
                    '1100',
                    'USD Bank',
                    'Asset',
                    'Debit',
                    false,
                    'None',
                    true
                );

            GL_Account__c gain =
                account(
                    company.Id,
                    '7300',
                    'Realized FX Gain',
                    'Revenue',
                    'Credit',
                    false,
                    'None',
                    true
                );

            GL_Account__c loss =
                account(
                    company.Id,
                    '6300',
                    'Realized FX Loss',
                    'Expense',
                    'Debit',
                    false,
                    'None',
                    true
                );

            company.Realized_FX_Gain_Account__c =
                gain.Id;
            company.Realized_FX_Loss_Account__c =
                loss.Id;
            update company;

            Account customerAccount =
                new Account(
                    Name =
                        'G7C FX Customer'
                );
            insert customerAccount;

            Account supplierAccount =
                new Account(
                    Name =
                        'G7C FX Supplier'
                );
            insert supplierAccount;

            Party_Accounting_Profile__c customer =
                new Party_Accounting_Profile__c(
                    Company__c =
                        company.Id,
                    Account__c =
                        customerAccount.Id,
                    Profile_Key__c =
                        'G7C-CUSTOMER',
                    Is_Supplier__c =
                        false,
                    Is_Customer__c =
                        true,
                    Is_Active__c =
                        true,
                    AR_Control_Account__c =
                        ar.Id
                );
            insert customer;

            Party_Accounting_Profile__c supplier =
                new Party_Accounting_Profile__c(
                    Company__c =
                        company.Id,
                    Account__c =
                        supplierAccount.Id,
                    Profile_Key__c =
                        'G7C-SUPPLIER',
                    Is_Supplier__c =
                        true,
                    Is_Customer__c =
                        false,
                    Is_Active__c =
                        true,
                    AP_Control_Account__c =
                        ap.Id
                );
            insert supplier;

            Bank_Account__c bank =
                new Bank_Account__c(
                    Name =
                        'G7C USD Bank',
                    Company__c =
                        company.Id,
                    Bank_Name__c =
                        'G7C Test Bank',
                    Currency__c =
                        'USD',
                    GL_Account__c =
                        bankGL.Id,
                    Is_Active__c =
                        true
                );
            insert bank;

            Invoice__c invoice =
                new Invoice__c(
                    Company__c =
                        company.Id,
                    Party_Profile__c =
                        customer.Id,
                    Document_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            5
                        ),
                    Accounting_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            5
                        ),
                    Due_Date__c =
                        Date.newInstance(
                            2026,
                            10,
                            5
                        ),
                    Document_Type__c =
                        'Invoice',
                    Status__c =
                        'Draft',
                    Transaction_Currency__c =
                        'USD',
                    Functional_Currency__c =
                        'BDT',
                    Exchange_Rate__c =
                        100,
                    Exchange_Rate_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            5
                        ),
                    Subtotal__c =
                        10,
                    Tax_Total__c =
                        0,
                    Total__c =
                        10
                );
            insert invoice;

            invoice.Status__c =
                'Posted';
            update invoice;

            Supplier_Bill__c bill =
                new Supplier_Bill__c(
                    Company__c =
                        company.Id,
                    Supplier_Profile__c =
                        supplier.Id,
                    Document_Type__c =
                        'Bill',
                    Document_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            6
                        ),
                    Accounting_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            6
                        ),
                    Due_Date__c =
                        Date.newInstance(
                            2026,
                            10,
                            6
                        ),
                    Vendor_Reference__c =
                        'G7C-FX-BILL',
                    Transaction_Currency__c =
                        'USD',
                    Functional_Currency__c =
                        'BDT',
                    Exchange_Rate__c =
                        100,
                    Status__c =
                        'Draft',
                    Subtotal__c =
                        8,
                    Tax_Total__c =
                        0,
                    Total__c =
                        8
                );
            insert bill;

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

            Accounting_Payment__c receipt =
                payment(
                    company.Id,
                    customer.Id,
                    bank.Id,
                    'Receipt',
                    'G7C-USD-RECEIPT',
                    10,
                    110
                );

            Accounting_Payment__c disbursement =
                payment(
                    company.Id,
                    supplier.Id,
                    bank.Id,
                    'Disbursement',
                    'G7C-USD-PAYMENT',
                    8,
                    110
                );

            insert new List<Payment_Allocation__c>{
                new Payment_Allocation__c(
                    Allocation_Key__c =
                        'G7C-AR-ALLOC',
                    Payment__c =
                        receipt.Id,
                    Company__c =
                        company.Id,
                    Invoice__c =
                        invoice.Id,
                    Supplier_Bill__c =
                        null,
                    Allocated_Amount__c =
                        10,
                    Payment_Amount__c =
                        10,
                    Document_Amount__c =
                        10,
                    Base_Amount__c =
                        1100,
                    Transaction_Currency__c =
                        'USD',
                    Exchange_Rate__c =
                        110,
                    Allocation_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            20
                        ),
                    Effective_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            20
                        ),
                    Status__c =
                        'Allocated',
                    Notes__c =
                        'AR-FX'
                ),
                new Payment_Allocation__c(
                    Allocation_Key__c =
                        'G7C-AP-ALLOC',
                    Payment__c =
                        disbursement.Id,
                    Company__c =
                        company.Id,
                    Invoice__c =
                        null,
                    Supplier_Bill__c =
                        bill.Id,
                    Allocated_Amount__c =
                        8,
                    Payment_Amount__c =
                        8,
                    Document_Amount__c =
                        8,
                    Base_Amount__c =
                        880,
                    Transaction_Currency__c =
                        'USD',
                    Exchange_Rate__c =
                        110,
                    Allocation_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            21
                        ),
                    Effective_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            21
                        ),
                    Status__c =
                        'Allocated',
                    Notes__c =
                        'AP-FX'
                )
            };
        }
    }

    @IsTest
    static void arGainPostsExactlyOnceAndLocksSnapshot() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Payment_Allocation__c allocation =
                getAllocation(
                    'G7C-AR-ALLOC'
                );

            Test.startTest();

            SABRealizedFXSettlementService.SettlementResult first =
                SABRealizedFXSettlementService.processAllocation(
                    allocation.Id,
                    'G7C-RFX-AR-001',
                    'Foreign-currency customer settlement.'
                );

            SABRealizedFXSettlementService.SettlementResult replay =
                SABRealizedFXSettlementService.processAllocation(
                    allocation.Id,
                    'G7C-RFX-AR-001',
                    'Foreign-currency customer settlement.'
                );

            Test.stopTest();

            System.assertEquals(
                'Posted',
                first.state
            );

            System.assertEquals(
                Decimal.valueOf('1000.0000'),
                first.historicalCarryingBase
            );

            System.assertEquals(
                Decimal.valueOf('1100.0000'),
                first.settlementBaseAmount
            );

            System.assertEquals(
                Decimal.valueOf('100.0000'),
                first.realizedFXAmount
            );

            System.assertNotEquals(
                null,
                first.journalEntryId
            );

            System.assertNotEquals(
                null,
                first.accountingEventId
            );

            System.assertEquals(
                true,
                replay.replay
            );

            System.assertEquals(
                first.journalEntryId,
                replay.journalEntryId
            );

            Accounting_Event__c eventRecord = [
                SELECT Event_Type__c,
                       State__c,
                       Source_Type__c,
                       Source_Record_Id__c
                FROM Accounting_Event__c
                WHERE Id =
                        :first.accountingEventId
            ];

            System.assertEquals(
                'Realized FX Settlement',
                eventRecord.Event_Type__c
            );

            System.assertEquals(
                'Posted',
                eventRecord.State__c
            );

            System.assertEquals(
                'Payment_Allocation__c',
                eventRecord.Source_Type__c
            );

            System.assertEquals(
                String.valueOf(
                    allocation.Id
                ),
                eventRecord.Source_Record_Id__c
            );

            Accounting_Company__c company =
                getCompany();

            Party_Accounting_Profile__c customer = [
                SELECT AR_Control_Account__c
                FROM Party_Accounting_Profile__c
                WHERE Profile_Key__c =
                        'G7C-CUSTOMER'
                LIMIT 1
            ];

            Journal_Entry_Line__c controlLine = [
                SELECT Debit_Base__c,
                       Credit_Base__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c =
                        :first.journalEntryId
                  AND GL_Account__c =
                        :customer.AR_Control_Account__c
                LIMIT 1
            ];

            Journal_Entry_Line__c gainLine = [
                SELECT Debit_Base__c,
                       Credit_Base__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c =
                        :first.journalEntryId
                  AND GL_Account__c =
                        :company.Realized_FX_Gain_Account__c
                LIMIT 1
            ];

            System.assertEquals(
                Decimal.valueOf('100.0000'),
                controlLine.Debit_Base__c
            );

            System.assertEquals(
                Decimal.valueOf('0.0000'),
                controlLine.Credit_Base__c
            );

            System.assertEquals(
                Decimal.valueOf('100.0000'),
                gainLine.Credit_Base__c
            );

            // Guard: system-managed realized FX fields cannot be edited directly.
            Payment_Allocation__c protectedAllocation = [
                SELECT Id,
                       Realized_FX_Amount__c
                FROM Payment_Allocation__c
                WHERE Id =
                        :allocation.Id
            ];

            protectedAllocation.Realized_FX_Amount__c =
                999;

            Boolean realizedBlocked =
                false;

            try {
                update protectedAllocation;
            } catch (DmlException ex) {
                realizedBlocked =
                    ex.getMessage().contains(
                        'system-managed'
                    );
            }

            System.assertEquals(
                true,
                realizedBlocked
            );

            Payment_Allocation__c financialChange = [
                SELECT Id,
                       Base_Amount__c
                FROM Payment_Allocation__c
                WHERE Id =
                        :allocation.Id
            ];

            financialChange.Base_Amount__c =
                1101;

            Boolean financialBlocked =
                false;

            try {
                update financialChange;
            } catch (DmlException ex) {
                financialBlocked =
                    ex.getMessage().contains(
                        'financial source fields are locked'
                    );
            }

            System.assertEquals(
                true,
                financialBlocked
            );

            Payment_Allocation__c statusChange = [
                SELECT Id,
                       Status__c
                FROM Payment_Allocation__c
                WHERE Id =
                        :allocation.Id
            ];

            statusChange.Status__c =
                'Reversed';

            Boolean statusBlocked =
                false;

            try {
                update statusChange;
            } catch (DmlException ex) {
                statusBlocked =
                    ex.getMessage().contains(
                        'cannot change status'
                    );
            }

            System.assertEquals(
                true,
                statusBlocked
            );

            Payment_Allocation__c deleteTarget = [
                SELECT Id
                FROM Payment_Allocation__c
                WHERE Id =
                        :allocation.Id
            ];

            Boolean deleteBlocked =
                false;

            try {
                delete deleteTarget;
            } catch (DmlException ex) {
                deleteBlocked =
                    ex.getMessage().contains(
                        'cannot be deleted'
                    );
            }

            System.assertEquals(
                true,
                deleteBlocked
            );
        }
    }

    @IsTest
    static void apLossPostsToLossAndCreditsAP() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Payment_Allocation__c allocation =
                getAllocation(
                    'G7C-AP-ALLOC'
                );

            SABRealizedFXSettlementService.SettlementResult result =
                SABRealizedFXSettlementService.processAllocation(
                    allocation.Id,
                    'G7C-RFX-AP-001',
                    'Foreign-currency supplier settlement.'
                );

            System.assertEquals(
                'Posted',
                result.state
            );

            System.assertEquals(
                Decimal.valueOf('800.0000'),
                result.historicalCarryingBase
            );

            System.assertEquals(
                Decimal.valueOf('880.0000'),
                result.settlementBaseAmount
            );

            System.assertEquals(
                Decimal.valueOf('-80.0000'),
                result.realizedFXAmount
            );

            Accounting_Company__c company =
                getCompany();

            Party_Accounting_Profile__c supplier = [
                SELECT AP_Control_Account__c
                FROM Party_Accounting_Profile__c
                WHERE Profile_Key__c =
                        'G7C-SUPPLIER'
                LIMIT 1
            ];

            Journal_Entry_Line__c apLine = [
                SELECT Debit_Base__c,
                       Credit_Base__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c =
                        :result.journalEntryId
                  AND GL_Account__c =
                        :supplier.AP_Control_Account__c
                LIMIT 1
            ];

            Journal_Entry_Line__c lossLine = [
                SELECT Debit_Base__c,
                       Credit_Base__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c =
                        :result.journalEntryId
                  AND GL_Account__c =
                        :company.Realized_FX_Loss_Account__c
                LIMIT 1
            ];

            System.assertEquals(
                Decimal.valueOf('80.0000'),
                apLine.Credit_Base__c
            );

            System.assertEquals(
                Decimal.valueOf('80.0000'),
                lossLine.Debit_Base__c
            );
        }
    }

    @IsTest
    static void zeroDifferenceIsCalculatedWithoutJournal() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Accounting_Company__c company =
                getCompany();

            Party_Accounting_Profile__c customer = [
                SELECT Id
                FROM Party_Accounting_Profile__c
                WHERE Profile_Key__c =
                        'G7C-CUSTOMER'
                LIMIT 1
            ];

            Bank_Account__c bank = [
                SELECT Id
                FROM Bank_Account__c
                WHERE Company__c =
                        :company.Id
                LIMIT 1
            ];

            Invoice__c invoice =
                new Invoice__c(
                    Company__c =
                        company.Id,
                    Party_Profile__c =
                        customer.Id,
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
                    Document_Type__c =
                        'Invoice',
                    Status__c =
                        'Draft',
                    Transaction_Currency__c =
                        'USD',
                    Functional_Currency__c =
                        'BDT',
                    Exchange_Rate__c =
                        100,
                    Exchange_Rate_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            10
                        ),
                    Subtotal__c =
                        5,
                    Tax_Total__c =
                        0,
                    Total__c =
                        5
                );
            insert invoice;

            invoice.Status__c =
                'Posted';
            update invoice;

            Accounting_Payment__c receipt =
                payment(
                    company.Id,
                    customer.Id,
                    bank.Id,
                    'Receipt',
                    'G7C-ZERO-RECEIPT',
                    5,
                    100
                );

            Payment_Allocation__c allocation =
                new Payment_Allocation__c(
                    Allocation_Key__c =
                        'G7C-ZERO-ALLOC',
                    Payment__c =
                        receipt.Id,
                    Company__c =
                        company.Id,
                    Invoice__c =
                        invoice.Id,
                    Allocated_Amount__c =
                        5,
                    Payment_Amount__c =
                        5,
                    Document_Amount__c =
                        5,
                    Base_Amount__c =
                        500,
                    Transaction_Currency__c =
                        'USD',
                    Exchange_Rate__c =
                        100,
                    Allocation_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            22
                        ),
                    Effective_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            22
                        ),
                    Status__c =
                        'Allocated'
                );
            insert allocation;

            Integer journalsBefore = [
                SELECT COUNT()
                FROM Journal_Entry__c
                WHERE Company__c =
                        :company.Id
            ];

            SABRealizedFXSettlementService.SettlementResult result =
                SABRealizedFXSettlementService.processAllocation(
                    allocation.Id,
                    'G7C-RFX-ZERO',
                    'No rate movement.'
                );

            System.assertEquals(
                'Calculated',
                result.state
            );

            System.assertEquals(
                Decimal.valueOf('0.0000'),
                result.realizedFXAmount
            );

            System.assertEquals(
                null,
                result.journalEntryId
            );

            System.assertEquals(
                null,
                result.accountingEventId
            );

            System.assertEquals(
                journalsBefore,
                [
                    SELECT COUNT()
                    FROM Journal_Entry__c
                    WHERE Company__c =
                            :company.Id
                ]
            );
        }
    }

    private static Accounting_Payment__c payment(
        Id companyId,
        Id profileId,
        Id bankId,
        String direction,
        String reference,
        Decimal amount,
        Decimal rate
    ) {
        Accounting_Payment__c row =
            new Accounting_Payment__c(
                Company__c =
                    companyId,
                Party_Profile__c =
                    profileId,
                Bank_Account__c =
                    bankId,
                Direction__c =
                    direction,
                Method__c =
                    'Bank Transfer',
                Reference__c =
                    reference,
                Amount__c =
                    amount,
                Transaction_Currency__c =
                    'USD',
                Functional_Currency__c =
                    'BDT',
                Exchange_Rate__c =
                    rate,
                Effective_Date__c =
                    Date.newInstance(
                        2026,
                        9,
                        20
                    ),
                Processing_State__c =
                    'Draft'
            );

        insert row;

        SABAccountingPaymentMutationContext.beginMutation();

        try {
            row.Processing_State__c =
                'Succeeded';
            update row;
        } finally {
            SABAccountingPaymentMutationContext.endMutation();
        }

        return row;
    }

    private static GL_Account__c account(
        Id companyId,
        String code,
        String displayName,
        String accountType,
        String normalBalance,
        Boolean isControl,
        String controlType,
        Boolean manualPostingAllowed
    ) {
        GL_Account__c row =
            new GL_Account__c(
                Name =
                    displayName,
                Company__c =
                    companyId,
                Company_Account_Key__c =
                    'G7S-' + code,
                Account_Code__c =
                    code,
                Account_Type__c =
                    accountType,
                Normal_Balance__c =
                    normalBalance,
                Is_Active__c =
                    true,
                Is_Control_Account__c =
                    isControl,
                Control_Type__c =
                    controlType,
                Manual_Posting_Allowed__c =
                    manualPostingAllowed
            );

        insert row;
        return row;
    }

    private static User createUser() {
        Profile profileRecord = [
            SELECT Id
            FROM Profile
            WHERE UserType =
                    'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String seed =
            String.valueOf(
                Datetime.now().getTime()
            );

        User row =
            new User(
                Alias =
                    'g7cfx',
                Email =
                    'g7cfx.'
                    + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    'G7C Settlement User',
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    profileRecord.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    'g7cfx.'
                    + seed
                    + '@example.test'
            );

        insert row;
        return row;
    }

    private static void assignPermissionSets(
        User userRecord
    ) {
        Map<String, Id> ids =
            new Map<String, Id>();

        for (PermissionSet row : [
            SELECT Id,
                   Name
            FROM PermissionSet
            WHERE Name IN :REQUIRED_PERMISSION_SETS
        ]) {
            ids.put(
                row.Name,
                row.Id
            );
        }

        System.assertEquals(
            REQUIRED_PERMISSION_SETS.size(),
            ids.size(),
            'All G7C realized FX dependency permission sets must exist.'
        );

        List<PermissionSetAssignment> assignments =
            new List<PermissionSetAssignment>();

        for (String nameValue : REQUIRED_PERMISSION_SETS) {
            assignments.add(
                new PermissionSetAssignment(
                    AssigneeId =
                        userRecord.Id,
                    PermissionSetId =
                        ids.get(
                            nameValue
                        )
                )
            );
        }

        insert assignments;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                    'G7C Settlement User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getCompany() {
        return [
            SELECT Id,
                   Realized_FX_Gain_Account__c,
                   Realized_FX_Loss_Account__c
            FROM Accounting_Company__c
            WHERE Company_Key__c =
                    'G7S'
            LIMIT 1
        ];
    }

    private static Payment_Allocation__c getAllocation(
        String allocationKey
    ) {
        return [
            SELECT Id,
                   Allocation_Key__c
            FROM Payment_Allocation__c
            WHERE Allocation_Key__c =
                    :allocationKey
            LIMIT 1
        ];
    }
}
