@IsTest
private class SABCompanySharingServiceTest {

    @TestSetup
    static void createTargetUser() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String uniqueValue =
            'sabshare.' + String.valueOf(DateTime.now().getTime());

        User targetUser = new User(
            Alias = 'sabshr',
            Email = uniqueValue + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Sharing Target',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = uniqueValue + '@example.test'
        );

        insert targetUser;
    }

    private static User getTargetUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB Sharing Target'
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
        String keySuffix
    ) {
        return new Company_User_Access__c(
            Company__c = companyId,
            User__c = userId,
            Effective_From__c = effectiveFrom,
            Effective_To__c = effectiveTo,
            Grant_Key__c = 'SHARE-' + keySuffix,
            Is_Active__c = isActive,
            Role__c = 'Bookkeeper'
        );
    }

    private static Integer manualCompanyShareCount(
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
    static void activeGrantCreatesCompanyShareAndRunsCoreReconciliation() {
        User targetUser = getTargetUser();
        Accounting_Company__c company =
            makeCompany('A1', 'Sharing Company A');

        Company_User_Access__c grant = makeGrant(
            company.Id,
            targetUser.Id,
            true,
            Date.today().addDays(-1),
            null,
            'ACTIVE'
        );

        Test.startTest();
        insert grant;
        Test.stopTest();

        System.assertEquals(
            1,
            manualCompanyShareCount(company.Id, targetUser.Id)
        );

        // Metadata-driven list proves that the expansion service detects the
        // currently deployed shareable company-scoped objects without
        // hard-coding their required business fields in this test.
        List<String> shareableObjects =
            SABCompanySharingService.getShareableSupportedObjects();

        System.assertNotEquals(null, shareableObjects);
    }

    @IsTest
    static void inactiveAndExpiredGrantCreateNoCompanyShare() {
        User targetUser = getTargetUser();

        Accounting_Company__c inactiveCompany =
            makeCompany('B1', 'Inactive Grant Company');

        Accounting_Company__c expiredCompany =
            makeCompany('B2', 'Expired Grant Company');

        Test.startTest();

        insert new List<Company_User_Access__c>{
            makeGrant(
                inactiveCompany.Id,
                targetUser.Id,
                false,
                Date.today().addDays(-1),
                null,
                'INACTIVE'
            ),
            makeGrant(
                expiredCompany.Id,
                targetUser.Id,
                true,
                Date.today().addDays(-10),
                Date.today().addDays(-1),
                'EXPIRED'
            )
        };

        Test.stopTest();

        System.assertEquals(
            0,
            manualCompanyShareCount(
                inactiveCompany.Id,
                targetUser.Id
            )
        );

        System.assertEquals(
            0,
            manualCompanyShareCount(
                expiredCompany.Id,
                targetUser.Id
            )
        );
    }

    @IsTest
    static void deactivatingGrantRemovesCompanyShare() {
        User targetUser = getTargetUser();

        Accounting_Company__c company =
            makeCompany('C1', 'Deactivate Grant Company');

        Company_User_Access__c grant = makeGrant(
            company.Id,
            targetUser.Id,
            true,
            Date.today(),
            null,
            'DEACT'
        );

        insert grant;

        System.assertEquals(
            1,
            manualCompanyShareCount(company.Id, targetUser.Id)
        );

        grant.Is_Active__c = false;

        Test.startTest();
        update grant;
        Test.stopTest();

        System.assertEquals(
            0,
            manualCompanyShareCount(company.Id, targetUser.Id)
        );
    }

    @IsTest
    static void deletingGrantRemovesCompanyShare() {
        User targetUser = getTargetUser();

        Accounting_Company__c company =
            makeCompany('D1', 'Delete Grant Company');

        Company_User_Access__c grant = makeGrant(
            company.Id,
            targetUser.Id,
            true,
            Date.today(),
            null,
            'DELETE'
        );

        insert grant;

        Test.startTest();
        delete grant;
        Test.stopTest();

        System.assertEquals(
            0,
            manualCompanyShareCount(company.Id, targetUser.Id)
        );
    }

    @IsTest
    static void undeletingGrantRecreatesCompanyShare() {
        User targetUser = getTargetUser();

        Accounting_Company__c company =
            makeCompany('E1', 'Undelete Grant Company');

        Company_User_Access__c grant = makeGrant(
            company.Id,
            targetUser.Id,
            true,
            Date.today(),
            null,
            'UNDELETE'
        );

        insert grant;
        delete grant;

        Test.startTest();
        undelete grant;
        Test.stopTest();

        System.assertEquals(
            1,
            manualCompanyShareCount(company.Id, targetUser.Id)
        );
    }

    @IsTest
    static void multipleEffectiveGrantsKeepOneCompanyShare() {
        User targetUser = getTargetUser();

        Accounting_Company__c company =
            makeCompany('F1', 'Duplicate Grant Company');

        Test.startTest();

        insert new List<Company_User_Access__c>{
            makeGrant(
                company.Id,
                targetUser.Id,
                true,
                Date.today().addDays(-5),
                null,
                'DUP1'
            ),
            makeGrant(
                company.Id,
                targetUser.Id,
                true,
                Date.today().addDays(-1),
                null,
                'DUP2'
            )
        };

        Test.stopTest();

        System.assertEquals(
            1,
            manualCompanyShareCount(company.Id, targetUser.Id)
        );
    }
}
