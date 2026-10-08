/**
 * G16: shared builder for module postings. Creates a Draft Subledger journal in the Open period containing the
 * accounting date and posts it through SABPostingService with an Accounting Event that points at the source record
 * (the rule SABPostingService enforces for Subledger journals). Functional currency only.
 *
 * Callers run their own permission, company and lifecycle checks first; SABPostingService then applies the ledger
 * checks (balance, period, journal access, event idempotency).
 */
public with sharing class SABSubledgerPostingHelper {
    public class SubledgerPostingException extends Exception {}

    public class LineSpec {
        public Id accountId;
        public Decimal debit = 0;
        public Decimal credit = 0;
        public String explanation;
        public LineSpec(Id accountId, Decimal signedAmount, String explanation) {
            this.accountId = accountId;
            this.debit = signedAmount > 0 ? signedAmount : 0;
            this.credit = signedAmount < 0 ? -signedAmount : 0;
            this.explanation = explanation;
        }
    }

    public class PostingSpec {
        public Id companyId;
        public Date accountingDate;
        public String description;
        public String adapterKey;
        public String eventKey;
        public String eventType;
        public String sourceType;
        public Id sourceRecordId;
        public String sourceBusinessKey;
        public Integer sourceVersion = 1;
        public String requestKey;
        public List<LineSpec> lines = new List<LineSpec>();
    }

    public static SABPostingService.PostingResult post(PostingSpec spec) {
        Store store = new Store();
        Accounting_Period__c period = store.openPeriod(spec.companyId, spec.accountingDate);
        String currencyCode = store.functionalCurrency(spec.companyId);
        Decimal debits = 0;
        Decimal credits = 0;
        List<Journal_Entry_Line__c> lines = new List<Journal_Entry_Line__c>();
        Integer n = 1;
        for (LineSpec l : spec.lines) {
            if (l.debit == 0 && l.credit == 0) {
                continue;
            }
            debits += l.debit;
            credits += l.credit;
            lines.add(new Journal_Entry_Line__c(Line_Number__c = n, GL_Account__c = l.accountId, Debit_Base__c = l.debit, Credit_Base__c = l.credit,
                Transaction_Amount__c = l.debit > 0 ? l.debit : l.credit, Transaction_Currency__c = currencyCode,
                Functional_Currency__c = currencyCode, Applied_Exchange_Rate__c = 1, Rate_Date__c = spec.accountingDate,
                Rate_Source__c = 'Functional Currency', Source_Line_Key__c = (spec.eventKey + '|' + n).left(255),
                Explanation__c = String.isBlank(l.explanation) ? null : l.explanation.left(255)));
            n++;
        }
        if (lines.size() < 2 || debits != credits) {
            throw new SubledgerPostingException('The journal must have at least two lines and balance; debits ' + debits + ', credits ' + credits + '.');
        }
        Journal_Entry__c journal = new Journal_Entry__c(Company__c = spec.companyId, Accounting_Period__c = period.Id,
            Accounting_Date__c = spec.accountingDate, Entry_Type__c = 'Subledger', Status__c = 'Draft', Version__c = 1,
            Description__c = spec.description == null ? null : spec.description.left(255));
        new Writer().journal(journal, lines);

        SABAccountingEventService.ReservationRequest eventRequest = new SABAccountingEventService.ReservationRequest();
        eventRequest.companyId = spec.companyId;
        eventRequest.adapterKey = spec.adapterKey;
        eventRequest.requestKey = spec.requestKey.left(120);
        eventRequest.eventKey = spec.eventKey;
        eventRequest.eventType = activeEventType(spec.eventType);
        eventRequest.sourceBusinessKey = spec.sourceBusinessKey == null ? null : spec.sourceBusinessKey.left(180);
        eventRequest.sourceRecordId = String.valueOf(spec.sourceRecordId);
        eventRequest.sourceType = spec.sourceType;
        eventRequest.sourceVersion = spec.sourceVersion;
        SABPostingService.PostingRequest posting = new SABPostingService.PostingRequest();
        posting.journalEntryId = journal.Id;
        posting.postingKey = spec.eventKey;
        posting.eventRequest = eventRequest;
        return SABPostingService.postDraftJournal(posting);
    }

    /** The requested event type when it is active in this org; otherwise 'Manual Journal'. */
    @TestVisible
    private static String activeEventType(String requested) {
        for (Schema.PicklistEntry entry : Accounting_Event__c.Event_Type__c.getDescribe().getPicklistValues()) {
            if (entry.isActive() && entry.getValue() == requested) {
                return requested;
            }
        }
        return 'Manual Journal';
    }

    /** Narrow system reads: the posting period and functional currency, after the caller's company check. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Accounting_Period__c openPeriod(Id companyId, Date onDate) {
            List<Accounting_Period__c> rows = [SELECT Id, Status__c FROM Accounting_Period__c WHERE Company__c = :companyId
                AND Start_Date__c <= :onDate AND End_Date__c >= :onDate WITH SYSTEM_MODE LIMIT 2];
            if (rows.size() != 1 || rows[0].Status__c != 'Open') {
                throw new SubledgerPostingException('No single Open accounting period contains ' + String.valueOf(onDate) + '.');
            }
            return rows[0];
        }
        String functionalCurrency(Id companyId) {
            return [SELECT Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE].Functional_Currency__c;
        }
    }

    /** Draft journal and lines, written in explicit system mode after the caller's checks. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void journal(Journal_Entry__c journal, List<Journal_Entry_Line__c> lines) {
            insert as system journal;
            for (Journal_Entry_Line__c line : lines) {
                line.Journal_Entry__c = journal.Id;
            }
            insert as system lines;
        }
    }
}
