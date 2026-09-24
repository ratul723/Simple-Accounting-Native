trigger SABJournalCompanyGuardTrigger
on Journal_Entry__c (before insert, before update) {
    SABCrossCompanyGuardService.validateJournals(
        Trigger.new
    );
}
