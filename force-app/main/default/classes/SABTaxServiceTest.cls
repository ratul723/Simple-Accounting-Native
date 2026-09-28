@IsTest
private class SABTaxServiceTest {

    @TestSetup
    static void setupFixture() {
        Accounting_Company__c companyA =
            createCompany(
                'Tax Company A',
                'TXA'
            );

        Accounting_Company__c companyB =
            createCompany(
                'Tax Company B',
                'TXB'
            );

        Tax_Code__c standardExclusive =
            new Tax_Code__c(
                Name =
                    'VAT 15 Exclusive',
                Code__c =
                    'VAT15',
                Company__c =
                    companyA.Id,
                Inclusive__c =
                    false,
                Is_Active__c =
                    true,
                Jurisdiction__c =
                    'BD',
                Recoverability__c =
                    'Full',
                Treatment__c =
                    'Standard'
            );

        Tax_Code__c standardInclusive =
            new Tax_Code__c(
                Name =
                    'VAT 15 Inclusive',
                Code__c =
                    'VAT15I',
                Company__c =
                    companyA.Id,
                Inclusive__c =
                    true,
                Is_Active__c =
                    true,
                Jurisdiction__c =
                    'BD',
                Recoverability__c =
                    'None',
                Treatment__c =
                    'Standard'
            );

        Tax_Code__c partialPurchase =
            new Tax_Code__c(
                Name =
                    'Purchase VAT Partial',
                Code__c =
                    'PVAT10',
                Company__c =
                    companyA.Id,
                Inclusive__c =
                    false,
                Is_Active__c =
                    true,
                Jurisdiction__c =
                    'BD',
                Recoverability__c =
                    'Partial',
                Treatment__c =
                    'Standard'
            );

        Tax_Code__c zeroCode =
            new Tax_Code__c(
                Name =
                    'Zero Rated',
                Code__c =
                    'ZERO',
                Company__c =
                    companyA.Id,
                Inclusive__c =
                    false,
                Is_Active__c =
                    true,
                Jurisdiction__c =
                    'BD',
                Recoverability__c =
                    'None',
                Treatment__c =
                    'Zero'
            );

        Tax_Code__c unsupportedCode =
            new Tax_Code__c(
                Name =
                    'Reverse Charge',
                Code__c =
                    'RC',
                Company__c =
                    companyA.Id,
                Inclusive__c =
                    false,
                Is_Active__c =
                    true,
                Jurisdiction__c =
                    'BD',
                Recoverability__c =
                    'None',
                Treatment__c =
                    'Reverse Charge',
                Supported_Rule_Key__c =
                    'BD-RC'
            );

        Tax_Code__c wrongCompanyCode =
            new Tax_Code__c(
                Name =
                    'Other Company VAT',
                Code__c =
                    'OTHER15',
                Company__c =
                    companyB.Id,
                Inclusive__c =
                    false,
                Is_Active__c =
                    true,
                Jurisdiction__c =
                    'BD',
                Recoverability__c =
                    'None',
                Treatment__c =
                    'Standard'
            );

        insert new List<Tax_Code__c>{
            standardExclusive,
            standardInclusive,
            partialPurchase,
            zeroCode,
            unsupportedCode,
            wrongCompanyCode
        };

        insert new List<Tax_Rate__c>{
            taxRate(
                standardExclusive.Id,
                'VAT15-2026',
                15,
                null,
                Date.newInstance(
                    2026,
                    1,
                    1
                ),
                null
            ),
            taxRate(
                standardInclusive.Id,
                'VAT15I-2026',
                15,
                null,
                Date.newInstance(
                    2026,
                    1,
                    1
                ),
                null
            ),
            taxRate(
                partialPurchase.Id,
                'PVAT10-2026',
                10,
                60,
                Date.newInstance(
                    2026,
                    1,
                    1
                ),
                null
            ),
            taxRate(
                zeroCode.Id,
                'ZERO-2026',
                0,
                null,
                Date.newInstance(
                    2026,
                    1,
                    1
                ),
                null
            ),
            taxRate(
                unsupportedCode.Id,
                'RC-2026',
                15,
                null,
                Date.newInstance(
                    2026,
                    1,
                    1
                ),
                null
            ),
            taxRate(
                wrongCompanyCode.Id,
                'OTHER15-2026',
                15,
                null,
                Date.newInstance(
                    2026,
                    1,
                    1
                ),
                null
            )
        };
    }

    @IsTest
    static void exclusiveSalesTaxCalculatesCorrectly() {
        Accounting_Company__c company =
            companyByKey(
                'TXA'
            );

        Tax_Code__c code =
            taxCodeByCode(
                'VAT15'
            );

        SABTaxService.TaxRequest request =
            request(
                company.Id,
                code.Id,
                1000,
                SABTaxService.SIDE_SALES
            );

        Test.startTest();

        SABTaxService.TaxSnapshot result =
            SABTaxService.calculate(
                request
            );

        Test.stopTest();

        System.assertEquals(
            Decimal.valueOf(
                '1000.0000'
            ),
            result.taxableBase
        );

        System.assertEquals(
            Decimal.valueOf(
                '150.0000'
            ),
            result.taxAmount
        );

        System.assertEquals(
            Decimal.valueOf(
                '1150.0000'
            ),
            result.grossAmount
        );

        System.assertEquals(
            Decimal.valueOf(
                '0.0000'
            ),
            result.recoverableAmount
        );

        System.assertEquals(
            'VAT15',
            result.taxCodeKey
        );
    }

    @IsTest
    static void inclusiveTaxSeparatesBaseAndTax() {
        Accounting_Company__c company =
            companyByKey(
                'TXA'
            );

        Tax_Code__c code =
            taxCodeByCode(
                'VAT15I'
            );

        SABTaxService.TaxRequest request =
            request(
                company.Id,
                code.Id,
                1150,
                SABTaxService.SIDE_SALES
            );

        SABTaxService.TaxSnapshot result =
            SABTaxService.calculate(
                request
            );

        System.assertEquals(
            Decimal.valueOf(
                '1000.0000'
            ),
            result.taxableBase
        );

        System.assertEquals(
            Decimal.valueOf(
                '150.0000'
            ),
            result.taxAmount
        );

        System.assertEquals(
            Decimal.valueOf(
                '1150.0000'
            ),
            result.grossAmount
        );
    }

    @IsTest
    static void partialPurchaseRecoverabilityCalculates() {
        Accounting_Company__c company =
            companyByKey(
                'TXA'
            );

        Tax_Code__c code =
            taxCodeByCode(
                'PVAT10'
            );

        SABTaxService.TaxSnapshot result =
            SABTaxService.calculate(
                request(
                    company.Id,
                    code.Id,
                    100,
                    SABTaxService.SIDE_PURCHASE
                )
            );

        System.assertEquals(
            Decimal.valueOf(
                '10.0000'
            ),
            result.taxAmount
        );

        System.assertEquals(
            Decimal.valueOf(
                '60'
            ),
            result.recoverablePercent
        );

        System.assertEquals(
            Decimal.valueOf(
                '6.0000'
            ),
            result.recoverableAmount
        );

        System.assertEquals(
            Decimal.valueOf(
                '4.0000'
            ),
            result.nonrecoverableAmount
        );
    }

    @IsTest
    static void zeroRateProducesNoTax() {
        Accounting_Company__c company =
            companyByKey(
                'TXA'
            );

        Tax_Code__c code =
            taxCodeByCode(
                'ZERO'
            );

        SABTaxService.TaxSnapshot result =
            SABTaxService.calculate(
                request(
                    company.Id,
                    code.Id,
                    500,
                    SABTaxService.SIDE_SALES
                )
            );

        System.assertEquals(
            Decimal.valueOf(
                '0.0000'
            ),
            result.taxAmount
        );

        System.assertEquals(
            Decimal.valueOf(
                '500.0000'
            ),
            result.grossAmount
        );
    }

    @IsTest
    static void crossCompanyTaxCodeIsBlocked() {
        Accounting_Company__c company =
            companyByKey(
                'TXA'
            );

        Tax_Code__c code =
            taxCodeByCode(
                'OTHER15'
            );

        Boolean blocked =
            false;

        try {
            SABTaxService.calculate(
                request(
                    company.Id,
                    code.Id,
                    100,
                    SABTaxService.SIDE_SALES
                )
            );
        } catch (
            SABTaxService.TaxException ex
        ) {
            blocked =
                ex.getMessage().contains(
                    'same Accounting Company'
                );
        }

        System.assertEquals(
            true,
            blocked
        );
    }

    @IsTest
    static void unsupportedCountryTreatmentIsBlocked() {
        Accounting_Company__c company =
            companyByKey(
                'TXA'
            );

        Tax_Code__c code =
            taxCodeByCode(
                'RC'
            );

        Boolean blocked =
            false;

        try {
            SABTaxService.calculate(
                request(
                    company.Id,
                    code.Id,
                    100,
                    SABTaxService.SIDE_SALES
                )
            );
        } catch (
            SABTaxService.TaxException ex
        ) {
            blocked =
                ex.getMessage().contains(
                    'country-specific'
                );
        }

        System.assertEquals(
            true,
            blocked
        );
    }

    @IsTest
    static void latestEffectiveRateIsSelected() {
        Tax_Code__c code =
            taxCodeByCode(
                'VAT15'
            );

        Tax_Rate__c oldRate =
            [
                SELECT Id,
                       Effective_To__c
                FROM Tax_Rate__c
                WHERE Tax_Code__c =
                    :code.Id
                LIMIT 1
            ];

        oldRate.Effective_To__c =
            Date.newInstance(
                2026,
                6,
                30
            );
        update oldRate;

        insert taxRate(
            code.Id,
            'VAT15-H2-2026',
            18,
            null,
            Date.newInstance(
                2026,
                7,
                1
            ),
            null
        );

        Accounting_Company__c company =
            companyByKey(
                'TXA'
            );

        SABTaxService.TaxRequest request =
            request(
                company.Id,
                code.Id,
                100,
                SABTaxService.SIDE_SALES
            );

        request.taxDate =
            Date.newInstance(
                2026,
                9,
                28
            );

        SABTaxService.TaxSnapshot result =
            SABTaxService.calculate(
                request
            );

        System.assertEquals(
            Decimal.valueOf(
                '18'
            ),
            result.taxRatePercent
        );

        System.assertEquals(
            Decimal.valueOf(
                '18.0000'
            ),
            result.taxAmount
        );
    }

    private static SABTaxService.TaxRequest request(
        Id companyId,
        Id taxCodeId,
        Decimal amount,
        String side
    ) {
        SABTaxService.TaxRequest request =
            new SABTaxService.TaxRequest();

        request.companyId =
            companyId;
        request.taxCodeId =
            taxCodeId;
        request.taxDate =
            Date.newInstance(
                2026,
                9,
                28
            );
        request.lineAmount =
            amount;
        request.documentSide =
            side;
        request.roundingMode =
            RoundingMode.HALF_UP;

        return request;
    }

    private static Tax_Rate__c taxRate(
        Id taxCodeId,
        String rateKey,
        Decimal rate,
        Decimal recoverablePercent,
        Date effectiveFrom,
        Date effectiveTo
    ) {
        return new Tax_Rate__c(
            Tax_Code__c =
                taxCodeId,
            Rate_Key__c =
                rateKey,
            Rate__c =
                rate,
            Recoverable_Percent__c =
                recoverablePercent,
            Country_Pack_Version__c =
                'GENERIC-1',
            Effective_From__c =
                effectiveFrom,
            Effective_To__c =
                effectiveTo
        );
    }

    private static Accounting_Company__c createCompany(
        String companyName,
        String companyKey
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    companyName,
                Company_Key__c =
                    companyKey,
                Country_Code__c =
                    'BD',
                Functional_Currency__c =
                    'BDT',
                Fiscal_Calendar_Type__c =
                    'Calendar',
                Fiscal_Year_Start_Month__c =
                    1,
                Setup_Status__c =
                    'Active',
                Is_Active__c =
                    true
            );

        insert company;

        return company;
    }

    private static Accounting_Company__c companyByKey(
        String companyKey
    ) {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c =
                :companyKey
            LIMIT 1
        ];
    }

    private static Tax_Code__c taxCodeByCode(
        String code
    ) {
        return [
            SELECT Id
            FROM Tax_Code__c
            WHERE Code__c =
                :code
            LIMIT 1
        ];
    }
}
