@IsTest
private class SABLedgerReportServiceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String POST_PERMISSION_SET =
        'SAB_Post_Journal_Action';

    private static final String REVERSE_PERMISSION_SET =
        'SAB_Reverse_Journal_Action';

    @TestSetup
    static void setupReportingUserAndReversalFixture() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String seed =
            String.valueOf(
                DateTime.now().getTime()
            );

        User u = new User(
            Alias = 'sabrpt',
            Email =
                'sabrpt.' + seed + '@example.test',
            EmailEncodingKey =
                'UTF-8',
            LastName =
                'SAB Reporting User',
            LanguageLocaleKey =
                'en_US',
            LocaleSidKey =
                'en_US',
            ProfileId =
                p.Id,
            TimeZoneSidKey =
                'Asia/Dhaka',
            Username =
                'sabrpt.' + seed + '@example.test'
        );

        insert u;

        Map<String, Id> permissionSetIds =
            new Map<String, Id>();

        for (PermissionSet ps : [
            SELECT Id,
                   Name
            FROM PermissionSet
            WHERE Name IN (
                :ADMIN_PERMISSION_SET,
                :POST_PERMISSION_SET,
                :REVERSE_PERMISSION_SET
            )
        ]) {
            permissionSetIds.put(
                ps.Name,
                ps.Id
            );
        }

        System.assertEquals(
            3,
            permissionSetIds.size(),
            'Reporting regression requires the SAB data, post and reverse permission sets.'
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId =
                    u.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        ADMIN_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId =
                    u.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        POST_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId =
                    u.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        REVERSE_PERMISSION_SET
                    )
            )
        };

        // Build ONE posted fixture in @TestSetup. Test-setup governor limits are
        // separate from each individual @IsTest method. The reversal test can
        // therefore use one fresh reversal transaction without stacking two
        // full posting-service executions into the same test method.
        System.runAs(u) {
            Accounting_Company__c company =
                makeCompany(
                    'RV',
                    'Reversal Reporting Fixture'
                );

            grant(
                company.Id,
                u.Id,
                'TB-RV'
            );

            Accounting_Period__c period =
                makePeriod(
                    company.Id,
                    'RV',
                    Date.newInstance(
                        2026,
                        1,
                        1
                    ),
                    Date.newInstance(
                        2026,
                        1,
                        31
                    )
                );

            GL_Account__c cash =
                makeAccount(
                    company.Id,
                    '1000',
                    'Fixture Cash',
                    'Asset',
                    'Debit'
                );

            GL_Account__c expense =
                makeAccount(
                    company.Id,
                    '6000',
                    'Fixture Expense',
                    'Expense',
                    'Debit'
                );

            Journal_Entry__c original =
                makeDraftJournal(
                    company.Id,
                    period.Id,
                    Date.newInstance(
                        2026,
                        1,
                        15
                    ),
                    'Manual',
                    'Fixture original to reverse'
                );

            insertLines(
                original.Id,
                new List<LineSeed>{
                    new LineSeed(
                        expense.Id,
                        50,
                        0
                    ),
                    new LineSeed(
                        cash.Id,
                        0,
                        50
                    )
                }
            );

            SABPostingService.postDraftJournal(
                postingRequest(
                    original,
                    'FIXTURE-RV'
                )
            );
        }
    }

    @IsTest
    static void openingBalanceUsesPostedLedgerBeforeRange() {
        User reportUser =
            getReportingUser();

        Accounting_Company__c company =
            makeCompany(
                'O1',
                'Opening Balance Test'
            );

        grant(
            company.Id,
            reportUser.Id,
            'TB-O1'
        );

        Accounting_Period__c openingPeriod =
            makePeriod(
                company.Id,
                'O0',
                Date.newInstance(
                    2025,
                    12,
                    1
                ),
                Date.newInstance(
                    2025,
                    12,
                    31
                )
            );

        GL_Account__c cash =
            makeAccount(
                company.Id,
                '1000',
                'Cash',
                'Asset',
                'Debit'
            );

        GL_Account__c equity =
            makeAccount(
                company.Id,
                '3000',
                'Opening Equity',
                'Equity',
                'Credit'
            );

        Journal_Entry__c opening =
            makeDraftJournal(
                company.Id,
                openingPeriod.Id,
                Date.newInstance(
                    2025,
                    12,
                    31
                ),
                'Opening',
                'Opening balance'
            );

        insertLines(
            opening.Id,
            new List<LineSeed>{
                new LineSeed(
                    cash.Id,
                    500,
                    0
                ),
                new LineSeed(
                    equity.Id,
                    0,
                    500
                )
            }
        );

        // The production posting pipeline is deliberately heavy: access,
        // validation, event/idempotency and sharing checks all run here.
        // Give that ONE business transaction a fresh governor context.
        Test.startTest();

        postJournal(
            reportUser,
            opening,
            'OPEN-O1'
        );

        Test.stopTest();

        SABLedgerReportService.TrialBalanceResult result;

        System.runAs(reportUser) {
            SABLedgerReportService.TrialBalanceRequest request =
                new SABLedgerReportService.TrialBalanceRequest();

            request.companyId =
                company.Id;
            request.fromDate =
                Date.newInstance(
                    2026,
                    1,
                    1
                );
            request.toDate =
                Date.newInstance(
                    2026,
                    1,
                    31
                );
            request.includeZeroBalance =
                false;

            result =
                SABLedgerReportService.getTrialBalance(
                    request
                );
        }

        System.assertEquals(
            Decimal.valueOf('500'),
            result.totalOpeningDebit
        );

        System.assertEquals(
            Decimal.valueOf('500'),
            result.totalOpeningCredit
        );

        System.assertEquals(
            Decimal.valueOf('0'),
            result.totalMovementDebit
        );

        System.assertEquals(
            Decimal.valueOf('0'),
            result.totalMovementCredit
        );

        System.assertEquals(
            Decimal.valueOf('500'),
            result.totalClosingDebit
        );

        System.assertEquals(
            Decimal.valueOf('500'),
            result.totalClosingCredit
        );

        System.assertEquals(
            true,
            result.balanced
        );
    }

    @IsTest
    static void movementUsesPostedLedgerAndExcludesDraft() {
        User reportUser =
            getReportingUser();

        // Reuse the legitimate Posted journal created once in @TestSetup.
        // Every @IsTest method receives its own pristine copy of @TestSetup
        // data, so this Journal is still Posted here (the reversal performed
        // by another test method does not leak into this test).
        Accounting_Company__c company = [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c = 'RV'
            LIMIT 1
        ];

        Accounting_Period__c period = [
            SELECT Id
            FROM Accounting_Period__c
            WHERE Company__c = :company.Id
            LIMIT 1
        ];

        GL_Account__c cash = [
            SELECT Id
            FROM GL_Account__c
            WHERE Company__c = :company.Id
              AND Account_Code__c = '1000'
            LIMIT 1
        ];

        GL_Account__c expense = [
            SELECT Id
            FROM GL_Account__c
            WHERE Company__c = :company.Id
              AND Account_Code__c = '6000'
            LIMIT 1
        ];

        // Add a Draft with a very large amount. If Drafts accidentally enter
        // the ledger report, the expected 50/50 movement below will fail.
        Journal_Entry__c draft =
            makeDraftJournal(
                company.Id,
                period.Id,
                Date.newInstance(
                    2026,
                    1,
                    18
                ),
                'Manual',
                'Draft excluded from Trial Balance'
            );

        insertLines(
            draft.Id,
            new List<LineSeed>{
                new LineSeed(
                    expense.Id,
                    999,
                    0
                ),
                new LineSeed(
                    cash.Id,
                    0,
                    999
                )
            }
        );

        SABLedgerReportService.TrialBalanceResult result;

        System.runAs(reportUser) {
            SABLedgerReportService.TrialBalanceRequest request =
                new SABLedgerReportService.TrialBalanceRequest();

            request.companyId =
                company.Id;
            request.fromDate =
                Date.newInstance(
                    2026,
                    1,
                    1
                );
            request.toDate =
                Date.newInstance(
                    2026,
                    1,
                    31
                );
            request.includeZeroBalance =
                false;

            // IMPORTANT: this fresh governor context now belongs to the
            // REPORT under test, not to fixture creation.
            Test.startTest();

            result =
                SABLedgerReportService.getTrialBalance(
                    request
                );

            Test.stopTest();
        }

        System.assertEquals(
            Decimal.valueOf('50'),
            result.totalMovementDebit
        );

        System.assertEquals(
            Decimal.valueOf('50'),
            result.totalMovementCredit
        );

        System.assertEquals(
            Decimal.valueOf('50'),
            result.totalClosingDebit
        );

        System.assertEquals(
            Decimal.valueOf('50'),
            result.totalClosingCredit
        );

        System.assertEquals(
            true,
            result.balanced
        );

        Map<String, SABLedgerReportService.TrialBalanceRow> byCode =
            rowsByCode(
                result.rows
            );

        System.assertEquals(
            Decimal.valueOf('50'),
            byCode.get('6000').movementDebit
        );

        System.assertEquals(
            Decimal.valueOf('0'),
            byCode.get('6000').movementCredit
        );

        System.assertEquals(
            Decimal.valueOf('50'),
            byCode.get('1000').movementCredit
        );

        System.assertEquals(
            Decimal.valueOf('0'),
            byCode.get('1000').movementDebit
        );
    }

    @IsTest
    static void reversalKeepsOriginalAndOppositeInLedger() {
        User reportUser =
            getReportingUser();

        Accounting_Company__c company = [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c = 'RV'
            LIMIT 1
        ];

        Accounting_Period__c period = [
            SELECT Id
            FROM Accounting_Period__c
            WHERE Company__c = :company.Id
            LIMIT 1
        ];

        Journal_Entry__c original = [
            SELECT Id
            FROM Journal_Entry__c
            WHERE Company__c = :company.Id
              AND Status__c = 'Posted'
            LIMIT 1
        ];

        System.runAs(reportUser) {
            SABReversalService.ReversalRequest reversalRequest =
                new SABReversalService.ReversalRequest();

            reversalRequest.originalJournalEntryId =
                original.Id;
            reversalRequest.reversalAccountingPeriodId =
                period.Id;
            reversalRequest.reversalAccountingDate =
                Date.newInstance(
                    2026,
                    1,
                    20
                );
            reversalRequest.postingKey =
                'POST-RPT-REV-RV';
            reversalRequest.eventKey =
                'EVENT-RPT-REV-RV';
            reversalRequest.requestKey =
                'REQ-RPT-REV-RV';
            reversalRequest.reason =
                'Trial Balance reversal regression';

            Test.startTest();

            SABReversalService.reversePostedJournal(
                reversalRequest
            );

            Test.stopTest();
        }

        SABLedgerReportService.TrialBalanceResult result;

        System.runAs(reportUser) {
            SABLedgerReportService.TrialBalanceRequest request =
                new SABLedgerReportService.TrialBalanceRequest();

            request.companyId =
                company.Id;
            request.fromDate =
                Date.newInstance(
                    2026,
                    1,
                    1
                );
            request.toDate =
                Date.newInstance(
                    2026,
                    1,
                    31
                );
            request.includeZeroBalance =
                true;

            result =
                SABLedgerReportService.getTrialBalance(
                    request
                );
        }

        System.assertEquals(
            Decimal.valueOf('100'),
            result.totalMovementDebit
        );

        System.assertEquals(
            Decimal.valueOf('100'),
            result.totalMovementCredit
        );

        System.assertEquals(
            Decimal.valueOf('0'),
            result.totalClosingDebit
        );

        System.assertEquals(
            Decimal.valueOf('0'),
            result.totalClosingCredit
        );

        Map<String, SABLedgerReportService.TrialBalanceRow> byCode =
            rowsByCode(
                result.rows
            );

        System.assertEquals(
            Decimal.valueOf('50'),
            byCode.get('1000').movementDebit
        );

        System.assertEquals(
            Decimal.valueOf('50'),
            byCode.get('1000').movementCredit
        );

        System.assertEquals(
            Decimal.valueOf('0'),
            byCode.get('1000').closingDebit
        );

        System.assertEquals(
            Decimal.valueOf('0'),
            byCode.get('1000').closingCredit
        );

        System.assertEquals(
            Decimal.valueOf('50'),
            byCode.get('6000').movementDebit
        );

        System.assertEquals(
            Decimal.valueOf('50'),
            byCode.get('6000').movementCredit
        );

        System.assertEquals(
            Decimal.valueOf('0'),
            byCode.get('6000').closingDebit
        );

        System.assertEquals(
            Decimal.valueOf('0'),
            byCode.get('6000').closingCredit
        );

        System.assertEquals(
            'Reversed',
            [
                SELECT Status__c
                FROM Journal_Entry__c
                WHERE Id = :original.Id
            ].Status__c
        );
    }

    @IsTest
    static void otherCompanyLedgerDoesNotLeak() {
        User reportUser =
            getReportingUser();

        // @TestSetup already created Company RV with a legitimate Posted
        // journal. Reuse that as the "other company" ledger fixture rather
        // than performing another expensive posting pipeline in this test.
        Accounting_Company__c otherCompany = [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c = 'RV'
            LIMIT 1
        ];

        System.assert(
            [
                SELECT COUNT()
                FROM Journal_Entry__c
                WHERE Company__c = :otherCompany.Id
                  AND Status__c = 'Posted'
            ] > 0,
            'The shared fixture must contain posted ledger history.'
        );

        Accounting_Company__c companyA =
            makeCompany(
                'I1',
                'Isolation Company A'
            );

        grant(
            companyA.Id,
            reportUser.Id,
            'TB-I1'
        );

        GL_Account__c accountA =
            makeAccount(
                companyA.Id,
                '1000',
                'Company A Cash',
                'Asset',
                'Debit'
            );

        SABLedgerReportService.TrialBalanceResult result;

        System.runAs(reportUser) {
            SABLedgerReportService.TrialBalanceRequest request =
                new SABLedgerReportService.TrialBalanceRequest();

            request.companyId =
                companyA.Id;
            request.fromDate =
                Date.newInstance(
                    2026,
                    1,
                    1
                );
            request.toDate =
                Date.newInstance(
                    2026,
                    1,
                    31
                );
            request.includeZeroBalance =
                true;

            Test.startTest();

            result =
                SABLedgerReportService.getTrialBalance(
                    request
                );

            Test.stopTest();
        }

        System.assertEquals(
            Decimal.valueOf('0'),
            result.totalMovementDebit
        );

        System.assertEquals(
            Decimal.valueOf('0'),
            result.totalMovementCredit
        );

        System.assertEquals(
            1,
            result.rows.size()
        );

        System.assertEquals(
            accountA.Id,
            result.rows[0].glAccountId
        );

        System.assertEquals(
            '1000',
            result.rows[0].accountCode
        );
    }

    @IsTest
    static void movementDrilldownExcludesDraft() {
        User reportUser =
            getReportingUser();

        // Reuse the same legitimate Posted fixture from @TestSetup.
        Accounting_Company__c company = [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c = 'RV'
            LIMIT 1
        ];

        Accounting_Period__c period = [
            SELECT Id
            FROM Accounting_Period__c
            WHERE Company__c = :company.Id
            LIMIT 1
        ];

        GL_Account__c expense = [
            SELECT Id
            FROM GL_Account__c
            WHERE Company__c = :company.Id
              AND Account_Code__c = '6000'
            LIMIT 1
        ];

        GL_Account__c cash = [
            SELECT Id
            FROM GL_Account__c
            WHERE Company__c = :company.Id
              AND Account_Code__c = '1000'
            LIMIT 1
        ];

        Journal_Entry__c posted = [
            SELECT Id
            FROM Journal_Entry__c
            WHERE Company__c = :company.Id
              AND Status__c = 'Posted'
            LIMIT 1
        ];

        // Draft in the same account/date range must not appear in drilldown.
        Journal_Entry__c draft =
            makeDraftJournal(
                company.Id,
                period.Id,
                Date.newInstance(
                    2026,
                    1,
                    18
                ),
                'Manual',
                'Draft excluded from drilldown'
            );

        insertLines(
            draft.Id,
            new List<LineSeed>{
                new LineSeed(
                    expense.Id,
                    999,
                    0
                ),
                new LineSeed(
                    cash.Id,
                    0,
                    999
                )
            }
        );

        List<SABLedgerReportService.LedgerLine> lines;

        System.runAs(reportUser) {
            // Fresh governor budget belongs to the report query itself.
            Test.startTest();

            lines =
                SABLedgerReportService.getAccountMovementLines(
                    company.Id,
                    expense.Id,
                    Date.newInstance(
                        2026,
                        1,
                        1
                    ),
                    Date.newInstance(
                        2026,
                        1,
                        31
                    )
                );

            Test.stopTest();
        }

        System.assertEquals(
            1,
            lines.size()
        );

        System.assertEquals(
            posted.Id,
            lines[0].journalId
        );

        System.assertEquals(
            Decimal.valueOf('50'),
            lines[0].debit
        );

        System.assertEquals(
            Decimal.valueOf('0'),
            lines[0].credit
        );
    }

    @IsTest
    static void fromDateAfterToDateIsRejected() {
        User reportUser =
            getReportingUser();

        Accounting_Company__c company =
            makeCompany(
                'E1',
                'Invalid Range'
            );

        grant(
            company.Id,
            reportUser.Id,
            'TB-E1'
        );

        Boolean thrown =
            false;

        System.runAs(reportUser) {
            SABLedgerReportService.TrialBalanceRequest request =
                new SABLedgerReportService.TrialBalanceRequest();

            request.companyId =
                company.Id;
            request.fromDate =
                Date.newInstance(
                    2026,
                    5,
                    31
                );
            request.toDate =
                Date.newInstance(
                    2026,
                    5,
                    1
                );

            Test.startTest();

            try {
                SABLedgerReportService.getTrialBalance(
                    request
                );
            } catch (SABLedgerReportService.ReportException ex) {
                thrown =
                    true;
            }

            Test.stopTest();
        }

        System.assertEquals(
            true,
            thrown
        );
    }

    private class LineSeed {
        Id accountId;
        Decimal debit;
        Decimal credit;

        LineSeed(
            Id accountIdValue,
            Decimal debitValue,
            Decimal creditValue
        ) {
            accountId =
                accountIdValue;
            debit =
                debitValue;
            credit =
                creditValue;
        }
    }

    private static User getReportingUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                'SAB Reporting User'
            LIMIT 1
        ];
    }

    private static Map<String, SABLedgerReportService.TrialBalanceRow> rowsByCode(
        List<SABLedgerReportService.TrialBalanceRow> rows
    ) {
        Map<String, SABLedgerReportService.TrialBalanceRow> result =
            new Map<String, SABLedgerReportService.TrialBalanceRow>();

        for (
            SABLedgerReportService.TrialBalanceRow row
            : rows
        ) {
            result.put(
                row.accountCode,
                row
            );
        }

        return result;
    }

    private static Accounting_Company__c makeCompany(
        String keyValue,
        String nameValue
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    nameValue,
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

    private static void grant(
        Id companyId,
        Id userId,
        String grantKey
    ) {
        insert new Company_User_Access__c(
            Company__c =
                companyId,
            User__c =
                userId,
            Effective_From__c =
                Date.today(),
            Effective_To__c =
                null,
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
        String suffixValue,
        Date startDate,
        Date endDate
    ) {
        Integer quarterNumber =
            (
                (
                    startDate.month()
                    - 1
                )
                / 3
            )
            + 1;

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
                    startDate,
                End_Date__c =
                    endDate,
                Fiscal_Year__c =
                    startDate.year(),
                Fiscal_Quarter__c =
                    quarterNumber,
                Period_Number__c =
                    startDate.month(),
                Status__c =
                    'Open'
            );

        insert period;
        return period;
    }

    private static GL_Account__c makeAccount(
        Id companyId,
        String code,
        String nameValue,
        String typeValue,
        String normalBalance
    ) {
        GL_Account__c account =
            new GL_Account__c(
                Name =
                    nameValue,
                Company__c =
                    companyId,
                Company_Account_Key__c =
                    String.valueOf(
                        companyId
                    )
                    + '-'
                    + code,
                Account_Code__c =
                    code,
                Account_Type__c =
                    typeValue,
                Normal_Balance__c =
                    normalBalance,
                Is_Active__c =
                    true,
                Is_Control_Account__c =
                    false,
                Control_Type__c =
                    'None',
                Manual_Posting_Allowed__c =
                    true
            );

        insert account;
        return account;
    }

    private static Journal_Entry__c makeDraftJournal(
        Id companyId,
        Id periodId,
        Date accountingDate,
        String entryType,
        String descriptionValue
    ) {
        Journal_Entry__c journal =
            new Journal_Entry__c(
                Company__c =
                    companyId,
                Accounting_Period__c =
                    periodId,
                Accounting_Date__c =
                    accountingDate,
                Entry_Type__c =
                    entryType,
                Status__c =
                    'Draft',
                Description__c =
                    descriptionValue,
                Version__c =
                    1
            );

        insert journal;
        return journal;
    }

    private static void insertLines(
        Id journalId,
        List<LineSeed> seeds
    ) {
        List<Journal_Entry_Line__c> lines =
            new List<Journal_Entry_Line__c>();

        Integer lineNumber =
            1;

        for (LineSeed seed : seeds) {
            lines.add(
                new Journal_Entry_Line__c(
                    Journal_Entry__c =
                        journalId,
                    GL_Account__c =
                        seed.accountId,
                    Line_Number__c =
                        lineNumber,
                    Debit_Base__c =
                        seed.debit,
                    Credit_Base__c =
                        seed.credit,
                    Functional_Currency__c =
                        'BDT',
                    Explanation__c =
                        'Reporting test line'
                )
            );

            lineNumber++;
        }

        insert lines;
    }

    private static void postJournal(
        User userRecord,
        Journal_Entry__c journal,
        String suffixValue
    ) {
        System.runAs(userRecord) {
            SABPostingService.postDraftJournal(
                postingRequest(
                    journal,
                    suffixValue
                )
            );
        }
    }

    private static SABPostingService.PostingRequest postingRequest(
        Journal_Entry__c journal,
        String suffixValue
    ) {
        SABAccountingEventService.ReservationRequest eventRequest =
            new SABAccountingEventService.ReservationRequest();

        eventRequest.companyId =
            journal.Company__c;
        eventRequest.adapterKey =
            'MANUAL_JOURNAL';
        eventRequest.requestKey =
            'REQ-RPT-' + suffixValue;
        eventRequest.eventKey =
            'EVENT-RPT-' + suffixValue;
        eventRequest.eventType =
            journal.Entry_Type__c == 'Opening'
                ? 'Opening Balance'
                : 'Manual Journal';
        eventRequest.sourceBusinessKey =
            'POST-RPT-' + suffixValue;
        eventRequest.sourceRecordId =
            String.valueOf(
                journal.Id
            );
        eventRequest.sourceType =
            'Journal_Entry__c';
        eventRequest.sourceVersion =
            1;

        SABPostingService.PostingRequest request =
            new SABPostingService.PostingRequest();

        request.journalEntryId =
            journal.Id;
        request.postingKey =
            'POST-RPT-' + suffixValue;
        request.eventRequest =
            eventRequest;

        return request;
    }
}
