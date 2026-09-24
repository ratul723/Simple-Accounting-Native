@IsTest
private class SABCompanySetupWizardTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    @TestSetup
    static void setupUser() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String uniqueValue =
            'sabwiz.'
            + String.valueOf(
                DateTime.now().getTime()
            );

        User u = new User(
            Alias = 'sabwiz',
            Email =
                uniqueValue + '@example.test',
            EmailEncodingKey =
                'UTF-8',
            LastName =
                'SAB Setup Wizard User',
            LanguageLocaleKey =
                'en_US',
            LocaleSidKey =
                'en_US',
            ProfileId =
                p.Id,
            TimeZoneSidKey =
                'Asia/Dhaka',
            Username =
                uniqueValue + '@example.test'
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
    static void completeSetupReturnsReadyState() {
        User u =
            targetUser();

        Accounting_Company__c company =
            makeCompany(
                'G1',
                'Validated'
            );

        grant(
            company.Id,
            u.Id,
            'WIZ-G1'
        );

        makePeriod(
            company.Id,
            'G1'
        );

        makeAccount(
            company.Id,
            '6100'
        );

        insert new Document_Sequence__c(
            Company__c =
                company.Id,
            Sequence_Key__c =
                'WIZ-G1-INV',
            Document_Type__c =
                'Invoice',
            Fiscal_Series__c =
                'FY2026',
            Prefix__c =
                'INV-',
            Minimum_Digits__c =
                6,
            Next_Number__c =
                1,
            Is_Active__c =
                true
        );

        insert new Company_Feature__c(
            Company__c =
                company.Id,
            Company_Feature_Key__c =
                'G1|PROJECTS',
            Feature_Key__c =
                'PROJECTS',
            Enabled__c =
                true,
            Configuration_Status__c =
                'Valid'
        );

        System.runAs(u) {
            Test.startTest();

            SABCompanySetupWizardController.SetupStateDTO result =
                SABCompanySetupWizardController.getSetupState(
                    company.Id
                );

            Test.stopTest();

            System.assertEquals(
                company.Id,
                result.companyId
            );
            System.assertEquals(
                true,
                result.readyForCoreAccounting
            );
            System.assertEquals(
                1,
                result.periodCount
            );
            System.assertEquals(
                1,
                result.openPeriodCount
            );
            System.assertEquals(
                1,
                result.activeGLAccountCount
            );
            System.assertEquals(
                1,
                result.activeSequenceCount
            );
            System.assertEquals(
                1,
                result.enabledFeatureCount
            );
            System.assertEquals(
                0,
                result.errors.size()
            );
        }
    }

    @IsTest
    static void incompleteSetupReturnsServiceErrors() {
        User u =
            targetUser();

        Accounting_Company__c company =
            makeCompany(
                'G2',
                'In Progress'
            );

        grant(
            company.Id,
            u.Id,
            'WIZ-G2'
        );

        System.runAs(u) {
            Test.startTest();

            SABCompanySetupWizardController.SetupStateDTO result =
                SABCompanySetupWizardController.getSetupState(
                    company.Id
                );

            Test.stopTest();

            System.assertEquals(
                false,
                result.readyForCoreAccounting
            );

            String errors =
                String.join(
                    result.errors,
                    ' '
                );

            System.assert(
                errors.contains(
                    'Accounting Period'
                )
            );

            System.assert(
                errors.contains(
                    'active GL Account'
                )
            );

            System.assert(
                result.warnings.size() > 0
            );
        }
    }

    @IsTest
    static void companyAuthorizationIsRequired() {
        User u =
            targetUser();

        Accounting_Company__c company =
            makeCompany(
                'G3',
                'Validated'
            );

        System.runAs(u) {
            Boolean thrown =
                false;

            Test.startTest();

            try {
                SABCompanySetupWizardController.getSetupState(
                    company.Id
                );
            } catch (Exception ex) {
                thrown =
                    true;
            }

            Test.stopTest();

            System.assertEquals(
                true,
                thrown
            );
        }
    }

    private static User targetUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                'SAB Setup Wizard User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c makeCompany(
        String keyValue,
        String setupStatus
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    'Setup Wizard ' + keyValue,
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
                    setupStatus,
                Created_Setup_Version__c =
                    'STAGE-8G',
                Is_Active__c =
                    true
            );

        insert company;
        return company;
    }

    private static void grant(
        Id companyId,
        Id userId,
        String keyValue
    ) {
        insert new Company_User_Access__c(
            Company__c =
                companyId,
            User__c =
                userId,
            Effective_From__c =
                Date.today(),
            Grant_Key__c =
                keyValue,
            Is_Active__c =
                true,
            Role__c =
                'Finance Manager'
        );
    }

    private static void makePeriod(
        Id companyId,
        String suffixValue
    ) {
        insert new Accounting_Period__c(
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
    }

    private static void makeAccount(
        Id companyId,
        String code
    ) {
        insert new GL_Account__c(
            Name =
                'Account ' + code,
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
    }
}
