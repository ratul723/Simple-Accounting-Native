/**
 * G22 setup in the shell: create an Accounting Company and maintain its foundation records without leaving the app.
 *
 *   createCompany   SAB_Create_Accounting_Company   new company In Progress plus a Finance Manager grant for the creator,
 *                                                   so a new user can create a company and then set it up
 *   saveCompany     SAB_Manage_Company_Setup        profile fields; Validated or Active needs a passing core setup check
 *   savePeriod      SAB_Manage_Company_Setup        create (Open) or edit an accounting period
 *   saveAccount     SAB_Manage_Company_Setup        create or edit a GL account
 *   saveSequence    SAB_Manage_Company_Setup        create or edit a document sequence
 *   saveFeature     SAB_Manage_Company_Setup        create or edit a company feature switch
 *   getSetupRecords read                            the company profile or its records of one kind for the setup screens
 *
 * Unique keys are derived from the company key (KEY-2026-07, KEY-4000, KEY-Invoice-FY27, KEY-PAYROLL), as the test
 * fixtures and earlier stages do. Updates still pass the configuration protection triggers, which refuse changes
 * that would alter posted history. Every save is idempotent by request key and audited in Business_Action__c.
 */
public with sharing class SABSetupRecordService {
    public class SetupRecordException extends Exception {}

    private static final String CREATE_PERMISSION = 'SAB_Create_Accounting_Company';
    private static final String MANAGE_PERMISSION = 'SAB_Manage_Company_Setup';
    private static final String SOURCE_TYPE = 'Setup';
    private static final Set<String> READY_STATUSES = new Set<String>{ 'Validated', 'Active' };
    private static final Set<String> SETUP_STATUSES = new Set<String>{ 'Not Started', 'In Progress', 'Validated', 'Active', 'Suspended' };
    private static final Set<String> KINDS = new Set<String>{ 'company', 'period', 'account', 'sequence', 'feature' };
    private static final Pattern KEY_PATTERN = Pattern.compile('^[A-Za-z0-9][A-Za-z0-9_-]{0,49}$');
    private static final Pattern COUNTRY_PATTERN = Pattern.compile('^[A-Z]{2}$');

    public class CompanyRequest {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String companyKey { get; set; }
        @AuraEnabled public String countryCode { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public String fiscalCalendarType { get; set; }
        @AuraEnabled public Integer fiscalYearStartMonth { get; set; }
        @AuraEnabled public String setupStatus { get; set; }
        @AuraEnabled public Boolean isActive { get; set; }
    }

    public class PeriodRequest {
        @AuraEnabled public Id periodId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String periodKey { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date endDate { get; set; }
        @AuraEnabled public Integer fiscalYear { get; set; }
        @AuraEnabled public Integer fiscalQuarter { get; set; }
        @AuraEnabled public Integer periodNumber { get; set; }
    }

    public class AccountRequest {
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String code { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String accountType { get; set; }
        @AuraEnabled public String normalBalance { get; set; }
        @AuraEnabled public String controlType { get; set; }
        @AuraEnabled public Boolean isControlAccount { get; set; }
        @AuraEnabled public Boolean manualPostingAllowed { get; set; }
        @AuraEnabled public Boolean isActive { get; set; }
        @AuraEnabled public String cashFlowCategory { get; set; }
        @AuraEnabled public String reportGroup { get; set; }
    }

    public class SequenceRequest {
        @AuraEnabled public Id sequenceId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String documentType { get; set; }
        @AuraEnabled public String fiscalSeries { get; set; }
        @AuraEnabled public String prefix { get; set; }
        @AuraEnabled public Integer minimumDigits { get; set; }
        @AuraEnabled public Integer nextNumber { get; set; }
        @AuraEnabled public Boolean isActive { get; set; }
    }

    public class FeatureRequest {
        @AuraEnabled public Id featureId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String featureKey { get; set; }
        @AuraEnabled public Boolean enabled { get; set; }
        @AuraEnabled public String configurationStatus { get; set; }
    }

    // ---------------------------------------------------------------- company

    @AuraEnabled
    public static Id createCompany(CompanyRequest request, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(CREATE_PERMISSION, 'You do not have permission to create Accounting Companies.');
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, 'COMPANY_CREATED');
        }
        if (request == null) {
            throw new SetupRecordException('Company details are required.');
        }
        String companyKey = requireText(request.companyKey, 'Company key');
        if (!KEY_PATTERN.matcher(companyKey).matches()) {
            throw new SetupRecordException('Company key can use letters, numbers, hyphens and underscores, up to 50 characters.');
        }
        if (store.companyKeyExists(companyKey)) {
            throw new SetupRecordException('Company key ' + companyKey + ' is already used.');
        }
        Accounting_Company__c company = new Accounting_Company__c(Company_Key__c = companyKey, Setup_Status__c = 'In Progress',
            Is_Active__c = true);
        applyProfile(company, request);
        Company_User_Access__c ownerGrant = new Company_User_Access__c(User__c = UserInfo.getUserId(), Is_Active__c = true,
            Effective_From__c = Date.today(), Role__c = 'Finance Manager',
            Grant_Key__c = (companyKey + '-OWNER-' + UserInfo.getUserId()).left(160));
        new Writer().createCompany(company, ownerGrant, audit(null, 'COMPANY_CREATED', key, null, 'Created ' + company.Name__c));
        return company.Id;
    }

    @AuraEnabled
    public static Id saveCompany(CompanyRequest request, String requestKey) {
        String key = requireKey(requestKey);
        if (request == null || request.companyId == null) {
            throw new SetupRecordException('Accounting Company is required.');
        }
        assertManage(request.companyId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, 'SETUP_COMPANY_SAVED');
        }
        Accounting_Company__c company = new Accounting_Company__c(Id = request.companyId);
        applyProfile(company, request);
        if (String.isNotBlank(request.setupStatus)) {
            if (!SETUP_STATUSES.contains(request.setupStatus)) {
                throw new SetupRecordException('Setup status is not valid.');
            }
            if (READY_STATUSES.contains(request.setupStatus)) {
                assertCoreSetupPasses(request.companyId);
            }
            company.Setup_Status__c = request.setupStatus;
        }
        if (request.isActive != null) {
            company.Is_Active__c = request.isActive;
        }
        new Writer().save(company, audit(request.companyId, 'SETUP_COMPANY_SAVED', key, request.companyId, 'Company profile saved'));
        return company.Id;
    }

    private static void applyProfile(Accounting_Company__c company, CompanyRequest request) {
        String name = requireText(request.name, 'Name');
        if (name.length() > 80) {
            throw new SetupRecordException('Name cannot exceed 80 characters.');
        }
        String country = requireText(request.countryCode, 'Country code').toUpperCase();
        if (!COUNTRY_PATTERN.matcher(country).matches()) {
            throw new SetupRecordException('Country code must be two letters, for example AU.');
        }
        String currencyCode;
        try {
            currencyCode = SABMoneyService.normalizeCurrencyCode(requireText(request.functionalCurrency, 'Functional currency'));
        } catch (SABMoneyService.MoneyException ex) {
            throw new SetupRecordException('Functional currency must be a three-letter code, for example AUD.');
        }
        if (request.fiscalYearStartMonth == null || request.fiscalYearStartMonth < 1 || request.fiscalYearStartMonth > 12) {
            throw new SetupRecordException('Fiscal year start month must be between 1 and 12.');
        }
        String calendar = String.isBlank(request.fiscalCalendarType) ? 'Calendar' : request.fiscalCalendarType;
        if (calendar != 'Calendar' && calendar != 'Custom') {
            throw new SetupRecordException('Fiscal calendar type must be Calendar or Custom.');
        }
        company.Name__c = name;
        company.Country_Code__c = country;
        company.Functional_Currency__c = currencyCode;
        company.Fiscal_Year_Start_Month__c = request.fiscalYearStartMonth;
        company.Fiscal_Calendar_Type__c = calendar;
    }

    private static void assertCoreSetupPasses(Id companyId) {
        SABCompanySetupService.SetupResult result = SABCompanySetupService.validateCoreSetup(companyId);
        if (!result.errors.isEmpty()) {
            throw new SetupRecordException('Core setup is not ready: ' + String.join(result.errors, ' '));
        }
    }

    // ----------------------------------------------------------- foundation

    @AuraEnabled
    public static Id savePeriod(PeriodRequest request, String requestKey) {
        String key = requireKey(requestKey);
        if (request == null || request.companyId == null) {
            throw new SetupRecordException('Accounting Company is required.');
        }
        assertManage(request.companyId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, 'SETUP_PERIOD_SAVED');
        }
        String periodKey = requireText(request.periodKey, 'Period key');
        if (request.startDate == null || request.endDate == null || request.endDate < request.startDate) {
            throw new SetupRecordException('Start and end dates are required and the end cannot be before the start.');
        }
        if (request.fiscalYear == null || request.periodNumber == null || request.periodNumber < 1 || request.periodNumber > 13) {
            throw new SetupRecordException('Fiscal year and a period number from 1 to 13 are required.');
        }
        Integer quarter = request.fiscalQuarter == null ? Math.min(4, ((request.periodNumber - 1) / 3) + 1) : request.fiscalQuarter;
        Accounting_Period__c period = new Accounting_Period__c(Id = request.periodId, Period_Key__c = periodKey,
            Start_Date__c = request.startDate, End_Date__c = request.endDate, Fiscal_Year__c = request.fiscalYear,
            Fiscal_Quarter__c = quarter, Period_Number__c = request.periodNumber);
        if (request.periodId == null) {
            period.Company__c = request.companyId;
            period.Name = periodKey.left(80);
            period.Company_Period_Key__c = (store.companyKey(request.companyId) + '-' + periodKey).left(160);
            period.Status__c = 'Open';
        } else {
            store.assertBelongs(Accounting_Period__c.SObjectType, request.periodId, request.companyId);
        }
        new Writer().save(period, audit(request.companyId, 'SETUP_PERIOD_SAVED', key, null, 'Period ' + periodKey + ' saved'));
        return period.Id;
    }

    @AuraEnabled
    public static Id saveAccount(AccountRequest request, String requestKey) {
        String key = requireKey(requestKey);
        if (request == null || request.companyId == null) {
            throw new SetupRecordException('Accounting Company is required.');
        }
        assertManage(request.companyId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, 'SETUP_ACCOUNT_SAVED');
        }
        String code = requireText(request.code, 'Account code');
        String name = requireText(request.name, 'Account name');
        GL_Account__c account = new GL_Account__c(Id = request.accountId, Account_Code__c = code, Name = name.left(80),
            Account_Type__c = requireText(request.accountType, 'Account type'), Normal_Balance__c = requireText(request.normalBalance, 'Normal balance'),
            Control_Type__c = String.isBlank(request.controlType) ? 'None' : request.controlType,
            Is_Control_Account__c = request.isControlAccount == true, Manual_Posting_Allowed__c = request.manualPostingAllowed != false,
            Is_Active__c = request.isActive != false, Cash_Flow_Category__c = String.isBlank(request.cashFlowCategory) ? null : request.cashFlowCategory,
            Report_Group__c = String.isBlank(request.reportGroup) ? null : request.reportGroup);
        if (request.accountId == null) {
            account.Company__c = request.companyId;
            account.Company_Account_Key__c = (store.companyKey(request.companyId) + '-' + code).left(140);
        } else {
            store.assertBelongs(GL_Account__c.SObjectType, request.accountId, request.companyId);
        }
        new Writer().save(account, audit(request.companyId, 'SETUP_ACCOUNT_SAVED', key, null, 'GL account ' + code + ' saved'));
        return account.Id;
    }

    @AuraEnabled
    public static Id saveSequence(SequenceRequest request, String requestKey) {
        String key = requireKey(requestKey);
        if (request == null || request.companyId == null) {
            throw new SetupRecordException('Accounting Company is required.');
        }
        assertManage(request.companyId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, 'SETUP_SEQUENCE_SAVED');
        }
        String documentType = requireText(request.documentType, 'Document type');
        String series = requireText(request.fiscalSeries, 'Fiscal series');
        if (request.nextNumber == null || request.nextNumber < 1) {
            throw new SetupRecordException('Next number must be 1 or more.');
        }
        Document_Sequence__c sequence = new Document_Sequence__c(Id = request.sequenceId, Prefix__c = request.prefix,
            Minimum_Digits__c = request.minimumDigits, Is_Active__c = request.isActive != false);
        if (request.sequenceId == null) {
            sequence.Company__c = request.companyId;
            sequence.Document_Type__c = documentType;
            sequence.Fiscal_Series__c = series;
            sequence.Next_Number__c = request.nextNumber;
            sequence.Sequence_Key__c = (store.companyKey(request.companyId) + '-' + documentType + '-' + series).left(180);
        } else {
            store.assertBelongs(Document_Sequence__c.SObjectType, request.sequenceId, request.companyId);
        }
        new Writer().save(sequence, audit(request.companyId, 'SETUP_SEQUENCE_SAVED', key, null, documentType + ' sequence saved'));
        return sequence.Id;
    }

    @AuraEnabled
    public static Id saveFeature(FeatureRequest request, String requestKey) {
        String key = requireKey(requestKey);
        if (request == null || request.companyId == null) {
            throw new SetupRecordException('Accounting Company is required.');
        }
        assertManage(request.companyId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, 'SETUP_FEATURE_SAVED');
        }
        String featureKey = requireText(request.featureKey, 'Feature key').toUpperCase();
        Company_Feature__c feature = new Company_Feature__c(Id = request.featureId, Enabled__c = request.enabled == true,
            Configuration_Status__c = String.isBlank(request.configurationStatus) ? 'Not Configured' : request.configurationStatus);
        if (request.enabled == true) {
            feature.Enabled_At__c = System.now();
            feature.Enabled_By__c = UserInfo.getUserId();
        }
        if (request.featureId == null) {
            feature.Company__c = request.companyId;
            feature.Feature_Key__c = featureKey;
            feature.Company_Feature_Key__c = (store.companyKey(request.companyId) + '-' + featureKey).left(180);
        } else {
            store.assertBelongs(Company_Feature__c.SObjectType, request.featureId, request.companyId);
        }
        new Writer().save(feature, audit(request.companyId, 'SETUP_FEATURE_SAVED', key, null, featureKey + ' feature saved'));
        return feature.Id;
    }

    // ------------------------------------------------------------------ read

    @AuraEnabled
    public static List<Map<String, Object>> getSetupRecords(Id companyId, String kind) {
        if (companyId == null || !SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw auraError('You do not have active access to this Accounting Company.');
        }
        if (!KINDS.contains(kind)) {
            throw auraError('Unknown setup record type.');
        }
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        try {
            for (SObject record : records(companyId, kind)) {
                rows.add(record.getPopulatedFieldsAsMap());
            }
        } catch (QueryException ex) {
            throw auraError('Setup records could not be loaded: ' + ex.getMessage());
        }
        return rows;
    }

    @AuraEnabled
    public static Boolean canManageSetup() {
        return SABPermissionService.hasPermission(MANAGE_PERMISSION);
    }

    private static List<SObject> records(Id companyId, String kind) {
        if (kind == 'company') {
            return [SELECT Id, Name__c, Company_Key__c, Country_Code__c, Functional_Currency__c, Fiscal_Calendar_Type__c,
                        Fiscal_Year_Start_Month__c, Setup_Status__c, Is_Active__c
                    FROM Accounting_Company__c WHERE Id = :companyId WITH USER_MODE LIMIT 1];
        }
        if (kind == 'period') {
            return [SELECT Id, Period_Key__c, Start_Date__c, End_Date__c, Fiscal_Year__c, Fiscal_Quarter__c, Period_Number__c, Status__c
                    FROM Accounting_Period__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Start_Date__c LIMIT 200];
        }
        if (kind == 'account') {
            return [SELECT Id, Account_Code__c, Name, Account_Type__c, Normal_Balance__c, Control_Type__c, Is_Control_Account__c,
                        Manual_Posting_Allowed__c, Is_Active__c, Cash_Flow_Category__c, Report_Group__c
                    FROM GL_Account__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Account_Code__c LIMIT 1000];
        }
        if (kind == 'sequence') {
            return [SELECT Id, Document_Type__c, Fiscal_Series__c, Prefix__c, Minimum_Digits__c, Next_Number__c, Is_Active__c
                    FROM Document_Sequence__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Document_Type__c LIMIT 200];
        }
        return [SELECT Id, Feature_Key__c, Enabled__c, Configuration_Status__c
                FROM Company_Feature__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Feature_Key__c LIMIT 200];
    }

    // --------------------------------------------------------------- helpers

    private static void assertManage(Id companyId) {
        SABPermissionService.assertPermission(MANAGE_PERMISSION, 'You do not have permission to manage company setup.');
        SABCompanyAccessService.assertCompanyAccess(companyId);
    }

    private static String requireText(String value, String label) {
        if (String.isBlank(value)) {
            throw new SetupRecordException(label + ' is required.');
        }
        return value.trim();
    }

    private static String requireKey(String requestKey) {
        if (String.isBlank(requestKey) || requestKey.trim().length() > 160) {
            throw new SetupRecordException('A request key of up to 160 characters is required.');
        }
        return requestKey.trim();
    }

    private static Id replay(Business_Action__c prior, String actionName) {
        if (prior.Action__c != actionName) {
            throw new SetupRecordException('Request key has already been used for a different setup action.');
        }
        return Id.valueOf(prior.Source_Record_Id__c);
    }

    private static Business_Action__c audit(Id companyId, String actionName, String key, Id recordId, String reason) {
        return new Business_Action__c(Company__c = companyId, Action__c = actionName, Actor__c = UserInfo.getUserId(),
            Action_At__c = System.now(), Reason__c = reason, Request_Key__c = key, Source_Type__c = SOURCE_TYPE,
            Source_Record_Id__c = recordId == null ? null : String.valueOf(recordId), Source_Version__c = 1);
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }

    // System reads after the permission and company checks above: the company key and request-key replay must be
    // found even when the user's sharing would hide the audit row.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c FROM Business_Action__c
                WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }

        Boolean companyKeyExists(String companyKey) {
            return [SELECT COUNT() FROM Accounting_Company__c WHERE Company_Key__c = :companyKey WITH SYSTEM_MODE] > 0;
        }

        String companyKey(Id companyId) {
            return [SELECT Company_Key__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE LIMIT 1].Company_Key__c;
        }

        void assertBelongs(Schema.SObjectType objectType, Id recordId, Id companyId) {
            String objectName = objectType.getDescribe(SObjectDescribeOptions.DEFERRED).getName();
            List<SObject> rows = Database.queryWithBinds('SELECT Company__c FROM ' + objectName + ' WHERE Id = :recordId LIMIT 1',
                new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.SYSTEM_MODE);
            if (rows.isEmpty() || (Id) rows[0].get('Company__c') != companyId) {
                throw new SetupRecordException('The record does not belong to this Accounting Company.');
            }
        }
    }

    // System writes after the permission and company checks above; field-level edit rights for setup fields are
    // granted by the setup permission, and the configuration protection triggers still run.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void createCompany(Accounting_Company__c company, Company_User_Access__c ownerGrant, Business_Action__c audit) {
            insert as system company;
            ownerGrant.Company__c = company.Id;
            insert as system ownerGrant;
            audit.Company__c = company.Id;
            audit.Source_Record_Id__c = String.valueOf(company.Id);
            insert as system audit;
        }

        void save(SObject record, Business_Action__c audit) {
            if (record.Id == null) {
                insert as system record;
            } else {
                update as system record;
            }
            audit.Source_Record_Id__c = String.valueOf(record.Id);
            insert as system audit;
        }
    }
}
