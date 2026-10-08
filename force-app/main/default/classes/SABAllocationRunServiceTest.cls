@IsTest
private class SABAllocationRunServiceTest {

    @TestSetup
    static void setupData() {
        SABAllocationTestFixture.createFixture();
        // Approved 60/40 Sales/Ops split of Rent and Utilities, created by the approver so the preparer can run it.
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.APPROVER)) {
            SABAllocationTestFixture.seedRule('RENT-SPLIT', 'Approved', 'Percent', 'Largest Remainder', new List<String>{'6100', '6200'},
                new List<List<Object>>{new List<Object>{'SAL', (Decimal) 60}, new List<Object>{'OPS', (Decimal) 40}});
        }
    }

    private static Id ruleId(String key) {
        return [SELECT Id FROM Allocation_Rule__c WHERE Rule_Key__c = :key WITH SYSTEM_MODE LIMIT 1].Id;
    }

    private static Id october() {
        return SABAllocationTestFixture.periodId('A14-2026-10');
    }

    @IsTest
    static void previewApproveAndPostABalancedAllocationJournal() {
        SABAllocationRunService.ActionResult previewed;
        SABAllocationRunService.ActionResult replay;
        SABAllocationRunService.ActionResult posted;
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            previewed = SABAllocationRunService.preview(ruleId('RENT-SPLIT'), october(), 'A14-PREVIEW');
            replay = SABAllocationRunService.preview(ruleId('RENT-SPLIT'), october(), 'A14-PREVIEW');
        }
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.APPROVER)) {
            SABAllocationRunService.approve(previewed.runId, 'A14-RUN-APPROVE');
        }
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            SABTestGovernor.startTest();
            posted = SABAllocationRunService.post(previewed.runId, 'A14-POST');
            SABTestGovernor.stopTest();
        }
        System.assertEquals('Preview', previewed.status, 'Preview run.');
        System.assertEquals(1100.01, previewed.sourceAmount, 'Rent 1,000.00 plus utilities 100.01.');
        System.assertEquals(previewed.runId, replay.runId, 'Same key replays the preview.');
        System.assertEquals('Posted', posted.status, 'Run is Posted.');
        Journal_Entry__c journal = [SELECT Status__c, Entry_Type__c, Accounting_Date__c, Accounting_Event__r.Event_Type__c,
            Accounting_Event__r.Adapter_Key__c FROM Journal_Entry__c WHERE Id = :posted.journalEntryId WITH SYSTEM_MODE];
        System.assertEquals('Posted', journal.Status__c, 'Journal posted through SABPostingService.');
        System.assertEquals('Subledger', journal.Entry_Type__c, 'Allocation posts a Subledger journal like every module.');
        System.assertEquals('Allocation', journal.Accounting_Event__r.Event_Type__c, 'The event is typed Allocation.');
        System.assertEquals(Date.newInstance(2026, 10, 31), journal.Accounting_Date__c, 'Dated at period end.');
        System.assertEquals('COST_ALLOCATION', journal.Accounting_Event__r.Adapter_Key__c, 'Allocation adapter.');
        Decimal debits = 0;
        Decimal credits = 0;
        Map<String, Decimal> byLine = new Map<String, Decimal>();
        for (Journal_Entry_Line__c l : [SELECT GL_Account__r.Account_Code__c, Department__r.Code__c, Debit_Base__c, Credit_Base__c
                FROM Journal_Entry_Line__c WHERE Journal_Entry__c = :posted.journalEntryId WITH SYSTEM_MODE]) {
            debits += l.Debit_Base__c;
            credits += l.Credit_Base__c;
            byLine.put(l.GL_Account__r.Account_Code__c + '|' + l.Department__r.Code__c, l.Debit_Base__c - l.Credit_Base__c);
        }
        System.assertEquals(debits, credits, 'Allocation journal balances.');
        System.assertEquals(1100.01, debits, 'Everything allocated.');
        System.assertEquals(-1000, byLine.get('6100|null'), 'Rent credited off the undepartmented balance.');
        System.assertEquals(600, byLine.get('6100|SAL'), 'Sales takes 60% of rent.');
        System.assertEquals(60.01, byLine.get('6200|SAL'), 'Largest remainder gives Sales the leftover cent of utilities.');
        System.assertEquals(40.00, byLine.get('6200|OPS'), 'Ops takes the rest of utilities.');
        System.assertEquals(3, [SELECT COUNT() FROM Business_Action__c WHERE Source_Type__c = 'Allocation_Run__c'
            AND Source_Record_Id__c = :String.valueOf(previewed.runId) WITH SYSTEM_MODE], 'Preview, approve and post are audited once each.');
    }

    @IsTest
    static void detectsSourceDriftAndSupportsDiscardAndRepreview() {
        Id runId;
        List<String> messages = new List<String>();
        SABAllocationRunService.ActionResult discarded;
        SABAllocationRunService.ActionResult repreviewed;
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            runId = SABAllocationRunService.preview(ruleId('RENT-SPLIT'), october(), 'A14-DRIFT-PREVIEW').runId;
            try {
                SABAllocationRunService.preview(ruleId('RENT-SPLIT'), october(), 'A14-DRIFT-AGAIN');
            } catch (SABAllocationRunService.AllocationRunException ex) {
                messages.add(ex.getMessage());
            }
        }
        // Everything after the first preview runs in its own governor window (setup carries into the outer one).
        SABTestGovernor.startTest();
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            try {
                SABAllocationRunService.approve(runId, 'A14-DRIFT-SELF');
            } catch (SABPermissionService.PermissionDeniedException ex) {
                messages.add('preparer-cannot-approve');
            }
        }
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.APPROVER)) {
            SABAllocationRunService.approve(runId, 'A14-DRIFT-APPROVE');
        }
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            SABAllocationTestFixture.postActual('6100', 50, 'Late rent invoice');
            try {
                SABAllocationRunService.post(runId, 'A14-DRIFT-POST');
            } catch (SABAllocationRunService.AllocationRunException ex) {
                messages.add(ex.getMessage());
            }
            discarded = SABAllocationRunService.discard(runId, 'Late rent invoice arrived', 'A14-DRIFT-DISCARD');
            repreviewed = SABAllocationRunService.preview(ruleId('RENT-SPLIT'), october(), 'A14-DRIFT-REPREVIEW');
        }
        SABTestGovernor.stopTest();
        System.assert(messages[0].contains('already has a live run'), 'One live run per rule and period: ' + messages[0]);
        System.assertEquals('preparer-cannot-approve', messages[1], 'Preparers without the approve permission cannot approve.');
        System.assert(messages[2].contains('changed since the preview'), 'Posting re-checks the source balances: ' + messages[2]);
        System.assertEquals('Failed', discarded.status, 'Discarded runs are Failed.');
        System.assertEquals(1150.01, repreviewed.sourceAmount, 'The new preview includes the late invoice.');
        System.assertNotEquals(runId, repreviewed.runId, 'A new run after the discard.');
    }

    @IsTest
    static void roundingAccountPolicyPostsTheResidual() {
        SABAllocationRunService.ActionResult posted;
        Id ruleThirds;
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.APPROVER)) {
            ruleThirds = SABAllocationTestFixture.seedRule('UTIL-THIRDS', 'Approved', 'Manual Driver', 'Rounding Account', new List<String>{'6200'},
                new List<List<Object>>{new List<Object>{'SAL', (Decimal) 1}, new List<Object>{'OPS', (Decimal) 1},
                    new List<Object>{'SAL', (Decimal) 1}});
        }
        Id runId;
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            runId = SABAllocationRunService.preview(ruleThirds, october(), 'A14-THIRDS-PREVIEW').runId;
        }
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.APPROVER)) {
            SABAllocationRunService.approve(runId, 'A14-THIRDS-APPROVE');
        }
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            SABTestGovernor.startTest();
            posted = SABAllocationRunService.post(runId, 'A14-THIRDS-POST');
            SABTestGovernor.stopTest();
        }
        Decimal rounding = 0;
        Decimal debits = 0;
        Decimal credits = 0;
        for (Journal_Entry_Line__c l : [SELECT GL_Account__r.Account_Code__c, Debit_Base__c, Credit_Base__c FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c = :posted.journalEntryId WITH SYSTEM_MODE]) {
            debits += l.Debit_Base__c;
            credits += l.Credit_Base__c;
            if (l.GL_Account__r.Account_Code__c == '7990') {
                rounding += l.Credit_Base__c - l.Debit_Base__c;
            }
        }
        System.assertEquals(debits, credits, 'The rounding line keeps the journal balanced.');
        System.assertEquals(0.01, rounding, 'Three shares of 33.34 over-allocate 100.01 by one cent, credited to the rounding account.');
    }

    @IsTest
    static void refusesInvalidRunsAndUsersWithoutAGrant() {
        List<String> messages = new List<String>();
        Boolean outsiderDenied = false;
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.APPROVER)) {
            SABAllocationTestFixture.seedRule('DRAFT-RULE', 'Draft', 'Percent', 'Largest Remainder', new List<String>{'6100'},
                new List<List<Object>>{new List<Object>{'SAL', (Decimal) 100}});
            SABAllocationTestFixture.seedRule('EMPTY-RULE', 'Approved', 'Percent', 'Largest Remainder', new List<String>{'7990'},
                new List<List<Object>>{new List<Object>{'SAL', (Decimal) 100}});
        }
        SABTestGovernor.startTest();
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            List<List<Object>> attempts = new List<List<Object>>{
                new List<Object>{'DRAFT-RULE', october()},
                new List<Object>{'RENT-SPLIT', SABAllocationTestFixture.periodId('A14-2026-11')},
                new List<Object>{'EMPTY-RULE', october()}};
            Integer n = 0;
            for (List<Object> attempt : attempts) {
                try {
                    SABAllocationRunService.preview(ruleId((String) attempt[0]), (Id) attempt[1], 'A14-BAD-' + n++);
                } catch (SABAllocationRunService.AllocationRunException ex) {
                    messages.add(ex.getMessage());
                }
            }
        }
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.OUTSIDER)) {
            try {
                SABAllocationRunService.preview(ruleId('RENT-SPLIT'), october(), 'A14-OUTSIDER');
            } catch (Exception ex) {
                outsiderDenied = true;
            }
        }
        SABTestGovernor.stopTest();
        List<String> fragments = new List<String>{'Only an Approved allocation rule', 'Open period', 'no posted balance'};
        System.assertEquals(fragments.size(), messages.size(), 'Every invalid run was refused.');
        for (Integer i = 0; i < fragments.size(); i++) {
            System.assert(messages[i].contains(fragments[i]), 'Expected "' + fragments[i] + '" but got: ' + messages[i]);
        }
        System.assertEquals(true, outsiderDenied, 'Users without a company grant cannot run allocations.');
        System.assertEquals('Allocation', SABAllocationRunService.eventType(), 'The defined Allocation event type is used.');
    }
}
