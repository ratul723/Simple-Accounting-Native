@IsTest
private class SABSequenceServiceTest {

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
            'sabsequence.'
            + String.valueOf(
                DateTime.now().getTime()
            );

        User u = new User(
            Alias = 'sabseq',
            Email = uniqueValue + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Sequence User',
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
            WHERE LastName = 'SAB Sequence User'
            LIMIT 1
        ];
    }

    @IsTest
    static void reservesFormatsAndIncrementsNumber() {
        User u = targetUser();
        Accounting_Company__c company =
            makeCompany('Q61');

        grant(company.Id, u.Id, 'SEQ-GRANT-1');

        Document_Sequence__c sequenceRecord =
            makeSequence(
                company.Id,
                'SEQ-Q61',
                'Invoice',
                'FY2026',
                'INV-',
                6,
                1,
                true
            );

        System.runAs(u) {
            SABSequenceService.ReservationResult result =
                SABSequenceService.reserveNextNumber(
                    company.Id,
                    'Invoice',
                    'FY2026'
                );

            System.assertEquals(
                Decimal.valueOf('1'),
                result.reservedNumber
            );
            System.assertEquals(
                'INV-000001',
                result.formattedNumber
            );
            System.assertEquals(
                Decimal.valueOf('2'),
                result.nextNumber
            );
        }

        System.assertEquals(
            Decimal.valueOf('2'),
            [
                SELECT Next_Number__c
                FROM Document_Sequence__c
                WHERE Id = :sequenceRecord.Id
            ].Next_Number__c
        );
    }

    @IsTest
    static void directCounterEditIsBlocked() {
        Accounting_Company__c company =
            makeCompany('Q62');

        Document_Sequence__c sequenceRecord =
            makeSequence(
                company.Id,
                'SEQ-Q62',
                'Invoice',
                'FY2026',
                'INV-',
                6,
                1,
                true
            );

        sequenceRecord.Next_Number__c = 50;

        Database.SaveResult result =
            Database.update(
                sequenceRecord,
                false
            );

        System.assertEquals(
            false,
            result.isSuccess()
        );
    }

    @IsTest
    static void activeIdentityAndFormatCannotChange() {
        Accounting_Company__c company =
            makeCompany('Q63');

        Document_Sequence__c sequenceRecord =
            makeSequence(
                company.Id,
                'SEQ-Q63',
                'Invoice',
                'FY2026',
                'INV-',
                6,
                1,
                true
            );

        sequenceRecord.Prefix__c = 'NEW-';

        System.assertEquals(
            false,
            Database.update(
                sequenceRecord,
                false
            ).isSuccess()
        );
    }

    @IsTest
    static void inactiveSequenceCannotReserve() {
        User u = targetUser();
        Accounting_Company__c company =
            makeCompany('Q64');

        grant(company.Id, u.Id, 'SEQ-GRANT-4');

        Document_Sequence__c sequenceRecord =
            makeSequence(
                company.Id,
                'SEQ-Q64',
                'Invoice',
                'FY2026',
                'INV-',
                6,
                1,
                false
            );

        System.runAs(u) {
            Boolean thrown = false;

            try {
                SABSequenceService.reserveNextNumberById(
                    sequenceRecord.Id
                );
            } catch (
                SABSequenceService.SequenceException ex
            ) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }
    }

    @IsTest
    static void userWithoutCompanyAccessCannotReserve() {
        User u = targetUser();
        Accounting_Company__c company =
            makeCompany('Q65');

        Document_Sequence__c sequenceRecord =
            makeSequence(
                company.Id,
                'SEQ-Q65',
                'Invoice',
                'FY2026',
                'INV-',
                6,
                1,
                true
            );

        System.runAs(u) {
            Boolean thrown = false;

            try {
                SABSequenceService.reserveNextNumberById(
                    sequenceRecord.Id
                );
            } catch (Exception ex) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }
    }

    @IsTest
    static void transactionRollbackRestoresCounter() {
        User u = targetUser();
        Accounting_Company__c company =
            makeCompany('Q66');

        grant(company.Id, u.Id, 'SEQ-GRANT-6');

        Document_Sequence__c sequenceRecord =
            makeSequence(
                company.Id,
                'SEQ-Q66',
                'Invoice',
                'FY2026',
                'INV-',
                6,
                10,
                true
            );

        System.runAs(u) {
            Savepoint sp = Database.setSavepoint();

            SABSequenceService.ReservationResult result =
                SABSequenceService.reserveNextNumberById(
                    sequenceRecord.Id
                );

            System.assertEquals(
                'INV-000010',
                result.formattedNumber
            );

            Database.rollback(sp);
        }

        System.assertEquals(
            Decimal.valueOf('10'),
            [
                SELECT Next_Number__c
                FROM Document_Sequence__c
                WHERE Id = :sequenceRecord.Id
            ].Next_Number__c
        );
    }

    @IsTest
    static void duplicateActiveScopeIsRejected() {
        User u = targetUser();
        Accounting_Company__c company =
            makeCompany('Q67');

        grant(company.Id, u.Id, 'SEQ-GRANT-7');

        makeSequence(
            company.Id,
            'SEQ-Q67-A',
            'Invoice',
            'FY2026',
            'A-',
            6,
            1,
            true
        );

        makeSequence(
            company.Id,
            'SEQ-Q67-B',
            'Invoice',
            'FY2026',
            'B-',
            6,
            1,
            true
        );

        System.runAs(u) {
            Boolean thrown = false;

            try {
                SABSequenceService.reserveNextNumber(
                    company.Id,
                    'Invoice',
                    'FY2026'
                );
            } catch (
                SABSequenceService.SequenceException ex
            ) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }
    }

    private static Accounting_Company__c makeCompany(
        String keyValue
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c = 'Sequence ' + keyValue,
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

    private static Document_Sequence__c makeSequence(
        Id companyId,
        String sequenceKey,
        String documentType,
        String fiscalSeries,
        String prefix,
        Integer minimumDigits,
        Integer nextNumber,
        Boolean isActive
    ) {
        Document_Sequence__c recordValue =
            new Document_Sequence__c(
                Company__c = companyId,
                Sequence_Key__c = sequenceKey,
                Document_Type__c = documentType,
                Fiscal_Series__c = fiscalSeries,
                Prefix__c = prefix,
                Minimum_Digits__c = minimumDigits,
                Next_Number__c = nextNumber,
                Is_Active__c = isActive
            );

        insert recordValue;
        return recordValue;
    }
}
