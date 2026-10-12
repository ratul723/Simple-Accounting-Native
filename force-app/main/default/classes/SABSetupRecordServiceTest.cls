@IsTest
private class SABSetupRecordServiceTest {

    private static final String ADMIN_LAST_NAME = 'SAB G22S Setup Admin';

    @TestSetup
    static void setupData() {
        SABAppShellTestFixture.createUser('sabg22s', ADMIN_LAST_NAME, new List<String>{
            'SAB_App_User', 'SAB_Create_Accounting_Company_Action', 'SAB_Manage_Company_Setup_Action' });
        SABTestGovernor.assertSetupWithin(50);
    }

    private static User admin() {
        return [SELECT Id FROM User WHERE LastName = :ADMIN_LAST_NAME WITH SYSTEM_MODE LIMIT 1];
    }

    private static SABSetupRecordService.CompanyRequest companyRequest(String key) {
        SABSetupRecordService.CompanyRequest r = new SABSetupRecordService.CompanyRequest();
        r.name = 'Harbourline ' + key;
        r.companyKey = key;
        r.countryCode = 'au';
        r.functionalCurrency = 'aud';
        r.fiscalYearStartMonth = 7;
        return r;
    }

    @IsTest
    static void createCompanyGrantsTheCreatorAndReplays() {
        User user = admin();
        Id companyId;
        Id replayId;
        String duplicate;
        System.runAs(user) {
            Test.startTest();
            companyId = SABSetupRecordService.createCompany(companyRequest('G22S'), 'G22S-CREATE');
            replayId = SABSetupRecordService.createCompany(companyRequest('G22S'), 'G22S-CREATE');
            try {
                SABSetupRecordService.createCompany(companyRequest('G22S'), 'G22S-CREATE-2');
            } catch (SABSetupRecordService.SetupRecordException ex) {
                duplicate = ex.getMessage();
            }
            Test.stopTest();
        }
        Accounting_Company__c company = [SELECT Name__c, Country_Code__c, Functional_Currency__c, Setup_Status__c, Fiscal_Calendar_Type__c
            FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE];
        System.assertEquals('AU', company.Country_Code__c, 'Country is upper-cased.');
        System.assertEquals('AUD', company.Functional_Currency__c, 'Currency is normalised.');
        System.assertEquals('In Progress', company.Setup_Status__c, 'New companies start in setup.');
        System.assertEquals('Calendar', company.Fiscal_Calendar_Type__c, 'Calendar by default.');
        System.assertEquals(companyId, replayId, 'The same request key returns the same company.');
        System.assertEquals('Company key G22S is already used.', duplicate, 'Company keys are unique.');
        Company_User_Access__c grant = [SELECT Role__c, Is_Active__c FROM Company_User_Access__c
            WHERE Company__c = :companyId AND User__c = :user.Id WITH SYSTEM_MODE];
        System.assert(grant.Is_Active__c, 'The creator holds an active grant.');
        System.assertEquals('Finance Manager', grant.Role__c, 'The creator is the finance manager.');
        System.assertEquals(1, [SELECT COUNT() FROM Business_Action__c WHERE Request_Key__c = 'G22S-CREATE' WITH SYSTEM_MODE], 'Audited once.');
    }

    @IsTest
    static void foundationRecordsAreCreatedEditedAndListed() {
        User user = admin();
        Map<String, Integer> counts = new Map<String, Integer>();
        String readyMessage;
        String renamed;
        System.runAs(user) {
            Id companyId = SABSetupRecordService.createCompany(companyRequest('G22F'), 'G22F-CREATE');
            Test.startTest();
            SABSetupRecordService.CompanyRequest profile = companyRequest('G22F');
            profile.companyId = companyId;
            profile.name = 'Harbourline Renamed';
            SABSetupRecordService.saveCompany(profile, 'G22F-PROFILE');
            profile.setupStatus = 'Active';
            try {
                SABSetupRecordService.saveCompany(profile, 'G22F-ACTIVE');
            } catch (SABSetupRecordService.SetupRecordException ex) {
                readyMessage = ex.getMessage();
            }
            SABSetupRecordService.PeriodRequest period = new SABSetupRecordService.PeriodRequest();
            period.companyId = companyId;
            period.periodKey = 'FY27-P01';
            period.startDate = Date.newInstance(2026, 7, 1);
            period.endDate = Date.newInstance(2026, 7, 31);
            period.fiscalYear = 2027;
            period.periodNumber = 1;
            Id periodId = SABSetupRecordService.savePeriod(period, 'G22F-PERIOD');
            period.periodId = periodId;
            period.endDate = Date.newInstance(2026, 7, 31);
            SABSetupRecordService.savePeriod(period, 'G22F-PERIOD-EDIT');

            SABSetupRecordService.AccountRequest account = new SABSetupRecordService.AccountRequest();
            account.companyId = companyId;
            account.code = '1000';
            account.name = 'Operating bank';
            account.accountType = 'Asset';
            account.normalBalance = 'Debit';
            account.controlType = 'Bank';
            account.isControlAccount = true;
            account.cashFlowCategory = 'Cash';
            SABSetupRecordService.saveAccount(account, 'G22F-ACCOUNT');

            SABSetupRecordService.SequenceRequest sequence = new SABSetupRecordService.SequenceRequest();
            sequence.companyId = companyId;
            sequence.documentType = 'Invoice';
            sequence.fiscalSeries = 'FY27';
            sequence.prefix = 'INV-';
            sequence.minimumDigits = 6;
            sequence.nextNumber = 1;
            SABSetupRecordService.saveSequence(sequence, 'G22F-SEQUENCE');

            SABSetupRecordService.FeatureRequest feature = new SABSetupRecordService.FeatureRequest();
            feature.companyId = companyId;
            feature.featureKey = 'payroll';
            feature.enabled = true;
            SABSetupRecordService.saveFeature(feature, 'G22F-FEATURE');

            for (String kind : new List<String>{ 'company', 'period', 'account', 'sequence', 'feature' }) {
                counts.put(kind, SABSetupRecordService.getSetupRecords(companyId, kind).size());
            }
            renamed = [SELECT Name__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE].Name__c;
            Test.stopTest();
        }
        System.assertEquals(1, counts.get('company'), 'The company profile.');
        System.assertEquals(1, counts.get('period'), 'One period.');
        System.assertEquals(1, counts.get('account'), 'One GL account.');
        System.assertEquals(1, counts.get('sequence'), 'One sequence.');
        System.assertEquals(1, counts.get('feature'), 'One feature.');
        System.assertEquals('Harbourline Renamed', renamed, 'Profile saved.');
        System.assert(readyMessage != null && readyMessage.startsWith('Core setup is not ready'), 'Active needs a passing setup check.');
        GL_Account__c saved = [SELECT Company_Account_Key__c, Control_Type__c FROM GL_Account__c WHERE Account_Code__c = '1000'
            AND Company__r.Company_Key__c = 'G22F' WITH SYSTEM_MODE];
        System.assertEquals('G22F-1000', saved.Company_Account_Key__c, 'Account key from the company key.');
        System.assertEquals('G22F-PAYROLL', [SELECT Company_Feature_Key__c FROM Company_Feature__c WHERE Feature_Key__c = 'PAYROLL'
            AND Company__r.Company_Key__c = 'G22F' WITH SYSTEM_MODE].Company_Feature_Key__c, 'Feature keys are upper-cased.');
    }

    @IsTest
    static void validationAndPermissionsAreEnforced() {
        User user = admin();
        User outsider = SABAppShellTestFixture.createUser('sabg22o', 'SAB G22S Outsider', new List<String>{ 'SAB_App_User' });
        List<String> messages = new List<String>();
        Test.startTest();
        System.runAs(user) {
            SABSetupRecordService.CompanyRequest bad = companyRequest('bad key!');
            messages.add(capture(bad, 'G22V-1'));
            bad = companyRequest('G22V');
            bad.countryCode = 'AUS';
            messages.add(capture(bad, 'G22V-2'));
            bad = companyRequest('G22V');
            bad.functionalCurrency = 'DOLLARS';
            messages.add(capture(bad, 'G22V-3'));
            bad = companyRequest('G22V');
            bad.fiscalYearStartMonth = 13;
            messages.add(capture(bad, 'G22V-4'));
            bad = companyRequest('G22V');
            bad.fiscalCalendarType = 'Lunar';
            messages.add(capture(bad, 'G22V-5'));
            messages.add(capture(companyRequest('G22V'), ''));
            try {
                SABSetupRecordService.getSetupRecords(null, 'period');
            } catch (AuraHandledException ex) {
                messages.add(ex.getMessage());
            }
            System.assert(SABSetupRecordService.canManageSetup(), 'Setup admin can manage.');
        }
        System.runAs(outsider) {
            messages.add(capture(companyRequest('G22X'), 'G22X-1'));
            System.assert(!SABSetupRecordService.canManageSetup(), 'Outsider cannot manage.');
        }
        Test.stopTest();
        System.assertEquals('Company key can use letters, numbers, hyphens and underscores, up to 50 characters.', messages[0], 'Key format.');
        System.assertEquals('Country code must be two letters, for example AU.', messages[1], 'Country.');
        System.assertEquals('Functional currency must be a three-letter code, for example AUD.', messages[2], 'Currency.');
        System.assertEquals('Fiscal year start month must be between 1 and 12.', messages[3], 'Month.');
        System.assertEquals('Fiscal calendar type must be Calendar or Custom.', messages[4], 'Calendar.');
        System.assertEquals('A request key of up to 160 characters is required.', messages[5], 'Request key.');
        System.assertEquals('You do not have active access to this Accounting Company.', messages[6], 'Company access.');
        System.assertNotEquals(null, messages[7], 'Creating needs the create permission.');
    }

    @IsTest
    static void recordsOfAnotherCompanyAreRefused() {
        User user = admin();
        String message;
        String kindMessage;
        System.runAs(user) {
            Id first = SABSetupRecordService.createCompany(companyRequest('G22A1'), 'G22A1-CREATE');
            Id second = SABSetupRecordService.createCompany(companyRequest('G22A2'), 'G22A2-CREATE');
            Test.startTest();
            SABSetupRecordService.FeatureRequest feature = new SABSetupRecordService.FeatureRequest();
            feature.companyId = first;
            feature.featureKey = 'BUDGETS';
            Id featureId = SABSetupRecordService.saveFeature(feature, 'G22A1-FEATURE');
            feature.companyId = second;
            feature.featureId = featureId;
            try {
                SABSetupRecordService.saveFeature(feature, 'G22A2-FEATURE');
            } catch (SABSetupRecordService.SetupRecordException ex) {
                message = ex.getMessage();
            }
            try {
                SABSetupRecordService.getSetupRecords(first, 'invoice');
            } catch (AuraHandledException ex) {
                kindMessage = ex.getMessage();
            }
            Test.stopTest();
        }
        System.assertEquals('The record does not belong to this Accounting Company.', message, 'Cross-company edits are refused.');
        System.assertEquals('Unknown setup record type.', kindMessage, 'Only setup kinds are listed.');
    }

    private static String capture(SABSetupRecordService.CompanyRequest request, String key) {
        try {
            SABSetupRecordService.createCompany(request, key);
        } catch (Exception ex) {
            return ex.getMessage();
        }
        return null;
    }
}
