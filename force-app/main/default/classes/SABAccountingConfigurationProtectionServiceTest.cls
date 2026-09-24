@IsTest
private class SABAccountingConfigurationProtectionServiceTest {

    private class Fixture {
        Accounting_Company__c company;
        Accounting_Period__c period;
        GL_Account__c account;
        GL_Account__c offsetAccount;
        Journal_Entry__c journal;
    }

    @IsTest
    static void unusedConfigurationRemainsEditable() {
        Accounting_Company__c company = makeCompany('S51');
        Accounting_Period__c period = makePeriod(company.Id, 'S51');
        GL_Account__c account = makeAccount(company.Id, '5101', 'Asset', 'Debit');

        company.Functional_Currency__c = 'USD';
        update company;

        account.Account_Type__c = 'Expense';
        update account;

        period.Start_Date__c = Date.newInstance(2026, 8, 31);
        update period;

        System.assertEquals(
            'USD',
            [SELECT Functional_Currency__c
             FROM Accounting_Company__c
             WHERE Id = :company.Id].Functional_Currency__c
        );
    }

    @IsTest
    static void postedHistoryFreezesCompanyGLAndPeriodMeaning() {
        Fixture fixture = makePostedFixture('S52');

        Accounting_Company__c company = [
            SELECT Id, Functional_Currency__c
            FROM Accounting_Company__c
            WHERE Id = :fixture.company.Id
        ];
        company.Functional_Currency__c = 'USD';
        System.assertEquals(
            false,
            Database.update(company, false).isSuccess()
        );

        GL_Account__c account = [
            SELECT Id, Account_Type__c
            FROM GL_Account__c
            WHERE Id = :fixture.account.Id
        ];
        account.Account_Type__c = 'Expense';
        System.assertEquals(
            false,
            Database.update(account, false).isSuccess()
        );

        Accounting_Period__c period = [
            SELECT Id, Start_Date__c
            FROM Accounting_Period__c
            WHERE Id = :fixture.period.Id
        ];
        period.Start_Date__c = Date.newInstance(2026, 8, 31);
        System.assertEquals(
            false,
            Database.update(period, false).isSuccess()
        );
    }

    @IsTest
    static void prospectiveOperationalFlagsRemainEditable() {
        Fixture fixture = makePostedFixture('S53');

        Accounting_Company__c company = [
            SELECT Id, Is_Active__c
            FROM Accounting_Company__c
            WHERE Id = :fixture.company.Id
        ];
        company.Is_Active__c = false;
        update company;

        GL_Account__c account = [
            SELECT Id, Is_Active__c, Manual_Posting_Allowed__c
            FROM GL_Account__c
            WHERE Id = :fixture.account.Id
        ];
        account.Is_Active__c = false;
        account.Manual_Posting_Allowed__c = false;
        update account;

        System.assertEquals(
            false,
            [SELECT Is_Active__c
             FROM Accounting_Company__c
             WHERE Id = :fixture.company.Id].Is_Active__c
        );
    }

    @IsTest
    static void directPeriodStateChangeIsBlocked() {
        Accounting_Company__c company = makeCompany('S54');
        Accounting_Period__c period = makePeriod(company.Id, 'S54');

        period.Status__c = 'Closed';

        Database.SaveResult result =
            Database.update(period, false);

        System.assertEquals(false, result.isSuccess());
        System.assert(
            result.getErrors()[0].getMessage().contains('SABPeriodService')
        );
    }

    @IsTest
    static void trustedPeriodTransitionContextCanChangeState() {
        Accounting_Company__c company = makeCompany('S55');
        Accounting_Period__c period = makePeriod(company.Id, 'S55');

        period.Status__c = 'Closed';
        period.Closed_By__c = UserInfo.getUserId();
        period.Closed_At__c = System.now();
        period.Close_Request_Key__c = 'CLOSE-S55';

        SABAccountingConfigurationMutationContext.beginPeriodTransition();
        try {
            update period;
        } finally {
            SABAccountingConfigurationMutationContext.endPeriodTransition();
        }

        System.assertEquals(
            'Closed',
            [SELECT Status__c
             FROM Accounting_Period__c
             WHERE Id = :period.Id].Status__c
        );
    }

    @IsTest
    static void usedConfigurationDeleteAttemptsFail() {
        Fixture fixture = makePostedFixture('S56');

        System.assertEquals(
            false,
            Database.delete(fixture.account, false).isSuccess()
        );
        System.assertEquals(
            false,
            Database.delete(fixture.period, false).isSuccess()
        );
        System.assertEquals(
            false,
            Database.delete(fixture.company, false).isSuccess()
        );
    }

    private static Fixture makePostedFixture(String keyValue) {
        Fixture fixture = new Fixture();

        fixture.company = makeCompany(keyValue);
        fixture.period = makePeriod(fixture.company.Id, keyValue);
        fixture.account = makeAccount(
            fixture.company.Id,
            '1' + keyValue.right(2) + '1',
            'Asset',
            'Debit'
        );
        fixture.offsetAccount = makeAccount(
            fixture.company.Id,
            '2' + keyValue.right(2) + '1',
            'Liability',
            'Credit'
        );

        fixture.journal = new Journal_Entry__c(
            Company__c = fixture.company.Id,
            Accounting_Period__c = fixture.period.Id,
            Accounting_Date__c = Date.newInstance(2026, 9, 15),
            Entry_Type__c = 'Manual',
            Status__c = 'Draft',
            Description__c = 'Step 5 configuration fixture',
            Version__c = 1
        );
        insert fixture.journal;

        insert new List<Journal_Entry_Line__c>{
            new Journal_Entry_Line__c(
                Journal_Entry__c = fixture.journal.Id,
                GL_Account__c = fixture.account.Id,
                Line_Number__c = 1,
                Debit_Base__c = 100,
                Credit_Base__c = 0,
                Functional_Currency__c = 'BDT'
            ),
            new Journal_Entry_Line__c(
                Journal_Entry__c = fixture.journal.Id,
                GL_Account__c = fixture.offsetAccount.Id,
                Line_Number__c = 2,
                Debit_Base__c = 0,
                Credit_Base__c = 100,
                Functional_Currency__c = 'BDT'
            )
        };

        fixture.journal.Status__c = 'Posted';
        fixture.journal.Posting_Key__c = 'POST-' + keyValue;
        fixture.journal.Posted_By__c = UserInfo.getUserId();
        fixture.journal.Posted_At__c = System.now();

        SABLedgerMutationContext.beginPosting();
        try {
            update fixture.journal;
        } finally {
            SABLedgerMutationContext.endPosting();
        }

        return fixture;
    }

    private static Accounting_Company__c makeCompany(String keyValue) {
        Accounting_Company__c company = new Accounting_Company__c(
            Name__c = 'Configuration ' + keyValue,
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
        Accounting_Period__c period = new Accounting_Period__c(
            Name = 'Period ' + suffixValue,
            Company__c = companyId,
            Company_Period_Key__c = 'CP-' + suffixValue,
            Period_Key__c = 'P-' + suffixValue,
            Start_Date__c = Date.newInstance(2026, 9, 1),
            End_Date__c = Date.newInstance(2026, 9, 30),
            Fiscal_Year__c = 2026,
            Fiscal_Quarter__c = 3,
            Period_Number__c = 9,
            Status__c = 'Open'
        );
        insert period;
        return period;
    }

    private static GL_Account__c makeAccount(
        Id companyId,
        String code,
        String accountType,
        String normalBalance
    ) {
        GL_Account__c account = new GL_Account__c(
            Name = 'Account ' + code,
            Company__c = companyId,
            Company_Account_Key__c = String.valueOf(companyId) + '-' + code,
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
