/**
 * G20: Staged file imports.
 *
 *   stage     SAB_Manage_Imports  parse a CSV into an Import Job and Import Rows (Parsed); the same file for the same company
 *                                 and type replays the existing job (SHA-256 file hash)
 *   validate  SAB_Manage_Imports  mark every row Valid or Error with a message; the job becomes Ready (no errors) or Validated
 *   commit    SAB_Commit_Imports  re-validates, then commits the Valid rows; the job becomes Committed or Part Failed
 *
 * Supported types in G20:
 *   Chart of Accounts   account_code, name, account_type [, normal_balance] [, is_active]       -> GL accounts
 *   Journal Entries     journal_key, accounting_date (yyyy-mm-dd), account_code, debit, credit [, description] [, explanation]
 *   Opening Balances    same columns as Journal Entries
 * Journal imports create Draft journals (Manual or Opening) grouped by journal_key: each must balance, fall in an Open period
 * and avoid control accounts. Posting stays with the journal workspace and its controls. Limits: 2,000 rows, 500,000 characters.
 */
public with sharing class SABImportService {
    public class ImportException extends Exception {}

    private static final String MANAGE = 'SAB_Manage_Imports';
    private static final String COMMIT_PERMISSION = 'SAB_Commit_Imports';
    private static final Integer MAX_ROWS = 2000;
    private static final Integer MAX_CHARS = 500000;
    private static final String SOURCE_TYPE = 'Import_Job__c';
    private static final Map<String, List<String>> REQUIRED_COLUMNS = new Map<String, List<String>>{
        'Chart of Accounts' => new List<String>{'account_code', 'name', 'account_type'},
        'Journal Entries' => new List<String>{'journal_key', 'accounting_date', 'account_code', 'debit', 'credit'},
        'Opening Balances' => new List<String>{'journal_key', 'accounting_date', 'account_code', 'debit', 'credit'}};
    private static final Set<String> ACCOUNT_TYPES = new Set<String>{'Asset', 'Liability', 'Equity', 'Revenue', 'Expense'};

    public class ActionResult {
        @AuraEnabled public Id importJobId;
        @AuraEnabled public String status;
        @AuraEnabled public Integer rowCount;
        @AuraEnabled public Integer validCount;
        @AuraEnabled public Integer errorCount;
        @AuraEnabled public Integer committedCount;
        @AuraEnabled public Boolean replay;
    }

    // ----------------------------------------------------------------- stage

    @AuraEnabled
    public static ActionResult stage(Id companyId, String importType, String csvText) {
        SABPermissionService.assertPermission(MANAGE, 'Import permission is required.');
        if (companyId == null || String.isBlank(importType) || String.isBlank(csvText)) {
            throw new ImportException('Company, import type and file content are required.');
        }
        SABCompanyAccessService.assertCompanyAccess(companyId);
        if (!REQUIRED_COLUMNS.containsKey(importType)) {
            throw new ImportException('G20 imports Chart of Accounts, Journal Entries and Opening Balances.');
        }
        if (csvText.length() > MAX_CHARS) {
            throw new ImportException('Import files cannot exceed ' + MAX_CHARS + ' characters.');
        }
        String hash = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(importType + '\n' + csvText)));
        Store store = new Store();
        Import_Job__c existing = store.jobByHash(companyId, hash);
        if (existing != null) {
            return result(existing, true);
        }
        List<List<String>> table;
        try {
            table = SABCsvParser.parse(csvText);
        } catch (SABCsvParser.CsvException ex) {
            throw new ImportException(ex.getMessage());
        }
        if (table.size() < 2) {
            throw new ImportException('The file needs a header row and at least one data row.');
        }
        if (table.size() - 1 > MAX_ROWS) {
            throw new ImportException('An import can have at most ' + MAX_ROWS + ' rows.');
        }
        List<String> header = new List<String>();
        for (String column : table[0]) {
            header.add(column.trim().toLowerCase());
        }
        for (String required : REQUIRED_COLUMNS.get(importType)) {
            if (!header.contains(required)) {
                throw new ImportException('Missing required column: ' + required + '.');
            }
        }
        List<Import_Row__c> rows = new List<Import_Row__c>();
        String keyColumn = importType == 'Chart of Accounts' ? 'account_code' : 'journal_key';
        for (Integer r = 1; r < table.size(); r++) {
            Map<String, String> values = new Map<String, String>();
            for (Integer c = 0; c < header.size(); c++) {
                values.put(header[c], c < table[r].size() ? table[r][c].trim() : '');
            }
            rows.add(new Import_Row__c(Row_Number__c = r, Parsed_Value_JSON__c = JSON.serialize(values),
                External_Key__c = values.get(keyColumn) == null ? null : values.get(keyColumn).left(180), Validation_Status__c = 'Pending'));
        }
        Import_Job__c job = new Import_Job__c(Company__c = companyId, Import_Type__c = importType, File_Hash__c = hash, Status__c = 'Parsed',
            Row_Count__c = rows.size(), Valid_Row_Count__c = 0, Error_Row_Count__c = 0, Requested_By__c = UserInfo.getUserId(),
            Requested_At__c = System.now());
        new Writer().stage(job, rows);
        return result(job, false);
    }

    // -------------------------------------------------------------- validate

    @AuraEnabled
    public static ActionResult validate(Id importJobId) {
        SABPermissionService.assertPermission(MANAGE, 'Import permission is required.');
        Store store = new Store();
        Import_Job__c job = store.lockJob(importJobId);
        SABCompanyAccessService.assertCompanyAccess(job.Company__c);
        if (job.Status__c != 'Parsed' && job.Status__c != 'Validated' && job.Status__c != 'Ready') {
            throw new ImportException('Only a parsed, uncommitted import can be validated.');
        }
        List<Import_Row__c> rows = store.rows(job.Id);
        check(job, rows, store);
        Integer errors = 0;
        for (Import_Row__c row : rows) {
            errors += row.Validation_Status__c == 'Error' ? 1 : 0;
        }
        job.Valid_Row_Count__c = rows.size() - errors;
        job.Error_Row_Count__c = errors;
        job.Status__c = errors == 0 ? 'Ready' : 'Validated';
        new Writer().saveRows(new Import_Job__c(Id = job.Id, Status__c = job.Status__c, Valid_Row_Count__c = job.Valid_Row_Count__c,
            Error_Row_Count__c = errors), rows, null);
        return result(job, false);
    }

    // ---------------------------------------------------------------- commit

    @AuraEnabled
    public static ActionResult commitImport(Id importJobId, String requestKey) {
        if (String.isBlank(requestKey) || requestKey.trim().length() > Business_Action__c.Request_Key__c.getDescribe().getLength()) {
            throw new ImportException('A request key is required.');
        }
        String key = requestKey.trim();
        SABPermissionService.assertPermission(COMMIT_PERMISSION, 'Import commit permission is required.');
        Store store = new Store();
        Import_Job__c job = store.lockJob(importJobId);
        SABCompanyAccessService.assertCompanyAccess(job.Company__c);
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            if (prior.Action__c != 'IMPORT_COMMITTED' || prior.Source_Record_Id__c != String.valueOf(job.Id)) {
                throw new ImportException('Request key has already been used for a different import action.');
            }
            return result(job, true);
        }
        if (job.Status__c != 'Ready' && job.Status__c != 'Validated') {
            throw new ImportException('Validate the import before committing it.');
        }
        List<Import_Row__c> rows = store.rows(job.Id);
        check(job, rows, store);
        List<Import_Row__c> valid = new List<Import_Row__c>();
        for (Import_Row__c row : rows) {
            if (row.Validation_Status__c == 'Valid') {
                valid.add(row);
            }
        }
        if (valid.isEmpty()) {
            throw new ImportException('There are no valid rows to commit.');
        }
        Savepoint sp = Database.setSavepoint();
        try {
            if (job.Import_Type__c == 'Chart of Accounts') {
                commitAccounts(job, valid);
            } else {
                commitJournals(job, valid, store);
            }
            Integer committed = valid.size();
            Integer errors = rows.size() - committed;
            String status = errors == 0 ? 'Committed' : 'Part Failed';
            new Writer().saveRows(new Import_Job__c(Id = job.Id, Status__c = status, Valid_Row_Count__c = committed, Error_Row_Count__c = errors),
                rows, new Business_Action__c(Company__c = job.Company__c, Action__c = 'IMPORT_COMMITTED', Actor__c = UserInfo.getUserId(),
                    Action_At__c = System.now(), Request_Key__c = key, Source_Type__c = SOURCE_TYPE, Source_Record_Id__c = String.valueOf(job.Id),
                    Source_Version__c = 1, Reason__c = (job.Import_Type__c + ': ' + committed + ' rows committed, ' + errors + ' rejected.').left(255)));
            job.Status__c = status;
            job.Valid_Row_Count__c = committed;
            job.Error_Row_Count__c = errors;
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
        ActionResult r = result(job, false);
        r.committedCount = valid.size();
        return r;
    }

    // ------------------------------------------------------------ validation

    // Sets Validation_Status__c and Validation_Message__c on every row (in memory).
    private static void check(Import_Job__c job, List<Import_Row__c> rows, Store store) {
        Map<String, GL_Account__c> accounts = store.accountsByCode(job.Company__c);
        if (job.Import_Type__c == 'Chart of Accounts') {
            checkAccounts(rows, accounts);
        } else {
            checkJournals(job, rows, accounts, store);
        }
    }

    private static void checkAccounts(List<Import_Row__c> rows, Map<String, GL_Account__c> existing) {
        Map<String, Integer> codesInFile = new Map<String, Integer>();
        for (Import_Row__c row : rows) {
            String code = values(row).get('account_code');
            if (String.isNotBlank(code)) {
                codesInFile.put(code, (codesInFile.containsKey(code) ? codesInFile.get(code) : 0) + 1);
            }
        }
        for (Import_Row__c row : rows) {
            Map<String, String> v = values(row);
            String code = v.get('account_code');
            String type = v.get('account_type');
            String balance = v.get('normal_balance');
            List<String> errors = new List<String>();
            if (String.isBlank(code) || code.length() > 40) {
                errors.add('account_code is required (up to 40 characters)');
            } else if (codesInFile.get(code) > 1) {
                errors.add('account_code appears more than once in the file');
            } else if (existing.containsKey(code)) {
                errors.add('account_code already exists in the company');
            }
            if (String.isBlank(v.get('name')) || v.get('name').length() > 80) {
                errors.add('name is required (up to 80 characters)');
            }
            if (!ACCOUNT_TYPES.contains(type)) {
                errors.add('account_type must be Asset, Liability, Equity, Revenue or Expense');
            }
            if (String.isNotBlank(balance) && balance != 'Debit' && balance != 'Credit') {
                errors.add('normal_balance must be Debit or Credit');
            }
            mark(row, errors);
        }
    }

    private static void checkJournals(Import_Job__c job, List<Import_Row__c> rows, Map<String, GL_Account__c> accounts, Store store) {
        Map<String, List<Import_Row__c>> byJournal = new Map<String, List<Import_Row__c>>();
        Map<Id, List<String>> rowErrors = new Map<Id, List<String>>();
        Set<Date> dates = new Set<Date>();
        for (Import_Row__c row : rows) {
            Map<String, String> v = values(row);
            List<String> errors = new List<String>();
            String key = v.get('journal_key');
            if (String.isBlank(key)) {
                errors.add('journal_key is required');
                key = '#row' + row.Row_Number__c;
            }
            Date onDate = parseDate(v.get('accounting_date'));
            if (onDate == null) {
                errors.add('accounting_date must be yyyy-mm-dd');
            } else {
                dates.add(onDate);
            }
            GL_Account__c account = accounts.get(v.get('account_code'));
            if (account == null || account.Is_Active__c != true) {
                errors.add('account_code is not an active account of the company');
            } else if (account.Is_Control_Account__c == true) {
                errors.add('control accounts cannot be used in imported journals');
            }
            Decimal debit = parseAmount(v.get('debit'));
            Decimal credit = parseAmount(v.get('credit'));
            if (debit == null || credit == null || debit < 0 || credit < 0 || (debit > 0) == (credit > 0)) {
                errors.add('each line needs either a positive debit or a positive credit');
            }
            rowErrors.put(row.Id, errors);
            if (!byJournal.containsKey(key)) {
                byJournal.put(key, new List<Import_Row__c>());
            }
            byJournal.get(key).add(row);
        }
        Map<Date, Accounting_Period__c> periods = store.openPeriods(job.Company__c, dates);
        for (String key : byJournal.keySet()) {
            List<Import_Row__c> lines = byJournal.get(key);
            Decimal debits = 0;
            Decimal credits = 0;
            Set<String> journalDates = new Set<String>();
            for (Import_Row__c row : lines) {
                Map<String, String> v = values(row);
                debits += nz(parseAmount(v.get('debit')));
                credits += nz(parseAmount(v.get('credit')));
                journalDates.add(v.get('accounting_date'));
            }
            List<String> journalErrors = new List<String>();
            // A journal is imported whole or not at all: one invalid line rejects every line of the journal.
            List<String> badRows = new List<String>();
            for (Import_Row__c row : lines) {
                if (!rowErrors.get(row.Id).isEmpty()) {
                    badRows.add(String.valueOf(row.Row_Number__c));
                }
            }
            if (!badRows.isEmpty()) {
                journalErrors.add('journal ' + key + ' has invalid lines (row ' + String.join(badRows, ', ') + ')');
            }
            if (lines.size() < 2) {
                journalErrors.add('journal ' + key + ' needs at least two lines');
            }
            if (debits.setScale(2, RoundingMode.HALF_UP) != credits.setScale(2, RoundingMode.HALF_UP)) {
                journalErrors.add('journal ' + key + ' does not balance (debits ' + debits + ', credits ' + credits + ')');
            }
            if (journalDates.size() > 1) {
                journalErrors.add('journal ' + key + ' has more than one accounting_date');
            } else {
                Date onDate = parseDate(new List<String>(journalDates)[0]);
                if (onDate != null && !periods.containsKey(onDate)) {
                    journalErrors.add('no Open accounting period contains ' + String.valueOf(onDate));
                }
            }
            for (Import_Row__c row : lines) {
                List<String> errors = rowErrors.get(row.Id);
                errors.addAll(journalErrors);
                mark(row, errors);
            }
        }
    }

    // ---------------------------------------------------------------- commit

    private static void commitAccounts(Import_Job__c job, List<Import_Row__c> valid) {
        List<GL_Account__c> accounts = new List<GL_Account__c>();
        for (Import_Row__c row : valid) {
            Map<String, String> v = values(row);
            String type = v.get('account_type');
            String balance = String.isNotBlank(v.get('normal_balance')) ? v.get('normal_balance')
                : (type == 'Asset' || type == 'Expense' ? 'Debit' : 'Credit');
            accounts.add(new GL_Account__c(Name = v.get('name'), Company__c = job.Company__c, Account_Code__c = v.get('account_code'),
                Company_Account_Key__c = (String.valueOf(job.Company__c) + '-' + v.get('account_code')).left(140), Account_Type__c = type,
                Normal_Balance__c = balance, Is_Active__c = v.get('is_active') != 'false', Is_Control_Account__c = false, Control_Type__c = 'None',
                Manual_Posting_Allowed__c = true));
        }
        new Writer().insertRecords(accounts);
        for (Integer i = 0; i < valid.size(); i++) {
            valid[i].Validation_Status__c = 'Committed';
            valid[i].Committed_Record_Id__c = accounts[i].Id;
        }
    }

    private static void commitJournals(Import_Job__c job, List<Import_Row__c> valid, Store store) {
        Map<String, GL_Account__c> accounts = store.accountsByCode(job.Company__c);
        String currencyCode = store.functionalCurrency(job.Company__c);
        String entryType = job.Import_Type__c == 'Opening Balances' ? 'Opening' : 'Manual';
        Map<String, List<Import_Row__c>> byJournal = new Map<String, List<Import_Row__c>>();
        Set<Date> dates = new Set<Date>();
        for (Import_Row__c row : valid) {
            String key = values(row).get('journal_key');
            if (!byJournal.containsKey(key)) {
                byJournal.put(key, new List<Import_Row__c>());
            }
            byJournal.get(key).add(row);
            dates.add(parseDate(values(row).get('accounting_date')));
        }
        Map<Date, Accounting_Period__c> periods = store.openPeriods(job.Company__c, dates);
        Map<String, Journal_Entry__c> journals = new Map<String, Journal_Entry__c>();
        for (String key : byJournal.keySet()) {
            Map<String, String> first = values(byJournal.get(key)[0]);
            Date onDate = parseDate(first.get('accounting_date'));
            String description = String.isBlank(first.get('description')) ? 'Imported journal ' + key : first.get('description');
            journals.put(key, new Journal_Entry__c(Company__c = job.Company__c, Accounting_Period__c = periods.get(onDate).Id, Accounting_Date__c = onDate,
                Entry_Type__c = entryType, Status__c = 'Draft', Version__c = 1, Description__c = description.left(255)));
        }
        new Writer().insertRecords(journals.values());
        List<Journal_Entry_Line__c> lines = new List<Journal_Entry_Line__c>();
        for (String key : byJournal.keySet()) {
            Integer n = 1;
            for (Import_Row__c row : byJournal.get(key)) {
                Map<String, String> v = values(row);
                Decimal debit = nz(parseAmount(v.get('debit')));
                Decimal credit = nz(parseAmount(v.get('credit')));
                Date onDate = parseDate(v.get('accounting_date'));
                lines.add(new Journal_Entry_Line__c(Journal_Entry__c = journals.get(key).Id, Line_Number__c = n++,
                    GL_Account__c = accounts.get(v.get('account_code')).Id, Debit_Base__c = debit, Credit_Base__c = credit,
                    Transaction_Amount__c = debit > 0 ? debit : credit, Transaction_Currency__c = currencyCode, Functional_Currency__c = currencyCode,
                    Applied_Exchange_Rate__c = 1, Rate_Date__c = onDate, Rate_Source__c = 'Import',
                    Explanation__c = (String.isBlank(v.get('explanation')) ? 'Imported line' : v.get('explanation')).left(255)));
                row.Validation_Status__c = 'Committed';
                row.Committed_Record_Id__c = journals.get(key).Id;
            }
        }
        new Writer().insertRecords(lines);
    }

    // --------------------------------------------------------------- helpers

    private static Map<String, String> values(Import_Row__c row) {
        return (Map<String, String>) JSON.deserialize(row.Parsed_Value_JSON__c, Map<String, String>.class);
    }

    private static void mark(Import_Row__c row, List<String> errors) {
        row.Validation_Status__c = errors.isEmpty() ? 'Valid' : 'Error';
        row.Validation_Message__c = errors.isEmpty() ? null : String.join(errors, '; ');
    }

    @TestVisible
    private static Date parseDate(String value) {
        if (String.isBlank(value) || !Pattern.matches('\\d{4}-\\d{2}-\\d{2}', value)) {
            return null;
        }
        try {
            return Date.valueOf(value);
        } catch (Exception ex) {
            return null;
        }
    }

    @TestVisible
    private static Decimal parseAmount(String value) {
        if (String.isBlank(value)) {
            return 0;
        }
        try {
            return Decimal.valueOf(value.replace(',', ''));
        } catch (Exception ex) {
            return null;
        }
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }

    private static ActionResult result(Import_Job__c job, Boolean isReplay) {
        ActionResult r = new ActionResult();
        r.importJobId = job.Id;
        r.status = job.Status__c;
        r.rowCount = job.Row_Count__c == null ? 0 : job.Row_Count__c.intValue();
        r.validCount = job.Valid_Row_Count__c == null ? 0 : job.Valid_Row_Count__c.intValue();
        r.errorCount = job.Error_Row_Count__c == null ? 0 : job.Error_Row_Count__c.intValue();
        r.replay = isReplay;
        return r;
    }

    /** Narrow system reads after the permission and company checks; validation sees every account and period of the company. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c FROM Business_Action__c WHERE Request_Key__c = :key
                WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        Import_Job__c jobByHash(Id companyId, String hash) {
            List<Import_Job__c> rows = [SELECT Id, Status__c, Row_Count__c, Valid_Row_Count__c, Error_Row_Count__c FROM Import_Job__c
                WHERE Company__c = :companyId AND File_Hash__c = :hash AND Status__c != 'Failed' WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        Import_Job__c lockJob(Id jobId) {
            List<Import_Job__c> rows = [SELECT Id, Company__c, Import_Type__c, Status__c, Row_Count__c, Valid_Row_Count__c, Error_Row_Count__c
                FROM Import_Job__c WHERE Id = :jobId WITH SYSTEM_MODE FOR UPDATE];
            if (rows.isEmpty()) {
                throw new ImportException('Import job not found.');
            }
            return rows[0];
        }
        List<Import_Row__c> rows(Id jobId) {
            return [SELECT Id, Row_Number__c, Parsed_Value_JSON__c, External_Key__c, Validation_Status__c, Validation_Message__c,
                Committed_Record_Id__c FROM Import_Row__c WHERE Import_Job__c = :jobId WITH SYSTEM_MODE ORDER BY Row_Number__c LIMIT 2001];
        }
        Map<String, GL_Account__c> accountsByCode(Id companyId) {
            Map<String, GL_Account__c> result = new Map<String, GL_Account__c>();
            for (GL_Account__c a : [SELECT Id, Account_Code__c, Is_Active__c, Is_Control_Account__c FROM GL_Account__c WHERE Company__c = :companyId
                    WITH SYSTEM_MODE LIMIT 10000]) {
                result.put(a.Account_Code__c, a);
            }
            return result;
        }
        Map<Date, Accounting_Period__c> openPeriods(Id companyId, Set<Date> dates) {
            Map<Date, Accounting_Period__c> result = new Map<Date, Accounting_Period__c>();
            if (dates.isEmpty()) {
                return result;
            }
            List<Date> sorted = new List<Date>(dates);
            sorted.sort();
            Date first = sorted[0];
            Date last = sorted[sorted.size() - 1];
            for (Accounting_Period__c p : [SELECT Id, Start_Date__c, End_Date__c FROM Accounting_Period__c WHERE Company__c = :companyId
                    AND Status__c = 'Open' AND Start_Date__c <= :last AND End_Date__c >= :first WITH SYSTEM_MODE LIMIT 500]) {
                for (Date d : dates) {
                    if (d >= p.Start_Date__c && d <= p.End_Date__c) {
                        result.put(d, p);
                    }
                }
            }
            return result;
        }
        String functionalCurrency(Id companyId) {
            return [SELECT Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE].Functional_Currency__c;
        }
    }

    /** Narrow system writes inside the G20 guard scope, after the service's checks (explicit system mode). */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void stage(Import_Job__c job, List<Import_Row__c> rows) {
            SABImportGuard.beginWrite();
            try {
                insert as system job;
                for (Import_Row__c row : rows) {
                    row.Import_Job__c = job.Id;
                }
                insert as system rows;
            } finally {
                SABImportGuard.endWrite();
            }
        }
        void saveRows(Import_Job__c job, List<Import_Row__c> rows, Business_Action__c audit) {
            SABImportGuard.beginWrite();
            try {
                update as system rows;
                update as system job;
                if (audit != null) {
                    insert as system audit;
                }
            } finally {
                SABImportGuard.endWrite();
            }
        }
        void insertRecords(List<SObject> records) {
            insert as system records;
        }
    }
}
