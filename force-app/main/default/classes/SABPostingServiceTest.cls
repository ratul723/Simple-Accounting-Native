@IsTest
private class SABPostingServiceTest {

    @TestSetup
    static void setupPostingUser() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String uniqueValue =
            'sabposting.'
            + String.valueOf(DateTime.now().getTime());

        User postingUser = new User(
            Alias = 'sabpost',
            Email = uniqueValue + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Posting User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = uniqueValue + '@example.test'
        );

        insert postingUser;

        Map<String, Id> permissionSetIds =
            new Map<String, Id>();

        for (PermissionSet ps : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN (
                'SAB_Remaining_Fields_Admin',
                'SAB_Post_Journal_Action'
            )
        ]) {
            permissionSetIds.put(ps.Name, ps.Id);
        }

        System.assert(
            permissionSetIds.containsKey(
                'SAB_Remaining_Fields_Admin'
            ),
            'SAB_Remaining_Fields_Admin must be deployed.'
        );

        System.assert(
            permissionSetIds.containsKey(
                'SAB_Post_Journal_Action'
            ),
            'SAB_Post_Journal_Action must be deployed.'
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = postingUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        'SAB_Remaining_Fields_Admin'
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = postingUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        'SAB_Post_Journal_Action'
                    )
            )
        };
    }

    private static User postingUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB Posting User'
            LIMIT 1
        ];
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

    private static Accounting_Period__c makePeriod(
        Id companyId,
        String suffixValue,
        String statusValue
    ) {
        Accounting_Period__c period =
            new Accounting_Period__c(
                Name = 'Period ' + suffixValue,
                Company__c = companyId,
                Company_Period_Key__c =
                    'CP-' + suffixValue,
                Period_Key__c =
                    'P-' + suffixValue,
                Start_Date__c =
                    Date.newInstance(2026, 9, 1),
                End_Date__c =
                    Date.newInstance(2026, 9, 30),
                Fiscal_Year__c = 2026,
                Fiscal_Quarter__c = 3,
                Period_Number__c = 9,
                Status__c = statusValue
            );

        if (statusValue == 'Closed') {
            period.Closed_At__c = System.now();
            period.Closed_By__c = UserInfo.getUserId();
        }

        insert period;
        return period;
    }

    private static GL_Account__c makeGLAccount(
        Id companyId,
        String accountCode
    ) {
        GL_Account__c account =
            new GL_Account__c(
                Name = 'Account ' + accountCode,
                Company__c = companyId,
                Company_Account_Key__c =
                    String.valueOf(companyId)
                    + '-'
                    + accountCode,
                Account_Code__c = accountCode,
                Account_Type__c = 'Asset',
                Normal_Balance__c = 'Debit',
                Is_Active__c = true,
                Is_Control_Account__c = false,
                Control_Type__c = 'None',
                Manual_Posting_Allowed__c = true
            );

        insert account;
        return account;
    }

    private static Journal_Entry__c makeJournal(
        Id companyId,
        Id periodId,
        String description
    ) {
        Journal_Entry__c journal =
            new Journal_Entry__c(
                Company__c = companyId,
                Accounting_Period__c = periodId,
                Accounting_Date__c =
                    Date.newInstance(2026, 9, 15),
                Entry_Type__c = 'Manual',
                Status__c = 'Draft',
                Description__c = description,
                Version__c = 1
            );

        insert journal;
        return journal;
    }

    private static Journal_Entry_Line__c makeLine(
        Id journalId,
        Id glAccountId,
        Integer lineNumber,
        Decimal debit,
        Decimal credit
    ) {
        return new Journal_Entry_Line__c(
            Journal_Entry__c = journalId,
            GL_Account__c = glAccountId,
            Line_Number__c = lineNumber,
            Debit_Base__c = debit,
            Credit_Base__c = credit,
            Functional_Currency__c = 'BDT'
        );
    }

    private static void addBalancedLines(
        Id journalId,
        Id debitAccountId,
        Id creditAccountId,
        Decimal amount
    ) {
        insert new List<Journal_Entry_Line__c>{
            makeLine(
                journalId,
                debitAccountId,
                1,
                amount,
                0
            ),
            makeLine(
                journalId,
                creditAccountId,
                2,
                0,
                amount
            )
        };
    }

    private static void grantCompanyAccess(
        Id companyId,
        Id userId,
        String grantKey
    ) {
        insert new Company_User_Access__c(
            Company__c = companyId,
            User__c = userId,
            Effective_From__c = Date.today(),
            Effective_To__c = null,
            Grant_Key__c = grantKey,
            Is_Active__c = true,
            Role__c = 'Bookkeeper'
        );
    }

    private static SABPostingService.PostingRequest buildRequest(
        Journal_Entry__c journal,
        String postingKey,
        String eventKey
    ) {
        SABAccountingEventService.ReservationRequest eventRequest =
            new SABAccountingEventService.ReservationRequest();

        eventRequest.companyId =
            journal.Company__c;
        eventRequest.adapterKey =
            'MANUAL_JOURNAL';
        eventRequest.requestKey =
            'REQ-' + eventKey;
        eventRequest.eventKey =
            eventKey;
        eventRequest.eventType =
            'Manual Journal';
        eventRequest.sourceBusinessKey =
            postingKey;
        eventRequest.sourceRecordId =
            String.valueOf(journal.Id);
        eventRequest.sourceType =
            'Journal_Entry__c';
        eventRequest.sourceVersion = 1;

        SABPostingService.PostingRequest request =
            new SABPostingService.PostingRequest();

        request.journalEntryId = journal.Id;
        request.postingKey = postingKey;
        request.eventRequest = eventRequest;

        return request;
    }

    @IsTest
    static void balancedDraftPostsAtomically() {
        User u = postingUser();

        Accounting_Company__c company =
            makeCompany('PS1', 'Posting Company One');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'PS1',
                'Open'
            );

        GL_Account__c debitAccount =
            makeGLAccount(company.Id, '6100');

        GL_Account__c creditAccount =
            makeGLAccount(company.Id, '1100');

        Journal_Entry__c journal =
            makeJournal(
                company.Id,
                period.Id,
                'Balanced posting test'
            );

        addBalancedLines(
            journal.Id,
            debitAccount.Id,
            creditAccount.Id,
            125
        );

        grantCompanyAccess(
            company.Id,
            u.Id,
            'POST-GRANT-1'
        );

        SABPostingService.PostingResult result;

        System.runAs(u) {
            Test.startTest();

            result =
                SABPostingService.postDraftJournal(
                    buildRequest(
                        journal,
                        'POST-PS1-001',
                        'EVENT-PS1-001'
                    )
                );

            Test.stopTest();
        }

        System.assertEquals(false, result.replay);
        System.assertEquals(journal.Id, result.journalEntryId);
        System.assertNotEquals(null, result.accountingEventId);
        System.assertNotEquals(null, result.postedAt);

        Journal_Entry__c storedJournal = [
            SELECT Status__c,
                   Posting_Key__c,
                   Accounting_Event__c,
                   Posted_By__c,
                   Posted_At__c
            FROM Journal_Entry__c
            WHERE Id = :journal.Id
        ];

        System.assertEquals(
            'Posted',
            storedJournal.Status__c
        );
        System.assertEquals(
            'POST-PS1-001',
            storedJournal.Posting_Key__c
        );
        System.assertEquals(
            u.Id,
            storedJournal.Posted_By__c
        );
        System.assertNotEquals(
            null,
            storedJournal.Posted_At__c
        );
        System.assertEquals(
            result.accountingEventId,
            storedJournal.Accounting_Event__c
        );

        Accounting_Event__c storedEvent = [
            SELECT State__c,
                   Journal_Entry__c,
                   Event_Key__c
            FROM Accounting_Event__c
            WHERE Id = :result.accountingEventId
        ];

        System.assertEquals(
            'Posted',
            storedEvent.State__c
        );
        System.assertEquals(
            journal.Id,
            storedEvent.Journal_Entry__c
        );
        System.assertEquals(
            'EVENT-PS1-001',
            storedEvent.Event_Key__c
        );
    }

    @IsTest
    static void retryReturnsExistingPostedResult() {
        User u = postingUser();

        Accounting_Company__c company =
            makeCompany('PS2', 'Posting Company Two');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'PS2',
                'Open'
            );

        GL_Account__c debitAccount =
            makeGLAccount(company.Id, '6200');

        GL_Account__c creditAccount =
            makeGLAccount(company.Id, '1200');

        Journal_Entry__c journal =
            makeJournal(
                company.Id,
                period.Id,
                'Idempotent posting test'
            );

        addBalancedLines(
            journal.Id,
            debitAccount.Id,
            creditAccount.Id,
            75
        );

        grantCompanyAccess(
            company.Id,
            u.Id,
            'POST-GRANT-2'
        );

        SABPostingService.PostingRequest request =
            buildRequest(
                journal,
                'POST-PS2-001',
                'EVENT-PS2-001'
            );

        Id firstEventId;

        System.runAs(u) {
            SABPostingService.PostingResult firstResult =
                SABPostingService.postDraftJournal(
                    request
                );

            firstEventId = firstResult.accountingEventId;

            SABPostingService.PostingResult secondResult =
                SABPostingService.postDraftJournal(
                    request
                );

            System.assertEquals(true, secondResult.replay);
            System.assertEquals(
                firstEventId,
                secondResult.accountingEventId
            );
            System.assertEquals(
                journal.Id,
                secondResult.journalEntryId
            );
        }

        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM Accounting_Event__c
                WHERE Event_Key__c = 'EVENT-PS2-001'
            ]
        );
    }

    @IsTest
    static void unbalancedJournalRollsBackEventReservation() {
        User u = postingUser();

        Accounting_Company__c company =
            makeCompany('PS3', 'Posting Company Three');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'PS3',
                'Open'
            );

        GL_Account__c debitAccount =
            makeGLAccount(company.Id, '6300');

        GL_Account__c creditAccount =
            makeGLAccount(company.Id, '1300');

        Journal_Entry__c journal =
            makeJournal(
                company.Id,
                period.Id,
                'Rollback posting test'
            );

        insert new List<Journal_Entry_Line__c>{
            makeLine(
                journal.Id,
                debitAccount.Id,
                1,
                100,
                0
            ),
            makeLine(
                journal.Id,
                creditAccount.Id,
                2,
                0,
                90
            )
        };

        grantCompanyAccess(
            company.Id,
            u.Id,
            'POST-GRANT-3'
        );

        System.runAs(u) {
            Boolean thrown = false;

            try {
                SABPostingService.postDraftJournal(
                    buildRequest(
                        journal,
                        'POST-PS3-001',
                        'EVENT-PS3-001'
                    )
                );
            } catch (Exception ex) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }

        Journal_Entry__c storedJournal = [
            SELECT Status__c,
                   Posting_Key__c,
                   Accounting_Event__c,
                   Posted_At__c
            FROM Journal_Entry__c
            WHERE Id = :journal.Id
        ];

        System.assertEquals(
            'Draft',
            storedJournal.Status__c
        );
        System.assertEquals(
            null,
            storedJournal.Posting_Key__c
        );
        System.assertEquals(
            null,
            storedJournal.Accounting_Event__c
        );
        System.assertEquals(
            null,
            storedJournal.Posted_At__c
        );

        System.assertEquals(
            0,
            [
                SELECT COUNT()
                FROM Accounting_Event__c
                WHERE Event_Key__c = 'EVENT-PS3-001'
            ]
        );
    }

    @IsTest
    static void closedPeriodDoesNotPost() {
        User u = postingUser();

        Accounting_Company__c company =
            makeCompany('PS4', 'Posting Company Four');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'PS4',
                'Closed'
            );

        GL_Account__c debitAccount =
            makeGLAccount(company.Id, '6400');

        GL_Account__c creditAccount =
            makeGLAccount(company.Id, '1400');

        Journal_Entry__c journal =
            makeJournal(
                company.Id,
                period.Id,
                'Closed period test'
            );

        addBalancedLines(
            journal.Id,
            debitAccount.Id,
            creditAccount.Id,
            40
        );

        grantCompanyAccess(
            company.Id,
            u.Id,
            'POST-GRANT-4'
        );

        System.runAs(u) {
            Boolean thrown = false;

            try {
                SABPostingService.postDraftJournal(
                    buildRequest(
                        journal,
                        'POST-PS4-001',
                        'EVENT-PS4-001'
                    )
                );
            } catch (Exception ex) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }

        Journal_Entry__c storedJournal = [
            SELECT Status__c,
                   Accounting_Event__c
            FROM Journal_Entry__c
            WHERE Id = :journal.Id
        ];

        System.assertEquals(
            'Draft',
            storedJournal.Status__c
        );
        System.assertEquals(
            null,
            storedJournal.Accounting_Event__c
        );

        System.assertEquals(
            0,
            [
                SELECT COUNT()
                FROM Accounting_Event__c
                WHERE Event_Key__c = 'EVENT-PS4-001'
            ]
        );
    }

    @IsTest
    static void userWithoutCompanyAccessCannotPost() {
        User u = postingUser();

        Accounting_Company__c company =
            makeCompany('PS5', 'Unauthorized Posting Company');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'PS5',
                'Open'
            );

        GL_Account__c debitAccount =
            makeGLAccount(company.Id, '6500');

        GL_Account__c creditAccount =
            makeGLAccount(company.Id, '1500');

        Journal_Entry__c journal =
            makeJournal(
                company.Id,
                period.Id,
                'Unauthorized posting test'
            );

        addBalancedLines(
            journal.Id,
            debitAccount.Id,
            creditAccount.Id,
            20
        );

        System.runAs(u) {
            Boolean thrown = false;

            try {
                SABPostingService.postDraftJournal(
                    buildRequest(
                        journal,
                        'POST-PS5-001',
                        'EVENT-PS5-001'
                    )
                );
            } catch (Exception ex) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }

        Journal_Entry__c storedJournal = [
            SELECT Status__c
            FROM Journal_Entry__c
            WHERE Id = :journal.Id
        ];

        System.assertEquals(
            'Draft',
            storedJournal.Status__c
        );
    }
}
