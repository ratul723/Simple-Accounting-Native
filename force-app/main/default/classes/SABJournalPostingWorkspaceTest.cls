@IsTest
private class SABJournalPostingWorkspaceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String POST_PERMISSION_SET =
        'SAB_Post_Journal_Action';

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

        User poster = new User(
            Alias = 'sabpost',
            Email = 'sabpost.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Workspace Poster',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = 'sabpost.' + seed + '@example.test'
        );

        User viewer = new User(
            Alias = 'sabview',
            Email = 'sabview.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Workspace Viewer',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = 'sabview.' + seed + '@example.test'
        );

        insert new List<User>{ poster, viewer };

        Map<String, Id> permissionSets =
            new Map<String, Id>();

        for (PermissionSet ps : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN (
                :ADMIN_PERMISSION_SET,
                :POST_PERMISSION_SET
            )
        ]) {
            permissionSets.put(ps.Name, ps.Id);
        }

        System.assertEquals(
            2,
            permissionSets.size(),
            'Required SAB permission sets must exist.'
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = poster.Id,
                PermissionSetId =
                    permissionSets.get(
                        ADMIN_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = poster.Id,
                PermissionSetId =
                    permissionSets.get(
                        POST_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = viewer.Id,
                PermissionSetId =
                    permissionSets.get(
                        ADMIN_PERMISSION_SET
                    )
            )
        };
    }

    @IsTest
    static void balancedDraftValidatesAndPosts() {
        User poster =
            getUser('SAB Workspace Poster');

        Fixture f =
            makeBalancedFixture(
                'C1',
                poster.Id
            );

        System.runAs(poster) {
            Test.startTest();

            SABJournalWorkspaceController.ValidationDTO validation =
                SABJournalWorkspaceController.validateJournal(
                    f.journal.Id
                );

            SABJournalWorkspaceController.PostingDTO posted =
                SABJournalWorkspaceController.postJournal(
                    f.journal.Id
                );

            Test.stopTest();

            System.assertEquals(
                true,
                validation.isValid
            );
            System.assertEquals(
                2,
                validation.lineCount
            );
            System.assertEquals(
                Decimal.valueOf('100'),
                validation.totalDebit
            );
            System.assertEquals(
                Decimal.valueOf('100'),
                validation.totalCredit
            );

            System.assertEquals(
                'Posted',
                posted.status
            );
            System.assertEquals(
                f.journal.Id,
                posted.journalId
            );
            System.assertNotEquals(
                null,
                posted.accountingEventId
            );
            System.assertNotEquals(
                null,
                posted.postingKey
            );
            System.assertEquals(
                false,
                posted.replay
            );
        }

        Journal_Entry__c stored = [
            SELECT Status__c,
                   Posting_Key__c,
                   Accounting_Event__c,
                   Posted_By__c,
                   Posted_At__c
            FROM Journal_Entry__c
            WHERE Id = :f.journal.Id
        ];

        System.assertEquals(
            'Posted',
            stored.Status__c
        );
        System.assertNotEquals(
            null,
            stored.Accounting_Event__c
        );
    }

    @IsTest
    static void repeatedPostReturnsReplay() {
        User poster =
            getUser('SAB Workspace Poster');

        Fixture f =
            makeBalancedFixture(
                'C2',
                poster.Id
            );

        System.runAs(poster) {
            SABJournalWorkspaceController.PostingDTO first =
                SABJournalWorkspaceController.postJournal(
                    f.journal.Id
                );

            Test.startTest();

            SABJournalWorkspaceController.PostingDTO second =
                SABJournalWorkspaceController.postJournal(
                    f.journal.Id
                );

            Test.stopTest();

            System.assertEquals(
                first.postingKey,
                second.postingKey
            );
            System.assertEquals(
                first.accountingEventId,
                second.accountingEventId
            );
            System.assertEquals(
                true,
                second.replay
            );
        }
    }

    @IsTest
    static void invalidDraftReturnsValidationErrors() {
        User poster =
            getUser('SAB Workspace Poster');

        Fixture f =
            makeBalancedFixture(
                'C3',
                poster.Id
            );

        // Keep the record as Draft but make it unbalanced.
        Journal_Entry_Line__c creditLine = [
            SELECT Id, Credit_Base__c
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__c = :f.journal.Id
              AND Credit_Base__c > 0
            LIMIT 1
        ];
        creditLine.Credit_Base__c = 90;
        update creditLine;

        System.runAs(poster) {
            Test.startTest();

            SABJournalWorkspaceController.ValidationDTO validation =
                SABJournalWorkspaceController.validateJournal(
                    f.journal.Id
                );

            Test.stopTest();

            System.assertEquals(
                false,
                validation.isValid
            );
            System.assert(
                String.join(validation.errors, ' ').contains('not balanced')
            );
        }
    }

    @IsTest
    static void userWithoutPostPermissionCannotPost() {
        User viewer =
            getUser('SAB Workspace Viewer');

        Fixture f =
            makeBalancedFixture(
                'C4',
                viewer.Id
            );

        System.runAs(viewer) {
            SABJournalWorkspaceController.WorkspaceDTO workspace =
                SABJournalWorkspaceController.getWorkspace(
                    f.company.Id
                );

            System.assertEquals(
                false,
                workspace.canPostJournal
            );

            Boolean thrown = false;

            Test.startTest();

            try {
                SABJournalWorkspaceController.postJournal(
                    f.journal.Id
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
            'Draft',
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

    private static Fixture makeBalancedFixture(
        String suffixValue,
        Id userId
    ) {
        Fixture f = new Fixture();

        f.company =
            makeCompany(
                suffixValue
            );

        grant(
            f.company.Id,
            userId,
            'GRANT-' + suffixValue
        );

        f.period =
            makePeriod(
                f.company.Id,
                suffixValue
            );

        f.debitAccount =
            makeAccount(
                f.company.Id,
                '6' + suffixValue.right(2) + '0',
                'Expense',
                'Debit'
            );

        f.creditAccount =
            makeAccount(
                f.company.Id,
                '1' + suffixValue.right(2) + '0',
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
                    'Stage 8C ' + suffixValue,
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
                    'Debit'
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
                    'Credit'
            )
        };

        return f;
    }

    private static User getUser(String lastName) {
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
                    'Stage 8C Company ' + suffixValue,
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

    private static void grant(
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
