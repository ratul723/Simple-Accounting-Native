@IsTest
private class SABMoneyServiceTest {

    @IsTest
    static void deployedPrecisionContractIsUsed() {
        System.assertEquals(
            4,
            SABMoneyService.ledgerScale()
        );

        System.assertEquals(
            4,
            SABMoneyService.transactionScale()
        );

        System.assertEquals(
            10,
            SABMoneyService.exchangeRateScale()
        );
    }

    @IsTest
    static void currencyCodeIsNormalized() {
        System.assertEquals(
            'BDT',
            SABMoneyService.normalizeCurrencyCode(
                ' bdt '
            )
        );

        System.assertEquals(
            'USD',
            SABMoneyService.normalizeCurrencyCode(
                'usd'
            )
        );
    }

    @IsTest
    static void invalidCurrencyCodeIsRejected() {
        for (
            String badCode :
            new List<String>{
                null,
                '',
                'US',
                'USDD',
                '12A'
            }
        ) {
            Boolean thrown = false;

            try {
                SABMoneyService.normalizeCurrencyCode(
                    badCode
                );
            } catch (
                SABMoneyService.MoneyException ex
            ) {
                thrown = true;
            }

            System.assertEquals(
                true,
                thrown,
                'Invalid code should fail: '
                    + String.valueOf(badCode)
            );
        }
    }

    @IsTest
    static void zeroTwoAndThreeMinorUnitsAreSupported() {
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
    static void transactionAndLedgerAmountsUseFourDecimals() {
        System.assertEquals(
            Decimal.valueOf('12.3457'),
            SABMoneyService.normalizeTransactionAmount(
                Decimal.valueOf('12.34567'),
                RoundingMode.HALF_UP
            )
        );

        System.assertEquals(
            Decimal.valueOf('12.3457'),
            SABMoneyService.normalizeLedgerAmount(
                Decimal.valueOf('12.34567'),
                RoundingMode.HALF_UP
            )
        );
    }

    @IsTest
    static void exchangeRateUsesTenDecimals() {
        System.assertEquals(
            Decimal.valueOf('1.2345678901'),
            SABMoneyService.normalizeExchangeRate(
                Decimal.valueOf(
                    '1.23456789014'
                ),
                RoundingMode.HALF_UP
            )
        );
    }

    @IsTest
    static void sameCurrencyUsesRateOne() {
        SABMoneyService.ConversionResult result =
            SABMoneyService.convertToFunctional(
                Decimal.valueOf('100.12567'),
                'BDT',
                'bdt',
                null,
                RoundingMode.HALF_UP
            );

        System.assertEquals(
            'BDT',
            result.transactionCurrency
        );
        System.assertEquals(
            'BDT',
            result.functionalCurrency
        );
        System.assertEquals(
            Decimal.valueOf('100.1257'),
            result.transactionAmount
        );
        System.assertEquals(
            Decimal.valueOf('1.0000000000'),
            result.appliedExchangeRate
        );
        System.assertEquals(
            Decimal.valueOf('100.1257'),
            result.functionalAmount
        );
    }

    @IsTest
    static void sameCurrencyNonOneRateIsRejected() {
        Boolean thrown = false;

        try {
            SABMoneyService.convertToFunctional(
                Decimal.valueOf('100'),
                'BDT',
                'BDT',
                Decimal.valueOf('1.01'),
                RoundingMode.HALF_UP
            );
        } catch (
            SABMoneyService.MoneyException ex
        ) {
            thrown = true;
        }

        System.assertEquals(true, thrown);
    }

    @IsTest
    static void foreignCurrencyConversionPreservesRatePrecision() {
        SABMoneyService.ConversionResult result =
            SABMoneyService.convertToFunctional(
                Decimal.valueOf('123.4567'),
                'USD',
                'BDT',
                Decimal.valueOf('1.2345678901'),
                RoundingMode.HALF_UP
            );

        System.assertEquals(
            Decimal.valueOf('123.4567'),
            result.transactionAmount
        );
        System.assertEquals(
            Decimal.valueOf('1.2345678901'),
            result.appliedExchangeRate
        );
        System.assertEquals(
            Decimal.valueOf('152.4157'),
            result.functionalAmount
        );
    }

    @IsTest
    static void negativeCreditOrRefundAmountsAreAllowed() {
        SABMoneyService.ConversionResult result =
            SABMoneyService.convertToFunctional(
                Decimal.valueOf('-100.125'),
                'USD',
                'BDT',
                Decimal.valueOf('1.2'),
                RoundingMode.HALF_UP
            );

        System.assertEquals(
            Decimal.valueOf('-100.1250'),
            result.transactionAmount
        );

        System.assertEquals(
            Decimal.valueOf('-120.1500'),
            result.functionalAmount
        );
    }

    @IsTest
    static void foreignCurrencyRequiresPositiveRate() {
        for (
            Decimal invalidRate :
            new List<Decimal>{
                null,
                Decimal.valueOf('0'),
                Decimal.valueOf('-1')
            }
        ) {
            Boolean thrown = false;

            try {
                SABMoneyService.convertToFunctional(
                    Decimal.valueOf('10'),
                    'USD',
                    'BDT',
                    invalidRate,
                    RoundingMode.HALF_UP
                );
            } catch (
                SABMoneyService.MoneyException ex
            ) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }
    }

    @IsTest
    static void ledgerComparisonUsesStoragePrecision() {
        System.assertEquals(
            true,
            SABMoneyService.ledgerAmountsEqual(
                Decimal.valueOf('100.12344'),
                Decimal.valueOf('100.12343'),
                RoundingMode.HALF_UP
            )
        );

        System.assertEquals(
            false,
            SABMoneyService.ledgerAmountsEqual(
                Decimal.valueOf('100.12345'),
                Decimal.valueOf('100.12344'),
                RoundingMode.HALF_UP
            )
        );
    }

    @IsTest
    static void roundingDifferenceIsLedgerNormalized() {
        System.assertEquals(
            Decimal.valueOf('0.0001'),
            SABMoneyService.roundingDifference(
                Decimal.valueOf('100.00006'),
                Decimal.valueOf('100.00000'),
                RoundingMode.HALF_UP
            )
        );
    }

    @IsTest
    static void invalidMinorUnitsAreRejected() {
        for (
            Integer units :
            new List<Integer>{ -1, 4 }
        ) {
            Boolean thrown = false;

            try {
                SABMoneyService.roundForMinorUnits(
                    Decimal.valueOf('10'),
                    units,
                    RoundingMode.HALF_UP
                );
            } catch (
                SABMoneyService.MoneyException ex
            ) {
                thrown = true;
            }

            System.assertEquals(true, thrown);
        }
    }

    @IsTest
    static void roundingAccountMustBelongToSameCompany() {
        Accounting_Company__c companyA =
            makeCompany(
                'M1',
                'Money Company One'
            );

        Accounting_Company__c companyB =
            makeCompany(
                'M2',
                'Money Company Two'
            );

        GL_Account__c roundingAccountA =
            makeGLAccount(
                companyA.Id,
                '9998'
            );

        companyA.Default_Rounding_Account__c =
            roundingAccountA.Id;
        update companyA;

        // Real persisted valid configuration passes.
        SABMoneyService.assertRoundingAccountBelongsToCompany(
            companyA
        );

        // The org validation rule already prevents persisting a cross-company
        // Default_Rounding_Account__c. Test the service's defense-in-depth
        // comparison directly without trying to save invalid Salesforce data.
        Boolean thrown = false;

        try {
            SABMoneyService.assertSameCompany(
                companyA.Id,
                companyB.Id
            );
        } catch (
            SABMoneyService.MoneyException ex
        ) {
            thrown = true;

            System.assert(
                ex.getMessage().contains(
                    'same Accounting Company'
                )
            );
        }

        System.assertEquals(
            true,
            thrown
        );
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
                Name = 'Rounding Account '
                    + accountCode,
                Company__c = companyId,
                Company_Account_Key__c =
                    String.valueOf(companyId)
                    + '-'
                    + accountCode,
                Account_Code__c =
                    accountCode,
                Account_Type__c =
                    'Expense',
                Normal_Balance__c =
                    'Debit',
                Is_Active__c =
                    true,
                Is_Control_Account__c =
                    false,
                Control_Type__c =
                    'None',
                Manual_Posting_Allowed__c =
                    true
            );

        insert account;
        return account;
    }
}
