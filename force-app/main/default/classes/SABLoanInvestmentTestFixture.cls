/**
 * G16: shared test data for loan and investment tests, lean by design (SABTestGovernor rules).
 *
 * Users (System Administrator profile; access comes from the G16 permission sets):
 *   manager   Loan User + Investment User + Manage Loans + Manage Investments + Post Journal
 *   approver  Loan User + Approve Loans + Post Journal
 *   outsider  Loan User + Investment User + Manage Loans + Manage Investments, no company grant
 * Company 'L16' (USD): periods Jan-Apr 2026 Open. GL 1100 Bank, 1300 Loan receivable, 1310 Interest receivable,
 * 1500 Investments, 2500 Loan payable, 2510 Interest payable, 4700 Interest income, 4800 Investment income,
 * 4900 Investment gain/loss, 6800 Interest expense, 6900 Investment fees. USD bank account on 1100.
 */
@IsTest
public class SABLoanInvestmentTestFixture {
    public static final String MANAGER = 'SAB L16 Manager';
    public static final String APPROVER = 'SAB L16 Approver';
    public static final String OUTSIDER = 'SAB L16 Outsider';

    private static Map<String, User> users = new Map<String, User>();
    private static Map<String, Id> ids = new Map<String, Id>();

    public static void createFixture() {
        User managerUser;
        User approverUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            managerUser = newUser(MANAGER, 'l16mgr', unique);
            approverUser = newUser(APPROVER, 'l16apr', unique);
            User outsiderUser = newUser(OUTSIDER, 'l16out', unique);
            insert as system new List<User>{managerUser, approverUser, outsiderUser};
            Map<Id, Set<String>> setsByUser = new Map<Id, Set<String>>{
                managerUser.Id => new Set<String>{'SAB_Loan_User', 'SAB_Investment_User', 'SAB_Manage_Loans_Action', 'SAB_Manage_Investments_Action',
                    'SAB_Post_Journal_Action'},
                approverUser.Id => new Set<String>{'SAB_Loan_User', 'SAB_Approve_Loans_Action', 'SAB_Post_Journal_Action'},
                outsiderUser.Id => new Set<String>{'SAB_Loan_User', 'SAB_Investment_User', 'SAB_Manage_Loans_Action', 'SAB_Manage_Investments_Action'}};
            Map<String, Id> setIds = new Map<String, Id>();
            for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN ('SAB_Loan_User', 'SAB_Investment_User', 'SAB_Manage_Loans_Action',
                    'SAB_Manage_Investments_Action', 'SAB_Approve_Loans_Action', 'SAB_Post_Journal_Action') WITH SYSTEM_MODE]) {
                setIds.put(p.Name, p.Id);
            }
            System.assertEquals(6, setIds.size(), 'Deploy the G16 permission sets and SAB_Post_Journal_Action first.');
            List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
            for (Id userId : setsByUser.keySet()) {
                for (String name : setsByUser.get(userId)) {
                    rows.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = setIds.get(name)));
                }
            }
            insert as system rows;
        }
        System.runAs(managerUser) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'L16 Company', Company_Key__c = 'L16', Country_Code__c = 'BD',
                Functional_Currency__c = 'USD', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active', Is_Active__c = true);
            insert as system company;
            insert as system new List<Company_User_Access__c>{
                new Company_User_Access__c(Company__c = company.Id, User__c = managerUser.Id, Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'L16-MANAGER', Role__c = 'Finance Manager'),
                new Company_User_Access__c(Company__c = company.Id, User__c = approverUser.Id, Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'L16-APPROVER', Role__c = 'Finance Manager')};
            List<Accounting_Period__c> periods = new List<Accounting_Period__c>();
            for (Integer month = 1; month <= 4; month++) {
                Date starts = Date.newInstance(2026, month, 1);
                String key = 'L16-2026-0' + month;
                periods.add(new Accounting_Period__c(Name = key, Company__c = company.Id, Company_Period_Key__c = key, Period_Key__c = key,
                    Start_Date__c = starts, End_Date__c = starts.addMonths(1).addDays(-1), Fiscal_Year__c = 2026, Fiscal_Quarter__c = ((month - 1) / 3) + 1,
                    Period_Number__c = month, Status__c = 'Open'));
            }
            insert as system periods;
            Map<String, List<String>> accounts = new Map<String, List<String>>{
                '1100' => new List<String>{'Bank', 'Asset', 'Debit'}, '1300' => new List<String>{'Loan receivable', 'Asset', 'Debit'},
                '1310' => new List<String>{'Interest receivable', 'Asset', 'Debit'}, '1500' => new List<String>{'Investments', 'Asset', 'Debit'},
                '2500' => new List<String>{'Loan payable', 'Liability', 'Credit'}, '2510' => new List<String>{'Interest payable', 'Liability', 'Credit'},
                '4700' => new List<String>{'Interest income', 'Revenue', 'Credit'}, '4800' => new List<String>{'Investment income', 'Revenue', 'Credit'},
                '4900' => new List<String>{'Investment gain or loss', 'Revenue', 'Credit'}, '6800' => new List<String>{'Interest expense', 'Expense', 'Debit'},
                '6900' => new List<String>{'Investment fees', 'Expense', 'Debit'}};
            List<GL_Account__c> rows = new List<GL_Account__c>();
            for (String code : accounts.keySet()) {
                List<String> a = accounts.get(code);
                rows.add(new GL_Account__c(Name = a[0], Company__c = company.Id, Company_Account_Key__c = 'L16-' + code, Account_Code__c = code,
                    Account_Type__c = a[1], Normal_Balance__c = a[2], Is_Active__c = true, Is_Control_Account__c = false, Control_Type__c = 'None',
                    Manual_Posting_Allowed__c = true));
            }
            insert as system rows;
            insert as system new Bank_Account__c(Name = 'L16 Operating', Company__c = company.Id, Currency__c = 'USD',
                GL_Account__c = accountId('1100'), Is_Active__c = true);
            insert as system new Account(Name = 'L16 Counterparty Bank');
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static User newUser(String lastName, String alias, String unique) {
        return new User(Username = alias + '.' + unique + '@example.invalid', Email = alias + '@example.invalid', LastName = lastName,
            Alias = alias, TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', ProfileId = UserInfo.getProfileId());
    }

    public static User user(String lastName) {
        if (!users.containsKey(lastName)) {
            users.put(lastName, [SELECT Id FROM User WHERE LastName = :lastName AND Alias LIKE 'l16%' WITH SYSTEM_MODE LIMIT 1]);
        }
        return users.get(lastName);
    }

    private static Id cached(String key, String soql) {
        if (!ids.containsKey(key)) {
            ids.put(key, Database.query(soql, AccessLevel.SYSTEM_MODE).Id);
        }
        return ids.get(key);
    }

    public static Id companyId() {
        return cached('company', 'SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = \'L16\' LIMIT 1');
    }

    public static Id accountId(String code) {
        return cached('gl' + code, 'SELECT Id FROM GL_Account__c WHERE Company_Account_Key__c = \'L16-' + String.escapeSingleQuotes(code) + '\' LIMIT 1');
    }

    public static Id bankAccountId() {
        return cached('bank', 'SELECT Id FROM Bank_Account__c WHERE Name = \'L16 Operating\' LIMIT 1');
    }

    public static Id counterpartyId() {
        return cached('counterparty', 'SELECT Id FROM Account WHERE Name = \'L16 Counterparty Bank\' LIMIT 1');
    }

    /** Loan request for 12,000 at 12% from 1 Jan 2026, three monthly instalments; borrowing or lending accounts by type. */
    public static SABLoanService.LoanRequest loanRequest(String loanType, String method) {
        Boolean lending = loanType == 'Lending';
        SABLoanService.LoanRequest r = new SABLoanService.LoanRequest();
        r.companyId = companyId();
        r.name = 'L16 ' + loanType;
        r.loanType = loanType;
        r.counterpartyAccountId = counterpartyId();
        r.principal = 12000;
        r.annualRatePercent = 12;
        r.startDate = Date.newInstance(2026, 1, 1);
        r.maturityDate = Date.newInstance(2026, 4, 1);
        r.repaymentFrequency = 'Monthly';
        r.scheduleMethod = method;
        r.principalAccountId = accountId(lending ? '1300' : '2500');
        r.interestAccountId = accountId(lending ? '4700' : '6800');
        r.accruedInterestAccountId = accountId(lending ? '1310' : '2510');
        r.bankAccountId = bankAccountId();
        return r;
    }

    /** Draft loan from loanRequest, seeded through the guard scope and created by the running user. */
    public static Id seedDraftLoan(String loanType, String method, Date maturityDate) {
        SABLoanService.LoanRequest r = loanRequest(loanType, method);
        Loan__c loan = new Loan__c(Name = r.name, Company__c = r.companyId, Loan_Type__c = r.loanType, Counterparty_Account__c = r.counterpartyAccountId,
            Currency__c = 'USD', Principal__c = r.principal, Interest_Rate__c = r.annualRatePercent, Start_Date__c = r.startDate,
            Maturity_Date__c = maturityDate, Repayment_Frequency__c = r.repaymentFrequency, Schedule_Method__c = r.scheduleMethod,
            Principal_Account__c = r.principalAccountId, Interest_Account__c = r.interestAccountId,
            Accrued_Interest_Account__c = r.accruedInterestAccountId, Bank_Account__c = r.bankAccountId, Status__c = 'Draft');
        SABLoanInvestmentGuard.beginWrite();
        try {
            insert as system loan;
        } finally {
            SABLoanInvestmentGuard.endWrite();
        }
        return loan.Id;
    }

    /**
     * Active loan with its schedule seeded through the guard scope (no drawdown posting), so repayment tests spend their
     * queries on the postings under test. lineStatuses gives each instalment's status in order.
     */
    public static Id seedActiveLoan(String loanType, String method, Date maturityDate, List<String> lineStatuses) {
        Id loanId = seedDraftLoan(loanType, method, maturityDate);
        List<SABLoanScheduleCalculator.Instalment> schedule = SABLoanScheduleCalculator.build(12000, 12, Date.newInstance(2026, 1, 1),
            maturityDate, 'Monthly', method);
        List<Loan_Schedule_Line__c> lines = new List<Loan_Schedule_Line__c>();
        for (SABLoanScheduleCalculator.Instalment i : schedule) {
            lines.add(new Loan_Schedule_Line__c(Loan__c = loanId, Sequence__c = i.sequence, Due_Date__c = i.dueDate, Principal_Due__c = i.principalDue,
                Interest_Due__c = i.interestDue, Principal_Balance__c = i.closingBalance, Status__c = lineStatuses[i.sequence - 1]));
        }
        SABLoanInvestmentGuard.beginWrite();
        try {
            update as system new Loan__c(Id = loanId, Status__c = 'Active');
            insert as system lines;
        } finally {
            SABLoanInvestmentGuard.endWrite();
        }
        return loanId;
    }

    public static SABInvestmentService.InvestmentRequest investmentRequest(String policy) {
        SABInvestmentService.InvestmentRequest r = new SABInvestmentService.InvestmentRequest();
        r.companyId = companyId();
        r.name = 'L16 Equity Fund';
        r.instrumentKey = 'L16-FUND-' + policy;
        r.classification = 'Equity';
        r.valuationPolicy = policy;
        r.investmentAccountId = accountId('1500');
        r.incomeAccountId = accountId('4800');
        r.gainLossAccountId = accountId('4900');
        r.feeAccountId = accountId('6900');
        r.bankAccountId = bankAccountId();
        return r;
    }

    /**
     * Investment with a seeded holding: 100 units acquired for 10,000 and, for FVTPL, a +500 valuation. The seeded
     * transactions point at one Draft journal so holdings count them without spending posting queries.
     */
    public static Id seedHolding(String policy) {
        SABInvestmentService.InvestmentRequest r = investmentRequest(policy);
        Investment__c investment = new Investment__c(Name = r.name, Company__c = r.companyId, Instrument_Key__c = r.instrumentKey,
            Classification__c = r.classification, Valuation_Policy_Key__c = policy, Currency__c = 'USD', Status__c = 'Active',
            Investment_Account__c = r.investmentAccountId, Income_Account__c = r.incomeAccountId, Gain_Loss_Account__c = r.gainLossAccountId,
            Fee_Account__c = r.feeAccountId, Bank_Account__c = r.bankAccountId);
        Journal_Entry__c placeholder = new Journal_Entry__c(Company__c = r.companyId,
            Accounting_Period__c = [SELECT Id FROM Accounting_Period__c WHERE Company_Period_Key__c = 'L16-2026-01' WITH SYSTEM_MODE].Id,
            Accounting_Date__c = Date.newInstance(2026, 1, 5), Entry_Type__c = 'Manual', Status__c = 'Draft', Version__c = 1,
            Description__c = 'Seeded holding');
        insert as system placeholder;
        SABLoanInvestmentGuard.beginWrite();
        try {
            insert as system investment;
            List<Investment_Transaction__c> txs = new List<Investment_Transaction__c>{new Investment_Transaction__c(Investment__c = investment.Id,
                Transaction_Type__c = 'Acquisition', Transaction_Date__c = Date.newInstance(2026, 1, 5), Accounting_Date__c = Date.newInstance(2026, 1, 5),
                Amount__c = 10000, Quantity__c = 100, Currency__c = 'USD', Journal_Entry__c = placeholder.Id)};
            if (policy == 'FVTPL') {
                txs.add(new Investment_Transaction__c(Investment__c = investment.Id, Transaction_Type__c = 'Valuation',
                    Transaction_Date__c = Date.newInstance(2026, 1, 31), Accounting_Date__c = Date.newInstance(2026, 1, 31), Amount__c = 500,
                    Currency__c = 'USD', Journal_Entry__c = placeholder.Id));
            }
            insert as system txs;
        } finally {
            SABLoanInvestmentGuard.endWrite();
        }
        return investment.Id;
    }
}
