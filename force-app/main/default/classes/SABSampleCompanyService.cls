/**
 * G22H: "Load sample company".
 *
 * startSampleCompany creates a ready-to-explore company in one transaction (Harbourline Trading sample): the company and
 * a Finance Manager grant for the user, 24 monthly periods (last year and this year), a chart of accounts with control,
 * cash flow and report groups, departments, cost centers, a bank account, three customers and three suppliers, the
 * Budgets and Projects features, an invoice sequence, and profit and loss and balance sheet definitions with mappings.
 *
 * Transactions are then added by SABSampleCompanyJob, one step per queueable so each posting gets its own limits:
 * an opening balance journal, three months of trading journals, two posted invoices (one overdue), and a set of drafts
 * to work on (a draft journal, a bill waiting for approval, a draft receipt). Every posting goes through the normal
 * services as the user who started the load, so the sample follows the same rules and permissions as real data; a step
 * the user is not allowed to do is recorded as a failure and the load carries on. Progress is a Processing_Run__c.
 */
public with sharing class SABSampleCompanyService {
    public class SampleCompanyException extends Exception {}

    public static final String RUN_TYPE = 'Sample Company';
    public static final List<String> STEPS = new List<String>{
        'Opening balances', 'Trading two months ago', 'Trading last month', 'Trading this month', 'Overdue invoice', 'Current invoice', 'Work to do' };

    private static final String CREATE_PERMISSION = 'SAB_Create_Accounting_Company';

    public class StartResult {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public Id runId { get; set; }
        @AuraEnabled public String companyName { get; set; }
    }

    public class StatusView {
        @AuraEnabled public Id runId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Integer stepsDone { get; set; }
        @AuraEnabled public Integer stepsTotal { get; set; }
        @AuraEnabled public Integer failures { get; set; }
        @AuraEnabled public String lastMessage { get; set; }
        @AuraEnabled public List<String> steps { get; set; }
    }

    // ------------------------------------------------------------------ start

    @AuraEnabled
    public static StartResult startSampleCompany(String requestKey) {
        if (String.isBlank(requestKey) || requestKey.length() > 160) {
            throw auraError('A request key of up to 160 characters is required.');
        }
        if (!SABPermissionService.hasPermission(CREATE_PERMISSION)) {
            throw auraError('You do not have permission to create Accounting Companies.');
        }
        Seeder seeder = new Seeder();
        Business_Action__c prior = seeder.action(requestKey);
        if (prior != null) {
            return seeder.replay(prior);
        }
        StartResult result = seeder.seed(requestKey);
        if (!Test.isRunningTest()) {
            System.enqueueJob(new SABSampleCompanyJob(result.runId, 0));
        }
        return result;
    }

    @AuraEnabled
    public static StatusView getStatus(Id runId) {
        if (runId == null) {
            throw auraError('A sample load is required.');
        }
        // System read limited to the caller's own sample run: users often have no field access to Processing_Run__c,
        // and the run carries only step counts and step messages for a company the caller just created.
        Id userId = UserInfo.getUserId();
        List<Processing_Run__c> runs = [
            SELECT Id, Company__c, Status__c, Processed_Count__c, Failure_Count__c, Cursor__c
            FROM Processing_Run__c WHERE Id = :runId AND Run_Type__c = :RUN_TYPE AND CreatedById = :userId WITH SYSTEM_MODE LIMIT 1
        ];
        if (runs.isEmpty()) {
            throw auraError('The sample load was not found.');
        }
        StatusView view = new StatusView();
        view.runId = runs[0].Id;
        view.companyId = runs[0].Company__c;
        view.status = runs[0].Status__c;
        view.stepsDone = runs[0].Processed_Count__c == null ? 0 : runs[0].Processed_Count__c.intValue();
        view.failures = runs[0].Failure_Count__c == null ? 0 : runs[0].Failure_Count__c.intValue();
        view.stepsTotal = STEPS.size();
        view.lastMessage = runs[0].Cursor__c;
        view.steps = STEPS;
        return view;
    }

    // ------------------------------------------------------------------ steps

    /** Runs one transaction step and records the outcome on the run. Called by SABSampleCompanyJob. */
    public static Boolean runStep(Id runId, Integer step) {
        Processing_Run__c run = [SELECT Id, Company__c, Processed_Count__c, Failure_Count__c FROM Processing_Run__c WHERE Id = :runId WITH SYSTEM_MODE LIMIT 1];
        String message = STEPS[step] + ': done';
        Boolean failed = false;
        Savepoint sp = Database.setSavepoint();
        try {
            executeStep(run.Company__c, step);
        } catch (Exception ex) {
            Database.rollback(sp);
            failed = true;
            message = STEPS[step] + ': ' + ex.getMessage();
        }
        Boolean last = step >= STEPS.size() - 1;
        new Seeder().progress(run, failed, message, last);
        return !last;
    }

    @TestVisible
    private static void executeStep(Id companyId, Integer step) {
        Map<String, Id> accounts = new Seeder().accounts(companyId);
        Date today = Date.today();
        if (step == 0) {
            postJournal(companyId, monthStart(-3), 'Opening balances', new List<Object[]>{
                new Object[]{ '1000', 120000, 0, null }, new Object[]{ '1500', 18000, 0, null }, new Object[]{ '3000', 0, 50000, null }, new Object[]{ '3100', 0, 88000, null } }, accounts);
        } else if (step >= 1 && step <= 3) {
            Integer month = step - 3;
            Decimal factor = 1 + (step * 0.06);
            Date accountingDate = monthStart(month).addDays(14) > today ? today : monthStart(month).addDays(14);
            Decimal sales = (35000 * factor).setScale(2);
            Decimal services = (7500 * factor).setScale(2);
            Decimal cogs = (18200 * factor).setScale(2);
            Decimal spend = cogs + 9600 + 4000 + 650 + 820;
            postJournal(companyId, accountingDate, 'Trading summary ' + accountingDate.month() + '/' + accountingDate.year(), new List<Object[]>{
                new Object[]{ '1000', sales + services, 0, null }, new Object[]{ '4000', 0, sales, 'SAL' }, new Object[]{ '4100', 0, services, 'SAL' },
                new Object[]{ '5000', cogs, 0, 'OPS' }, new Object[]{ '6000', 9600, 0, 'OPS' }, new Object[]{ '6100', 4000, 0, 'ADM' },
                new Object[]{ '6200', 650, 0, 'ADM' }, new Object[]{ '6400', 820, 0, 'ADM' }, new Object[]{ '1000', 0, spend, null } }, accounts);
        } else if (step == 4) {
            postInvoice(companyId, 'C1', today.addDays(-45), today.addDays(-15), 'Produce supply, August', 1, 9120, accounts.get('4000'));
        } else if (step == 5) {
            postInvoice(companyId, 'C2', today.addDays(-10), today.addDays(20), 'Consulting days', 2, 1000, accounts.get('4100'));
        } else {
            workToDo(companyId, accounts);
        }
    }

    private static Date monthStart(Integer offset) {
        return Date.today().toStartOfMonth().addMonths(offset);
    }

    private static void postJournal(Id companyId, Date accountingDate, String description, List<Object[]> lines, Map<String, Id> accounts) {
        Id journalId = new Seeder().draftJournal(companyId, accountingDate, description, lines, accounts);
        SABJournalWorkspaceController.postJournal(journalId);
    }

    private static void postInvoice(Id companyId, String customer, Date documentDate, Date dueDate, String description, Decimal quantity, Decimal price, Id accountId) {
        SABDocumentEntryService.DocumentRequest request = new SABDocumentEntryService.DocumentRequest();
        request.companyId = companyId;
        request.partyProfileId = new Seeder().profile(companyId, customer);
        request.documentDate = documentDate;
        request.dueDate = dueDate;
        SABDocumentEntryService.LineRequest line = new SABDocumentEntryService.LineRequest();
        line.description = description;
        line.quantity = quantity;
        line.unitPrice = price;
        line.accountId = accountId;
        request.lines = new List<SABDocumentEntryService.LineRequest>{ line };
        Id invoiceId = SABDocumentEntryService.saveInvoice(request, 'SAMPLE-INV-' + invoiceKey(companyId, customer));
        new Seeder().approveInvoice(invoiceId);
        SABInvoicePostingService.PostingRequest posting = new SABInvoicePostingService.PostingRequest();
        posting.invoiceId = invoiceId;
        posting.requestKey = 'SAMPLE-INVPOST-' + invoiceKey(companyId, customer);
        SABInvoicePostingService.postApprovedInvoice(posting);
    }

    private static String invoiceKey(Id companyId, String customer) {
        return String.valueOf(companyId) + '-' + customer;
    }

    private static void workToDo(Id companyId, Map<String, Id> accounts) {
        Seeder seeder = new Seeder();
        seeder.draftJournal(companyId, Date.today(), 'Accrue audit fee', new List<Object[]>{
            new Object[]{ '6400', 2500, 0, 'ADM' }, new Object[]{ '2300', 0, 2500, null } }, accounts);
        SABDocumentEntryService.DocumentRequest bill = new SABDocumentEntryService.DocumentRequest();
        bill.companyId = companyId;
        bill.partyProfileId = seeder.profile(companyId, 'S1');
        bill.documentDate = Date.today().addDays(-3);
        bill.dueDate = Date.today().addDays(27);
        bill.reference = 'FUEL-8812';
        SABDocumentEntryService.LineRequest line = new SABDocumentEntryService.LineRequest();
        line.description = 'Diesel, September';
        line.quantity = 1;
        line.unitPrice = 6720;
        line.accountId = accounts.get('6200');
        bill.lines = new List<SABDocumentEntryService.LineRequest>{ line };
        Id billId = SABDocumentEntryService.saveBill(bill, 'SAMPLE-BILL-' + companyId);
        SABSupplierBillService.submit(billId, 'SAMPLE-BILL-SUBMIT-' + companyId);
        SABDocumentEntryService.PaymentRequest receipt = new SABDocumentEntryService.PaymentRequest();
        receipt.companyId = companyId;
        receipt.direction = 'Receipt';
        receipt.partyProfileId = seeder.profile(companyId, 'C1');
        receipt.bankAccountId = seeder.bank(companyId);
        receipt.amount = 4000;
        receipt.effectiveDate = Date.today();
        receipt.method = 'Bank Transfer';
        receipt.reference = 'Greenfield part payment';
        SABDocumentEntryService.savePayment(receipt, 'SAMPLE-RECEIPT-' + companyId);
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }

    // ----------------------------------------------------------------- seeder

    // System writes after the create permission check: the sample company does not exist yet, so the user cannot have
    // object access through a grant; triggers still run.
    @SuppressWarnings('PMD.ApexCRUDViolation, PMD.ExcessiveParameterList')
    private without sharing class Seeder {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c, Company__c FROM Business_Action__c WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }

        StartResult replay(Business_Action__c prior) {
            if (prior.Action__c != 'SAMPLE_COMPANY_STARTED') {
                throw new SampleCompanyException('Request key has already been used for a different action.');
            }
            StartResult result = new StartResult();
            result.runId = Id.valueOf(prior.Source_Record_Id__c);
            result.companyId = prior.Company__c;
            result.companyName = [SELECT Name__c FROM Accounting_Company__c WHERE Id = :prior.Company__c WITH SYSTEM_MODE LIMIT 1].Name__c;
            return result;
        }

        StartResult seed(String requestKey) {
            String suffix = String.valueOf(Math.abs(Crypto.getRandomInteger())).leftPad(6, '0').right(6);
            String key = 'SAMPLE-' + suffix;
            Id userId = UserInfo.getUserId();
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'Harbourline Trading (sample ' + suffix + ')', Company_Key__c = key, Country_Code__c = 'AU',
                Functional_Currency__c = 'AUD', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active', Is_Active__c = true);
            insert as system company;
            Id companyId = company.Id;
            insert as system new Company_User_Access__c(Company__c = companyId, User__c = userId, Effective_From__c = Date.today().addYears(-2), Is_Active__c = true,
                Role__c = 'Finance Manager', Grant_Key__c = (key + '-OWNER-' + userId).left(160));
            insert as system periods(companyId, key);
            List<GL_Account__c> accounts = glAccounts(companyId, key);
            insert as system accounts;
            Map<String, Id> byCode = new Map<String, Id>();
            for (GL_Account__c a : accounts) {
                byCode.put(a.Account_Code__c, a.Id);
            }
            insert as system new List<Department__c>{ department(companyId, key, 'OPS', 'Operations'), department(companyId, key, 'SAL', 'Sales'),
                department(companyId, key, 'ADM', 'Administration') };
            insert as system new List<Cost_Center__c>{
                new Cost_Center__c(Company__c = companyId, Code__c = 'HO', Name = 'Head office', Company_Cost_Center_Key__c = key + '-HO', Is_Active__c = true),
                new Cost_Center__c(Company__c = companyId, Code__c = 'WH', Name = 'Warehouse', Company_Cost_Center_Key__c = key + '-WH', Is_Active__c = true) };
            insert as system new Bank_Account__c(Name = 'Operating account', Company__c = companyId, Bank_Name__c = 'Commonwealth Bank', Currency__c = 'AUD',
                GL_Account__c = byCode.get('1000'), Is_Active__c = true);
            parties(companyId, key, byCode);
            insert as system new List<Company_Feature__c>{ feature(companyId, key, 'BUDGETS'), feature(companyId, key, 'PROJECTS') };
            insert as system new Document_Sequence__c(Company__c = companyId, Document_Type__c = 'Invoice', Fiscal_Series__c = String.valueOf(Date.today().year()),
                Prefix__c = 'INV-', Minimum_Digits__c = 6, Next_Number__c = 1, Is_Active__c = true, Sequence_Key__c = key + '-Invoice-' + Date.today().year());
            reportDefinitions(companyId, key, byCode);
            Processing_Run__c run = new Processing_Run__c(Company__c = companyId, Run_Type__c = RUN_TYPE, Status__c = 'Queued', Processed_Count__c = 0,
                Failure_Count__c = 0, Retry_Count__c = 0, Started_At__c = System.now(), Cursor__c = 'Company created');
            insert as system run;
            insert as system new Business_Action__c(Company__c = companyId, Action__c = 'SAMPLE_COMPANY_STARTED', Actor__c = userId, Action_At__c = System.now(),
                Reason__c = 'Sample company created', Request_Key__c = requestKey, Source_Type__c = 'Sample', Source_Record_Id__c = String.valueOf(run.Id), Source_Version__c = 1);
            StartResult result = new StartResult();
            result.companyId = companyId;
            result.runId = run.Id;
            result.companyName = company.Name__c;
            return result;
        }

        List<Accounting_Period__c> periods(Id companyId, String key) {
            List<Accounting_Period__c> rows = new List<Accounting_Period__c>();
            Integer year = Date.today().year();
            for (Integer y = year - 1; y <= year; y++) {
                for (Integer m = 1; m <= 12; m++) {
                    Date start = Date.newInstance(y, m, 1);
                    String periodKey = y + '-' + String.valueOf(m).leftPad(2, '0');
                    rows.add(new Accounting_Period__c(Company__c = companyId, Name = periodKey, Period_Key__c = periodKey, Company_Period_Key__c = key + '-' + periodKey,
                        Start_Date__c = start, End_Date__c = start.addMonths(1).addDays(-1), Fiscal_Year__c = y, Fiscal_Quarter__c = ((m - 1) / 3) + 1,
                        Period_Number__c = m, Status__c = 'Open'));
                }
            }
            return rows;
        }

        List<GL_Account__c> glAccounts(Id companyId, String key) {
            List<GL_Account__c> rows = new List<GL_Account__c>();
            for (String[] a : new List<String[]>{
                new String[]{ '1000', 'Operating account', 'Asset', 'Debit', 'None', 'Cash', 'Cash' },
                new String[]{ '1100', 'Accounts receivable', 'Asset', 'Debit', 'AR', 'Operating', 'Receivables' },
                new String[]{ '1200', 'GST paid', 'Asset', 'Debit', 'None', 'Operating', 'Tax' },
                new String[]{ '1500', 'Equipment', 'Asset', 'Debit', 'None', 'Investing', 'Fixed assets' },
                new String[]{ '2000', 'Accounts payable', 'Liability', 'Credit', 'AP', 'Operating', 'Payables' },
                new String[]{ '2100', 'GST collected', 'Liability', 'Credit', 'None', 'Operating', 'Tax' },
                new String[]{ '2200', 'Payroll payable', 'Liability', 'Credit', 'None', 'Operating', 'Payroll' },
                new String[]{ '2300', 'Accrued expenses', 'Liability', 'Credit', 'None', 'Operating', 'Accruals' },
                new String[]{ '3000', 'Share capital', 'Equity', 'Credit', 'None', 'Financing', 'Equity' },
                new String[]{ '3100', 'Retained earnings', 'Equity', 'Credit', 'None', 'Financing', 'Equity' },
                new String[]{ '4000', 'Sales', 'Revenue', 'Credit', 'None', null, 'Revenue' },
                new String[]{ '4100', 'Services revenue', 'Revenue', 'Credit', 'None', null, 'Revenue' },
                new String[]{ '5000', 'Cost of goods sold', 'Expense', 'Debit', 'None', null, 'Cost of sales' },
                new String[]{ '6000', 'Wages', 'Expense', 'Debit', 'None', null, 'Employment costs' },
                new String[]{ '6100', 'Rent', 'Expense', 'Debit', 'None', null, 'Occupancy' },
                new String[]{ '6200', 'Fuel and utilities', 'Expense', 'Debit', 'None', null, 'Occupancy' },
                new String[]{ '6400', 'Office and professional', 'Expense', 'Debit', 'None', null, 'Administration' },
                new String[]{ '6900', 'Rounding', 'Expense', 'Debit', 'None', null, 'Administration' } }) {
                Boolean control = a[4] != 'None';
                rows.add(new GL_Account__c(Company__c = companyId, Account_Code__c = a[0], Name = a[1], Account_Type__c = a[2], Normal_Balance__c = a[3],
                    Control_Type__c = a[4], Is_Control_Account__c = control, Manual_Posting_Allowed__c = !control, Is_Active__c = true, Cash_Flow_Category__c = a[5],
                    Report_Group__c = a[6], Company_Account_Key__c = key + '-' + a[0]));
            }
            return rows;
        }

        Department__c department(Id companyId, String key, String code, String name) {
            return new Department__c(Company__c = companyId, Code__c = code, Name = name, Company_Department_Key__c = key + '-' + code, Is_Active__c = true);
        }

        Company_Feature__c feature(Id companyId, String key, String featureKey) {
            return new Company_Feature__c(Company__c = companyId, Feature_Key__c = featureKey, Company_Feature_Key__c = key + '-' + featureKey, Enabled__c = true,
                Configuration_Status__c = 'Valid', Enabled_At__c = System.now(), Enabled_By__c = UserInfo.getUserId());
        }

        void parties(Id companyId, String key, Map<String, Id> byCode) {
            List<String[]> rows = new List<String[]>{ new String[]{ 'C1', 'Greenfield Produce' }, new String[]{ 'C2', 'Coastal Foods' }, new String[]{ 'C3', 'Pacific Grocers' },
                new String[]{ 'S1', 'Fuel Co' }, new String[]{ 'S2', 'Pack & Ship' }, new String[]{ 'S3', 'Riverside Property' } };
            List<Account> accounts = new List<Account>();
            for (String[] r : rows) {
                accounts.add(new Account(Name = r[1] + ' (sample)'));
            }
            insert as system accounts;
            List<Party_Accounting_Profile__c> profiles = new List<Party_Accounting_Profile__c>();
            for (Integer i = 0; i < rows.size(); i++) {
                Boolean customer = rows[i][0].startsWith('C');
                profiles.add(new Party_Accounting_Profile__c(Company__c = companyId, Account__c = accounts[i].Id, Profile_Key__c = key + '-' + rows[i][0],
                    Is_Customer__c = customer, Is_Supplier__c = !customer, Is_Active__c = true, Credit_Limit__c = customer ? 20000 : null,
                    AR_Control_Account__c = customer ? byCode.get('1100') : null, AP_Control_Account__c = customer ? null : byCode.get('2000')));
            }
            insert as system profiles;
        }

        void reportDefinitions(Id companyId, String key, Map<String, Id> byCode) {
            Date effectiveFrom = Date.newInstance(Date.today().year() - 1, 1, 1);
            Report_Definition__c pl = new Report_Definition__c(Company__c = companyId, Definition_Key__c = key + '-PL', Report_Type__c = 'P&L', Version__c = 1,
                Status__c = 'Active', Effective_From__c = effectiveFrom);
            Report_Definition__c bs = new Report_Definition__c(Company__c = companyId, Definition_Key__c = key + '-BS', Report_Type__c = 'Balance Sheet', Version__c = 1,
                Status__c = 'Active', Effective_From__c = effectiveFrom);
            insert as system new List<Report_Definition__c>{ pl, bs };
            List<Report_Mapping__c> mappings = new List<Report_Mapping__c>();
            Integer order = 10;
            for (String[] m : new List<String[]>{
                new String[]{ 'PL', '4000', 'INCOME', 'SALES' }, new String[]{ 'PL', '4100', 'INCOME', 'SERVICES' }, new String[]{ 'PL', '5000', 'COST_OF_SALES', 'COST_OF_GOODS_SOLD' },
                new String[]{ 'PL', '6000', 'EXPENSES', 'EMPLOYMENT_COSTS' }, new String[]{ 'PL', '6100', 'EXPENSES', 'OCCUPANCY' }, new String[]{ 'PL', '6200', 'EXPENSES', 'OCCUPANCY' },
                new String[]{ 'PL', '6400', 'EXPENSES', 'ADMINISTRATION' }, new String[]{ 'PL', '6900', 'EXPENSES', 'ADMINISTRATION' },
                new String[]{ 'BS', '1000', 'ASSETS', 'CASH' }, new String[]{ 'BS', '1100', 'ASSETS', 'RECEIVABLES' }, new String[]{ 'BS', '1200', 'ASSETS', 'TAX_RECEIVABLE' },
                new String[]{ 'BS', '1500', 'ASSETS', 'EQUIPMENT' }, new String[]{ 'BS', '2000', 'LIABILITIES', 'PAYABLES' }, new String[]{ 'BS', '2100', 'LIABILITIES', 'TAX_PAYABLE' },
                new String[]{ 'BS', '2200', 'LIABILITIES', 'PAYROLL_PAYABLE' }, new String[]{ 'BS', '2300', 'LIABILITIES', 'ACCRUALS' },
                new String[]{ 'BS', '3000', 'EQUITY', 'SHARE_CAPITAL' }, new String[]{ 'BS', '3100', 'EQUITY', 'RETAINED_EARNINGS' } }) {
                mappings.add(new Report_Mapping__c(Report_Definition__c = m[0] == 'PL' ? pl.Id : bs.Id, GL_Account__c = byCode.get(m[1]), Group_Key__c = m[2], Row_Key__c = m[3],
                    Display_Order__c = order, Sign_Multiplier__c = 1, Effective_From__c = effectiveFrom));
                order += 10;
            }
            insert as system mappings;
        }

        Map<String, Id> accounts(Id companyId) {
            Map<String, Id> byCode = new Map<String, Id>();
            for (GL_Account__c a : [SELECT Id, Account_Code__c FROM GL_Account__c WHERE Company__c = :companyId WITH SYSTEM_MODE]) {
                byCode.put(a.Account_Code__c, a.Id);
            }
            return byCode;
        }

        Id profile(Id companyId, String suffix) {
            String key = [SELECT Company_Key__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE LIMIT 1].Company_Key__c + '-' + suffix;
            return [SELECT Id FROM Party_Accounting_Profile__c WHERE Profile_Key__c = :key WITH SYSTEM_MODE LIMIT 1].Id;
        }

        Id bank(Id companyId) {
            return [SELECT Id FROM Bank_Account__c WHERE Company__c = :companyId WITH SYSTEM_MODE LIMIT 1].Id;
        }

        Id draftJournal(Id companyId, Date accountingDate, String description, List<Object[]> lines, Map<String, Id> byCode) {
            Accounting_Period__c period = [SELECT Id FROM Accounting_Period__c WHERE Company__c = :companyId AND Start_Date__c <= :accountingDate
                AND End_Date__c >= :accountingDate WITH SYSTEM_MODE LIMIT 1];
            Map<String, Id> departments = new Map<String, Id>();
            for (Department__c d : [SELECT Id, Code__c FROM Department__c WHERE Company__c = :companyId WITH SYSTEM_MODE]) {
                departments.put(d.Code__c, d.Id);
            }
            Journal_Entry__c journal = new Journal_Entry__c(Company__c = companyId, Accounting_Period__c = period.Id, Accounting_Date__c = accountingDate,
                Entry_Type__c = 'Manual', Status__c = 'Draft', Description__c = description, Version__c = 1);
            insert as system journal;
            List<Journal_Entry_Line__c> rows = new List<Journal_Entry_Line__c>();
            Integer n = 1;
            for (Object[] l : lines) {
                // Literal amounts arrive as Integer or Decimal inside Object[]; normalise through the string form.
                Decimal debit = Decimal.valueOf(String.valueOf(l[1]));
                Decimal credit = Decimal.valueOf(String.valueOf(l[2]));
                rows.add(new Journal_Entry_Line__c(Journal_Entry__c = journal.Id, GL_Account__c = byCode.get((String) l[0]), Line_Number__c = n++,
                    Debit_Base__c = debit, Credit_Base__c = credit, Functional_Currency__c = 'AUD',
                    Department__c = l[3] == null ? null : departments.get((String) l[3]), Explanation__c = description));
            }
            insert as system rows;
            return journal.Id;
        }

        void approveInvoice(Id invoiceId) {
            update as system new Invoice__c(Id = invoiceId, Status__c = 'Approved');
        }

        void progress(Processing_Run__c run, Boolean failed, String message, Boolean last) {
            Integer done = (run.Processed_Count__c == null ? 0 : run.Processed_Count__c.intValue()) + 1;
            Integer failures = (run.Failure_Count__c == null ? 0 : run.Failure_Count__c.intValue()) + (failed ? 1 : 0);
            Processing_Run__c row = new Processing_Run__c(Id = run.Id, Processed_Count__c = done, Success_Count__c = done - failures, Failure_Count__c = failures,
                Cursor__c = message.left(255), Status__c = last ? (failures == STEPS.size() ? 'Failed' : 'Complete') : 'Running');
            if (last) {
                row.Completed_At__c = System.now();
            }
            update as system row;
        }
    }
}