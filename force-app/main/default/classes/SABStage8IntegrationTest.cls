@IsTest
private class SABStage8IntegrationTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    @TestSetup
    static void setupUiUser() {
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

        User u = new User(
            Alias = 'sab8h',
            Email =
                'sab8h.' + seed + '@example.test',
            EmailEncodingKey =
                'UTF-8',
            LastName =
                'SAB Stage 8 Integration User',
            LanguageLocaleKey =
                'en_US',
            LocaleSidKey =
                'en_US',
            ProfileId =
                p.Id,
            TimeZoneSidKey =
                'Asia/Dhaka',
            Username =
                'sab8h.' + seed + '@example.test'
        );

        insert u;

        PermissionSet adminPermissionSet = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = :ADMIN_PERMISSION_SET
            LIMIT 1
        ];

        insert new PermissionSetAssignment(
            AssigneeId =
                u.Id,
            PermissionSetId =
                adminPermissionSet.Id
        );
    }

    @IsTest
    static void allStage8WorkspacesStayCompanyScoped() {
        User uiUser =
            getUiUser();

        Accounting_Company__c companyA =
            makeCompany(
                'H1',
                'Stage 8H Company A'
            );

        Accounting_Company__c companyB =
            makeCompany(
                'H2',
                'Stage 8H Company B'
            );

        grantCompany(
            companyA.Id,
            uiUser.Id,
            '8H-A'
        );

        Accounting_Period__c periodA =
            makePeriod(
                companyA.Id,
                'A1'
            );

        Accounting_Period__c periodB =
            makePeriod(
                companyB.Id,
                'B1'
            );

        GL_Account__c accountA =
            makeAccount(
                companyA.Id,
                '6101'
            );

        GL_Account__c accountB =
            makeAccount(
                companyB.Id,
                '6102'
            );

        insert new Business_Action__c(
            Company__c =
                companyA.Id,
            Source_Type__c =
                'Accounting_Company__c',
            Source_Record_Id__c =
                String.valueOf(
                    companyA.Id
                ),
            Source_Version__c =
                1,
            Action__c =
                'Stage 8H Test',
            Actor__c =
                uiUser.Id,
            Action_At__c =
                System.now(),
            Reason__c =
                'Company A audit row',
            Request_Key__c =
                '8H-AUD-A'
        );

        insert new Business_Action__c(
            Company__c =
                companyB.Id,
            Source_Type__c =
                'Accounting_Company__c',
            Source_Record_Id__c =
                String.valueOf(
                    companyB.Id
                ),
            Source_Version__c =
                1,
            Action__c =
                'Stage 8H Test',
            Actor__c =
                uiUser.Id,
            Action_At__c =
                System.now(),
            Reason__c =
                'Company B audit row',
            Request_Key__c =
                '8H-AUD-B'
        );

        System.runAs(uiUser) {
            Test.startTest();

            List<SABCompanyContextController.CompanyContext>
                companies =
                    SABCompanyContextController.getAccessibleCompanies();

            SABJournalWorkspaceController.WorkspaceDTO
                journalWorkspace =
                    SABJournalWorkspaceController.getWorkspace(
                            companyA.Id
                        );

            SABAccountingPeriodWorkspaceController.WorkspaceDTO
                periodWorkspace =
                    SABAccountingPeriodWorkspaceController.getWorkspace(
                            companyA.Id
                        );

            SABAuditTimelineController.TimelineDTO
                auditWorkspace =
                    SABAuditTimelineController.getTimeline(
                            companyA.Id
                        );

            SABCompanySetupWizardController.SetupStateDTO
                setupWorkspace =
                    SABCompanySetupWizardController.getSetupState(
                            companyA.Id
                        );

            Test.stopTest();

            System.assertEquals(
                1,
                companies.size(),
                'Only the explicitly authorized company should be available in the company selector.'
            );

            System.assertEquals(
                companyA.Id,
                companies[0].companyId
            );

            System.assertEquals(
                1,
                journalWorkspace.periods.size()
            );

            System.assertEquals(
                periodA.Id,
                journalWorkspace.periods[0].value
            );

            System.assertEquals(
                1,
                journalWorkspace.glAccounts.size()
            );

            System.assertEquals(
                accountA.Id,
                journalWorkspace.glAccounts[0].value
            );

            System.assertEquals(
                1,
                periodWorkspace.periods.size()
            );

            System.assertEquals(
                periodA.Id,
                periodWorkspace.periods[0].periodId
            );

            System.assertEquals(
                1,
                auditWorkspace.businessActionCount,
                'Company B audit data must not leak into Company A.'
            );

            System.assertEquals(
                companyA.Id,
                setupWorkspace.companyId
            );

            System.assertEquals(
                1,
                setupWorkspace.periodCount
            );

            System.assertEquals(
                1,
                setupWorkspace.activeGLAccountCount
            );

            System.assertNotEquals(
                periodB.Id,
                journalWorkspace.periods[0].value
            );

            System.assertNotEquals(
                accountB.Id,
                journalWorkspace.glAccounts[0].value
            );
        }
    }

    @IsTest
    static void unauthorizedCompanyIsRejectedAcrossStage8Controllers() {
        User uiUser =
            getUiUser();

        Accounting_Company__c authorizedCompany =
            makeCompany(
                'H3',
                'Stage 8H Authorized'
            );

        Accounting_Company__c blockedCompany =
            makeCompany(
                'H4',
                'Stage 8H Blocked'
            );

        grantCompany(
            authorizedCompany.Id,
            uiUser.Id,
            '8H-AUTH'
        );

        makePeriod(
            blockedCompany.Id,
            'B2'
        );

        makeAccount(
            blockedCompany.Id,
            '6201'
        );

        System.runAs(uiUser) {
            System.assertEquals(
                true,
                failsJournalWorkspace(
                    blockedCompany.Id
                )
            );

            System.assertEquals(
                true,
                failsPeriodWorkspace(
                    blockedCompany.Id
                )
            );

            System.assertEquals(
                true,
                failsAuditWorkspace(
                    blockedCompany.Id
                )
            );

            System.assertEquals(
                true,
                failsSetupWorkspace(
                    blockedCompany.Id
                )
            );
        }
    }

    private static Boolean failsJournalWorkspace(
        Id companyId
    ) {
        try {
            SABJournalWorkspaceController.getWorkspace(
                companyId
            );
            return false;
        } catch (Exception ex) {
            return true;
        }
    }

    private static Boolean failsPeriodWorkspace(
        Id companyId
    ) {
        try {
            SABAccountingPeriodWorkspaceController.getWorkspace(
                companyId
            );
            return false;
        } catch (Exception ex) {
            return true;
        }
    }

    private static Boolean failsAuditWorkspace(
        Id companyId
    ) {
        try {
            SABAuditTimelineController.getTimeline(
                companyId
            );
            return false;
        } catch (Exception ex) {
            return true;
        }
    }

    private static Boolean failsSetupWorkspace(
        Id companyId
    ) {
        try {
            SABCompanySetupWizardController.getSetupState(
                companyId
            );
            return false;
        } catch (Exception ex) {
            return true;
        }
    }

    private static User getUiUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                'SAB Stage 8 Integration User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c makeCompany(
        String keyValue,
        String displayName
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    displayName,
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
                    'In Progress',
                Created_Setup_Version__c =
                    'STAGE-8H',
                Is_Active__c =
                    true
            );

        insert company;
        return company;
    }

    private static void grantCompany(
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

    private static GL_Account__c makeAccount(
        Id companyId,
        String code
    ) {
        GL_Account__c account =
            new GL_Account__c(
                Name =
                    'Stage 8H Account ' + code,
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
                    'Expense',
                Normal_Balance__c =
                    'Debit',
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
