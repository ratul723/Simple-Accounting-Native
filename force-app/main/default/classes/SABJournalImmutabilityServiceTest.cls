@IsTest
private class SABJournalImmutabilityServiceTest {

    @TestSetup
    static void setupUser() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String uniqueValue =
            'sabimmutable.'
            + String.valueOf(DateTime.now().getTime());

        User u = new User(
            Alias = 'sabimm',
            Email = uniqueValue + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Immutability User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = uniqueValue + '@example.test'
        );

        insert u;

        Map<String, Id> ids = new Map<String, Id>();

        for (PermissionSet ps : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN (
                'SAB_Remaining_Fields_Admin',
                'SAB_Post_Journal_Action',
                'SAB_Reverse_Journal_Action'
            )
        ]) {
            ids.put(ps.Name, ps.Id);
        }

        System.assertEquals(
            3,
            ids.size(),
            'Required SAB permission sets must be deployed.'
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = u.Id,
                PermissionSetId =
                    ids.get('SAB_Remaining_Fields_Admin')
            ),
            new PermissionSetAssignment(
                AssigneeId = u.Id,
                PermissionSetId =
                    ids.get('SAB_Post_Journal_Action')
            ),
            new PermissionSetAssignment(
                AssigneeId = u.Id,
                PermissionSetId =
                    ids.get('SAB_Reverse_Journal_Action')
            )
        };
    }

    private static User testUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB Immutability User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c makeCompany() {
        Accounting_Company__c c =
            new Accounting_Company__c(
                Name__c = 'Immutable Ledger Company',
                Company_Key__c = 'IL',
                Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT',
                Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active',
                Is_Active__c = true
            );
        insert c;
        return c;
    }

    private static Accounting_Period__c makePeriod(Id companyId) {
        Accounting_Period__c p =
            new Accounting_Period__c(
                Name = 'September 2026',
                Company__c = companyId,
                Company_Period_Key__c = 'CP-IL-2026-09',
                Period_Key__c = 'P-IL-2026-09',
                Start_Date__c = Date.newInstance(2026, 9, 1),
                End_Date__c = Date.newInstance(2026, 9, 30),
                Fiscal_Year__c = 2026,
                Fiscal_Quarter__c = 3,
                Period_Number__c = 9,
                Status__c = 'Open'
            );
        insert p;
        return p;
    }

    private static GL_Account__c makeAccount(
        Id companyId,
        String code
    ) {
        GL_Account__c a =
            new GL_Account__c(
                Name = 'Account ' + code,
                Company__c = companyId,
                Company_Account_Key__c =
                    String.valueOf(companyId) + '-' + code,
                Account_Code__c = code,
                Account_Type__c = 'Asset',
                Normal_Balance__c = 'Debit',
                Is_Active__c = true,
                Is_Control_Account__c = false,
                Control_Type__c = 'None',
                Manual_Posting_Allowed__c = true
            );
        insert a;
        return a;
    }

    private static Journal_Entry__c makeDraft(
        Id companyId,
        Id periodId
    ) {
        Journal_Entry__c j =
            new Journal_Entry__c(
                Company__c = companyId,
                Accounting_Period__c = periodId,
                Accounting_Date__c =
                    Date.newInstance(2026, 9, 15),
                Entry_Type__c = 'Manual',
                Status__c = 'Draft',
                Description__c = 'Immutability test',
                Version__c = 1
            );
        insert j;
        return j;
    }

    private static void addLines(
        Id journalId,
        Id debitAccountId,
        Id creditAccountId
    ) {
        insert new List<Journal_Entry_Line__c>{
            new Journal_Entry_Line__c(
                Journal_Entry__c = journalId,
                GL_Account__c = debitAccountId,
                Line_Number__c = 1,
                Debit_Base__c = 100,
                Credit_Base__c = 0,
                Functional_Currency__c = 'BDT'
            ),
            new Journal_Entry_Line__c(
                Journal_Entry__c = journalId,
                GL_Account__c = creditAccountId,
                Line_Number__c = 2,
                Debit_Base__c = 0,
                Credit_Base__c = 100,
                Functional_Currency__c = 'BDT'
            )
        };
    }

    private static void grantAccess(
        Id companyId,
        Id userId
    ) {
        insert new Company_User_Access__c(
            Company__c = companyId,
            User__c = userId,
            Effective_From__c = Date.today(),
            Grant_Key__c = 'IMM-GRANT',
            Is_Active__c = true,
            Role__c = 'Finance Manager'
        );
    }

    private static SABPostingService.PostingRequest postingRequest(
        Journal_Entry__c journal
    ) {
        SABAccountingEventService.ReservationRequest e =
            new SABAccountingEventService.ReservationRequest();

        e.companyId = journal.Company__c;
        e.adapterKey = 'MANUAL_JOURNAL';
        e.requestKey = 'REQ-IMM-POST';
        e.eventKey = 'EVENT-IMM-POST';
        e.eventType = 'Manual Journal';
        e.sourceBusinessKey = 'POST-IMM-001';
        e.sourceRecordId = String.valueOf(journal.Id);
        e.sourceType = 'Journal_Entry__c';
        e.sourceVersion = 1;

        SABPostingService.PostingRequest r =
            new SABPostingService.PostingRequest();

        r.journalEntryId = journal.Id;
        r.postingKey = 'POST-IMM-001';
        r.eventRequest = e;

        return r;
    }

    @IsTest
    static void postedHeaderAndLinesCannotBeEditedOrDeleted() {
        User u = testUser();
        Accounting_Company__c c = makeCompany();
        Accounting_Period__c p = makePeriod(c.Id);
        GL_Account__c a1 = makeAccount(c.Id, '8100');
        GL_Account__c a2 = makeAccount(c.Id, '3100');
        Journal_Entry__c j = makeDraft(c.Id, p.Id);
        addLines(j.Id, a1.Id, a2.Id);
        grantAccess(c.Id, u.Id);

        System.runAs(u) {
            SABPostingService.postDraftJournal(
                postingRequest(j)
            );

            Journal_Entry__c posted = [
                SELECT Id, Description__c
                FROM Journal_Entry__c
                WHERE Id = :j.Id
            ];
            posted.Description__c = 'Changed illegally';

            System.assertEquals(
                false,
                Database.update(posted, false).isSuccess()
            );

            System.assertEquals(
                false,
                Database.delete(posted, false).isSuccess()
            );

            Journal_Entry_Line__c line = [
                SELECT Id, Explanation__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c = :j.Id
                LIMIT 1
            ];

            line.Explanation__c = 'Changed illegally';

            System.assertEquals(
                false,
                Database.update(line, false).isSuccess()
            );

            System.assertEquals(
                false,
                Database.delete(line, false).isSuccess()
            );

            Journal_Entry_Line__c extraLine =
                new Journal_Entry_Line__c(
                    Journal_Entry__c = j.Id,
                    GL_Account__c = a1.Id,
                    Line_Number__c = 3,
                    Debit_Base__c = 1,
                    Credit_Base__c = 0,
                    Functional_Currency__c = 'BDT'
                );

            System.assertEquals(
                false,
                Database.insert(extraLine, false).isSuccess()
            );
        }
    }

    @IsTest
    static void draftHeaderAndLinesRemainEditable() {
        Accounting_Company__c c = makeCompany();
        Accounting_Period__c p = makePeriod(c.Id);
        GL_Account__c a1 = makeAccount(c.Id, '8200');
        GL_Account__c a2 = makeAccount(c.Id, '3200');
        Journal_Entry__c j = makeDraft(c.Id, p.Id);
        addLines(j.Id, a1.Id, a2.Id);

        j.Description__c = 'Valid draft edit';
        update j;

        Journal_Entry_Line__c line = [
            SELECT Id, Explanation__c
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__c = :j.Id
            LIMIT 1
        ];

        line.Explanation__c = 'Valid draft line edit';
        update line;

        System.assertEquals(
            'Valid draft edit',
            [
                SELECT Description__c
                FROM Journal_Entry__c
                WHERE Id = :j.Id
            ].Description__c
        );
    }

    @IsTest
    static void reversalServiceCanPerformControlledTransition() {
        User u = testUser();
        Accounting_Company__c c = makeCompany();
        Accounting_Period__c p = makePeriod(c.Id);
        GL_Account__c a1 = makeAccount(c.Id, '8300');
        GL_Account__c a2 = makeAccount(c.Id, '3300');
        Journal_Entry__c j = makeDraft(c.Id, p.Id);
        addLines(j.Id, a1.Id, a2.Id);
        grantAccess(c.Id, u.Id);

        System.runAs(u) {
            SABPostingService.postDraftJournal(
                postingRequest(j)
            );

            SABReversalService.ReversalRequest r =
                new SABReversalService.ReversalRequest();

            r.originalJournalEntryId = j.Id;
            r.reversalAccountingPeriodId = p.Id;
            r.reversalAccountingDate =
                Date.newInstance(2026, 9, 20);
            r.postingKey = 'POST-IMM-REV';
            r.eventKey = 'EVENT-IMM-REV';
            r.requestKey = 'REQ-IMM-REV';
            r.reason = 'Controlled correction';

            SABReversalService.ReversalResult result =
                SABReversalService.reversePostedJournal(r);

            System.assertNotEquals(
                null,
                result.reversalJournalEntryId
            );

            System.assertEquals(
                'Reversed',
                [
                    SELECT Status__c
                    FROM Journal_Entry__c
                    WHERE Id = :j.Id
                ].Status__c
            );
        }
    }
}
