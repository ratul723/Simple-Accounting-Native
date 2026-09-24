trigger SABJournalLineCompanyGuardTrigger
on Journal_Entry_Line__c (before insert, before update) {
    SABCrossCompanyGuardService.validateJournalLines(
        Trigger.new
    );
}
