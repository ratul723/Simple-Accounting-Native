@IsTest
private class SABCompanyRecordSharingOwnerGuardTest {

    @TestSetup
    static void setupTargetUser() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String uniqueValue =
            'sabownershare.' + String.valueOf(DateTime.now().getTime());

        User u = new User(
            Alias = 'sabownr',
            Email = uniqueValue + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Owner Share User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = uniqueValue + '@example.test'
        );
        insert u;
    }

    private static User targetUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB Owner Share User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c makeCompany() {
        Accounting_Company__c company = new Accounting_Company__c(
            Name__c = 'Owner Share Company',
            Company_Key__c = 'OS',
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

    @IsTest
    static void creatingOwnedJournalDoesNotTryToShareBackToOwner() {
        User u = targetUser();
        Accounting_Company__c company = makeCompany();

        insert new Company_User_Access__c(
            Company__c = company.Id,
            User__c = u.Id,
            Effective_From__c = Date.today(),
            Grant_Key__c = 'OWNER-GRANT',
            Is_Active__c = true,
            Role__c = 'Bookkeeper'
        );

        Accounting_Period__c period = new Accounting_Period__c(
            Name = 'Owner Share Period',
            Company__c = company.Id,
            Company_Period_Key__c = 'CP-OWNER',
            Period_Key__c = 'P-OWNER',
            Start_Date__c = Date.newInstance(2026, 9, 1),
            End_Date__c = Date.newInstance(2026, 9, 30),
            Fiscal_Year__c = 2026,
            Fiscal_Quarter__c = 3,
            Period_Number__c = 9,
            Status__c = 'Open'
        );
        insert period;

        System.runAs(u) {
            Test.startTest();

            Journal_Entry__c journal = new Journal_Entry__c(
                Company__c = company.Id,
                Accounting_Period__c = period.Id,
                Accounting_Date__c = Date.newInstance(2026, 9, 15),
                Entry_Type__c = 'Manual',
                Status__c = 'Draft',
                Description__c = 'Owner share guard test',
                Version__c = 1
            );
            insert journal;

            Test.stopTest();

            System.assertEquals(
                u.Id,
                [
                    SELECT OwnerId
                    FROM Journal_Entry__c
                    WHERE Id = :journal.Id
                ].OwnerId
            );

            System.assertEquals(
                0,
                [
                    SELECT COUNT()
                    FROM Journal_Entry__Share
                    WHERE ParentId = :journal.Id
                      AND UserOrGroupId = :u.Id
                      AND RowCause = 'Manual'
                ],
                'No Manual share is needed for the record owner.'
            );
        }
    }
}
