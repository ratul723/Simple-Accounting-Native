@IsTest
private class SABBankReconFinalizationTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String FINALIZE_PERMISSION_SET =
        'SAB_Finalize_Bank_Reconciliation_Action';

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
                        'G5C Reconciliation Company',
                    Company_Key__c =
                        'BFC',
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
                    'G5C-ACCESS',
                Role__c =
                    'Finance Manager'
            );

            Accounting_Period__c augustPeriod =
                period(
                    company.Id,
                    'August 2026',
                    'BFC-2026-08',
                    '2026-08-BFC',
                    Date.newInstance(2026, 8, 1),
                    Date.newInstance(2026, 8, 31),
                    8
                );
            insert augustPeriod;

            Accounting_Period__c septemberPeriod =
                period(
                    company.Id,
                    'September 2026',
                    'BFC-2026-09',
                    '2026-09-BFC',
                    Date.newInstance(2026, 9, 1),
                    Date.newInstance(2026, 9, 30),
                    9
                );
            insert septemberPeriod;

            GL_Account__c bankGL =
                createGL(
                    company.Id,
                    '1100',
                    'G5C Bank GL',
                    'Asset',
                    'Debit',
                    'BFC-1100'
                );

            GL_Account__c offsetGL =
                createGL(
                    company.Id,
                    '4900',
                    'G5C Offset GL',
                    'Expense',
                    'Debit',
                    'BFC-4900'
                );

            Bank_Account__c bank =
                new Bank_Account__c(
                    Name =
                        'G5C Main BDT Bank',
                    Company__c =
                        company.Id,
                    Bank_Name__c =
                        'G5C Bank',
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
                        'G5C-STATEMENT-001',
                    Statement_Start_Date__c =
                        Date.newInstance(2026, 9, 1),
                    Statement_End_Date__c =
                        Date.newInstance(2026, 9, 30),
                    Status__c =
                        'Validated'
                );
            insert statement;

            List<Bank_Statement_Line__c> statementLines =
                new List<Bank_Statement_Line__c>{
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
                            'G5C-DEP',
                        Reference__c =
                            'Customer receipt',
                        Line_Fingerprint__c =
                            'G5C-LINE-DEP'
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
                            'G5C-WITH',
                        Reference__c =
                            'Supplier payment',
                        Line_Fingerprint__c =
                            'G5C-LINE-WITH'
                    )
                };
            insert statementLines;

            Id openingBankLineId =
                createPostedJournal(
                    company.Id,
                    augustPeriod.Id,
                    bankGL.Id,
                    offsetGL.Id,
                    Date.newInstance(2026, 8, 31),
                    1000,
                    true,
                    'G5C-OPENING'
                );

            Id depositBankLineId =
                createPostedJournal(
                    company.Id,
                    septemberPeriod.Id,
                    bankGL.Id,
                    offsetGL.Id,
                    Date.newInstance(2026, 9, 10),
                    200,
                    true,
                    'G5C-DEPOSIT'
                );

            Id withdrawalBankLineId =
                createPostedJournal(
                    company.Id,
                    septemberPeriod.Id,
                    bankGL.Id,
                    offsetGL.Id,
                    Date.newInstance(2026, 9, 15),
                    100,
                    false,
                    'G5C-WITHDRAWAL'
                );

            System.assertNotEquals(
                null,
                openingBankLineId
            );

            Bank_Reconciliation__c reconciliation =
                new Bank_Reconciliation__c(
                    Company__c =
                        company.Id,
                    Bank_Account__c =
                        bank.Id,
                    Bank_Statement__c =
                        statement.Id,
                    Statement_Closing_Amount__c =
                        1100,
                    Status__c =
                        'In Review'
                );
            insert reconciliation;

            insert new List<Reconciliation_Match__c>{
                new Reconciliation_Match__c(
                    Bank_Reconciliation__c =
                        reconciliation.Id,
                    Bank_Statement_Line__c =
                        statementLines[0].Id,
                    Journal_Entry_Line__c =
                        depositBankLineId,
                    Match_Type__c =
                        'Manual',
                    Matched_Amount__c =
                        200,
                    Status__c =
                        'Confirmed'
                ),
                new Reconciliation_Match__c(
                    Bank_Reconciliation__c =
                        reconciliation.Id,
                    Bank_Statement_Line__c =
                        statementLines[1].Id,
                    Journal_Entry_Line__c =
                        withdrawalBankLineId,
                    Match_Type__c =
                        'Manual',
                    Matched_Amount__c =
                        100,
                    Status__c =
                        'Confirmed'
                )
            };
        }
    }

    @IsTest
    static void successfulFinalizationAndReplay() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Bank_Reconciliation__c reconciliation =
                getReconciliation();

            Test.startTest();

            SABBankReconciliationFinalizationService.FinalizationResult first =
                SABBankReconciliationFinalizationService.finalizeReconciliation(
                    reconciliation.Id
                );

            SABBankReconciliationFinalizationService.FinalizationResult replay =
                SABBankReconciliationFinalizationService.finalizeReconciliation(
                    reconciliation.Id
                );

            Test.stopTest();

            System.assertEquals(
                'Finalized',
                first.reconciliationStatus
            );

            System.assertEquals(
                'Reconciled',
                first.statementStatus
            );

            System.assertEquals(
                Decimal.valueOf('1100.0000'),
                first.bookClosingAmount
            );

            System.assertEquals(
                Decimal.valueOf('1100.0000'),
                first.statementClosingAmount
            );

            System.assertEquals(
                Decimal.valueOf('0.0000'),
                first.difference
            );

            System.assertEquals(
                testUser.Id,
                first.approvedById
            );

            System.assertNotEquals(
                null,
                first.approvedAt
            );

            System.assertEquals(
                2,
                first.statementLineCount
            );

            System.assertEquals(
                2,
                first.confirmedMatchCount
            );

            System.assertEquals(
                true,
                replay.replay
            );

            Bank_Reconciliation__c stored = [
                SELECT Status__c,
                       Book_Closing_Amount__c,
                       Statement_Closing_Amount__c,
                       Difference__c,
                       Approved_By__c,
                       Approved_At__c,
                       Bank_Statement__r.Status__c
                FROM Bank_Reconciliation__c
                WHERE Id =
                    :reconciliation.Id
            ];

            System.assertEquals(
                'Finalized',
                stored.Status__c
            );

            System.assertEquals(
                'Reconciled',
                stored.Bank_Statement__r.Status__c
            );
        }
    }

    @IsTest
    static void unmatchedStatementLineBlocksFinalization() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Bank_Reconciliation__c reconciliation =
                getReconciliation();

            Reconciliation_Match__c matchRow = [
                SELECT Id,
                       Status__c
                FROM Reconciliation_Match__c
                WHERE Bank_Reconciliation__c =
                        :reconciliation.Id
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];

            matchRow.Status__c =
                'Reversed';
            update matchRow;

            Boolean blocked =
                false;

            Test.startTest();

            try {
                SABBankReconciliationFinalizationService.finalizeReconciliation(
                    reconciliation.Id
                );
            } catch (
                SABBankReconciliationFinalizationService.BankReconciliationFinalizationException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'fully matched'
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
    static void proposedMatchBlocksFinalization() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Bank_Reconciliation__c reconciliation =
                getReconciliation();

            Reconciliation_Match__c matchRow = [
                SELECT Id,
                       Status__c
                FROM Reconciliation_Match__c
                WHERE Bank_Reconciliation__c =
                        :reconciliation.Id
                ORDER BY CreatedDate ASC
                LIMIT 1
            ];

            matchRow.Status__c =
                'Proposed';
            update matchRow;

            Boolean blocked =
                false;

            Test.startTest();

            try {
                SABBankReconciliationFinalizationService.finalizeReconciliation(
                    reconciliation.Id
                );
            } catch (
                SABBankReconciliationFinalizationService.BankReconciliationFinalizationException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'Proposed'
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
    static void nonZeroBookDifferenceBlocksFinalization() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Bank_Reconciliation__c reconciliation =
                getReconciliation();

            Bank_Statement__c statement = [
                SELECT Id,
                       Closing_Amount__c
                FROM Bank_Statement__c
                WHERE Id =
                    :reconciliation.Bank_Statement__c
            ];

            statement.Closing_Amount__c =
                1090;
            update statement;

            Boolean blocked =
                false;

            Test.startTest();

            try {
                SABBankReconciliationFinalizationService.finalizeReconciliation(
                    reconciliation.Id
                );
            } catch (
                SABBankReconciliationFinalizationService.BankReconciliationFinalizationException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'Difference'
                    );
            }

            Test.stopTest();

            System.assertEquals(
                true,
                blocked
            );

            Bank_Reconciliation__c afterAttempt = [
                SELECT Status__c,
                       Approved_By__c,
                       Approved_At__c
                FROM Bank_Reconciliation__c
                WHERE Id =
                    :reconciliation.Id
            ];

            System.assertEquals(
                'In Review',
                afterAttempt.Status__c
            );

            System.assertEquals(
                null,
                afterAttempt.Approved_By__c
            );

            System.assertEquals(
                null,
                afterAttempt.Approved_At__c
            );
        }
    }

    private static Accounting_Period__c period(
        Id companyId,
        String nameValue,
        String companyPeriodKey,
        String periodKey,
        Date startDate,
        Date endDate,
        Integer periodNumber
    ) {
        return new Accounting_Period__c(
            Name =
                nameValue,
            Company__c =
                companyId,
            Company_Period_Key__c =
                companyPeriodKey,
            Period_Key__c =
                periodKey,
            Start_Date__c =
                startDate,
            End_Date__c =
                endDate,
            Fiscal_Year__c =
                2026,
            Fiscal_Quarter__c =
                periodNumber <= 3
                    ? 1
                    : (
                        periodNumber <= 6
                            ? 2
                            : (
                                periodNumber <= 9
                                    ? 3
                                    : 4
                            )
                    ),
            Period_Number__c =
                periodNumber,
            Status__c =
                'Open'
        );
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

    private static Id createPostedJournal(
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

        Journal_Entry_Line__c bankLine =
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
            );

        Journal_Entry_Line__c offsetLine =
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
            );

        insert new List<Journal_Entry_Line__c>{
            bankLine,
            offsetLine
        };

        SABLedgerMutationContext.beginPosting();

        try {
            journal.Status__c =
                'Posted';
            update journal;
        } finally {
            SABLedgerMutationContext.endPosting();
        }

        return bankLine.Id;
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
                    'g5cfin',
                Email =
                    'g5cfin.'
                    + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    'G5C Finalization User',
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    profileRecord.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    'g5cfin.'
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
                FINALIZE_PERMISSION_SET
            };

        Map<String, Id> idsByName =
            new Map<String, Id>();

        for (PermissionSet row : [
            SELECT Id,
                   Name
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
            'Required G5C permission sets must exist.'
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
                        FINALIZE_PERMISSION_SET
                    )
            )
        };
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                'G5C Finalization User'
            LIMIT 1
        ];
    }

    private static Bank_Reconciliation__c getReconciliation() {
        return [
            SELECT Id,
                   Bank_Statement__c
            FROM Bank_Reconciliation__c
            WHERE Bank_Statement__r.Import_Fingerprint__c =
                'G5C-STATEMENT-001'
            LIMIT 1
        ];
    }
}
