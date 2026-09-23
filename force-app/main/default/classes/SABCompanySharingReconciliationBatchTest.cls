@IsTest
private class SABCompanySharingReconciliationBatchTest {

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
            'sabreconcile.' + String.valueOf(DateTime.now().getTime());

        insert new User(
            Alias = 'sabrec',
            Email = uniqueValue + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Reconciliation Target',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = uniqueValue + '@example.test'
        );
    }

    private static User getTargetUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB Reconciliation Target'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c makeCompany(
        String companyKey,
        String displayName
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c = displayName,
                Company_Key__c = companyKey,
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
        Boolean isActive,
        Date effectiveFrom,
        Date effectiveTo,
        String grantKey
    ) {
        return new Company_User_Access__c(
            Company__c = companyId,
            User__c = userId,
            Effective_From__c = effectiveFrom,
            Effective_To__c = effectiveTo,
            Grant_Key__c = grantKey,
            Is_Active__c = isActive,
            Role__c = 'Bookkeeper'
        );
    }

    private static Integer companyShareCount(
        Id companyId,
        Id userId
    ) {
        return [
            SELECT COUNT()
            FROM Accounting_Company__Share
            WHERE ParentId = :companyId
              AND UserOrGroupId = :userId
              AND RowCause = 'Manual'
        ];
    }

    @IsTest
    static void batchRestoresMissingShareForEffectiveGrant() {
        User targetUser = getTargetUser();
        Accounting_Company__c company =
            makeCompany('S1', 'Scheduled Reconcile Company');

        Company_User_Access__c grant = makeGrant(
            company.Id,
            targetUser.Id,
            true,
            Date.today().addDays(-1),
            null,
            'SCH-1'
        );

        insert grant;

        List<Accounting_Company__Share> existingShares = [
            SELECT Id
            FROM Accounting_Company__Share
            WHERE ParentId = :company.Id
              AND UserOrGroupId = :targetUser.Id
              AND RowCause = 'Manual'
        ];

        System.assertEquals(1, existingShares.size());

        // Simulate a stale/missing share so the scheduled reconciliation
        // has something to repair.
        delete existingShares;

        System.assertEquals(
            0,
            companyShareCount(company.Id, targetUser.Id)
        );

        Test.startTest();
        Database.executeBatch(
            new SABCompanySharingReconciliationBatch(),
            50
        );
        Test.stopTest();

        System.assertEquals(
            1,
            companyShareCount(company.Id, targetUser.Id)
        );
    }

    @IsTest
    static void batchRemovesShareForExpiredGrant() {
        User targetUser = getTargetUser();
        Accounting_Company__c company =
            makeCompany('S2', 'Expired Reconcile Company');

        // Insert already-expired grant. Trigger should not create a share.
        insert makeGrant(
            company.Id,
            targetUser.Id,
            true,
            Date.today().addDays(-10),
            Date.today().addDays(-1),
            'SCH-2'
        );

        // Simulate a stale Manual share left behind from yesterday.
        insert new Accounting_Company__Share(
            ParentId = company.Id,
            UserOrGroupId = targetUser.Id,
            AccessLevel = 'Read',
            RowCause = Schema.Accounting_Company__Share.RowCause.Manual
        );

        System.assertEquals(
            1,
            companyShareCount(company.Id, targetUser.Id)
        );

        Test.startTest();
        Database.executeBatch(
            new SABCompanySharingReconciliationBatch(),
            50
        );
        Test.stopTest();

        System.assertEquals(
            0,
            companyShareCount(company.Id, targetUser.Id)
        );
    }

    @IsTest
    static void schedulerLaunchesReconciliationBatch() {
        User targetUser = getTargetUser();
        Accounting_Company__c company =
            makeCompany('S3', 'Scheduler Company');

        insert makeGrant(
            company.Id,
            targetUser.Id,
            true,
            Date.today(),
            null,
            'SCH-3'
        );

        Test.startTest();

        String jobId = System.schedule(
            'SAB Sharing Scheduler Test',
            '0 0 0 1 1 ? 2099',
            new SABCompanySharingScheduler()
        );

        System.assertNotEquals(null, jobId);

        Test.stopTest();

        System.assertEquals(
            1,
            companyShareCount(company.Id, targetUser.Id)
        );
    }
}
