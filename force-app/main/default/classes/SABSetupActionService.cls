/**
 * Remaining-tasks batch 1: setup actions the redesigned workspaces were missing.
 *
 *   getOptions            calendar type, the next period start, FX account choices and current FX accounts
 *   generatePeriods       a fiscal year of periods: monthly (any start day), 4-4-5, 4-5-4, 5-4-4 or 13 four-week periods
 *   saveFxAccounts        the four FX gain and loss accounts on the company, creating standard accounts when asked
 *   saveTaxRegistration   create or edit a tax registration
 *   saveParty             create a customer or supplier (account and accounting profile) from document entry
 *
 * Setup actions need SAB_Manage_Company_Setup; parties need create access to accounts and party accounting profiles
 * and are written in user mode. Every action checks the company grant, is idempotent by request key and audited.
 */
public with sharing class SABSetupActionService {
    public class SetupActionException extends Exception {}

    private static final String SETUP_PERMISSION = 'SAB_Manage_Company_Setup';
    public static final List<String> PATTERNS = new List<String>{ 'Monthly', '4-4-5 weeks', '4-5-4 weeks', '5-4-4 weeks', '13 periods of 4 weeks' };

    public class Option {
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public String label { get; set; }

        Option(String value, String label) {
            this.value = value;
            this.label = label;
        }
    }

    public class Options {
        @AuraEnabled public Boolean canManageSetup { get; set; }
        @AuraEnabled public String fiscalCalendarType { get; set; }
        @AuraEnabled public Integer fiscalYearStartMonth { get; set; }
        @AuraEnabled public Date nextPeriodStart { get; set; }
        @AuraEnabled public List<String> patterns { get; set; }
        @AuraEnabled public List<Option> gainAccounts { get; set; }
        @AuraEnabled public List<Option> lossAccounts { get; set; }
        @AuraEnabled public Id unrealizedGainAccountId { get; set; }
        @AuraEnabled public Id unrealizedLossAccountId { get; set; }
        @AuraEnabled public Id realizedGainAccountId { get; set; }
        @AuraEnabled public Id realizedLossAccountId { get; set; }
        @AuraEnabled public String countryCode { get; set; }
        @AuraEnabled public String countryPackVersion { get; set; }
        @AuraEnabled public List<String> filingFrequencies { get; set; }
    }

    public class GenerateRequest {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public Date firstDay { get; set; }
        @AuraEnabled public String pattern { get; set; }
        @AuraEnabled public Integer fiscalYear { get; set; }
    }

    public class FxRequest {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public Id unrealizedGainAccountId { get; set; }
        @AuraEnabled public Id unrealizedLossAccountId { get; set; }
        @AuraEnabled public Id realizedGainAccountId { get; set; }
        @AuraEnabled public Id realizedLossAccountId { get; set; }
        @AuraEnabled public Boolean createMissing { get; set; }
    }

    public class RegistrationRequest {
        @AuraEnabled public Id registrationId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String jurisdiction { get; set; }
        @AuraEnabled public String identifier { get; set; }
        @AuraEnabled public String filingFrequency { get; set; }
        @AuraEnabled public Date effectiveFrom { get; set; }
        @AuraEnabled public Date effectiveTo { get; set; }
        @AuraEnabled public String countryPackVersion { get; set; }
        @AuraEnabled public Boolean active { get; set; }
    }

    public class PartyRequest {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public Boolean isCustomer { get; set; }
        @AuraEnabled public Boolean isSupplier { get; set; }
        @AuraEnabled public String taxRegistrationNumber { get; set; }
        @AuraEnabled public Decimal creditLimit { get; set; }
    }

    // ---------------------------------------------------------------- options

    @AuraEnabled
    public static Options getOptions(Id companyId) {
        assertCompany(companyId);
        Options o = new Options();
        o.canManageSetup = SABPermissionService.hasPermission(SETUP_PERMISSION);
        Accounting_Company__c company = new Store().company(companyId);
        o.fiscalCalendarType = company.Fiscal_Calendar_Type__c;
        o.fiscalYearStartMonth = company.Fiscal_Year_Start_Month__c == null ? 1 : company.Fiscal_Year_Start_Month__c.intValue();
        o.countryCode = company.Country_Code__c;
        o.countryPackVersion = company.Country_Pack_Version__c;
        o.unrealizedGainAccountId = company.Unrealized_FX_Gain_Account__c;
        o.unrealizedLossAccountId = company.Unrealized_FX_Loss_Account__c;
        o.realizedGainAccountId = company.Realized_FX_Gain_Account__c;
        o.realizedLossAccountId = company.Realized_FX_Loss_Account__c;
        o.patterns = PATTERNS;
        Date lastEnd = new Store().lastPeriodEnd(companyId);
        if (lastEnd != null) {
            o.nextPeriodStart = lastEnd.addDays(1);
        } else {
            Date today = Date.today();
            Date start = Date.newInstance(today.year(), o.fiscalYearStartMonth, 1);
            o.nextPeriodStart = start > today ? start.addYears(-1) : start;
        }
        o.gainAccounts = new List<Option>();
        o.lossAccounts = new List<Option>();
        for (GL_Account__c a : new Store().profitAndLossAccounts(companyId)) {
            Option option = new Option(a.Id, a.Account_Code__c + ' ' + a.Name);
            if (a.Account_Type__c == 'Revenue') {
                o.gainAccounts.add(option);
            } else {
                o.lossAccounts.add(option);
            }
        }
        o.filingFrequencies = new List<String>();
        for (Schema.PicklistEntry e : Tax_Registration__c.Filing_Frequency__c.getDescribe().getPicklistValues()) {
            if (e.isActive()) {
                o.filingFrequencies.add(e.getValue());
            }
        }
        return o;
    }

    // ---------------------------------------------------------------- periods

    @AuraEnabled
    public static Integer generatePeriods(GenerateRequest request, String requestKey) {
        String key = requireKey(requestKey);
        if (request == null || request.companyId == null) {
            throw new SetupActionException('Accounting Company is required.');
        }
        assertSetup(request.companyId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return [SELECT COUNT() FROM Accounting_Period__c WHERE Company__c = :request.companyId WITH SYSTEM_MODE];
        }
        if (request.firstDay == null) {
            throw new SetupActionException('Choose the first day of the fiscal year.');
        }
        String pattern = String.isBlank(request.pattern) ? 'Monthly' : request.pattern;
        if (!PATTERNS.contains(pattern)) {
            throw new SetupActionException('Choose a supported period pattern.');
        }
        List<Date[]> ranges = ranges(request.firstDay, pattern);
        Date lastDay = ranges[ranges.size() - 1][1];
        Integer fiscalYear = request.fiscalYear != null ? request.fiscalYear
            : (request.firstDay.month() == 1 && request.firstDay.day() == 1 ? request.firstDay.year() : lastDay.year());
        if (store.overlaps(request.companyId, request.firstDay, lastDay)) {
            throw new SetupActionException('Periods already exist between ' + request.firstDay.format() + ' and ' + lastDay.format() + '.');
        }
        String companyKey = store.company(request.companyId).Company_Key__c;
        String prefix = 'FY' + String.valueOf(fiscalYear).right(2);
        List<Accounting_Period__c> rows = new List<Accounting_Period__c>();
        for (Integer i = 0; i < ranges.size(); i++) {
            Integer number_x = i + 1;
            String periodKey = prefix + '-P' + String.valueOf(number_x).leftPad(2, '0');
            rows.add(new Accounting_Period__c(Company__c = request.companyId, Name = periodKey, Period_Key__c = periodKey,
                Company_Period_Key__c = (companyKey + '-' + periodKey).left(160), Start_Date__c = ranges[i][0], End_Date__c = ranges[i][1],
                Fiscal_Year__c = fiscalYear, Fiscal_Quarter__c = Math.min(4, (i / 3) + 1), Period_Number__c = number_x, Status__c = 'Open'));
        }
        new Writer().insertAll(rows, audit(request.companyId, 'SETUP_PERIODS_GENERATED', key, request.companyId,
            rows.size() + ' periods generated for ' + prefix + ' (' + pattern + ')'));
        return rows.size();
    }

    @TestVisible
    private static List<Date[]> ranges(Date firstDay, String pattern) {
        List<Date[]> result = new List<Date[]>();
        if (pattern == 'Monthly') {
            for (Integer i = 0; i < 12; i++) {
                result.add(new Date[]{ firstDay.addMonths(i), firstDay.addMonths(i + 1).addDays(-1) });
            }
            return result;
        }
        List<Integer> weeks = pattern == '4-4-5 weeks' ? new List<Integer>{ 4, 4, 5 }
            : pattern == '4-5-4 weeks' ? new List<Integer>{ 4, 5, 4 }
            : pattern == '5-4-4 weeks' ? new List<Integer>{ 5, 4, 4 } : new List<Integer>{ 4 };
        Integer count = weeks.size() == 1 ? 13 : 12;
        Date start = firstDay;
        for (Integer i = 0; i < count; i++) {
            Integer length = weeks[Math.mod(i, weeks.size())] * 7;
            result.add(new Date[]{ start, start.addDays(length - 1) });
            start = start.addDays(length);
        }
        return result;
    }

    // ------------------------------------------------------------- FX accounts

    @AuraEnabled
    public static Id saveFxAccounts(FxRequest request, String requestKey) {
        String key = requireKey(requestKey);
        if (request == null || request.companyId == null) {
            throw new SetupActionException('Accounting Company is required.');
        }
        assertSetup(request.companyId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return request.companyId;
        }
        Accounting_Company__c company = store.company(request.companyId);
        Map<String, Id> chosen = new Map<String, Id>{ 'UG' => request.unrealizedGainAccountId, 'UL' => request.unrealizedLossAccountId,
            'RG' => request.realizedGainAccountId, 'RL' => request.realizedLossAccountId };
        Map<String, String[]> standard = new Map<String, String[]>{
            'UG' => new String[]{ '4910', 'Unrealized FX gain', 'Revenue', 'Credit' }, 'RG' => new String[]{ '4920', 'Realized FX gain', 'Revenue', 'Credit' },
            'UL' => new String[]{ '6910', 'Unrealized FX loss', 'Expense', 'Debit' }, 'RL' => new String[]{ '6920', 'Realized FX loss', 'Expense', 'Debit' } };
        Map<String, GL_Account__c> existing = store.accountsByCode(request.companyId);
        List<GL_Account__c> toCreate = new List<GL_Account__c>();
        Map<String, GL_Account__c> created = new Map<String, GL_Account__c>();
        for (String slot : chosen.keySet()) {
            if (chosen.get(slot) != null) {
                continue;
            }
            if (request.createMissing != true) {
                throw new SetupActionException('Choose all four FX accounts, or let the app create the missing ones.');
            }
            String[] s = standard.get(slot);
            if (existing.containsKey(s[0])) {
                chosen.put(slot, existing.get(s[0]).Id);
            } else {
                GL_Account__c account = new GL_Account__c(Company__c = request.companyId, Account_Code__c = s[0], Name = s[1], Account_Type__c = s[2],
                    Normal_Balance__c = s[3], Control_Type__c = 'None', Is_Control_Account__c = false, Manual_Posting_Allowed__c = true, Is_Active__c = true,
                    Report_Group__c = 'Foreign exchange', Company_Account_Key__c = (company.Company_Key__c + '-' + s[0]).left(140));
                toCreate.add(account);
                created.put(slot, account);
            }
        }
        Map<Id, GL_Account__c> byId = new Map<Id, GL_Account__c>(existing.values());
        for (String slot : chosen.keySet()) {
            Id accountId = chosen.get(slot);
            if (accountId == null) {
                continue;
            }
            GL_Account__c account = byId.get(accountId);
            if (account == null) {
                throw new SetupActionException('An FX account does not belong to this Accounting Company.');
            }
            if (!account.Is_Active__c || account.Is_Control_Account__c || (account.Account_Type__c != 'Revenue' && account.Account_Type__c != 'Expense')) {
                throw new SetupActionException('FX accounts must be active revenue or expense accounts that are not control accounts: ' + account.Account_Code__c + '.');
            }
        }
        new Writer().saveFx(company, toCreate, created, chosen, audit(request.companyId, 'SETUP_FX_ACCOUNTS_SAVED', key, request.companyId, 'FX gain and loss accounts saved'));
        return request.companyId;
    }

    // -------------------------------------------------------- tax registration

    @AuraEnabled
    public static Id saveTaxRegistration(RegistrationRequest request, String requestKey) {
        String key = requireKey(requestKey);
        if (request == null || request.companyId == null) {
            throw new SetupActionException('Accounting Company is required.');
        }
        assertSetup(request.companyId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return Id.valueOf(prior.Source_Record_Id__c);
        }
        Date effectiveFrom = request.effectiveFrom == null ? Date.today() : request.effectiveFrom;
        if (request.effectiveTo != null && request.effectiveTo < effectiveFrom) {
            throw new SetupActionException('The end date cannot be before the start date.');
        }
        String identifier = requireText(request.identifier, 'Registration number');
        Tax_Registration__c row = new Tax_Registration__c(Id = request.registrationId, Name = requireText(request.name, 'Name').left(80),
            Jurisdiction__c = requireText(request.jurisdiction, 'Jurisdiction'), Registration_Identifier__c = identifier,
            Filing_Frequency__c = String.isBlank(request.filingFrequency) ? 'Quarterly' : request.filingFrequency, Effective_From__c = effectiveFrom,
            Effective_To__c = request.effectiveTo, Country_Pack_Version__c = packVersion(request, store),
            Is_Active__c = request.active != false);
        if (request.registrationId == null) {
            row.Company__c = request.companyId;
        } else {
            store.assertBelongs(request.registrationId, request.companyId);
        }
        Business_Action__c audit = audit(request.companyId, 'SETUP_TAX_REGISTRATION_SAVED', key, null, 'Tax registration ' + identifier + ' saved');
        new Writer().saveRegistration(row, audit);
        return row.Id;
    }

    /** The registration's country pack, or the company's when left blank; the field is required. */
    private static String packVersion(RegistrationRequest request, Store store) {
        String value = String.isBlank(request.countryPackVersion) ? store.company(request.companyId).Country_Pack_Version__c : request.countryPackVersion.trim();
        if (String.isBlank(value)) {
            throw new SetupActionException('Country pack version is required because the company has none.');
        }
        return value;
    }

    // ------------------------------------------------------------------ party

    @AuraEnabled
    public static Id saveParty(PartyRequest request, String requestKey) {
        String key = requireKey(requestKey);
        if (request == null || request.companyId == null) {
            throw new SetupActionException('Accounting Company is required.');
        }
        assertCompany(request.companyId);
        if (!SABContactService.canManage()) {
            throw new SetupActionException('You do not have permission to manage customers and suppliers. Ask for the SAB Manage Contacts Action permission set.');
        }
        if (!Schema.SObjectType.Account.isCreateable() || !Schema.SObjectType.Party_Accounting_Profile__c.isCreateable()) {
            throw new SetupActionException('You do not have permission to create customers or suppliers.');
        }
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return Id.valueOf(prior.Source_Record_Id__c);
        }
        Boolean customer = request.isCustomer == true;
        Boolean supplier = request.isSupplier == true;
        if (!customer && !supplier) {
            throw new SetupActionException('Choose customer, supplier or both.');
        }
        String name = requireText(request.name, 'Name');
        Map<String, Id> controls = store.controlAccounts(request.companyId);
        if (customer && !controls.containsKey('AR')) {
            throw new SetupActionException('Add an active accounts receivable control account in Chart of accounts first.');
        }
        if (supplier && !controls.containsKey('AP')) {
            throw new SetupActionException('Add an active accounts payable control account in Chart of accounts first.');
        }
        Savepoint sp = Database.setSavepoint();
        Party_Accounting_Profile__c profile;
        try {
            Account account = new Account(Name = name.left(255));
            insert as user account;
            profile = new Party_Accounting_Profile__c(Company__c = request.companyId, Account__c = account.Id, Is_Customer__c = customer, Is_Supplier__c = supplier,
                Is_Active__c = true, Profile_Key__c = (store.company(request.companyId).Company_Key__c + '-' + account.Id).left(80),
                AR_Control_Account__c = customer ? controls.get('AR') : null, AP_Control_Account__c = supplier ? controls.get('AP') : null,
                Tax_Registration_Number__c = String.isBlank(request.taxRegistrationNumber) ? null : request.taxRegistrationNumber.trim(),
                Credit_Limit__c = customer ? request.creditLimit : null);
            insert as user profile;
            Business_Action__c entry = audit(request.companyId, 'PARTY_CREATED', key, profile.Id, (customer ? 'Customer ' : 'Supplier ') + name + ' created');
            new Writer().audit(entry);
        } catch (DmlException ex) {
            Database.rollback(sp);
            throw new SetupActionException(ex.getDmlMessage(0));
        }
        return profile.Id;
    }

    // ---------------------------------------------------------------- helpers

    private static void assertCompany(Id companyId) {
        if (companyId == null || !SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw new SetupActionException('You do not have active access to this Accounting Company.');
        }
    }

    private static void assertSetup(Id companyId) {
        assertCompany(companyId);
        SABPermissionService.assertPermission(SETUP_PERMISSION, 'You do not have permission to manage company setup.');
    }

    private static String requireText(String value, String label) {
        if (String.isBlank(value)) {
            throw new SetupActionException(label + ' is required.');
        }
        return value.trim();
    }

    private static String requireKey(String requestKey) {
        if (String.isBlank(requestKey) || requestKey.trim().length() > 160) {
            throw new SetupActionException('A request key of up to 160 characters is required.');
        }
        return requestKey.trim();
    }

    private static Business_Action__c audit(Id companyId, String actionName, String key, Id recordId, String reason) {
        return new Business_Action__c(Company__c = companyId, Action__c = actionName, Actor__c = UserInfo.getUserId(), Action_At__c = System.now(),
            Reason__c = reason.left(255), Request_Key__c = key, Source_Type__c = 'Setup', Source_Version__c = 1,
            Source_Record_Id__c = recordId == null ? null : String.valueOf(recordId));
    }

    // System reads after the company and permission checks.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c FROM Business_Action__c WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }

        Accounting_Company__c company(Id companyId) {
            return [SELECT Id, Company_Key__c, Country_Code__c, Country_Pack_Version__c, Fiscal_Calendar_Type__c, Fiscal_Year_Start_Month__c, Unrealized_FX_Gain_Account__c,
                    Unrealized_FX_Loss_Account__c, Realized_FX_Gain_Account__c, Realized_FX_Loss_Account__c
                FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE LIMIT 1];
        }

        Date lastPeriodEnd(Id companyId) {
            List<Accounting_Period__c> rows = [SELECT End_Date__c FROM Accounting_Period__c WHERE Company__c = :companyId WITH SYSTEM_MODE ORDER BY End_Date__c DESC LIMIT 1];
            return rows.isEmpty() ? null : rows[0].End_Date__c;
        }

        Boolean overlaps(Id companyId, Date firstDay, Date lastDay) {
            return [SELECT COUNT() FROM Accounting_Period__c WHERE Company__c = :companyId AND Start_Date__c <= :lastDay AND End_Date__c >= :firstDay WITH SYSTEM_MODE] > 0;
        }

        List<GL_Account__c> profitAndLossAccounts(Id companyId) {
            return [SELECT Id, Account_Code__c, Name, Account_Type__c FROM GL_Account__c WHERE Company__c = :companyId AND Is_Active__c = true
                AND Is_Control_Account__c = false AND Account_Type__c IN ('Revenue', 'Expense') WITH SYSTEM_MODE ORDER BY Account_Code__c LIMIT 1000];
        }

        Map<String, GL_Account__c> accountsByCode(Id companyId) {
            Map<String, GL_Account__c> rows = new Map<String, GL_Account__c>();
            for (GL_Account__c a : [SELECT Id, Account_Code__c, Account_Type__c, Is_Active__c, Is_Control_Account__c FROM GL_Account__c
                    WHERE Company__c = :companyId WITH SYSTEM_MODE LIMIT 2000]) {
                rows.put(a.Account_Code__c, a);
            }
            return rows;
        }

        Map<String, Id> controlAccounts(Id companyId) {
            Map<String, Id> rows = new Map<String, Id>();
            for (GL_Account__c a : [SELECT Id, Control_Type__c FROM GL_Account__c WHERE Company__c = :companyId AND Is_Active__c = true
                    AND Control_Type__c IN ('AR', 'AP') WITH SYSTEM_MODE ORDER BY Account_Code__c]) {
                if (!rows.containsKey(a.Control_Type__c)) {
                    rows.put(a.Control_Type__c, a.Id);
                }
            }
            return rows;
        }

        void assertBelongs(Id registrationId, Id companyId) {
            List<Tax_Registration__c> rows = [SELECT Company__c FROM Tax_Registration__c WHERE Id = :registrationId WITH SYSTEM_MODE LIMIT 1];
            if (rows.isEmpty() || rows[0].Company__c != companyId) {
                throw new SetupActionException('The tax registration does not belong to this Accounting Company.');
            }
        }
    }

    // System writes after the company and permission checks; configuration guards and sharing triggers still run.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void insertAll(List<SObject> rows, Business_Action__c audit) {
            insert as system rows;
            insert as system audit;
        }

        void saveFx(Accounting_Company__c company, List<GL_Account__c> toCreate, Map<String, GL_Account__c> created, Map<String, Id> chosen, Business_Action__c audit) {
            if (!toCreate.isEmpty()) {
                insert as system toCreate;
                for (String slot : created.keySet()) {
                    chosen.put(slot, created.get(slot).Id);
                }
            }
            update as system new Accounting_Company__c(Id = company.Id, Unrealized_FX_Gain_Account__c = chosen.get('UG'), Unrealized_FX_Loss_Account__c = chosen.get('UL'),
                Realized_FX_Gain_Account__c = chosen.get('RG'), Realized_FX_Loss_Account__c = chosen.get('RL'));
            insert as system audit;
        }

        void saveRegistration(Tax_Registration__c row, Business_Action__c audit) {
            if (row.Id == null) {
                insert as system row;
            } else {
                update as system row;
            }
            audit.Source_Record_Id__c = String.valueOf(row.Id);
            insert as system audit;
        }

        void audit(Business_Action__c entry) {
            insert as system entry;
        }
    }
}
