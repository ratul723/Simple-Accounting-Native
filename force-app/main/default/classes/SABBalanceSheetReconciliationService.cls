/**
 * New requirements batch 1 (R1): the balance sheet explained by its source records.
 *
 * The ledger stays the source of truth: every section starts from posted GL balances at the reporting date, and the
 * matching subledger only explains that number. Sections:
 *   Cash and bank      bank GL accounts            vs latest bank statement closing balance on or before the date
 *   Receivables        AR control accounts         vs open invoices in AR aging
 *   Payables           AP control accounts         vs open posted bills in AP aging
 *   Fixed assets       asset and accumulated depreciation accounts of the asset categories vs the asset register
 *   Loans              loan principal accounts     vs principal outstanding on active loan schedules
 *   Payroll            payroll control accounts    vs net pay still to pay on posted payroll runs (deductions and
 *                      contributions payable to authorities stay as an explained difference)
 *   Share capital      equity class capital and premium accounts vs posted equity transactions
 *   Tax                tax control accounts        (reviewed against tax returns; not matched automatically)
 *   Retained earnings and other balance sheet accounts (ledger only)
 *   Inventory          dependency: needs an inventory module
 * A subledger the user cannot read is reported as not available rather than failing the whole view.
 */
public with sharing class SABBalanceSheetReconciliationService {
    public class ReconciliationException extends Exception {}

    public class SourceRow {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String detail { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
    }

    public class AccountRow {
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public Decimal balance { get; set; }
    }

    public class Section {
        @AuraEnabled public String key { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String side { get; set; }
        @AuraEnabled public Decimal ledger { get; set; }
        @AuraEnabled public Decimal subledger { get; set; }
        @AuraEnabled public Decimal difference { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String sourceLabel { get; set; }
        @AuraEnabled public String workspace { get; set; }
        @AuraEnabled public String note { get; set; }
        @AuraEnabled public List<AccountRow> accounts { get; set; }
        @AuraEnabled public List<SourceRow> sources { get; set; }
    }

    public class Reconciliation {
        @AuraEnabled public Date asOfDate { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Decimal totalAssets { get; set; }
        @AuraEnabled public Decimal totalLiabilitiesAndEquity { get; set; }
        @AuraEnabled public List<Section> sections { get; set; }
    }

    private static final Integer MAX_SOURCES = 50;

    @AuraEnabled
    public static Reconciliation getReconciliation(Id companyId, Date asOfDate) {
        if (companyId == null || !SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw auraError('You do not have active access to this Accounting Company.');
        }
        if (!Schema.SObjectType.Journal_Entry_Line__c.isAccessible() || !Schema.SObjectType.GL_Account__c.isAccessible()) {
            throw auraError('You do not have permission to view the general ledger.');
        }
        Date asOf = asOfDate == null ? Date.today() : asOfDate;
        Reconciliation r = new Reconciliation();
        r.asOfDate = asOf;
        r.currencyCode = [SELECT Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH USER_MODE LIMIT 1].Functional_Currency__c;
        Map<Id, GL_Account__c> accounts = new Map<Id, GL_Account__c>([SELECT Id, Account_Code__c, Name, Account_Type__c, Control_Type__c FROM GL_Account__c
            WHERE Company__c = :companyId AND Account_Type__c IN ('Asset', 'Liability', 'Equity') WITH USER_MODE LIMIT 2000]);
        Map<Id, Decimal> debitBalances = ledgerBalances(companyId, asOf);
        Set<Id> used = new Set<Id>();
        r.sections = new List<Section>();
        r.sections.add(bank(companyId, asOf, accounts, debitBalances, used));
        r.sections.add(receivables(companyId, asOf, accounts, debitBalances, used));
        r.sections.add(payables(companyId, asOf, accounts, debitBalances, used));
        r.sections.add(fixedAssets(companyId, accounts, debitBalances, used));
        r.sections.add(loans(companyId, accounts, debitBalances, used));
        r.sections.add(payroll(companyId, accounts, debitBalances, used));
        r.sections.add(tax(accounts, debitBalances, used));
        r.sections.add(shareCapital(companyId, asOf, accounts, debitBalances, used));
        r.sections.add(other(accounts, debitBalances, used));
        r.sections.add(inventory());
        r.totalAssets = 0;
        r.totalLiabilitiesAndEquity = 0;
        for (Id accountId : debitBalances.keySet()) {
            GL_Account__c a = accounts.get(accountId);
            if (a == null) {
                continue;
            }
            if (a.Account_Type__c == 'Asset') {
                r.totalAssets += debitBalances.get(accountId);
            } else {
                r.totalLiabilitiesAndEquity -= debitBalances.get(accountId);
            }
        }
        return r;
    }

    // ---------------------------------------------------------------- ledger

    private static Map<Id, Decimal> ledgerBalances(Id companyId, Date asOf) {
        Map<Id, Decimal> balances = new Map<Id, Decimal>();
        for (AggregateResult agg : [SELECT GL_Account__c accountId, SUM(Debit_Base__c) debit, SUM(Credit_Base__c) credit FROM Journal_Entry_Line__c
                WHERE Journal_Entry__r.Company__c = :companyId AND Journal_Entry__r.Status__c IN ('Posted', 'Reversed')
                AND Journal_Entry__r.Accounting_Date__c <= :asOf WITH USER_MODE GROUP BY GL_Account__c LIMIT 2000]) {
            balances.put((Id) agg.get('accountId'), zero((Decimal) agg.get('debit')) - zero((Decimal) agg.get('credit')));
        }
        return balances;
    }

    /** Builds a section from the given accounts; liabilities and equity are shown as positive credit balances. */
    private static Section section(String key, String label, String side, Set<Id> accountIds, Map<Id, GL_Account__c> accounts,
            Map<Id, Decimal> debitBalances, Set<Id> used) {
        Section s = new Section();
        s.key = key;
        s.label = label;
        s.side = side;
        s.ledger = 0;
        s.accounts = new List<AccountRow>();
        s.sources = new List<SourceRow>();
        Decimal sign = side == 'Asset' ? 1 : -1;
        for (Id accountId : accountIds) {
            GL_Account__c a = accounts.get(accountId);
            if (a == null || used.contains(accountId)) {
                continue;
            }
            used.add(accountId);
            Decimal balance = sign * (debitBalances.containsKey(accountId) ? debitBalances.get(accountId) : 0);
            s.ledger += balance;
            AccountRow row = new AccountRow();
            row.accountId = accountId;
            row.label = a.Account_Code__c + ' ' + a.Name;
            row.balance = balance;
            s.accounts.add(row);
        }
        return s;
    }

    private static Set<Id> byControl(Map<Id, GL_Account__c> accounts, String controlType) {
        Set<Id> ids = new Set<Id>();
        for (GL_Account__c a : accounts.values()) {
            if (a.Control_Type__c == controlType) {
                ids.add(a.Id);
            }
        }
        return ids;
    }

    private static void compare(Section s, Decimal subledger, String sourceLabel, String workspace, String note) {
        s.subledger = subledger;
        s.sourceLabel = sourceLabel;
        s.workspace = workspace;
        s.note = note;
        if (subledger == null) {
            s.status = 'Ledger only';
            return;
        }
        s.difference = (s.ledger - subledger).setScale(2);
        s.status = s.difference == 0 ? 'Agreed' : 'Difference';
    }

    private static void unavailable(Section s, String sourceLabel, String workspace, Exception ex) {
        s.sourceLabel = sourceLabel;
        s.workspace = workspace;
        s.status = 'Not available';
        s.note = 'The source could not be read: ' + ex.getMessage();
    }

    private static SourceRow source(Id recordId, String label, String detail, Decimal amount) {
        SourceRow row = new SourceRow();
        row.recordId = recordId;
        row.label = label;
        row.detail = detail;
        row.amount = amount;
        return row;
    }

    // -------------------------------------------------------------- sections

    private static Section bank(Id companyId, Date asOf, Map<Id, GL_Account__c> accounts, Map<Id, Decimal> balances, Set<Id> used) {
        List<Bank_Account__c> banks = new List<Bank_Account__c>();
        String readError;
        try {
            if (Schema.SObjectType.Bank_Account__c.isAccessible()) {
                banks = [SELECT Id, Name, GL_Account__c FROM Bank_Account__c WHERE Company__c = :companyId WITH USER_MODE LIMIT 200];
            }
        } catch (QueryException ex) {
            readError = ex.getMessage();
        }
        Set<Id> ids = byControl(accounts, 'Bank');
        for (Bank_Account__c b : banks) {
            ids.add(b.GL_Account__c);
        }
        Section s = section('cash', 'Cash and bank', 'Asset', ids, accounts, balances, used);
        if (readError != null) {
            unavailable(s, 'Bank statements', 'bank', new ReconciliationException(readError));
            return s;
        }
        try {
            Decimal statements = 0;
            Boolean anyStatement = false;
            Map<Id, Bank_Statement__c> latestByBank = new Map<Id, Bank_Statement__c>();
            for (Bank_Statement__c st : [SELECT Id, Name, Bank_Account__c, Closing_Amount__c, Statement_End_Date__c, Status__c FROM Bank_Statement__c
                    WHERE Bank_Account__c IN :new Map<Id, Bank_Account__c>(banks).keySet() AND Statement_End_Date__c <= :asOf
                    WITH USER_MODE ORDER BY Statement_End_Date__c DESC LIMIT 2000]) {
                if (!latestByBank.containsKey(st.Bank_Account__c)) {
                    latestByBank.put(st.Bank_Account__c, st);
                }
            }
            for (Bank_Account__c b : banks) {
                List<Bank_Statement__c> latest = latestByBank.containsKey(b.Id) ? new List<Bank_Statement__c>{ latestByBank.get(b.Id) } : new List<Bank_Statement__c>();
                Decimal book = balances.containsKey(b.GL_Account__c) ? balances.get(b.GL_Account__c) : 0;
                if (latest.isEmpty()) {
                    s.sources.add(source(b.Id, b.Name, 'No bank statement on or before the date; book balance ' + book.setScale(2), book));
                    statements += book;
                } else {
                    anyStatement = true;
                    statements += zero(latest[0].Closing_Amount__c);
                    s.sources.add(source(b.Id, b.Name, latest[0].Name + ' to ' + latest[0].Statement_End_Date__c.format() + ' (' + latest[0].Status__c + ')',
                        latest[0].Closing_Amount__c));
                }
            }
            compare(s, anyStatement ? statements : null, 'Bank statements', 'bank',
                'A difference is usually receipts or payments not yet on the statement. Reconcile them in Banking.');
        } catch (Exception ex) {
            unavailable(s, 'Bank statements', 'bank', ex);
        }
        return s;
    }

    private static Section receivables(Id companyId, Date asOf, Map<Id, GL_Account__c> accounts, Map<Id, Decimal> balances, Set<Id> used) {
        Section s = section('ar', 'Receivables', 'Asset', byControl(accounts, 'AR'), accounts, balances, used);
        try {
            SABARAgingService.ARAgingRequest request = new SABARAgingService.ARAgingRequest();
            request.companyId = companyId;
            request.asOfDate = asOf;
            request.includeSettled = false;
            Decimal total = 0;
            for (SABARAgingService.ARAgingRow row : SABARAgingService.getAging(request).rows) {
                Decimal amount = zero(row.outstandingBaseAmount);
                total += amount;
                if (amount != 0 && s.sources.size() < MAX_SOURCES) {
                    s.sources.add(source(row.invoiceId, row.legalNumber, row.customerName + ', due ' + (row.dueDate == null ? '' : row.dueDate.format()), amount));
                }
            }
            compare(s, total, 'AR aging', 'sales', 'Open invoices and credit notes in the functional currency.');
        } catch (Exception ex) {
            unavailable(s, 'AR aging', 'sales', ex);
        }
        return s;
    }

    private static Section payables(Id companyId, Date asOf, Map<Id, GL_Account__c> accounts, Map<Id, Decimal> balances, Set<Id> used) {
        Section s = section('ap', 'Payables', 'Liability', byControl(accounts, 'AP'), accounts, balances, used);
        try {
            SABAccountsPayableWorkspaceController.WorkspaceDTO ap = SABAccountsPayableWorkspaceController.getWorkspace(companyId, asOf, null, null, false);
            Decimal total = 0;
            for (SABAccountsPayableWorkspaceController.BillRowDTO bill : ap.bills) {
                if (bill.status != 'Posted' || zero(bill.outstandingAmount) == 0) {
                    continue;
                }
                total += bill.outstandingAmount;
                if (s.sources.size() < MAX_SOURCES) {
                    s.sources.add(source(bill.billId, bill.billNumber, bill.supplierName + ', due ' + (bill.dueDate == null ? '' : bill.dueDate.format()), bill.outstandingAmount));
                }
            }
            compare(s, total, 'AP aging', 'purchases', 'Open posted bills and supplier credits.');
        } catch (Exception ex) {
            unavailable(s, 'AP aging', 'purchases', ex);
        }
        return s;
    }

    private static Section fixedAssets(Id companyId, Map<Id, GL_Account__c> accounts, Map<Id, Decimal> balances, Set<Id> used) {
        Set<Id> ids = new Set<Id>();
        String readError;
        try {
            if (Schema.SObjectType.Asset_Category__c.isAccessible()) {
                for (Asset_Category__c c : [SELECT Asset_Account__c, Accumulated_Depreciation_Account__c FROM Asset_Category__c WHERE Company__c = :companyId WITH USER_MODE]) {
                    ids.add(c.Asset_Account__c);
                    ids.add(c.Accumulated_Depreciation_Account__c);
                }
            }
        } catch (QueryException ex) {
            readError = ex.getMessage();
        }
        Section s = section('assets', 'Property, plant and equipment', 'Asset', ids, accounts, balances, used);
        if (readError != null) {
            unavailable(s, 'Asset register', 'assets', new ReconciliationException(readError));
            return s;
        }
        try {
            SABFixedAssetWorkspaceController.DashboardDTO register = SABFixedAssetWorkspaceController.getDashboard(companyId);
            for (SABFixedAssetWorkspaceController.AssetRowDTO a : register.assets) {
                if (s.sources.size() < MAX_SOURCES && zero(a.netBookValue) != 0) {
                    s.sources.add(source(a.assetId, String.isBlank(a.assetTag) ? a.name : a.assetTag + ' ' + a.name, a.categoryName + ', ' + a.status, a.netBookValue));
                }
            }
            compare(s, register.netBookValue, 'Asset register', 'assets', 'Cost less accumulated depreciation and impairment. The register shows current values.');
        } catch (Exception ex) {
            unavailable(s, 'Asset register', 'assets', ex);
        }
        return s;
    }

    private static Section loans(Id companyId, Map<Id, GL_Account__c> accounts, Map<Id, Decimal> balances, Set<Id> used) {
        // Users without access to loan fields keep the rest of the reconciliation; this section reports why it is missing.
        List<Loan__c> loanRows = new List<Loan__c>();
        String readError;
        try {
            if (Schema.SObjectType.Loan__c.isAccessible()) {
                loanRows = [SELECT Id, Name, Loan_Type__c, Principal__c, Principal_Account__c, Status__c FROM Loan__c WHERE Company__c = :companyId
                    AND Status__c IN ('Active', 'Defaulted') AND Loan_Type__c != 'Lending' WITH USER_MODE LIMIT 200];
            }
        } catch (QueryException ex) {
            readError = ex.getMessage();
        }
        Set<Id> ids = new Set<Id>();
        for (Loan__c l : loanRows) {
            ids.add(l.Principal_Account__c);
        }
        Section s = section('loans', 'Loans and borrowings', 'Liability', ids, accounts, balances, used);
        if (readError != null) {
            unavailable(s, 'Loan schedules', 'loans', new ReconciliationException(readError));
            return s;
        }
        if (loanRows.isEmpty()) {
            compare(s, null, 'Loan schedules', 'loans', 'No active borrowings.');
            return s;
        }
        try {
            Map<Id, Decimal> repaid = new Map<Id, Decimal>();
            for (AggregateResult agg : [SELECT Loan__c loanId, SUM(Principal_Due__c) paid FROM Loan_Schedule_Line__c
                    WHERE Loan__c IN :new Map<Id, Loan__c>(loanRows).keySet() AND Status__c = 'Paid' WITH USER_MODE GROUP BY Loan__c]) {
                repaid.put((Id) agg.get('loanId'), zero((Decimal) agg.get('paid')));
            }
            Decimal total = 0;
            for (Loan__c l : loanRows) {
                Decimal outstanding = zero(l.Principal__c) - (repaid.containsKey(l.Id) ? repaid.get(l.Id) : 0);
                total += outstanding;
                s.sources.add(source(l.Id, l.Name, l.Loan_Type__c + ', ' + l.Status__c, outstanding));
            }
            compare(s, total, 'Loan schedules', 'loans', 'Principal less repayments marked paid on the schedule.');
        } catch (Exception ex) {
            unavailable(s, 'Loan schedules', 'loans', ex);
        }
        return s;
    }

    private static Section payroll(Id companyId, Map<Id, GL_Account__c> accounts, Map<Id, Decimal> balances, Set<Id> used) {
        Section s = section('payroll', 'Payroll liabilities', 'Liability', byControl(accounts, 'Payroll'), accounts, balances, used);
        try {
            SABPayrollSummaryController.SummaryData summary = SABPayrollSummaryController.getSummary(companyId, null);
            Decimal total = 0;
            for (SABPayrollSummaryController.RunRow run : summary.runs) {
                if (run.state != 'Posted') {
                    continue;
                }
                Decimal owed = zero(run.netTotal) - zero(run.settledAmount);
                total += owed;
                s.sources.add(source(run.runId, run.name, 'Net pay still to pay', owed));
            }
            compare(s, total, 'Payroll runs', 'payroll',
                'Net pay still to pay on posted runs. Deductions and employer contributions owed to authorities make up the rest of the ledger balance.');
        } catch (Exception ex) {
            unavailable(s, 'Payroll runs', 'payroll', ex);
        }
        return s;
    }

    private static Section tax(Map<Id, GL_Account__c> accounts, Map<Id, Decimal> balances, Set<Id> used) {
        Section s = section('tax', 'Tax payable and receivable', 'Liability', byControl(accounts, 'Tax'), accounts, balances, used);
        compare(s, null, 'Tax returns', 'tax', 'Review against prepared and lodged tax returns in Tax.');
        return s;
    }

    private static Section shareCapital(Id companyId, Date asOf, Map<Id, GL_Account__c> accounts, Map<Id, Decimal> balances, Set<Id> used) {
        Set<Id> ids = new Set<Id>();
        String readError;
        try {
            if (Schema.SObjectType.Equity_Class__c.isAccessible()) {
                for (Equity_Class__c c : [SELECT Capital_Account__c, Premium_Account__c FROM Equity_Class__c WHERE Company__c = :companyId WITH USER_MODE]) {
                    ids.add(c.Capital_Account__c);
                    ids.add(c.Premium_Account__c);
                }
            }
        } catch (QueryException ex) {
            readError = ex.getMessage();
        }
        Section s = section('equity', 'Share capital', 'Equity', ids, accounts, balances, used);
        if (readError != null) {
            unavailable(s, 'Equity register', 'equity', new ReconciliationException(readError));
            return s;
        }
        if (ids.isEmpty()) {
            compare(s, null, 'Equity register', 'equity', 'No equity classes are set up.');
            return s;
        }
        try {
            Decimal total = 0;
            for (Equity_Transaction__c t : [SELECT Id, Name, Transaction_Type__c, Value__c, Transaction_Date__c FROM Equity_Transaction__c
                    WHERE Company__c = :companyId AND Status__c = 'Posted' AND Transaction_Date__c <= :asOf WITH USER_MODE ORDER BY Transaction_Date__c LIMIT 2000]) {
                Decimal value = t.Transaction_Type__c == 'Redemption' ? -zero(t.Value__c) : (t.Transaction_Type__c == 'Transfer' ? 0 : zero(t.Value__c));
                total += value;
                if (value != 0 && s.sources.size() < MAX_SOURCES) {
                    s.sources.add(source(t.Id, t.Name, t.Transaction_Type__c + ', ' + t.Transaction_Date__c.format(), value));
                }
            }
            compare(s, total, 'Equity register', 'equity', 'Posted issues and contributions less redemptions.');
        } catch (Exception ex) {
            unavailable(s, 'Equity register', 'equity', ex);
        }
        return s;
    }

    private static Section other(Map<Id, GL_Account__c> accounts, Map<Id, Decimal> balances, Set<Id> used) {
        Set<Id> remaining = new Set<Id>();
        for (Id accountId : balances.keySet()) {
            if (accounts.containsKey(accountId) && !used.contains(accountId)) {
                remaining.add(accountId);
            }
        }
        Section s = section('other', 'Retained earnings and other accounts', 'Equity', new Set<Id>(), accounts, balances, used);
        for (Id accountId : remaining) {
            GL_Account__c a = accounts.get(accountId);
            Decimal balance = (a.Account_Type__c == 'Asset' ? 1 : -1) * balances.get(accountId);
            AccountRow row = new AccountRow();
            row.accountId = accountId;
            row.label = a.Account_Code__c + ' ' + a.Name + ' (' + a.Account_Type__c + ')';
            row.balance = balance;
            s.accounts.add(row);
            s.ledger -= balances.get(accountId);
        }
        compare(s, null, 'General ledger', 'journal', 'Net credit balance of the remaining accounts, explained by journals. Retained earnings carry the profit and loss of earlier years.');
        return s;
    }

    private static Section inventory() {
        Section s = new Section();
        s.key = 'inventory';
        s.label = 'Inventory';
        s.side = 'Asset';
        s.ledger = null;
        s.status = 'Dependency';
        s.sourceLabel = 'Inventory records';
        s.note = 'Needs an inventory module before stock values can be reconciled.';
        s.accounts = new List<AccountRow>();
        s.sources = new List<SourceRow>();
        return s;
    }

    private static Decimal zero(Decimal value) {
        return value == null ? 0 : value;
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}