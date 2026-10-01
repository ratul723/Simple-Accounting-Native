@IsTest
private class SABFixedAssetWorkspaceControllerTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Remaining_Fields_Admin',
            'SAB_Fixed_Asset_Manager',
            'SAB_Fixed_Asset_Schedule_Manager',
            'SAB_Fixed_Asset_Workspace_User'
        };

    @TestSetup
    static void setupFixture() {
        User testUser = createUser();
        assignPermissionSets(testUser);

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c = 'G9E Workspace Company',
                    Company_Key__c = 'F9F',
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
                Grant_Key__c = 'G9E-ACCESS',
                Is_Active__c = true,
                Role__c = 'Finance Manager'
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
                    'Asset Gain Loss',
                    'Expense',
                    'Debit'
                );

            insert new Asset_Category__c(
                Name = 'Equipment',
                Company__c = company.Id,
                Category_Key__c = 'F9F-EQUIPMENT',
                Asset_Account__c = assetAccount.Id,
                Accumulated_Depreciation_Account__c =
                    accumulated.Id,
                Depreciation_Expense_Account__c =
                    depreciationExpense.Id,
                Disposal_Gain_Loss_Account__c =
                    disposal.Id,
                Default_Useful_Life_Months__c = 3,
                Allowed_Methods__c = 'Straight Line',
                Is_Active__c = true
            );

            insert new List<Accounting_Period__c>{
                period(
                    company.Id,
                    'F9F-2026-10',
                    Date.newInstance(2026, 10, 1),
                    Date.newInstance(2026, 10, 31),
                    10,
                    4
                ),
                period(
                    company.Id,
                    'F9F-2026-11',
                    Date.newInstance(2026, 11, 1),
                    Date.newInstance(2026, 11, 30),
                    11,
                    4
                ),
                period(
                    company.Id,
                    'F9F-2026-12',
                    Date.newInstance(2026, 12, 1),
                    Date.newInstance(2026, 12, 31),
                    12,
                    4
                )
            };

            SABFixedAssetRegisterService.RegistrationRequest request =
                new SABFixedAssetRegisterService.RegistrationRequest();

            request.companyId = company.Id;
            request.assetName = 'G9E Workspace Laptop';
            request.companyAssetKey = 'F9F-G9E-ASSET-001';
            request.assetCategoryId = [
                SELECT Id
                FROM Asset_Category__c
                WHERE Category_Key__c = 'F9F-EQUIPMENT'
                LIMIT 1
            ].Id;
            request.acquisitionDate =
                Date.newInstance(2026, 10, 1);
            request.inServiceDate =
                Date.newInstance(2026, 10, 1);
            request.functionalCurrencyCost = 120000;
            request.residualValue = 12000;
            request.usefulLifeMonths = 3;
            request.depreciationMethod = 'Straight Line';
            request.assetTag = 'G9E-001';
            request.location = 'Dhaka Office';
            request.initialStatus = 'In Service';

            SABFixedAssetRegisterService.RegistrationResult result =
                SABFixedAssetRegisterService.registerAsset(
                    request
                );

            SABFixedAssetScheduleService.ScheduleRequest scheduleRequest =
                new SABFixedAssetScheduleService.ScheduleRequest();

            scheduleRequest.fixedAssetId =
                result.fixedAssetId;
            scheduleRequest.bookKey = 'PRIMARY';

            SABFixedAssetScheduleService.generateSchedule(
                scheduleRequest
            );
        }
    }

    @IsTest
    static void dashboardAndDetailReturnWorkspaceData() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Company__c company = [
                SELECT Id
                FROM Accounting_Company__c
                WHERE Company_Key__c = 'F9F'
                LIMIT 1
            ];

            Test.startTest();

            SABFixedAssetWorkspaceController.DashboardDTO dashboard =
                SABFixedAssetWorkspaceController.getDashboard(
                    company.Id
                );

            Fixed_Asset__c asset = [
                SELECT Id
                FROM Fixed_Asset__c
                WHERE Company__c = :company.Id
                LIMIT 1
            ];

            SABFixedAssetWorkspaceController.AssetDetailDTO detail =
                SABFixedAssetWorkspaceController.getAssetDetail(
                    asset.Id
                );

            Test.stopTest();

            System.assertEquals(
                1,
                dashboard.totalAssets
            );
            System.assertEquals(
                1,
                dashboard.inServiceAssets
            );
            System.assertEquals(
                Decimal.valueOf('120000.0000'),
                dashboard.grossCost
            );
            System.assertEquals(
                Decimal.valueOf('120000.0000'),
                dashboard.netBookValue
            );
            System.assert(
                dashboard.futurePlannedDepreciation
                    > Decimal.valueOf('0')
            );

            System.assertEquals(
                asset.Id,
                detail.assetId
            );
            System.assertEquals(
                3,
                detail.scheduleLines.size()
            );
            System.assertEquals(
                'OK',
                detail.reconciliation.status
            );
            System.assertEquals(
                0,
                detail.reconciliation.issueCount
            );
        }
    }

    @IsTest
    static void accessibleCompaniesReturnsAuthorizedCompany() {
        User testUser = getUser();

        System.runAs(testUser) {
            Test.startTest();

            List<SABFixedAssetWorkspaceController.CompanyOptionDTO> companies =
                SABFixedAssetWorkspaceController.getAccessibleCompanies();

            Test.stopTest();

            System.assertEquals(
                1,
                companies.size()
            );
            System.assertEquals(
                'G9E Workspace Company',
                companies[0].name
            );
        }
    }

    @IsTest
    static void unauthorizedCompanyIsBlocked() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Company__c otherCompany =
                new Accounting_Company__c(
                    Name__c = 'G9E Unauthorized Company',
                    Company_Key__c = 'F9G',
                    Country_Code__c = 'BD',
                    Functional_Currency__c = 'BDT',
                    Fiscal_Calendar_Type__c = 'Calendar',
                    Fiscal_Year_Start_Month__c = 1,
                    Setup_Status__c = 'Active',
                    Is_Active__c = true
                );
            insert otherCompany;

            System.assertEquals(
                false,
                SABCompanyAccessService.hasCompanyAccess(
                    otherCompany.Id
                )
            );

            Boolean blocked = false;

            try {
                SABFixedAssetWorkspaceController.getDashboard(
                    otherCompany.Id
                );
            } catch (Exception ex) {
                blocked = true;
            }

            System.assertEquals(
                true,
                blocked,
                'The workspace must reject a company for which the current user has no active company access.'
            );
        }
    }

    private static Accounting_Period__c period(
        Id companyId,
        String nameValue,
        Date startDate,
        Date endDate,
        Integer monthNumber,
        Integer quarterNumber
    ) {
        return new Accounting_Period__c(
            Name = nameValue,
            Company__c = companyId,
            Start_Date__c = startDate,
            End_Date__c = endDate,
            Fiscal_Year__c = 2026,
            Fiscal_Quarter__c = quarterNumber,
            Company_Period_Key__c = nameValue,
            Period_Key__c = nameValue,
            Period_Number__c = monthNumber,
            Status__c = 'Open'
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
            String.valueOf(
                Datetime.now().getTime()
            );

        User row =
            new User(
                Alias = 'g9ewsp',
                Email =
                    'g9e.' + seed + '@example.test',
                EmailEncodingKey = 'UTF-8',
                LastName = 'G9E Workspace User',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = profileRecord.Id,
                TimeZoneSidKey = 'Asia/Dhaka',
                Username =
                    'g9e.' + seed + '@example.test'
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
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN :REQUIRED_PERMISSION_SETS
        ]) {
            ids.put(row.Name, row.Id);
        }

        System.assertEquals(
            REQUIRED_PERMISSION_SETS.size(),
            ids.size(),
            'G9E dependency Permission Sets must exist.'
        );

        List<PermissionSetAssignment> assignments =
            new List<PermissionSetAssignment>();

        for (String permissionSetName :
            REQUIRED_PERMISSION_SETS
        ) {
            assignments.add(
                new PermissionSetAssignment(
                    AssigneeId = userRecord.Id,
                    PermissionSetId =
                        ids.get(permissionSetName)
                )
            );
        }

        insert assignments;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'G9E Workspace User'
            LIMIT 1
        ];
    }
}
