@IsTest
private class SABJournalWorkspaceControllerTest {

    @IsTest
    static void workspaceIsCompanyScoped() {
        Accounting_Company__c companyA =
            makeCompany('A1', 'Workspace A');
        Accounting_Company__c companyB =
            makeCompany('B1', 'Workspace B');

        grantCurrentUser(companyA.Id, 'WS-A1');

        Accounting_Period__c periodA =
            makePeriod(companyA.Id, 'A1');
        makePeriod(companyB.Id, 'B1');

        GL_Account__c accountA =
            makeAccount(companyA.Id, '1001');
        makeAccount(companyB.Id, '1001');

        insert new Journal_Entry__c(
            Company__c = companyA.Id,
            Accounting_Period__c = periodA.Id,
            Accounting_Date__c = Date.today(),
            Entry_Type__c = 'Manual',
            Status__c = 'Draft',
            Description__c = 'Draft A',
            Version__c = 1
        );

        Test.startTest();
        SABJournalWorkspaceController.WorkspaceDTO result =
            SABJournalWorkspaceController.getWorkspace(
                companyA.Id
            );
        Test.stopTest();

        System.assertEquals(companyA.Id, result.companyId);
        System.assertEquals('BDT', result.functionalCurrency);
        System.assertEquals(1, result.periods.size());
        System.assertEquals(periodA.Id, result.periods[0].value);
        System.assertEquals(1, result.glAccounts.size());
        System.assertEquals(accountA.Id, result.glAccounts[0].value);
        System.assertEquals(1, result.drafts.size());
    }

    @IsTest
    static void saveAndReloadDraft() {
        Accounting_Company__c company =
            makeCompany('C1', 'Workspace C');
        grantCurrentUser(company.Id, 'WS-C1');

        Accounting_Period__c period =
            makePeriod(company.Id, 'C1');
        GL_Account__c debitAccount =
            makeAccount(company.Id, '6100');
        GL_Account__c creditAccount =
            makeAccount(company.Id, '1100');

        SABJournalWorkspaceController.DraftSaveRequest request =
            new SABJournalWorkspaceController.DraftSaveRequest();

        request.companyId = company.Id;
        request.periodId = period.Id;
        request.accountingDate = Date.today();
        request.description = 'Workspace draft';
        request.lines =
            new List<SABJournalWorkspaceController.DraftLineInput>{
                makeLine(debitAccount.Id, 100, 0, 'Debit'),
                makeLine(creditAccount.Id, 0, 100, 'Credit')
            };

        Test.startTest();
        SABJournalWorkspaceController.JournalDTO saved =
            SABJournalWorkspaceController.saveDraft(request);

        SABJournalWorkspaceController.JournalDTO loaded =
            SABJournalWorkspaceController.getJournal(
                saved.journalId
            );
        Test.stopTest();

        System.assertEquals('Draft', saved.status);
        System.assertEquals('Manual', saved.entryType);
        System.assertEquals(2, saved.lines.size());
        System.assertEquals(100, saved.totalDebit);
        System.assertEquals(100, saved.totalCredit);
        System.assertEquals(saved.journalId, loaded.journalId);

        List<Journal_Entry_Line__c> storedLines = [
            SELECT Functional_Currency__c
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__c = :saved.journalId
        ];

        System.assertEquals(2, storedLines.size());
        System.assertEquals(
            'BDT',
            storedLines[0].Functional_Currency__c
        );
    }

    @IsTest
    static void updatingDraftReplacesLinesAndIncrementsVersion() {
        Accounting_Company__c company =
            makeCompany('D1', 'Workspace D');
        grantCurrentUser(company.Id, 'WS-D1');

        Accounting_Period__c period =
            makePeriod(company.Id, 'D1');
        GL_Account__c accountOne =
            makeAccount(company.Id, '6200');
        GL_Account__c accountTwo =
            makeAccount(company.Id, '1200');

        SABJournalWorkspaceController.DraftSaveRequest request =
            new SABJournalWorkspaceController.DraftSaveRequest();
        request.companyId = company.Id;
        request.periodId = period.Id;
        request.accountingDate = Date.today();
        request.description = 'Original';
        request.lines =
            new List<SABJournalWorkspaceController.DraftLineInput>{
                makeLine(accountOne.Id, 50, 0, 'Debit'),
                makeLine(accountTwo.Id, 0, 50, 'Credit')
            };

        SABJournalWorkspaceController.JournalDTO firstSave =
            SABJournalWorkspaceController.saveDraft(request);

        request.journalId = firstSave.journalId;
        request.description = 'Updated';
        request.lines =
            new List<SABJournalWorkspaceController.DraftLineInput>{
                makeLine(accountOne.Id, 75, 0, 'New debit'),
                makeLine(accountTwo.Id, 0, 75, 'New credit')
            };

        Test.startTest();
        SABJournalWorkspaceController.JournalDTO secondSave =
            SABJournalWorkspaceController.saveDraft(request);
        Test.stopTest();

        Journal_Entry__c stored = [
            SELECT Description__c, Version__c
            FROM Journal_Entry__c
            WHERE Id = :firstSave.journalId
        ];

        System.assertEquals('Updated', stored.Description__c);
        System.assertEquals(2, stored.Version__c);
        System.assertEquals(75, secondSave.totalDebit);
        System.assertEquals(2, secondSave.lines.size());
    }

    @IsTest
    static void otherCompanyPeriodIsRejected() {
        Accounting_Company__c companyA =
            makeCompany('E1', 'Workspace E');
        Accounting_Company__c companyB =
            makeCompany('F1', 'Workspace F');

        grantCurrentUser(companyA.Id, 'WS-E1');

        Accounting_Period__c periodB =
            makePeriod(companyB.Id, 'F1');
        GL_Account__c accountA =
            makeAccount(companyA.Id, '6300');

        SABJournalWorkspaceController.DraftSaveRequest request =
            new SABJournalWorkspaceController.DraftSaveRequest();
        request.companyId = companyA.Id;
        request.periodId = periodB.Id;
        request.accountingDate = Date.today();
        request.description = 'Cross company';
        request.lines =
            new List<SABJournalWorkspaceController.DraftLineInput>{
                makeLine(accountA.Id, 10, 0, 'Debit')
            };

        Boolean thrown = false;

        Test.startTest();
        try {
            SABJournalWorkspaceController.saveDraft(request);
        } catch (AuraHandledException ex) {
            thrown = true;
        }
        Test.stopTest();

        System.assertEquals(true, thrown);
    }

    @IsTest
    static void unauthorizedCompanyWorkspaceIsRejected() {
        Accounting_Company__c company =
            makeCompany('G1', 'Workspace G');

        Boolean thrown = false;

        Test.startTest();
        try {
            SABJournalWorkspaceController.getWorkspace(
                company.Id
            );
        } catch (Exception ex) {
            thrown = true;
        }
        Test.stopTest();

        System.assertEquals(true, thrown);
    }

    private static SABJournalWorkspaceController.DraftLineInput
        makeLine(
            Id accountId,
            Decimal debit,
            Decimal credit,
            String explanation
        ) {
        SABJournalWorkspaceController.DraftLineInput line =
            new SABJournalWorkspaceController.DraftLineInput();
        line.glAccountId = accountId;
        line.debit = debit;
        line.credit = credit;
        line.explanation = explanation;
        return line;
    }

    private static Accounting_Company__c makeCompany(
        String keyValue,
        String displayName
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c = displayName,
                Company_Key__c = keyValue,
                Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT',
                Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active',
                Is_Active__c = true
            );

        insert company;
        return company;
    }

    private static void grantCurrentUser(
        Id companyId,
        String grantKey
    ) {
        insert new Company_User_Access__c(
            Company__c = companyId,
            User__c = UserInfo.getUserId(),
            Effective_From__c = Date.today(),
            Grant_Key__c = grantKey,
            Is_Active__c = true,
            Role__c = 'Finance Manager'
        );
    }

    private static Accounting_Period__c makePeriod(
        Id companyId,
        String suffixValue
    ) {
        Accounting_Period__c period =
            new Accounting_Period__c(
                Name = 'Period ' + suffixValue,
                Company__c = companyId,
                Company_Period_Key__c = 'CP-' + suffixValue,
                Period_Key__c = 'P-' + suffixValue,
                Start_Date__c = Date.today().toStartOfMonth(),
                End_Date__c = Date.today().toStartOfMonth().addMonths(1).addDays(-1),
                Fiscal_Year__c = Date.today().year(),
                Fiscal_Quarter__c = 1,
                Period_Number__c = Date.today().month(),
                Status__c = 'Open'
            );

        insert period;
        return period;
    }

    private static GL_Account__c makeAccount(
        Id companyId,
        String code
    ) {
        GL_Account__c account =
            new GL_Account__c(
                Name = 'Account ' + code,
                Company__c = companyId,
                Company_Account_Key__c =
                    String.valueOf(companyId)
                    + '-'
                    + code,
                Account_Code__c = code,
                Account_Type__c = 'Expense',
                Normal_Balance__c = 'Debit',
                Is_Active__c = true,
                Is_Control_Account__c = false,
                Control_Type__c = 'None',
                Manual_Posting_Allowed__c = true
            );

        insert account;
        return account;
    }
}
