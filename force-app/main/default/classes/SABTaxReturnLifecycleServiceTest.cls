@IsTest
private class SABTaxReturnLifecycleServiceTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Review_Tax_Return_Action',
            'SAB_Submit_Tax_Return_Action',
            'SAB_Record_Tax_Authority_Outcome_Action',
            'SAB_Amend_Tax_Return_Action'
        };

    @TestSetup
    static void setupFixture() {
        User lifecycleUser =
            createUser();

        assignPermissionSets(
            lifecycleUser
        );

        System.runAs(lifecycleUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c = 'G6D Company',
                    Company_Key__c = 'G6D',
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
                User__c = lifecycleUser.Id,
                Is_Active__c = true,
                Effective_From__c = Date.today(),
                Grant_Key__c = 'G6D-ACCESS',
                Role__c = 'Finance Manager'
            );

            Tax_Registration__c registration =
                new Tax_Registration__c(
                    Name = 'G6D Registration',
                    Company__c = company.Id,
                    Country_Pack_Version__c = 'GENERIC-1',
                    Effective_From__c =
                        Date.newInstance(2026, 1, 1),
                    Filing_Frequency__c = 'Monthly',
                    Is_Active__c = true,
                    Jurisdiction__c = 'BD',
                    Registration_Identifier__c =
                        'G6D-BD-VAT'
                );
            insert registration;

            createPreparedReturn(
                company.Id,
                registration.Id,
                1,
                Date.newInstance(2026, 9, 1),
                Date.newInstance(2026, 9, 30)
            );

            createPreparedReturn(
                company.Id,
                registration.Id,
                1,
                Date.newInstance(2026, 8, 1),
                Date.newInstance(2026, 8, 31)
            );
        }
    }

    @IsTest
    static void reviewSubmitAcceptLocksAndAudits() {
        User lifecycleUser =
            getUser();

        System.runAs(lifecycleUser) {
            Tax_Return__c taxReturn =
                getReturn(
                    Date.newInstance(2026, 9, 1)
                );

            Test.startTest();

            SABTaxReturnLifecycleService.LifecycleResult reviewed =
                SABTaxReturnLifecycleService.reviewReturn(
                    taxReturn.Id,
                    'G6D-REVIEW-SEP',
                    'Finance review complete.'
                );

            SABTaxReturnLifecycleService.LifecycleResult submitted =
                SABTaxReturnLifecycleService.submitReturn(
                    taxReturn.Id,
                    'FILE-SEP-2026',
                    'G6D-SUBMIT-SEP',
                    'Submitted to authority.'
                );

            SABTaxReturnLifecycleService.LifecycleResult accepted =
                SABTaxReturnLifecycleService.recordAuthorityOutcome(
                    taxReturn.Id,
                    'Accepted',
                    'ACK-SEP-2026',
                    'G6D-ACCEPT-SEP',
                    'Authority accepted return.'
                );

            Test.stopTest();

            System.assertEquals(
                'Reviewed',
                reviewed.status
            );
            System.assertEquals(
                64,
                reviewed.lockedSourceHash.length()
            );
            System.assertEquals(
                'Submitted',
                submitted.status
            );
            System.assertEquals(
                'FILE-SEP-2026',
                submitted.filingReference
            );
            System.assertEquals(
                'Accepted',
                accepted.status
            );
            System.assertEquals(
                'ACK-SEP-2026',
                accepted.acknowledgementReference
            );

            Integer auditCount = [
                SELECT COUNT()
                FROM Business_Action__c
                WHERE Source_Record_Id__c =
                        :String.valueOf(taxReturn.Id)
            ];

            System.assertEquals(
                3,
                auditCount
            );

            Tax_Return_Line__c line = [
                SELECT Id,
                       Adjustment_Amount__c
                FROM Tax_Return_Line__c
                WHERE Tax_Return__c =
                        :taxReturn.Id
                LIMIT 1
            ];

            line.Adjustment_Amount__c =
                99;

            Boolean blocked =
                false;

            try {
                update line;
            } catch (DmlException ex) {
                blocked =
                    ex.getMessage().contains(
                        'locked after review'
                    );
            }

            System.assertEquals(
                true,
                blocked
            );
        }
    }

    @IsTest
    static void sourceHashMismatchBlocksSubmission() {
        User lifecycleUser =
            getUser();

        System.runAs(lifecycleUser) {
            Tax_Return__c taxReturn =
                getReturn(
                    Date.newInstance(2026, 8, 1)
                );

            SABTaxReturnLifecycleService.reviewReturn(
                taxReturn.Id,
                'G6D-REVIEW-AUG',
                'Reviewed August return.'
            );

            Tax_Return_Line__c line = [
                SELECT Id,
                       Tax_Return__c,
                       Box_Key__c,
                       Calculated_Amount__c,
                       Adjustment_Amount__c,
                       Final_Amount__c,
                       Source_Inclusion_Hash__c
                FROM Tax_Return_Line__c
                WHERE Tax_Return__c =
                        :taxReturn.Id
                  AND Box_Key__c =
                        'NET_TAX_DUE'
                LIMIT 1
            ];

            SABTaxReturnLifecycleService.lifecycleMutationInProgress =
                true;

            try {
                line.Final_Amount__c =
                    line.Final_Amount__c + 1;
                update line;
            } finally {
                SABTaxReturnLifecycleService.lifecycleMutationInProgress =
                    false;
            }

            Boolean blocked =
                false;

            try {
                SABTaxReturnLifecycleService.submitReturn(
                    taxReturn.Id,
                    'FILE-AUG-2026',
                    'G6D-SUBMIT-AUG',
                    'Should fail because snapshot changed.'
                );
            } catch (
                SABTaxReturnLifecycleService.TaxReturnLifecycleException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'changed after review'
                    );
            }

            System.assertEquals(
                true,
                blocked
            );
        }
    }

    @IsTest
    static void rejectedReturnCanCreateVersionedAmendmentAndReplay() {
        User lifecycleUser =
            getUser();

        System.runAs(lifecycleUser) {
            Tax_Return__c taxReturn =
                getReturn(
                    Date.newInstance(2026, 8, 1)
                );

            SABTaxReturnLifecycleService.reviewReturn(
                taxReturn.Id,
                'G6D-REVIEW-AUG2',
                'Review.'
            );

            SABTaxReturnLifecycleService.submitReturn(
                taxReturn.Id,
                'FILE-AUG-2',
                'G6D-SUBMIT-AUG2',
                'Submit.'
            );

            SABTaxReturnLifecycleService.recordAuthorityOutcome(
                taxReturn.Id,
                'Rejected',
                'ACK-REJECT-AUG',
                'G6D-REJECT-AUG',
                'Authority requested correction.'
            );

            Test.startTest();

            SABTaxReturnLifecycleService.LifecycleResult first =
                SABTaxReturnLifecycleService.createAmendment(
                    taxReturn.Id,
                    'G6D-AMEND-AUG',
                    'Correct rejected August return.'
                );

            SABTaxReturnLifecycleService.LifecycleResult replay =
                SABTaxReturnLifecycleService.createAmendment(
                    taxReturn.Id,
                    'G6D-AMEND-AUG',
                    'Correct rejected August return.'
                );

            Test.stopTest();

            System.assertEquals(
                'Amended',
                first.status
            );
            System.assertNotEquals(
                null,
                first.amendmentTaxReturnId
            );
            System.assertEquals(
                true,
                replay.replay
            );
            System.assertEquals(
                first.amendmentTaxReturnId,
                replay.amendmentTaxReturnId
            );

            Tax_Return__c amendment = [
                SELECT Status__c,
                       Return_Version__c,
                       Amends_Tax_Return__c,
                       Locked_Source_Hash__c,
                       Filing_Reference__c,
                       Acknowledgement_Reference__c
                FROM Tax_Return__c
                WHERE Id =
                        :first.amendmentTaxReturnId
            ];

            System.assertEquals(
                'Draft',
                amendment.Status__c
            );
            System.assertEquals(
                Decimal.valueOf('2'),
                amendment.Return_Version__c
            );
            System.assertEquals(
                taxReturn.Id,
                amendment.Amends_Tax_Return__c
            );
            System.assertEquals(
                null,
                amendment.Locked_Source_Hash__c
            );
            System.assertEquals(
                null,
                amendment.Filing_Reference__c
            );
            System.assertEquals(
                null,
                amendment.Acknowledgement_Reference__c
            );

            Integer amendmentLineCount = [
                SELECT COUNT()
                FROM Tax_Return_Line__c
                WHERE Tax_Return__c =
                        :amendment.Id
            ];

            System.assertEquals(
                0,
                amendmentLineCount,
                'New amendment starts Draft; G6C must prepare fresh lines.'
            );
        }
    }

    private static void createPreparedReturn(
        Id companyId,
        Id registrationId,
        Decimal version,
        Date periodStart,
        Date periodEnd
    ) {
        Tax_Return__c taxReturn =
            new Tax_Return__c(
                Company__c = companyId,
                Tax_Registration__c = registrationId,
                Period_Start__c = periodStart,
                Period_End__c = periodEnd,
                Country_Pack_Version__c = 'GENERIC-1',
                Return_Version__c = version,
                Status__c = 'Prepared'
            );
        insert taxReturn;

        insert new List<Tax_Return_Line__c>{
            returnLine(
                taxReturn.Id,
                'OUTPUT_TAXABLE_BASE',
                'Output Taxable Base',
                100,
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            ),
            returnLine(
                taxReturn.Id,
                'OUTPUT_TAX',
                'Output Tax',
                15,
                'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            ),
            returnLine(
                taxReturn.Id,
                'INPUT_TAXABLE_BASE',
                'Input Taxable Base',
                100,
                'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
            ),
            returnLine(
                taxReturn.Id,
                'INPUT_TAX_RECOVERABLE',
                'Recoverable Input Tax',
                6,
                'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
            ),
            returnLine(
                taxReturn.Id,
                'NET_TAX_DUE',
                'Net Tax Due',
                9,
                'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
            )
        };
    }

    private static Tax_Return_Line__c returnLine(
        Id taxReturnId,
        String boxKey,
        String label,
        Decimal amount,
        String sourceHash
    ) {
        return new Tax_Return_Line__c(
            Tax_Return__c = taxReturnId,
            Box_Key__c = boxKey,
            Label__c = label,
            Calculated_Amount__c = amount,
            Adjustment_Amount__c = 0,
            Final_Amount__c = amount,
            Source_Inclusion_Hash__c = sourceHash
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

        User userRecord =
            new User(
                Alias = 'g6dlife',
                Email =
                    'g6dlife.'
                    + seed
                    + '@example.test',
                EmailEncodingKey = 'UTF-8',
                LastName = 'G6D Lifecycle User',
                LanguageLocaleKey = 'en_US',
                LocaleSidKey = 'en_US',
                ProfileId = profileRecord.Id,
                TimeZoneSidKey = 'Asia/Dhaka',
                Username =
                    'g6dlife.'
                    + seed
                    + '@example.test'
            );

        insert userRecord;

        return userRecord;
    }

    private static void assignPermissionSets(
        User userRecord
    ) {
        Map<String, Id> idsByName =
            new Map<String, Id>();

        for (PermissionSet row : [
            SELECT Id,
                   Name
            FROM PermissionSet
            WHERE Name IN :REQUIRED_PERMISSION_SETS
        ]) {
            idsByName.put(
                row.Name,
                row.Id
            );
        }

        System.assertEquals(
            REQUIRED_PERMISSION_SETS.size(),
            idsByName.size(),
            'All G6D action permission sets must exist.'
        );

        List<PermissionSetAssignment> assignments =
            new List<PermissionSetAssignment>();

        for (String nameValue : REQUIRED_PERMISSION_SETS) {
            assignments.add(
                new PermissionSetAssignment(
                    AssigneeId = userRecord.Id,
                    PermissionSetId =
                        idsByName.get(
                            nameValue
                        )
                )
            );
        }

        insert assignments;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                'G6D Lifecycle User'
            LIMIT 1
        ];
    }

    private static Tax_Return__c getReturn(
        Date periodStart
    ) {
        return [
            SELECT Id,
                   Status__c,
                   Return_Version__c
            FROM Tax_Return__c
            WHERE Period_Start__c =
                    :periodStart
            LIMIT 1
        ];
    }
}
