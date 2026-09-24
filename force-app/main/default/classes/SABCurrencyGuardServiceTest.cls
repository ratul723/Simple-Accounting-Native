@IsTest
private class SABCurrencyGuardServiceTest {

    @IsTest
    static void zeroTwoThreeMinorUnitRegression() {
        System.assertEquals(
            Decimal.valueOf('124'),
            SABMoneyService.roundForMinorUnits(
                Decimal.valueOf('123.55'),
                0,
                RoundingMode.HALF_UP
            )
        );

        System.assertEquals(
            Decimal.valueOf('123.46'),
            SABMoneyService.roundForMinorUnits(
                Decimal.valueOf('123.456'),
                2,
                RoundingMode.HALF_UP
            )
        );

        System.assertEquals(
            Decimal.valueOf('123.457'),
            SABMoneyService.roundForMinorUnits(
                Decimal.valueOf('123.4567'),
                3,
                RoundingMode.HALF_UP
            )
        );
    }

    @IsTest
    static void legacySingleCurrencyLineWithoutTransactionSnapshotPasses() {
        Journal_Entry_Line__c line =
            new Journal_Entry_Line__c(
                Debit_Base__c = 100,
                Credit_Base__c = 0,
                Functional_Currency__c = 'BDT'
            );

        SABCurrencyGuardService.ValidationResult result =
            SABCurrencyGuardService.validateJournalLineSnapshot(
                    line,
                    'BDT'
                );

        System.assertEquals(true, result.isValid);
        System.assertEquals(0, result.errors.size());
    }

    @IsTest
    static void sameCurrencyCompleteSnapshotPasses() {
        Journal_Entry_Line__c line =
            new Journal_Entry_Line__c(
                Debit_Base__c = 100.1250,
                Credit_Base__c = 0,
                Transaction_Currency__c = 'BDT',
                Transaction_Amount__c = 100.1250,
                Functional_Currency__c = 'BDT',
                Applied_Exchange_Rate__c = 1
            );

        SABCurrencyGuardService.ValidationResult result =
            SABCurrencyGuardService.validateJournalLineSnapshot(
                    line,
                    'BDT'
                );

        System.assertEquals(true, result.isValid);
    }

    @IsTest
    static void sameCurrencyNonOneRateFails() {
        Journal_Entry_Line__c line =
            new Journal_Entry_Line__c(
                Debit_Base__c = 100,
                Credit_Base__c = 0,
                Transaction_Currency__c = 'BDT',
                Transaction_Amount__c = 100,
                Functional_Currency__c = 'BDT',
                Applied_Exchange_Rate__c = 1.01
            );

        SABCurrencyGuardService.ValidationResult result =
            SABCurrencyGuardService.validateJournalLineSnapshot(
                    line,
                    'BDT'
                );

        System.assertEquals(false, result.isValid);
        System.assert(
            String.join(result.errors, ' ').contains(
                'Applied Exchange Rate of 1'
            )
        );
    }

    @IsTest
    static void foreignCurrencyRequiresCompleteSnapshot() {
        Journal_Entry_Line__c line =
            new Journal_Entry_Line__c(
                Debit_Base__c = 122.2500,
                Credit_Base__c = 0,
                Transaction_Currency__c = 'USD',
                Transaction_Amount__c = 1,
                Functional_Currency__c = 'BDT'
            );

        SABCurrencyGuardService.ValidationResult result =
            SABCurrencyGuardService.validateJournalLineSnapshot(
                    line,
                    'BDT'
                );

        String errors =
            String.join(result.errors, ' ');

        System.assertEquals(false, result.isValid);
        System.assert(
            errors.contains('Applied Exchange Rate')
        );
        System.assert(
            errors.contains('Rate Date')
        );
        System.assert(
            errors.contains('Rate Source')
        );
    }

    @IsTest
    static void validForeignCurrencySnapshotPasses() {
        Journal_Entry_Line__c line =
            new Journal_Entry_Line__c(
                Debit_Base__c = 122.2500,
                Credit_Base__c = 0,
                Transaction_Currency__c = 'USD',
                Transaction_Amount__c = 1,
                Functional_Currency__c = 'BDT',
                Applied_Exchange_Rate__c =
                    Decimal.valueOf('122.2500000000'),
                Rate_Date__c =
                    Date.newInstance(2026, 9, 24),
                Rate_Source__c =
                    'Approved Provider'
            );

        SABCurrencyGuardService.ValidationResult result =
            SABCurrencyGuardService.validateJournalLineSnapshot(
                    line,
                    'BDT'
                );

        System.assertEquals(true, result.isValid);
    }

    @IsTest
    static void lowercaseStoredCurrencyFailsEvenThoughItCanBeNormalized() {
        Journal_Entry_Line__c line =
            new Journal_Entry_Line__c(
                Debit_Base__c = 100,
                Credit_Base__c = 0,
                Transaction_Currency__c = 'usd',
                Transaction_Amount__c = 1,
                Functional_Currency__c = 'BDT',
                Applied_Exchange_Rate__c = 100,
                Rate_Date__c =
                    Date.newInstance(2026, 9, 24),
                Rate_Source__c = 'Provider'
            );

        SABCurrencyGuardService.ValidationResult result =
            SABCurrencyGuardService.validateJournalLineSnapshot(
                    line,
                    'BDT'
                );

        System.assertEquals(false, result.isValid);
        System.assert(
            String.join(result.errors, ' ').contains('uppercase')
        );
    }

    @IsTest
    static void partialTransactionSnapshotWithoutCurrencyFails() {
        Journal_Entry_Line__c line =
            new Journal_Entry_Line__c(
                Debit_Base__c = 100,
                Credit_Base__c = 0,
                Transaction_Amount__c = 1,
                Functional_Currency__c = 'BDT'
            );

        SABCurrencyGuardService.ValidationResult result =
            SABCurrencyGuardService.validateJournalLineSnapshot(
                    line,
                    'BDT'
                );

        System.assertEquals(false, result.isValid);
        System.assert(
            String.join(result.errors, ' ').contains('Transaction Currency is required')
        );
    }

    @IsTest
    static void differentFunctionalCurrencyFails() {
        Journal_Entry_Line__c line =
            new Journal_Entry_Line__c(
                Debit_Base__c = 100,
                Credit_Base__c = 0,
                Functional_Currency__c = 'USD'
            );

        SABCurrencyGuardService.ValidationResult result =
            SABCurrencyGuardService.validateJournalLineSnapshot(
                    line,
                    'BDT'
                );

        System.assertEquals(false, result.isValid);
        System.assert(
            String.join(result.errors, ' ').contains('Accounting Company')
        );
    }

    @IsTest
    static void roundingDifferenceNeedsConfiguredAccount() {
        Accounting_Company__c company =
            makeCompany(
                'C1',
                'Currency Company One'
            );

        // Zero difference does not require a rounding account.
        SABCurrencyGuardService.assertRoundingConfiguration(
                company.Id,
                0
            );

        Boolean thrown = false;

        try {
            SABCurrencyGuardService.assertRoundingConfiguration(
                    company.Id,
                    Decimal.valueOf('0.0001')
                );
        } catch (
            SABCurrencyGuardService.CurrencyGuardException ex
        ) {
            thrown = true;
        }

        System.assertEquals(true, thrown);

        GL_Account__c roundingAccount =
            makeGLAccount(
                company.Id,
                '9997'
            );

        company.Default_Rounding_Account__c =
            roundingAccount.Id;
        update company;

        SABCurrencyGuardService.assertRoundingConfiguration(
                company.Id,
                Decimal.valueOf('0.0001')
            );
    }

    @IsTest
    static void journalValidationUsesCurrencyGuard() {
        User u = makeUser();

        Accounting_Company__c company =
            makeCompany(
                'C2',
                'Currency Company Two'
            );

        Accounting_Period__c period =
            new Accounting_Period__c(
                Name = 'Sep 2026',
                Company__c = company.Id,
                Company_Period_Key__c = 'CP-C2-09',
                Period_Key__c = 'P-C2-09',
                Start_Date__c =
                    Date.newInstance(2026, 9, 1),
                End_Date__c =
                    Date.newInstance(2026, 9, 30),
                Fiscal_Year__c = 2026,
                Fiscal_Quarter__c = 3,
                Period_Number__c = 9,
                Status__c = 'Open'
            );
        insert period;

        GL_Account__c debitAccount =
            makeGLAccount(
                company.Id,
                '6101'
            );

        GL_Account__c creditAccount =
            makeGLAccount(
                company.Id,
                '1101'
            );

        Journal_Entry__c journal =
            new Journal_Entry__c(
                Company__c = company.Id,
                Accounting_Period__c = period.Id,
                Accounting_Date__c =
                    Date.newInstance(2026, 9, 24),
                Entry_Type__c = 'Manual',
                Status__c = 'Draft',
                Description__c =
                    'Currency guard integration test',
                Version__c = 1
            );
        insert journal;

        insert new List<Journal_Entry_Line__c>{
            new Journal_Entry_Line__c(
                Journal_Entry__c = journal.Id,
                GL_Account__c = debitAccount.Id,
                Line_Number__c = 1,
                Debit_Base__c = 122.25,
                Credit_Base__c = 0,
                Transaction_Currency__c = 'USD',
                Transaction_Amount__c = 1,
                Functional_Currency__c = 'BDT',
                Applied_Exchange_Rate__c = 122.25
                // Missing Rate_Date__c and Rate_Source__c intentionally.
            ),
            new Journal_Entry_Line__c(
                Journal_Entry__c = journal.Id,
                GL_Account__c = creditAccount.Id,
                Line_Number__c = 2,
                Debit_Base__c = 0,
                Credit_Base__c = 122.25,
                Functional_Currency__c = 'BDT'
            )
        };

        insert new Company_User_Access__c(
            Company__c = company.Id,
            User__c = u.Id,
            Effective_From__c = Date.today(),
            Grant_Key__c = 'CURR-GRANT',
            Is_Active__c = true,
            Role__c = 'Bookkeeper'
        );

        System.runAs(u) {
            SABJournalValidationService.ValidationResult result =
                SABJournalValidationService.validateForPosting(
                        journal.Id
                    );

            String errors =
                String.join(result.errors, ' ');

            System.assertEquals(false, result.isValid);
            System.assert(
                errors.contains('Rate Date')
            );
            System.assert(
                errors.contains('Rate Source')
            );
        }
    }

    @IsTest
    static void exchangeRateAndMoneyServicesWorkTogether() {
        Datetime asOf =
            Datetime.newInstance(
                2026, 9, 24,
                10, 0, 0
            );

        insert new Exchange_Rate__c(
            Rate_Key__c = 'USD-BDT-4C',
            From_Currency__c = 'USD',
            To_Currency__c = 'BDT',
            Rate_Type__c = 'Spot',
            Effective_Date_Time__c =
                asOf.addMinutes(-1),
            Rate__c =
                Decimal.valueOf('122.2500000000'),
            Source__c = 'Step 4C Provider',
            Approved__c = true,
            Approved_By__c =
                UserInfo.getUserId()
        );

        SABExchangeRateService.RateRequest request =
            new SABExchangeRateService.RateRequest();

        request.fromCurrency = 'USD';
        request.toCurrency = 'BDT';
        request.rateType = 'Spot';
        request.effectiveAt = asOf;

        SABExchangeRateService.ConversionSnapshot conversion =
            SABExchangeRateService.convertUsingApprovedRate(
                    Decimal.valueOf('2'),
                    request,
                    RoundingMode.HALF_UP
                );

        System.assertEquals(
            Decimal.valueOf('244.5000'),
            conversion.money.functionalAmount
        );

        System.assertEquals(
            'Step 4C Provider',
            conversion.rateSnapshot.source
        );
    }

    private static User makeUser() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String uniqueValue =
            'sabcurrency.'
            + String.valueOf(
                DateTime.now().getTime()
            );

        User u = new User(
            Alias = 'sabcur',
            Email =
                uniqueValue + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Currency Guard User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username =
                uniqueValue + '@example.test'
        );

        insert u;
        return u;
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

    private static GL_Account__c makeGLAccount(
        Id companyId,
        String accountCode
    ) {
        GL_Account__c account =
            new GL_Account__c(
                Name =
                    'Account ' + accountCode,
                Company__c = companyId,
                Company_Account_Key__c =
                    String.valueOf(companyId)
                    + '-'
                    + accountCode,
                Account_Code__c = accountCode,
                Account_Type__c = 'Expense',
                Normal_Balance__c = 'Debit',
                Is_Active__c = true,
                Is_Control_Account__c = false,
                Control_Type__c = 'None',
                Manual_Posting_Allowed__c = true
            );

        insert account;
        return account;
    }
}
