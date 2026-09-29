@IsTest
private class SABFixedAssetScheduleServiceTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Remaining_Fields_Admin',
            'SAB_Fixed_Asset_Manager',
            'SAB_Fixed_Asset_Schedule_Manager'
        };

    @TestSetup
    static void setupFixture() {
        User testUser = createUser();
        assignPermissionSets(testUser);

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c =
                        'G9B Schedule Company',
                    Company_Key__c = 'F9C',
                    Country_Code__c = 'BD',
                    Functional_Currency__c =
                        'BDT',
                    Fiscal_Calendar_Type__c =
                        'Calendar',
                    Fiscal_Year_Start_Month__c =
                        1,
                    Setup_Status__c =
                        'Active',
                    Is_Active__c = true
                );
            insert company;

            insert new Company_User_Access__c(
                Company__c = company.Id,
                User__c = testUser.Id,
                Effective_From__c =
                    Date.today(),
                Grant_Key__c =
                    'G9B-ACCESS',
                Is_Active__c = true,
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

            insert new Asset_Category__c(
                Name = 'Equipment',
                Company__c = company.Id,
                Category_Key__c =
                    'F9C-EQUIPMENT',
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
                    'Straight Line,Other Supported',
                Is_Active__c = true
            );

            insert new List<Accounting_Period__c>{
                period(
                    company.Id,
                    'F9C-2026-09',
                    Date.newInstance(
                        2026, 9, 1
                    ),
                    Date.newInstance(
                        2026, 9, 30
                    ),
                    9,
                    3
                ),
                period(
                    company.Id,
                    'F9C-2026-10',
                    Date.newInstance(
                        2026, 10, 1
                    ),
                    Date.newInstance(
                        2026, 10, 31
                    ),
                    10,
                    4
                ),
                period(
                    company.Id,
                    'F9C-2026-11',
                    Date.newInstance(
                        2026, 11, 1
                    ),
                    Date.newInstance(
                        2026, 11, 30
                    ),
                    11,
                    4
                )
            };
        }
    }

    @IsTest
    static void straightLineScheduleGeneratesAndBalances() {
        User testUser = getUser();

        System.runAs(testUser) {
            Id assetId = registerAsset(
                'F9C-ASSET-001',
                'Straight Line',
                100,
                0,
                3
            );

            SABFixedAssetScheduleService.ScheduleRequest request =
                    new SABFixedAssetScheduleService.ScheduleRequest();

            request.fixedAssetId = assetId;
            request.bookKey = 'PRIMARY';

            Test.startTest();

            SABFixedAssetScheduleService.ScheduleResult result =
                    SABFixedAssetScheduleService.generateSchedule(request);

            Test.stopTest();

            System.assertEquals(
                false,
                result.replay
            );
            System.assertEquals(
                1,
                result.calculationVersion
            );
            System.assertEquals(
                3,
                result.lineCount
            );
            System.assertEquals(
                3,
                result.plannedCount
            );
            System.assertEquals(
                0,
                result.postedCount
            );
            System.assertEquals(
                Decimal.valueOf('100.0000'),
                result.depreciableBase
            );
            System.assertEquals(
                Decimal.valueOf('100.0000'),
                result.scheduledTotal
            );

            List<Asset_Schedule_Line__c> rows = [
                SELECT Planned_Depreciation__c,
                       Scheduled_Date__c,
                       Calculation_Version__c,
                       Status__c,
                       Period__r.Start_Date__c
                FROM Asset_Schedule_Line__c
                WHERE Fixed_Asset__c =
                    :assetId
                ORDER BY Scheduled_Date__c
            ];

            System.assertEquals(
                Decimal.valueOf('33.3333'),
                rows[0].Planned_Depreciation__c
            );
            System.assertEquals(
                Decimal.valueOf('33.3333'),
                rows[1].Planned_Depreciation__c
            );
            System.assertEquals(
                Decimal.valueOf('33.3334'),
                rows[2].Planned_Depreciation__c
            );

            System.assertEquals(
                Date.newInstance(
                    2026, 9, 30
                ),
                rows[0].Scheduled_Date__c
            );
            System.assertEquals(
                Date.newInstance(
                    2026, 11, 30
                ),
                rows[2].Scheduled_Date__c
            );
        }
    }

    @IsTest
    static void repeatGenerationIsIdempotent() {
        User testUser = getUser();

        System.runAs(testUser) {
            Id assetId = registerAsset(
                'F9C-ASSET-002',
                'Straight Line',
                300,
                30,
                3
            );

            SABFixedAssetScheduleService.ScheduleRequest request =
                    new SABFixedAssetScheduleService.ScheduleRequest();

            request.fixedAssetId = assetId;
            request.bookKey = 'PRIMARY';

            SABFixedAssetScheduleService.ScheduleResult first =
                    SABFixedAssetScheduleService.generateSchedule(request);

            Test.startTest();

            SABFixedAssetScheduleService.ScheduleResult replay =
                    SABFixedAssetScheduleService.generateSchedule(request);

            Test.stopTest();

            System.assertEquals(
                true,
                replay.replay
            );
            System.assertEquals(
                first.calculationVersion,
                replay.calculationVersion
            );
            System.assertEquals(
                first.lineCount,
                replay.lineCount
            );
            System.assertEquals(
                Decimal.valueOf('270.0000'),
                replay.scheduledTotal
            );

            System.assertEquals(
                3,
                [
                    SELECT COUNT()
                    FROM Asset_Schedule_Line__c
                    WHERE Fixed_Asset__c =
                        :assetId
                      AND Book_Key__c =
                        'PRIMARY'
                ]
            );
        }
    }

    @IsTest
    static void insufficientPeriodCoverageBlocksGeneration() {
        User testUser = getUser();

        System.runAs(testUser) {
            Id assetId = registerAsset(
                'F9C-ASSET-003',
                'Straight Line',
                400,
                0,
                4
            );

            SABFixedAssetScheduleService.ScheduleRequest request =
                    new SABFixedAssetScheduleService.ScheduleRequest();

            request.fixedAssetId = assetId;
            request.bookKey = 'PRIMARY';

            Boolean blocked = false;

            Test.startTest();

            try {
                SABFixedAssetScheduleService.generateSchedule(request);
            } catch (
                SABFixedAssetScheduleService.FixedAssetScheduleException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'Not enough Accounting Periods'
                    );
            }

            Test.stopTest();

            System.assertEquals(
                true,
                blocked
            );

            System.assertEquals(
                0,
                [
                    SELECT COUNT()
                    FROM Asset_Schedule_Line__c
                    WHERE Fixed_Asset__c =
                        :assetId
                ]
            );
        }
    }

    @IsTest
    static void unsupportedDepreciationMethodIsBlocked() {
        User testUser = getUser();

        System.runAs(testUser) {
            Id assetId = registerAsset(
                'F9C-ASSET-004',
                'Other Supported',
                300,
                0,
                3
            );

            SABFixedAssetScheduleService.ScheduleRequest request =
                    new SABFixedAssetScheduleService.ScheduleRequest();

            request.fixedAssetId = assetId;
            request.bookKey = 'PRIMARY';

            Boolean blocked = false;

            try {
                SABFixedAssetScheduleService.generateSchedule(request);
            } catch (
                SABFixedAssetScheduleService.FixedAssetScheduleException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'Straight Line'
                    );
            }

            System.assertEquals(
                true,
                blocked
            );
        }
    }

    @IsTest
    static void directScheduleLineInsertIsBlocked() {
        User testUser = getUser();

        System.runAs(testUser) {
            Id assetId = registerAsset(
                'F9C-ASSET-005',
                'Straight Line',
                100,
                0,
                3
            );

            Accounting_Period__c periodRecord = [
                SELECT Id,
                       End_Date__c
                FROM Accounting_Period__c
                WHERE Company__r.Company_Key__c =
                    'F9C'
                ORDER BY Start_Date__c
                LIMIT 1
            ];

            Database.SaveResult result =
                Database.insert(
                    new Asset_Schedule_Line__c(
                        Fixed_Asset__c =
                            assetId,
                        Period__c =
                            periodRecord.Id,
                        Scheduled_Date__c =
                            periodRecord.End_Date__c,
                        Planned_Depreciation__c =
                            10,
                        Book_Key__c =
                            'DIRECT',
                        Calculation_Version__c =
                            1,
                        Status__c =
                            'Planned'
                    ),
                    false
                );

            System.assertEquals(
                false,
                result.isSuccess()
            );

            System.assert(
                result.getErrors()[0].getMessage().contains(
                        'controlled Fixed Asset Schedule service'
                    ),
                result.getErrors()[0].getMessage()
            );
        }
    }

    private static Id registerAsset(
        String assetKey,
        String method,
        Decimal cost,
        Decimal residual,
        Integer usefulLife
    ) {
        Accounting_Company__c company = [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c =
                'F9C'
            LIMIT 1
        ];

        Asset_Category__c category = [
            SELECT Id
            FROM Asset_Category__c
            WHERE Category_Key__c =
                'F9C-EQUIPMENT'
            LIMIT 1
        ];

        SABFixedAssetRegisterService.RegistrationRequest request =
                new SABFixedAssetRegisterService.RegistrationRequest();

        request.companyId = company.Id;
        request.assetName =
            'Asset ' + assetKey;
        request.companyAssetKey =
            assetKey;
        request.assetTag =
            assetKey;
        request.assetCategoryId =
            category.Id;
        request.acquisitionDate =
            Date.newInstance(
                2026, 9, 1
            );
        request.inServiceDate =
            Date.newInstance(
                2026, 9, 15
            );
        request.functionalCurrencyCost =
            cost;
        request.residualValue =
            residual;
        request.usefulLifeMonths =
            usefulLife;
        request.depreciationMethod =
            method;
        request.initialStatus =
            'In Service';

        return SABFixedAssetRegisterService.registerAsset(request).fixedAssetId;
    }

    private static Accounting_Period__c period(
        Id companyId,
        String keyValue,
        Date startDate,
        Date endDate,
        Integer periodNumber,
        Integer quarter
    ) {
        return new Accounting_Period__c(
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
                'Open'
        );
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
                Name = label,
                Company__c = companyId,
                Company_Account_Key__c =
                    String.valueOf(companyId)
                    + '-' + code,
                Account_Code__c = code,
                Account_Type__c =
                    accountType,
                Normal_Balance__c =
                    normalBalance,
                Is_Active__c = true,
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
                Alias = 'g9bsch',
                Email =
                    'g9b.' + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    'G9B Asset Schedule User',
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    profileRecord.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    'g9b.' + seed
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
            'G9B dependency Permission Sets must exist.'
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
                'G9B Asset Schedule User'
            LIMIT 1
        ];
    }
}
