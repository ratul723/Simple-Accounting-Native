@IsTest
private class SABAccountingEventServiceTest {

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
            'sabacctevent.'
            + String.valueOf(DateTime.now().getTime());

        User postingUser = new User(
            Alias = 'sabacct',
            Email = uniqueValue + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Accounting Event User',
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
            WHERE LastName =
                'SAB Accounting Event User'
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
        String suffixValue
    ) {
        Accounting_Period__c period =
            new Accounting_Period__c(
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
                Status__c = 'Open'
            );

        insert period;
        return period;
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

    private static SABAccountingEventService.ReservationRequest
        requestFor(
            Id companyId,
            String eventKey
        ) {

        SABAccountingEventService.ReservationRequest request =
            new SABAccountingEventService.ReservationRequest();

        request.companyId = companyId;
        request.adapterKey = 'MANUAL_JOURNAL';
        request.requestKey = 'REQ-' + eventKey;
        request.eventKey = eventKey;
        request.eventType = 'Manual Journal';
        request.sourceBusinessKey = 'MANUAL-' + eventKey;
        request.sourceRecordId = null;
        request.sourceType = 'Journal_Entry__c';
        request.sourceVersion = 1;

        return request;
    }

    @IsTest
    static void reserveCreatesEventAndReplayReturnsSameEvent() {
        User u = postingUser();

        Accounting_Company__c company =
            makeCompany('E1', 'Event Company One');

        grantCompanyAccess(
            company.Id,
            u.Id,
            'EVENT-GRANT-1'
        );

        SABAccountingEventService.EventResult firstResult;
        SABAccountingEventService.EventResult replayResult;

        System.runAs(u) {
            Test.startTest();

            firstResult =
                SABAccountingEventService.reserveForPosting(
                    requestFor(
                        company.Id,
                        'EVENT-E1-001'
                    )
                );

            replayResult =
                SABAccountingEventService.reserveForPosting(
                    requestFor(
                        company.Id,
                        'EVENT-E1-001'
                    )
                );

            Test.stopTest();
        }

        System.assertNotEquals(
            null,
            firstResult.accountingEventId
        );

        System.assertEquals(
            false,
            firstResult.replay
        );

        System.assertEquals(
            'Reserved',
            firstResult.state
        );

        System.assertEquals(
            firstResult.accountingEventId,
            replayResult.accountingEventId
        );

        System.assertEquals(
            true,
            replayResult.replay
        );

        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM Accounting_Event__c
                WHERE Event_Key__c = 'EVENT-E1-001'
            ]
        );
    }

    @IsTest
    static void sameEventKeyWithDifferentIdentityIsRejected() {
        User u = postingUser();

        Accounting_Company__c company =
            makeCompany('E2', 'Event Company Two');

        grantCompanyAccess(
            company.Id,
            u.Id,
            'EVENT-GRANT-2'
        );

        System.runAs(u) {
            SABAccountingEventService.reserveForPosting(
                requestFor(
                    company.Id,
                    'EVENT-E2-001'
                )
            );

            SABAccountingEventService.ReservationRequest changed =
                requestFor(
                    company.Id,
                    'EVENT-E2-001'
                );

            changed.sourceBusinessKey =
                'DIFFERENT-BUSINESS-KEY';

            Boolean thrown = false;

            try {
                SABAccountingEventService.reserveForPosting(
                    changed
                );
            } catch (
                SABAccountingEventService.AccountingEventException ex
            ) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }
    }

    @IsTest
    static void userWithoutCompanyGrantCannotReserveEvent() {
        User u = postingUser();

        Accounting_Company__c company =
            makeCompany('E3', 'Unauthorized Company');

        System.runAs(u) {
            Boolean thrown = false;

            try {
                SABAccountingEventService.reserveForPosting(
                    requestFor(
                        company.Id,
                        'EVENT-E3-001'
                    )
                );
            } catch (
                SABCompanyAccessService.CompanyAccessDeniedException ex
            ) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }
    }

    @IsTest
    static void attachPostedJournalCompletesReservedEvent() {
        User u = postingUser();

        Accounting_Company__c company =
            makeCompany('E4', 'Posting Company');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'E4-2026-09'
            );

        grantCompanyAccess(
            company.Id,
            u.Id,
            'EVENT-GRANT-4'
        );

        Id eventId;

        System.runAs(u) {
            SABAccountingEventService.EventResult reserveResult =
                SABAccountingEventService.reserveForPosting(
                    requestFor(
                        company.Id,
                        'EVENT-E4-001'
                    )
                );

            eventId = reserveResult.accountingEventId;
        }

        // Create the posted journal as the admin test context. The next
        // SABPostingService step will own this creation in production.
        Journal_Entry__c journal =
            new Journal_Entry__c(
                Company__c = company.Id,
                Accounting_Period__c = period.Id,
                Accounting_Date__c =
                    Date.newInstance(2026, 9, 15),
                Entry_Type__c = 'Manual',
                Status__c = 'Posted',
                Posting_Key__c = 'POST-E4-001',
                Description__c =
                    'Accounting Event service test',
                Version__c = 1,
                Accounting_Event__c = eventId,
                Posted_By__c = UserInfo.getUserId(),
                Posted_At__c = System.now()
            );

        insert journal;

        SABAccountingEventService.EventResult attachResult;

        System.runAs(u) {
            Test.startTest();

            attachResult =
                SABAccountingEventService.attachPostedJournal(
                    eventId,
                    journal.Id
                );

            Test.stopTest();
        }

        System.assertEquals(false, attachResult.replay);
        System.assertEquals('Posted', attachResult.state);
        System.assertEquals(
            journal.Id,
            attachResult.journalEntryId
        );

        Accounting_Event__c storedEvent = [
            SELECT State__c, Journal_Entry__c
            FROM Accounting_Event__c
            WHERE Id = :eventId
        ];

        System.assertEquals(
            'Posted',
            storedEvent.State__c
        );

        System.assertEquals(
            journal.Id,
            storedEvent.Journal_Entry__c
        );

        // Calling attach again is idempotent.
        System.runAs(u) {
            SABAccountingEventService.EventResult replayAttach =
                SABAccountingEventService.attachPostedJournal(
                    eventId,
                    journal.Id
                );

            System.assertEquals(
                true,
                replayAttach.replay
            );
        }
    }

    @IsTest
    static void invalidRequestIsRejectedBeforeInsert() {
        User u = postingUser();

        Accounting_Company__c company =
            makeCompany('E5', 'Validation Company');

        grantCompanyAccess(
            company.Id,
            u.Id,
            'EVENT-GRANT-5'
        );

        System.runAs(u) {
            SABAccountingEventService.ReservationRequest request =
                requestFor(
                    company.Id,
                    'EVENT-E5-001'
                );

            request.adapterKey = null;

            Boolean thrown = false;

            try {
                SABAccountingEventService.reserveForPosting(
                    request
                );
            } catch (
                SABAccountingEventService.AccountingEventException ex
            ) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }
    }
}
