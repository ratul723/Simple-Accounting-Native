@IsTest
private class SABFXRevaluationPostingServiceTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Remaining_Fields_Admin',
            'SAB_Post_Journal_Action',
            'SAB_Approve_FX_Revaluation_Action',
            'SAB_Post_FX_Revaluation_Action'
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
                        'G7B FX Company',
                    Company_Key__c =
                        'G7B',
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
                    'G7B-ACCESS',
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
                        'G7B-2026-09',
                    Period_Key__c =
                        'G7B-2026-09',
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

            GL_Account__c gain =
                makeAccount(
                    company.Id,
                    '7200',
                    'Unrealized FX Gain',
                    'Revenue',
                    'Credit',
                    false,
                    'None'
                );

            GL_Account__c loss =
                makeAccount(
                    company.Id,
                    '6200',
                    'Unrealized FX Loss',
                    'Expense',
                    'Debit',
                    false,
                    'None'
                );

            company.Unrealized_FX_Gain_Account__c =
                gain.Id;
            company.Unrealized_FX_Loss_Account__c =
                loss.Id;
            update company;

            Exchange_Rate__c rate =
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
                                12,
                                0,
                                0,
                                0
                            )
                        ),
                    Rate__c =
                        110,
                    Source__c =
                        'G7B Test',
                    Approved__c =
                        true,
                    Approved_By__c =
                        testUser.Id,
                    Rate_Key__c =
                        'G7B-USD-BDT-CLOSING'
                );
            insert rate;

            FX_Revaluation_Run__c run =
                new FX_Revaluation_Run__c(
                    Company__c =
                        company.Id,
                    Accounting_Period__c =
                        period.Id,
                    Rate_Set_Key__c =
                        'G7B-RATE-SET',
                    Reversal_Policy__c =
                        'First Day of Next Period',
                    Run_Key__c =
                        'G7B-RUN-001',
                    Status__c =
                        'Preview'
                );
            insert run;

            insert new List<FX_Revaluation_Line__c>{
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
                        ar.Id,
                    Transaction_Currency__c =
                        'USD',
                    Outstanding_Amount__c =
                        10,
                    Carrying_Amount__c =
                        1000,
                    Revalued_Amount__c =
                        1100,
                    Adjustment_Amount__c =
                        100,
                    Applied_Rate__c =
                        110,
                    Exchange_Rate__c =
                        rate.Id
                ),
                new FX_Revaluation_Line__c(
                    FX_Revaluation_Run__c =
                        run.Id,
                    Source_Type__c =
                        'Supplier_Bill__c',
                    Source_Record_Id__c =
                        String.valueOf(
                            period.Id
                        ),
                    Source_GL_Account__c =
                        ap.Id,
                    Transaction_Currency__c =
                        'USD',
                    Outstanding_Amount__c =
                        8,
                    Carrying_Amount__c =
                        800,
                    Revalued_Amount__c =
                        880,
                    Adjustment_Amount__c =
                        -80,
                    Applied_Rate__c =
                        110,
                    Exchange_Rate__c =
                        rate.Id
                )
            };
        }
    }

    @IsTest
    static void approveLocksPreviewAndCreatesAudit() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            FX_Revaluation_Run__c run =
                getRun();

            Test.startTest();

            SABFXRevaluationPostingService.LifecycleResult result =
                SABFXRevaluationPostingService.approveRun(
                    run.Id,
                    'G7B-APPROVE-001',
                    'Controller reviewed FX preview.'
                );

            Test.stopTest();

            System.assertEquals(
                'Approved',
                result.status
            );

            System.assertEquals(
                64,
                result.approvedSnapshotHash.length()
            );

            System.assertNotEquals(
                null,
                result.approvedAt
            );

            Integer auditCount = [
                SELECT COUNT()
                FROM Business_Action__c
                WHERE Request_Key__c =
                        'G7B-APPROVE-001'
            ];

            System.assertEquals(
                1,
                auditCount
            );

            FX_Revaluation_Line__c line = [
                SELECT Id,
                       FX_Revaluation_Run__c,
                       Adjustment_Amount__c
                FROM FX_Revaluation_Line__c
                WHERE FX_Revaluation_Run__c =
                        :run.Id
                LIMIT 1
            ];

            line.Adjustment_Amount__c =
                line.Adjustment_Amount__c
                + 1;

            Boolean blocked =
                false;

            try {
                update line;
            } catch (DmlException ex) {
                blocked =
                    ex.getMessage().contains(
                        'locked after approval'
                    );
            }

            System.assertEquals(
                true,
                blocked
            );
        }
    }

    @IsTest
    static void approvedRunPostsBalancedJournalExactlyOnce() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            FX_Revaluation_Run__c run =
                getRun();

            SABFXRevaluationPostingService.approveRun(
                run.Id,
                'G7B-APPROVE-POST',
                'Approved for posting.'
            );

            Test.startTest();

            SABFXRevaluationPostingService.LifecycleResult first =
                SABFXRevaluationPostingService.postApprovedRun(
                    run.Id,
                    'G7B-POST-001',
                    'Month-end FX revaluation.'
                );

            SABFXRevaluationPostingService.LifecycleResult replay =
                SABFXRevaluationPostingService.postApprovedRun(
                    run.Id,
                    'G7B-POST-001',
                    'Month-end FX revaluation.'
                );

            Test.stopTest();

            System.assertEquals(
                'Posted',
                first.status
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

            Journal_Entry__c journal = [
                SELECT Id,
                       Status__c,
                       Entry_Type__c,
                       Accounting_Event__c
                FROM Journal_Entry__c
                WHERE Id =
                        :first.journalEntryId
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
                first.accountingEventId,
                journal.Accounting_Event__c
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
                'FX Revaluation',
                eventRecord.Event_Type__c
            );

            System.assertEquals(
                'Posted',
                eventRecord.State__c
            );

            System.assertEquals(
                'FX_Revaluation_Run__c',
                eventRecord.Source_Type__c
            );

            System.assertEquals(
                String.valueOf(
                    run.Id
                ),
                eventRecord.Source_Record_Id__c
            );

            AggregateResult totals = [
                SELECT SUM(Debit_Base__c) totalDebit,
                       SUM(Credit_Base__c) totalCredit
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c =
                        :journal.Id
            ];

            System.assertEquals(
                Decimal.valueOf('180.0000'),
                (Decimal)totals.get(
                    'totalDebit'
                )
            );

            System.assertEquals(
                Decimal.valueOf('180.0000'),
                (Decimal)totals.get(
                    'totalCredit'
                )
            );

            Accounting_Company__c company = [
                SELECT Unrealized_FX_Gain_Account__c,
                       Unrealized_FX_Loss_Account__c
                FROM Accounting_Company__c
                WHERE Id =
                        :getCompany().Id
            ];

            Journal_Entry_Line__c gainLine = [
                SELECT Credit_Base__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c =
                        :journal.Id
                  AND GL_Account__c =
                        :company.Unrealized_FX_Gain_Account__c
                LIMIT 1
            ];

            Journal_Entry_Line__c lossLine = [
                SELECT Debit_Base__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c =
                        :journal.Id
                  AND GL_Account__c =
                        :company.Unrealized_FX_Loss_Account__c
                LIMIT 1
            ];

            System.assertEquals(
                Decimal.valueOf('100.0000'),
                gainLine.Credit_Base__c
            );

            System.assertEquals(
                Decimal.valueOf('80.0000'),
                lossLine.Debit_Base__c
            );

            Integer journalCount = [
                SELECT COUNT()
                FROM Journal_Entry__c
                WHERE Id =
                        :first.journalEntryId
            ];

            System.assertEquals(
                1,
                journalCount
            );
        }
    }

    @IsTest
    static void tamperedApprovedSnapshotCannotPost() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            FX_Revaluation_Run__c run =
                getRun();

            SABFXRevaluationPostingService.approveRun(
                run.Id,
                'G7B-APPROVE-TAMPER',
                'Approve then simulate corruption.'
            );

            FX_Revaluation_Line__c line = [
                SELECT Id,
                       FX_Revaluation_Run__c,
                       Adjustment_Amount__c
                FROM FX_Revaluation_Line__c
                WHERE FX_Revaluation_Run__c =
                        :run.Id
                LIMIT 1
            ];

            SABFXRevaluationPostingService.lifecycleMutationInProgress =
                true;

            try {
                line.Adjustment_Amount__c =
                    line.Adjustment_Amount__c
                    + 5;
                update line;
            } finally {
                SABFXRevaluationPostingService.lifecycleMutationInProgress =
                    false;
            }

            Boolean blocked =
                false;

            try {
                SABFXRevaluationPostingService.postApprovedRun(
                    run.Id,
                    'G7B-POST-TAMPER',
                    'Must fail.'
                );
            } catch (
                SABFXRevaluationPostingService.FXPostingException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'changed after approval'
                    );
            }

            System.assertEquals(
                true,
                blocked
            );
        }
    }

    @IsTest
    static void missingGainLossConfigurationBlocksPosting() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            FX_Revaluation_Run__c run =
                getRun();

            SABFXRevaluationPostingService.approveRun(
                run.Id,
                'G7B-APPROVE-NOCFG',
                'Approve.'
            );

            Accounting_Company__c company =
                getCompany();

            company.Unrealized_FX_Gain_Account__c =
                null;

            update company;

            Boolean blocked =
                false;

            try {
                SABFXRevaluationPostingService.postApprovedRun(
                    run.Id,
                    'G7B-POST-NOCFG',
                    'Must fail.'
                );
            } catch (
                SABFXRevaluationPostingService.FXPostingException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'requires both Unrealized FX Gain and Unrealized FX Loss'
                    );
            }

            System.assertEquals(
                true,
                blocked
            );
        }
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
                Name =
                    displayName,
                Company__c =
                    companyId,
                Company_Account_Key__c =
                    'G7B-' + code,
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
                    'g7bfx',
                Email =
                    'g7bfx.'
                    + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    'G7B FX User',
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    profileRecord.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    'g7bfx.'
                    + seed
                    + '@example.test'
            );

        insert row;

        return row;
    }

    private static void assignPermissionSets(
        User userRecord
    ) {
        Map<String, Id> idsByName =
            new Map<String, Id>();

        for (PermissionSet row : [
            SELECT Id,
                   Name
            FROM PermissionSet
            WHERE Name IN :REQUIRED_PERMISSION_SETS
        ]) {
            idsByName.put(
                row.Name,
                row.Id
            );
        }

        System.assertEquals(
            REQUIRED_PERMISSION_SETS.size(),
            idsByName.size(),
            'All G7B dependency permission sets must exist.'
        );

        List<PermissionSetAssignment> assignments =
            new List<PermissionSetAssignment>();

        for (
            String permissionSetName :
            REQUIRED_PERMISSION_SETS
        ) {
            assignments.add(
                new PermissionSetAssignment(
                    AssigneeId =
                        userRecord.Id,
                    PermissionSetId =
                        idsByName.get(
                            permissionSetName
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
                    'G7B FX User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getCompany() {
        return [
            SELECT Id,
                   Unrealized_FX_Gain_Account__c,
                   Unrealized_FX_Loss_Account__c
            FROM Accounting_Company__c
            WHERE Company_Key__c =
                    'G7B'
            LIMIT 1
        ];
    }

    private static FX_Revaluation_Run__c getRun() {
        return [
            SELECT Id,
                   Status__c
            FROM FX_Revaluation_Run__c
            WHERE Run_Key__c =
                    'G7B-RUN-001'
            LIMIT 1
        ];
    }
}
