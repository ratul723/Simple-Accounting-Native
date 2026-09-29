@IsTest
private class SABFXSecurityHardeningTest {

    private static final String WORKSPACE_PERMISSION_SET =
        'SAB_FX_Operations_Workspace';

    @TestSetup
    static void setupUsers() {
        Profile adminProfile = [
            SELECT Id
            FROM Profile
            WHERE UserType =
                    'Standard'
              AND PermissionsModifyAllData =
                    true
            ORDER BY Name
            LIMIT 1
        ];

        Profile standardProfile = [
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

        User adminWithoutWorkspace =
            new User(
                Alias =
                    'g7fadm',
                Email =
                    'g7f.admin.'
                    + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    'G7F Admin Without Workspace',
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    adminProfile.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    'g7f.admin.'
                    + seed
                    + '@example.test'
            );

        User workspaceOnly =
            new User(
                Alias =
                    'g7fws',
                Email =
                    'g7f.workspace.'
                    + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    'G7F Workspace Only',
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    standardProfile.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    'g7f.workspace.'
                    + seed
                    + '@example.test'
            );

        insert new List<User>{
            adminWithoutWorkspace,
            workspaceOnly
        };

        PermissionSet workspacePermission = [
            SELECT Id
            FROM PermissionSet
            WHERE Name =
                    :WORKSPACE_PERMISSION_SET
            LIMIT 1
        ];

        insert new PermissionSetAssignment(
            AssigneeId =
                workspaceOnly.Id,
            PermissionSetId =
                workspacePermission.Id
        );
    }

    @IsTest
    static void systemAdministratorDoesNotBypassWorkspaceCustomPermission() {
        User adminUser =
            getUser(
                'G7F Admin Without Workspace'
            );

        Accounting_Company__c company =
            makeCompany(
                'F7A'
            );

        insert new Company_User_Access__c(
            Company__c =
                company.Id,
            User__c =
                adminUser.Id,
            Effective_From__c =
                Date.today(),
            Grant_Key__c =
                'G7F-ADMIN-GRANT',
            Is_Active__c =
                true,
            Role__c =
                'Finance Manager'
        );

        System.runAs(adminUser) {
            System.assertEquals(
                false,
                SABPermissionService.hasPermission(
                    'SAB_View_FX_Operations'
                ),
                'System Administrator privileges must not silently grant the package Custom Permission.'
            );

            Boolean blocked =
                false;

            try {
                SABFXOperationsWorkspaceController.getDashboard(
                    company.Id
                );
            } catch (Exception ex) {
                blocked =
                    true;
            }

            System.assertEquals(
                true,
                blocked
            );
        }
    }

    @IsTest
    static void workspacePermissionDoesNotBypassCompanyAuthorization() {
        User workspaceUser =
            getUser(
                'G7F Workspace Only'
            );

        Accounting_Company__c company =
            makeCompany(
                'F7B'
            );

        System.runAs(workspaceUser) {
            System.assertEquals(
                true,
                SABPermissionService.hasPermission(
                    'SAB_View_FX_Operations'
                )
            );

            System.assertEquals(
                false,
                SABCompanyAccessService.hasCompanyAccess(
                    company.Id
                )
            );

            Boolean blocked =
                false;

            try {
                SABFXOperationsWorkspaceController.getDashboard(
                    company.Id
                );
            } catch (Exception ex) {
                blocked =
                    true;
            }

            System.assertEquals(
                true,
                blocked,
                'Workspace permission alone must not grant access to an unauthorized Accounting Company.'
            );
        }
    }

    @IsTest
    static void directApprovedRunInsertIsBlocked() {
        Accounting_Company__c company =
            makeCompany(
                'F7C'
            );

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'F7C-P1'
            );

        FX_Revaluation_Run__c run =
            new FX_Revaluation_Run__c(
                Company__c =
                    company.Id,
                Accounting_Period__c =
                    period.Id,
                Rate_Set_Key__c =
                    'F7C-RATESET',
                Reversal_Policy__c =
                    'First Day of Next Period',
                Run_Key__c =
                    'F7C-RUN',
                Status__c =
                    'Approved'
            );

        Database.SaveResult result =
            Database.insert(
                run,
                false
            );

        System.assertEquals(
            false,
            result.isSuccess()
        );

        System.assert(
            result.getErrors()[0]
                .getMessage()
                .contains(
                    'must be created in Preview status'
                ),
            result.getErrors()[0]
                .getMessage()
        );
    }

    @IsTest
    static void previewRunCannotInjectLifecycleAuditFields() {
        Accounting_Company__c company =
            makeCompany(
                'F7D'
            );

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'F7D-P1'
            );

        FX_Revaluation_Run__c run =
            new FX_Revaluation_Run__c(
                Company__c =
                    company.Id,
                Accounting_Period__c =
                    period.Id,
                Rate_Set_Key__c =
                    'F7D-RATESET',
                Reversal_Policy__c =
                    'Next Open Period',
                Run_Key__c =
                    'F7D-RUN',
                Status__c =
                    'Preview',
                Approved_At__c =
                    System.now()
            );

        Database.SaveResult result =
            Database.insert(
                run,
                false
            );

        System.assertEquals(
            false,
            result.isSuccess()
        );

        System.assert(
            result.getErrors()[0]
                .getMessage()
                .contains(
                    'system-managed'
                ),
            result.getErrors()[0]
                .getMessage()
        );
    }

    @IsTest
    static void normalPreviewInsertRemainsAllowed() {
        Accounting_Company__c company =
            makeCompany(
                'F7E'
            );

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'F7E-P1'
            );

        FX_Revaluation_Run__c run =
            new FX_Revaluation_Run__c(
                Company__c =
                    company.Id,
                Accounting_Period__c =
                    period.Id,
                Rate_Set_Key__c =
                    'F7E-RATESET',
                Reversal_Policy__c =
                    'No Automatic Reversal',
                Run_Key__c =
                    'F7E-RUN',
                Status__c =
                    'Preview'
            );

        insert run;

        System.assertNotEquals(
            null,
            run.Id
        );
    }

    @IsTest
    static void lineInsertIntoApprovedRunIsBlocked() {
        Accounting_Company__c company =
            makeCompany(
                'F7F'
            );

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'F7F-P1'
            );

        GL_Account__c accountRecord =
            makeGLAccount(
                company.Id,
                '1200',
                'FX Source',
                'Asset',
                'Debit',
                false,
                'None'
            );

        FX_Revaluation_Run__c run =
            new FX_Revaluation_Run__c(
                Company__c =
                    company.Id,
                Accounting_Period__c =
                    period.Id,
                Rate_Set_Key__c =
                    'F7F-RATESET',
                Reversal_Policy__c =
                    'First Day of Next Period',
                Run_Key__c =
                    'F7F-RUN',
                Status__c =
                    'Preview'
            );
        insert run;

        SABFXRevaluationPostingService.lifecycleMutationInProgress =
            true;

        try {
            run.Status__c =
                'Approved';
            run.Approved_Snapshot_Hash__c =
                'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
            run.Approved_By__c =
                UserInfo.getUserId();
            run.Approved_At__c =
                System.now();
            update run;
        } finally {
            SABFXRevaluationPostingService.lifecycleMutationInProgress =
                false;
        }

        FX_Revaluation_Line__c line =
            new FX_Revaluation_Line__c(
                FX_Revaluation_Run__c =
                    run.Id,
                Source_Type__c =
                    'Invoice__c',
                Source_Record_Id__c =
                    String.valueOf(
                        company.Id
                    ),
                Source_GL_Account__c =
                    accountRecord.Id,
                Transaction_Currency__c =
                    'USD',
                Outstanding_Amount__c =
                    1,
                Carrying_Amount__c =
                    100,
                Revalued_Amount__c =
                    110,
                Adjustment_Amount__c =
                    10,
                Applied_Rate__c =
                    110
            );

        Database.SaveResult result =
            Database.insert(
                line,
                false
            );

        System.assertEquals(
            false,
            result.isSuccess()
        );

        System.assert(
            result.getErrors()[0]
                .getMessage()
                .contains(
                    'locked after approval'
                ),
            result.getErrors()[0]
                .getMessage()
        );
    }

    @IsTest
    static void directRealizedFxSnapshotInsertIsBlocked() {
        SettlementFixture fixture =
            makeSettlementFixture(
                'F7G'
            );

        Payment_Allocation__c allocation =
            validAllocation(
                fixture,
                'F7G-ALLOC'
            );

        allocation.Historical_Carrying_Base__c =
            1000;
        allocation.Settlement_Base_Amount__c =
            1100;
        allocation.Realized_FX_Amount__c =
            100;
        allocation.Realized_FX_State__c =
            'Posted';
        allocation.Realized_FX_Source_GL_Account__c =
            fixture.arAccount.Id;

        Database.SaveResult result =
            Database.insert(
                allocation,
                false
            );

        System.assertEquals(
            false,
            result.isSuccess()
        );

        System.assert(
            result.getErrors()[0]
                .getMessage()
                .contains(
                    'system-managed'
                ),
            result.getErrors()[0]
                .getMessage()
        );
    }

    @IsTest
    static void directRealizedFxUpdateAndStatusBypassAreBlocked() {
        SettlementFixture fixture =
            makeSettlementFixture(
                'F7H'
            );

        Payment_Allocation__c allocation =
            validAllocation(
                fixture,
                'F7H-ALLOC'
            );
        insert allocation;

        allocation = [
            SELECT Id,
                   Status__c,
                   Historical_Carrying_Base__c,
                   Settlement_Base_Amount__c,
                   Realized_FX_Amount__c,
                   Realized_FX_State__c,
                   Realized_FX_Source_GL_Account__c
            FROM Payment_Allocation__c
            WHERE Id =
                    :allocation.Id
        ];

        SABRealizedFXSettlementService.mutationInProgress =
            true;

        try {
            allocation.Historical_Carrying_Base__c =
                1000;
            allocation.Settlement_Base_Amount__c =
                1100;
            allocation.Realized_FX_Amount__c =
                100;
            allocation.Realized_FX_State__c =
                'Posted';
            allocation.Realized_FX_Source_GL_Account__c =
                fixture.arAccount.Id;
            update allocation;
        } finally {
            SABRealizedFXSettlementService.mutationInProgress =
                false;
        }

        Payment_Allocation__c directFinancialEdit = [
            SELECT Id,
                   Realized_FX_Amount__c
            FROM Payment_Allocation__c
            WHERE Id =
                    :allocation.Id
        ];

        directFinancialEdit.Realized_FX_Amount__c =
            999;

        Database.SaveResult financialResult =
            Database.update(
                directFinancialEdit,
                false
            );

        System.assertEquals(
            false,
            financialResult.isSuccess()
        );

        Payment_Allocation__c directStatusEdit = [
            SELECT Id,
                   Status__c
            FROM Payment_Allocation__c
            WHERE Id =
                    :allocation.Id
        ];

        directStatusEdit.Status__c =
            'Reversed';

        Database.SaveResult statusResult =
            Database.update(
                directStatusEdit,
                false
            );

        System.assertEquals(
            false,
            statusResult.isSuccess()
        );

        System.assert(
            statusResult.getErrors()[0]
                .getMessage()
                .contains(
                    'cannot change status'
                ),
            statusResult.getErrors()[0]
                .getMessage()
        );
    }

    private class SettlementFixture {
        Accounting_Company__c company;
        Accounting_Period__c period;
        GL_Account__c arAccount;
        GL_Account__c bankGL;
        Party_Accounting_Profile__c customer;
        Bank_Account__c bank;
        Invoice__c invoice;
        Accounting_Payment__c payment;
    }

    private static SettlementFixture makeSettlementFixture(
        String keyValue
    ) {
        SettlementFixture fixture =
            new SettlementFixture();

        fixture.company =
            makeCompany(
                keyValue
            );

        fixture.period =
            makePeriod(
                fixture.company.Id,
                keyValue + '-P1'
            );

        fixture.arAccount =
            makeGLAccount(
                fixture.company.Id,
                '1200',
                'AR ' + keyValue,
                'Asset',
                'Debit',
                true,
                'AR'
            );

        fixture.bankGL =
            makeGLAccount(
                fixture.company.Id,
                '1100',
                'Bank ' + keyValue,
                'Asset',
                'Debit',
                false,
                'None'
            );

        Account customerAccount =
            new Account(
                Name =
                    'Customer ' + keyValue
            );
        insert customerAccount;

        fixture.customer =
            new Party_Accounting_Profile__c(
                Company__c =
                    fixture.company.Id,
                Account__c =
                    customerAccount.Id,
                Profile_Key__c =
                    keyValue + '-CUSTOMER',
                Is_Customer__c =
                    true,
                Is_Supplier__c =
                    false,
                Is_Active__c =
                    true,
                AR_Control_Account__c =
                    fixture.arAccount.Id
            );
        insert fixture.customer;

        fixture.bank =
            new Bank_Account__c(
                Name =
                    'USD Bank ' + keyValue,
                Company__c =
                    fixture.company.Id,
                Bank_Name__c =
                    'Test Bank',
                Currency__c =
                    'USD',
                GL_Account__c =
                    fixture.bankGL.Id,
                Is_Active__c =
                    true
            );
        insert fixture.bank;

        fixture.invoice =
            new Invoice__c(
                Company__c =
                    fixture.company.Id,
                Party_Profile__c =
                    fixture.customer.Id,
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
                    keyValue + '-INV',
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
        insert fixture.invoice;

        fixture.invoice.Status__c =
            'Posted';
        update fixture.invoice;

        fixture.payment =
            new Accounting_Payment__c(
                Company__c =
                    fixture.company.Id,
                Party_Profile__c =
                    fixture.customer.Id,
                Bank_Account__c =
                    fixture.bank.Id,
                Direction__c =
                    'Receipt',
                Method__c =
                    'Bank Transfer',
                Reference__c =
                    keyValue + '-PAY',
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
        insert fixture.payment;

        SABAccountingPaymentMutationContext.beginMutation();

        try {
            fixture.payment.Processing_State__c =
                'Succeeded';
            update fixture.payment;
        } finally {
            SABAccountingPaymentMutationContext.endMutation();
        }

        return fixture;
    }

    private static Payment_Allocation__c validAllocation(
        SettlementFixture fixture,
        String keyValue
    ) {
        return new Payment_Allocation__c(
            Allocation_Key__c =
                keyValue,
            Payment__c =
                fixture.payment.Id,
            Company__c =
                fixture.company.Id,
            Invoice__c =
                fixture.invoice.Id,
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
                'Allocated'
        );
    }

    private static Accounting_Company__c makeCompany(
        String keyValue
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    'G7F Company ' + keyValue,
                Company_Key__c =
                    keyValue,
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

    private static Accounting_Period__c makePeriod(
        Id companyId,
        String keyValue
    ) {
        Accounting_Period__c period =
            new Accounting_Period__c(
                Name =
                    keyValue,
                Company__c =
                    companyId,
                Company_Period_Key__c =
                    keyValue,
                Period_Key__c =
                    keyValue,
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
        return period;
    }

    private static GL_Account__c makeGLAccount(
        Id companyId,
        String code,
        String label,
        String accountType,
        String normalBalance,
        Boolean isControl,
        String controlType
    ) {
        GL_Account__c accountRecord =
            new GL_Account__c(
                Name =
                    label,
                Company__c =
                    companyId,
                Company_Account_Key__c =
                    String.valueOf(
                        companyId
                    )
                    + '-'
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
                    isControl,
                Control_Type__c =
                    controlType,
                Manual_Posting_Allowed__c =
                    !isControl
            );

        insert accountRecord;
        return accountRecord;
    }

    private static User getUser(
        String lastName
    ) {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                    :lastName
            LIMIT 1
        ];
    }
}
