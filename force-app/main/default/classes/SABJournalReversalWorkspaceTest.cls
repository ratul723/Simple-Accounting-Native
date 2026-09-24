@IsTest
private class SABJournalReversalWorkspaceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String POST_PERMISSION_SET =
        'SAB_Post_Journal_Action';

    private static final String REVERSE_PERMISSION_SET =
        'SAB_Reverse_Journal_Action';

    @TestSetup
    static void setupUsers() {
        Profile p = [
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

        User reverser = new User(
            Alias = 'sabrevui',
            Email = 'sabrevui.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Workspace Reverser',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = 'sabrevui.' + seed + '@example.test'
        );

        User posterOnly = new User(
            Alias = 'sabponly',
            Email = 'sabponly.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Workspace Poster Only',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = 'sabponly.' + seed + '@example.test'
        );

        insert new List<User>{
            reverser,
            posterOnly
        };

        Map<String, Id> permissionSets =
            new Map<String, Id>();

        for (PermissionSet ps : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN (
                :ADMIN_PERMISSION_SET,
                :POST_PERMISSION_SET,
                :REVERSE_PERMISSION_SET
            )
        ]) {
            permissionSets.put(
                ps.Name,
                ps.Id
            );
        }

        System.assertEquals(
            3,
            permissionSets.size(),
            'Required SAB permission sets must exist.'
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = reverser.Id,
                PermissionSetId =
                    permissionSets.get(
                        ADMIN_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = reverser.Id,
                PermissionSetId =
                    permissionSets.get(
                        POST_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = reverser.Id,
                PermissionSetId =
                    permissionSets.get(
                        REVERSE_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = posterOnly.Id,
                PermissionSetId =
                    permissionSets.get(
                        ADMIN_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = posterOnly.Id,
                PermissionSetId =
                    permissionSets.get(
                        POST_PERMISSION_SET
                    )
            )
        };
    }

    @IsTest
    static void postedJournalAppearsAndCanBeReversed() {
        User u =
            getUser('SAB Workspace Reverser');

        Fixture f =
            makePostedFixture(
                'R1',
                u.Id
            );

        System.runAs(u) {
            SABJournalWorkspaceController.WorkspaceDTO workspace =
                SABJournalWorkspaceController.getWorkspace(
                    f.company.Id
                );

            System.assertEquals(
                true,
                workspace.canReverseJournal
            );
            System.assertEquals(
                1,
                workspace.postedJournals.size()
            );
            System.assertEquals(
                f.journal.Id,
                workspace.postedJournals[0].journalId
            );

            Test.startTest();

            SABJournalWorkspaceController.ReversalDTO result =
                SABJournalWorkspaceController.reverseJournal(
                    f.journal.Id,
                    f.period.Id,
                    Date.today(),
                    'Correcting the original journal'
                );

            Test.stopTest();

            System.assertEquals(
                'Reversed',
                result.originalStatus
            );
            System.assertEquals(
                false,
                result.replay
            );
            System.assertNotEquals(
                null,
                result.reversalJournalId
            );
            System.assertNotEquals(
                null,
                result.reversalAccountingEventId
            );
        }

        Journal_Entry__c original = [
            SELECT Status__c,
                   Reversal_Journal__c
            FROM Journal_Entry__c
            WHERE Id = :f.journal.Id
        ];

        System.assertEquals(
            'Reversed',
            original.Status__c
        );
        System.assertNotEquals(
            null,
            original.Reversal_Journal__c
        );

        Journal_Entry__c reversal = [
            SELECT Status__c,
                   Reversal_Of__c,
                   Accounting_Event__c
            FROM Journal_Entry__c
            WHERE Id = :original.Reversal_Journal__c
        ];

        System.assertEquals(
            'Posted',
            reversal.Status__c
        );
        System.assertEquals(
            f.journal.Id,
            reversal.Reversal_Of__c
        );
        System.assertNotEquals(
            null,
            reversal.Accounting_Event__c
        );

        List<Journal_Entry_Line__c> reversalLines = [
            SELECT Debit_Base__c,
                   Credit_Base__c
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__c = :reversal.Id
            ORDER BY Line_Number__c
        ];

        System.assertEquals(
            2,
            reversalLines.size()
        );
        System.assertEquals(
            Decimal.valueOf('0'),
            reversalLines[0].Debit_Base__c
        );
        System.assertEquals(
            Decimal.valueOf('100'),
            reversalLines[0].Credit_Base__c
        );
        System.assertEquals(
            Decimal.valueOf('100'),
            reversalLines[1].Debit_Base__c
        );
        System.assertEquals(
            Decimal.valueOf('0'),
            reversalLines[1].Credit_Base__c
        );
    }

    @IsTest
    static void repeatedReversalReturnsOriginalResult() {
        User u =
            getUser('SAB Workspace Reverser');

        Fixture f =
            makePostedFixture(
                'R2',
                u.Id
            );

        System.runAs(u) {
            SABJournalWorkspaceController.ReversalDTO first =
                SABJournalWorkspaceController.reverseJournal(
                    f.journal.Id,
                    f.period.Id,
                    Date.today(),
                    'Correction'
                );

            Test.startTest();

            SABJournalWorkspaceController.ReversalDTO second =
                SABJournalWorkspaceController.reverseJournal(
                    f.journal.Id,
                    f.period.Id,
                    Date.today(),
                    'Correction'
                );

            Test.stopTest();

            System.assertEquals(
                true,
                second.replay
            );
            System.assertEquals(
                first.reversalJournalId,
                second.reversalJournalId
            );
            System.assertEquals(
                first.reversalAccountingEventId,
                second.reversalAccountingEventId
            );
            System.assertEquals(
                first.reversalPostingKey,
                second.reversalPostingKey
            );
        }
    }

    @IsTest
    static void reasonIsRequiredByWorkspace() {
        User u =
            getUser('SAB Workspace Reverser');

        Fixture f =
            makePostedFixture(
                'R3',
                u.Id
            );

        System.runAs(u) {
            Boolean thrown = false;

            Test.startTest();

            try {
                SABJournalWorkspaceController.reverseJournal(
                    f.journal.Id,
                    f.period.Id,
                    Date.today(),
                    ' '
                );
            } catch (AuraHandledException ex) {
                thrown = true;
            }

            Test.stopTest();

            System.assertEquals(
                true,
                thrown
            );
        }

        System.assertEquals(
            'Posted',
            [
                SELECT Status__c
                FROM Journal_Entry__c
                WHERE Id = :f.journal.Id
            ].Status__c
        );
    }

    @IsTest
    static void userWithoutReversePermissionCannotReverse() {
        User u =
            getUser('SAB Workspace Poster Only');

        Fixture f =
            makePostedFixture(
                'R4',
                u.Id
            );

        System.runAs(u) {
            SABJournalWorkspaceController.WorkspaceDTO workspace =
                SABJournalWorkspaceController.getWorkspace(
                    f.company.Id
                );

            System.assertEquals(
                false,
                workspace.canReverseJournal
            );

            Boolean thrown = false;

            Test.startTest();

            try {
                SABJournalWorkspaceController.reverseJournal(
                    f.journal.Id,
                    f.period.Id,
                    Date.today(),
                    'Should be blocked'
                );
            } catch (AuraHandledException ex) {
                thrown = true;
            }

            Test.stopTest();

            System.assertEquals(
                true,
                thrown
            );
        }

        System.assertEquals(
            'Posted',
            [
                SELECT Status__c
                FROM Journal_Entry__c
                WHERE Id = :f.journal.Id
            ].Status__c
        );
    }

    private class Fixture {
        Accounting_Company__c company;
        Accounting_Period__c period;
        GL_Account__c debitAccount;
        GL_Account__c creditAccount;
        Journal_Entry__c journal;
    }

    private static Fixture makePostedFixture(
        String suffixValue,
        Id userId
    ) {
        Fixture f = new Fixture();

        f.company =
            makeCompany(
                suffixValue
            );

        grantCompanyAccess(
            f.company.Id,
            userId,
            'REV-' + suffixValue
        );

        f.period =
            makePeriod(
                f.company.Id,
                suffixValue
            );

        f.debitAccount =
            makeAccount(
                f.company.Id,
                '61' + suffixValue.right(1),
                'Expense',
                'Debit'
            );

        f.creditAccount =
            makeAccount(
                f.company.Id,
                '11' + suffixValue.right(1),
                'Asset',
                'Debit'
            );

        f.journal =
            new Journal_Entry__c(
                Company__c =
                    f.company.Id,
                Accounting_Period__c =
                    f.period.Id,
                Accounting_Date__c =
                    Date.today(),
                Entry_Type__c =
                    'Manual',
                Status__c =
                    'Draft',
                Description__c =
                    'Stage 8D ' + suffixValue,
                Version__c =
                    1
            );

        insert f.journal;

        insert new List<Journal_Entry_Line__c>{
            new Journal_Entry_Line__c(
                Journal_Entry__c =
                    f.journal.Id,
                GL_Account__c =
                    f.debitAccount.Id,
                Line_Number__c =
                    1,
                Debit_Base__c =
                    100,
                Credit_Base__c =
                    0,
                Functional_Currency__c =
                    'BDT',
                Explanation__c =
                    'Original debit'
            ),
            new Journal_Entry_Line__c(
                Journal_Entry__c =
                    f.journal.Id,
                GL_Account__c =
                    f.creditAccount.Id,
                Line_Number__c =
                    2,
                Debit_Base__c =
                    0,
                Credit_Base__c =
                    100,
                Functional_Currency__c =
                    'BDT',
                Explanation__c =
                    'Original credit'
            )
        };

        User u = [
            SELECT Id
            FROM User
            WHERE Id = :userId
        ];

        System.runAs(u) {
            SABJournalWorkspaceController.postJournal(
                f.journal.Id
            );
        }

        return f;
    }

    private static User getUser(
        String lastName
    ) {
        return [
            SELECT Id
            FROM User
            WHERE LastName = :lastName
            LIMIT 1
        ];
    }

    private static Accounting_Company__c makeCompany(
        String suffixValue
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    'Stage 8D Company ' + suffixValue,
                Company_Key__c =
                    suffixValue,
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

    private static void grantCompanyAccess(
        Id companyId,
        Id userId,
        String grantKey
    ) {
        insert new Company_User_Access__c(
            Company__c =
                companyId,
            User__c =
                userId,
            Effective_From__c =
                Date.today(),
            Grant_Key__c =
                grantKey,
            Is_Active__c =
                true,
            Role__c =
                'Finance Manager'
        );
    }

    private static Accounting_Period__c makePeriod(
        Id companyId,
        String suffixValue
    ) {
        Accounting_Period__c period =
            new Accounting_Period__c(
                Name =
                    'Period ' + suffixValue,
                Company__c =
                    companyId,
                Company_Period_Key__c =
                    'CP-' + suffixValue,
                Period_Key__c =
                    'P-' + suffixValue,
                Start_Date__c =
                    Date.today().toStartOfMonth(),
                End_Date__c =
                    Date.today().toStartOfMonth().addMonths(1).addDays(-1),
                Fiscal_Year__c =
                    Date.today().year(),
                Fiscal_Quarter__c =
                    1,
                Period_Number__c =
                    Date.today().month(),
                Status__c =
                    'Open'
            );

        insert period;
        return period;
    }

    private static GL_Account__c makeAccount(
        Id companyId,
        String code,
        String accountType,
        String normalBalance
    ) {
        GL_Account__c account =
            new GL_Account__c(
                Name =
                    'Account ' + code,
                Company__c =
                    companyId,
                Company_Account_Key__c =
                    String.valueOf(companyId)
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
                    false,
                Control_Type__c =
                    'None',
                Manual_Posting_Allowed__c =
                    true
            );

        insert account;
        return account;
    }
}
