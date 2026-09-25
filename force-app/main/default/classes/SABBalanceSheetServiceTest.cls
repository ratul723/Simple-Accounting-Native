@IsTest
private class SABBalanceSheetServiceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String POST_PERMISSION_SET =
        'SAB_Post_Journal_Action';

    @TestSetup
    static void setupOpenYearFixture() {
        User testUser = createUser();
        assignPermissionSets(testUser);

        System.runAs(testUser) {
            Accounting_Company__c company =
                makeCompany(
                    'BSO',
                    'Balance Sheet Open Year'
                );

            grant(company.Id, testUser.Id, 'BSO-GRANT');

            Accounting_Period__c period =
                makePeriod(company.Id, 'BSO');

            GL_Account__c cash =
                makeAccount(
                    company.Id,
                    '1000',
                    'Cash',
                    'Asset',
                    'Debit'
                );

            GL_Account__c liability =
                makeAccount(
                    company.Id,
                    '2000',
                    'Accounts Payable',
                    'Liability',
                    'Credit'
                );

            GL_Account__c capital =
                makeAccount(
                    company.Id,
                    '3000',
                    'Owner Capital',
                    'Equity',
                    'Credit'
                );

            GL_Account__c revenue =
                makeAccount(
                    company.Id,
                    '4000',
                    'Service Revenue',
                    'Revenue',
                    'Credit'
                );

            GL_Account__c expense =
                makeAccount(
                    company.Id,
                    '6000',
                    'Office Expense',
                    'Expense',
                    'Debit'
                );

            Report_Definition__c definition =
                makeDefinition(
                    company.Id,
                    'BS|OPEN|V1',
                    'Open Year Balance Sheet'
                );

            insert new List<Report_Mapping__c>{
                mapping(
                    definition.Id,
                    cash.Id,
                    'CASH',
                    'ASSETS',
                    1,
                    100
                ),
                mapping(
                    definition.Id,
                    liability.Id,
                    'ACCOUNTS_PAYABLE',
                    'LIABILITIES',
                    -1,
                    200
                ),
                mapping(
                    definition.Id,
                    capital.Id,
                    'OWNER_CAPITAL',
                    'EQUITY',
                    -1,
                    300
                )
            };

            Journal_Entry__c journal =
                makeDraftJournal(
                    company.Id,
                    period.Id,
                    'Open year balance sheet fixture'
                );

            insert new List<Journal_Entry_Line__c>{
                line(journal.Id, cash.Id, 1, 1300, 0),
                line(journal.Id, expense.Id, 2, 200, 0),
                line(journal.Id, liability.Id, 3, 0, 500),
                line(journal.Id, capital.Id, 4, 0, 300),
                line(journal.Id, revenue.Id, 5, 0, 700)
            };

            SABPostingService.postDraftJournal(
                postingRequest(
                    journal,
                    company.Id,
                    'OPEN'
                )
            );
        }
    }

    @IsTest
    static void openYearBalanceSheetIncludesCurrentYearEarningsOnce() {
        User testUser = getUser();
        Accounting_Company__c company =
            getCompany('BSO');

        Report_Definition__c definition =
            getDefinition(
                company.Id,
                'BS|OPEN|V1'
            );

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
            Decimal.valueOf('300'),
            result.currentEquityBeforeEarnings
        );
        System.assertEquals(
            Decimal.valueOf('500'),
            result.currentYearEarnings
        );
        System.assertEquals(
            Decimal.valueOf('800'),
            result.currentTotalEquity
        );
        System.assertEquals(
            Decimal.valueOf('1300'),
            result.currentLiabilitiesAndEquity
        );
        System.assertEquals(
            Decimal.valueOf('0'),
            result.currentEquationDifference
        );
        System.assertEquals(
            true,
            result.currentBalanced
        );

        Map<String, SABFinancialStatementService.BalanceSheetRow> rows =
            rowsByKey(result);

        System.assertEquals(
            Decimal.valueOf('1300'),
            rows.get('CASH').currentAmount
        );
        System.assertEquals(
            Decimal.valueOf('500'),
            rows.get('ACCOUNTS_PAYABLE').currentAmount
        );
        System.assertEquals(
            Decimal.valueOf('300'),
            rows.get('OWNER_CAPITAL').currentAmount
        );
        System.assertEquals(
            Decimal.valueOf('500'),
            rows.get('CURRENT_YEAR_EARNINGS').currentAmount
        );
        System.assertEquals(
            true,
            rows.get('CURRENT_YEAR_EARNINGS').syntheticCurrentYearEarnings
        );
    }

    @IsTest
    static void currentYearEarningsDrilldownShowsRevenueAndExpense() {
        User testUser = getUser();
        Accounting_Company__c company =
            getCompany('BSO');

        Report_Definition__c definition =
            getDefinition(
                company.Id,
                'BS|OPEN|V1'
            );

        List<SABFinancialStatementService.BalanceSheetDrilldownLine>
            lines;

        System.runAs(testUser) {
            SABFinancialStatementService.BalanceSheetRequest request =
                new SABFinancialStatementService.BalanceSheetRequest();

            request.companyId = company.Id;
            request.reportDefinitionId = definition.Id;
            request.asOfDate =
                Date.newInstance(2026, 1, 31);

            Test.startTest();

            lines =
                SABFinancialStatementService.getBalanceSheetRowDrilldown(
                        request,
                        'CURRENT_YEAR_EARNINGS',
                        false
                    );

            Test.stopTest();
        }

        System.assertEquals(2, lines.size());

        Decimal totalContribution =
            Decimal.valueOf('0');

        for (
            SABFinancialStatementService.BalanceSheetDrilldownLine
                sourceLine
            : lines
        ) {
            totalContribution +=
                sourceLine.presentedAmount;
        }

        System.assertEquals(
            Decimal.valueOf('500'),
            totalContribution
        );
    }

    @IsTest
    static void missingPermanentAccountMappingBlocksStatement() {
        User testUser = getUser();
        Accounting_Company__c company =
            getCompany('BSO');

        GL_Account__c cash = [
            SELECT Id
            FROM GL_Account__c
            WHERE Company__c = :company.Id
              AND Account_Code__c = '1000'
            LIMIT 1
        ];

        Report_Definition__c incomplete =
            makeDefinition(
                company.Id,
                'BS|INCOMPLETE|V1',
                'Incomplete Balance Sheet'
            );

        insert mapping(
            incomplete.Id,
            cash.Id,
            'CASH_ONLY',
            'ASSETS',
            1,
            100
        );

        Boolean thrown = false;

        System.runAs(testUser) {
            SABFinancialStatementService.BalanceSheetRequest request =
                new SABFinancialStatementService.BalanceSheetRequest();

            request.companyId = company.Id;
            request.reportDefinitionId = incomplete.Id;
            request.asOfDate =
                Date.newInstance(2026, 1, 31);

            Test.startTest();

            try {
                SABFinancialStatementService.getBalanceSheet(
                    request
                );
            } catch (
                SABFinancialStatementService.StatementException ex
            ) {
                thrown = true;
            }

            Test.stopTest();
        }

        System.assertEquals(
            true,
            thrown
        );
    }

    private static User createUser() {
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
            Alias = 'sabbs',
            Email =
                'sabbs.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Balance Sheet User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profileRecord.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username =
                'sabbs.' + seed + '@example.test'
        );

        insert testUser;
        return testUser;
    }

    private static void assignPermissionSets(User testUser) {
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

    private static void grant(
        Id companyId,
        Id userId,
        String grantKey
    ) {
        insert new Company_User_Access__c(
            Company__c = companyId,
            User__c = userId,
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
                Name = 'January 2026',
                Company__c = companyId,
                Company_Period_Key__c =
                    'CP-' + suffixValue,
                Period_Key__c =
                    'P-' + suffixValue,
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
        return period;
    }

    private static GL_Account__c makeAccount(
        Id companyId,
        String code,
        String displayName,
        String accountType,
        String normalBalance
    ) {
        GL_Account__c account =
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

        insert account;
        return account;
    }

    private static Report_Definition__c makeDefinition(
        Id companyId,
        String definitionKey,
        String displayName
    ) {
        Report_Definition__c definition =
            new Report_Definition__c(
                Name = displayName,
                Company__c = companyId,
                Definition_Key__c = definitionKey,
                Effective_From__c =
                    Date.newInstance(2026, 1, 1),
                Report_Type__c = 'Balance Sheet',
                Status__c = 'Active',
                Version__c = 1
            );

        insert definition;
        return definition;
    }

    private static Report_Mapping__c mapping(
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

    private static Journal_Entry__c makeDraftJournal(
        Id companyId,
        Id periodId,
        String descriptionValue
    ) {
        Journal_Entry__c journal =
            new Journal_Entry__c(
                Company__c = companyId,
                Accounting_Period__c = periodId,
                Accounting_Date__c =
                    Date.newInstance(2026, 1, 15),
                Entry_Type__c = 'Manual',
                Status__c = 'Draft',
                Description__c = descriptionValue,
                Version__c = 1
            );

        insert journal;
        return journal;
    }

    private static Journal_Entry_Line__c line(
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
        Id companyId,
        String suffixValue
    ) {
        SABAccountingEventService.ReservationRequest eventRequest =
            new SABAccountingEventService.ReservationRequest();

        eventRequest.companyId = companyId;
        eventRequest.adapterKey = 'MANUAL_JOURNAL';
        eventRequest.requestKey =
            'REQ-G2D-' + suffixValue;
        eventRequest.eventKey =
            'EVENT-G2D-' + suffixValue;
        eventRequest.eventType = 'Manual Journal';
        eventRequest.sourceBusinessKey =
            'POST-G2D-' + suffixValue;
        eventRequest.sourceRecordId =
            String.valueOf(journal.Id);
        eventRequest.sourceType = 'Journal_Entry__c';
        eventRequest.sourceVersion = 1;

        SABPostingService.PostingRequest request =
            new SABPostingService.PostingRequest();

        request.journalEntryId = journal.Id;
        request.postingKey =
            'POST-G2D-' + suffixValue;
        request.eventRequest = eventRequest;

        return request;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB Balance Sheet User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getCompany(
        String companyKey
    ) {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c = :companyKey
            LIMIT 1
        ];
    }

    private static Report_Definition__c getDefinition(
        Id companyId,
        String definitionKey
    ) {
        return [
            SELECT Id
            FROM Report_Definition__c
            WHERE Company__c = :companyId
              AND Definition_Key__c = :definitionKey
            LIMIT 1
        ];
    }

    private static Map<String, SABFinancialStatementService.BalanceSheetRow>
        rowsByKey(
            SABFinancialStatementService.BalanceSheetResult result
        ) {
        Map<String, SABFinancialStatementService.BalanceSheetRow>
            rows =
                new Map<String, SABFinancialStatementService.BalanceSheetRow>();

        for (
            SABFinancialStatementService.BalanceSheetGroup
                statementGroup
            : result.groups
        ) {
            for (
                SABFinancialStatementService.BalanceSheetRow row
                : statementGroup.rows
            ) {
                rows.put(row.rowKey, row);
            }
        }

        return rows;
    }
}
