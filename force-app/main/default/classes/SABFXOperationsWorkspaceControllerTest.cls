@IsTest
private class SABFXOperationsWorkspaceControllerTest {

    @TestSetup
    static void setupFixture() {
        User testUser =
            createUser();

        PermissionSet workspacePermission = [
            SELECT Id
            FROM PermissionSet
            WHERE Name =
                    'SAB_FX_Operations_Workspace'
            LIMIT 1
        ];

        insert new PermissionSetAssignment(
            AssigneeId =
                testUser.Id,
            PermissionSetId =
                workspacePermission.Id
        );

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c =
                        'G7E Workspace Company',
                    Company_Key__c =
                        'G7E',
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
                    'G7E-WORKSPACE-ACCESS',
                Role__c =
                    'Finance Manager'
            );

            GL_Account__c ar =
                account(
                    company.Id,
                    '1200',
                    'Accounts Receivable',
                    'Asset',
                    'Debit',
                    true,
                    'AR'
                );

            GL_Account__c bankGL =
                account(
                    company.Id,
                    '1100',
                    'USD Bank',
                    'Asset',
                    'Debit',
                    false,
                    'None'
                );

            GL_Account__c unrealizedGain =
                account(
                    company.Id,
                    '7200',
                    'Unrealized FX Gain',
                    'Revenue',
                    'Credit',
                    false,
                    'None'
                );

            GL_Account__c unrealizedLoss =
                account(
                    company.Id,
                    '6200',
                    'Unrealized FX Loss',
                    'Expense',
                    'Debit',
                    false,
                    'None'
                );

            GL_Account__c realizedGain =
                account(
                    company.Id,
                    '7300',
                    'Realized FX Gain',
                    'Revenue',
                    'Credit',
                    false,
                    'None'
                );

            GL_Account__c realizedLoss =
                account(
                    company.Id,
                    '6300',
                    'Realized FX Loss',
                    'Expense',
                    'Debit',
                    false,
                    'None'
                );

            company.Unrealized_FX_Gain_Account__c =
                unrealizedGain.Id;
            company.Unrealized_FX_Loss_Account__c =
                unrealizedLoss.Id;
            company.Realized_FX_Gain_Account__c =
                realizedGain.Id;
            company.Realized_FX_Loss_Account__c =
                realizedLoss.Id;
            update company;

            Accounting_Period__c september =
                new Accounting_Period__c(
                    Name =
                        'September 2026',
                    Company__c =
                        company.Id,
                    Company_Period_Key__c =
                        'G7E-2026-09',
                    Period_Key__c =
                        'G7E-2026-09',
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

            Accounting_Period__c october =
                new Accounting_Period__c(
                    Name =
                        'October 2026',
                    Company__c =
                        company.Id,
                    Company_Period_Key__c =
                        'G7E-2026-10',
                    Period_Key__c =
                        'G7E-2026-10',
                    Start_Date__c =
                        Date.newInstance(
                            2026,
                            10,
                            1
                        ),
                    End_Date__c =
                        Date.newInstance(
                            2026,
                            10,
                            31
                        ),
                    Fiscal_Year__c =
                        2026,
                    Fiscal_Quarter__c =
                        4,
                    Period_Number__c =
                        10,
                    Status__c =
                        'Open'
                );
            insert october;

            Exchange_Rate__c closingRate =
                new Exchange_Rate__c(
                    From_Currency__c =
                        'USD',
                    To_Currency__c =
                        'BDT',
                    Rate_Type__c =
                        'Closing',
                    Effective_Date_Time__c =
                        Datetime.newInstance(
                            Date.newInstance(
                                2026,
                                9,
                                30
                            ),
                            Time.newInstance(
                                23,
                                59,
                                59,
                                999
                            )
                        ),
                    Rate__c =
                        110,
                    Source__c =
                        'G7E Approved Closing Rate',
                    Approved__c =
                        true,
                    Approved_By__c =
                        testUser.Id,
                    Rate_Key__c =
                        'G7E-USD-BDT-CLOSING-2026-09'
                );
            insert closingRate;

            Account customerAccount =
                new Account(
                    Name =
                        'G7E Customer'
                );
            insert customerAccount;

            Party_Accounting_Profile__c customer =
                new Party_Accounting_Profile__c(
                    Account__c =
                        customerAccount.Id,
                    Company__c =
                        company.Id,
                    Profile_Key__c =
                        'G7E-CUSTOMER',
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

            Bank_Account__c bank =
                new Bank_Account__c(
                    Name =
                        'G7E USD Bank',
                    Company__c =
                        company.Id,
                    Bank_Name__c =
                        'G7E Bank',
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
                    Legal_Number__c =
                        'G7E-INV-001',
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
                        'G7E-USD-RECEIPT',
                    Amount__c =
                        10,
                    Transaction_Currency__c =
                        'USD',
                    Functional_Currency__c =
                        'BDT',
                    Exchange_Rate__c =
                        110,
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

            SABAccountingPaymentMutationContext.beginMutation();

            try {
                payment.Processing_State__c =
                    'Succeeded';
                update payment;
            } finally {
                SABAccountingPaymentMutationContext.endMutation();
            }

            Payment_Allocation__c allocation =
                new Payment_Allocation__c(
                    Allocation_Key__c =
                        'G7E-ALLOC-001',
                    Payment__c =
                        payment.Id,
                    Company__c =
                        company.Id,
                    Invoice__c =
                        invoice.Id,
                    Allocated_Amount__c =
                        2,
                    Payment_Amount__c =
                        2,
                    Document_Amount__c =
                        2,
                    Base_Amount__c =
                        220,
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
                        'Allocated'
                );
            insert allocation;

            SABRealizedFXSettlementService.mutationInProgress =
                true;

            try {
                allocation.Historical_Carrying_Base__c =
                    200;
                allocation.Settlement_Base_Amount__c =
                    220;
                allocation.Realized_FX_Amount__c =
                    20;
                allocation.Realized_FX_State__c =
                    'Posted';
                allocation.Realized_FX_Source_GL_Account__c =
                    ar.Id;
                update allocation;
            } finally {
                SABRealizedFXSettlementService.mutationInProgress =
                    false;
            }

            FX_Revaluation_Run__c run =
                new FX_Revaluation_Run__c(
                    Company__c =
                        company.Id,
                    Accounting_Period__c =
                        september.Id,
                    Rate_Set_Key__c =
                        'G7E-RATE-SET-001',
                    Reversal_Policy__c =
                        'First Day of Next Period',
                    Run_Key__c =
                        'G7E-RUN-001',
                    Status__c =
                        'Preview'
                );
            insert run;

            insert new FX_Revaluation_Line__c(
                FX_Revaluation_Run__c =
                    run.Id,
                Source_Type__c =
                    'Invoice__c',
                Source_Record_Id__c =
                    String.valueOf(
                        invoice.Id
                    ),
                Source_GL_Account__c =
                    ar.Id,
                Transaction_Currency__c =
                    'USD',
                Outstanding_Amount__c =
                    8,
                Carrying_Amount__c =
                    800,
                Applied_Rate__c =
                    110,
                Exchange_Rate__c =
                    closingRate.Id,
                Revalued_Amount__c =
                    880,
                Adjustment_Amount__c =
                    80
            );
        }
    }

    @IsTest
    static void dashboardShowsFXOperationsData() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Id companyId =
                getCompany().Id;

            Test.startTest();

            SABFXOperationsWorkspaceController.DashboardDTO dashboard =
                SABFXOperationsWorkspaceController.getDashboard(
                    companyId
                );

            Test.stopTest();

            System.assertEquals(
                companyId,
                dashboard.companyId
            );

            System.assertEquals(
                'BDT',
                dashboard.functionalCurrency
            );

            System.assertEquals(
                true,
                dashboard.unrealizedAccountsConfigured
            );

            System.assertEquals(
                true,
                dashboard.realizedAccountsConfigured
            );

            System.assertEquals(
                2,
                dashboard.periods.size()
            );

            System.assertEquals(
                1,
                dashboard.revaluationRuns.size()
            );

            System.assertEquals(
                'Preview',
                dashboard.revaluationRuns[0].status
            );

            System.assertEquals(
                1,
                dashboard.revaluationRuns[0].lineCount
            );

            System.assertEquals(
                Decimal.valueOf('80'),
                dashboard.revaluationRuns[0].signedAdjustmentTotal
            );

            System.assertEquals(
                1,
                dashboard.foreignPayments.size()
            );

            System.assertEquals(
                'Succeeded',
                dashboard.foreignPayments[0].processingState
            );

            System.assertEquals(
                Decimal.valueOf('2'),
                dashboard.foreignPayments[0].activeAllocatedAmount
            );

            System.assertEquals(
                Decimal.valueOf('8'),
                dashboard.foreignPayments[0].unallocatedAmount
            );

            System.assertEquals(
                1,
                dashboard.allocations.size()
            );

            System.assertEquals(
                Decimal.valueOf('20'),
                dashboard.postedRealizedGainTotal
            );
        }
    }

    @IsTest
    static void eligibleTargetsUseDocumentOutstandingAmount() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Accounting_Payment__c payment = [
                SELECT Id
                FROM Accounting_Payment__c
                WHERE Reference__c =
                        'G7E-USD-RECEIPT'
                LIMIT 1
            ];

            Test.startTest();

            List<SABFXOperationsWorkspaceController.SettlementTargetDTO>
                targets =
                    SABFXOperationsWorkspaceController.getEligibleSettlementTargets(
                            payment.Id
                        );

            Test.stopTest();

            System.assertEquals(
                1,
                targets.size()
            );

            System.assertEquals(
                'Invoice',
                targets[0].targetType
            );

            System.assertEquals(
                'USD',
                targets[0].transactionCurrency
            );

            System.assertEquals(
                Decimal.valueOf('10'),
                targets[0].totalAmount
            );

            System.assertEquals(
                Decimal.valueOf('8'),
                targets[0].outstandingAmount
            );

            System.assertEquals(
                Decimal.valueOf('100'),
                targets[0].historicalRate
            );
        }
    }

    @IsTest
    static void companyIdIsRequired() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Boolean blocked =
                false;

            try {
                SABFXOperationsWorkspaceController.getDashboard(
                        null
                    );
            } catch (AuraHandledException ex) {
                blocked =
                    true;
            }

            System.assertEquals(
                true,
                blocked
            );
        }
    }

    private static GL_Account__c account(
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
                Name =
                    displayName,
                Company__c =
                    companyId,
                Company_Account_Key__c =
                    'G7E-' + code,
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
                    !isControl
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
              AND PermissionsModifyAllData =
                    false
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
                    'g7efx',
                Email =
                    'g7efx.'
                    + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    'G7E FX Workspace User',
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    profileRecord.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    'g7efx.'
                    + seed
                    + '@example.test'
            );

        insert row;
        return row;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                    'G7E FX Workspace User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getCompany() {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c =
                    'G7E'
            LIMIT 1
        ];
    }
}
