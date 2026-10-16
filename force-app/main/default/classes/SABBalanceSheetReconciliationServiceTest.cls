@IsTest
private class SABBalanceSheetReconciliationServiceTest {

    @TestSetup
    static void setupData() {
        SABAppShellTestFixture.seed();
        SABTestGovernor.assertSetupWithin(50);
    }

    @IsTest
    static void sectionsReconcileLedgerToSources() {
        Id companyId = SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
        SABBalanceSheetReconciliationService.Reconciliation r;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            r = SABBalanceSheetReconciliationService.getReconciliation(companyId, Date.today());
            Test.stopTest();
        }
        Map<String, SABBalanceSheetReconciliationService.Section> byKey = new Map<String, SABBalanceSheetReconciliationService.Section>();
        for (SABBalanceSheetReconciliationService.Section s : r.sections) {
            byKey.put(s.key, s);
        }
        System.assertEquals(10, r.sections.size(), 'Every section is listed.');
        System.assertEquals('Dependency', byKey.get('inventory').status, 'Inventory needs a module.');
        System.assertEquals(1, byKey.get('cash').accounts.size(), 'The bank GL account belongs to cash.');
        System.assertEquals(0, byKey.get('cash').ledger, 'Nothing posted yet.');
        System.assertNotEquals(null, byKey.get('ar').status, 'Receivables are compared or reported as unavailable.');
        System.assertEquals('Ledger only', byKey.get('tax').status, 'Tax is reviewed, not matched.');
        System.assertEquals(Date.today(), r.asOfDate, 'Reporting date.');
        System.assert(new Set<String>{ 'Ledger only', 'Not available', 'Agreed', 'Difference' }.contains(byKey.get('loans').status),
            'Loans are reconciled, or reported as unavailable when loan fields cannot be read.');
    }

    @IsTest
    static void companyAccessIsRequired() {
        String message;
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            try {
                SABBalanceSheetReconciliationService.getReconciliation(null, null);
            } catch (AuraHandledException ex) {
                message = ex.getMessage();
            }
            Test.stopTest();
        }
        System.assertEquals('You do not have active access to this Accounting Company.', message, 'Grant required.');
    }
}
