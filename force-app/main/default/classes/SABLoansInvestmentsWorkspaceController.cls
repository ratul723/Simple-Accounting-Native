/**
 * G22B: controller for c/sabLoansWorkspace (Investments & loans).
 *
 * Read only. Actions in the workspace call the G16 services directly, unchanged:
 * SABLoanService.saveDraft / approve / accrueInterest / recordRepayment and
 * SABInvestmentService.saveInvestment / recordTransaction, each with a request key.
 *
 * Loan balance is the closing principal balance of the last Paid instalment (principal before any
 * repayment, zero once Closed). Holdings follow SABInvestmentService.holding: posted transactions only
 * (Journal_Entry__c set); acquisitions add quantity and cost, valuations change the carrying amount,
 * disposals relieve quantity and the carrying amount relieved.
 */
public with sharing class SABLoansInvestmentsWorkspaceController {

    private static final Integer MAX_LOANS = 100;
    private static final Integer MAX_INVESTMENTS = 100;
    private static final Integer TRANSACTIONS_SHOWN = 50;
    private static final Set<String> BORROWING_TYPES = new Set<String>{ 'Borrowing', 'Shareholder Loan' };

    public class WorkspaceData {
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Id userId { get; set; }
        @AuraEnabled public Boolean canManageLoans { get; set; }
        @AuraEnabled public Boolean canApproveLoans { get; set; }
        @AuraEnabled public Boolean canManageInvestments { get; set; }
        @AuraEnabled public Boolean canPostJournal { get; set; }
        @AuraEnabled public Boolean loansAvailable { get; set; }
        @AuraEnabled public Boolean investmentsAvailable { get; set; }
        @AuraEnabled public Decimal borrowings { get; set; }
        @AuraEnabled public Integer borrowingCount { get; set; }
        @AuraEnabled public Decimal lending { get; set; }
        @AuraEnabled public Decimal interestThisQuarter { get; set; }
        @AuraEnabled public Integer interestLoanCount { get; set; }
        @AuraEnabled public Decimal investmentsTotal { get; set; }
        @AuraEnabled public Decimal incomeYearToDate { get; set; }
        @AuraEnabled public Date fiscalYearStart { get; set; }
        @AuraEnabled public List<LoanRow> loans { get; set; }
        @AuraEnabled public List<InvestmentRow> investments { get; set; }
        @AuraEnabled public List<TransactionRow> transactions { get; set; }
    }

    public class LoanRow {
        @AuraEnabled public Id loanId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String loanType { get; set; }
        @AuraEnabled public String counterparty { get; set; }
        @AuraEnabled public String principalAccountCode { get; set; }
        @AuraEnabled public Decimal principal { get; set; }
        @AuraEnabled public Decimal rate { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date maturityDate { get; set; }
        @AuraEnabled public String frequency { get; set; }
        @AuraEnabled public String method { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Boolean createdByMe { get; set; }
        @AuraEnabled public Decimal balance { get; set; }
        @AuraEnabled public Decimal repaid { get; set; }
        @AuraEnabled public Date nextDueDate { get; set; }
        @AuraEnabled public Decimal nextPayment { get; set; }
        @AuraEnabled public Id nextLineId { get; set; }
        @AuraEnabled public String nextAction { get; set; }
        @AuraEnabled public List<LineRow> lines { get; set; }
    }

    public class LineRow {
        @AuraEnabled public Id lineId { get; set; }
        @AuraEnabled public Integer sequence { get; set; }
        @AuraEnabled public Date dueDate { get; set; }
        @AuraEnabled public Decimal payment { get; set; }
        @AuraEnabled public Decimal interest { get; set; }
        @AuraEnabled public Decimal principalDue { get; set; }
        @AuraEnabled public Decimal balance { get; set; }
        @AuraEnabled public String status { get; set; }
    }

    public class InvestmentRow {
        @AuraEnabled public Id investmentId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String instrumentKey { get; set; }
        @AuraEnabled public String classification { get; set; }
        @AuraEnabled public String valuationPolicy { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String accountCode { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
        @AuraEnabled public Decimal carryingAmount { get; set; }
        @AuraEnabled public Decimal cost { get; set; }
        @AuraEnabled public Decimal incomeYearToDate { get; set; }
    }

    public class TransactionRow {
        @AuraEnabled public Id transactionId { get; set; }
        @AuraEnabled public Id investmentId { get; set; }
        @AuraEnabled public String investmentName { get; set; }
        @AuraEnabled public String transactionType { get; set; }
        @AuraEnabled public Date transactionDate { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
        @AuraEnabled public Decimal gainLoss { get; set; }
        @AuraEnabled public Boolean posted { get; set; }
    }

    public class Option {
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String kind { get; set; }

        Option(String value, String label, String kind) {
            this.value = value;
            this.label = label;
            this.kind = kind;
        }
    }

    public class FormOptions {
        @AuraEnabled public List<Option> counterparties { get; set; }
        @AuraEnabled public List<Option> glAccounts { get; set; }
        @AuraEnabled public List<Option> bankAccounts { get; set; }
    }

    @AuraEnabled
    public static WorkspaceData getWorkspace(Id companyId) {
        assertView(companyId);
        try {
            return build(companyId, Date.today());
        } catch (QueryException ex) {
            throw auraError('Investments & loans could not be loaded: ' + ex.getMessage());
        }
    }

    @AuraEnabled
    public static FormOptions getFormOptions(Id companyId) {
        assertView(companyId);
        FormOptions options = new FormOptions();
        options.counterparties = new List<Option>();
        options.glAccounts = new List<Option>();
        options.bankAccounts = new List<Option>();
        try {
            for (Account account : [SELECT Id, Name FROM Account WITH USER_MODE ORDER BY Name LIMIT 500]) {
                options.counterparties.add(new Option(account.Id, account.Name, null));
            }
            for (GL_Account__c account : [
                SELECT Id, Name, Account_Code__c, Account_Type__c
                FROM GL_Account__c
                WHERE Company__c = :companyId AND Is_Active__c = true
                WITH USER_MODE
                ORDER BY Account_Code__c
                LIMIT 1000
            ]) {
                options.glAccounts.add(new Option(account.Id, account.Account_Code__c + ' ' + account.Name, account.Account_Type__c));
            }
            for (Bank_Account__c bank : [
                SELECT Id, Name, Currency__c
                FROM Bank_Account__c
                WHERE Company__c = :companyId AND Is_Active__c = true
                WITH USER_MODE
                ORDER BY Name
                LIMIT 200
            ]) {
                options.bankAccounts.add(new Option(bank.Id, bank.Name + ' (' + bank.Currency__c + ')', null));
            }
        } catch (QueryException ex) {
            throw auraError('Form options could not be loaded: ' + ex.getMessage());
        }
        return options;
    }

    @TestVisible
    private static WorkspaceData build(Id companyId, Date today) {
        Accounting_Company__c company = [
            SELECT Functional_Currency__c, Fiscal_Year_Start_Month__c
            FROM Accounting_Company__c
            WHERE Id = :companyId
            WITH USER_MODE
            LIMIT 1
        ];
        WorkspaceData data = new WorkspaceData();
        data.currencyCode = company.Functional_Currency__c;
        data.userId = UserInfo.getUserId();
        data.canManageLoans = SABPermissionService.hasPermission('SAB_Manage_Loans');
        data.canApproveLoans = SABPermissionService.hasPermission('SAB_Approve_Loans');
        data.canManageInvestments = SABPermissionService.hasPermission('SAB_Manage_Investments');
        data.canPostJournal = SABPermissionService.hasPermission('SAB_Post_Journal');
        data.fiscalYearStart = fiscalYearStart(today, company.Fiscal_Year_Start_Month__c);
        data.loansAvailable = SABLoansInvestmentsReadPolicy.canReadLoans();
        data.investmentsAvailable = SABLoansInvestmentsReadPolicy.canReadInvestments();
        data.loans = data.loansAvailable ? loans(companyId) : new List<LoanRow>();
        loanFigures(data, today);
        data.investments = new List<InvestmentRow>();
        data.transactions = new List<TransactionRow>();
        if (data.investmentsAvailable) {
            loadInvestments(data, companyId);
        }
        return data;
    }

    @TestVisible
    private static Date fiscalYearStart(Date today, Decimal startMonth) {
        Integer month = startMonth == null || startMonth < 1 || startMonth > 12 ? 1 : startMonth.intValue();
        Integer year = today.month() >= month ? today.year() : today.year() - 1;
        return Date.newInstance(year, month, 1);
    }

    private static List<LoanRow> loans(Id companyId) {
        Map<Id, LoanRow> byId = new Map<Id, LoanRow>();
        List<LoanRow> rows = new List<LoanRow>();
        Id userId = UserInfo.getUserId();
        for (Loan__c loan : [
            SELECT Id, Name, Loan_Type__c, Counterparty_Account__r.Name, Principal_Account__r.Account_Code__c, Principal__c,
                   Interest_Rate__c, Start_Date__c, Maturity_Date__c, Repayment_Frequency__c, Schedule_Method__c, Status__c, CreatedById
            FROM Loan__c
            WHERE Company__c = :companyId
            WITH USER_MODE
            ORDER BY Start_Date__c DESC, Name
            LIMIT :MAX_LOANS
        ]) {
            LoanRow row = new LoanRow();
            row.loanId = loan.Id;
            row.name = loan.Name;
            row.loanType = loan.Loan_Type__c;
            row.counterparty = loan.Counterparty_Account__r == null ? null : loan.Counterparty_Account__r.Name;
            row.principalAccountCode = loan.Principal_Account__r == null ? null : loan.Principal_Account__r.Account_Code__c;
            row.principal = zero(loan.Principal__c);
            row.rate = loan.Interest_Rate__c;
            row.startDate = loan.Start_Date__c;
            row.maturityDate = loan.Maturity_Date__c;
            row.frequency = loan.Repayment_Frequency__c;
            row.method = loan.Schedule_Method__c;
            row.status = loan.Status__c;
            row.createdByMe = loan.CreatedById == userId;
            row.balance = loan.Status__c == 'Closed' ? 0 : row.principal;
            row.lines = new List<LineRow>();
            byId.put(loan.Id, row);
            rows.add(row);
        }
        if (byId.isEmpty()) {
            return rows;
        }
        Set<Id> loanIds = byId.keySet();
        for (Loan_Schedule_Line__c line : [
            SELECT Id, Loan__c, Sequence__c, Due_Date__c, Principal_Due__c, Interest_Due__c, Principal_Balance__c, Status__c
            FROM Loan_Schedule_Line__c
            WHERE Loan__c IN :loanIds
            WITH USER_MODE
            ORDER BY Loan__c, Sequence__c
            LIMIT 5000
        ]) {
            LoanRow row = byId.get(line.Loan__c);
            LineRow lineRow = new LineRow();
            lineRow.lineId = line.Id;
            lineRow.sequence = line.Sequence__c == null ? null : line.Sequence__c.intValue();
            lineRow.dueDate = line.Due_Date__c;
            lineRow.principalDue = zero(line.Principal_Due__c);
            lineRow.interest = zero(line.Interest_Due__c);
            lineRow.payment = lineRow.principalDue + lineRow.interest;
            lineRow.balance = zero(line.Principal_Balance__c);
            lineRow.status = line.Status__c;
            row.lines.add(lineRow);
            applyLine(row, lineRow);
        }
        for (LoanRow row : rows) {
            row.repaid = row.principal - row.balance;
        }
        return rows;
    }

    private static void applyLine(LoanRow row, LineRow line) {
        if (line.status == 'Paid') {
            row.balance = line.balance;
            return;
        }
        if (row.nextLineId == null && (line.status == 'Planned' || line.status == 'Due')) {
            row.nextLineId = line.lineId;
            row.nextDueDate = line.dueDate;
            row.nextPayment = line.payment;
            row.nextAction = row.status == 'Active' ? (line.status == 'Planned' ? 'accrue' : 'repay') : null;
        }
    }

    private static void loanFigures(WorkspaceData data, Date today) {
        data.borrowings = 0;
        data.lending = 0;
        data.borrowingCount = 0;
        data.interestThisQuarter = 0;
        data.interestLoanCount = 0;
        Integer quarterStartMonth = ((today.month() - 1) / 3) * 3 + 1;
        Date quarterStart = Date.newInstance(today.year(), quarterStartMonth, 1);
        Date quarterEnd = quarterStart.addMonths(3).addDays(-1);
        for (LoanRow row : data.loans) {
            if (row.status != 'Active') {
                continue;
            }
            if (BORROWING_TYPES.contains(row.loanType)) {
                data.borrowings += row.balance;
                data.borrowingCount++;
            } else {
                data.lending += row.balance;
            }
            Decimal quarterInterest = 0;
            for (LineRow line : row.lines) {
                if (line.dueDate != null && line.dueDate >= quarterStart && line.dueDate <= quarterEnd) {
                    quarterInterest += line.interest;
                }
            }
            if (quarterInterest > 0) {
                data.interestThisQuarter += quarterInterest;
                data.interestLoanCount++;
            }
        }
    }

    private static void loadInvestments(WorkspaceData data, Id companyId) {
        Map<Id, InvestmentRow> byId = new Map<Id, InvestmentRow>();
        for (Investment__c investment : [
            SELECT Id, Name, Instrument_Key__c, Classification__c, Valuation_Policy_Key__c, Status__c, Investment_Account__r.Account_Code__c
            FROM Investment__c
            WHERE Company__c = :companyId
            WITH USER_MODE
            ORDER BY Name
            LIMIT :MAX_INVESTMENTS
        ]) {
            InvestmentRow row = new InvestmentRow();
            row.investmentId = investment.Id;
            row.name = investment.Name;
            row.instrumentKey = investment.Instrument_Key__c;
            row.classification = investment.Classification__c;
            row.valuationPolicy = investment.Valuation_Policy_Key__c;
            row.status = investment.Status__c;
            row.accountCode = investment.Investment_Account__r == null ? null : investment.Investment_Account__r.Account_Code__c;
            row.quantity = 0;
            row.carryingAmount = 0;
            row.cost = 0;
            row.incomeYearToDate = 0;
            byId.put(investment.Id, row);
            data.investments.add(row);
        }
        data.investmentsTotal = 0;
        data.incomeYearToDate = 0;
        if (byId.isEmpty()) {
            return;
        }
        Set<Id> investmentIds = byId.keySet();
        for (Investment_Transaction__c tx : [
            SELECT Id, Investment__c, Investment__r.Name, Transaction_Type__c, Transaction_Date__c, Amount__c, Quantity__c,
                   Carrying_Amount_Relieved__c, Realized_Gain_Loss__c, Journal_Entry__c
            FROM Investment_Transaction__c
            WHERE Investment__c IN :investmentIds
            WITH USER_MODE
            ORDER BY Transaction_Date__c DESC, CreatedDate DESC
            LIMIT 5000
        ]) {
            InvestmentRow row = byId.get(tx.Investment__c);
            Boolean posted = tx.Journal_Entry__c != null;
            if (posted) {
                applyTransaction(row, tx, data.fiscalYearStart);
            }
            if (data.transactions.size() < TRANSACTIONS_SHOWN) {
                data.transactions.add(transactionRow(tx, posted));
            }
        }
        for (InvestmentRow row : data.investments) {
            data.investmentsTotal += row.carryingAmount;
            data.incomeYearToDate += row.incomeYearToDate;
        }
    }

    @TestVisible
    private static void applyTransaction(InvestmentRow row, Investment_Transaction__c tx, Date fiscalYearStart) {
        Decimal amount = zero(tx.Amount__c);
        Decimal quantity = zero(tx.Quantity__c);
        String type = tx.Transaction_Type__c;
        if (type == 'Acquisition') {
            row.quantity += quantity;
            row.carryingAmount += amount;
            row.cost += amount;
        } else if (type == 'Valuation') {
            row.carryingAmount += amount;
        } else if (type == 'Disposal') {
            row.quantity -= quantity;
            row.carryingAmount -= zero(tx.Carrying_Amount_Relieved__c);
        } else if (type == 'Income' && tx.Transaction_Date__c != null && tx.Transaction_Date__c >= fiscalYearStart) {
            row.incomeYearToDate += amount;
        }
    }

    private static TransactionRow transactionRow(Investment_Transaction__c tx, Boolean posted) {
        TransactionRow row = new TransactionRow();
        row.transactionId = tx.Id;
        row.investmentId = tx.Investment__c;
        row.investmentName = tx.Investment__r == null ? null : tx.Investment__r.Name;
        row.transactionType = tx.Transaction_Type__c;
        row.transactionDate = tx.Transaction_Date__c;
        row.amount = tx.Amount__c;
        row.quantity = tx.Quantity__c;
        row.gainLoss = tx.Realized_Gain_Loss__c;
        row.posted = posted;
        return row;
    }

    private static void assertView(Id companyId) {
        try {
            SABLoansInvestmentsReadPolicy.assertCanView(companyId);
        } catch (SABLoansInvestmentsReadPolicy.LoansInvestmentsAccessException ex) {
            throw auraError(ex.getMessage());
        }
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