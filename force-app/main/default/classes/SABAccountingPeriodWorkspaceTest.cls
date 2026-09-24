@IsTest
private class SABAccountingPeriodWorkspaceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String CLOSE_PERMISSION_SET =
        'SAB_Close_Period_Action';

    private static final String REOPEN_PERMISSION_SET =
        'SAB_Reopen_Period_Action';

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

        User manager = new User(
            Alias = 'sabperui',
            Email =
                'sabperui.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Period Workspace Manager',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username =
                'sabperui.' + seed + '@example.test'
        );

        User viewer = new User(
            Alias = 'sabpervw',
            Email =
                'sabpervw.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Period Workspace Viewer',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username =
                'sabpervw.' + seed + '@example.test'
        );

        insert new List<User>{
            manager,
            viewer
        };

        Map<String, Id> permissionSets =
            new Map<String, Id>();

        for (PermissionSet ps : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN (
                :ADMIN_PERMISSION_SET,
                :CLOSE_PERMISSION_SET,
                :REOPEN_PERMISSION_SET
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
            'Required SAB period permission sets must exist.'
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = manager.Id,
                PermissionSetId =
                    permissionSets.get(
                        ADMIN_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = manager.Id,
                PermissionSetId =
                    permissionSets.get(
                        CLOSE_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = manager.Id,
                PermissionSetId =
                    permissionSets.get(
                        REOPEN_PERMISSION_SET
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
    static void workspaceListsOnlySelectedCompanyPeriods() {
        User manager =
            getUser('SAB Period Workspace Manager');

        Accounting_Company__c companyA =
            makeCompany(
                'P1',
                'Period UI Company A'
            );

        Accounting_Company__c companyB =
            makeCompany(
                'P2',
                'Period UI Company B'
            );

        grant(
            companyA.Id,
            manager.Id,
            'PER-A'
        );

        makePeriod(
            companyA.Id,
            'A1',
            'Open'
        );

        makePeriod(
            companyB.Id,
            'B1',
            'Open'
        );

        System.runAs(manager) {
            Test.startTest();

            SABAccountingPeriodWorkspaceController.WorkspaceDTO result =
                SABAccountingPeriodWorkspaceController.getWorkspace(
                    companyA.Id
                );

            Test.stopTest();

            System.assertEquals(
                true,
                result.canClosePeriod
            );
            System.assertEquals(
                true,
                result.canReopenPeriod
            );
            System.assertEquals(
                1,
                result.periods.size()
            );
            System.assertEquals(
                companyA.Id,
                result.companyId
            );
        }
    }

    @IsTest
    static void closeAndReopenCreatesVisibleHistory() {
        User manager =
            getUser('SAB Period Workspace Manager');

        Accounting_Company__c company =
            makeCompany(
                'P3',
                'Period UI Company C'
            );

        grant(
            company.Id,
            manager.Id,
            'PER-C'
        );

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'C1',
                'Open'
            );

        System.runAs(manager) {
            Test.startTest();

            SABAccountingPeriodWorkspaceController.PeriodActionDTO closeResult =
                SABAccountingPeriodWorkspaceController.closePeriod(
                    period.Id,
                    'UI-CLOSE-C1',
                    'Month-end close complete'
                );

            SABAccountingPeriodWorkspaceController.PeriodActionDTO reopenResult =
                SABAccountingPeriodWorkspaceController.reopenPeriod(
                    period.Id,
                    'UI-REOPEN-C1',
                    'Backdated correction required'
                );

            SABAccountingPeriodWorkspaceController.PeriodDetailDTO detail =
                SABAccountingPeriodWorkspaceController.getPeriodDetail(
                    period.Id
                );

            Test.stopTest();

            System.assertEquals(
                'Closed',
                closeResult.newStatus
            );
            System.assertEquals(
                'Open',
                reopenResult.newStatus
            );
            System.assertEquals(
                'Open',
                detail.period.status
            );
            System.assertEquals(
                2,
                detail.actions.size()
            );
            System.assertEquals(
                reopenResult.actionId,
                detail.latestActionId
            );
            System.assertEquals(
                'Backdated correction required',
                detail.actions[0].reason
            );
        }
    }

    @IsTest
    static void repeatedCloseRequestReturnsSameAction() {
        User manager =
            getUser('SAB Period Workspace Manager');

        Accounting_Company__c company =
            makeCompany(
                'P4',
                'Period UI Company D'
            );

        grant(
            company.Id,
            manager.Id,
            'PER-D'
        );

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'D1',
                'Open'
            );

        System.runAs(manager) {
            SABAccountingPeriodWorkspaceController.PeriodActionDTO first =
                SABAccountingPeriodWorkspaceController.closePeriod(
                    period.Id,
                    'UI-CLOSE-D1',
                    'Controlled close'
                );

            Test.startTest();

            SABAccountingPeriodWorkspaceController.PeriodActionDTO second =
                SABAccountingPeriodWorkspaceController.closePeriod(
                    period.Id,
                    'UI-CLOSE-D1',
                    'Controlled close'
                );

            Test.stopTest();

            System.assertEquals(
                true,
                second.replay
            );
            System.assertEquals(
                first.actionId,
                second.actionId
            );
        }
    }

    @IsTest
    static void viewerCannotClosePeriod() {
        User viewer =
            getUser('SAB Period Workspace Viewer');

        Accounting_Company__c company =
            makeCompany(
                'P5',
                'Period UI Company E'
            );

        grant(
            company.Id,
            viewer.Id,
            'PER-E'
        );

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'E1',
                'Open'
            );

        System.runAs(viewer) {
            SABAccountingPeriodWorkspaceController.WorkspaceDTO workspace =
                SABAccountingPeriodWorkspaceController.getWorkspace(
                    company.Id
                );

            System.assertEquals(
                false,
                workspace.canClosePeriod
            );
            System.assertEquals(
                false,
                workspace.canReopenPeriod
            );

            Boolean thrown =
                false;

            Test.startTest();

            try {
                SABAccountingPeriodWorkspaceController.closePeriod(
                    period.Id,
                    'UI-CLOSE-E1',
                    'Should be rejected'
                );
            } catch (AuraHandledException ex) {
                thrown =
                    true;
            }

            Test.stopTest();

            System.assertEquals(
                true,
                thrown
            );
        }

        System.assertEquals(
            'Open',
            [
                SELECT Status__c
                FROM Accounting_Period__c
                WHERE Id = :period.Id
            ].Status__c
        );
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
        String suffixValue,
        String statusValue
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
                    statusValue
            );

        if (statusValue == 'Closed') {
            period.Closed_By__c =
                UserInfo.getUserId();
            period.Closed_At__c =
                System.now();
            period.Close_Request_Key__c =
                'INIT-' + suffixValue;
        }

        insert period;
        return period;
    }
}
