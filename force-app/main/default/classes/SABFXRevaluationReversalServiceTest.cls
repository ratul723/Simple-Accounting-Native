@IsTest
private class SABFXRevaluationReversalServiceTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Remaining_Fields_Admin',
            'SAB_Post_Journal_Action',
            'SAB_Reverse_Journal_Action',
            'SAB_Reverse_FX_Revaluation_Action'
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
                        'G7C Reversal Company',
                    Company_Key__c =
                        'G7R',
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
                    'G7C-REV-ACCESS',
                Role__c =
                    'Finance Manager'
            );

            Accounting_Period__c september =
                period(
                    company.Id,
                    'G7R-2026-09',
                    Date.newInstance(
                        2026,
                        9,
                        1
                    ),
                    Date.newInstance(
                        2026,
                        9,
                        30
                    ),
                    9
                );

            Accounting_Period__c october =
                period(
                    company.Id,
                    'G7R-2026-10',
                    Date.newInstance(
                        2026,
                        10,
                        1
                    ),
                    Date.newInstance(
                        2026,
                        10,
                        31
                    ),
                    10
                );

            GL_Account__c expense =
                account(
                    company.Id,
                    '6100',
                    'FX Test Expense',
                    'Expense',
                    'Debit'
                );

            GL_Account__c revenue =
                account(
                    company.Id,
                    '7100',
                    'FX Test Revenue',
                    'Revenue',
                    'Credit'
                );

            GL_Account__c source =
                account(
                    company.Id,
                    '1200',
                    'FX Test AR',
                    'Asset',
                    'Debit'
                );

            Id journalId =
                postJournal(
                    company.Id,
                    september.Id,
                    expense.Id,
                    revenue.Id,
                    'G7C-BASE-JOURNAL-001'
                );

            FX_Revaluation_Run__c run =
                new FX_Revaluation_Run__c(
                    Company__c =
                        company.Id,
                    Accounting_Period__c =
                        september.Id,
                    Rate_Set_Key__c =
                        'G7C-RATESET-001',
                    Reversal_Policy__c =
                        'First Day of Next Period',
                    Run_Key__c =
                        'G7C-REV-RUN-001',
                    Status__c =
                        'Preview'
                );
            insert run;

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
                        source.Id,
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
                        110
                );
            insert line;

            SABFXRevaluationPostingService.lifecycleMutationInProgress =
                true;

            try {
                run.Journal_Entry__c =
                    journalId;
                run.Approved_Snapshot_Hash__c =
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
                run.Approved_By__c =
                    testUser.Id;
                run.Approved_At__c =
                    System.now();
                run.Posted_At__c =
                    System.now();
                run.Status__c =
                    'Posted';
                update run;
            } finally {
                SABFXRevaluationPostingService.lifecycleMutationInProgress =
                    false;
            }
        }
    }

    @IsTest
    static void firstDayPolicyReversesAndReplays() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            FX_Revaluation_Run__c run =
                getRun(
                    'G7C-REV-RUN-001'
                );

            Test.startTest();

            SABFXRevaluationReversalService.ReversalResult first =
                SABFXRevaluationReversalService.reversePostedRun(
                    run.Id,
                    null,
                    null,
                    'G7C-REV-REQ-001',
                    'Reverse September unrealized FX on opening day.'
                );

            SABFXRevaluationReversalService.ReversalResult replay =
                SABFXRevaluationReversalService.reversePostedRun(
                    run.Id,
                    null,
                    null,
                    'G7C-REV-REQ-001',
                    'Reverse September unrealized FX on opening day.'
                );

            Test.stopTest();

            System.assertEquals(
                'Reversed',
                first.status
            );

            System.assertEquals(
                Date.newInstance(
                    2026,
                    10,
                    1
                ),
                first.reversalAccountingDate
            );

            System.assertNotEquals(
                null,
                first.reversalJournalEntryId
            );

            System.assertNotEquals(
                null,
                first.reversalAccountingEventId
            );

            System.assertEquals(
                true,
                replay.replay
            );

            System.assertEquals(
                first.reversalJournalEntryId,
                replay.reversalJournalEntryId
            );

            Journal_Entry__c originalJournal = [
                SELECT Status__c,
                       Reversal_Journal__c
                FROM Journal_Entry__c
                WHERE Id =
                        :first.originalJournalEntryId
            ];

            System.assertEquals(
                'Reversed',
                originalJournal.Status__c
            );

            System.assertEquals(
                first.reversalJournalEntryId,
                originalJournal.Reversal_Journal__c
            );

            Journal_Entry__c reversalJournal = [
                SELECT Status__c,
                       Accounting_Date__c,
                       Accounting_Period__c,
                       Reversal_Of__c
                FROM Journal_Entry__c
                WHERE Id =
                        :first.reversalJournalEntryId
            ];

            System.assertEquals(
                'Posted',
                reversalJournal.Status__c
            );

            System.assertEquals(
                Date.newInstance(
                    2026,
                    10,
                    1
                ),
                reversalJournal.Accounting_Date__c
            );

            Accounting_Event__c reversalEvent = [
                SELECT Event_Type__c,
                       State__c
                FROM Accounting_Event__c
                WHERE Id =
                        :first.reversalAccountingEventId
            ];

            System.assertEquals(
                'Reversal',
                reversalEvent.Event_Type__c
            );

            System.assertEquals(
                'Posted',
                reversalEvent.State__c
            );

            Integer auditCount = [
                SELECT COUNT()
                FROM Business_Action__c
                WHERE Request_Key__c =
                        'G7C-REV-REQ-001'
            ];

            System.assertEquals(
                1,
                auditCount
            );

            // Guard coverage: a reversed run is locked.
            FX_Revaluation_Run__c protectedRun = [
                SELECT Id,
                       Reversal_Policy__c
                FROM FX_Revaluation_Run__c
                WHERE Id =
                        :run.Id
            ];

            protectedRun.Reversal_Policy__c =
                'No Automatic Reversal';

            Boolean runBlocked =
                false;

            try {
                update protectedRun;
            } catch (DmlException ex) {
                runBlocked =
                    ex.getMessage().contains(
                        'locked'
                    );
            }

            System.assertEquals(
                true,
                runBlocked
            );

            FX_Revaluation_Line__c protectedLine = [
                SELECT Id,
                       Adjustment_Amount__c
                FROM FX_Revaluation_Line__c
                WHERE FX_Revaluation_Run__c =
                        :run.Id
                LIMIT 1
            ];

            protectedLine.Adjustment_Amount__c =
                105;

            Boolean lineBlocked =
                false;

            try {
                update protectedLine;
            } catch (DmlException ex) {
                lineBlocked =
                    ex.getMessage().contains(
                        'locked after approval'
                    );
            }

            System.assertEquals(
                true,
                lineBlocked
            );

            Boolean deleteBlocked =
                false;

            try {
                delete protectedRun;
            } catch (DmlException ex) {
                deleteBlocked =
                    ex.getMessage().contains(
                        'Only Preview'
                    );
            }

            System.assertEquals(
                true,
                deleteBlocked
            );
        }
    }

    @IsTest
    static void manualPolicyRequiresExplicitPeriodAndDate() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            FX_Revaluation_Run__c run =
                createPostedRun(
                    'G7C-MANUAL-RUN',
                    'No Automatic Reversal'
                );

            Boolean blocked =
                false;

            try {
                SABFXRevaluationReversalService.reversePostedRun(
                    run.Id,
                    null,
                    null,
                    'G7C-MANUAL-MISSING',
                    'Manual reversal test.'
                );
            } catch (
                SABFXRevaluationReversalService.FXRevaluationReversalException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'requires an explicit'
                    );
            }

            System.assertEquals(
                true,
                blocked
            );

            Accounting_Period__c october =
                getPeriod(
                    'G7R-2026-10'
                );

            // createPostedRun() intentionally exercises the already-tested
            // posting stack to build a realistic Posted journal fixture.
            // Reset governor limits before exercising G7C reversal itself.
            Test.startTest();

            SABFXRevaluationReversalService.ReversalResult result =
                SABFXRevaluationReversalService.reversePostedRun(
                    run.Id,
                    october.Id,
                    Date.newInstance(
                        2026,
                        10,
                        15
                    ),
                    'G7C-MANUAL-OK',
                    'Controller selected a manual reversal date.'
                );

            Test.stopTest();

            System.assertEquals(
                'Reversed',
                result.status
            );

            System.assertEquals(
                Date.newInstance(
                    2026,
                    10,
                    15
                ),
                result.reversalAccountingDate
            );
        }
    }

    @IsTest
    static void nextOpenPeriodPolicyResolvesEarliestLaterOpenPeriod() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            FX_Revaluation_Run__c run =
                createPostedRun(
                    'G7C-NEXTOPEN-RUN',
                    'Next Open Period'
                );

            // The helper above creates a real Posted journal through the
            // central posting stack. Give the reversal path its own fresh
            // governor-limit context, matching production execution.
            Test.startTest();

            SABFXRevaluationReversalService.ReversalResult result =
                SABFXRevaluationReversalService.reversePostedRun(
                    run.Id,
                    null,
                    null,
                    'G7C-NEXTOPEN-REQ',
                    'Reverse in earliest later open period.'
                );

            Test.stopTest();

            System.assertEquals(
                Date.newInstance(
                    2026,
                    10,
                    1
                ),
                result.reversalAccountingDate
            );

            System.assertEquals(
                getPeriod(
                    'G7R-2026-10'
                ).Id,
                result.reversalAccountingPeriodId
            );
        }
    }

    private static FX_Revaluation_Run__c createPostedRun(
        String runKey,
        String policy
    ) {
        Accounting_Company__c company =
            getCompany();

        Accounting_Period__c september =
            getPeriod(
                'G7R-2026-09'
            );

        List<GL_Account__c> accounts = [
            SELECT Id,
                   Account_Type__c
            FROM GL_Account__c
            WHERE Company__c =
                    :company.Id
              AND Account_Type__c IN (
                    'Expense',
                    'Revenue'
                  )
            ORDER BY Account_Type__c
        ];

        Id expenseId;
        Id revenueId;

        for (GL_Account__c accountRecord : accounts) {
            if (
                accountRecord.Account_Type__c
                    == 'Expense'
            ) {
                expenseId =
                    accountRecord.Id;
            } else if (
                accountRecord.Account_Type__c
                    == 'Revenue'
            ) {
                revenueId =
                    accountRecord.Id;
            }
        }

        Id journalId =
            postJournal(
                company.Id,
                september.Id,
                expenseId,
                revenueId,
                runKey + '-JNL'
            );

        FX_Revaluation_Run__c run =
            new FX_Revaluation_Run__c(
                Company__c =
                    company.Id,
                Accounting_Period__c =
                    september.Id,
                Rate_Set_Key__c =
                    runKey + '-RATESET',
                Reversal_Policy__c =
                    policy,
                Run_Key__c =
                    runKey,
                Status__c =
                    'Preview'
            );

        insert run;

        SABFXRevaluationPostingService.lifecycleMutationInProgress =
            true;

        try {
            run.Journal_Entry__c =
                journalId;
            run.Approved_Snapshot_Hash__c =
                'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
            run.Approved_By__c =
                UserInfo.getUserId();
            run.Approved_At__c =
                System.now();
            run.Posted_At__c =
                System.now();
            run.Status__c =
                'Posted';
            update run;
        } finally {
            SABFXRevaluationPostingService.lifecycleMutationInProgress =
                false;
        }

        return run;
    }

    private static Id postJournal(
        Id companyId,
        Id periodId,
        Id debitAccountId,
        Id creditAccountId,
        String seed
    ) {
        Journal_Entry__c journal =
            new Journal_Entry__c(
                Company__c =
                    companyId,
                Accounting_Period__c =
                    periodId,
                Accounting_Date__c =
                    Date.newInstance(
                        2026,
                        9,
                        30
                    ),
                Entry_Type__c =
                    'Subledger',
                Status__c =
                    'Draft',
                Description__c =
                    seed,
                Version__c =
                    1
            );

        insert journal;

        insert new List<Journal_Entry_Line__c>{
            new Journal_Entry_Line__c(
                Journal_Entry__c =
                    journal.Id,
                Line_Number__c =
                    1,
                GL_Account__c =
                    debitAccountId,
                Debit_Base__c =
                    100,
                Credit_Base__c =
                    0,
                Functional_Currency__c =
                    'BDT',
                Explanation__c =
                    'G7C reversal test debit',
                Source_Line_Key__c =
                    seed + '-DR'
            ),
            new Journal_Entry_Line__c(
                Journal_Entry__c =
                    journal.Id,
                Line_Number__c =
                    2,
                GL_Account__c =
                    creditAccountId,
                Debit_Base__c =
                    0,
                Credit_Base__c =
                    100,
                Functional_Currency__c =
                    'BDT',
                Explanation__c =
                    'G7C reversal test credit',
                Source_Line_Key__c =
                    seed + '-CR'
            )
        };

        SABAccountingEventService.ReservationRequest eventRequest =
            new SABAccountingEventService.ReservationRequest();

        eventRequest.companyId =
            companyId;
        eventRequest.adapterKey =
            'FX_REVALUATION';
        eventRequest.requestKey =
            seed + '-EVENT-REQ';
        eventRequest.eventKey =
            seed + '-EVENT';
        eventRequest.eventType =
            'FX Revaluation';
        eventRequest.sourceBusinessKey =
            seed;
        eventRequest.sourceRecordId =
            String.valueOf(
                companyId
            );
        eventRequest.sourceType =
            'Accounting_Company__c';
        eventRequest.sourceVersion =
            1;

        SABPostingService.PostingRequest postingRequest =
            new SABPostingService.PostingRequest();

        postingRequest.journalEntryId =
            journal.Id;
        postingRequest.postingKey =
            seed + '-POST';
        postingRequest.eventRequest =
            eventRequest;

        SABPostingService.PostingResult result =
            SABPostingService.postDraftJournal(
                postingRequest
            );

        return result.journalEntryId;
    }

    private static Accounting_Period__c period(
        Id companyId,
        String key,
        Date startDate,
        Date endDate,
        Integer numberValue
    ) {
        Accounting_Period__c row =
            new Accounting_Period__c(
                Name =
                    key,
                Company__c =
                    companyId,
                Company_Period_Key__c =
                    key,
                Period_Key__c =
                    key,
                Start_Date__c =
                    startDate,
                End_Date__c =
                    endDate,
                Fiscal_Year__c =
                    2026,
                Fiscal_Quarter__c =
                    numberValue <= 9
                        ? 3
                        : 4,
                Period_Number__c =
                    numberValue,
                Status__c =
                    'Open'
            );

        insert row;
        return row;
    }

    private static GL_Account__c account(
        Id companyId,
        String code,
        String displayName,
        String accountType,
        String normalBalance
    ) {
        GL_Account__c row =
            new GL_Account__c(
                Name =
                    displayName,
                Company__c =
                    companyId,
                Company_Account_Key__c =
                    'G7R-' + code,
                Account_Code__c =
                    code,
                Account_Type__c =
                    accountType,
                Normal_Balance__c =
                    normalBalance,
                Is_Active__c =
                    true,
                Is_Control_Account__c =
                    false,
                Control_Type__c =
                    'None',
                Manual_Posting_Allowed__c =
                    true
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
                    'g7crv',
                Email =
                    'g7crv.'
                    + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    'G7C Reversal User',
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    profileRecord.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    'g7crv.'
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
            'All G7C reversal dependency permission sets must exist.'
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
                    'G7C Reversal User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getCompany() {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c =
                    'G7R'
            LIMIT 1
        ];
    }

    private static Accounting_Period__c getPeriod(
        String periodKey
    ) {
        return [
            SELECT Id,
                   Start_Date__c,
                   End_Date__c,
                   Status__c
            FROM Accounting_Period__c
            WHERE Period_Key__c =
                    :periodKey
            LIMIT 1
        ];
    }

    private static FX_Revaluation_Run__c getRun(
        String runKey
    ) {
        return [
            SELECT Id,
                   Status__c
            FROM FX_Revaluation_Run__c
            WHERE Run_Key__c =
                    :runKey
            LIMIT 1
        ];
    }
}
