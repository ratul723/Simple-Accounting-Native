@IsTest
private class SABGeneralLedgerServiceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String POST_PERMISSION_SET =
        'SAB_Post_Journal_Action';

    @TestSetup
    static void setupPostedLedgerFixture() {
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
            Alias = 'sabgl',
            Email =
                'sabgl.' + seed + '@example.test',
            EmailEncodingKey =
                'UTF-8',
            LastName =
                'SAB General Ledger User',
            LanguageLocaleKey =
                'en_US',
            LocaleSidKey =
                'en_US',
            ProfileId =
                p.Id,
            TimeZoneSidKey =
                'Asia/Dhaka',
            Username =
                'sabgl.' + seed + '@example.test'
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
                :POST_PERMISSION_SET
            )
        ]) {
            permissionSetIds.put(
                ps.Name,
                ps.Id
            );
        }

        System.assertEquals(
            2,
            permissionSetIds.size()
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
            )
        };

        System.runAs(u) {
            Accounting_Company__c company =
                makeCompany(
                    'GL',
                    'General Ledger Fixture'
                );

            grant(
                company.Id,
                u.Id,
                'GL-GRANT'
            );

            Accounting_Period__c period =
                makePeriod(
                    company.Id,
                    'GL-P1'
                );

            GL_Account__c cash =
                makeAccount(
                    company.Id,
                    '1000',
                    'Cash',
                    'Asset',
                    'Debit'
                );

            GL_Account__c expense =
                makeAccount(
                    company.Id,
                    '6000',
                    'Office Expense',
                    'Expense',
                    'Debit'
                );

            Journal_Entry__c journal =
                new Journal_Entry__c(
                    Company__c =
                        company.Id,
                    Accounting_Period__c =
                        period.Id,
                    Accounting_Date__c =
                        Date.newInstance(
                            2026,
                            1,
                            10
                        ),
                    Entry_Type__c =
                        'Manual',
                    Status__c =
                        'Draft',
                    Description__c =
                        'G2B running balance fixture',
                    Version__c =
                        1
                );

            insert journal;

            insert new List<Journal_Entry_Line__c>{
                new Journal_Entry_Line__c(
                    Journal_Entry__c =
                        journal.Id,
                    GL_Account__c =
                        expense.Id,
                    Line_Number__c =
                        1,
                    Debit_Base__c =
                        100,
                    Credit_Base__c =
                        0,
                    Functional_Currency__c =
                        'BDT',
                    Explanation__c =
                        'Expense part 1'
                ),
                new Journal_Entry_Line__c(
                    Journal_Entry__c =
                        journal.Id,
                    GL_Account__c =
                        expense.Id,
                    Line_Number__c =
                        2,
                    Debit_Base__c =
                        50,
                    Credit_Base__c =
                        0,
                    Functional_Currency__c =
                        'BDT',
                    Explanation__c =
                        'Expense part 2'
                ),
                new Journal_Entry_Line__c(
                    Journal_Entry__c =
                        journal.Id,
                    GL_Account__c =
                        cash.Id,
                    Line_Number__c =
                        3,
                    Debit_Base__c =
                        0,
                    Credit_Base__c =
                        150,
                    Functional_Currency__c =
                        'BDT',
                    Explanation__c =
                        'Cash offset'
                )
            };

            SABPostingService.postDraftJournal(
                postingRequest(
                    journal
                )
            );
        }
    }

    @IsTest
    static void movementAndRunningBalanceAreCorrect() {
        User u =
            getUser();

        Accounting_Company__c company =
            getFixtureCompany();

        GL_Account__c expense =
            getAccount(
                company.Id,
                '6000'
            );

        SABLedgerReportService.GeneralLedgerResult result;

        System.runAs(u) {
            SABLedgerReportService.GeneralLedgerRequest request =
                new SABLedgerReportService.GeneralLedgerRequest();

            request.companyId =
                company.Id;
            request.glAccountId =
                expense.Id;
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

            Test.startTest();

            result =
                SABLedgerReportService.getGeneralLedger(
                    request
                );

            Test.stopTest();
        }

        System.assertEquals(
            false,
            result.fullLedgerScope
        );

        System.assertEquals(
            1,
            result.accounts.size()
        );

        SABLedgerReportService.GeneralLedgerAccount account =
            result.accounts[0];

        System.assertEquals(
            Decimal.valueOf('0'),
            account.openingDebit
        );

        System.assertEquals(
            Decimal.valueOf('150'),
            account.movementDebit
        );

        System.assertEquals(
            Decimal.valueOf('150'),
            account.closingDebit
        );

        System.assertEquals(
            2,
            account.lines.size()
        );

        System.assertEquals(
            Decimal.valueOf('100'),
            account.lines[0].runningDebit
        );

        System.assertEquals(
            Decimal.valueOf('150'),
            account.lines[1].runningDebit
        );
    }

    @IsTest
    static void balanceBeforeRangeBecomesOpeningBalance() {
        User u =
            getUser();

        Accounting_Company__c company =
            getFixtureCompany();

        GL_Account__c expense =
            getAccount(
                company.Id,
                '6000'
            );

        SABLedgerReportService.GeneralLedgerResult result;

        System.runAs(u) {
            SABLedgerReportService.GeneralLedgerRequest request =
                new SABLedgerReportService.GeneralLedgerRequest();

            request.companyId =
                company.Id;
            request.glAccountId =
                expense.Id;
            request.fromDate =
                Date.newInstance(
                    2026,
                    1,
                    15
                );
            request.toDate =
                Date.newInstance(
                    2026,
                    1,
                    31
                );

            Test.startTest();

            result =
                SABLedgerReportService.getGeneralLedger(
                    request
                );

            Test.stopTest();
        }

        SABLedgerReportService.GeneralLedgerAccount account =
            result.accounts[0];

        System.assertEquals(
            Decimal.valueOf('150'),
            account.openingDebit
        );

        System.assertEquals(
            Decimal.valueOf('0'),
            account.movementDebit
        );

        System.assertEquals(
            Decimal.valueOf('150'),
            account.closingDebit
        );

        System.assertEquals(
            0,
            account.lines.size()
        );
    }

    @IsTest
    static void creditBalanceIsPresentedOnCreditSide() {
        User u =
            getUser();

        Accounting_Company__c company =
            getFixtureCompany();

        GL_Account__c cash =
            getAccount(
                company.Id,
                '1000'
            );

        SABLedgerReportService.GeneralLedgerResult result;

        System.runAs(u) {
            SABLedgerReportService.GeneralLedgerRequest request =
                new SABLedgerReportService.GeneralLedgerRequest();

            request.companyId =
                company.Id;
            request.glAccountId =
                cash.Id;
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

            Test.startTest();

            result =
                SABLedgerReportService.getGeneralLedger(
                    request
                );

            Test.stopTest();
        }

        SABLedgerReportService.GeneralLedgerAccount account =
            result.accounts[0];

        System.assertEquals(
            Decimal.valueOf('150'),
            account.movementCredit
        );

        System.assertEquals(
            Decimal.valueOf('150'),
            account.closingCredit
        );

        System.assertEquals(
            Decimal.valueOf('150'),
            account.lines[0].runningCredit
        );

        System.assertEquals(
            Decimal.valueOf('0'),
            account.lines[0].runningDebit
        );
    }

    @IsTest
    static void draftLinesAreExcluded() {
        User u =
            getUser();

        Accounting_Company__c company =
            getFixtureCompany();

        Accounting_Period__c period = [
            SELECT Id
            FROM Accounting_Period__c
            WHERE Company__c = :company.Id
            LIMIT 1
        ];

        GL_Account__c cash =
            getAccount(
                company.Id,
                '1000'
            );

        GL_Account__c expense =
            getAccount(
                company.Id,
                '6000'
            );

        Journal_Entry__c draft =
            new Journal_Entry__c(
                Company__c =
                    company.Id,
                Accounting_Period__c =
                    period.Id,
                Accounting_Date__c =
                    Date.newInstance(
                        2026,
                        1,
                        20
                    ),
                Entry_Type__c =
                    'Manual',
                Status__c =
                    'Draft',
                Description__c =
                    'Excluded draft',
                Version__c =
                    1
            );

        insert draft;

        insert new List<Journal_Entry_Line__c>{
            new Journal_Entry_Line__c(
                Journal_Entry__c =
                    draft.Id,
                GL_Account__c =
                    expense.Id,
                Line_Number__c =
                    1,
                Debit_Base__c =
                    999,
                Credit_Base__c =
                    0,
                Functional_Currency__c =
                    'BDT'
            ),
            new Journal_Entry_Line__c(
                Journal_Entry__c =
                    draft.Id,
                GL_Account__c =
                    cash.Id,
                Line_Number__c =
                    2,
                Debit_Base__c =
                    0,
                Credit_Base__c =
                    999,
                Functional_Currency__c =
                    'BDT'
            )
        };

        SABLedgerReportService.GeneralLedgerResult result;

        System.runAs(u) {
            SABLedgerReportService.GeneralLedgerRequest request =
                new SABLedgerReportService.GeneralLedgerRequest();

            request.companyId =
                company.Id;
            request.glAccountId =
                expense.Id;
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

            Test.startTest();

            result =
                SABLedgerReportService.getGeneralLedger(
                    request
                );

            Test.stopTest();
        }

        System.assertEquals(
            Decimal.valueOf('150'),
            result.accounts[0].movementDebit
        );

        System.assertEquals(
            2,
            result.accounts[0].lines.size()
        );
    }

    @IsTest
    static void allAccountScopeBalances() {
        User u =
            getUser();

        Accounting_Company__c company =
            getFixtureCompany();

        SABLedgerReportService.GeneralLedgerResult result;

        System.runAs(u) {
            SABLedgerReportService.GeneralLedgerRequest request =
                new SABLedgerReportService.GeneralLedgerRequest();

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

            Test.startTest();

            result =
                SABLedgerReportService.getGeneralLedger(
                    request
                );

            Test.stopTest();
        }

        System.assertEquals(
            true,
            result.fullLedgerScope
        );

        System.assertEquals(
            true,
            result.balanced
        );

        System.assertEquals(
            2,
            result.accountCount
        );

        System.assertEquals(
            3,
            result.totalMovementLineCount
        );

        System.assertEquals(
            Decimal.valueOf('150'),
            result.totalMovementDebit
        );

        System.assertEquals(
            Decimal.valueOf('150'),
            result.totalMovementCredit
        );

        System.assertEquals(
            Decimal.valueOf('150'),
            result.totalClosingDebit
        );

        System.assertEquals(
            Decimal.valueOf('150'),
            result.totalClosingCredit
        );
    }

    @IsTest
    static void unauthorizedCompanyIsRejected() {
        User u =
            getUser();

        Accounting_Company__c blocked =
            makeCompany(
                'GX',
                'Blocked GL Company'
            );

        Boolean thrown =
            false;

        System.runAs(u) {
            SABLedgerReportService.GeneralLedgerRequest request =
                new SABLedgerReportService.GeneralLedgerRequest();

            request.companyId =
                blocked.Id;
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

            Test.startTest();

            try {
                SABLedgerReportService.getGeneralLedger(
                    request
                );
            } catch (Exception ex) {
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

    private static SABPostingService.PostingRequest postingRequest(
        Journal_Entry__c journal
    ) {
        SABAccountingEventService.ReservationRequest eventRequest =
            new SABAccountingEventService.ReservationRequest();

        eventRequest.companyId =
            journal.Company__c;
        eventRequest.adapterKey =
            'MANUAL_JOURNAL';
        eventRequest.requestKey =
            'REQ-G2B';
        eventRequest.eventKey =
            'EVENT-G2B';
        eventRequest.eventType =
            'Manual Journal';
        eventRequest.sourceBusinessKey =
            'POST-G2B';
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
            'POST-G2B';
        request.eventRequest =
            eventRequest;

        return request;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                'SAB General Ledger User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getFixtureCompany() {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c =
                'GL'
            LIMIT 1
        ];
    }

    private static GL_Account__c getAccount(
        Id companyId,
        String accountCode
    ) {
        return [
            SELECT Id
            FROM GL_Account__c
            WHERE Company__c =
                :companyId
              AND Account_Code__c =
                :accountCode
            LIMIT 1
        ];
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
                    'January 2026',
                Company__c =
                    companyId,
                Company_Period_Key__c =
                    'CP-' + suffixValue,
                Period_Key__c =
                    'P-' + suffixValue,
                Start_Date__c =
                    Date.newInstance(
                        2026,
                        1,
                        1
                    ),
                End_Date__c =
                    Date.newInstance(
                        2026,
                        1,
                        31
                    ),
                Fiscal_Year__c =
                    2026,
                Fiscal_Quarter__c =
                    1,
                Period_Number__c =
                    1,
                Status__c =
                    'Open'
            );

        insert period;
        return period;
    }

    private static GL_Account__c makeAccount(
        Id companyId,
        String code,
        String displayName,
        String typeValue,
        String normalBalance
    ) {
        GL_Account__c account =
            new GL_Account__c(
                Name =
                    displayName,
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
}
