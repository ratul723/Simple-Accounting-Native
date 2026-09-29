@IsTest
private class SABFixedAssetRegisterServiceTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Remaining_Fields_Admin',
            'SAB_Fixed_Asset_Manager'
        };

    @TestSetup
    static void setupFixture() {
        User testUser = createUser();
        assignPermissionSets(testUser);

        System.runAs(testUser) {
            Accounting_Company__c company =
                makeCompany('F9A');

            insert new Company_User_Access__c(
                Company__c = company.Id,
                User__c = testUser.Id,
                Effective_From__c = Date.today(),
                Grant_Key__c = 'G9A-ACCESS',
                Is_Active__c = true,
                Role__c = 'Finance Manager'
            );

            GL_Account__c assetAccount =
                makeGL(
                    company.Id,
                    '1600',
                    'Computer Equipment',
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
                Name = 'Computer Equipment',
                Company__c = company.Id,
                Category_Key__c = 'F9A-COMPUTERS',
                Asset_Account__c = assetAccount.Id,
                Accumulated_Depreciation_Account__c =
                    accumulated.Id,
                Depreciation_Expense_Account__c =
                    depreciationExpense.Id,
                Disposal_Gain_Loss_Account__c =
                    disposal.Id,
                Default_Useful_Life_Months__c = 36,
                Allowed_Methods__c = 'Straight Line',
                Is_Active__c = true
            );
        }
    }

    @IsTest
    static void manualOpeningAssetRegistersWithoutPosting() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Company__c company =
                getCompany('F9A');

            Asset_Category__c category = [
                SELECT Id
                FROM Asset_Category__c
                WHERE Category_Key__c =
                    'F9A-COMPUTERS'
                LIMIT 1
            ];

            Integer eventsBefore = [
                SELECT COUNT()
                FROM Accounting_Event__c
                WHERE Company__c = :company.Id
            ];

            Integer journalsBefore = [
                SELECT COUNT()
                FROM Journal_Entry__c
                WHERE Company__c = :company.Id
            ];

            SABFixedAssetRegisterService.RegistrationRequest request =
                    new SABFixedAssetRegisterService.RegistrationRequest();

            request.companyId = company.Id;
            request.assetName = 'Laptop 001';
            request.companyAssetKey =
                'F9A-LAPTOP-001';
            request.assetCategoryId =
                category.Id;
            request.acquisitionDate =
                Date.newInstance(2026, 9, 1);
            request.inServiceDate =
                Date.newInstance(2026, 9, 2);
            request.functionalCurrencyCost =
                120000;
            request.residualValue = 12000;
            request.depreciationMethod =
                'Straight Line';
            request.assetTag = 'LT-001';
            request.location = 'Dhaka Office';
            request.initialStatus =
                'In Service';

            Test.startTest();

            SABFixedAssetRegisterService.RegistrationResult result =
                    SABFixedAssetRegisterService.registerAsset(request);

            Test.stopTest();

            System.assertNotEquals(
                null,
                result.fixedAssetId
            );
            System.assertEquals(
                'In Service',
                result.status
            );
            System.assertEquals(
                Decimal.valueOf('120000.0000'),
                result.functionalCurrencyCost
            );
            System.assertEquals(
                false,
                result.sourceBillLinked
            );

            Fixed_Asset__c asset = [
                SELECT Company__c,
                       Asset_Category__c,
                       Functional_Currency_Cost__c,
                       Residual_Value__c,
                       Useful_Life_Months__c,
                       Depreciation_Method__c,
                       Status__c
                FROM Fixed_Asset__c
                WHERE Id = :result.fixedAssetId
            ];

            System.assertEquals(
                36,
                Integer.valueOf(
                    asset.Useful_Life_Months__c
                )
            );

            System.assertEquals(
                eventsBefore,
                [
                    SELECT COUNT()
                    FROM Accounting_Event__c
                    WHERE Company__c = :company.Id
                ]
            );

            System.assertEquals(
                journalsBefore,
                [
                    SELECT COUNT()
                    FROM Journal_Entry__c
                    WHERE Company__c = :company.Id
                ]
            );
        }
    }

    @IsTest
    static void residualCannotExceedCost() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Company__c company =
                getCompany('F9A');

            Asset_Category__c category = [
                SELECT Id
                FROM Asset_Category__c
                WHERE Category_Key__c =
                    'F9A-COMPUTERS'
                LIMIT 1
            ];

            SABFixedAssetRegisterService.RegistrationRequest request =
                    new SABFixedAssetRegisterService.RegistrationRequest();

            request.companyId = company.Id;
            request.assetName = 'Invalid Asset';
            request.companyAssetKey =
                'F9A-INVALID-001';
            request.assetCategoryId =
                category.Id;
            request.acquisitionDate =
                Date.newInstance(2026, 9, 1);
            request.inServiceDate =
                Date.newInstance(2026, 9, 1);
            request.functionalCurrencyCost =
                100;
            request.residualValue = 101;
            request.usefulLifeMonths = 12;
            request.depreciationMethod =
                'Straight Line';
            request.initialStatus =
                'In Service';

            Boolean blocked = false;

            try {
                SABFixedAssetRegisterService.registerAsset(request);
            } catch (
                SABFixedAssetRegisterService.FixedAssetRegisterException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'Residual Value'
                    );
            }

            System.assertEquals(true, blocked);
        }
    }

    @IsTest
    static void crossCompanyCategoryIsBlocked() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Company__c company =
                getCompany('F9A');

            Accounting_Company__c otherCompany =
                makeCompany('F9B');

            GL_Account__c assetAccount =
                makeGL(
                    otherCompany.Id,
                    '1600',
                    'Other Asset',
                    'Asset',
                    'Debit'
                );

            GL_Account__c accumulated =
                makeGL(
                    otherCompany.Id,
                    '1690',
                    'Other Accumulated Depreciation',
                    'Asset',
                    'Credit'
                );

            GL_Account__c depreciationExpense =
                makeGL(
                    otherCompany.Id,
                    '6200',
                    'Other Depreciation Expense',
                    'Expense',
                    'Debit'
                );

            GL_Account__c disposal =
                makeGL(
                    otherCompany.Id,
                    '7200',
                    'Other Disposal',
                    'Expense',
                    'Debit'
                );

            Asset_Category__c category =
                new Asset_Category__c(
                    Name = 'Other Category',
                    Company__c =
                        otherCompany.Id,
                    Category_Key__c =
                        'F9B-CATEGORY',
                    Asset_Account__c =
                        assetAccount.Id,
                    Accumulated_Depreciation_Account__c =
                        accumulated.Id,
                    Depreciation_Expense_Account__c =
                        depreciationExpense.Id,
                    Disposal_Gain_Loss_Account__c =
                        disposal.Id,
                    Default_Useful_Life_Months__c =
                        24,
                    Allowed_Methods__c =
                        'Straight Line',
                    Is_Active__c = true
                );
            insert category;

            SABFixedAssetRegisterService.RegistrationRequest request =
                    new SABFixedAssetRegisterService.RegistrationRequest();

            request.companyId = company.Id;
            request.assetName = 'Wrong Category Asset';
            request.companyAssetKey =
                'F9A-WRONG-CAT';
            request.assetCategoryId =
                category.Id;
            request.acquisitionDate =
                Date.newInstance(2026, 9, 1);
            request.inServiceDate =
                Date.newInstance(2026, 9, 1);
            request.functionalCurrencyCost =
                1000;
            request.residualValue = 0;
            request.usefulLifeMonths = 12;
            request.depreciationMethod =
                'Straight Line';
            request.initialStatus =
                'In Service';

            Boolean blocked = false;

            try {
                SABFixedAssetRegisterService.registerAsset(request);
            } catch (
                SABFixedAssetRegisterService.FixedAssetRegisterException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'same Accounting Company'
                    );
            }

            System.assertEquals(true, blocked);
        }
    }

    @IsTest
    static void directFixedAssetInsertIsBlocked() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Company__c company =
                getCompany('F9A');

            Asset_Category__c category = [
                SELECT Id
                FROM Asset_Category__c
                WHERE Category_Key__c =
                    'F9A-COMPUTERS'
                LIMIT 1
            ];

            Database.SaveResult result =
                Database.insert(
                    new Fixed_Asset__c(
                        Name = 'Direct Insert',
                        Company__c = company.Id,
                        Company_Asset_Key__c =
                            'F9A-DIRECT',
                        Asset_Category__c =
                            category.Id,
                        Acquisition_Date__c =
                            Date.newInstance(2026, 9, 1),
                        In_Service_Date__c =
                            Date.newInstance(2026, 9, 1),
                        Functional_Currency_Cost__c =
                            500,
                        Residual_Value__c = 0,
                        Useful_Life_Months__c = 12,
                        Depreciation_Method__c =
                            'Straight Line',
                        Status__c = 'In Service'
                    ),
                    false
                );

            System.assertEquals(
                false,
                result.isSuccess()
            );

            System.assert(
                result.getErrors()[0].getMessage().contains(
                        'controlled Fixed Asset service'
                    ),
                result.getErrors()[0].getMessage()
            );
        }
    }

    private static Accounting_Company__c makeCompany(
        String keyValue
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    'G9A Company ' + keyValue,
                Company_Key__c = keyValue,
                Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT',
                Fiscal_Calendar_Type__c =
                    'Calendar',
                Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active',
                Is_Active__c = true
            );
        insert company;
        return company;
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
                Normal_Balance__c =
                    normalBalance,
                Is_Active__c = true,
                Is_Control_Account__c =
                    false,
                Control_Type__c = 'None',
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
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String seed =
            String.valueOf(
                Datetime.now().getTime()
            );

        User row = new User(
            Alias = 'g9aast',
            Email =
                'g9a.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName =
                'G9A Fixed Asset User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profileRecord.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username =
                'g9a.' + seed + '@example.test'
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
            'G9A dependency Permission Sets must exist.'
        );

        List<PermissionSetAssignment> rows =
            new List<PermissionSetAssignment>();

        for (String permissionSetName :
            REQUIRED_PERMISSION_SETS
        ) {
            rows.add(
                new PermissionSetAssignment(
                    AssigneeId = userRecord.Id,
                    PermissionSetId =
                        ids.get(permissionSetName)
                )
            );
        }

        insert rows;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                'G9A Fixed Asset User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getCompany(
        String keyValue
    ) {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c =
                :keyValue
            LIMIT 1
        ];
    }
}
