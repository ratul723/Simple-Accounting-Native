/**
 * G16: Investments.
 *
 *   saveInvestment     SAB_Manage_Investments                    create an investment, or change its mapping before any transaction
 *   recordTransaction  SAB_Manage_Investments + SAB_Post_Journal  record and post one transaction
 *   getHolding         read                                       quantity held and carrying amount from posted transactions
 *
 * Valuation policy (Valuation_Policy_Key__c): COST, or FVTPL (fair value through profit or loss).
 *   Acquisition  Dr Investment / Cr Bank                 (amount > 0, quantity > 0)
 *   Income       Dr Bank / Cr Income                     (dividends, interest; amount > 0)
 *   Fee          Dr Fee / Cr Bank                        (amount > 0)
 *   Valuation    FVTPL only; signed fair value change: gain Dr Investment / Cr Gain-Loss, loss the reverse
 *   Disposal     amount = proceeds; relieves the average carrying amount for the quantity sold:
 *                Dr Bank (proceeds) / Cr Investment (carrying relieved) / gain or loss to Gain-Loss. A full disposal
 *                marks the investment Disposed.
 * Functional currency only. Postings are Subledger journals (event type Investment). Every transaction is idempotent
 * by request key and audited.
 */
public with sharing class SABInvestmentService {
    public class InvestmentException extends Exception {}

    private static final String MANAGE = 'SAB_Manage_Investments';
    private static final String POST_JOURNAL = 'SAB_Post_Journal';
    private static final Set<String> POLICIES = new Set<String>{'COST', 'FVTPL'};
    private static final Set<String> TRANSACTION_TYPES = new Set<String>{'Acquisition', 'Disposal', 'Income', 'Fee', 'Valuation'};
    private static final String ADAPTER = 'INVESTMENT';
    private static final String SOURCE_TYPE = 'Investment_Transaction__c';

    public class InvestmentRequest {
        @AuraEnabled public Id investmentId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String instrumentKey { get; set; }
        @AuraEnabled public String classification { get; set; }
        @AuraEnabled public String valuationPolicy { get; set; }
        @AuraEnabled public Id counterpartyAccountId { get; set; }
        @AuraEnabled public Id investmentAccountId { get; set; }
        @AuraEnabled public Id incomeAccountId { get; set; }
        @AuraEnabled public Id gainLossAccountId { get; set; }
        @AuraEnabled public Id feeAccountId { get; set; }
        @AuraEnabled public Id bankAccountId { get; set; }
    }

    public class TransactionRequest {
        @AuraEnabled public Id investmentId { get; set; }
        @AuraEnabled public String transactionType { get; set; }
        @AuraEnabled public Date transactionDate { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
    }

    public class Holding {
        @AuraEnabled public Decimal quantity = 0;
        @AuraEnabled public Decimal carryingAmount = 0;
    }

    public class ActionResult {
        @AuraEnabled public Id transactionId;
        @AuraEnabled public Id journalEntryId;
        @AuraEnabled public Decimal carryingAmountRelieved;
        @AuraEnabled public Decimal realizedGainLoss;
        @AuraEnabled public String investmentStatus;
        @AuraEnabled public Boolean replay;
    }

    // ----------------------------------------------------------- investments

    @AuraEnabled
    public static Id saveInvestment(InvestmentRequest request) {
        SABPermissionService.assertPermission(MANAGE, 'Investment management permission is required.');
        if (request == null || request.companyId == null || String.isBlank(request.name) || String.isBlank(request.instrumentKey)
            || String.isBlank(request.classification) || String.isBlank(request.valuationPolicy)) {
            throw new InvestmentException('Company, name, instrument key, classification and valuation policy are required.');
        }
        SABCompanyAccessService.assertCompanyAccess(request.companyId);
        String policy = request.valuationPolicy.trim().toUpperCase();
        if (!POLICIES.contains(policy)) {
            throw new InvestmentException('Valuation policy must be COST or FVTPL.');
        }
        if (request.name.trim().length() > 80 || request.instrumentKey.trim().length() > 80 || request.classification.trim().length() > 80) {
            throw new InvestmentException('Name, instrument key and classification cannot exceed 80 characters.');
        }
        Store store = new Store();
        String functional = store.functionalCurrency(request.companyId);
        validateAccounts(request, functional);
        Investment__c investment;
        if (request.investmentId != null) {
            visibleInvestment(request.investmentId);
            investment = store.lockInvestment(request.investmentId);
            if (investment.Company__c != request.companyId) {
                throw new InvestmentException('An investment cannot move to another company.');
            }
            if (store.hasTransactions(investment.Id)) {
                throw new InvestmentException('The mapping and policy of an investment with transactions cannot change.');
            }
        } else {
            investment = new Investment__c(Company__c = request.companyId, Status__c = 'Active');
        }
        investment.Name = request.name.trim();
        investment.Instrument_Key__c = request.instrumentKey.trim();
        investment.Classification__c = request.classification.trim();
        investment.Valuation_Policy_Key__c = policy;
        investment.Counterparty_Account__c = request.counterpartyAccountId;
        investment.Currency__c = functional;
        investment.Investment_Account__c = request.investmentAccountId;
        investment.Income_Account__c = request.incomeAccountId;
        investment.Gain_Loss_Account__c = request.gainLossAccountId;
        investment.Fee_Account__c = request.feeAccountId;
        investment.Bank_Account__c = request.bankAccountId;
        new Writer().saveInvestment(investment);
        return investment.Id;
    }

    @AuraEnabled
    public static Holding getHolding(Id investmentId) {
        visibleInvestment(investmentId);
        return holding(new Store().postedTransactions(investmentId));
    }

    // ---------------------------------------------------------- transactions

    @AuraEnabled
    public static ActionResult recordTransaction(TransactionRequest request, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(MANAGE, 'Investment management permission is required.');
        SABPermissionService.assertPermission(POST_JOURNAL, 'Journal posting permission is required.');
        if (request == null || request.investmentId == null || request.transactionDate == null || request.amount == null
            || !TRANSACTION_TYPES.contains(request.transactionType)) {
            throw new InvestmentException('Investment, transaction type, date and amount are required.');
        }
        visibleInvestment(request.investmentId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            if (prior.Action__c != 'INVESTMENT_TRANSACTION_POSTED' || prior.Reason__c == null
                    || !prior.Reason__c.startsWith(String.valueOf(request.investmentId))) {
                throw new InvestmentException('Request key has already been used for a different investment action.');
            }
            Investment_Transaction__c done = store.transactionById(Id.valueOf(prior.Source_Record_Id__c));
            return result(done, store.lockInvestment(request.investmentId).Status__c, true);
        }
        Investment__c investment = store.lockInvestment(request.investmentId);
        if (investment.Status__c != 'Active') {
            throw new InvestmentException('Transactions can be recorded only on an Active investment.');
        }
        String type = request.transactionType;
        Decimal amount = request.amount.setScale(2, RoundingMode.HALF_UP);
        Decimal quantity = request.quantity;
        Holding held = holding(store.postedTransactions(investment.Id));
        Investment_Transaction__c tx = new Investment_Transaction__c(Investment__c = investment.Id, Transaction_Type__c = type,
            Transaction_Date__c = request.transactionDate, Accounting_Date__c = request.transactionDate, Amount__c = amount,
            Currency__c = investment.Currency__c, Quantity__c = quantity);
        Id bankGl = store.bankGl(investment.Bank_Account__c);
        List<SABSubledgerPostingHelper.LineSpec> lines;
        Boolean disposed = false;
        if (type == 'Acquisition') {
            requirePositive(amount, 'Acquisition amount');
            requirePositive(quantity, 'Acquisition quantity');
            lines = pair(investment.Investment_Account__c, bankGl, amount, 'Acquisition');
        } else if (type == 'Income') {
            requirePositive(amount, 'Income amount');
            tx.Quantity__c = null;
            lines = pair(bankGl, investment.Income_Account__c, amount, 'Investment income');
        } else if (type == 'Fee') {
            requirePositive(amount, 'Fee amount');
            tx.Quantity__c = null;
            lines = pair(investment.Fee_Account__c, bankGl, amount, 'Investment fee');
        } else if (type == 'Valuation') {
            if (investment.Valuation_Policy_Key__c != 'FVTPL') {
                throw new InvestmentException('Valuation changes are recorded only for FVTPL investments.');
            }
            if (amount == 0 || held.quantity <= 0) {
                throw new InvestmentException('A valuation needs a non-zero change on an investment that is held.');
            }
            tx.Quantity__c = null;
            lines = pair(investment.Investment_Account__c, investment.Gain_Loss_Account__c, amount, 'Fair value change');
        } else {
            if (amount < 0) {
                throw new InvestmentException('Disposal proceeds cannot be negative.');
            }
            requirePositive(quantity, 'Disposal quantity');
            if (quantity > held.quantity) {
                throw new InvestmentException('Cannot dispose of ' + quantity.stripTrailingZeros().toPlainString() + ' units; '
                    + held.quantity.stripTrailingZeros().toPlainString() + ' are held.');
            }
            disposed = quantity == held.quantity;
            Decimal relieved = disposed ? held.carryingAmount : (held.carryingAmount * quantity / held.quantity).setScale(2, RoundingMode.HALF_UP);
            Decimal gain = amount - relieved;
            tx.Carrying_Amount_Relieved__c = relieved;
            tx.Realized_Gain_Loss__c = gain;
            lines = new List<SABSubledgerPostingHelper.LineSpec>{
                new SABSubledgerPostingHelper.LineSpec(bankGl, amount, 'Disposal proceeds'),
                new SABSubledgerPostingHelper.LineSpec(investment.Investment_Account__c, -relieved, 'Carrying amount relieved'),
                new SABSubledgerPostingHelper.LineSpec(investment.Gain_Loss_Account__c, -gain, gain >= 0 ? 'Realized gain' : 'Realized loss')};
        }
        Savepoint sp = Database.setSavepoint();
        try {
            Writer writer = new Writer();
            writer.insertTransaction(tx);
            SABSubledgerPostingHelper.PostingSpec spec = new SABSubledgerPostingHelper.PostingSpec();
            spec.companyId = investment.Company__c;
            spec.accountingDate = tx.Accounting_Date__c;
            spec.description = ('Investment ' + type.toLowerCase() + ' ' + investment.Name).left(255);
            spec.adapterKey = ADAPTER;
            spec.eventKey = 'INVESTMENT|' + tx.Id;
            spec.eventType = 'Investment';
            spec.sourceType = SOURCE_TYPE;
            spec.sourceRecordId = tx.Id;
            spec.sourceBusinessKey = 'INVESTMENT|' + investment.Instrument_Key__c + '|' + type;
            spec.requestKey = key;
            spec.lines = lines;
            SABPostingService.PostingResult postingResult = SABSubledgerPostingHelper.post(spec);
            tx.Journal_Entry__c = postingResult.journalEntryId;
            tx.Accounting_Event__c = postingResult.accountingEventId;
            writer.complete(tx, disposed ? new Investment__c(Id = investment.Id, Status__c = 'Disposed') : null,
                new Business_Action__c(Company__c = investment.Company__c, Action__c = 'INVESTMENT_TRANSACTION_POSTED',
                    Actor__c = UserInfo.getUserId(), Action_At__c = System.now(), Request_Key__c = key, Source_Type__c = SOURCE_TYPE,
                    Source_Record_Id__c = String.valueOf(tx.Id), Source_Version__c = 1,
                    Reason__c = String.valueOf(investment.Id) + ': ' + type + ' ' + amount + (disposed ? '; investment disposed.' : '.')));
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
        return result(tx, disposed ? 'Disposed' : 'Active', false);
    }

    // --------------------------------------------------------------- helpers

    /** Quantity and carrying amount from posted transactions (journal attached). */
    @TestVisible
    private static Holding holding(List<Investment_Transaction__c> posted) {
        Holding h = new Holding();
        for (Investment_Transaction__c t : posted) {
            if (t.Transaction_Type__c == 'Acquisition') {
                h.quantity += t.Quantity__c == null ? 0 : t.Quantity__c;
                h.carryingAmount += t.Amount__c;
            } else if (t.Transaction_Type__c == 'Valuation') {
                h.carryingAmount += t.Amount__c;
            } else if (t.Transaction_Type__c == 'Disposal') {
                h.quantity -= t.Quantity__c == null ? 0 : t.Quantity__c;
                h.carryingAmount -= t.Carrying_Amount_Relieved__c == null ? 0 : t.Carrying_Amount_Relieved__c;
            }
        }
        return h;
    }

    // Signed pair: amount > 0 debits the first account and credits the second; amount < 0 does the reverse.
    private static List<SABSubledgerPostingHelper.LineSpec> pair(Id debitAccount, Id creditAccount, Decimal amount, String explanation) {
        return new List<SABSubledgerPostingHelper.LineSpec>{
            new SABSubledgerPostingHelper.LineSpec(debitAccount, amount, explanation),
            new SABSubledgerPostingHelper.LineSpec(creditAccount, -amount, explanation)};
    }

    private static void requirePositive(Decimal value, String label) {
        if (value == null || value <= 0) {
            throw new InvestmentException(label + ' must be greater than zero.');
        }
    }

    // Each role is checked on its own account, so one account used for two roles cannot hide a type mismatch.
    private static void validateAccounts(InvestmentRequest r, String functional) {
        Map<String, Id> roles = new Map<String, Id>{'investment' => r.investmentAccountId, 'income' => r.incomeAccountId,
            'gainLoss' => r.gainLossAccountId, 'fee' => r.feeAccountId};
        if (roles.values().contains(null) || r.bankAccountId == null) {
            throw new InvestmentException('Investment, income, gain/loss and fee accounts and a bank account are required.');
        }
        Map<String, Set<String>> allowed = new Map<String, Set<String>>{'investment' => new Set<String>{'Asset'},
            'income' => new Set<String>{'Revenue'}, 'gainLoss' => new Set<String>{'Revenue', 'Expense'}, 'fee' => new Set<String>{'Expense'}};
        Set<Id> accountIds = new Set<Id>(roles.values());
        Map<Id, GL_Account__c> accounts = new Map<Id, GL_Account__c>([SELECT Id, Company__c, Is_Active__c, Account_Type__c FROM GL_Account__c
            WHERE Id IN :accountIds WITH USER_MODE]);
        for (String role : roles.keySet()) {
            GL_Account__c a = accounts.get(roles.get(role));
            if (a == null) {
                throw new InvestmentException('An investment GL account was not found or is not accessible.');
            }
            if (a.Company__c != r.companyId || a.Is_Active__c != true || !allowed.get(role).contains(a.Account_Type__c)) {
                throw new InvestmentException('Investment accounts must be active accounts of the company: investment Asset, income Revenue, '
                    + 'fee Expense, gain/loss Revenue or Expense.');
            }
        }
        List<Bank_Account__c> banks = [SELECT Id, Company__c, Is_Active__c, Currency__c FROM Bank_Account__c WHERE Id = :r.bankAccountId
            WITH USER_MODE];
        if (banks.isEmpty() || banks[0].Company__c != r.companyId || banks[0].Is_Active__c != true || banks[0].Currency__c != functional) {
            throw new InvestmentException('The bank account must be an active ' + functional + ' bank account of the company.');
        }
    }

    private static Investment__c visibleInvestment(Id investmentId) {
        if (investmentId == null) {
            throw new InvestmentException('Investment is required.');
        }
        List<Investment__c> rows = [SELECT Id, Company__c FROM Investment__c WHERE Id = :investmentId WITH USER_MODE];
        if (rows.isEmpty()) {
            throw new InvestmentException('Investment not found or not accessible.');
        }
        SABCompanyAccessService.assertCompanyAccess(rows[0].Company__c);
        return rows[0];
    }

    private static String requireKey(String requestKey) {
        Integer maxLength = Business_Action__c.Request_Key__c.getDescribe().getLength();
        if (String.isBlank(requestKey) || requestKey.trim().length() > maxLength) {
            throw new InvestmentException('Request key is required and must not exceed ' + maxLength + ' characters.');
        }
        return requestKey.trim();
    }

    private static ActionResult result(Investment_Transaction__c tx, String investmentStatus, Boolean isReplay) {
        ActionResult r = new ActionResult();
        r.transactionId = tx.Id;
        r.journalEntryId = tx.Journal_Entry__c;
        r.carryingAmountRelieved = tx.Carrying_Amount_Relieved__c;
        r.realizedGainLoss = tx.Realized_Gain_Loss__c;
        r.investmentStatus = investmentStatus;
        r.replay = isReplay;
        return r;
    }

    /** Narrow system reads after the permission and company checks; holdings use every posted transaction. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c, Reason__c FROM Business_Action__c
                WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        String functionalCurrency(Id companyId) {
            return [SELECT Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE].Functional_Currency__c;
        }
        Investment__c lockInvestment(Id investmentId) {
            return [SELECT Id, Name, Company__c, Status__c, Currency__c, Instrument_Key__c, Valuation_Policy_Key__c, Investment_Account__c,
                Income_Account__c, Gain_Loss_Account__c, Fee_Account__c, Bank_Account__c FROM Investment__c WHERE Id = :investmentId
                WITH SYSTEM_MODE FOR UPDATE];
        }
        Boolean hasTransactions(Id investmentId) {
            return [SELECT COUNT() FROM Investment_Transaction__c WHERE Investment__c = :investmentId WITH SYSTEM_MODE] > 0;
        }
        List<Investment_Transaction__c> postedTransactions(Id investmentId) {
            return [SELECT Id, Transaction_Type__c, Amount__c, Quantity__c, Carrying_Amount_Relieved__c FROM Investment_Transaction__c
                WHERE Investment__c = :investmentId AND Journal_Entry__c != null WITH SYSTEM_MODE ORDER BY Transaction_Date__c, CreatedDate
                LIMIT 10000];
        }
        Investment_Transaction__c transactionById(Id txId) {
            return [SELECT Id, Journal_Entry__c, Carrying_Amount_Relieved__c, Realized_Gain_Loss__c FROM Investment_Transaction__c
                WHERE Id = :txId WITH SYSTEM_MODE];
        }
        Id bankGl(Id bankAccountId) {
            return [SELECT GL_Account__c FROM Bank_Account__c WHERE Id = :bankAccountId WITH SYSTEM_MODE].GL_Account__c;
        }
    }

    /** Narrow system writes inside the G16 guard scope, after the service's checks (explicit system mode). */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void saveInvestment(Investment__c investment) {
            SABLoanInvestmentGuard.beginWrite();
            try {
                upsert as system investment;
            } finally {
                SABLoanInvestmentGuard.endWrite();
            }
        }
        void insertTransaction(Investment_Transaction__c tx) {
            SABLoanInvestmentGuard.beginWrite();
            try {
                insert as system tx;
            } finally {
                SABLoanInvestmentGuard.endWrite();
            }
        }
        void complete(Investment_Transaction__c tx, Investment__c investment, Business_Action__c audit) {
            SABLoanInvestmentGuard.beginWrite();
            try {
                update as system new Investment_Transaction__c(Id = tx.Id, Journal_Entry__c = tx.Journal_Entry__c,
                    Accounting_Event__c = tx.Accounting_Event__c);
                if (investment != null) {
                    update as system investment;
                }
                insert as system audit;
            } finally {
                SABLoanInvestmentGuard.endWrite();
            }
        }
    }
}
