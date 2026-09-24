@IsTest
private class SABExchangeRateServiceTest {

    private static Exchange_Rate__c makeRate(
        String keyValue,
        String fromCurrency,
        String toCurrency,
        String rateType,
        Datetime effectiveAt,
        Decimal rate,
        Boolean approved,
        String source
    ) {
        Exchange_Rate__c recordValue =
            new Exchange_Rate__c(
                Rate_Key__c = keyValue,
                From_Currency__c =
                    fromCurrency,
                To_Currency__c =
                    toCurrency,
                Rate_Type__c =
                    rateType,
                Effective_Date_Time__c =
                    effectiveAt,
                Rate__c =
                    rate,
                Source__c =
                    source,
                Approved__c =
                    approved,
                Approved_By__c =
                    approved
                        ? UserInfo.getUserId()
                        : null
            );

        insert recordValue;
        return recordValue;
    }

    private static SABExchangeRateService.RateRequest
        requestFor(
            String fromCurrency,
            String toCurrency,
            String rateType,
            Datetime effectiveAt
        ) {

        SABExchangeRateService.RateRequest request =
            new SABExchangeRateService.RateRequest();

        request.fromCurrency =
            fromCurrency;
        request.toCurrency =
            toCurrency;
        request.rateType =
            rateType;
        request.effectiveAt =
            effectiveAt;

        return request;
    }

    @IsTest
    static void latestApprovedEffectiveRateIsSelected() {
        Datetime asOf =
            Datetime.newInstance(
                2026, 9, 24,
                10, 0, 0
            );

        makeRate(
            'USD-BDT-SPOT-1',
            'USD',
            'BDT',
            'Spot',
            asOf.addDays(-2),
            Decimal.valueOf('121.1000000000'),
            true,
            'Provider A'
        );

        Exchange_Rate__c expected =
            makeRate(
                'USD-BDT-SPOT-2',
                'USD',
                'BDT',
                'Spot',
                asOf.addHours(-1),
                Decimal.valueOf('122.2500000000'),
                true,
                'Provider B'
            );

        // Future approved rate must be ignored.
        makeRate(
            'USD-BDT-SPOT-FUTURE',
            'USD',
            'BDT',
            'Spot',
            asOf.addHours(1),
            Decimal.valueOf('130.0000000000'),
            true,
            'Future Provider'
        );

        // More recent but unapproved rate must be ignored.
        makeRate(
            'USD-BDT-SPOT-DRAFT',
            'USD',
            'BDT',
            'Spot',
            asOf.addMinutes(-10),
            Decimal.valueOf('129.0000000000'),
            false,
            'Draft Provider'
        );

        SABExchangeRateService.RateSnapshot result =
            SABExchangeRateService.selectApprovedRate(
                requestFor(
                    'usd',
                    'bdt',
                    'spot',
                    asOf
                )
            );

        System.assertEquals(
            expected.Id,
            result.exchangeRateId
        );
        System.assertEquals(
            'USD',
            result.fromCurrency
        );
        System.assertEquals(
            'BDT',
            result.toCurrency
        );
        System.assertEquals(
            'Spot',
            result.rateType
        );
        System.assertEquals(
            Decimal.valueOf('122.2500000000'),
            result.rate
        );
        System.assertEquals(
            'Provider B',
            result.source
        );
        System.assertEquals(
            UserInfo.getUserId(),
            result.approvedById
        );
        System.assertEquals(
            false,
            result.synthetic
        );
    }

    @IsTest
    static void rateAtExactEffectiveTimestampIsAllowed() {
        Datetime asOf =
            Datetime.newInstance(
                2026, 9, 24,
                12, 30, 0
            );

        Exchange_Rate__c expected =
            makeRate(
                'EUR-BDT-EXACT',
                'EUR',
                'BDT',
                'Spot',
                asOf,
                Decimal.valueOf('143.5000000000'),
                true,
                'Exact Provider'
            );

        SABExchangeRateService.RateSnapshot result =
            SABExchangeRateService.selectApprovedRate(
                requestFor(
                    'EUR',
                    'BDT',
                    'Spot',
                    asOf
                )
            );

        System.assertEquals(
            expected.Id,
            result.exchangeRateId
        );
    }

    @IsTest
    static void sameCurrencyReturnsSyntheticRateOne() {
        Datetime asOf =
            Datetime.newInstance(
                2026, 9, 24,
                9, 0, 0
            );

        SABExchangeRateService.RateSnapshot result =
            SABExchangeRateService.selectApprovedRate(
                requestFor(
                    'bdt',
                    'BDT',
                    'Spot',
                    asOf
                )
            );

        System.assertEquals(
            null,
            result.exchangeRateId
        );
        System.assertEquals(
            Decimal.valueOf('1.0000000000'),
            result.rate
        );
        System.assertEquals(
            'Same Currency',
            result.source
        );
        System.assertEquals(
            true,
            result.synthetic
        );
    }

    @IsTest
    static void noApprovedRateThrows() {
        Datetime asOf =
            Datetime.newInstance(
                2026, 9, 24,
                10, 0, 0
            );

        makeRate(
            'GBP-BDT-DRAFT',
            'GBP',
            'BDT',
            'Spot',
            asOf.addHours(-1),
            Decimal.valueOf('165.0000000000'),
            false,
            'Draft Provider'
        );

        Boolean thrown = false;

        try {
            SABExchangeRateService.selectApprovedRate(
                requestFor(
                    'GBP',
                    'BDT',
                    'Spot',
                    asOf
                )
            );
        } catch (
            SABExchangeRateService.ExchangeRateException ex
        ) {
            thrown = true;
        }

        System.assertEquals(true, thrown);
    }

    @IsTest
    static void inverseRateIsNotSilentlyUsed() {
        Datetime asOf =
            Datetime.newInstance(
                2026, 9, 24,
                10, 0, 0
            );

        makeRate(
            'BDT-USD-SPOT',
            'BDT',
            'USD',
            'Spot',
            asOf.addHours(-1),
            Decimal.valueOf('0.0081000000'),
            true,
            'Provider'
        );

        Boolean thrown = false;

        try {
            SABExchangeRateService.selectApprovedRate(
                requestFor(
                    'USD',
                    'BDT',
                    'Spot',
                    asOf
                )
            );
        } catch (
            SABExchangeRateService.ExchangeRateException ex
        ) {
            thrown = true;
        }

        System.assertEquals(true, thrown);
    }

    @IsTest
    static void explicitApprovedRateCanBeValidated() {
        Datetime asOf =
            Datetime.newInstance(
                2026, 9, 24,
                11, 0, 0
            );

        Exchange_Rate__c rateRecord =
            makeRate(
                'USD-BDT-SELECTED',
                'USD',
                'BDT',
                'Custom',
                asOf.addMinutes(-30),
                Decimal.valueOf('122.3333333333'),
                true,
                'Treasury Approved'
            );

        SABExchangeRateService.RateSnapshot result =
            SABExchangeRateService.validateApprovedRate(
                rateRecord.Id,
                requestFor(
                    'USD',
                    'BDT',
                    'Custom',
                    asOf
                )
            );

        System.assertEquals(
            rateRecord.Id,
            result.exchangeRateId
        );
        System.assertEquals(
            Decimal.valueOf('122.3333333333'),
            result.rate
        );
        System.assertEquals(
            'Treasury Approved',
            result.source
        );
    }

    @IsTest
    static void unapprovedExplicitRateIsRejected() {
        Datetime asOf =
            Datetime.newInstance(
                2026, 9, 24,
                11, 0, 0
            );

        Exchange_Rate__c rateRecord =
            makeRate(
                'USD-BDT-UNAPPROVED',
                'USD',
                'BDT',
                'Spot',
                asOf.addMinutes(-30),
                Decimal.valueOf('122.0000000000'),
                false,
                'Draft Rate'
            );

        Boolean thrown = false;

        try {
            SABExchangeRateService.validateApprovedRate(
                rateRecord.Id,
                requestFor(
                    'USD',
                    'BDT',
                    'Spot',
                    asOf
                )
            );
        } catch (
            SABExchangeRateService.ExchangeRateException ex
        ) {
            thrown = true;
        }

        System.assertEquals(true, thrown);
    }

    @IsTest
    static void futureExplicitRateIsRejected() {
        Datetime asOf =
            Datetime.newInstance(
                2026, 9, 24,
                11, 0, 0
            );

        Exchange_Rate__c rateRecord =
            makeRate(
                'USD-BDT-FUTURE-SELECTED',
                'USD',
                'BDT',
                'Spot',
                asOf.addHours(2),
                Decimal.valueOf('125.0000000000'),
                true,
                'Future Rate'
            );

        Boolean thrown = false;

        try {
            SABExchangeRateService.validateApprovedRate(
                rateRecord.Id,
                requestFor(
                    'USD',
                    'BDT',
                    'Spot',
                    asOf
                )
            );
        } catch (
            SABExchangeRateService.ExchangeRateException ex
        ) {
            thrown = true;
        }

        System.assertEquals(true, thrown);
    }

    @IsTest
    static void invalidRateTypeIsRejected() {
        Boolean thrown = false;

        try {
            SABExchangeRateService.selectApprovedRate(
                requestFor(
                    'USD',
                    'BDT',
                    'Not A Rate Type',
                    System.now()
                )
            );
        } catch (
            SABExchangeRateService.ExchangeRateException ex
        ) {
            thrown = true;
        }

        System.assertEquals(true, thrown);
    }

    @IsTest
    static void conversionUsesSelectedApprovedRate() {
        Datetime asOf =
            Datetime.newInstance(
                2026, 9, 24,
                10, 0, 0
            );

        makeRate(
            'USD-BDT-CONVERT',
            'USD',
            'BDT',
            'Spot',
            asOf.addMinutes(-5),
            Decimal.valueOf('1.2345678901'),
            true,
            'Conversion Test'
        );

        SABExchangeRateService.ConversionSnapshot result =
            SABExchangeRateService.convertUsingApprovedRate(
                Decimal.valueOf('123.4567'),
                requestFor(
                    'USD',
                    'BDT',
                    'Spot',
                    asOf
                ),
                RoundingMode.HALF_UP
            );

        System.assertEquals(
            Decimal.valueOf('1.2345678901'),
            result.rateSnapshot.rate
        );

        System.assertEquals(
            Decimal.valueOf('152.4157'),
            result.money.functionalAmount
        );
    }

    @IsTest
    static void sameCurrencyConversionUsesSyntheticRate() {
        SABExchangeRateService.ConversionSnapshot result =
            SABExchangeRateService.convertUsingApprovedRate(
                Decimal.valueOf('100.12567'),
                requestFor(
                    'BDT',
                    'BDT',
                    'Spot',
                    System.now()
                ),
                RoundingMode.HALF_UP
            );

        System.assertEquals(
            true,
            result.rateSnapshot.synthetic
        );

        System.assertEquals(
            Decimal.valueOf('100.1257'),
            result.money.functionalAmount
        );
    }
}
