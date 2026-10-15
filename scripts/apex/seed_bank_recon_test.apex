// Simple Accounting Books - bank reconciliation test data.
// Creates GL 1060 + bank account "Recon Test Bank" (USD) in the company below and 8 journals on it.
// All journals are created as Draft. Then post RT-01..RT-07 with post_next_recon_journal.apex; keep RT-08 Draft for the test.
// Run: sf apex run --file scripts/apex/seed_bank_recon_test.apex --target-org devscratchorg
// The running user needs SAB_Post_Journal_Action and access to the company.

String COMPANY_NAME = 'Ratuls Company Ltd';   // change if needed (matches Name__c)
String BANK_CODE = '1060';

Accounting_Company__c company = [SELECT Id, Functional_Currency__c FROM Accounting_Company__c WHERE Name__c = :COMPANY_NAME LIMIT 1];
String cur = company.Functional_Currency__c;

// Accounting period that covers October 2026: prefer a full-month open period.
List<Accounting_Period__c> periods = [SELECT Id, Name, Start_Date__c, End_Date__c FROM Accounting_Period__c
    WHERE Company__c = :company.Id AND Status__c = 'Open' AND Start_Date__c <= 2026-10-01 AND End_Date__c >= 2026-10-13
    ORDER BY Start_Date__c DESC];
if (periods.isEmpty()) {
    throw new IllegalArgumentException('No open period covers 1-13 Oct 2026 for ' + COMPANY_NAME + '. Generate periods in Company setup first.');
}
Id periodId = periods[0].Id;

// GL account for the bank (normal asset, manual posting allowed so manual journals can use it).
List<GL_Account__c> existing = [SELECT Id FROM GL_Account__c WHERE Company__c = :company.Id AND Account_Code__c = :BANK_CODE LIMIT 1];
GL_Account__c bankGl;
if (existing.isEmpty()) {
    bankGl = new GL_Account__c(Name = 'Recon Test Bank - ' + cur, Company__c = company.Id, Account_Code__c = BANK_CODE,
        Company_Account_Key__c = String.valueOf(company.Id) + '-' + BANK_CODE, Account_Type__c = 'Asset', Normal_Balance__c = 'Debit',
        Control_Type__c = 'None', Is_Control_Account__c = false, Manual_Posting_Allowed__c = true, Is_Active__c = true);
    insert bankGl;
} else {
    bankGl = existing[0];
}
if ([SELECT COUNT() FROM Bank_Account__c WHERE GL_Account__c = :bankGl.Id] == 0) {
    insert new Bank_Account__c(Name = 'Recon Test Bank', Company__c = company.Id, Bank_Name__c = 'Recon Test Bank',
        Currency__c = cur, GL_Account__c = bankGl.Id, Masked_Account_Number__c = 'RT-****1060',
        Opening_Balance__c = 0, Opening_Balance_Date__c = Date.newInstance(2026, 10, 1), Is_Active__c = true);
}

// Counter accounts: first active, non-control account of each type.
Map<String, Id> counter = new Map<String, Id>();
for (GL_Account__c a : [SELECT Id, Account_Type__c FROM GL_Account__c WHERE Company__c = :company.Id AND Is_Active__c = true
        AND Is_Control_Account__c = false AND Manual_Posting_Allowed__c = true AND Account_Type__c IN ('Equity', 'Revenue', 'Expense')
        ORDER BY Account_Code__c]) {
    if (!counter.containsKey(a.Account_Type__c)) {
        counter.put(a.Account_Type__c, a.Id);
    }
}
for (String t : new List<String>{ 'Equity', 'Revenue', 'Expense' }) {
    if (!counter.containsKey(t)) {
        throw new IllegalArgumentException('No active manual-posting ' + t + ' account in ' + COMPANY_NAME + '.');
    }
}

// key, day, description, bank amount (+ deposit / - payment), counter type, post now?
List<List<Object>> plan = new List<List<Object>>{
    new List<Object>{ 'RT-01', 1,  'Capital deposited',              10000, 'Equity',  true },
    new List<Object>{ 'RT-02', 3,  'Customer receipt - Acme',         2500, 'Revenue', true },
    new List<Object>{ 'RT-03', 5,  'Office rent October',            -1200, 'Expense', true },
    new List<Object>{ 'RT-04', 7,  'Supplier payment - Fuel Co',      -800, 'Expense', true },
    new List<Object>{ 'RT-05', 8,  'Office supplies - Paper Ltd',     -800, 'Expense', true },
    new List<Object>{ 'RT-06', 10, 'Electricity',                     -350, 'Expense', true },
    new List<Object>{ 'RT-07', 12, 'Cheque 1001 - cleaning (not yet cleared)', -600, 'Expense', true },
    new List<Object>{ 'RT-08', 13, 'Bank charges October',             -25, 'Expense', false }
};

List<Id> toPost = new List<Id>();
for (List<Object> p : plan) {
    String key = (String) p[0];
    String descr = '[' + key + '] ' + (String) p[2];
    if ([SELECT COUNT() FROM Journal_Entry__c WHERE Company__c = :company.Id AND Description__c = :descr] > 0) {
        continue; // already created by an earlier run
    }
    Decimal amount = Decimal.valueOf(String.valueOf(p[3]));
    Decimal abs = amount.abs();
    Journal_Entry__c je = new Journal_Entry__c(Company__c = company.Id, Accounting_Date__c = Date.newInstance(2026, 10, (Integer) p[1]),
        Accounting_Period__c = periodId, Entry_Type__c = 'Manual', Status__c = 'Draft', Description__c = descr);
    insert je;
    Id other = counter.get((String) p[4]);
    insert new List<Journal_Entry_Line__c>{
        new Journal_Entry_Line__c(Journal_Entry__c = je.Id, Line_Number__c = 1, GL_Account__c = bankGl.Id,
            Debit_Base__c = amount > 0 ? abs : 0, Credit_Base__c = amount > 0 ? 0 : abs, Functional_Currency__c = cur, Explanation__c = (String) p[2]),
        new Journal_Entry_Line__c(Journal_Entry__c = je.Id, Line_Number__c = 2, GL_Account__c = other,
            Debit_Base__c = amount > 0 ? 0 : abs, Credit_Base__c = amount > 0 ? abs : 0, Functional_Currency__c = cur, Explanation__c = (String) p[2])
    };
    if ((Boolean) p[5]) {
        toPost.add(je.Id);
    }
}
// Posting is done one journal per run by post_next_recon_journal.apex (each posting uses many queries).
System.debug('Recon test data ready: ' + toPost.size() + ' new draft journals to post. Now run post_next_recon_journal.apex 7 times.');
