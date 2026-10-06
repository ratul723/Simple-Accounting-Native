@IsTest
private class SABPayrollRuleEngineTest {

    // Custom metadata cannot be inserted in tests; build in-memory rule rows instead.
    private static SAB_Statutory_Rule__mdt rule(String key, String method, String extraJson) {
        String body = '{"Rule_Key__c":"' + key + '","Rule_Version__c":"2026.1","Method__c":"' + method + '",'
            + '"Is_Active__c":true,"Effective_From__c":"2026-01-01"' + (String.isBlank(extraJson) ? '' : ',' + extraJson) + '}';
        return (SAB_Statutory_Rule__mdt) JSON.deserialize(body, SAB_Statutory_Rule__mdt.class);
    }

    private static String failure(String formulaJson) {
        try {
            SABPayrollRuleEngine.parseFormula(formulaJson);
        } catch (SABPayrollRuleEngine.RuleException ex) {
            return ex.getMessage();
        }
        return null;
    }

    private static String ruleFailure(SAB_Statutory_Rule__mdt row) {
        try {
            SABPayrollRuleEngine.toRule(row);
        } catch (SABPayrollRuleEngine.RuleException ex) {
            return ex.getMessage();
        }
        return null;
    }

    private static Boolean matches(String message, String fragment) {
        return message != null && message.contains(fragment);
    }

    private static void expect(String message, String fragment) {
        System.assert(matches(message, fragment), 'Expected "' + fragment + '" but got: ' + message);
    }

    private static User runner() {
        return new User(Id = UserInfo.getUserId());
    }

    @IsTest
    static void prorationUsesInclusiveCalendarDays() {
        System.runAs(runner()) {
            Date starts = Date.newInstance(2026, 10, 1);
            Date ends = Date.newInstance(2026, 10, 31);
            System.assertEquals(31, SABPayrollRuleEngine.periodDays(starts, ends), 'October has 31 days.');
            SABPayrollRuleEngine.Window w = SABPayrollRuleEngine.overlap(starts, ends, Date.newInstance(2026, 10, 17), null);
            System.assertEquals(15, w.days, 'Oct 17 to Oct 31 is 15 inclusive days.');
            System.assertEquals(Date.newInstance(2026, 10, 17), w.startDate, 'Window starts at the later start.');
            System.assertEquals(null, SABPayrollRuleEngine.overlap(starts, ends, Date.newInstance(2026, 11, 1), null), 'No overlap.');
            System.assertEquals(5, SABPayrollRuleEngine.overlap(starts, null, Date.newInstance(2025, 1, 1), Date.newInstance(2026, 10, 5)).days,
                'Open-ended first range is bounded by the second.');
            System.assertEquals(31000, SABPayrollRuleEngine.prorate(31000, 31, 31), 'Full period is unchanged.');
            System.assertEquals(15000, SABPayrollRuleEngine.prorate(31000, 15, 31), '15 of 31 days.');
            for (List<Object> bad : new List<List<Object>>{new List<Object>{null, 1, 31}, new List<Object>{100, 32, 31},
                    new List<Object>{100, -1, 31}, new List<Object>{100, 1, 0}}) {
                String message;
                try {
                    SABPayrollRuleEngine.prorate((Decimal) bad[0], (Integer) bad[1], (Integer) bad[2]);
                } catch (SABPayrollRuleEngine.RuleException ex) {
                    message = ex.getMessage();
                }
                expect(message, 'Proration inputs');
            }
            String missingStart;
            try {
                SABPayrollRuleEngine.overlap(null, ends, starts, ends);
            } catch (SABPayrollRuleEngine.RuleException ex) {
                missingStart = ex.getMessage();
            }
            expect(missingStart, 'start dates');
        }
    }

    @IsTest
    static void parsesAndEvaluatesSupportedFormulas() {
        System.runAs(runner()) {
            Map<String, Decimal> fixedTotals = new Map<String, Decimal>{'Basic Salary' => 31000, 'Food Allowance' => 500};
            SABPayrollRuleEngine.Formula house = SABPayrollRuleEngine.parseFormula('{"type":"PERCENT_OF","percent":40,"basis":["Basic Salary"]}');
            System.assertEquals(12400, SABPayrollRuleEngine.evaluateFormula(house, null, fixedTotals, 31, 31), '40% of basic.');
            SABPayrollRuleEngine.Formula capped = SABPayrollRuleEngine.parseFormula(
                '{"type":"PERCENT_OF","percent":50,"basis":["Basic Salary","Food Allowance","Incentive"],"cap":10000}');
            System.assertEquals(10000, SABPayrollRuleEngine.evaluateFormula(capped, null, fixedTotals, 31, 31), 'Cap applies.');
            SABPayrollRuleEngine.Formula daily = SABPayrollRuleEngine.parseFormula('{"type":"DAILY_RATE","rate":50,"floor":1000}');
            System.assertEquals(1550, SABPayrollRuleEngine.evaluateFormula(daily, null, fixedTotals, 31, 31), 'Rate times days.');
            System.assertEquals(1000, SABPayrollRuleEngine.evaluateFormula(daily, null, fixedTotals, 10, 31), 'Floor applies.');
            SABPayrollRuleEngine.Formula flat = SABPayrollRuleEngine.parseFormula('{"type":"FIXED","prorate":false}');
            System.assertEquals(300, SABPayrollRuleEngine.evaluateFormula(flat, 300, fixedTotals, 15, 31), 'Not prorated.');
            SABPayrollRuleEngine.Formula prorated = SABPayrollRuleEngine.parseFormula('{"type":"FIXED","prorate":true}');
            System.assertEquals(150, SABPayrollRuleEngine.evaluateFormula(prorated, 310, fixedTotals, 15, 31), 'Prorated.');
            String noAmount;
            try {
                SABPayrollRuleEngine.evaluateFormula(flat, null, fixedTotals, 31, 31);
            } catch (SABPayrollRuleEngine.RuleException ex) {
                noAmount = ex.getMessage();
            }
            expect(noAmount, 'non-negative amount');
        }
    }

    @IsTest
    static void rejectsInvalidFormulas() {
        System.runAs(runner()) {
            System.assert(matches(failure('not json'), 'JSON object'), 'Expected ' + 'JSON object');
            System.assert(matches(failure('[1,2]'), 'JSON object'), 'Expected ' + 'JSON object');
            System.assert(matches(failure('{"rate":1}'), 'formula type'), 'Expected ' + 'formula type');
            System.assert(matches(failure('{"type":"BONUS"}'), 'formula type'), 'Expected ' + 'formula type');
            System.assert(matches(failure('{"type":"DAILY_RATE","rate":5,"percent":1}'), 'does not support "percent"'), 'Expected ' + 'does not support "percent"');
            System.assert(matches(failure('{"type":"DAILY_RATE"}'), 'numeric "rate"'), 'Expected ' + 'numeric "rate"');
            System.assert(matches(failure('{"type":"DAILY_RATE","rate":-5}'), 'cannot be negative'), 'Expected ' + 'cannot be negative');
            System.assert(matches(failure('{"type":"DAILY_RATE","rate":"abc"}'), 'must be a number'), 'Expected ' + 'must be a number');
            System.assert(matches(failure('{"type":"PERCENT_OF","percent":1001,"basis":["Basic Salary"]}'), 'exceed 1000'), 'Expected ' + 'exceed 1000');
            System.assert(matches(failure('{"type":"PERCENT_OF","percent":5,"basis":[]}'), 'non-empty basis'), 'Expected ' + 'non-empty basis');
            System.assert(matches(failure('{"type":"PERCENT_OF","percent":5,"basis":["Bonus Pool"]}'), 'valid pay component categories'), 'Expected ' + 'valid pay component categories');
            System.assert(matches(failure('{"type":"FIXED"}'), '"prorate"'), 'Expected ' + '"prorate"');
            System.assert(matches(failure('{"type":"FIXED","prorate":true,"floor":10,"cap":5}'), 'floor cannot exceed'), 'Expected ' + 'floor cannot exceed');
        }
    }

    @IsTest
    static void evaluatesRateCappedAndSlabRules() {
        System.runAs(runner()) {
            Map<String, Decimal> totals = new Map<String, Decimal>{'Basic Salary' => 31000, 'Other' => 13900, 'Incentive' => 2000,
                'Food Allowance' => 1550, 'Deduction' => 999};
            SABPayrollRuleEngine.StatutoryRule pf = SABPayrollRuleEngine.toRule(rule('PF', 'Rate',
                '"Rate_Percent__c":10,"Basis_Categories__c":"Basic Salary"'));
            System.assertEquals(3100, SABPayrollRuleEngine.evaluateStatutory(pf, totals), '10% of basic.');
            SABPayrollRuleEngine.StatutoryRule er = SABPayrollRuleEngine.toRule(rule('ER', 'Capped_Rate',
                '"Rate_Percent__c":10,"Basis_Ceiling__c":25000,"Amount_Cap__c":2000,"Basis_Categories__c":"Basic Salary"'));
            System.assertEquals(2000, SABPayrollRuleEngine.evaluateStatutory(er, totals), 'Ceiling then cap.');
            SABPayrollRuleEngine.StatutoryRule tax = SABPayrollRuleEngine.toRule(rule('TAX', 'Slab',
                '"Bands__c":"[[20000,0],[40000,10],[null,20]]"'));
            System.assertEquals(48450, SABPayrollRuleEngine.statutoryBasis(tax, totals), 'Default basis is all gross categories.');
            System.assertEquals(3690, SABPayrollRuleEngine.evaluateStatutory(tax, totals), '0 + 2,000 + 20% of 8,450.');
            System.assertEquals(0, SABPayrollRuleEngine.evaluateStatutory(tax, new Map<String, Decimal>()), 'Zero basis.');
            System.assertEquals(500, SABPayrollRuleEngine.evaluateStatutory(tax, new Map<String, Decimal>{'Basic Salary' => 25000}),
                'Second band only.');
        }
    }

    @IsTest
    static void rejectsInvalidRuleDefinitions() {
        System.runAs(runner()) {
            System.assert(matches(ruleFailure(rule('A', 'Rate', '"Rate_Percent__c":101')), 'rate between 0 and 100'), 'Expected ' + 'rate between 0 and 100');
            System.assert(matches(ruleFailure(rule('B', 'Rate', null)), 'rate between 0 and 100'), 'Expected ' + 'rate between 0 and 100');
            System.assert(matches(ruleFailure(rule('C', 'Rate', '"Rate_Percent__c":5,"Basis_Categories__c":"Basic Salary;Bonus"')), 'unknown basis category'), 'Expected ' + 'unknown basis category');
            System.assert(matches(ruleFailure(rule('D', 'Slab', '"Bands__c":"[[20000,0],[10000,5],[null,10]]"')), 'bands must ascend'), 'Expected ' + 'bands must ascend');
            System.assert(matches(ruleFailure(rule('E', 'Slab', '"Bands__c":"[[20000,0],[40000,5]]"')), 'bands must ascend'), 'Expected ' + 'bands must ascend');
            System.assert(matches(ruleFailure(rule('F', 'Slab', '"Bands__c":"[[null,101]]"')), 'bands must ascend'), 'Expected ' + 'bands must ascend');
            System.assert(matches(ruleFailure(rule('G', 'Slab', '"Bands__c":"not json"')), 'bands must be'), 'Expected ' + 'bands must be');
            System.assert(matches(ruleFailure(rule('H', 'Slab', '"Bands__c":"[]"')), 'at least one band'), 'Expected ' + 'at least one band');
            SAB_Statutory_Rule__mdt unversioned = (SAB_Statutory_Rule__mdt) JSON.deserialize('{"Rule_Key__c":"I","Method__c":"Rate",'
                + '"Rate_Percent__c":5,"Is_Active__c":true,"Effective_From__c":"2026-01-01"}', SAB_Statutory_Rule__mdt.class);
            System.assert(matches(ruleFailure(unversioned), 'rule version'), 'Expected ' + 'rule version');
            System.assert(matches(ruleFailure(rule('J', 'Flat', null)), 'unsupported method'), 'Expected ' + 'unsupported method');
        }
    }

    @IsTest
    static void selectsExactlyOneEffectiveRule() {
        System.runAs(runner()) {
            Date asOf = Date.newInstance(2026, 10, 31);
            SABPayrollRuleEngine.ruleOverride = new List<SAB_Statutory_Rule__mdt>{
                rule('PF', 'Rate', '"Rate_Percent__c":10,"Country_Code__c":"BD"'),
                rule('PF', 'Rate', '"Rate_Percent__c":12,"Country_Code__c":"IN"'),
                rule('OLD', 'Rate', '"Rate_Percent__c":5,"Effective_To__c":"2026-06-30"'),
                rule('OFF', 'Rate', '"Rate_Percent__c":5,"Is_Active__c":false'),
                rule('DUP', 'Rate', '"Rate_Percent__c":5'),
                rule('DUP', 'Rate', '"Rate_Percent__c":6'),
                rule('ANY', 'Rate', '"Rate_Percent__c":7')};
            System.assertEquals(10, SABPayrollRuleEngine.ruleFor('PF', 'BD', asOf).ratePercent, 'Country-specific rule.');
            System.assertEquals(7, SABPayrollRuleEngine.ruleFor('ANY', 'BD', asOf).ratePercent, 'Blank country applies everywhere.');
            Map<String, String> failures = new Map<String, String>{'OLD' => 'No active statutory rule', 'OFF' => 'No active statutory rule',
                'DUP' => 'More than one', 'MISSING' => 'No active statutory rule'};
            for (String key : failures.keySet()) {
                String message;
                try {
                    SABPayrollRuleEngine.ruleFor(key, 'BD', asOf);
                } catch (SABPayrollRuleEngine.RuleException ex) {
                    message = ex.getMessage();
                }
                expect(message, failures.get(key));
            }
            String wrongCountry;
            try {
                SABPayrollRuleEngine.ruleFor('PF', 'NP', asOf);
            } catch (SABPayrollRuleEngine.RuleException ex) {
                wrongCountry = ex.getMessage();
            }
            expect(wrongCountry, 'for country NP');
            SABPayrollRuleEngine.ruleOverride = null;
            System.assertNotEquals(null, SAB_Statutory_Rule__mdt.getAll(), 'Live custom metadata is readable without overrides.');
        }
    }
}
