@IsTest
private class SABAuditTimelineControllerTest {

    @IsTest
    static void timelineIsCompanyScopedAndCombinesAuditSources() {
        Accounting_Company__c companyA =
            makeCompany(
                'A1',
                'Audit Company A'
            );

        Accounting_Company__c companyB =
            makeCompany(
                'B1',
                'Audit Company B'
            );

        grantCurrentUser(
            companyA.Id,
            'AUD-A'
        );

        Accounting_Period__c periodA =
            makePeriod(
                companyA.Id,
                'A1'
            );

        Accounting_Period__c periodB =
            makePeriod(
                companyB.Id,
                'B1'
            );

        Accounting_Event__c eventA =
            makeEvent(
                companyA.Id,
                'EV-A'
            );

        Accounting_Event__c eventB =
            makeEvent(
                companyB.Id,
                'EV-B'
            );

        insert new List<Accounting_Event__c>{
            eventA,
            eventB
        };

        Journal_Entry__c journalA =
            makePostedJournal(
                companyA.Id,
                periodA.Id,
                eventA.Id,
                'PK-A'
            );

        Journal_Entry__c journalB =
            makePostedJournal(
                companyB.Id,
                periodB.Id,
                eventB.Id,
                'PK-B'
            );

        insert new List<Journal_Entry__c>{
            journalA,
            journalB
        };

        insert new Accounting_Period_Action__c(
            Period__c =
                periodA.Id,
            Previous_Status__c =
                'Open',
            New_Status__c =
                'Closed',
            Performed_By__c =
                UserInfo.getUserId(),
            Performed_At__c =
                System.now().addMinutes(-2),
            Reason__c =
                'Month end complete',
            Request_Key__c =
                'PER-A1'
        );

        insert new Business_Action__c(
            Company__c =
                companyA.Id,
            Source_Type__c =
                'Journal_Entry__c',
            Source_Record_Id__c =
                String.valueOf(
                    journalA.Id
                ),
            Source_Version__c =
                1,
            Action__c =
                'Reviewed Journal',
            Actor__c =
                UserInfo.getUserId(),
            Action_At__c =
                System.now().addMinutes(-1),
            Reason__c =
                'Audit review',
            Request_Key__c =
                'BUS-A1'
        );

        Test.startTest();

        SABAuditTimelineController.TimelineDTO result =
            SABAuditTimelineController.getTimeline(
                companyA.Id
            );

        Test.stopTest();

        System.assertEquals(
            companyA.Id,
            result.companyId
        );

        System.assertEquals(
            1,
            result.businessActionCount
        );

        System.assertEquals(
            1,
            result.periodActionCount
        );

        System.assertEquals(
            1,
            result.journalActionCount
        );

        System.assertEquals(
            1,
            result.accountingEventCount
        );

        System.assertEquals(
            4,
            result.items.size()
        );

        Set<String> categories =
            new Set<String>();

        for (
            SABAuditTimelineController.TimelineItemDTO item
            : result.items
        ) {
            categories.add(
                item.category
            );

            System.assertNotEquals(
                String.valueOf(
                    journalB.Id
                ),
                item.sourceRecordId,
                'Company B records must not appear in Company A timeline.'
            );
        }

        System.assertEquals(
            new Set<String>{
                'BUSINESS',
                'PERIOD',
                'JOURNAL',
                'EVENT'
            },
            categories
        );
    }

    @IsTest
    static void companyAccessIsRequiredEvenForRecordOwner() {
        Accounting_Company__c company =
            makeCompany(
                'C1',
                'Audit Company C'
            );

        Boolean thrown =
            false;

        Test.startTest();

        try {
            SABAuditTimelineController.getTimeline(
                company.Id
            );
        } catch (Exception ex) {
            thrown =
                true;
        }

        Test.stopTest();

        System.assertEquals(
            true,
            thrown,
            'Company_User_Access__c authorization must still be required.'
        );
    }

    private static Accounting_Company__c makeCompany(
        String keyValue,
        String displayName
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    displayName,
                Company_Key__c =
                    keyValue,
                Country_Code__c =
                    'BD',
                Functional_Currency__c =
                    'BDT',
                Fiscal_Calendar_Type__c =
                    'Calendar',
                Fiscal_Year_Start_Month__c =
                    1,
                Setup_Status__c =
                    'Active',
                Is_Active__c =
                    true
            );

        insert company;
        return company;
    }

    private static void grantCurrentUser(
        Id companyId,
        String grantKey
    ) {
        insert new Company_User_Access__c(
            Company__c =
                companyId,
            User__c =
                UserInfo.getUserId(),
            Effective_From__c =
                Date.today(),
            Grant_Key__c =
                grantKey,
            Is_Active__c =
                true,
            Role__c =
                'Finance Manager'
        );
    }

    private static Accounting_Period__c makePeriod(
        Id companyId,
        String suffixValue
    ) {
        Accounting_Period__c period =
            new Accounting_Period__c(
                Name =
                    'Period ' + suffixValue,
                Company__c =
                    companyId,
                Company_Period_Key__c =
                    'CP-' + suffixValue,
                Period_Key__c =
                    'P-' + suffixValue,
                Start_Date__c =
                    Date.newInstance(
                        2026,
                        9,
                        1
                    ),
                End_Date__c =
                    Date.newInstance(
                        2026,
                        9,
                        30
                    ),
                Fiscal_Year__c =
                    2026,
                Fiscal_Quarter__c =
                    3,
                Period_Number__c =
                    9,
                Status__c =
                    'Open'
            );

        insert period;
        return period;
    }

    private static Accounting_Event__c makeEvent(
        Id companyId,
        String eventKey
    ) {
        return new Accounting_Event__c(
            Company__c =
                companyId,
            Adapter_Key__c =
                'MANUAL_JOURNAL',
            Event_Key__c =
                eventKey,
            Event_Type__c =
                'Manual Journal',
            Source_Type__c =
                'Journal_Entry__c',
            Source_Record_Id__c =
                null,
            Source_Version__c =
                1,
            State__c =
                'Posted',
            Created_Request_Key__c =
                'REQ-' + eventKey
        );
    }

    private static Journal_Entry__c makePostedJournal(
        Id companyId,
        Id periodId,
        Id eventId,
        String postingKey
    ) {
        return new Journal_Entry__c(
            Company__c =
                companyId,
            Accounting_Period__c =
                periodId,
            Accounting_Date__c =
                Date.newInstance(
                    2026,
                    9,
                    24
                ),
            Entry_Type__c =
                'Manual',
            Status__c =
                'Posted',
            Description__c =
                'Audit test journal',
            Version__c =
                1,
            Posting_Key__c =
                postingKey,
            Posted_By__c =
                UserInfo.getUserId(),
            Posted_At__c =
                System.now(),
            Accounting_Event__c =
                eventId
        );
    }
}
