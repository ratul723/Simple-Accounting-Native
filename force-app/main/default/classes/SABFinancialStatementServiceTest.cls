@IsTest
private class SABFinancialStatementServiceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String POST_PERMISSION_SET =
        'SAB_Post_Journal_Action';

    @TestSetup
    static void setupFixture() {
        Profile profileRecord = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String seed = String.valueOf(DateTime.now().getTime());

        User testUser = new User(
            Alias = 'sabpl',
            Email = 'sabpl.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Profit Loss User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profileRecord.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = 'sabpl.' + seed + '@example.test'
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

        System.assertEquals(2, permissionSetIds.size());

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId =
                    permissionSetIds.get(ADMIN_PERMISSION_SET)
            ),
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId =
                    permissionSetIds.get(POST_PERMISSION_SET)
            )
        };

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c = 'P&L Fixture',
                    Company_Key__c = 'PL',
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
                Grant_Key__c = 'PL-GRANT',
                Is_Active__c = true,
                Role__c = 'Finance Manager'
            );

            Accounting_Period__c period =
                new Accounting_Period__c(
                    Name = 'January 2026',
                    Company__c = company.Id,
                    Company_Period_Key__c = 'CP-PL',
                    Period_Key__c = 'P-PL',
                    Start_Date__c = Date.newInstance(2026, 1, 1),
                    End_Date__c = Date.newInstance(2026, 1, 31),
                    Fiscal_Year__c = 2026,
                    Fiscal_Quarter__c = 1,
                    Period_Number__c = 1,
                    Status__c = 'Open'
                );

            insert period;

            GL_Account__c cash =
                makeAccount(
                    company.Id,
                    '1000',
                    'Cash',
                    'Asset',
                    'Debit'
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
                new Report_Definition__c(
                    Name = 'Default Profit and Loss',
                    Company__c = company.Id,
                    Definition_Key__c = 'PL|DEFAULT|V1',
                    Effective_From__c =
                        Date.newInstance(2026, 1, 1),
                    Report_Type__c = 'P&L',
                    Status__c = 'Active',
                    Version__c = 1
                );

            insert definition;

            insert new List<Report_Mapping__c>{
                new Report_Mapping__c(
                    Report_Definition__c = definition.Id,
                    GL_Account__c = revenue.Id,
                    Row_Key__c = 'SERVICE_REVENUE',
                    Group_Key__c = 'REVENUE',
                    Sign_Multiplier__c = -1,
                    Display_Order__c = 100,
                    Effective_From__c =
                        Date.newInstance(2026, 1, 1)
                ),
                new Report_Mapping__c(
                    Report_Definition__c = definition.Id,
                    GL_Account__c = expense.Id,
                    Row_Key__c = 'OFFICE_EXPENSE',
                    Group_Key__c = 'OPERATING_EXPENSES',
                    Sign_Multiplier__c = 1,
                    Display_Order__c = 200,
                    Effective_From__c =
                        Date.newInstance(2026, 1, 1)
                )
            };

            Journal_Entry__c journal =
                new Journal_Entry__c(
                    Company__c = company.Id,
                    Accounting_Period__c = period.Id,
                    Accounting_Date__c =
                        Date.newInstance(2026, 1, 15),
                    Entry_Type__c = 'Manual',
                    Status__c = 'Draft',
                    Description__c = 'P&L fixture',
                    Version__c = 1
                );

            insert journal;

            insert new List<Journal_Entry_Line__c>{
                new Journal_Entry_Line__c(
                    Journal_Entry__c = journal.Id,
                    GL_Account__c = cash.Id,
                    Line_Number__c = 1,
                    Debit_Base__c = 700,
                    Credit_Base__c = 0,
                    Functional_Currency__c = 'BDT'
                ),
                new Journal_Entry_Line__c(
                    Journal_Entry__c = journal.Id,
                    GL_Account__c = expense.Id,
                    Line_Number__c = 2,
                    Debit_Base__c = 300,
                    Credit_Base__c = 0,
                    Functional_Currency__c = 'BDT',
                    Explanation__c = 'Office cost'
                ),
                new Journal_Entry_Line__c(
                    Journal_Entry__c = journal.Id,
                    GL_Account__c = revenue.Id,
                    Line_Number__c = 3,
                    Debit_Base__c = 0,
                    Credit_Base__c = 1000,
                    Functional_Currency__c = 'BDT',
                    Explanation__c = 'Service revenue'
                )
            };

            SABPostingService.postDraftJournal(
                postingRequest(journal, company.Id)
            );
        }
    }

    @IsTest
    static void profitLossCalculatesRevenueExpenseAndNet() {
        User testUser = getUser();
        Accounting_Company__c company = getCompany();
        Report_Definition__c definition =
            getDefinition(company.Id);

        SABFinancialStatementService.ProfitLossResult result;

        System.runAs(testUser) {
            SABFinancialStatementService.ProfitLossRequest request =
                new SABFinancialStatementService.ProfitLossRequest();

            request.companyId = company.Id;
            request.reportDefinitionId = definition.Id;
            request.fromDate = Date.newInstance(2026, 1, 1);
            request.toDate = Date.newInstance(2026, 1, 31);

            Test.startTest();

            result =
                SABFinancialStatementService.getProfitLoss(
                    request
                );

            Test.stopTest();
        }

        System.assertEquals(
            Decimal.valueOf('1000'),
            result.currentRevenue
        );
        System.assertEquals(
            Decimal.valueOf('300'),
            result.currentExpense
        );
        System.assertEquals(
            Decimal.valueOf('700'),
            result.currentNetProfitLoss
        );
        System.assertEquals(2, result.currentLineCount);
        System.assertEquals(2, result.groups.size());
    }

    @IsTest
    static void revenueRowDrilldownUsesPresentationSign() {
        User testUser = getUser();
        Accounting_Company__c company = getCompany();
        Report_Definition__c definition =
            getDefinition(company.Id);

        List<SABFinancialStatementService.DrilldownLine> lines;

        System.runAs(testUser) {
            SABFinancialStatementService.ProfitLossRequest request =
                new SABFinancialStatementService.ProfitLossRequest();

            request.companyId = company.Id;
            request.reportDefinitionId = definition.Id;
            request.fromDate = Date.newInstance(2026, 1, 1);
            request.toDate = Date.newInstance(2026, 1, 31);

            Test.startTest();

            lines =
                SABFinancialStatementService.getProfitLossRowDrilldown(
                    request,
                    'SERVICE_REVENUE',
                    false
                );

            Test.stopTest();
        }

        System.assertEquals(1, lines.size());
        System.assertEquals('Revenue', lines[0].accountType);
        System.assertEquals(
            Decimal.valueOf('1000'),
            lines[0].presentedAmount
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
        eventRequest.requestKey = 'REQ-G2C';
        eventRequest.eventKey = 'EVENT-G2C';
        eventRequest.eventType = 'Manual Journal';
        eventRequest.sourceBusinessKey = 'POST-G2C';
        eventRequest.sourceRecordId =
            String.valueOf(journal.Id);
        eventRequest.sourceType = 'Journal_Entry__c';
        eventRequest.sourceVersion = 1;

        SABPostingService.PostingRequest request =
            new SABPostingService.PostingRequest();

        request.journalEntryId = journal.Id;
        request.postingKey = 'POST-G2C';
        request.eventRequest = eventRequest;

        return request;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB Profit Loss User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getCompany() {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c = 'PL'
            LIMIT 1
        ];
    }

    private static Report_Definition__c getDefinition(
        Id companyId
    ) {
        return [
            SELECT Id
            FROM Report_Definition__c
            WHERE Company__c = :companyId
              AND Definition_Key__c = 'PL|DEFAULT|V1'
            LIMIT 1
        ];
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
                    String.valueOf(companyId) + '-' + code,
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
}
