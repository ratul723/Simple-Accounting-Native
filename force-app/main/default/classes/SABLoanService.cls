/**
 * G16: Loans.
 *
 *   saveDraft        SAB_Manage_Loans                    create or edit a Draft loan
 *   approve          SAB_Approve_Loans + SAB_Post_Journal Draft -> Active: generates the schedule and posts the drawdown;
 *                                                         the approver differs from the creator
 *   accrueInterest   SAB_Manage_Loans + SAB_Post_Journal  Planned line -> Due: posts the instalment's interest
 *   recordRepayment  SAB_Manage_Loans + SAB_Post_Journal  Due line -> Paid, in instalment order; the loan closes after the last
 *
 * Direction: Borrowing and Shareholder Loan (a borrowing from a shareholder) are liabilities; Lending is an asset.
 *   Drawdown   borrowing Dr Bank / Cr Principal            lending Dr Principal / Cr Bank
 *   Accrual    borrowing Dr Interest / Cr Accrued interest  lending Dr Accrued interest / Cr Interest income
 *   Repayment  borrowing Dr Principal + Dr Accrued / Cr Bank  lending Dr Bank / Cr Principal + Cr Accrued
 * Functional currency only. Postings are Subledger journals (event type Loan). Every action is idempotent and audited.
 */
public with sharing class SABLoanService {
    public class LoanException extends Exception {}

    private static final String MANAGE = 'SAB_Manage_Loans';
    private static final String APPROVE = 'SAB_Approve_Loans';
    private static final String POST_JOURNAL = 'SAB_Post_Journal';
    private static final Set<String> TYPES = new Set<String>{'Borrowing', 'Lending', 'Shareholder Loan'};
    private static final String ADAPTER = 'LOAN';
    private static final String SOURCE_TYPE = 'Loan__c';

    public class LoanRequest {
        @AuraEnabled public Id loanId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String loanType { get; set; }
        @AuraEnabled public Id counterpartyAccountId { get; set; }
        @AuraEnabled public Decimal principal { get; set; }
        @AuraEnabled public Decimal annualRatePercent { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date maturityDate { get; set; }
        @AuraEnabled public String repaymentFrequency { get; set; }
        @AuraEnabled public String scheduleMethod { get; set; }
        @AuraEnabled public Id principalAccountId { get; set; }
        @AuraEnabled public Id interestAccountId { get; set; }
        @AuraEnabled public Id accruedInterestAccountId { get; set; }
        @AuraEnabled public Id bankAccountId { get; set; }
    }

    public class ActionResult {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String status;
        @AuraEnabled public Id journalEntryId;
        @AuraEnabled public Boolean replay;
    }

    // ---------------------------------------------------------------- drafts

    @AuraEnabled
    public static Id saveDraft(LoanRequest request) {
        SABPermissionService.assertPermission(MANAGE, 'Loan management permission is required.');
        if (request == null || request.companyId == null || String.isBlank(request.name) || String.isBlank(request.loanType)
            || request.counterpartyAccountId == null) {
            throw new LoanException('Company, name, loan type and counterparty are required.');
        }
        SABCompanyAccessService.assertCompanyAccess(request.companyId);
        String name = request.name.trim();
        if (name.length() > 80) {
            throw new LoanException('Loan name cannot exceed 80 characters.');
        }
        if (!TYPES.contains(request.loanType)) {
            throw new LoanException('Loan type must be Borrowing, Lending or Shareholder Loan.');
        }
        // Validates principal, rate, dates, frequency and method; the schedule itself is generated on approval.
        try {
            SABLoanScheduleCalculator.build(request.principal, request.annualRatePercent, request.startDate, request.maturityDate,
                request.repaymentFrequency, request.scheduleMethod);
        } catch (SABLoanScheduleCalculator.LoanScheduleException ex) {
            throw new LoanException(ex.getMessage());
        }
        if ([SELECT COUNT() FROM Account WHERE Id = :request.counterpartyAccountId WITH USER_MODE] == 0) {
            throw new LoanException('Counterparty account not found or not accessible.');
        }
        Store store = new Store();
        String functional = store.functionalCurrency(request.companyId);
        validateAccounts(request.companyId, request.loanType, request.principalAccountId, request.interestAccountId,
            request.accruedInterestAccountId, request.bankAccountId, functional);
        Loan__c loan;
        if (request.loanId != null) {
            visibleLoan(request.loanId);
            loan = store.lockLoan(request.loanId);
            if (loan.Status__c != 'Draft' || loan.Company__c != request.companyId) {
                throw new LoanException('Only Draft loans of the same company can be edited.');
            }
        } else {
            loan = new Loan__c(Company__c = request.companyId, Status__c = 'Draft');
        }
        loan.Name = name;
        loan.Loan_Type__c = request.loanType;
        loan.Counterparty_Account__c = request.counterpartyAccountId;
        loan.Currency__c = functional;
        loan.Principal__c = request.principal;
        loan.Interest_Rate__c = request.annualRatePercent;
        loan.Start_Date__c = request.startDate;
        loan.Maturity_Date__c = request.maturityDate;
        loan.Repayment_Frequency__c = request.repaymentFrequency;
        loan.Schedule_Method__c = request.scheduleMethod;
        loan.Principal_Account__c = request.principalAccountId;
        loan.Interest_Account__c = request.interestAccountId;
        loan.Accrued_Interest_Account__c = request.accruedInterestAccountId;
        loan.Bank_Account__c = request.bankAccountId;
        new Writer().upsertLoan(loan);
        return loan.Id;
    }

    // ------------------------------------------------------------- lifecycle

    @AuraEnabled
    public static ActionResult approve(Id loanId, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(APPROVE, 'Loan approval permission is required.');
        SABPermissionService.assertPermission(POST_JOURNAL, 'Journal posting permission is required.');
        Loan__c visible = visibleLoan(loanId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'LOAN_APPROVED', store);
        }
        Loan__c loan = store.lockLoan(loanId);
        if (loan.Status__c != 'Draft') {
            throw new LoanException('Only a Draft loan can be approved.');
        }
        if (loan.CreatedById == UserInfo.getUserId()) {
            throw new LoanException('The creator of a loan cannot approve it.');
        }
        validateAccounts(loan.Company__c, loan.Loan_Type__c, loan.Principal_Account__c, loan.Interest_Account__c,
            loan.Accrued_Interest_Account__c, loan.Bank_Account__c, store.functionalCurrency(loan.Company__c));
        List<SABLoanScheduleCalculator.Instalment> schedule = SABLoanScheduleCalculator.build(loan.Principal__c, loan.Interest_Rate__c,
            loan.Start_Date__c, loan.Maturity_Date__c, loan.Repayment_Frequency__c, loan.Schedule_Method__c);
        List<Loan_Schedule_Line__c> lines = new List<Loan_Schedule_Line__c>();
        for (SABLoanScheduleCalculator.Instalment i : schedule) {
            lines.add(new Loan_Schedule_Line__c(Loan__c = loan.Id, Sequence__c = i.sequence, Due_Date__c = i.dueDate,
                Principal_Due__c = i.principalDue, Interest_Due__c = i.interestDue, Principal_Balance__c = i.closingBalance, Status__c = 'Planned'));
        }
        Decimal sign = isAsset(loan.Loan_Type__c) ? -1 : 1;
        Id bankGl = store.bankGl(loan.Bank_Account__c);
        Savepoint sp = Database.setSavepoint();
        try {
            SABPostingService.PostingResult posted = post(loan, 'DRAWDOWN', loan.Id, loan.Start_Date__c, key, 'Loan drawdown ' + loan.Name,
                new List<SABSubledgerPostingHelper.LineSpec>{
                    new SABSubledgerPostingHelper.LineSpec(bankGl, sign * loan.Principal__c, 'Loan drawdown'),
                    new SABSubledgerPostingHelper.LineSpec(loan.Principal_Account__c, -sign * loan.Principal__c, 'Loan principal')});
            new Writer().approve(new Loan__c(Id = loan.Id, Status__c = 'Active', Approved_By__c = UserInfo.getUserId(), Approved_At__c = System.now(),
                Drawdown_Journal__c = posted.journalEntryId), lines, audit(loan, 'LOAN_APPROVED', key, loan.Id,
                'Loan approved; ' + lines.size() + ' instalments scheduled and drawdown posted.'));
            return result(loan.Id, 'Active', posted.journalEntryId, false);
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
    }

    @AuraEnabled
    public static ActionResult accrueInterest(Id scheduleLineId, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(MANAGE, 'Loan management permission is required.');
        SABPermissionService.assertPermission(POST_JOURNAL, 'Journal posting permission is required.');
        Store store = new Store();
        Loan_Schedule_Line__c line = store.lockLine(scheduleLineId);
        Loan__c loan = loadActive(line.Loan__c, store);
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, line.Id, 'LOAN_INTEREST_ACCRUED', store);
        }
        if (line.Status__c != 'Planned') {
            throw new LoanException('Only a Planned instalment can have its interest accrued.');
        }
        Savepoint sp = Database.setSavepoint();
        try {
            Id journalId;
            if (line.Interest_Due__c != null && line.Interest_Due__c != 0) {
                Decimal sign = isAsset(loan.Loan_Type__c) ? -1 : 1;
                journalId = post(loan, 'ACCRUAL', line.Id, line.Due_Date__c, key, 'Loan interest ' + loan.Name + ' #' + line.Sequence__c,
                    new List<SABSubledgerPostingHelper.LineSpec>{
                        new SABSubledgerPostingHelper.LineSpec(loan.Interest_Account__c, sign * line.Interest_Due__c, 'Interest'),
                        new SABSubledgerPostingHelper.LineSpec(loan.Accrued_Interest_Account__c, -sign * line.Interest_Due__c, 'Accrued interest')})
                    .journalEntryId;
            }
            new Writer().line(new Loan_Schedule_Line__c(Id = line.Id, Status__c = 'Due', Accrual_Journal__c = journalId), null,
                audit(loan, 'LOAN_INTEREST_ACCRUED', key, line.Id, 'Interest accrued for instalment ' + line.Sequence__c + '.'));
            return result(line.Id, 'Due', journalId, false);
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
    }

    @AuraEnabled
    public static ActionResult recordRepayment(Id scheduleLineId, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(MANAGE, 'Loan management permission is required.');
        SABPermissionService.assertPermission(POST_JOURNAL, 'Journal posting permission is required.');
        Store store = new Store();
        Loan_Schedule_Line__c line = store.lockLine(scheduleLineId);
        Loan__c loan = loadActive(line.Loan__c, store);
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, line.Id, 'LOAN_REPAYMENT_RECORDED', store);
        }
        if (line.Status__c != 'Due') {
            throw new LoanException('Accrue the instalment\'s interest before recording its repayment.');
        }
        if (store.unpaidEarlier(loan.Id, line.Sequence__c)) {
            throw new LoanException('Earlier instalments must be repaid first.');
        }
        Decimal interest = line.Interest_Due__c == null ? 0 : line.Interest_Due__c;
        Decimal principalDue = line.Principal_Due__c == null ? 0 : line.Principal_Due__c;
        Decimal sign = isAsset(loan.Loan_Type__c) ? -1 : 1;
        Savepoint sp = Database.setSavepoint();
        try {
            SABPostingService.PostingResult posted = post(loan, 'REPAYMENT', line.Id, line.Due_Date__c, key,
                'Loan repayment ' + loan.Name + ' #' + line.Sequence__c, new List<SABSubledgerPostingHelper.LineSpec>{
                    new SABSubledgerPostingHelper.LineSpec(loan.Principal_Account__c, sign * principalDue, 'Principal repaid'),
                    new SABSubledgerPostingHelper.LineSpec(loan.Accrued_Interest_Account__c, sign * interest, 'Interest settled'),
                    new SABSubledgerPostingHelper.LineSpec(store.bankGl(loan.Bank_Account__c), -sign * (principalDue + interest), 'Repayment')});
            Boolean last = !store.otherUnpaid(loan.Id, line.Id);
            new Writer().line(new Loan_Schedule_Line__c(Id = line.Id, Status__c = 'Paid', Repayment_Journal__c = posted.journalEntryId),
                last ? new Loan__c(Id = loan.Id, Status__c = 'Closed') : null,
                audit(loan, 'LOAN_REPAYMENT_RECORDED', key, line.Id, 'Instalment ' + line.Sequence__c + ' repaid' + (last ? '; loan closed.' : '.')));
            return result(line.Id, 'Paid', posted.journalEntryId, false);
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
    }

    // --------------------------------------------------------------- helpers

    @TestVisible
    private static Boolean isAsset(String loanType) {
        return loanType == 'Lending';
    }

    private static void validateAccounts(Id companyId, String loanType, Id principalId, Id interestId, Id accruedId, Id bankId, String functional) {
        if (principalId == null || interestId == null || accruedId == null || bankId == null) {
            throw new LoanException('Principal, interest and accrued interest accounts and a bank account are required.');
        }
        Boolean asset = isAsset(loanType);
        Map<Id, String> expected = new Map<Id, String>{principalId => asset ? 'Asset' : 'Liability',
            interestId => asset ? 'Revenue' : 'Expense', accruedId => asset ? 'Asset' : 'Liability'};
        if (expected.size() != 3) {
            throw new LoanException('Principal, interest and accrued interest must be three different accounts.');
        }
        for (GL_Account__c a : [SELECT Id, Company__c, Is_Active__c, Account_Type__c FROM GL_Account__c WHERE Id IN :expected.keySet()
                WITH USER_MODE]) {
            if (a.Company__c != companyId || a.Is_Active__c != true || a.Account_Type__c != expected.get(a.Id)) {
                throw new LoanException('Loan accounts must be active accounts of the company: principal and accrued interest '
                    + (asset ? 'Asset' : 'Liability') + ', interest ' + (asset ? 'Revenue' : 'Expense') + '.');
            }
            expected.remove(a.Id);
        }
        if (!expected.isEmpty()) {
            throw new LoanException('A loan GL account was not found or is not accessible.');
        }
        List<Bank_Account__c> banks = [SELECT Id, Company__c, Is_Active__c, Currency__c FROM Bank_Account__c WHERE Id = :bankId WITH USER_MODE];
        if (banks.isEmpty() || banks[0].Company__c != companyId || banks[0].Is_Active__c != true || banks[0].Currency__c != functional) {
            throw new LoanException('The bank account must be an active ' + functional + ' bank account of the company.');
        }
    }

    private static Loan__c visibleLoan(Id loanId) {
        if (loanId == null) {
            throw new LoanException('Loan is required.');
        }
        List<Loan__c> rows = [SELECT Id, Company__c FROM Loan__c WHERE Id = :loanId WITH USER_MODE];
        if (rows.isEmpty()) {
            throw new LoanException('Loan not found or not accessible.');
        }
        SABCompanyAccessService.assertCompanyAccess(rows[0].Company__c);
        return rows[0];
    }

    private static Loan__c loadActive(Id loanId, Store store) {
        visibleLoan(loanId);
        Loan__c loan = store.lockLoan(loanId);
        if (loan.Status__c != 'Active') {
            throw new LoanException('The loan is not Active.');
        }
        return loan;
    }

    private static SABPostingService.PostingResult post(Loan__c loan, String stage, Id sourceId, Date onDate, String key, String description,
            List<SABSubledgerPostingHelper.LineSpec> lines) {
        SABSubledgerPostingHelper.PostingSpec spec = new SABSubledgerPostingHelper.PostingSpec();
        spec.companyId = loan.Company__c;
        spec.accountingDate = onDate;
        spec.description = description;
        spec.adapterKey = ADAPTER;
        spec.eventKey = 'LOAN|' + sourceId + '|' + stage;
        spec.eventType = 'Loan';
        spec.sourceType = SOURCE_TYPE;
        spec.sourceRecordId = sourceId;
        spec.sourceBusinessKey = 'LOAN|' + loan.Id + '|' + stage;
        spec.requestKey = key;
        spec.lines = lines;
        return SABSubledgerPostingHelper.post(spec);
    }

    private static String requireKey(String requestKey) {
        Integer maxLength = Business_Action__c.Request_Key__c.getDescribe().getLength();
        if (String.isBlank(requestKey) || requestKey.trim().length() > maxLength) {
            throw new LoanException('Request key is required and must not exceed ' + maxLength + ' characters.');
        }
        return requestKey.trim();
    }

    private static ActionResult replay(Business_Action__c prior, Id recordId, String expectedAction, Store store) {
        if (prior.Action__c != expectedAction || prior.Source_Record_Id__c != String.valueOf(recordId)) {
            throw new LoanException('Request key has already been used for a different loan action.');
        }
        String status = expectedAction == 'LOAN_APPROVED' ? store.lockLoan(recordId).Status__c : store.lockLine(recordId).Status__c;
        return result(recordId, status, null, true);
    }

    private static Business_Action__c audit(Loan__c loan, String actionName, String key, Id recordId, String reason) {
        return new Business_Action__c(Company__c = loan.Company__c, Action__c = actionName, Actor__c = UserInfo.getUserId(),
            Action_At__c = System.now(), Reason__c = reason, Request_Key__c = key, Source_Type__c = SOURCE_TYPE,
            Source_Record_Id__c = String.valueOf(recordId), Source_Version__c = 1);
    }

    private static ActionResult result(Id recordId, String status, Id journalId, Boolean isReplay) {
        ActionResult r = new ActionResult();
        r.recordId = recordId;
        r.status = status;
        r.journalEntryId = journalId;
        r.replay = isReplay;
        return r;
    }

    /** Narrow system reads after the permission and company checks; schedules and audits are read completely. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c FROM Business_Action__c WHERE Request_Key__c = :key
                WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        String functionalCurrency(Id companyId) {
            return [SELECT Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE].Functional_Currency__c;
        }
        Loan__c lockLoan(Id loanId) {
            List<Loan__c> rows = [SELECT Id, Name, Company__c, Loan_Type__c, Status__c, Principal__c, Interest_Rate__c, Start_Date__c,
                Maturity_Date__c, Repayment_Frequency__c, Schedule_Method__c, Principal_Account__c, Interest_Account__c,
                Accrued_Interest_Account__c, Bank_Account__c, CreatedById FROM Loan__c WHERE Id = :loanId WITH SYSTEM_MODE FOR UPDATE];
            if (rows.isEmpty()) {
                throw new LoanException('Loan not found.');
            }
            return rows[0];
        }
        Loan_Schedule_Line__c lockLine(Id lineId) {
            List<Loan_Schedule_Line__c> rows = [SELECT Id, Loan__c, Sequence__c, Due_Date__c, Principal_Due__c, Interest_Due__c, Status__c
                FROM Loan_Schedule_Line__c WHERE Id = :lineId WITH SYSTEM_MODE FOR UPDATE];
            if (rows.isEmpty()) {
                throw new LoanException('Loan schedule line not found.');
            }
            return rows[0];
        }
        Boolean unpaidEarlier(Id loanId, Decimal sequence) {
            return [SELECT COUNT() FROM Loan_Schedule_Line__c WHERE Loan__c = :loanId AND Sequence__c < :sequence AND Status__c != 'Paid'
                WITH SYSTEM_MODE] > 0;
        }
        Boolean otherUnpaid(Id loanId, Id lineId) {
            return [SELECT COUNT() FROM Loan_Schedule_Line__c WHERE Loan__c = :loanId AND Id != :lineId AND Status__c != 'Paid'
                WITH SYSTEM_MODE] > 0;
        }
        Id bankGl(Id bankAccountId) {
            return [SELECT GL_Account__c FROM Bank_Account__c WHERE Id = :bankAccountId WITH SYSTEM_MODE].GL_Account__c;
        }
    }

    /** Narrow system writes inside the G16 guard scope, after the service's checks (explicit system mode). */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void upsertLoan(Loan__c loan) {
            SABLoanInvestmentGuard.beginWrite();
            try {
                upsert as system loan;
            } finally {
                SABLoanInvestmentGuard.endWrite();
            }
        }
        void approve(Loan__c loan, List<Loan_Schedule_Line__c> lines, Business_Action__c audit) {
            SABLoanInvestmentGuard.beginWrite();
            try {
                update as system loan;
                insert as system lines;
                insert as system audit;
            } finally {
                SABLoanInvestmentGuard.endWrite();
            }
        }
        void line(Loan_Schedule_Line__c line, Loan__c loan, Business_Action__c audit) {
            SABLoanInvestmentGuard.beginWrite();
            try {
                update as system line;
                if (loan != null) {
                    update as system loan;
                }
                insert as system audit;
            } finally {
                SABLoanInvestmentGuard.endWrite();
            }
        }
    }
}
