@IsTest
private class SABBankReconWorkspaceControllerTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Remaining_Fields_Admin',
            'SAB_Bank_Reconciliation_Workspace_User',
            'SAB_Import_Bank_Statement_Action',
            'SAB_Reconcile_Bank_Action',
            'SAB_Finalize_Bank_Reconciliation_Action'
        };

    @TestSetup
    static void setupFixture() {
        User testUser = createUser();
        assignPermissionSets(testUser);

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c = 'G5D Workspace Company',
                    Company_Key__c = 'BWD',
                    Country_Code__c = 'BD',
                    Functional_Currency__c = 'BDT',
                    Fiscal_Calendar_Type__c = 'Calendar',
                    Fiscal_Year_Start_Month__c = 1,
                    Setup_Status__c = 'Active',
                    Is_Active__c = true
                );
            insert company;

            insert new Company_User_Access__c(
                Company__c = company.Id,
                User__c = testUser.Id,
                Is_Active__c = true,
                Effective_From__c = Date.today(),
                Grant_Key__c = 'G5D-ACCESS',
                Role__c = 'Finance Manager'
            );

            Accounting_Period__c period =
                new Accounting_Period__c(
                    Name = 'September 2026',
                    Company__c = company.Id,
                    Company_Period_Key__c = 'BWD-2026-09',
                    Period_Key__c = '2026-09-BWD',
                    Start_Date__c = Date.newInstance(2026, 9, 1),
                    End_Date__c = Date.newInstance(2026, 9, 30),
                    Fiscal_Year__c = 2026,
                    Fiscal_Quarter__c = 3,
                    Period_Number__c = 9,
                    Status__c = 'Open'
                );
            insert period;

            GL_Account__c bankGL =
                createGL(
                    company.Id,
                    '1100',
                    'G5D Bank GL',
                    'Asset',
                    'Debit',
                    'BWD-1100'
                );

            GL_Account__c offsetGL =
                createGL(
                    company.Id,
                    '4900',
                    'G5D Offset GL',
                    'Expense',
                    'Debit',
                    'BWD-4900'
                );

            Bank_Account__c bank =
                new Bank_Account__c(
                    Name = 'G5D Main Bank',
                    Company__c = company.Id,
                    Bank_Name__c = 'G5D Bank',
                    Masked_Account_Number__c = '****1234',
                    Currency__c = 'BDT',
                    GL_Account__c = bankGL.Id,
                    Is_Active__c = true
                );
            insert bank;

            Bank_Statement__c statement =
                new Bank_Statement__c(
                    Company__c = company.Id,
                    Bank_Account__c = bank.Id,
                    Opening_Amount__c = 0,
                    Closing_Amount__c = 150,
                    Currency__c = 'BDT',
                    Import_Fingerprint__c = 'G5D-STATEMENT-001',
                    Statement_Start_Date__c = Date.newInstance(2026, 9, 1),
                    Statement_End_Date__c = Date.newInstance(2026, 9, 30),
                    Status__c = 'Validated'
                );
            insert statement;

            Bank_Statement_Line__c statementLine =
                new Bank_Statement_Line__c(
                    Bank_Statement__c = statement.Id,
                    Line_Number__c = 1,
                    Transaction_Date__c = Date.newInstance(2026, 9, 10),
                    Value_Date__c = Date.newInstance(2026, 9, 10),
                    Amount__c = 150,
                    Provider_Line_Id__c = 'G5D-LINE-1',
                    Reference__c = 'Receipt',
                    Line_Fingerprint__c = 'G5D-LINE-FP-1'
                );
            insert statementLine;

            Id bankLineId =
                createPostedJournal(
                    company.Id,
                    period.Id,
                    bankGL.Id,
                    offsetGL.Id
                );

            Bank_Reconciliation__c reconciliation =
                new Bank_Reconciliation__c(
                    Company__c = company.Id,
                    Bank_Account__c = bank.Id,
                    Bank_Statement__c = statement.Id,
                    Statement_Closing_Amount__c = 150,
                    Status__c = 'In Review'
                );
            insert reconciliation;

            insert new Reconciliation_Match__c(
                Bank_Reconciliation__c = reconciliation.Id,
                Bank_Statement_Line__c = statementLine.Id,
                Journal_Entry_Line__c = bankLineId,
                Match_Type__c = 'Manual',
                Matched_Amount__c = 150,
                Status__c = 'Confirmed'
            );
        }
    }

    @IsTest
    static void dashboardAndStatementWorkspaceExposeUnifiedState() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Company__c company = getCompany();

            Bank_Statement__c statement = [
                SELECT Id
                FROM Bank_Statement__c
                WHERE Import_Fingerprint__c = 'G5D-STATEMENT-001'
                LIMIT 1
            ];

            Test.startTest();

            SABBankReconciliationWorkspaceController.DashboardDTO dashboard =
                SABBankReconciliationWorkspaceController.getDashboard(
                    company.Id
                );

            SABBankReconciliationWorkspaceController.StatementWorkspaceDTO workspace =
                SABBankReconciliationWorkspaceController.getStatementWorkspace(
                    statement.Id
                );

            Test.stopTest();

            System.assertEquals(1, dashboard.bankAccountCount);
            System.assertEquals(1, dashboard.statementCount);
            System.assertEquals(true, dashboard.canImport);
            System.assertEquals(true, dashboard.canReconcile);
            System.assertEquals(true, dashboard.canFinalize);
            System.assertEquals(
                Decimal.valueOf('150.0000'),
                dashboard.functionalCurrencyBookCash
            );
            System.assertEquals(1, workspace.lineCount);
            System.assertEquals(1, workspace.fullyMatchedLineCount);
            System.assertEquals(1, workspace.confirmedMatchCount);
            System.assertEquals(false, workspace.hasProposedMatches);
            System.assertEquals(
                Decimal.valueOf('150.0000'),
                workspace.provisionalBookClosingAmount
            );
            System.assertEquals(
                Decimal.valueOf('0.0000'),
                workspace.provisionalDifference
            );
            System.assertEquals(true, workspace.canFinalizeNow);
        }
    }

    @IsTest
    static void finalizationWrapperCompletesWorkspaceLifecycle() {
        User testUser = getUser();

        System.runAs(testUser) {
            Bank_Reconciliation__c reconciliation = [
                SELECT Id
                FROM Bank_Reconciliation__c
                WHERE Bank_Statement__r.Import_Fingerprint__c =
                    'G5D-STATEMENT-001'
                LIMIT 1
            ];

            Test.startTest();

            SABBankReconciliationWorkspaceController.ActionResultDTO result =
                SABBankReconciliationWorkspaceController.finalizeReconciliation(
                    reconciliation.Id
                );

            Test.stopTest();

            System.assertEquals('Finalized', result.status);

            Bank_Reconciliation__c stored = [
                SELECT Status__c,
                       Bank_Statement__r.Status__c
                FROM Bank_Reconciliation__c
                WHERE Id = :reconciliation.Id
            ];

            System.assertEquals('Finalized', stored.Status__c);
            System.assertEquals(
                'Reconciled',
                stored.Bank_Statement__r.Status__c
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
                Name = displayName,
                Company__c = companyId,
                Company_Account_Key__c = companyAccountKey,
                Account_Code__c = code,
                Account_Type__c = accountType,
                Normal_Balance__c = normalBalance,
                Is_Active__c = true,
                Is_Control_Account__c = false,
                Control_Type__c = 'None',
                Manual_Posting_Allowed__c = true
            );

        insert row;
        return row;
    }

    private static Id createPostedJournal(
        Id companyId,
        Id periodId,
        Id bankGLId,
        Id offsetGLId
    ) {
        Journal_Entry__c journal =
            new Journal_Entry__c(
                Company__c = companyId,
                Accounting_Period__c = periodId,
                Accounting_Date__c = Date.newInstance(2026, 9, 10),
                Entry_Type__c = 'Manual',
                Status__c = 'Draft',
                Posting_Key__c = 'G5D-POSTED-JOURNAL',
                Description__c = 'G5D posted bank movement',
                Version__c = 1
            );
        insert journal;

        Journal_Entry_Line__c bankLine =
            new Journal_Entry_Line__c(
                Journal_Entry__c = journal.Id,
                GL_Account__c = bankGLId,
                Line_Number__c = 1,
                Debit_Base__c = 150,
                Credit_Base__c = 0,
                Transaction_Amount__c = 150,
                Transaction_Currency__c = 'BDT',
                Functional_Currency__c = 'BDT',
                Applied_Exchange_Rate__c = 1,
                Source_Line_Key__c = 'G5D-POSTED-JOURNAL|BANK'
            );

        Journal_Entry_Line__c offsetLine =
            new Journal_Entry_Line__c(
                Journal_Entry__c = journal.Id,
                GL_Account__c = offsetGLId,
                Line_Number__c = 2,
                Debit_Base__c = 0,
                Credit_Base__c = 150,
                Transaction_Amount__c = 150,
                Transaction_Currency__c = 'BDT',
                Functional_Currency__c = 'BDT',
                Applied_Exchange_Rate__c = 1,
                Source_Line_Key__c = 'G5D-POSTED-JOURNAL|OFFSET'
            );

        insert new List<Journal_Entry_Line__c>{
            bankLine,
            offsetLine
        };

        SABLedgerMutationContext.beginPosting();

        try {
            journal.Status__c = 'Posted';
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
                Alias = 'g5dwrk',
                Email = 'g5dwrk.' + seed + '@example.test',
                EmailEncodingKey = 'UTF-8',
                LastName = 'G5D Workspace User',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = profileRecord.Id,
                TimeZoneSidKey = 'Asia/Dhaka',
                Username = 'g5dwrk.' + seed + '@example.test'
            );

        insert testUser;
        return testUser;
    }

    private static void assignPermissionSets(
        User testUser
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
            'All G5D dependency permission sets must exist.'
        );

        List<PermissionSetAssignment> assignments =
            new List<PermissionSetAssignment>();

        for (String nameValue : REQUIRED_PERMISSION_SETS) {
            assignments.add(
                new PermissionSetAssignment(
                    AssigneeId = testUser.Id,
                    PermissionSetId =
                        idsByName.get(nameValue)
                )
            );
        }

        insert assignments;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'G5D Workspace User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getCompany() {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c = 'BWD'
            LIMIT 1
        ];
    }
}
