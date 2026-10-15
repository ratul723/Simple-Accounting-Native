// Posts the next Draft test journal RT-01..RT-07 (RT-08 stays Draft for the test). One journal per run,
// because a single posting already uses many SOQL queries. Run it until it reports nothing left (7 times).
String COMPANY_NAME = 'Ratuls Company Ltd';
List<Journal_Entry__c> next = [SELECT Id, Description__c FROM Journal_Entry__c
    WHERE Company__r.Name__c = :COMPANY_NAME AND Status__c = 'Draft' AND Description__c LIKE '[RT-0%'
    AND (NOT Description__c LIKE '[RT-08]%') ORDER BY Accounting_Date__c, Description__c LIMIT 1];
if (next.isEmpty()) {
    System.debug('Nothing left to post. RT-01..RT-07 are posted; book balance of GL 1060 should be 8,750.00.');
} else {
    SABJournalWorkspaceController.postJournal(next[0].Id);
    System.debug('Posted ' + next[0].Description__c);
}
