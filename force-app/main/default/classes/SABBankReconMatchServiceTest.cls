@IsTest
private class SABBankReconMatchServiceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String RECONCILE_PERMISSION_SET =
        'SAB_Reconcile_Bank_Action';

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
                        'G5B Reconciliation Company',
                    Company_Key__c =
                        'BRC',
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
                    'G5B-ACCESS',
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
                        'BRC-2026-09',
                    Period_Key__c =
                        '2026-09-BRC',
                    Start_Date__c =
                        Date.newInstance(2026, 9, 1),
                    End_Date__c =
                        Date.newInstance(2026, 9, 30),
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

            GL_Account__c bankGL =
                createGL(
                    company.Id,
                    '1100',
                    'G5B Bank GL',
                    'Asset',
                    'Debit',
                    'BRC-1100'
                );

            GL_Account__c offsetGL =
                createGL(
                    company.Id,
                    '4900',
                    'G5B Clearing GL',
                    'Expense',
                    'Debit',
                    'BRC-4900'
                );

            Bank_Account__c bank =
                new Bank_Account__c(
                    Name =
                        'G5B Main BDT Bank',
                    Company__c =
                        company.Id,
                    Bank_Name__c =
                        'G5B Bank',
                    Currency__c =
                        'BDT',
                    GL_Account__c =
                        bankGL.Id,
                    Is_Active__c =
                        true
                );
            insert bank;

            Bank_Statement__c statement =
                new Bank_Statement__c(
                    Company__c =
                        company.Id,
                    Bank_Account__c =
                        bank.Id,
                    Opening_Amount__c =
                        1000,
                    Closing_Amount__c =
                        1100,
                    Currency__c =
                        'BDT',
                    Import_Fingerprint__c =
                        'G5B-STATEMENT-001',
                    Statement_Start_Date__c =
                        Date.newInstance(2026, 9, 1),
                    Statement_End_Date__c =
                        Date.newInstance(2026, 9, 30),
                    Status__c =
                        'Validated'
                );
            insert statement;

            insert new List<Bank_Statement_Line__c>{
                new Bank_Statement_Line__c(
                    Bank_Statement__c =
                        statement.Id,
                    Line_Number__c =
                        1,
                    Transaction_Date__c =
                        Date.newInstance(2026, 9, 10),
                    Value_Date__c =
                        Date.newInstance(2026, 9, 10),
                    Amount__c =
                        200,
                    Provider_Line_Id__c =
                        'G5B-DEP',
                    Reference__c =
                        'Customer receipt',
                    Line_Fingerprint__c =
                        'G5B-LINE-DEP'
                ),
                new Bank_Statement_Line__c(
                    Bank_Statement__c =
                        statement.Id,
                    Line_Number__c =
                        2,
                    Transaction_Date__c =
                        Date.newInstance(2026, 9, 15),
                    Value_Date__c =
                        Date.newInstance(2026, 9, 15),
                    Amount__c =
                        -100,
                    Provider_Line_Id__c =
                        'G5B-WITH',
                    Reference__c =
                        'Supplier payment',
                    Line_Fingerprint__c =
                        'G5B-LINE-WITH'
                )
            };

            createPostedJournal(
                company.Id,
                period.Id,
                bankGL.Id,
                offsetGL.Id,
                Date.newInstance(2026, 9, 10),
                200,
                true,
                'G5B-DEPOSIT-JOURNAL'
            );

            createPostedJournal(
                company.Id,
                period.Id,
                bankGL.Id,
                offsetGL.Id,
                Date.newInstance(2026, 9, 15),
                100,
                false,
                'G5B-WITHDRAWAL-JOURNAL'
            );
        }
    }

    @IsTest
    static void startAndManualMatchMoveReconciliationToReview() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Bank_Statement__c statement =
                getStatement();

            Bank_Statement_Line__c depositLine =
                getStatementLine(
                    'G5B-DEP'
                );

            Journal_Entry_Line__c bankDebitLine =
                getBankLine(
                    'G5B-DEPOSIT-JOURNAL'
                );

            Test.startTest();

            SABBankReconciliationMatchService.ReconciliationResult reconciliation =
                SABBankReconciliationMatchService.startReconciliation(
                    statement.Id
                );

            SABBankReconciliationMatchService.MatchResult result =
                SABBankReconciliationMatchService.createManualMatch(
                    reconciliation.reconciliationId,
                    depositLine.Id,
                    bankDebitLine.Id,
                    200
                );

            Test.stopTest();

            System.assertEquals(
                'Confirmed',
                result.status
            );

            System.assertEquals(
                'Manual',
                result.matchType
            );

            System.assertEquals(
                Decimal.valueOf('0'),
                result.statementRemainingAmount
            );

            System.assertEquals(
                Decimal.valueOf('0'),
                result.journalRemainingAmount
            );

            System.assertEquals(
                'In Review',
                [
                    SELECT Status__c
                    FROM Bank_Reconciliation__c
                    WHERE Id =
                        :reconciliation.reconciliationId
                ].Status__c
            );

            Reconciliation_Match__c stored = [
                SELECT Match_Type__c,
                       Status__c,
                       Matched_Amount__c
                FROM Reconciliation_Match__c
                WHERE Id =
                    :result.matchId
            ];

            System.assertEquals(
                'Confirmed',
                stored.Status__c
            );

            System.assertEquals(
                Decimal.valueOf('200'),
                stored.Matched_Amount__c
            );
        }
    }

    @IsTest
    static void candidatesRespectBankDirectionAndAmount() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Bank_Statement__c statement =
                getStatement();

            Bank_Statement_Line__c depositLine =
                getStatementLine(
                    'G5B-DEP'
                );

            SABBankReconciliationMatchService.ReconciliationResult reconciliation =
                SABBankReconciliationMatchService.startReconciliation(
                    statement.Id
                );

            Test.startTest();

            List<SABBankReconciliationMatchService.MatchCandidate> candidates =
                SABBankReconciliationMatchService.getMatchCandidates(
                    reconciliation.reconciliationId,
                    depositLine.Id,
                    7,
                    50
                );

            Test.stopTest();

            System.assertEquals(
                1,
                candidates.size(),
                'The positive bank line should suggest only the posted bank-debit journal line in the date window.'
            );

            System.assertEquals(
                Decimal.valueOf('200'),
                candidates[0].journalAmount
            );

            System.assertEquals(
                Decimal.valueOf('200'),
                candidates[0].suggestedMatchAmount
            );

            System.assertEquals(
                true,
                candidates[0].exactAmount
            );
        }
    }

    @IsTest
    static void oppositeDirectionIsBlocked() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Bank_Statement__c statement =
                getStatement();

            Bank_Statement_Line__c depositLine =
                getStatementLine(
                    'G5B-DEP'
                );

            Journal_Entry_Line__c bankCreditLine =
                getBankLine(
                    'G5B-WITHDRAWAL-JOURNAL'
                );

            SABBankReconciliationMatchService.ReconciliationResult reconciliation =
                SABBankReconciliationMatchService.startReconciliation(
                    statement.Id
                );

            Boolean blocked =
                false;

            Test.startTest();

            try {
                SABBankReconciliationMatchService.createManualMatch(
                    reconciliation.reconciliationId,
                    depositLine.Id,
                    bankCreditLine.Id,
                    100
                );
            } catch (
                SABBankReconciliationMatchService.BankReconciliationMatchException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'direction'
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
    static void overMatchIsBlocked() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Bank_Statement__c statement =
                getStatement();

            Bank_Statement_Line__c depositLine =
                getStatementLine(
                    'G5B-DEP'
                );

            Journal_Entry_Line__c bankDebitLine =
                getBankLine(
                    'G5B-DEPOSIT-JOURNAL'
                );

            SABBankReconciliationMatchService.ReconciliationResult reconciliation =
                SABBankReconciliationMatchService.startReconciliation(
                    statement.Id
                );

            Boolean blocked =
                false;

            Test.startTest();

            try {
                SABBankReconciliationMatchService.createManualMatch(
                    reconciliation.reconciliationId,
                    depositLine.Id,
                    bankDebitLine.Id,
                    201
                );
            } catch (
                SABBankReconciliationMatchService.BankReconciliationMatchException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'remaining Bank Statement Line amount'
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
    static void suggestedMatchCanBeConfirmedAndReversed() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Bank_Statement__c statement =
                getStatement();

            Bank_Statement_Line__c withdrawalLine =
                getStatementLine(
                    'G5B-WITH'
                );

            Journal_Entry_Line__c bankCreditLine =
                getBankLine(
                    'G5B-WITHDRAWAL-JOURNAL'
                );

            SABBankReconciliationMatchService.ReconciliationResult reconciliation =
                SABBankReconciliationMatchService.startReconciliation(
                    statement.Id
                );

            SABBankReconciliationMatchService.MatchResult proposal =
                SABBankReconciliationMatchService.createSuggestedMatch(
                    reconciliation.reconciliationId,
                    withdrawalLine.Id,
                    bankCreditLine.Id,
                    100
                );

            System.assertEquals(
                'Proposed',
                proposal.status
            );

            Test.startTest();

            SABBankReconciliationMatchService.MatchResult confirmed =
                SABBankReconciliationMatchService.confirmSuggestedMatch(
                    proposal.matchId
                );

            SABBankReconciliationMatchService.MatchResult reversal =
                SABBankReconciliationMatchService.reverseMatch(
                    confirmed.matchId
                );

            Test.stopTest();

            System.assertEquals(
                'Confirmed',
                confirmed.status
            );

            System.assertEquals(
                'Reversed',
                reversal.status
            );

            System.assertEquals(
                Decimal.valueOf('-100'),
                reversal.matchedAmount
            );

            System.assertEquals(
                confirmed.matchId,
                [
                    SELECT Reversal_Of__c
                    FROM Reconciliation_Match__c
                    WHERE Id =
                        :reversal.matchId
                ].Reversal_Of__c
            );
        }
    }

    private static GL_Account__c createGL(
        Id companyId,
        String code,
        String displayName,
        String accountType,
        String normalBalance,
        String companyAccountKey
    ) {
        GL_Account__c row =
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
                    false,
                Control_Type__c =
                    'None',
                Manual_Posting_Allowed__c =
                    true
            );

        insert row;
        return row;
    }

    private static void createPostedJournal(
        Id companyId,
        Id periodId,
        Id bankGLId,
        Id offsetGLId,
        Date accountingDate,
        Decimal amount,
        Boolean bankDebit,
        String postingKey
    ) {
        Journal_Entry__c journal =
            new Journal_Entry__c(
                Company__c =
                    companyId,
                Accounting_Period__c =
                    periodId,
                Accounting_Date__c =
                    accountingDate,
                Entry_Type__c =
                    'Manual',
                Status__c =
                    'Draft',
                Posting_Key__c =
                    postingKey,
                Description__c =
                    postingKey,
                Version__c =
                    1
            );
        insert journal;

        Decimal bankDebitAmount =
            bankDebit
                ? amount
                : 0;

        Decimal bankCreditAmount =
            bankDebit
                ? 0
                : amount;

        Decimal offsetDebitAmount =
            bankDebit
                ? 0
                : amount;

        Decimal offsetCreditAmount =
            bankDebit
                ? amount
                : 0;

        insert new List<Journal_Entry_Line__c>{
            new Journal_Entry_Line__c(
                Journal_Entry__c =
                    journal.Id,
                GL_Account__c =
                    bankGLId,
                Line_Number__c =
                    1,
                Debit_Base__c =
                    bankDebitAmount,
                Credit_Base__c =
                    bankCreditAmount,
                Transaction_Amount__c =
                    amount,
                Transaction_Currency__c =
                    'BDT',
                Functional_Currency__c =
                    'BDT',
                Applied_Exchange_Rate__c =
                    1,
                Source_Line_Key__c =
                    postingKey + '|BANK'
            ),
            new Journal_Entry_Line__c(
                Journal_Entry__c =
                    journal.Id,
                GL_Account__c =
                    offsetGLId,
                Line_Number__c =
                    2,
                Debit_Base__c =
                    offsetDebitAmount,
                Credit_Base__c =
                    offsetCreditAmount,
                Transaction_Amount__c =
                    amount,
                Transaction_Currency__c =
                    'BDT',
                Functional_Currency__c =
                    'BDT',
                Applied_Exchange_Rate__c =
                    1,
                Source_Line_Key__c =
                    postingKey + '|OFFSET'
            )
        };

        SABLedgerMutationContext.beginPosting();

        try {
            journal.Status__c =
                'Posted';
            update journal;
        } finally {
            SABLedgerMutationContext.endPosting();
        }
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
                    'g5brecon',
                Email =
                    'g5brecon.'
                    + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    'G5B Reconciliation User',
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    profileRecord.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    'g5brecon.'
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
                RECONCILE_PERMISSION_SET
            };

        Map<String, Id> idsByName =
            new Map<String, Id>();

        for (PermissionSet row : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN :names
        ]) {
            idsByName.put(
                row.Name,
                row.Id
            );
        }

        System.assertEquals(
            2,
            idsByName.size(),
            'Required G5B permission sets must exist.'
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId =
                    testUser.Id,
                PermissionSetId =
                    idsByName.get(
                        ADMIN_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId =
                    testUser.Id,
                PermissionSetId =
                    idsByName.get(
                        RECONCILE_PERMISSION_SET
                    )
            )
        };
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                'G5B Reconciliation User'
            LIMIT 1
        ];
    }

    private static Bank_Statement__c getStatement() {
        return [
            SELECT Id
            FROM Bank_Statement__c
            WHERE Import_Fingerprint__c =
                'G5B-STATEMENT-001'
            LIMIT 1
        ];
    }

    private static Bank_Statement_Line__c getStatementLine(
        String providerLineId
    ) {
        return [
            SELECT Id
            FROM Bank_Statement_Line__c
            WHERE Provider_Line_Id__c =
                :providerLineId
            LIMIT 1
        ];
    }

    private static Journal_Entry_Line__c getBankLine(
        String postingKey
    ) {
        return [
            SELECT Id
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__r.Posting_Key__c =
                    :postingKey
              AND Source_Line_Key__c LIKE '%|BANK'
            LIMIT 1
        ];
    }
}
