@IsTest
private class SABForeignCurrencySettlementServiceTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Remaining_Fields_Admin',
            'SAB_Post_Journal_Action',
            'SAB_Reverse_Journal_Action',
            'SAB_Post_Realized_FX_Action',
            'SAB_Reverse_Realized_FX_Action',
            'SAB_Foreign_Currency_Settlement_Action'
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
                        'G7D FX Company',
                    Company_Key__c =
                        'G7D',
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
                    'G7D-ACCESS',
                Role__c =
                    'Finance Manager'
            );

            Accounting_Period__c september =
                new Accounting_Period__c(
                    Name =
                        'September 2026',
                    Company__c =
                        company.Id,
                    Company_Period_Key__c =
                        'G7D-2026-09',
                    Period_Key__c =
                        'G7D-2026-09',
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
            insert september;

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
                        'G7D Customer'
                );
            insert customerAccount;

            Account supplierAccount =
                new Account(
                    Name =
                        'G7D Supplier'
                );
            insert supplierAccount;

            Party_Accounting_Profile__c customer =
                new Party_Accounting_Profile__c(
                    Account__c =
                        customerAccount.Id,
                    Company__c =
                        company.Id,
                    Profile_Key__c =
                        'G7D-CUSTOMER',
                    Is_Active__c =
                        true,
                    Is_Customer__c =
                        true,
                    Is_Supplier__c =
                        false,
                    AR_Control_Account__c =
                        ar.Id
                );
            insert customer;

            Party_Accounting_Profile__c supplier =
                new Party_Accounting_Profile__c(
                    Account__c =
                        supplierAccount.Id,
                    Company__c =
                        company.Id,
                    Profile_Key__c =
                        'G7D-SUPPLIER',
                    Is_Active__c =
                        true,
                    Is_Customer__c =
                        false,
                    Is_Supplier__c =
                        true,
                    AP_Control_Account__c =
                        ap.Id
                );
            insert supplier;

            Bank_Account__c bank =
                new Bank_Account__c(
                    Name =
                        'G7D USD Bank',
                    Company__c =
                        company.Id,
                    Bank_Name__c =
                        'G7D Bank',
                    Currency__c =
                        'USD',
                    GL_Account__c =
                        bankGL.Id,
                    Is_Active__c =
                        true
                );
            insert bank;

            Exchange_Rate__c spotRate =
                new Exchange_Rate__c(
                    From_Currency__c =
                        'USD',
                    To_Currency__c =
                        'BDT',
                    Rate_Type__c =
                        'Spot',
                    Effective_Date_Time__c =
                        Datetime.newInstance(
                            Date.newInstance(
                                2026,
                                9,
                                1
                            ),
                            Time.newInstance(
                                0,
                                0,
                                0,
                                0
                            )
                        ),
                    Rate__c =
                        110,
                    Source__c =
                        'G7D Approved Spot',
                    Approved__c =
                        true,
                    Approved_By__c =
                        testUser.Id,
                    Rate_Key__c =
                        'G7D-USD-BDT-SPOT'
                );
            insert spotRate;

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
                    Legal_Number__c =
                        'G7D-INV-1',
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

            Invoice__c reversalInvoice =
                new Invoice__c(
                    Company__c =
                        company.Id,
                    Party_Profile__c =
                        customer.Id,
                    Document_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            7
                        ),
                    Accounting_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            7
                        ),
                    Due_Date__c =
                        Date.newInstance(
                            2026,
                            10,
                            7
                        ),
                    Document_Type__c =
                        'Invoice',
                    Legal_Number__c =
                        'G7D-INV-REV',
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
                            7
                        ),
                    Subtotal__c =
                        10,
                    Tax_Total__c =
                        0,
                    Total__c =
                        10
                );
            insert reversalInvoice;

            reversalInvoice.Status__c =
                'Posted';
            update reversalInvoice;

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
                        'G7D-BILL',
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

            insert new List<Accounting_Payment__c>{
                new Accounting_Payment__c(
                    Company__c =
                        company.Id,
                    Party_Profile__c =
                        customer.Id,
                    Bank_Account__c =
                        bank.Id,
                    Direction__c =
                        'Receipt',
                    Method__c =
                        'Bank Transfer',
                    Reference__c =
                        'G7D-RECEIPT',
                    Amount__c =
                        10,
                    Transaction_Currency__c =
                        'USD',
                    Effective_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            20
                        ),
                    Processing_State__c =
                        'Draft'
                ),
                new Accounting_Payment__c(
                    Company__c =
                        company.Id,
                    Party_Profile__c =
                        supplier.Id,
                    Bank_Account__c =
                        bank.Id,
                    Direction__c =
                        'Disbursement',
                    Method__c =
                        'Bank Transfer',
                    Reference__c =
                        'G7D-DISBURSEMENT',
                    Amount__c =
                        8,
                    Transaction_Currency__c =
                        'USD',
                    Effective_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            21
                        ),
                    Processing_State__c =
                        'Draft'
                ),
                new Accounting_Payment__c(
                    Company__c =
                        company.Id,
                    Party_Profile__c =
                        customer.Id,
                    Bank_Account__c =
                        bank.Id,
                    Direction__c =
                        'Receipt',
                    Method__c =
                        'Bank Transfer',
                    Reference__c =
                        'G7D-REVERSAL-RECEIPT',
                    Amount__c =
                        10,
                    Transaction_Currency__c =
                        'USD',
                    Effective_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            22
                        ),
                    Processing_State__c =
                        'Draft'
                )
            };

        }
    }

    @IsTest
    static void foreignReceiptLifecyclePostsAtSettlementRate() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Accounting_Payment__c receipt =
                getPayment(
                    'G7D-RECEIPT'
                );

            Test.startTest();

            SABForeignCurrencySettlementService.PaymentLifecycleResult authorized =
                SABForeignCurrencySettlementService.authorizeForeignPayment(
                    receipt.Id,
                    'G7D-RCPT-AUTH'
                );

            SABForeignCurrencySettlementService.PaymentLifecycleResult submitted =
                SABForeignCurrencySettlementService.submitForeignPayment(
                    receipt.Id,
                    'PROVIDER-G7D-RCPT',
                    'G7D-RCPT-SUBMIT'
                );

            SABForeignCurrencySettlementService.PaymentLifecycleResult posted =
                SABForeignCurrencySettlementService.postForeignPayment(
                    receipt.Id,
                    'G7D-RCPT-POST'
                );

            Test.stopTest();

            System.assertEquals(
                'Authorized',
                authorized.newState
            );

            System.assertEquals(
                Decimal.valueOf('110'),
                authorized.exchangeRate
            );

            System.assertNotEquals(
                null,
                authorized.exchangeRateRecordId
            );

            System.assertEquals(
                'Submitted',
                submitted.newState
            );

            System.assertEquals(
                'Succeeded',
                posted.newState
            );

            System.assertNotEquals(
                null,
                posted.journalEntryId
            );

            Accounting_Payment__c stored = [
                SELECT Functional_Currency__c,
                       Exchange_Rate__c,
                       Exchange_Rate_Record__c,
                       Processing_State__c,
                       Accounting_Event__c
                FROM Accounting_Payment__c
                WHERE Id =
                        :receipt.Id
            ];

            System.assertEquals(
                'BDT',
                stored.Functional_Currency__c
            );

            System.assertEquals(
                Decimal.valueOf('110'),
                stored.Exchange_Rate__c
            );

            System.assertEquals(
                'Succeeded',
                stored.Processing_State__c
            );

            List<Journal_Entry_Line__c> lines = [
                SELECT GL_Account__c,
                       Debit_Base__c,
                       Credit_Base__c,
                       Transaction_Amount__c,
                       Transaction_Currency__c,
                       Functional_Currency__c,
                       Applied_Exchange_Rate__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c =
                        :posted.journalEntryId
                ORDER BY Line_Number__c
            ];

            System.assertEquals(
                2,
                lines.size()
            );

            System.assertEquals(
                Decimal.valueOf('1100.0000'),
                lines[0].Debit_Base__c
            );

            System.assertEquals(
                Decimal.valueOf('1100.0000'),
                lines[1].Credit_Base__c
            );

            for (Journal_Entry_Line__c line : lines) {
                System.assertEquals(
                    Decimal.valueOf('10.0000'),
                    line.Transaction_Amount__c
                );
                System.assertEquals(
                    'USD',
                    line.Transaction_Currency__c
                );
                System.assertEquals(
                    'BDT',
                    line.Functional_Currency__c
                );
                System.assertEquals(
                    Decimal.valueOf('110'),
                    line.Applied_Exchange_Rate__c
                );
            }
        }
    }

    @IsTest
    static void receiptAllocationAutomaticallyPostsRealizedGain() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Accounting_Payment__c receipt =
                getPayment(
                    'G7D-RECEIPT'
                );

            Invoice__c invoice =
                getInvoice();

            prepareAndPost(
                receipt.Id,
                'G7D-AR'
            );

            SABForeignCurrencySettlementService.ForeignAllocationRequest request =
                new SABForeignCurrencySettlementService.ForeignAllocationRequest();

            request.invoiceId =
                invoice.Id;
            request.amount =
                10;
            request.effectiveDate =
                Date.newInstance(
                    2026,
                    9,
                    20
                );
            request.notes =
                'Full USD receipt allocation.';

            Test.startTest();

            List<SABForeignCurrencySettlementService.ForeignAllocationResult> results =
                SABForeignCurrencySettlementService.allocateForeignPayment(
                    receipt.Id,
                    new List<SABForeignCurrencySettlementService.ForeignAllocationRequest>{
                        request
                    },
                    'G7D-AR-ALLOC',
                    'Allocate customer receipt and recognize realized FX.'
                );

            Test.stopTest();

            System.assertEquals(
                1,
                results.size()
            );

            SABForeignCurrencySettlementService.ForeignAllocationResult result =
                results[0];

            System.assertEquals(
                Decimal.valueOf('1100.0000'),
                result.baseAmount
            );

            System.assertEquals(
                Decimal.valueOf('100.0000'),
                result.realizedFXAmount
            );

            System.assertEquals(
                'Posted',
                result.realizedFXState
            );

            System.assertNotEquals(
                null,
                result.realizedFXJournalId
            );

            System.assertNotEquals(
                null,
                result.realizedFXAccountingEventId
            );

            Payment_Allocation__c allocation = [
                SELECT Payment_Amount__c,
                       Document_Amount__c,
                       Base_Amount__c,
                       Historical_Carrying_Base__c,
                       Settlement_Base_Amount__c,
                       Realized_FX_Amount__c,
                       Realized_FX_State__c
                FROM Payment_Allocation__c
                WHERE Id =
                        :result.allocationId
            ];

            System.assertEquals(
                Decimal.valueOf('10.0000'),
                allocation.Payment_Amount__c
            );

            System.assertEquals(
                Decimal.valueOf('10.0000'),
                allocation.Document_Amount__c
            );

            System.assertEquals(
                Decimal.valueOf('1000.0000'),
                allocation.Historical_Carrying_Base__c
            );

            System.assertEquals(
                Decimal.valueOf('1100.0000'),
                allocation.Settlement_Base_Amount__c
            );
        }
    }

    @IsTest
    static void supplierAllocationAutomaticallyPostsRealizedLoss() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Accounting_Payment__c payment =
                getPayment(
                    'G7D-DISBURSEMENT'
                );

            Supplier_Bill__c bill =
                getBill();

            prepareAndPost(
                payment.Id,
                'G7D-AP'
            );

            SABForeignCurrencySettlementService.ForeignAllocationRequest request =
                new SABForeignCurrencySettlementService.ForeignAllocationRequest();

            request.supplierBillId =
                bill.Id;
            request.amount =
                8;
            request.effectiveDate =
                Date.newInstance(
                    2026,
                    9,
                    21
                );

            Test.startTest();

            List<SABForeignCurrencySettlementService.ForeignAllocationResult> results =
                SABForeignCurrencySettlementService.allocateForeignPayment(
                    payment.Id,
                    new List<SABForeignCurrencySettlementService.ForeignAllocationRequest>{
                        request
                    },
                    'G7D-AP-ALLOC',
                    'Allocate supplier payment and recognize realized FX.'
                );

            Test.stopTest();

            System.assertEquals(
                1,
                results.size()
            );

            System.assertEquals(
                Decimal.valueOf('-80.0000'),
                results[0].realizedFXAmount
            );

            System.assertEquals(
                'Posted',
                results[0].realizedFXState
            );

            System.assertNotEquals(
                null,
                results[0].realizedFXJournalId
            );
        }
    }

    @IsTest
    static void allocationReversalReversesRealizedFXFirst() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Test.startTest();
            postReversalFixture();
            Test.stopTest();

            Accounting_Payment__c reversalReceipt =
                getPayment(
                    'G7D-REVERSAL-RECEIPT'
                );

            Payment_Allocation__c allocation = [
                SELECT Id,
                       Realized_FX_State__c
                FROM Payment_Allocation__c
                WHERE Payment__c =
                        :reversalReceipt.Id
                  AND Status__c =
                        'Allocated'
                LIMIT 1
            ];

            System.assertEquals(
                'Posted',
                allocation.Realized_FX_State__c
            );

            SABTestGovernor.requireHeadroom(
                40,
                'reverse foreign allocation'
            );

            SABForeignCurrencySettlementService.ForeignAllocationReversalResult result =
                SABForeignCurrencySettlementService.reverseForeignAllocation(
                    allocation.Id,
                    Date.newInstance(
                        2026,
                        9,
                        25
                    ),
                    'G7D-REV-REQ',
                    'Reverse allocation and its realized FX result.'
                );

            System.assertEquals(
                'Reversed',
                result.originalStatus
            );

            System.assertEquals(
                'Reversed',
                result.realizedFXState
            );

            System.assertNotEquals(
                null,
                result.realizedFXReversalJournalId
            );

            System.assertNotEquals(
                null,
                result.realizedFXReversalEventId
            );

            System.assertNotEquals(
                null,
                result.reversalAllocationId
            );

            Payment_Allocation__c original = [
                SELECT Status__c,
                       Realized_FX_State__c,
                       Realized_FX_Journal__c,
                       Realized_FX_Reversal_Journal__c
                FROM Payment_Allocation__c
                WHERE Id =
                        :allocation.Id
            ];

            System.assertEquals(
                'Reversed',
                original.Status__c
            );

            System.assertEquals(
                'Reversed',
                original.Realized_FX_State__c
            );

            Journal_Entry__c originalFXJournal = [
                SELECT Status__c,
                       Reversal_Journal__c
                FROM Journal_Entry__c
                WHERE Id =
                        :original.Realized_FX_Journal__c
            ];

            System.assertEquals(
                'Reversed',
                originalFXJournal.Status__c
            );

            System.assertEquals(
                original.Realized_FX_Reversal_Journal__c,
                originalFXJournal.Reversal_Journal__c
            );

            Payment_Allocation__c reversal = [
                SELECT Status__c,
                       Reversal_Of__c,
                       Payment_Amount__c,
                       Document_Amount__c,
                       Base_Amount__c,
                       Realized_FX_Amount__c
                FROM Payment_Allocation__c
                WHERE Id =
                        :result.reversalAllocationId
            ];

            System.assertEquals(
                'Reversed',
                reversal.Status__c
            );

            System.assertEquals(
                allocation.Id,
                reversal.Reversal_Of__c
            );

            System.assertEquals(
                Decimal.valueOf('-10.0000'),
                reversal.Payment_Amount__c
            );

            System.assertEquals(
                Decimal.valueOf('-100.0000'),
                reversal.Realized_FX_Amount__c
            );
        }
    }

    @IsTest
    static void sameCurrencyPaymentIsRejectedByG7DPath() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Accounting_Company__c company =
                getCompany();

            Party_Accounting_Profile__c customer = [
                SELECT Id
                FROM Party_Accounting_Profile__c
                WHERE Profile_Key__c =
                        'G7D-CUSTOMER'
                LIMIT 1
            ];

            GL_Account__c bankGL =
                account(
                    company.Id,
                    '1110',
                    'BDT Bank',
                    'Asset',
                    'Debit',
                    false,
                    'None',
                    true
                );

            Bank_Account__c bank =
                new Bank_Account__c(
                    Name =
                        'G7D BDT Bank',
                    Company__c =
                        company.Id,
                    Bank_Name__c =
                        'G7D Bank',
                    Currency__c =
                        'BDT',
                    GL_Account__c =
                        bankGL.Id,
                    Is_Active__c =
                        true
                );
            insert bank;

            Accounting_Payment__c payment =
                new Accounting_Payment__c(
                    Company__c =
                        company.Id,
                    Party_Profile__c =
                        customer.Id,
                    Bank_Account__c =
                        bank.Id,
                    Direction__c =
                        'Receipt',
                    Method__c =
                        'Bank Transfer',
                    Reference__c =
                        'G7D-BDT-RECEIPT',
                    Amount__c =
                        100,
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
            insert payment;

            Boolean blocked =
                false;

            try {
                SABForeignCurrencySettlementService.authorizeForeignPayment(
                    payment.Id,
                    'G7D-SAME-CURRENCY'
                );
            } catch (
                SABForeignCurrencySettlementService.ForeignCurrencySettlementException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'Use the existing same-currency'
                    );
            }

            System.assertEquals(
                true,
                blocked
            );
        }
    }

    // G10H: the reversal fixture runs two full posting chains (receipt post, then realized-FX allocation).
    // It used to run in @TestSetup, whose query usage every test inherits; now only the reversal test runs it,
    // inside its own Test.startTest() window.
    private static void postReversalFixture() {
        Accounting_Payment__c reversalReceipt = [
            SELECT Id
            FROM Accounting_Payment__c
            WHERE Reference__c =
                    'G7D-REVERSAL-RECEIPT'
            LIMIT 1
        ];

        SABForeignCurrencySettlementService.authorizeForeignPayment(
            reversalReceipt.Id,
            'G7D-SETUP-REV-AUTH'
        );

        SABForeignCurrencySettlementService.submitForeignPayment(
            reversalReceipt.Id,
            'G7D-SETUP-REV-PROVIDER',
            'G7D-SETUP-REV-SUBMIT'
        );

        SABForeignCurrencySettlementService.postForeignPayment(
            reversalReceipt.Id,
            'G7D-SETUP-REV-POST'
        );

        SABForeignCurrencySettlementService.ForeignAllocationRequest
            reversalRequest =
                new SABForeignCurrencySettlementService.ForeignAllocationRequest();

        reversalRequest.invoiceId =
            [SELECT Id FROM Invoice__c WHERE Legal_Number__c = 'G7D-INV-REV' LIMIT 1].Id;
        reversalRequest.amount =
            10;
        reversalRequest.effectiveDate =
            Date.newInstance(
                2026,
                9,
                22
            );

        SABForeignCurrencySettlementService.allocateForeignPayment(
            reversalReceipt.Id,
            new List<SABForeignCurrencySettlementService.ForeignAllocationRequest>{
                reversalRequest
            },
            'G7D-SETUP-REV-ALLOC',
            'Create realized-FX allocation fixture for reversal test.'
        );
    }

    private static void prepareAndPost(
        Id paymentId,
        String seed
    ) {
        SABForeignCurrencySettlementService.authorizeForeignPayment(
            paymentId,
            seed + '-AUTH'
        );

        SABForeignCurrencySettlementService.submitForeignPayment(
            paymentId,
            seed + '-PROVIDER',
            seed + '-SUBMIT'
        );

        SABForeignCurrencySettlementService.postForeignPayment(
            paymentId,
            seed + '-POST'
        );
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
                    'G7D-' + code,
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
                    'g7dfx',
                Email =
                    'g7dfx.'
                    + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    'G7D FX User',
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    profileRecord.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    'g7dfx.'
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
            'All G7D permission sets must exist.'
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
                    'G7D FX User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getCompany() {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c =
                    'G7D'
            LIMIT 1
        ];
    }

    private static Accounting_Payment__c getPayment(
        String referenceValue
    ) {
        return [
            SELECT Id
            FROM Accounting_Payment__c
            WHERE Reference__c =
                    :referenceValue
            LIMIT 1
        ];
    }

    private static Invoice__c getInvoice() {
        Id companyId =
            getCompany().Id;

        return [
            SELECT Id
            FROM Invoice__c
            WHERE Company__c =
                    :companyId
              AND Document_Type__c =
                    'Invoice'
              AND Legal_Number__c =
                    'G7D-INV-1'
            LIMIT 1
        ];
    }

    private static Supplier_Bill__c getBill() {
        Id companyId =
            getCompany().Id;

        return [
            SELECT Id
            FROM Supplier_Bill__c
            WHERE Company__c =
                    :companyId
              AND Document_Type__c =
                    'Bill'
            LIMIT 1
        ];
    }
}
