@IsTest
private class SABCompanySetupServiceTest {

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
            'sabsetup.'
            + String.valueOf(
                DateTime.now().getTime()
            );

        User u = new User(
            Alias = 'sabset',
            Email = uniqueValue + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Setup User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = uniqueValue + '@example.test'
        );

        insert u;
    }

    private static User targetUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB Setup User'
            LIMIT 1
        ];
    }

    @IsTest
    static void completeCoreSetupIsReady() {
        User u = targetUser();
        Accounting_Company__c company =
            makeCompany('U61', 'Validated');

        grant(company.Id, u.Id, 'SETUP-GRANT-1');

        makePeriod(company.Id, 'U61');
        makeAccount(company.Id, '6100', false, 'None', true);

        insert new Document_Sequence__c(
            Company__c = company.Id,
            Sequence_Key__c = 'SETUP-U61-INV',
            Document_Type__c = 'Invoice',
            Fiscal_Series__c = 'FY2026',
            Prefix__c = 'INV-',
            Minimum_Digits__c = 6,
            Next_Number__c = 1,
            Is_Active__c = true
        );

        System.runAs(u) {
            SABCompanySetupService.SetupResult result =
                SABCompanySetupService.validateCoreSetup(
                    company.Id
                );

            System.assertEquals(
                true,
                result.readyForCoreAccounting
            );
            System.assertEquals(1, result.periodCount);
            System.assertEquals(1, result.openPeriodCount);
            System.assertEquals(1, result.activeGLAccountCount);
            System.assertEquals(1, result.activeSequenceCount);
        }
    }

    @IsTest
    static void missingPeriodAndChartBlockReadiness() {
        User u = targetUser();
        Accounting_Company__c company =
            makeCompany('U62', 'In Progress');

        grant(company.Id, u.Id, 'SETUP-GRANT-2');

        System.runAs(u) {
            SABCompanySetupService.SetupResult result =
                SABCompanySetupService.validateCoreSetup(
                    company.Id
                );

            String errors =
                String.join(result.errors, ' ');

            System.assertEquals(
                false,
                result.readyForCoreAccounting
            );
            System.assert(
                errors.contains('Accounting Period')
            );
            System.assert(
                errors.contains('active GL Account')
            );
        }
    }

    @IsTest
    static void enabledFeatureMustBeValid() {
        User u = targetUser();
        Accounting_Company__c company =
            makeCompany('U63', 'Validated');

        grant(company.Id, u.Id, 'SETUP-GRANT-3');
        makePeriod(company.Id, 'U63');
        makeAccount(company.Id, '6300', false, 'None', true);

        insert new Company_Feature__c(
            Company__c = company.Id,
            Company_Feature_Key__c = 'U63|PROJECTS',
            Feature_Key__c = 'PROJECTS',
            Enabled__c = true,
            Configuration_Status__c = 'In Progress'
        );

        System.runAs(u) {
            SABCompanySetupService.SetupResult result =
                SABCompanySetupService.validateCoreSetup(
                    company.Id
                );

            System.assertEquals(
                false,
                result.readyForCoreAccounting
            );

            System.assert(
                String.join(result.errors, ' ').contains('Configuration Status = Valid')
            );
        }
    }

    @IsTest
    static void invalidControlAccountBlocksReadiness() {
        User u = targetUser();
        Accounting_Company__c company =
            makeCompany('U64', 'Validated');

        grant(company.Id, u.Id, 'SETUP-GRANT-4');
        makePeriod(company.Id, 'U64');
        makeAccount(company.Id, '6400', true, 'AR', true);

        System.runAs(u) {
            SABCompanySetupService.SetupResult result =
                SABCompanySetupService.validateCoreSetup(
                    company.Id
                );

            System.assertEquals(
                false,
                result.readyForCoreAccounting
            );

            System.assert(
                String.join(result.errors, ' ').contains('cannot allow manual posting')
            );
        }
    }

    @IsTest
    static void noSequenceIsWarningNotCoreBlocker() {
        User u = targetUser();
        Accounting_Company__c company =
            makeCompany('U65', 'Validated');

        grant(company.Id, u.Id, 'SETUP-GRANT-5');
        makePeriod(company.Id, 'U65');
        makeAccount(company.Id, '6500', false, 'None', true);

        System.runAs(u) {
            SABCompanySetupService.SetupResult result =
                SABCompanySetupService.validateCoreSetup(
                    company.Id
                );

            System.assertEquals(
                true,
                result.readyForCoreAccounting
            );

            System.assert(
                String.join(result.warnings, ' ').contains('No active Document Sequence')
            );
        }
    }

    @IsTest
    static void unauthorizedUserCannotValidateSetup() {
        User u = targetUser();
        Accounting_Company__c company =
            makeCompany('U66', 'Validated');

        System.runAs(u) {
            Boolean thrown = false;

            try {
                SABCompanySetupService.validateCoreSetup(
                    company.Id
                );
            } catch (Exception ex) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }
    }

    private static Accounting_Company__c makeCompany(
        String keyValue,
        String setupStatus
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c = 'Setup ' + keyValue,
                Company_Key__c = keyValue,
                Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT',
                Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = setupStatus,
                Created_Setup_Version__c = 'STEP-6',
                Is_Active__c = true
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
            Company__c = companyId,
            User__c = userId,
            Effective_From__c = Date.today(),
            Grant_Key__c = keyValue,
            Is_Active__c = true,
            Role__c = 'Finance Manager'
        );
    }

    private static void makePeriod(
        Id companyId,
        String suffixValue
    ) {
        insert new Accounting_Period__c(
            Name = 'Period ' + suffixValue,
            Company__c = companyId,
            Company_Period_Key__c = 'CP-' + suffixValue,
            Period_Key__c = 'P-' + suffixValue,
            Start_Date__c = Date.newInstance(2026, 9, 1),
            End_Date__c = Date.newInstance(2026, 9, 30),
            Fiscal_Year__c = 2026,
            Fiscal_Quarter__c = 3,
            Period_Number__c = 9,
            Status__c = 'Open'
        );
    }

    private static void makeAccount(
        Id companyId,
        String code,
        Boolean isControl,
        String controlType,
        Boolean manualPostingAllowed
    ) {
        insert new GL_Account__c(
            Name = 'Account ' + code,
            Company__c = companyId,
            Company_Account_Key__c =
                String.valueOf(companyId) + '-' + code,
            Account_Code__c = code,
            Account_Type__c = 'Asset',
            Normal_Balance__c = 'Debit',
            Is_Active__c = true,
            Is_Control_Account__c = isControl,
            Control_Type__c = controlType,
            Manual_Posting_Allowed__c = manualPostingAllowed
        );
    }
}
