@IsTest
private class SABJournalValidationServiceTest {

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
            'sabjournalvalidate.'
            + String.valueOf(DateTime.now().getTime());

        insert new User(
            Alias = 'sabjval',
            Email = uniqueValue + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Journal Validation User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = uniqueValue + '@example.test'
        );
    }

    private static User testUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                'SAB Journal Validation User'
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

    private static Accounting_Period__c makePeriod(
        Id companyId,
        String suffixValue,
        String statusValue
    ) {
        Accounting_Period__c period =
            new Accounting_Period__c(
                Name = 'Period ' + suffixValue,
                Company__c = companyId,
                Company_Period_Key__c =
                    'CP-' + suffixValue,
                Period_Key__c =
                    'P-' + suffixValue,
                Start_Date__c =
                    Date.newInstance(2026, 9, 1),
                End_Date__c =
                    Date.newInstance(2026, 9, 30),
                Fiscal_Year__c = 2026,
                Fiscal_Quarter__c = 3,
                Period_Number__c = 9,
                Status__c = statusValue
            );

        if (statusValue == 'Closed') {
            period.Closed_At__c = System.now();
            period.Closed_By__c = UserInfo.getUserId();
        }

        insert period;
        return period;
    }

    private static GL_Account__c makeGLAccount(
        Id companyId,
        String accountCode,
        Boolean isActive,
        Boolean manualPostingAllowed
    ) {
        GL_Account__c account =
            new GL_Account__c(
                Name = 'Account ' + accountCode,
                Company__c = companyId,
                Company_Account_Key__c =
                    String.valueOf(companyId)
                    + '-'
                    + accountCode,
                Account_Code__c = accountCode,
                Account_Type__c = 'Asset',
                Normal_Balance__c = 'Debit',
                Is_Active__c = isActive,
                Is_Control_Account__c = false,
                Control_Type__c = 'None',
                Manual_Posting_Allowed__c =
                    manualPostingAllowed
            );

        insert account;
        return account;
    }

    private static Journal_Entry__c makeJournal(
        Id companyId,
        Id periodId,
        Date accountingDate
    ) {
        Journal_Entry__c journal =
            new Journal_Entry__c(
                Company__c = companyId,
                Accounting_Period__c = periodId,
                Accounting_Date__c = accountingDate,
                Entry_Type__c = 'Manual',
                Status__c = 'Draft',
                Description__c =
                    'Journal validation test',
                Version__c = 1
            );

        insert journal;
        return journal;
    }

    private static Journal_Entry_Line__c makeLine(
        Id journalId,
        Id glAccountId,
        Integer lineNumber,
        Decimal debit,
        Decimal credit
    ) {
        return new Journal_Entry_Line__c(
            Journal_Entry__c = journalId,
            GL_Account__c = glAccountId,
            Line_Number__c = lineNumber,
            Debit_Base__c = debit,
            Credit_Base__c = credit,
            Functional_Currency__c = 'BDT'
        );
    }

    private static void grantCompanyAccess(
        Id companyId,
        Id userId,
        String grantKey
    ) {
        insert new Company_User_Access__c(
            Company__c = companyId,
            User__c = userId,
            Effective_From__c = Date.today(),
            Effective_To__c = null,
            Grant_Key__c = grantKey,
            Is_Active__c = true,
            Role__c = 'Bookkeeper'
        );
    }

    @IsTest
    static void balancedDraftJournalPasses() {
        User u = testUser();

        Accounting_Company__c company =
            makeCompany('JV1', 'Validation Company 1');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'JV1',
                'Open'
            );

        GL_Account__c cash =
            makeGLAccount(
                company.Id,
                '1000',
                true,
                true
            );

        GL_Account__c expense =
            makeGLAccount(
                company.Id,
                '5000',
                true,
                true
            );

        Journal_Entry__c journal =
            makeJournal(
                company.Id,
                period.Id,
                Date.newInstance(2026, 9, 15)
            );

        insert new List<Journal_Entry_Line__c>{
            makeLine(
                journal.Id,
                expense.Id,
                1,
                100,
                0
            ),
            makeLine(
                journal.Id,
                cash.Id,
                2,
                0,
                100
            )
        };

        grantCompanyAccess(
            company.Id,
            u.Id,
            'JVAL-1'
        );

        System.runAs(u) {
            Test.startTest();

            SABJournalValidationService.ValidationResult result =
                SABJournalValidationService.validateForPosting(journal.Id);

            Test.stopTest();

            System.assertEquals(true, result.isValid);
            System.assertEquals(2, result.lineCount);
            System.assertEquals(
                Decimal.valueOf('100.0000'),
                result.totalDebit
            );
            System.assertEquals(
                Decimal.valueOf('100.0000'),
                result.totalCredit
            );

            SABJournalValidationService.assertValidForPosting(journal.Id);
        }
    }

    @IsTest
    static void unbalancedJournalFails() {
        User u = testUser();

        Accounting_Company__c company =
            makeCompany('JV2', 'Validation Company 2');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'JV2',
                'Open'
            );

        GL_Account__c accountA =
            makeGLAccount(
                company.Id,
                '1100',
                true,
                true
            );

        GL_Account__c accountB =
            makeGLAccount(
                company.Id,
                '5100',
                true,
                true
            );

        Journal_Entry__c journal =
            makeJournal(
                company.Id,
                period.Id,
                Date.newInstance(2026, 9, 15)
            );

        insert new List<Journal_Entry_Line__c>{
            makeLine(
                journal.Id,
                accountA.Id,
                1,
                100,
                0
            ),
            makeLine(
                journal.Id,
                accountB.Id,
                2,
                0,
                90
            )
        };

        grantCompanyAccess(
            company.Id,
            u.Id,
            'JVAL-2'
        );

        System.runAs(u) {
            SABJournalValidationService.ValidationResult result =
                SABJournalValidationService.validateForPosting(journal.Id);

            System.assertEquals(false, result.isValid);
            System.assert(
                String.join(result.errors, ' ').contains('not balanced')
            );
        }
    }

    @IsTest
    static void closedPeriodFails() {
        User u = testUser();

        Accounting_Company__c company =
            makeCompany('JV3', 'Validation Company 3');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'JV3',
                'Closed'
            );

        GL_Account__c accountA =
            makeGLAccount(
                company.Id,
                '1200',
                true,
                true
            );

        GL_Account__c accountB =
            makeGLAccount(
                company.Id,
                '5200',
                true,
                true
            );

        Journal_Entry__c journal =
            makeJournal(
                company.Id,
                period.Id,
                Date.newInstance(2026, 9, 15)
            );

        insert new List<Journal_Entry_Line__c>{
            makeLine(
                journal.Id,
                accountA.Id,
                1,
                50,
                0
            ),
            makeLine(
                journal.Id,
                accountB.Id,
                2,
                0,
                50
            )
        };

        grantCompanyAccess(
            company.Id,
            u.Id,
            'JVAL-3'
        );

        System.runAs(u) {
            SABJournalValidationService.ValidationResult result =
                SABJournalValidationService.validateForPosting(journal.Id);

            System.assertEquals(false, result.isValid);
            System.assert(
                String.join(result.errors, ' ').contains('must be Open')
            );
        }
    }

    @IsTest
    static void inactiveGLFailsAfterCrossCompanyGuardAdded() {
        User u = testUser();

        Accounting_Company__c company =
            makeCompany('JV4', 'Validation Company');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'JV4',
                'Open'
            );

        GL_Account__c validAccount =
            makeGLAccount(
                company.Id,
                '1300',
                true,
                true
            );

        // Keep this account in the SAME company so Step 7B's
        // cross-company trigger allows the draft line to be inserted.
        // This test is now focused only on the journal validation
        // service's inactive-GL rule.
        GL_Account__c inactiveAccount =
            makeGLAccount(
                company.Id,
                '5300',
                false,
                true
            );

        Journal_Entry__c journal =
            makeJournal(
                company.Id,
                period.Id,
                Date.newInstance(2026, 9, 15)
            );

        insert new List<Journal_Entry_Line__c>{
            makeLine(
                journal.Id,
                validAccount.Id,
                1,
                75,
                0
            ),
            makeLine(
                journal.Id,
                inactiveAccount.Id,
                2,
                0,
                75
            )
        };

        grantCompanyAccess(
            company.Id,
            u.Id,
            'JVAL-4'
        );

        System.runAs(u) {
            SABJournalValidationService.ValidationResult result =
                SABJournalValidationService.validateForPosting(journal.Id);

            String messages =
                String.join(result.errors, ' ');

            System.assertEquals(false, result.isValid);
            System.assert(
                messages.contains('must be active')
            );
        }
    }

    @IsTest
    static void manualPostingDisallowedFails() {
        User u = testUser();

        Accounting_Company__c company =
            makeCompany('JV6', 'Manual Posting Company');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'JV6',
                'Open'
            );

        GL_Account__c restricted =
            makeGLAccount(
                company.Id,
                '1400',
                true,
                false
            );

        GL_Account__c offsetAccount =
            makeGLAccount(
                company.Id,
                '5400',
                true,
                true
            );

        Journal_Entry__c journal =
            makeJournal(
                company.Id,
                period.Id,
                Date.newInstance(2026, 9, 15)
            );

        insert new List<Journal_Entry_Line__c>{
            makeLine(
                journal.Id,
                restricted.Id,
                1,
                40,
                0
            ),
            makeLine(
                journal.Id,
                offsetAccount.Id,
                2,
                0,
                40
            )
        };

        grantCompanyAccess(
            company.Id,
            u.Id,
            'JVAL-5'
        );

        System.runAs(u) {
            SABJournalValidationService.ValidationResult result =
                SABJournalValidationService.validateForPosting(journal.Id);

            System.assertEquals(false, result.isValid);
            System.assert(
                String.join(result.errors, ' ').contains(
                    'does not allow manual/opening posting'
                )
            );
        }
    }

    @IsTest
    static void userWithoutCompanyAccessIsRejected() {
        User u = testUser();

        Accounting_Company__c company =
            makeCompany('JV7', 'Unauthorized Journal Company');

        Accounting_Period__c period =
            makePeriod(
                company.Id,
                'JV7',
                'Open'
            );

        GL_Account__c accountA =
            makeGLAccount(
                company.Id,
                '1500',
                true,
                true
            );

        GL_Account__c accountB =
            makeGLAccount(
                company.Id,
                '5500',
                true,
                true
            );

        Journal_Entry__c journal =
            makeJournal(
                company.Id,
                period.Id,
                Date.newInstance(2026, 9, 15)
            );

        insert new List<Journal_Entry_Line__c>{
            makeLine(
                journal.Id,
                accountA.Id,
                1,
                25,
                0
            ),
            makeLine(
                journal.Id,
                accountB.Id,
                2,
                0,
                25
            )
        };

        System.runAs(u) {
            Boolean thrown = false;

            try {
                SABJournalValidationService.validateForPosting(journal.Id);
            } catch (Exception ex) {
                thrown = true;
                System.assert(
                    ex.getMessage().contains(
                        'active access to this Accounting Company'
                    )
                    || ex.getMessage().contains(
                        'access to this Accounting Company'
                    )
                );
            }

            System.assertEquals(true, thrown);
        }
    }
}
