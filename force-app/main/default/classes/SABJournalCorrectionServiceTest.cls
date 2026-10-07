@IsTest
private class SABJournalCorrectionServiceTest {
    @IsTest
    static void createsEditableCorrectionFromReversedManualJournal() {
        assignActionPermission('SAB_Post_Journal_Action');
        assignActionPermission('SAB_Reverse_Journal_Action');

        Accounting_Company__c company = new Accounting_Company__c(
            Name__c='Correction Co', Company_Key__c='CR1', Country_Code__c='BD', Functional_Currency__c='BDT',
            Fiscal_Calendar_Type__c='Calendar', Fiscal_Year_Start_Month__c=1, Setup_Status__c='Active', Is_Active__c=true);
        insert company;
        insert new Company_User_Access__c(Company__c=company.Id, User__c=UserInfo.getUserId(), Role__c='Finance Manager',
            Is_Active__c=true, Effective_From__c=Date.today().addDays(-1), Grant_Key__c='CORRECTION-GRANT');

        Date monthStart=Date.today().toStartOfMonth();
        Accounting_Period__c period = new Accounting_Period__c(Name='Correction Period', Company__c=company.Id,
            Company_Period_Key__c='CR1-P1', Period_Key__c='CR1-'+String.valueOf(Date.today().year())+'-'+String.valueOf(Date.today().month()),
            Start_Date__c=monthStart, End_Date__c=monthStart.addMonths(1).addDays(-1), Fiscal_Year__c=Date.today().year(),
            Fiscal_Quarter__c=1, Period_Number__c=Date.today().month(), Status__c='Open');
        insert period;

        GL_Account__c debit = account(company.Id,'6100','Correction Expense','Expense','Debit');
        GL_Account__c credit = account(company.Id,'1100','Correction Cash','Asset','Debit');
        insert new List<GL_Account__c>{debit,credit};

        SABJournalWorkspaceController.DraftSaveRequest request = new SABJournalWorkspaceController.DraftSaveRequest();
        request.companyId=company.Id;
        request.periodId=period.Id;
        request.accountingDate=Date.today();
        request.description='Original manual entry';
        request.lines=new List<SABJournalWorkspaceController.DraftLineInput>{
            line(debit.Id,125,0,'Original debit'), line(credit.Id,0,125,'Original credit')};

        SABJournalWorkspaceController.JournalDTO draft=SABJournalWorkspaceController.saveDraft(request);
        SABJournalWorkspaceController.PostingDTO posted=SABJournalWorkspaceController.postJournal(draft.journalId);
        System.assertEquals('Posted',posted.status);
        SABJournalWorkspaceController.ReversalDTO reversed=SABJournalWorkspaceController.reverseJournal(
            draft.journalId,period.Id,Date.today(),'Correct the amount');
        System.assertEquals('Reversed',reversed.originalStatus);

        Test.startTest();
        List<SABJournalCorrectionService.ReversedJournalDTO> reversedList=
            SABJournalCorrectionService.getReversedJournals(company.Id);
        SABJournalWorkspaceController.JournalDTO corrected=
            SABJournalCorrectionService.createCorrectedDraft(draft.journalId);
        Test.stopTest();
        System.assertEquals(1,reversedList.size(),'The reversed original is available after refresh.');
        System.assertEquals(draft.journalId,reversedList[0].journalId);

        System.assertEquals('Draft',corrected.status);
        System.assertEquals('Manual',corrected.entryType);
        System.assertEquals(company.Id,corrected.companyId);
        System.assertEquals(period.Id,corrected.periodId);
        System.assertEquals(2,corrected.lines.size());
        System.assertEquals(125,corrected.totalDebit);
        System.assertEquals(125,corrected.totalCredit);
        System.assert(corrected.description.startsWith('Correction of '));

        Journal_Entry__c stored=[SELECT Status__c,Entry_Type__c,Posting_Key__c,Accounting_Event__c,
            Reversal_Journal__c,Reversal_Of__c FROM Journal_Entry__c WHERE Id=:corrected.journalId];
        System.assertEquals('Draft',stored.Status__c);
        System.assertEquals('Manual',stored.Entry_Type__c);
        System.assertEquals(null,stored.Posting_Key__c);
        System.assertEquals(null,stored.Accounting_Event__c);
        System.assertEquals(null,stored.Reversal_Journal__c);
        System.assertEquals(null,stored.Reversal_Of__c);
    }

    @IsTest
    static void rejectsMissingSource() {
        assignActionPermission('SAB_Reverse_Journal_Action');
        Boolean rejected=false;
        Test.startTest();
        try { SABJournalCorrectionService.createCorrectedDraft(null); }
        catch (AuraHandledException ex) { rejected=true; }
        Test.stopTest();
        System.assert(rejected,'A source Journal is required.');
    }

    private static void assignActionPermission(String permissionSetName) {
        System.runAs(new User(Id=UserInfo.getUserId())) {
            PermissionSet ps=[SELECT Id FROM PermissionSet WHERE Name=:permissionSetName LIMIT 1];
            Id uid=UserInfo.getUserId();
            if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId=:uid AND PermissionSetId=:ps.Id] == 0) {
                insert new PermissionSetAssignment(AssigneeId=uid,PermissionSetId=ps.Id);
            }
        }
    }

    private static SABJournalWorkspaceController.DraftLineInput line(Id accountId,Decimal debit,Decimal credit,String explanation) {
        SABJournalWorkspaceController.DraftLineInput result=new SABJournalWorkspaceController.DraftLineInput();
        result.glAccountId=accountId;result.debit=debit;result.credit=credit;result.explanation=explanation;return result;
    }

    private static GL_Account__c account(Id companyId,String code,String nameValue,String accountType,String normalBalance) {
        return new GL_Account__c(Name=nameValue,Company__c=companyId,
            Company_Account_Key__c=String.valueOf(companyId)+'-'+code,Account_Code__c=code,Account_Type__c=accountType,
            Normal_Balance__c=normalBalance,Is_Active__c=true,Is_Control_Account__c=false,Control_Type__c='None',
            Manual_Posting_Allowed__c=true);
    }
}
