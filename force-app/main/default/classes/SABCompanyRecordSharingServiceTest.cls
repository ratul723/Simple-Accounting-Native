@IsTest
private class SABCompanyRecordSharingServiceTest {

    @TestSetup
    static void setupUser() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String uniqueValue =
            'sabrecordshare.'
            + String.valueOf(DateTime.now().getTime());

        insert new User(
            Alias = 'sabrec',
            Email = uniqueValue + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Record Share Target',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = uniqueValue + '@example.test'
        );
    }

    private static User targetUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB Record Share Target'
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

    private static Company_User_Access__c makeGrant(
        Id companyId,
        Id userId,
        String grantKey
    ) {
        return new Company_User_Access__c(
            Company__c = companyId,
            User__c = userId,
            Effective_From__c = Date.today(),
            Effective_To__c = null,
            Grant_Key__c = grantKey,
            Is_Active__c = true,
            Role__c = 'Bookkeeper'
        );
    }

    private static Accounting_Period__c makePeriod(
        Id companyId,
        String suffixValue
    ) {
        return new Accounting_Period__c(
            Company__c = companyId,
            Company_Period_Key__c =
                'CP-' + suffixValue,
            Period_Key__c =
                'P-' + suffixValue,
            Start_Date__c = Date.newInstance(2026, 1, 1),
            End_Date__c = Date.newInstance(2026, 1, 31),
            Fiscal_Year__c = 2026,
            Fiscal_Quarter__c = 1,
            Period_Number__c = 1,
            Status__c = 'Open'
        );
    }

    private static Integer periodShareCount(
        Id periodId,
        Id userId
    ) {
        return [
            SELECT COUNT()
            FROM Accounting_Period__Share
            WHERE ParentId = :periodId
              AND UserOrGroupId = :userId
              AND RowCause = 'Manual'
        ];
    }

    @IsTest
    static void newPeriodIsSharedToActiveCompanyUser() {
        User u = targetUser();
        Accounting_Company__c company =
            makeCompany('R1', 'Record Sharing Company');

        insert makeGrant(
            company.Id,
            u.Id,
            'RECORD-SHARE-1'
        );

        Accounting_Period__c period =
            makePeriod(company.Id, '2026-01');

        Test.startTest();
        insert period;
        Test.stopTest();

        System.assertEquals(
            1,
            periodShareCount(period.Id, u.Id)
        );
    }

    @IsTest
    static void recordWithoutCompanyGrantIsNotShared() {
        User u = targetUser();
        Accounting_Company__c company =
            makeCompany('R2', 'No Grant Company');

        Accounting_Period__c period =
            makePeriod(company.Id, '2026-02');

        Test.startTest();
        insert period;
        Test.stopTest();

        System.assertEquals(
            0,
            periodShareCount(period.Id, u.Id)
        );
    }

    @IsTest
    static void movingRecordToAnotherCompanyReconcilesSharing() {
        User u = targetUser();

        Accounting_Company__c companyA =
            makeCompany('R3', 'Company A');

        Accounting_Company__c companyB =
            makeCompany('R4', 'Company B');

        insert makeGrant(
            companyA.Id,
            u.Id,
            'RECORD-SHARE-A'
        );

        Accounting_Period__c period =
            makePeriod(companyA.Id, '2026-03');

        insert period;

        System.assertEquals(
            1,
            periodShareCount(period.Id, u.Id)
        );

        period.Company__c = companyB.Id;

        Test.startTest();
        update period;
        Test.stopTest();

        System.assertEquals(
            0,
            periodShareCount(period.Id, u.Id)
        );
    }
}
