@IsTest
private class SABConsolidationServiceTest {

    @TestSetup
    static void setupData() {
        SABGroupAccountingTestFixture.createFixture();
        System.runAs(SABGroupAccountingTestFixture.user(SABGroupAccountingTestFixture.MANAGER)) {
            SABGroupAccountingTestFixture.seedIntercompany();
        }
    }

    private static Map<String, SABConsolidationService.TrialBalanceRow> rows(SABConsolidationService.TrialBalance tb) {
        Map<String, SABConsolidationService.TrialBalanceRow> result = new Map<String, SABConsolidationService.TrialBalanceRow>();
        for (SABConsolidationService.TrialBalanceRow r : tb.rows) {
            result.put(r.accountCode, r);
        }
        return result;
    }

    @IsTest
    static void eliminatesIntercompanyThenApprovesAndPublishes() {
        SABConsolidationService.ActionResult calculated;
        SABConsolidationService.TrialBalance tb;
        SABConsolidationService.ActionResult approved;
        SABConsolidationService.ActionResult published;
        SABTestGovernor.startTest();
        System.runAs(SABGroupAccountingTestFixture.user(SABGroupAccountingTestFixture.MANAGER)) {
            calculated = SABConsolidationService.calculate(SABGroupAccountingTestFixture.groupId(), Date.newInstance(2026, 1, 31), 'G18-CALC');
            tb = SABConsolidationService.getTrialBalance(calculated.runId);
        }
        System.runAs(SABGroupAccountingTestFixture.user(SABGroupAccountingTestFixture.APPROVER)) {
            approved = SABConsolidationService.approve(calculated.runId, 'G18-APPROVE');
            published = SABConsolidationService.publish(calculated.runId, 'G18-PUBLISH');
        }
        SABTestGovernor.stopTest();
        System.assertEquals(4, calculated.eliminationCount, 'Receivable, payable and both counter accounts are eliminated.');
        System.assertEquals(false, tb.stale, 'Fresh run.');
        Map<String, SABConsolidationService.TrialBalanceRow> byCode = rows(tb);
        System.assertEquals(7000, byCode.get('1100').consolidated, 'Bank: 5,000 + 2,000.');
        System.assertEquals(-7000, byCode.get('4000').consolidated, 'External sales stay.');
        for (String code : new List<String>{'1400', '2400', '4100', '6100'}) {
            System.assertEquals(0, byCode.get(code).consolidated, 'Intercompany account ' + code + ' eliminates to zero.');
        }
        System.assertEquals(1000, byCode.get('1400').memberTotal, 'Before elimination the receivable shows.');
        System.assertEquals(2, tb.consolidatedCompanies.size(), 'P and S are consolidated.');
        System.assertEquals(1, tb.excludedMembers.size(), 'The joint venture is excluded.');
        System.assert(tb.excludedMembers[0].contains('Joint Venture'), tb.excludedMembers[0]);
        System.assertEquals('Approved', approved.status, 'Approved.');
        System.assertEquals('Published', published.status, 'Published.');
    }

    @IsTest
    static void ledgerChangesMakeARunStale() {
        SABConsolidationService.ActionResult calculated;
        String refusal;
        SABConsolidationService.TrialBalance tb;
        // Everything runs in the governor window: the setup already spent part of the outer one seeding intercompany journals.
        SABTestGovernor.startTest();
        System.runAs(SABGroupAccountingTestFixture.user(SABGroupAccountingTestFixture.MANAGER)) {
            calculated = SABConsolidationService.calculate(SABGroupAccountingTestFixture.groupId(), Date.newInstance(2026, 1, 31), 'G18-STALE-CALC');
            SABGroupAccountingTestFixture.postPairs(new List<List<Object>>{
                new List<Object>{'S', Date.newInstance(2026, 1, 20), '1100', '4000', (Decimal) 300}});
        }
        System.runAs(SABGroupAccountingTestFixture.user(SABGroupAccountingTestFixture.APPROVER)) {
            try {
                SABConsolidationService.approve(calculated.runId, 'G18-STALE-APPROVE');
            } catch (SABConsolidationService.ConsolidationException ex) {
                refusal = ex.getMessage();
            }
            tb = SABConsolidationService.getTrialBalance(calculated.runId);
        }
        SABTestGovernor.stopTest();
        System.assert(refusal != null && refusal.contains('changed since calculation'), 'Stale runs cannot be approved: ' + refusal);
        System.assertEquals(true, tb.stale, 'The trial balance flags the run as stale.');
        System.assertEquals(7300, rows(tb).get('1100').consolidated, 'The trial balance shows current balances.');
    }

    @IsTest
    static void enforcesDutiesMembershipRulesAndGrants() {
        List<String> messages = new List<String>();
        String permissionRefusal;
        Boolean outsiderDenied = false;
        Database.SaveResult directRun;
        SABTestGovernor.startTest();
        System.runAs(SABGroupAccountingTestFixture.user(SABGroupAccountingTestFixture.APPROVER)) {
            Id ownRun = SABConsolidationService.calculate(SABGroupAccountingTestFixture.groupId(), Date.newInstance(2026, 1, 31), 'G18-OWN').runId;
            try {
                SABConsolidationService.approve(ownRun, 'G18-OWN-APPROVE');
            } catch (SABConsolidationService.ConsolidationException ex) {
                messages.add(ex.getMessage());
            }
            try {
                SABConsolidationService.calculate(SABGroupAccountingTestFixture.groupId(), Date.newInstance(2025, 12, 31), 'G18-EARLY');
            } catch (SABConsolidationService.ConsolidationException ex) {
                messages.add(ex.getMessage());
            }
        }
        System.runAs(SABGroupAccountingTestFixture.user(SABGroupAccountingTestFixture.MANAGER)) {
            List<SABConsolidationService.MemberRequest> bad = new List<SABConsolidationService.MemberRequest>{
                memberRequest('E', 100), memberRequest('P', 100), memberRequest('S', 150)};
            for (SABConsolidationService.MemberRequest r : bad) {
                try {
                    SABConsolidationService.saveMember(r);
                } catch (SABConsolidationService.ConsolidationException ex) {
                    messages.add(ex.getMessage());
                }
            }
            try {
                SABConsolidationService.approve([SELECT Id FROM Consolidation_Run__c WITH SYSTEM_MODE LIMIT 1].Id, 'G18-NOPERM');
            } catch (SABPermissionService.PermissionDeniedException ex) {
                permissionRefusal = 'permission';
            }
            directRun = Database.insert(new Consolidation_Run__c(Consolidation_Group__c = SABGroupAccountingTestFixture.groupId(),
                As_Of_Date__c = Date.newInstance(2026, 1, 31), Policy_Version__c = 'v1', Status__c = 'Published', Run_Key__c = 'G18-FORGED'), false,
                AccessLevel.SYSTEM_MODE);
        }
        System.runAs(SABGroupAccountingTestFixture.user(SABGroupAccountingTestFixture.OUTSIDER)) {
            try {
                SABConsolidationService.calculate(SABGroupAccountingTestFixture.groupId(), Date.newInstance(2026, 1, 31), 'G18-OUTSIDER');
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                outsiderDenied = true;
            }
        }
        SABTestGovernor.stopTest();
        List<String> fragments = new List<String>{'calculated a consolidation run cannot approve', 'No Subsidiary member is effective',
            'presentation currency', 'overlapping membership', 'at most 100'};
        System.assertEquals(fragments.size(), messages.size(), 'Every invalid request was refused: ' + messages);
        for (Integer i = 0; i < fragments.size(); i++) {
            System.assert(messages[i].contains(fragments[i]), 'Expected "' + fragments[i] + '" but got: ' + messages[i]);
        }
        System.assertEquals('permission', permissionRefusal, 'Managers without the approve permission cannot approve.');
        System.assertEquals(false, directRun.isSuccess(), 'Runs are created only by the service.');
        System.assertEquals(true, outsiderDenied, 'Consolidation needs a grant to every member company.');
    }

    private static SABConsolidationService.MemberRequest memberRequest(String companyKey, Decimal ownership) {
        SABConsolidationService.MemberRequest r = new SABConsolidationService.MemberRequest();
        r.groupId = SABGroupAccountingTestFixture.groupId();
        r.companyId = SABGroupAccountingTestFixture.companyId(companyKey);
        r.controlType = 'Subsidiary';
        r.ownershipPercent = ownership;
        r.effectiveFrom = Date.newInstance(2026, 6, 1);
        r.mappingVersion = 'CHART-1';
        return r;
    }
}
