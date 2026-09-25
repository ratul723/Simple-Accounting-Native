@IsTest
private class SABBalanceSheetCloseRegressionTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String POST_PERMISSION_SET =
        'SAB_Post_Journal_Action';

    @TestSetup
    static void setupClosedYearFixture() {
        Profile profileRecord = [
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

        User testUser = new User(
            Alias = 'sabbscl',
            Email =
                'sabbscl.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB BS Close User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profileRecord.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username =
                'sabbscl.' + seed + '@example.test'
        );

        insert testUser;

        Map<String, Id> permissionSetIds =
            new Map<String, Id>();

        for (PermissionSet permissionSetRecord : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN (
                :ADMIN_PERMISSION_SET,
                :POST_PERMISSION_SET
            )
        ]) {
            permissionSetIds.put(
                permissionSetRecord.Name,
                permissionSetRecord.Id
            );
        }

        System.assertEquals(
            2,
            permissionSetIds.size()
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        ADMIN_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        POST_PERMISSION_SET
                    )
            )
        };

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c =
                        'Balance Sheet Closed Year',
                    Company_Key__c = 'BSC',
                    Country_Code__c = 'BD',
                    Functional_Currency__c = 'BDT',
                    Fiscal_Calendar_Type__c = 'Calendar',
                    Fiscal_Year_Start_Month__c = 1,
                    Setup_Status__c = 'Active',
                    Is_Active__c = true
                );

            insert company;

            insert new Company_User_Access__c(
                Company__c = company.Id,
                User__c = testUser.Id,
                Effective_From__c = Date.today(),
                Grant_Key__c = 'BSC-GRANT',
                Is_Active__c = true,
                Role__c = 'Finance Manager'
            );

            Accounting_Period__c period =
                new Accounting_Period__c(
                    Name = 'January 2026',
                    Company__c = company.Id,
                    Company_Period_Key__c = 'CP-BSC',
                    Period_Key__c = 'P-BSC',
                    Start_Date__c =
                        Date.newInstance(2026, 1, 1),
                    End_Date__c =
                        Date.newInstance(2026, 1, 31),
                    Fiscal_Year__c = 2026,
                    Fiscal_Quarter__c = 1,
                    Period_Number__c = 1,
                    Status__c = 'Open'
                );

            insert period;

            GL_Account__c cash =
                account(
                    company.Id,
                    '1000',
                    'Cash',
                    'Asset',
                    'Debit'
                );

            GL_Account__c liability =
                account(
                    company.Id,
                    '2000',
                    'AP',
                    'Liability',
                    'Credit'
                );

            GL_Account__c capital =
                account(
                    company.Id,
                    '3000',
                    'Capital',
                    'Equity',
                    'Credit'
                );

            GL_Account__c retained =
                account(
                    company.Id,
                    '3100',
                    'Retained Earnings',
                    'Equity',
                    'Credit'
                );

            GL_Account__c revenue =
                account(
                    company.Id,
                    '4000',
                    'Revenue',
                    'Revenue',
                    'Credit'
                );

            GL_Account__c expense =
                account(
                    company.Id,
                    '6000',
                    'Expense',
                    'Expense',
                    'Debit'
                );

            Report_Definition__c definition =
                new Report_Definition__c(
                    Name = 'Closed Balance Sheet',
                    Company__c = company.Id,
                    Definition_Key__c =
                        'BS|CLOSED|V1',
                    Effective_From__c =
                        Date.newInstance(2026, 1, 1),
                    Report_Type__c =
                        'Balance Sheet',
                    Status__c = 'Active',
                    Version__c = 1
                );

            insert definition;

            insert new List<Report_Mapping__c>{
                mapRow(
                    definition.Id,
                    cash.Id,
                    'CASH',
                    'ASSETS',
                    1,
                    100
                ),
                mapRow(
                    definition.Id,
                    liability.Id,
                    'AP',
                    'LIABILITIES',
                    -1,
                    200
                ),
                mapRow(
                    definition.Id,
                    capital.Id,
                    'CAPITAL',
                    'EQUITY',
                    -1,
                    300
                ),
                mapRow(
                    definition.Id,
                    retained.Id,
                    'RETAINED_EARNINGS',
                    'EQUITY',
                    -1,
                    310
                )
            };

            Journal_Entry__c journal =
                new Journal_Entry__c(
                    Company__c = company.Id,
                    Accounting_Period__c = period.Id,
                    Accounting_Date__c =
                        Date.newInstance(2026, 1, 31),
                    Entry_Type__c = 'Manual',
                    Status__c = 'Draft',
                    Description__c =
                        'Operational activity plus closing transfer',
                    Version__c = 1
                );

            insert journal;

            insert new List<Journal_Entry_Line__c>{
                journalLine(
                    journal.Id,
                    cash.Id,
                    1,
                    1300,
                    0
                ),
                journalLine(
                    journal.Id,
                    expense.Id,
                    2,
                    200,
                    0
                ),
                journalLine(
                    journal.Id,
                    liability.Id,
                    3,
                    0,
                    500
                ),
                journalLine(
                    journal.Id,
                    capital.Id,
                    4,
                    0,
                    300
                ),
                journalLine(
                    journal.Id,
                    revenue.Id,
                    5,
                    0,
                    700
                ),
                journalLine(
                    journal.Id,
                    revenue.Id,
                    6,
                    700,
                    0
                ),
                journalLine(
                    journal.Id,
                    expense.Id,
                    7,
                    0,
                    200
                ),
                journalLine(
                    journal.Id,
                    retained.Id,
                    8,
                    0,
                    500
                )
            };

            SABPostingService.postDraftJournal(
                postingRequest(
                    journal,
                    company.Id
                )
            );
        }
    }

    @IsTest
    static void closedProfitMovesToEquityWithoutDoubleCounting() {
        User testUser = [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB BS Close User'
            LIMIT 1
        ];

        Accounting_Company__c company = [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c = 'BSC'
            LIMIT 1
        ];

        Report_Definition__c definition = [
            SELECT Id
            FROM Report_Definition__c
            WHERE Company__c = :company.Id
              AND Definition_Key__c =
                  'BS|CLOSED|V1'
            LIMIT 1
        ];

        SABFinancialStatementService.BalanceSheetResult result;

        System.runAs(testUser) {
            SABFinancialStatementService.BalanceSheetRequest request =
                new SABFinancialStatementService.BalanceSheetRequest();

            request.companyId = company.Id;
            request.reportDefinitionId = definition.Id;
            request.asOfDate =
                Date.newInstance(2026, 1, 31);

            Test.startTest();

            result =
                SABFinancialStatementService.getBalanceSheet(
                    request
                );

            Test.stopTest();
        }

        System.assertEquals(
            Decimal.valueOf('1300'),
            result.currentAssets
        );
        System.assertEquals(
            Decimal.valueOf('500'),
            result.currentLiabilities
        );
        System.assertEquals(
            Decimal.valueOf('800'),
            result.currentEquityBeforeEarnings
        );
        System.assertEquals(
            Decimal.valueOf('0'),
            result.currentYearEarnings
        );
        System.assertEquals(
            Decimal.valueOf('800'),
            result.currentTotalEquity
        );
        System.assertEquals(
            true,
            result.currentBalanced
        );

        Decimal retainedAmount =
            Decimal.valueOf('0');

        for (
            SABFinancialStatementService.BalanceSheetGroup
                statementGroup
            : result.groups
        ) {
            for (
                SABFinancialStatementService.BalanceSheetRow row
                : statementGroup.rows
            ) {
                if (
                    row.rowKey
                    == 'RETAINED_EARNINGS'
                ) {
                    retainedAmount =
                        row.currentAmount;
                }
            }
        }

        System.assertEquals(
            Decimal.valueOf('500'),
            retainedAmount
        );
    }

    private static GL_Account__c account(
        Id companyId,
        String code,
        String displayName,
        String accountType,
        String normalBalance
    ) {
        GL_Account__c accountRecord =
            new GL_Account__c(
                Name = displayName,
                Company__c = companyId,
                Company_Account_Key__c =
                    String.valueOf(companyId)
                    + '-'
                    + code,
                Account_Code__c = code,
                Account_Type__c = accountType,
                Normal_Balance__c = normalBalance,
                Is_Active__c = true,
                Is_Control_Account__c = false,
                Control_Type__c = 'None',
                Manual_Posting_Allowed__c = true
            );

        insert accountRecord;
        return accountRecord;
    }

    private static Report_Mapping__c mapRow(
        Id definitionId,
        Id accountId,
        String rowKey,
        String groupKey,
        Decimal signMultiplier,
        Decimal displayOrder
    ) {
        return new Report_Mapping__c(
            Report_Definition__c = definitionId,
            GL_Account__c = accountId,
            Row_Key__c = rowKey,
            Group_Key__c = groupKey,
            Sign_Multiplier__c = signMultiplier,
            Display_Order__c = displayOrder,
            Effective_From__c =
                Date.newInstance(2026, 1, 1)
        );
    }

    private static Journal_Entry_Line__c journalLine(
        Id journalId,
        Id accountId,
        Decimal lineNumber,
        Decimal debit,
        Decimal credit
    ) {
        return new Journal_Entry_Line__c(
            Journal_Entry__c = journalId,
            GL_Account__c = accountId,
            Line_Number__c = lineNumber,
            Debit_Base__c = debit,
            Credit_Base__c = credit,
            Functional_Currency__c = 'BDT'
        );
    }

    private static SABPostingService.PostingRequest postingRequest(
        Journal_Entry__c journal,
        Id companyId
    ) {
        SABAccountingEventService.ReservationRequest eventRequest =
            new SABAccountingEventService.ReservationRequest();

        eventRequest.companyId = companyId;
        eventRequest.adapterKey = 'MANUAL_JOURNAL';
        eventRequest.requestKey =
            'REQ-G2D-CLOSE';
        eventRequest.eventKey =
            'EVENT-G2D-CLOSE';
        eventRequest.eventType =
            'Manual Journal';
        eventRequest.sourceBusinessKey =
            'POST-G2D-CLOSE';
        eventRequest.sourceRecordId =
            String.valueOf(journal.Id);
        eventRequest.sourceType =
            'Journal_Entry__c';
        eventRequest.sourceVersion = 1;

        SABPostingService.PostingRequest request =
            new SABPostingService.PostingRequest();

        request.journalEntryId = journal.Id;
        request.postingKey =
            'POST-G2D-CLOSE';
        request.eventRequest = eventRequest;

        return request;
    }
}
