@IsTest
private class SABFixedAssetDepreciationPostingTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Remaining_Fields_Admin',
            'SAB_Post_Journal_Action',
            'SAB_Fixed_Asset_Manager',
            'SAB_Fixed_Asset_Schedule_Manager',
            'SAB_Fixed_Asset_Depreciation_Poster'
        };

    @TestSetup
    static void setupFixture() {
        User testUser = createUser();
        assignPermissionSets(testUser);

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c =
                        'G9C Depreciation Company',
                    Company_Key__c =
                        'F9D',
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
                Effective_From__c =
                    Date.today(),
                Grant_Key__c =
                    'G9C-ACCESS',
                Is_Active__c =
                    true,
                Role__c =
                    'Finance Manager'
            );

            GL_Account__c assetAccount =
                makeGL(
                    company.Id,
                    '1600',
                    'Equipment Asset',
                    'Asset',
                    'Debit'
                );

            GL_Account__c accumulated =
                makeGL(
                    company.Id,
                    '1690',
                    'Accumulated Depreciation',
                    'Asset',
                    'Credit'
                );

            GL_Account__c depreciationExpense =
                makeGL(
                    company.Id,
                    '6200',
                    'Depreciation Expense',
                    'Expense',
                    'Debit'
                );

            GL_Account__c disposal =
                makeGL(
                    company.Id,
                    '7200',
                    'Asset Disposal Gain Loss',
                    'Expense',
                    'Debit'
                );

            Asset_Category__c category =
                new Asset_Category__c(
                    Name =
                        'Equipment',
                    Company__c =
                        company.Id,
                    Category_Key__c =
                        'F9D-EQUIPMENT',
                    Asset_Account__c =
                        assetAccount.Id,
                    Accumulated_Depreciation_Account__c =
                        accumulated.Id,
                    Depreciation_Expense_Account__c =
                        depreciationExpense.Id,
                    Disposal_Gain_Loss_Account__c =
                        disposal.Id,
                    Default_Useful_Life_Months__c =
                        3,
                    Allowed_Methods__c =
                        'Straight Line',
                    Is_Active__c =
                        true
                );
            insert category;

            insert new List<Accounting_Period__c>{
                period(
                    company.Id,
                    'F9D-2026-09',
                    Date.newInstance(
                        2026, 9, 1
                    ),
                    Date.newInstance(
                        2026, 9, 30
                    ),
                    9,
                    3,
                    'Open'
                ),
                period(
                    company.Id,
                    'F9D-2026-10',
                    Date.newInstance(
                        2026, 10, 1
                    ),
                    Date.newInstance(
                        2026, 10, 31
                    ),
                    10,
                    4,
                    'Closed'
                ),
                period(
                    company.Id,
                    'F9D-2026-11',
                    Date.newInstance(
                        2026, 11, 1
                    ),
                    Date.newInstance(
                        2026, 11, 30
                    ),
                    11,
                    4,
                    'Open'
                )
            };

            SABFixedAssetRegisterService.RegistrationRequest assetRequest =
                    new SABFixedAssetRegisterService.RegistrationRequest();

            assetRequest.companyId =
                company.Id;
            assetRequest.assetName =
                'G9C Laptop';
            assetRequest.companyAssetKey =
                'F9D-LAPTOP-001';
            assetRequest.assetTag =
                'F9D-LAPTOP-001';
            assetRequest.assetCategoryId =
                category.Id;
            assetRequest.acquisitionDate =
                Date.newInstance(
                    2026, 9, 1
                );
            assetRequest.inServiceDate =
                Date.newInstance(
                    2026, 9, 15
                );
            assetRequest.functionalCurrencyCost =
                300;
            assetRequest.residualValue =
                30;
            assetRequest.usefulLifeMonths =
                3;
            assetRequest.depreciationMethod =
                'Straight Line';
            assetRequest.initialStatus =
                'In Service';

            SABFixedAssetRegisterService.RegistrationResult assetResult =
                    SABFixedAssetRegisterService.registerAsset(
                            assetRequest
                        );

            SABFixedAssetScheduleService.ScheduleRequest scheduleRequest =
                    new SABFixedAssetScheduleService.ScheduleRequest();

            scheduleRequest.fixedAssetId =
                assetResult.fixedAssetId;
            scheduleRequest.bookKey =
                'PRIMARY';

            SABFixedAssetScheduleService.generateSchedule(
                    scheduleRequest
                );
        }
    }

    @IsTest
    static void plannedLinePostsDepreciationJournal() {
        User testUser = getUser();

        System.runAs(testUser) {
            Asset_Schedule_Line__c line =
                getScheduleLine(
                    Date.newInstance(
                        2026, 9, 30
                    )
                );

            SABFixedAssetDepreciationPostingService.PostingRequest request =
                    new SABFixedAssetDepreciationPostingService.PostingRequest();

            request.scheduleLineId =
                line.Id;
            request.requestKey =
                'G9C-POST-SEP';

            Test.startTest();

            SABFixedAssetDepreciationPostingService.PostingResult result =
                    SABFixedAssetDepreciationPostingService.postDepreciation(
                            request
                        );

            Test.stopTest();

            System.assertEquals(
                false,
                result.replay
            );
            System.assertEquals(
                Decimal.valueOf('90.0000'),
                result.depreciationAmount
            );
            System.assertNotEquals(
                null,
                result.journalEntryId
            );
            System.assertNotEquals(
                null,
                result.accountingEventId
            );

            Asset_Schedule_Line__c stored = [
                SELECT Status__c
                FROM Asset_Schedule_Line__c
                WHERE Id = :line.Id
            ];

            System.assertEquals(
                'Posted',
                stored.Status__c
            );

            Journal_Entry__c journal = [
                SELECT Status__c,
                       Entry_Type__c,
                       Accounting_Date__c,
                       Accounting_Event__c
                FROM Journal_Entry__c
                WHERE Id =
                    :result.journalEntryId
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
                Date.newInstance(
                    2026, 9, 30
                ),
                journal.Accounting_Date__c
            );
            System.assertEquals(
                result.accountingEventId,
                journal.Accounting_Event__c
            );

            Map<String, Journal_Entry_Line__c> byCode =
                new Map<String, Journal_Entry_Line__c>();

            for (
                Journal_Entry_Line__c journalLine : [
                    SELECT GL_Account__r.Account_Code__c,
                           Debit_Base__c,
                           Credit_Base__c
                    FROM Journal_Entry_Line__c
                    WHERE Journal_Entry__c =
                        :result.journalEntryId
                ]
            ) {
                byCode.put(
                    journalLine.GL_Account__r.Account_Code__c,
                    journalLine
                );
            }

            System.assertEquals(
                2,
                byCode.size()
            );
            System.assertEquals(
                Decimal.valueOf('90.0000'),
                byCode.get('6200').Debit_Base__c
            );
            System.assertEquals(
                Decimal.valueOf('90.0000'),
                byCode.get('1690').Credit_Base__c
            );

            Accounting_Event__c eventRecord = [
                SELECT Event_Type__c,
                       Source_Type__c,
                       Source_Record_Id__c,
                       State__c
                FROM Accounting_Event__c
                WHERE Id =
                    :result.accountingEventId
            ];

            System.assertEquals(
                'Depreciation',
                eventRecord.Event_Type__c
            );
            System.assertEquals(
                'Asset_Schedule_Line__c',
                eventRecord.Source_Type__c
            );
            System.assertEquals(
                String.valueOf(line.Id),
                eventRecord.Source_Record_Id__c
            );
            System.assertEquals(
                'Posted',
                eventRecord.State__c
            );
        }
    }

    @IsTest
    static void closedAccountingPeriodBlocksPosting() {
        User testUser = getUser();

        System.runAs(testUser) {
            Asset_Schedule_Line__c line =
                getScheduleLine(
                    Date.newInstance(
                        2026, 10, 31
                    )
                );

            SABFixedAssetDepreciationPostingService.PostingRequest request =
                    new SABFixedAssetDepreciationPostingService.PostingRequest();

            request.scheduleLineId =
                line.Id;
            request.requestKey =
                'G9C-POST-CLOSED';

            Boolean blocked = false;

            Test.startTest();

            try {
                SABFixedAssetDepreciationPostingService.postDepreciation(
                        request
                    );
            } catch (
                SABFixedAssetDepreciationPostingService.FixedAssetDepreciationPostingException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'must be Open'
                    );
            }

            Test.stopTest();

            System.assertEquals(
                true,
                blocked
            );

            Asset_Schedule_Line__c stored = [
                SELECT Status__c
                FROM Asset_Schedule_Line__c
                WHERE Id = :line.Id
            ];

            System.assertEquals(
                'Planned',
                stored.Status__c
            );

            System.assertEquals(
                0,
                [
                    SELECT COUNT()
                    FROM Accounting_Event__c
                    WHERE Source_Type__c =
                        'Asset_Schedule_Line__c'
                      AND Source_Record_Id__c =
                        :String.valueOf(line.Id)
                ]
            );
        }
    }

    @IsTest
    static void postingIsIdempotentAfterScheduleLinePosted() {
        User testUser = getUser();

        System.runAs(testUser) {
            Asset_Schedule_Line__c line =
                getScheduleLine(
                    Date.newInstance(
                        2026, 9, 30
                    )
                );

            SABFixedAssetDepreciationPostingService.PostingRequest request =
                    new SABFixedAssetDepreciationPostingService.PostingRequest();

            request.scheduleLineId =
                line.Id;
            request.requestKey =
                'G9C-POST-REPLAY';

            Test.startTest();

            SABFixedAssetDepreciationPostingService.PostingResult first =
                    SABFixedAssetDepreciationPostingService.postDepreciation(
                            request
                        );

            Test.stopTest();

            SABFixedAssetDepreciationPostingService.PostingResult replay =
                    SABFixedAssetDepreciationPostingService.postDepreciation(
                            request
                        );

            System.assertEquals(
                true,
                replay.replay
            );
            System.assertEquals(
                first.journalEntryId,
                replay.journalEntryId
            );
            System.assertEquals(
                first.accountingEventId,
                replay.accountingEventId
            );
            System.assertEquals(
                first.postingKey,
                replay.postingKey
            );

            System.assertEquals(
                1,
                [
                    SELECT COUNT()
                    FROM Accounting_Event__c
                    WHERE Source_Type__c =
                        'Asset_Schedule_Line__c'
                      AND Source_Record_Id__c =
                        :String.valueOf(line.Id)
                ]
            );
        }
    }

    @IsTest
    static void directScheduleStatusUpdateRemainsBlocked() {
        User testUser = getUser();

        System.runAs(testUser) {
            Asset_Schedule_Line__c line =
                getScheduleLine(
                    Date.newInstance(
                        2026, 9, 30
                    )
                );

            line.Status__c =
                'Posted';

            Database.SaveResult result =
                Database.update(
                    line,
                    false
                );

            System.assertEquals(
                false,
                result.isSuccess()
            );

            System.assert(
                result.getErrors()[0].getMessage().contains(
                        'system-managed'
                    ),
                result.getErrors()[0].getMessage()
            );
        }
    }

    private static Accounting_Period__c period(
        Id companyId,
        String keyValue,
        Date startDate,
        Date endDate,
        Integer periodNumber,
        Integer quarter,
        String status
    ) {
        Accounting_Period__c row =
            new Accounting_Period__c(
                Name =
                    keyValue,
                Company__c =
                    companyId,
                Company_Period_Key__c =
                    keyValue,
                Period_Key__c =
                    keyValue,
                Start_Date__c =
                    startDate,
                End_Date__c =
                    endDate,
                Fiscal_Year__c =
                    2026,
                Fiscal_Quarter__c =
                    quarter,
                Period_Number__c =
                    periodNumber,
                Status__c =
                    status
            );

        if (status == 'Closed') {
            row.Closed_At__c =
                System.now();
            row.Closed_By__c =
                UserInfo.getUserId();
        }

        return row;
    }

    private static GL_Account__c makeGL(
        Id companyId,
        String code,
        String label,
        String accountType,
        String normalBalance
    ) {
        GL_Account__c row =
            new GL_Account__c(
                Name =
                    label,
                Company__c =
                    companyId,
                Company_Account_Key__c =
                    String.valueOf(companyId)
                    + '-' + code,
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

    private static Asset_Schedule_Line__c
        getScheduleLine(
            Date scheduledDate
        )
    {
        return [
            SELECT Id,
                   Status__c,
                   Scheduled_Date__c
            FROM Asset_Schedule_Line__c
            WHERE Fixed_Asset__r.Company__r.Company_Key__c =
                        'F9D'
              AND Scheduled_Date__c =
                    :scheduledDate
            LIMIT 1
        ];
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
                    'g9cdep',
                Email =
                    'g9c.' + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    'G9C Depreciation User',
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    profileRecord.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    'g9c.' + seed
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
            WHERE Name IN
                :REQUIRED_PERMISSION_SETS
        ]) {
            ids.put(
                row.Name,
                row.Id
            );
        }

        System.assertEquals(
            REQUIRED_PERMISSION_SETS.size(),
            ids.size(),
            'G9C dependency Permission Sets must exist.'
        );

        List<PermissionSetAssignment>
            assignments =
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
                        ids.get(
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
                'G9C Depreciation User'
            LIMIT 1
        ];
    }
}
