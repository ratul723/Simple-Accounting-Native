@IsTest
private class SABPeriodServiceTest {

    @TestSetup
    static void setupPeriodUser() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String uniqueValue =
            'sabperiod.'
            + String.valueOf(DateTime.now().getTime());

        User periodUser = new User(
            Alias = 'sabper',
            Email = uniqueValue + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Period User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = uniqueValue + '@example.test'
        );

        insert periodUser;

        Map<String, Id> permissionSetIds =
            new Map<String, Id>();

        for (PermissionSet ps : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN (
                'SAB_Remaining_Fields_Admin',
                'SAB_Close_Period_Action',
                'SAB_Reopen_Period_Action'
            )
        ]) {
            permissionSetIds.put(ps.Name, ps.Id);
        }

        System.assertEquals(
            3,
            permissionSetIds.size(),
            'Required SAB period permission sets must be deployed.'
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = periodUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        'SAB_Remaining_Fields_Admin'
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = periodUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        'SAB_Close_Period_Action'
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = periodUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        'SAB_Reopen_Period_Action'
                    )
            )
        };
    }

    private static User periodUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB Period User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c makeCompany(
        String keyValue,
        String displayName
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c = displayName,
                Company_Key__c = keyValue,
                Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT',
                Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active',
                Is_Active__c = true
            );

        insert company;
        return company;
    }

    private static Accounting_Period__c makePeriod(
        Id companyId,
        String suffixValue,
        String statusValue
    ) {
        Accounting_Period__c period =
            new Accounting_Period__c(
                Name = 'Period ' + suffixValue,
                Company__c = companyId,
                Company_Period_Key__c =
                    'CP-' + suffixValue,
                Period_Key__c =
                    'P-' + suffixValue,
                Start_Date__c =
                    Date.newInstance(2026, 9, 1),
                End_Date__c =
                    Date.newInstance(2026, 9, 30),
                Fiscal_Year__c = 2026,
                Fiscal_Quarter__c = 3,
                Period_Number__c = 9,
                Status__c = statusValue
            );

        if (statusValue == 'Closed') {
            period.Closed_By__c =
                UserInfo.getUserId();
            period.Closed_At__c =
                System.now();
            period.Close_Request_Key__c =
                'INITIAL-CLOSE-' + suffixValue;
        }

        insert period;
        return period;
    }

    private static void grantCompanyAccess(
        Id companyId,
        Id userId,
        String grantKey
    ) {
        insert new Company_User_Access__c(
            Company__c = companyId,
            User__c = userId,
            Effective_From__c = Date.today(),
            Effective_To__c = null,
            Grant_Key__c = grantKey,
            Is_Active__c = true,
            Role__c = 'Finance Manager'
        );
    }

    private static SABPeriodService.PeriodActionRequest
        actionRequest(
            Id periodId,
            String requestKey,
            String reason
        ) {

        SABPeriodService.PeriodActionRequest request =
            new SABPeriodService.PeriodActionRequest();

        request.periodId = periodId;
        request.requestKey = requestKey;
        request.reason = reason;

        return request;
    }

    @IsTest
    static void closeOpenPeriodCreatesImmutableAction() {
        User u = periodUser();

        Accounting_Company__c company =
            makeCompany('PD1', 'Period Company One');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'PD1',
                'Open'
            );

        grantCompanyAccess(
            company.Id,
            u.Id,
            'PERIOD-GRANT-1'
        );

        SABPeriodService.PeriodActionResult result;

        System.runAs(u) {
            Test.startTest();

            result = SABPeriodService.closePeriod(
                actionRequest(
                    period.Id,
                    'CLOSE-PD1',
                    'Month-end close complete'
                )
            );

            Test.stopTest();
        }

        System.assertEquals(false, result.replay);
        System.assertEquals('Open', result.previousStatus);
        System.assertEquals('Closed', result.newStatus);
        System.assertEquals('Closed', result.currentPeriodStatus);

        Accounting_Period__c storedPeriod = [
            SELECT Status__c,
                   Closed_By__c,
                   Closed_At__c,
                   Close_Request_Key__c
            FROM Accounting_Period__c
            WHERE Id = :period.Id
        ];

        System.assertEquals(
            'Closed',
            storedPeriod.Status__c
        );
        System.assertEquals(
            u.Id,
            storedPeriod.Closed_By__c
        );
        System.assertNotEquals(
            null,
            storedPeriod.Closed_At__c
        );
        System.assertEquals(
            'CLOSE-PD1',
            storedPeriod.Close_Request_Key__c
        );

        Accounting_Period_Action__c actionRecord = [
            SELECT Period__c,
                   Previous_Status__c,
                   New_Status__c,
                   Performed_By__c,
                   Performed_At__c,
                   Reason__c,
                   Request_Key__c
            FROM Accounting_Period_Action__c
            WHERE Id = :result.actionId
        ];

        System.assertEquals(period.Id, actionRecord.Period__c);
        System.assertEquals(
            'Open',
            actionRecord.Previous_Status__c
        );
        System.assertEquals(
            'Closed',
            actionRecord.New_Status__c
        );
        System.assertEquals(
            u.Id,
            actionRecord.Performed_By__c
        );
        System.assertEquals(
            'Month-end close complete',
            actionRecord.Reason__c
        );

        actionRecord.Reason__c = 'Changed after close';

        Database.SaveResult updateResult =
            Database.update(actionRecord, false);

        System.assertEquals(
            false,
            updateResult.isSuccess()
        );

        Database.DeleteResult deleteResult =
            Database.delete(actionRecord, false);

        System.assertEquals(
            false,
            deleteResult.isSuccess()
        );
    }

    @IsTest
    static void repeatedCloseRequestReturnsSameAction() {
        User u = periodUser();

        Accounting_Company__c company =
            makeCompany('PD2', 'Period Company Two');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'PD2',
                'Open'
            );

        grantCompanyAccess(
            company.Id,
            u.Id,
            'PERIOD-GRANT-2'
        );

        System.runAs(u) {
            SABPeriodService.PeriodActionRequest request =
                actionRequest(
                    period.Id,
                    'CLOSE-PD2',
                    'Close request replay'
                );

            SABPeriodService.PeriodActionResult firstResult =
                SABPeriodService.closePeriod(request);

            SABPeriodService.PeriodActionResult secondResult =
                SABPeriodService.closePeriod(request);

            System.assertEquals(
                true,
                secondResult.replay
            );
            System.assertEquals(
                firstResult.actionId,
                secondResult.actionId
            );
        }

        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM Accounting_Period_Action__c
                WHERE Request_Key__c = 'CLOSE-PD2'
            ]
        );
    }

    @IsTest
    static void closedPeriodCanBeReopenedWithNewAction() {
        User u = periodUser();

        Accounting_Company__c company =
            makeCompany('PD3', 'Period Company Three');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'PD3',
                'Open'
            );

        grantCompanyAccess(
            company.Id,
            u.Id,
            'PERIOD-GRANT-3'
        );

        System.runAs(u) {
            SABPeriodService.closePeriod(
                actionRequest(
                    period.Id,
                    'CLOSE-PD3',
                    'Initial close'
                )
            );

            Test.startTest();

            SABPeriodService.PeriodActionResult reopenResult =
                SABPeriodService.reopenPeriod(
                    actionRequest(
                        period.Id,
                        'REOPEN-PD3',
                        'Late approved correction required'
                    )
                );

            Test.stopTest();

            System.assertEquals(false, reopenResult.replay);
            System.assertEquals(
                'Closed',
                reopenResult.previousStatus
            );
            System.assertEquals(
                'Open',
                reopenResult.newStatus
            );
        }

        Accounting_Period__c storedPeriod = [
            SELECT Status__c,
                   Closed_By__c,
                   Closed_At__c,
                   Close_Request_Key__c
            FROM Accounting_Period__c
            WHERE Id = :period.Id
        ];

        System.assertEquals(
            'Open',
            storedPeriod.Status__c
        );
        System.assertEquals(
            null,
            storedPeriod.Closed_By__c
        );
        System.assertEquals(
            null,
            storedPeriod.Closed_At__c
        );
        System.assertEquals(
            null,
            storedPeriod.Close_Request_Key__c
        );

        List<Accounting_Period_Action__c> actions = [
            SELECT Previous_Status__c,
                   New_Status__c,
                   Reason__c
            FROM Accounting_Period_Action__c
            WHERE Period__c = :period.Id
            ORDER BY Performed_At__c ASC
        ];

        System.assertEquals(2, actions.size());
        System.assertEquals(
            'Closed',
            actions[1].Previous_Status__c
        );
        System.assertEquals(
            'Open',
            actions[1].New_Status__c
        );
    }

    @IsTest
    static void reopenRequiresReasonAndLeavesPeriodClosed() {
        User u = periodUser();

        Accounting_Company__c company =
            makeCompany('PD4', 'Period Company Four');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'PD4',
                'Closed'
            );

        grantCompanyAccess(
            company.Id,
            u.Id,
            'PERIOD-GRANT-4'
        );

        System.runAs(u) {
            Boolean thrown = false;

            try {
                SABPeriodService.reopenPeriod(
                    actionRequest(
                        period.Id,
                        'REOPEN-PD4',
                        null
                    )
                );
            } catch (Exception ex) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }

        Accounting_Period__c storedPeriod = [
            SELECT Status__c
            FROM Accounting_Period__c
            WHERE Id = :period.Id
        ];

        System.assertEquals(
            'Closed',
            storedPeriod.Status__c
        );
    }

    @IsTest
    static void differentCloseRequestCannotCloseAlreadyClosedPeriod() {
        User u = periodUser();

        Accounting_Company__c company =
            makeCompany('PD5', 'Period Company Five');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'PD5',
                'Open'
            );

        grantCompanyAccess(
            company.Id,
            u.Id,
            'PERIOD-GRANT-5'
        );

        System.runAs(u) {
            SABPeriodService.closePeriod(
                actionRequest(
                    period.Id,
                    'CLOSE-PD5-A',
                    'First close'
                )
            );

            Boolean thrown = false;

            try {
                SABPeriodService.closePeriod(
                    actionRequest(
                        period.Id,
                        'CLOSE-PD5-B',
                        'Second close'
                    )
                );
            } catch (Exception ex) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }

        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM Accounting_Period_Action__c
                WHERE Period__c = :period.Id
            ]
        );
    }

    @IsTest
    static void userWithoutCompanyAccessCannotClosePeriod() {
        User u = periodUser();

        Accounting_Company__c company =
            makeCompany('PD6', 'Unauthorized Period Company');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'PD6',
                'Open'
            );

        System.runAs(u) {
            Boolean thrown = false;

            try {
                SABPeriodService.closePeriod(
                    actionRequest(
                        period.Id,
                        'CLOSE-PD6',
                        'Unauthorized close attempt'
                    )
                );
            } catch (Exception ex) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
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
}
