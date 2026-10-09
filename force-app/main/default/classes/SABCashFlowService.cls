/**
 * G21: Cash flow statement, direct method.
 *
 * Cash accounts: the GL accounts behind the company's bank accounts plus accounts with Cash_Flow_Category__c = Cash.
 * For every Posted or Reversed journal dated in the range that moves cash, each non-cash line is classified by its
 * account's Cash_Flow_Category__c (Operating, Investing, Financing; blank = Operating) and contributes the negative of its
 * net (debit - credit). A balanced journal makes the contributions sum exactly to the cash movement, so no apportioning
 * is needed; journals that only move cash between cash accounts net to zero. Opening cash is the cash balance before the
 * range; the statement reconciles when opening + net change equals the cash balance at the end of the range.
 */
public with sharing class SABCashFlowService {
    public class CashFlowException extends Exception {}

    private static final List<String> SECTION_NAMES = new List<String>{'Operating', 'Investing', 'Financing'};

    public class Line {
        @AuraEnabled public String accountCode;
        @AuraEnabled public String accountName;
        @AuraEnabled public Decimal amount = 0;
    }

    public class Section {
        @AuraEnabled public String name;
        @AuraEnabled public List<Line> lines = new List<Line>();
        @AuraEnabled public Decimal total = 0;
    }

    public class CashFlowStatement {
        @AuraEnabled public Date fromDate;
        @AuraEnabled public Date toDate;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public List<Section> sections = new List<Section>();
        @AuraEnabled public Decimal netChange = 0;
        @AuraEnabled public Decimal openingCash = 0;
        @AuraEnabled public Decimal closingCash = 0;
        @AuraEnabled public Decimal ledgerClosingCash = 0;
        @AuraEnabled public Boolean reconciled;
    }

    @AuraEnabled
    public static CashFlowStatement getCashFlow(Id companyId, Date fromDate, Date toDate) {
        SABReportSupport.authorize(companyId);
        if (fromDate == null || toDate == null || toDate < fromDate) {
            throw new CashFlowException('A valid date range is required.');
        }
        Store store = new Store();
        Set<Id> cash = SABReportSupport.cashAccounts(companyId);
        CashFlowStatement s = new CashFlowStatement();
        s.fromDate = fromDate;
        s.toDate = toDate;
        s.currencyCode = store.functionalCurrency(companyId);
        Map<String, Section> sections = new Map<String, Section>();
        for (String name : SECTION_NAMES) {
            Section section = new Section();
            section.name = name;
            sections.put(name, section);
            s.sections.add(section);
        }
        if (!cash.isEmpty()) {
            s.openingCash = store.cashBalance(companyId, cash, fromDate.addDays(-1));
            s.ledgerClosingCash = store.cashBalance(companyId, cash, toDate);
            Map<String, Line> lines = new Map<String, Line>();
            Map<String, String> lineSection = new Map<String, String>();
            Set<Id> journals = store.cashJournals(companyId, cash, fromDate, toDate);
            for (Journal_Entry_Line__c l : store.counterLines(journals, cash)) {
                String category = l.GL_Account__r.Cash_Flow_Category__c;
                String sectionName = SECTION_NAMES.contains(category) ? category : 'Operating';
                String key = sectionName + '|' + l.GL_Account__r.Account_Code__c;
                if (!lines.containsKey(key)) {
                    Line line = new Line();
                    line.accountCode = l.GL_Account__r.Account_Code__c;
                    line.accountName = l.GL_Account__r.Name;
                    lines.put(key, line);
                    lineSection.put(key, sectionName);
                }
                Decimal contribution = nz(l.Credit_Base__c) - nz(l.Debit_Base__c);
                lines.get(key).amount += contribution;
                sections.get(sectionName).total += contribution;
            }
            List<String> keys = new List<String>(lines.keySet());
            keys.sort();
            for (String key : keys) {
                if (lines.get(key).amount != 0) {
                    sections.get(lineSection.get(key)).lines.add(lines.get(key));
                }
            }
        }
        for (Section section : s.sections) {
            s.netChange += section.total;
        }
        s.closingCash = s.openingCash + s.netChange;
        s.reconciled = s.closingCash == s.ledgerClosingCash;
        SABReportSupport.logRun(companyId, 'Cash Flow', new Map<String, Object>{'fromDate' => fromDate, 'toDate' => toDate}, s);
        return s;
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }

    /** Ledger reads after SABReportSupport.authorize (permission and company grant). */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        String functionalCurrency(Id companyId) {
            return [SELECT Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE].Functional_Currency__c;
        }
        Decimal cashBalance(Id companyId, Set<Id> cash, Date asOf) {
            AggregateResult ar = [SELECT SUM(Debit_Base__c) debitTotal, SUM(Credit_Base__c) creditTotal FROM Journal_Entry_Line__c
                WHERE GL_Account__c IN :cash AND Journal_Entry__r.Company__c = :companyId AND Journal_Entry__r.Status__c IN ('Posted', 'Reversed')
                AND Journal_Entry__r.Accounting_Date__c <= :asOf WITH SYSTEM_MODE];
            return nz((Decimal) ar.get('debitTotal')) - nz((Decimal) ar.get('creditTotal'));
        }
        Set<Id> cashJournals(Id companyId, Set<Id> cash, Date fromDate, Date toDate) {
            Set<Id> ids = new Set<Id>();
            for (AggregateResult ar : [SELECT Journal_Entry__c journalId FROM Journal_Entry_Line__c WHERE GL_Account__c IN :cash
                    AND Journal_Entry__r.Company__c = :companyId AND Journal_Entry__r.Status__c IN ('Posted', 'Reversed')
                    AND Journal_Entry__r.Accounting_Date__c >= :fromDate AND Journal_Entry__r.Accounting_Date__c <= :toDate
                    WITH SYSTEM_MODE GROUP BY Journal_Entry__c LIMIT 10000]) {
                ids.add((Id) ar.get('journalId'));
            }
            return ids;
        }
        List<Journal_Entry_Line__c> counterLines(Set<Id> journals, Set<Id> cash) {
            return [SELECT GL_Account__r.Account_Code__c, GL_Account__r.Name, GL_Account__r.Cash_Flow_Category__c, Debit_Base__c, Credit_Base__c
                FROM Journal_Entry_Line__c WHERE Journal_Entry__c IN :journals AND GL_Account__c NOT IN :cash WITH SYSTEM_MODE LIMIT 50000];
        }
    }
}
