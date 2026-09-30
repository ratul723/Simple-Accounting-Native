@IsTest
private class SABFixedAssetMovementServiceTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Remaining_Fields_Admin',
            'SAB_Post_Journal_Action',
            'SAB_Fixed_Asset_Manager',
            'SAB_Fixed_Asset_Schedule_Manager',
            'SAB_Fixed_Asset_Depreciation_Poster',
            'SAB_Fixed_Asset_Movement_Manager'
        };

    @TestSetup
    static void setupFixture() {
        User testUser = createUser();
        assignPermissionSets(testUser);

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c = 'G9D Asset Company',
                    Company_Key__c = 'F9E',
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
                Effective_From__c = Date.today(),
                Grant_Key__c = 'G9D-ACCESS',
                Is_Active__c = true,
                Role__c = 'Finance Manager'
            );

            GL_Account__c assetAccount =
                makeGL(company.Id, '1600', 'Equipment Asset', 'Asset', 'Debit');
            GL_Account__c accumulated =
                makeGL(company.Id, '1690', 'Accumulated Depreciation', 'Asset', 'Credit');
            GL_Account__c depreciationExpense =
                makeGL(company.Id, '6200', 'Depreciation Expense', 'Expense', 'Debit');
            GL_Account__c gainLoss =
                makeGL(company.Id, '7200', 'Asset Gain Loss', 'Expense', 'Debit');
            GL_Account__c bankGL =
                makeGL(company.Id, '1100', 'Operating Bank', 'Asset', 'Debit');

            Asset_Category__c category =
                new Asset_Category__c(
                    Name = 'Equipment',
                    Company__c = company.Id,
                    Category_Key__c = 'F9E-EQUIPMENT',
                    Asset_Account__c = assetAccount.Id,
                    Accumulated_Depreciation_Account__c = accumulated.Id,
                    Depreciation_Expense_Account__c = depreciationExpense.Id,
                    Disposal_Gain_Loss_Account__c = gainLoss.Id,
                    Default_Useful_Life_Months__c = 4,
                    Allowed_Methods__c = 'Straight Line',
                    Is_Active__c = true
                );
            insert category;

            Bank_Account__c bank =
                new Bank_Account__c(
                    Name = 'G9D Bank',
                    Company__c = company.Id,
                    Currency__c = 'BDT',
                    GL_Account__c = bankGL.Id,
                    Is_Active__c = true
                );
            insert bank;

            Department__c departmentA =
                new Department__c(
                    Name = 'Operations',
                    Company__c = company.Id,
                    Code__c = 'OPS',
                    Company_Department_Key__c = 'F9E-OPS',
                    Is_Active__c = true
                );

            Department__c departmentB =
                new Department__c(
                    Name = 'Delivery',
                    Company__c = company.Id,
                    Code__c = 'DEL',
                    Company_Department_Key__c = 'F9E-DEL',
                    Is_Active__c = true
                );
            insert new List<Department__c>{
                departmentA,
                departmentB
            };

            Cost_Center__c costCenterA =
                new Cost_Center__c(
                    Name = 'Operations CC',
                    Company__c = company.Id,
                    Code__c = 'OPS-CC',
                    Company_Cost_Center_Key__c = 'F9E-OPS-CC',
                    Is_Active__c = true
                );
            Cost_Center__c costCenterB =
                new Cost_Center__c(
                    Name = 'Delivery CC',
                    Company__c = company.Id,
                    Code__c = 'DLV-CC',
                    Company_Cost_Center_Key__c = 'F9E-DLV-CC',
                    Is_Active__c = true
                );
            insert new List<Cost_Center__c>{
                costCenterA,
                costCenterB
            };

            Employee__c employeeA =
                new Employee__c(
                    Name = 'Asset Custodian A',
                    Employee_Reference__c = 'F9E-EMP-A',
                    Status__c = 'Active'
                );
            Employee__c employeeB =
                new Employee__c(
                    Name = 'Asset Custodian B',
                    Employee_Reference__c = 'F9E-EMP-B',
                    Status__c = 'Active'
                );
            insert new List<Employee__c>{
                employeeA,
                employeeB
            };

            insert new List<Employment__c>{
                new Employment__c(
                    Company__c = company.Id,
                    Employee__c = employeeA.Id,
                    Employment_Key__c = 'F9E-EMPLOY-A',
                    Employment_Status__c = 'Active',
                    Start_Date__c = Date.newInstance(2026, 1, 1)
                ),
                new Employment__c(
                    Company__c = company.Id,
                    Employee__c = employeeB.Id,
                    Employment_Key__c = 'F9E-EMPLOY-B',
                    Employment_Status__c = 'Active',
                    Start_Date__c = Date.newInstance(2026, 1, 1)
                )
            };

            insert new List<Accounting_Period__c>{
                period(company.Id, 'F9E-2026-09', Date.newInstance(2026,9,1), Date.newInstance(2026,9,30), 9, 3, 'Open'),
                period(company.Id, 'F9E-2026-10', Date.newInstance(2026,10,1), Date.newInstance(2026,10,31), 10, 4, 'Open'),
                period(company.Id, 'F9E-2026-11', Date.newInstance(2026,11,1), Date.newInstance(2026,11,30), 11, 4, 'Open'),
                period(company.Id, 'F9E-2026-12', Date.newInstance(2026,12,1), Date.newInstance(2026,12,31), 12, 4, 'Open')
            };

            registerAndSchedule(
                'F9E-ASSET-TRANSFER',
                departmentA.Id,
                costCenterA.Id,
                employeeA.Id,
                'Dhaka Floor 1'
            );
            registerAndSchedule(
                'F9E-ASSET-IMPAIR',
                departmentA.Id,
                costCenterA.Id,
                employeeA.Id,
                'Dhaka Floor 1'
            );
            registerAndSchedule(
                'F9E-ASSET-DISPOSE',
                departmentA.Id,
                costCenterA.Id,
                employeeA.Id,
                'Dhaka Floor 1'
            );
        }
    }

    @IsTest
    static void transferCreatesAuditMovementAndUpdatesAsset() {
        User testUser = getUser();

        System.runAs(testUser) {
            Fixed_Asset__c asset = getAsset('F9E-ASSET-TRANSFER');
            Department__c toDepartment = [
                SELECT Id FROM Department__c
                WHERE Name = 'Delivery'
                LIMIT 1
            ];
            Cost_Center__c toCostCenter = [
                SELECT Id FROM Cost_Center__c
                WHERE Name = 'Delivery CC'
                LIMIT 1
            ];
            Employee__c toCustodian = [
                SELECT Id FROM Employee__c
                WHERE Employee_Reference__c = 'F9E-EMP-B'
                LIMIT 1
            ];

            SABFixedAssetMovementService.TransferRequest request =
                new SABFixedAssetMovementService.TransferRequest();
            request.fixedAssetId = asset.Id;
            request.movementKey = 'F9E-TRANSFER-001';
            request.bookKey = 'PRIMARY';
            request.movementDate = Date.newInstance(2026,10,10);
            request.accountingDate = Date.newInstance(2026,10,10);
            request.toDepartmentId = toDepartment.Id;
            request.toCostCenterId = toCostCenter.Id;
            request.toCustodianId = toCustodian.Id;
            request.toLocation = 'Dhaka Floor 2';
            request.reason = 'Operational transfer';

            Test.startTest();
            SABFixedAssetMovementService.MovementResult result =
                SABFixedAssetMovementService.transferAsset(request);
            Test.stopTest();

            System.assertEquals(false, result.replay);
            System.assertEquals('Transfer', result.movementType);
            System.assertEquals(Decimal.valueOf('0.0000'), result.amount);
            System.assertEquals(null, result.journalEntryId);
            System.assertEquals(null, result.accountingEventId);

            Fixed_Asset__c stored = [
                SELECT Department__c,
                       Cost_Center__c,
                       Custodian__c,
                       Location__c
                FROM Fixed_Asset__c
                WHERE Id = :asset.Id
            ];
            System.assertEquals(toDepartment.Id, stored.Department__c);
            System.assertEquals(toCostCenter.Id, stored.Cost_Center__c);
            System.assertEquals(toCustodian.Id, stored.Custodian__c);
            System.assertEquals('Dhaka Floor 2', stored.Location__c);

            Asset_Movement__c movement = [
                SELECT Movement_Type__c,
                       From_Location__c,
                       To_Location__c,
                       From_Department__c,
                       To_Department__c
                FROM Asset_Movement__c
                WHERE Id = :result.movementId
            ];
            System.assertEquals('Transfer', movement.Movement_Type__c);
            System.assertEquals('Dhaka Floor 1', movement.From_Location__c);
            System.assertEquals('Dhaka Floor 2', movement.To_Location__c);
            System.assertNotEquals(movement.From_Department__c, movement.To_Department__c);

            SABFixedAssetMovementService.MovementResult replay =
                SABFixedAssetMovementService.transferAsset(request);
            System.assertEquals(true, replay.replay);
            System.assertEquals(result.movementId, replay.movementId);
        }
    }

    @IsTest
    static void impairmentPostsAndRegeneratesFutureSchedule() {
        User testUser = getUser();

        System.runAs(testUser) {
            Fixed_Asset__c asset = getAsset('F9E-ASSET-IMPAIR');
            postSeptemberDepreciation(asset.Id, 'F9E-DEP-IMPAIR');

            SABFixedAssetMovementService.ImpairmentRequest request =
                new SABFixedAssetMovementService.ImpairmentRequest();
            request.fixedAssetId = asset.Id;
            request.movementKey = 'F9E-IMPAIR-001';
            request.bookKey = 'PRIMARY';
            request.movementDate = Date.newInstance(2026,10,15);
            request.accountingDate = Date.newInstance(2026,10,15);
            request.impairmentAmount = 30;
            request.requestKey = 'F9E-IMPAIR-POST-001';
            request.reason = 'Permanent impairment';

            Test.startTest();
            SABFixedAssetMovementService.MovementResult result =
                SABFixedAssetMovementService.recordImpairment(request);
            Test.stopTest();

            System.assertEquals('Impairment', result.movementType);
            System.assertEquals(Decimal.valueOf('30.0000'), result.amount);
            System.assertNotEquals(null, result.journalEntryId);
            System.assertNotEquals(null, result.accountingEventId);
            System.assertEquals('Impaired', result.assetStatus);

            Map<String, Journal_Entry_Line__c> byCode =
                journalLinesByCode(result.journalEntryId);
            System.assertEquals(
                Decimal.valueOf('30.0000'),
                byCode.get('7200').Debit_Base__c
            );
            System.assertEquals(
                Decimal.valueOf('30.0000'),
                byCode.get('1600').Credit_Base__c
            );

            List<Asset_Schedule_Line__c> activeFuture = [
                SELECT Planned_Depreciation__c,
                       Calculation_Version__c,
                       Status__c,
                       Scheduled_Date__c
                FROM Asset_Schedule_Line__c
                WHERE Fixed_Asset__c = :asset.Id
                  AND Book_Key__c = 'PRIMARY'
                  AND Status__c = 'Planned'
                ORDER BY Scheduled_Date__c
            ];
            System.assertEquals(3, activeFuture.size());
            System.assertEquals(Decimal.valueOf('80.0000'), activeFuture[0].Planned_Depreciation__c);
            System.assertEquals(Decimal.valueOf('80.0000'), activeFuture[1].Planned_Depreciation__c);
            System.assertEquals(Decimal.valueOf('80.0000'), activeFuture[2].Planned_Depreciation__c);
            System.assertEquals(Decimal.valueOf('2'), activeFuture[0].Calculation_Version__c);

            System.assertEquals(
                3,
                [
                    SELECT COUNT()
                    FROM Asset_Schedule_Line__c
                    WHERE Fixed_Asset__c = :asset.Id
                      AND Book_Key__c = 'PRIMARY'
                      AND Status__c = 'Superseded'
                ]
            );

            Asset_Schedule_Line__c octoberLine = [
                SELECT Id
                FROM Asset_Schedule_Line__c
                WHERE Fixed_Asset__c = :asset.Id
                  AND Book_Key__c = 'PRIMARY'
                  AND Status__c = 'Planned'
                  AND Scheduled_Date__c = :Date.newInstance(2026,10,31)
                LIMIT 1
            ];

            SABFixedAssetDepreciationPostingService.PostingRequest depRequest =
                new SABFixedAssetDepreciationPostingService.PostingRequest();
            depRequest.scheduleLineId = octoberLine.Id;
            depRequest.requestKey = 'F9E-DEP-AFTER-IMPAIR';

            SABFixedAssetDepreciationPostingService.PostingResult depResult =
                SABFixedAssetDepreciationPostingService.postDepreciation(depRequest);

            System.assertEquals(Decimal.valueOf('80.0000'), depResult.depreciationAmount);
        }
    }

    @IsTest
    static void disposalPostsDerecognitionAndProceeds() {
        User testUser = getUser();

        System.runAs(testUser) {
            Fixed_Asset__c asset = getAsset('F9E-ASSET-DISPOSE');
            postSeptemberDepreciation(asset.Id, 'F9E-DEP-DISPOSE');

            Bank_Account__c bank = [
                SELECT Id FROM Bank_Account__c
                WHERE Name = 'G9D Bank'
                LIMIT 1
            ];

            SABFixedAssetMovementService.DisposalRequest request =
                new SABFixedAssetMovementService.DisposalRequest();
            request.fixedAssetId = asset.Id;
            request.movementKey = 'F9E-DISPOSE-001';
            request.bookKey = 'PRIMARY';
            request.movementDate = Date.newInstance(2026,10,15);
            request.accountingDate = Date.newInstance(2026,10,15);
            request.proceeds = 250;
            request.bankAccountId = bank.Id;
            request.requestKey = 'F9E-DISPOSE-POST-001';
            request.reason = 'Asset sale';

            Test.startTest();
            SABFixedAssetMovementService.MovementResult result =
                SABFixedAssetMovementService.disposeAsset(request);
            Test.stopTest();

            System.assertEquals('Disposal', result.movementType);
            System.assertEquals(Decimal.valueOf('310.0000'), result.amount);
            System.assertEquals(Decimal.valueOf('250.0000'), result.proceeds);
            System.assertEquals('Disposed', result.assetStatus);

            Map<String, Journal_Entry_Line__c> byCode =
                journalLinesByCode(result.journalEntryId);

            System.assertEquals(Decimal.valueOf('250.0000'), byCode.get('1100').Debit_Base__c);
            System.assertEquals(Decimal.valueOf('90.0000'), byCode.get('1690').Debit_Base__c);
            System.assertEquals(Decimal.valueOf('60.0000'), byCode.get('7200').Debit_Base__c);
            System.assertEquals(Decimal.valueOf('400.0000'), byCode.get('1600').Credit_Base__c);

            System.assertEquals(
                0,
                [
                    SELECT COUNT()
                    FROM Asset_Schedule_Line__c
                    WHERE Fixed_Asset__c = :asset.Id
                      AND Book_Key__c = 'PRIMARY'
                      AND Status__c = 'Planned'
                ]
            );

            Asset_Movement__c movement = [
                SELECT Accounting_Event__c,
                       Journal_Entry__c,
                       Disposal_Proceeds__c,
                       Disposal_Bank_Account__c
                FROM Asset_Movement__c
                WHERE Id = :result.movementId
            ];
            System.assertEquals(result.accountingEventId, movement.Accounting_Event__c);
            System.assertEquals(result.journalEntryId, movement.Journal_Entry__c);
            System.assertEquals(Decimal.valueOf('250.0000'), movement.Disposal_Proceeds__c);
            System.assertEquals(bank.Id, movement.Disposal_Bank_Account__c);
        }
    }

    @IsTest
    static void directAssetMovementAndTransferMutationAreBlocked() {
        User testUser = getUser();

        System.runAs(testUser) {
            Fixed_Asset__c asset = getAsset('F9E-ASSET-TRANSFER');

            Accounting_Period__c periodRecord = [
                SELECT Id
                FROM Accounting_Period__c
                WHERE Company__r.Company_Key__c = 'F9E'
                ORDER BY Start_Date__c
                LIMIT 1
            ];

            Database.SaveResult movementInsert =
                Database.insert(
                    new Asset_Movement__c(
                        Fixed_Asset__c = asset.Id,
                        Movement_Type__c = 'Transfer',
                        Movement_Date__c = Date.newInstance(2026,9,20),
                        Accounting_Date__c = Date.newInstance(2026,9,20),
                        Period__c = periodRecord.Id,
                        Amount__c = 0,
                        Book_Key__c = 'PRIMARY',
                        Movement_Key__c = 'F9E-DIRECT-MOVE'
                    ),
                    false
                );

            System.assertEquals(false, movementInsert.isSuccess());

            asset.Location__c = 'Unauthorized Change';
            Database.SaveResult assetUpdate =
                Database.update(asset, false);

            System.assertEquals(false, assetUpdate.isSuccess());
            System.assert(
                assetUpdate.getErrors()[0].getMessage().contains(
                    'controlled asset lifecycle services'
                ),
                assetUpdate.getErrors()[0].getMessage()
            );
        }
    }

    @IsTest
    static void depreciationCreatesMovementEvidence() {
        User testUser = getUser();

        System.runAs(testUser) {
            Fixed_Asset__c asset = getAsset('F9E-ASSET-IMPAIR');
            SABFixedAssetDepreciationPostingService.PostingResult result =
                postSeptemberDepreciation(asset.Id, 'F9E-DEP-EVIDENCE');

            Asset_Movement__c movement = [
                SELECT Movement_Type__c,
                       Amount__c,
                       Book_Key__c,
                       Journal_Entry__c,
                       Accounting_Event__c
                FROM Asset_Movement__c
                WHERE Movement_Key__c =
                    :('DEP|' + String.valueOf(result.scheduleLineId) + '|V1')
                LIMIT 1
            ];

            System.assertEquals('Depreciation', movement.Movement_Type__c);
            System.assertEquals(result.depreciationAmount, movement.Amount__c);
            System.assertEquals('PRIMARY', movement.Book_Key__c);
            System.assertEquals(result.journalEntryId, movement.Journal_Entry__c);
            System.assertEquals(result.accountingEventId, movement.Accounting_Event__c);
        }
    }

    private static void registerAndSchedule(
        String assetKey,
        Id departmentId,
        Id costCenterId,
        Id custodianId,
        String location
    ) {
        Accounting_Company__c company = [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c = 'F9E'
            LIMIT 1
        ];

        Asset_Category__c category = [
            SELECT Id
            FROM Asset_Category__c
            WHERE Category_Key__c = 'F9E-EQUIPMENT'
            LIMIT 1
        ];

        SABFixedAssetRegisterService.RegistrationRequest assetRequest =
            new SABFixedAssetRegisterService.RegistrationRequest();

        assetRequest.companyId = company.Id;
        assetRequest.assetName = 'Asset ' + assetKey;
        assetRequest.companyAssetKey = assetKey;
        assetRequest.assetTag = assetKey;
        assetRequest.assetCategoryId = category.Id;
        assetRequest.acquisitionDate = Date.newInstance(2026,9,1);
        assetRequest.inServiceDate = Date.newInstance(2026,9,15);
        assetRequest.functionalCurrencyCost = 400;
        assetRequest.residualValue = 40;
        assetRequest.usefulLifeMonths = 4;
        assetRequest.depreciationMethod = 'Straight Line';
        assetRequest.departmentId = departmentId;
        assetRequest.costCenterId = costCenterId;
        assetRequest.custodianId = custodianId;
        assetRequest.location = location;
        assetRequest.initialStatus = 'In Service';

        Id assetId =
            SABFixedAssetRegisterService.registerAsset(assetRequest).fixedAssetId;

        SABFixedAssetScheduleService.ScheduleRequest scheduleRequest =
            new SABFixedAssetScheduleService.ScheduleRequest();
        scheduleRequest.fixedAssetId = assetId;
        scheduleRequest.bookKey = 'PRIMARY';

        SABFixedAssetScheduleService.generateSchedule(scheduleRequest);
    }

    private static SABFixedAssetDepreciationPostingService.PostingResult
        postSeptemberDepreciation(
            Id assetId,
            String requestKey
        )
    {
        Asset_Schedule_Line__c line = [
            SELECT Id
            FROM Asset_Schedule_Line__c
            WHERE Fixed_Asset__c = :assetId
              AND Book_Key__c = 'PRIMARY'
              AND Status__c = 'Planned'
              AND Scheduled_Date__c = :Date.newInstance(2026,9,30)
            LIMIT 1
        ];

        SABFixedAssetDepreciationPostingService.PostingRequest request =
            new SABFixedAssetDepreciationPostingService.PostingRequest();
        request.scheduleLineId = line.Id;
        request.requestKey = requestKey;

        return SABFixedAssetDepreciationPostingService.postDepreciation(request);
    }

    private static Map<String, Journal_Entry_Line__c>
        journalLinesByCode(
            Id journalEntryId
        )
    {
        Map<String, Journal_Entry_Line__c> result =
            new Map<String, Journal_Entry_Line__c>();

        for (Journal_Entry_Line__c line : [
            SELECT GL_Account__r.Account_Code__c,
                   Debit_Base__c,
                   Credit_Base__c
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__c = :journalEntryId
        ]) {
            result.put(
                line.GL_Account__r.Account_Code__c,
                line
            );
        }

        return result;
    }

    private static Fixed_Asset__c getAsset(String assetKey) {
        return [
            SELECT Id,
                   Location__c
            FROM Fixed_Asset__c
            WHERE Company_Asset_Key__c = :assetKey
            LIMIT 1
        ];
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
                Name = keyValue,
                Company__c = companyId,
                Company_Period_Key__c = keyValue,
                Period_Key__c = keyValue,
                Start_Date__c = startDate,
                End_Date__c = endDate,
                Fiscal_Year__c = 2026,
                Fiscal_Quarter__c = quarter,
                Period_Number__c = periodNumber,
                Status__c = status
            );

        if (status == 'Closed') {
            row.Closed_At__c = System.now();
            row.Closed_By__c = UserInfo.getUserId();
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
                Name = label,
                Company__c = companyId,
                Company_Account_Key__c =
                    String.valueOf(companyId)
                    + '-' + code,
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

    private static User createUser() {
        Profile profileRecord = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String seed =
            String.valueOf(Datetime.now().getTime());

        User row =
            new User(
                Alias = 'g9dmov',
                Email = 'g9d.' + seed + '@example.test',
                EmailEncodingKey = 'UTF-8',
                LastName = 'G9D Asset Movement User',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = profileRecord.Id,
                TimeZoneSidKey = 'Asia/Dhaka',
                Username = 'g9d.' + seed + '@example.test'
            );
        insert row;
        return row;
    }

    private static void assignPermissionSets(User userRecord) {
        Map<String, Id> ids =
            new Map<String, Id>();

        for (PermissionSet row : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN :REQUIRED_PERMISSION_SETS
        ]) {
            ids.put(row.Name, row.Id);
        }

        System.assertEquals(
            REQUIRED_PERMISSION_SETS.size(),
            ids.size(),
            'G9D dependency Permission Sets must exist.'
        );

        List<PermissionSetAssignment> assignments =
            new List<PermissionSetAssignment>();

        for (String permissionSetName : REQUIRED_PERMISSION_SETS) {
            assignments.add(
                new PermissionSetAssignment(
                    AssigneeId = userRecord.Id,
                    PermissionSetId = ids.get(permissionSetName)
                )
            );
        }

        insert assignments;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'G9D Asset Movement User'
            LIMIT 1
        ];
    }
}
