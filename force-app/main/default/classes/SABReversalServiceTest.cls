@IsTest
private class SABReversalServiceTest {

    @TestSetup
    static void setupReversalUser() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String uniqueValue =
            'sabreversal.'
            + String.valueOf(DateTime.now().getTime());

        User reversalUser = new User(
            Alias = 'sabrev',
            Email = uniqueValue + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Reversal User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = uniqueValue + '@example.test'
        );

        insert reversalUser;

        Map<String, Id> permissionSetIds =
            new Map<String, Id>();

        for (PermissionSet ps : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN (
                'SAB_Remaining_Fields_Admin',
                'SAB_Post_Journal_Action',
                'SAB_Reverse_Journal_Action'
            )
        ]) {
            permissionSetIds.put(ps.Name, ps.Id);
        }

        System.assertEquals(
            3,
            permissionSetIds.size(),
            'Required SAB permission sets must be deployed.'
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = reversalUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        'SAB_Remaining_Fields_Admin'
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = reversalUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        'SAB_Post_Journal_Action'
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = reversalUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        'SAB_Reverse_Journal_Action'
                    )
            )
        };
    }

    private static User reversalUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB Reversal User'
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

    private static Journal_Entry__c makeDraftJournal(
        Id companyId,
        Id periodId,
        String description
    ) {
        Journal_Entry__c journal =
            new Journal_Entry__c(
                Company__c = companyId,
                Accounting_Period__c = periodId,
                Accounting_Date__c =
                    Date.newInstance(2026, 9, 10),
                Entry_Type__c = 'Manual',
                Status__c = 'Draft',
                Description__c = description,
                Version__c = 1
            );

        insert journal;
        return journal;
    }

    private static void addBalancedLines(
        Id journalId,
        Id debitAccountId,
        Id creditAccountId,
        Decimal amount
    ) {
        insert new List<Journal_Entry_Line__c>{
            new Journal_Entry_Line__c(
                Journal_Entry__c = journalId,
                GL_Account__c = debitAccountId,
                Line_Number__c = 1,
                Debit_Base__c = amount,
                Credit_Base__c = 0,
                Functional_Currency__c = 'BDT',
                Transaction_Currency__c = 'BDT',
                Transaction_Amount__c = amount,
                Applied_Exchange_Rate__c = 1,
                Rate_Date__c =
                    Date.newInstance(2026, 9, 10),
                Rate_Source__c = 'Test',
                Explanation__c = 'Debit test line'
            ),
            new Journal_Entry_Line__c(
                Journal_Entry__c = journalId,
                GL_Account__c = creditAccountId,
                Line_Number__c = 2,
                Debit_Base__c = 0,
                Credit_Base__c = amount,
                Functional_Currency__c = 'BDT',
                Transaction_Currency__c = 'BDT',
                Transaction_Amount__c = -amount,
                Applied_Exchange_Rate__c = 1,
                Rate_Date__c =
                    Date.newInstance(2026, 9, 10),
                Rate_Source__c = 'Test',
                Explanation__c = 'Credit test line'
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

    private static SABPostingService.PostingRequest
        originalPostingRequest(
            Journal_Entry__c journal,
            String suffixValue
        ) {

        SABAccountingEventService.ReservationRequest eventRequest =
            new SABAccountingEventService.ReservationRequest();

        eventRequest.companyId = journal.Company__c;
        eventRequest.adapterKey = 'MANUAL_JOURNAL';
        eventRequest.requestKey = 'REQ-ORIG-' + suffixValue;
        eventRequest.eventKey = 'EVENT-ORIG-' + suffixValue;
        eventRequest.eventType = 'Manual Journal';
        eventRequest.sourceBusinessKey = 'POST-ORIG-' + suffixValue;
        eventRequest.sourceRecordId = String.valueOf(journal.Id);
        eventRequest.sourceType = 'Journal_Entry__c';
        eventRequest.sourceVersion = 1;

        SABPostingService.PostingRequest request =
            new SABPostingService.PostingRequest();

        request.journalEntryId = journal.Id;
        request.postingKey = 'POST-ORIG-' + suffixValue;
        request.eventRequest = eventRequest;

        return request;
    }

    private static SABReversalService.ReversalRequest
        reversalRequest(
            Id originalJournalId,
            Id periodId,
            String suffixValue
        ) {

        SABReversalService.ReversalRequest request =
            new SABReversalService.ReversalRequest();

        request.originalJournalEntryId =
            originalJournalId;
        request.reversalAccountingPeriodId =
            periodId;
        request.reversalAccountingDate =
            Date.newInstance(2026, 9, 20);
        request.postingKey =
            'POST-REV-' + suffixValue;
        request.eventKey =
            'EVENT-REV-' + suffixValue;
        request.requestKey =
            'REQ-REV-' + suffixValue;
        request.reason =
            'Correction test';

        return request;
    }

    @IsTest
    static void postedJournalIsReversedWithOppositeLines() {
        User u = reversalUser();

        Accounting_Company__c company =
            makeCompany('RV1', 'Reversal Company One');

        Accounting_Period__c period =
            makePeriod(company.Id, 'RV1', 'Open');

        GL_Account__c debitAccount =
            makeGLAccount(company.Id, '7100');

        GL_Account__c creditAccount =
            makeGLAccount(company.Id, '2100');

        Journal_Entry__c originalJournal =
            makeDraftJournal(
                company.Id,
                period.Id,
                'Original journal'
            );

        addBalancedLines(
            originalJournal.Id,
            debitAccount.Id,
            creditAccount.Id,
            100
        );

        grantCompanyAccess(
            company.Id,
            u.Id,
            'REV-GRANT-1'
        );

        SABReversalService.ReversalResult result;

        System.runAs(u) {
            SABPostingService.postDraftJournal(
                originalPostingRequest(
                    originalJournal,
                    'RV1'
                )
            );

            Test.startTest();

            result =
                SABReversalService.reversePostedJournal(
                    reversalRequest(
                        originalJournal.Id,
                        period.Id,
                        'RV1'
                    )
                );

            Test.stopTest();
        }

        System.assertEquals(false, result.replay);
        System.assertNotEquals(
            null,
            result.reversalJournalEntryId
        );
        System.assertNotEquals(
            null,
            result.reversalAccountingEventId
        );

        Journal_Entry__c storedOriginal = [
            SELECT Status__c,
                   Reversal_Journal__c,
                   Accounting_Event__c
            FROM Journal_Entry__c
            WHERE Id = :originalJournal.Id
        ];

        System.assertEquals(
            'Reversed',
            storedOriginal.Status__c
        );
        System.assertEquals(
            result.reversalJournalEntryId,
            storedOriginal.Reversal_Journal__c
        );

        Journal_Entry__c reversalJournal = [
            SELECT Status__c,
                   Entry_Type__c,
                   Reversal_Of__c,
                   Posting_Key__c,
                   Accounting_Event__c
            FROM Journal_Entry__c
            WHERE Id = :result.reversalJournalEntryId
        ];

        System.assertEquals(
            'Posted',
            reversalJournal.Status__c
        );
        System.assertEquals(
            'Reversal',
            reversalJournal.Entry_Type__c
        );
        System.assertEquals(
            originalJournal.Id,
            reversalJournal.Reversal_Of__c
        );
        System.assertEquals(
            'POST-REV-RV1',
            reversalJournal.Posting_Key__c
        );

        List<Journal_Entry_Line__c> originalLines = [
            SELECT Line_Number__c,
                   Debit_Base__c,
                   Credit_Base__c,
                   Transaction_Amount__c
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__c = :originalJournal.Id
            ORDER BY Line_Number__c
        ];

        List<Journal_Entry_Line__c> reversalLines = [
            SELECT Line_Number__c,
                   Debit_Base__c,
                   Credit_Base__c,
                   Transaction_Amount__c
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__c = :reversalJournal.Id
            ORDER BY Line_Number__c
        ];

        System.assertEquals(
            originalLines.size(),
            reversalLines.size()
        );

        for (Integer i = 0; i < originalLines.size(); i++) {
            System.assertEquals(
                originalLines[i].Debit_Base__c,
                reversalLines[i].Credit_Base__c
            );
            System.assertEquals(
                originalLines[i].Credit_Base__c,
                reversalLines[i].Debit_Base__c
            );
            System.assertEquals(
                -originalLines[i].Transaction_Amount__c,
                reversalLines[i].Transaction_Amount__c
            );
        }

        Accounting_Event__c originalEvent = [
            SELECT State__c,
                   Reversal_Event__c
            FROM Accounting_Event__c
            WHERE Id = :storedOriginal.Accounting_Event__c
        ];

        System.assertEquals(
            'Reversed',
            originalEvent.State__c
        );
        System.assertEquals(
            result.reversalAccountingEventId,
            originalEvent.Reversal_Event__c
        );
    }

    @IsTest
    static void identicalRetryReturnsExistingReversal() {
        User u = reversalUser();

        Accounting_Company__c company =
            makeCompany('RV2', 'Reversal Company Two');

        Accounting_Period__c period =
            makePeriod(company.Id, 'RV2', 'Open');

        GL_Account__c debitAccount =
            makeGLAccount(company.Id, '7200');

        GL_Account__c creditAccount =
            makeGLAccount(company.Id, '2200');

        Journal_Entry__c originalJournal =
            makeDraftJournal(
                company.Id,
                period.Id,
                'Replay reversal journal'
            );

        addBalancedLines(
            originalJournal.Id,
            debitAccount.Id,
            creditAccount.Id,
            50
        );

        grantCompanyAccess(
            company.Id,
            u.Id,
            'REV-GRANT-2'
        );

        SABReversalService.ReversalRequest request =
            reversalRequest(
                originalJournal.Id,
                period.Id,
                'RV2'
            );

        System.runAs(u) {
            SABPostingService.postDraftJournal(
                originalPostingRequest(
                    originalJournal,
                    'RV2'
                )
            );

            SABReversalService.ReversalResult firstResult =
                SABReversalService.reversePostedJournal(
                    request
                );

            SABReversalService.ReversalResult secondResult =
                SABReversalService.reversePostedJournal(
                    request
                );

            System.assertEquals(true, secondResult.replay);
            System.assertEquals(
                firstResult.reversalJournalEntryId,
                secondResult.reversalJournalEntryId
            );
            System.assertEquals(
                firstResult.reversalAccountingEventId,
                secondResult.reversalAccountingEventId
            );
        }
    }

    @IsTest
    static void draftJournalCannotBeReversed() {
        User u = reversalUser();

        Accounting_Company__c company =
            makeCompany('RV3', 'Reversal Company Three');

        Accounting_Period__c period =
            makePeriod(company.Id, 'RV3', 'Open');

        Journal_Entry__c draftJournal =
            makeDraftJournal(
                company.Id,
                period.Id,
                'Draft cannot reverse'
            );

        grantCompanyAccess(
            company.Id,
            u.Id,
            'REV-GRANT-3'
        );

        System.runAs(u) {
            Boolean thrown = false;

            try {
                SABReversalService.reversePostedJournal(
                    reversalRequest(
                        draftJournal.Id,
                        period.Id,
                        'RV3'
                    )
                );
            } catch (Exception ex) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }
    }

    @IsTest
    static void closedReversalPeriodRollsBack() {
        User u = reversalUser();

        Accounting_Company__c company =
            makeCompany('RV4', 'Reversal Company Four');

        Accounting_Period__c openPeriod =
            makePeriod(company.Id, 'RV4A', 'Open');

        Accounting_Period__c closedPeriod =
            makePeriod(company.Id, 'RV4B', 'Closed');

        GL_Account__c debitAccount =
            makeGLAccount(company.Id, '7400');

        GL_Account__c creditAccount =
            makeGLAccount(company.Id, '2400');

        Journal_Entry__c originalJournal =
            makeDraftJournal(
                company.Id,
                openPeriod.Id,
                'Closed reversal period test'
            );

        addBalancedLines(
            originalJournal.Id,
            debitAccount.Id,
            creditAccount.Id,
            30
        );

        grantCompanyAccess(
            company.Id,
            u.Id,
            'REV-GRANT-4'
        );

        System.runAs(u) {
            SABPostingService.postDraftJournal(
                originalPostingRequest(
                    originalJournal,
                    'RV4'
                )
            );

            Boolean thrown = false;

            try {
                SABReversalService.reversePostedJournal(
                    reversalRequest(
                        originalJournal.Id,
                        closedPeriod.Id,
                        'RV4'
                    )
                );
            } catch (Exception ex) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }

        Journal_Entry__c storedOriginal = [
            SELECT Status__c,
                   Reversal_Journal__c
            FROM Journal_Entry__c
            WHERE Id = :originalJournal.Id
        ];

        System.assertEquals(
            'Posted',
            storedOriginal.Status__c
        );
        System.assertEquals(
            null,
            storedOriginal.Reversal_Journal__c
        );

        System.assertEquals(
            0,
            [
                SELECT COUNT()
                FROM Journal_Entry__c
                WHERE Reversal_Of__c = :originalJournal.Id
            ]
        );
    }

    @IsTest
    static void userWithoutCompanyAccessCannotReverse() {
        User u = reversalUser();

        Accounting_Company__c company =
            makeCompany('RV5', 'Unauthorized Reversal Company');

        Accounting_Period__c period =
            makePeriod(company.Id, 'RV5', 'Open');

        GL_Account__c debitAccount =
            makeGLAccount(company.Id, '7500');

        GL_Account__c creditAccount =
            makeGLAccount(company.Id, '2500');

        Journal_Entry__c originalJournal =
            makeDraftJournal(
                company.Id,
                period.Id,
                'Unauthorized reversal source'
            );

        addBalancedLines(
            originalJournal.Id,
            debitAccount.Id,
            creditAccount.Id,
            25
        );

        // Give the user temporary company access only so the source journal
        // can be posted through the real trusted posting service.
        grantCompanyAccess(
            company.Id,
            u.Id,
            'REV-GRANT-5'
        );

        System.runAs(u) {
            SABPostingService.postDraftJournal(
                originalPostingRequest(
                    originalJournal,
                    'RV5'
                )
            );
        }

        // Remove the company grant before attempting the reversal.
        // The user still has the reversal permission set, but no longer has
        // Company_User_Access__c for this company.
        Company_User_Access__c accessGrant = [
            SELECT Id
            FROM Company_User_Access__c
            WHERE Company__c = :company.Id
              AND User__c = :u.Id
            LIMIT 1
        ];
        delete accessGrant;

        System.runAs(u) {
            Boolean thrown = false;

            try {
                SABReversalService.reversePostedJournal(
                    reversalRequest(
                        originalJournal.Id,
                        period.Id,
                        'RV5'
                    )
                );
            } catch (Exception ex) {
                thrown = true;
            }

            System.assertEquals(
                true,
                thrown,
                'Reversal must fail after company access is removed.'
            );
        }

        Journal_Entry__c storedOriginal = [
            SELECT Status__c,
                   Reversal_Journal__c
            FROM Journal_Entry__c
            WHERE Id = :originalJournal.Id
        ];

        System.assertEquals(
            'Posted',
            storedOriginal.Status__c
        );
        System.assertEquals(
            null,
            storedOriginal.Reversal_Journal__c
        );
    }
}
