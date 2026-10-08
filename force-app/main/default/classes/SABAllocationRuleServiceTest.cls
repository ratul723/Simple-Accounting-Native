@IsTest
private class SABAllocationRuleServiceTest {

    @TestSetup
    static void setupData() {
        SABAllocationTestFixture.createFixture();
    }

    private static SABAllocationRuleService.TargetRequest target(String deptCode, Decimal percentage) {
        SABAllocationRuleService.TargetRequest t = new SABAllocationRuleService.TargetRequest();
        t.targetDepartmentId = deptCode == null ? null : SABAllocationTestFixture.departmentId(deptCode);
        t.percentage = percentage;
        return t;
    }

    private static SABAllocationRuleService.RuleRequest request(Id ruleId, List<String> sourceCodes, List<SABAllocationRuleService.TargetRequest> targets) {
        SABAllocationRuleService.RuleRequest r = new SABAllocationRuleService.RuleRequest();
        r.ruleId = ruleId;
        r.companyId = SABAllocationTestFixture.companyId();
        r.name = 'Rent by department';
        r.ruleKey = 'rent-split';
        r.driverType = 'Percent';
        r.effectiveFrom = Date.newInstance(2026, 1, 1);
        r.sourceAccountIds = new List<Id>();
        for (String code : sourceCodes) {
            r.sourceAccountIds.add(SABAllocationTestFixture.accountId(code));
        }
        r.targets = targets;
        return r;
    }

    private static List<SABAllocationRuleService.TargetRequest> sixtyForty() {
        return new List<SABAllocationRuleService.TargetRequest>{target('SAL', 60), target('OPS', 40)};
    }

    private static String failure(SABAllocationRuleService.RuleRequest r) {
        try {
            SABAllocationRuleService.saveDraft(r);
        } catch (Exception ex) {
            return ex.getMessage();
        }
        return null;
    }

    @IsTest
    static void draftApproveReviseAndRetire() {
        Id ruleId;
        SABAllocationRuleService.ActionResult approved;
        SABAllocationRuleService.ActionResult replay;
        SABAllocationRuleService.ActionResult revision;
        SABAllocationRuleService.ActionResult approvedRevision;
        SABAllocationRuleService.ActionResult retired;
        SABTestGovernor.startTest();
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            ruleId = SABAllocationRuleService.saveDraft(request(null, new List<String>{'6100'}, sixtyForty()));
            SABAllocationRuleService.saveDraft(request(ruleId, new List<String>{'6100', '6200'}, sixtyForty()));
        }
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.APPROVER)) {
            approved = SABAllocationRuleService.approve(ruleId, 'A14-RULE-APPROVE');
            replay = SABAllocationRuleService.approve(ruleId, 'A14-RULE-APPROVE');
        }
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            revision = SABAllocationRuleService.revise(ruleId, 'Add utilities split', 'A14-RULE-REVISE');
        }
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.APPROVER)) {
            approvedRevision = SABAllocationRuleService.approve(revision.ruleId, 'A14-RULE-APPROVE-V2');
        }
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            retired = SABAllocationRuleService.retire(revision.ruleId, 'Replaced by headcount split', 'A14-RULE-RETIRE');
        }
        SABTestGovernor.stopTest();
        Allocation_Rule__c rule = [SELECT Rule_Key__c, Version__c, Rounding_Policy__c, Source_Filter_JSON__c FROM Allocation_Rule__c
            WHERE Id = :ruleId WITH SYSTEM_MODE];
        System.assertEquals('RENT-SPLIT', rule.Rule_Key__c, 'Rule keys are normalized to upper case.');
        System.assertEquals('Largest Remainder', rule.Rounding_Policy__c, 'Default rounding policy.');
        System.assertEquals(2, SABAllocationRuleService.parseSource(rule.Source_Filter_JSON__c).accountIds.size(), 'Edit replaced the sources.');
        System.assertEquals('Approved', approved.status, 'Approver approves.');
        System.assertEquals(true, replay.replay, 'Same key replays.');
        System.assertEquals(2, revision.version, 'Revision is version 2.');
        System.assertEquals(ruleId, approvedRevision.retiredRuleId, 'Approving v2 retires v1.');
        System.assertEquals('Retired', retired.status, 'Retired.');
        System.assertEquals(2, [SELECT COUNT() FROM Allocation_Rule_Line__c WHERE Allocation_Rule__c = :revision.ruleId WITH SYSTEM_MODE],
            'Revision copied the lines.');
    }

    @IsTest
    static void validatesRulesAndSeparatesDuties() {
        List<String> messages = new List<String>();
        String selfApproval;
        SABTestGovernor.startTest();
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            messages.add(failure(request(null, new List<String>{'6100'}, new List<SABAllocationRuleService.TargetRequest>{target('SAL', 60),
                target('OPS', 30)})));
            messages.add(failure(request(null, new List<String>{'2100'}, sixtyForty())));
            messages.add(failure(request(null, new List<String>(), sixtyForty())));
            messages.add(failure(request(null, new List<String>{'6100'}, new List<SABAllocationRuleService.TargetRequest>())));
            messages.add(failure(request(null, new List<String>{'6100'}, new List<SABAllocationRuleService.TargetRequest>{target(null, 100)})));
            SABAllocationRuleService.RuleRequest metric = request(null, new List<String>{'6100'}, sixtyForty());
            metric.driverType = 'Supported Metric';
            messages.add(failure(metric));
            SABAllocationRuleService.RuleRequest coin = request(null, new List<String>{'6100'}, sixtyForty());
            coin.roundingPolicy = 'Coin Toss';
            messages.add(failure(coin));
            SABAllocationRuleService.RuleRequest backwards = request(null, new List<String>{'6100'}, sixtyForty());
            backwards.effectiveTo = Date.newInstance(2025, 12, 31);
            messages.add(failure(backwards));
            Id ownRule = SABAllocationRuleService.saveDraft(request(null, new List<String>{'6100'}, sixtyForty()));
            messages.add(failure(request(null, new List<String>{'6100'}, sixtyForty())));
            try {
                SABAllocationRuleService.approve(ownRule, 'A14-SELF');
            } catch (SABPermissionService.PermissionDeniedException ex) {
                selfApproval = 'permission';
            }
        }
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.APPROVER)) {
            Id approverRule = SABAllocationTestFixture.seedRule('OWN-RULE', 'Draft', 'Percent', 'Largest Remainder', new List<String>{'6100'},
                new List<List<Object>>{new List<Object>{'SAL', (Decimal) 100}});
            try {
                SABAllocationRuleService.approve(approverRule, 'A14-OWN');
            } catch (SABAllocationRuleService.AllocationRuleException ex) {
                messages.add(ex.getMessage());
            }
        }
        SABTestGovernor.stopTest();
        List<String> fragments = new List<String>{'total exactly 100; they total 90', 'non-control accounts', 'between 1 and 50 source',
            'between 1 and 200 target', 'needs a GL account, a department or a cost center', 'Percent and Manual Driver',
            'Rounding policy must be', 'cannot be before', 'already has a Draft version', 'creator of an allocation rule cannot approve'};
        System.assertEquals(fragments.size(), messages.size(), 'Every invalid request was refused.');
        for (Integer i = 0; i < fragments.size(); i++) {
            System.assert(messages[i] != null && messages[i].contains(fragments[i]), 'Expected "' + fragments[i] + '" but got: ' + messages[i]);
        }
        System.assertEquals('permission', selfApproval, 'Preparers without the approve permission cannot approve.');
    }

    @IsTest
    static void guardsBlockDirectChanges() {
        System.runAs(SABAllocationTestFixture.user(SABAllocationTestFixture.PREPARER)) {
            Id approvedRule = SABAllocationTestFixture.seedRule('GUARDED', 'Approved', 'Percent', 'Largest Remainder', new List<String>{'6100'},
                new List<List<Object>>{new List<Object>{'SAL', (Decimal) 100}});
            Id approvedLine = [SELECT Id FROM Allocation_Rule_Line__c WHERE Allocation_Rule__c = :approvedRule WITH SYSTEM_MODE LIMIT 1].Id;
            SABTestGovernor.startTest();
            Allocation_Rule__c draft = new Allocation_Rule__c(Name = 'Direct', Company__c = SABAllocationTestFixture.companyId(),
                Rule_Key__c = 'DIRECT', Version__c = 1, Driver_Type__c = 'Percent', Rounding_Policy__c = 'Largest Remainder',
                Effective_From__c = Date.newInstance(2026, 1, 1), Source_Filter_JSON__c = '{"accountIds":[]}');
            System.assert(Database.insert(draft, AccessLevel.SYSTEM_MODE).isSuccess(), 'A Draft rule may be inserted directly.');
            System.assertEquals('Draft', [SELECT Status__c FROM Allocation_Rule__c WHERE Id = :draft.Id WITH SYSTEM_MODE].Status__c,
                'A blank status becomes Draft.');
            List<Database.SaveResult> blocked = new List<Database.SaveResult>{
                Database.update(new Allocation_Rule__c(Id = draft.Id, Status__c = 'Approved'), false, AccessLevel.SYSTEM_MODE),
                Database.update(new Allocation_Rule__c(Id = approvedRule, Name = 'Renamed'), false, AccessLevel.SYSTEM_MODE),
                Database.update(new Allocation_Rule_Line__c(Id = approvedLine, Percentage__c = 50), false, AccessLevel.SYSTEM_MODE),
                Database.insert(new Allocation_Run__c(Company__c = SABAllocationTestFixture.companyId(), Allocation_Rule__c = approvedRule,
                    Accounting_Period__c = SABAllocationTestFixture.periodId('A14-2026-10'), Rule_Version__c = 1, Status__c = 'Posted',
                    Run_Key__c = 'FORGED'), false, AccessLevel.SYSTEM_MODE)};
            Database.DeleteResult approvedDelete = Database.delete(approvedRule, false, AccessLevel.SYSTEM_MODE);
            SABTestGovernor.stopTest();
            for (Integer i = 0; i < blocked.size(); i++) {
                System.assertEquals(false, blocked[i].isSuccess(), 'Direct change ' + i + ' must be blocked.');
            }
            System.assertEquals(false, approvedDelete.isSuccess(), 'Approved rules cannot be deleted.');
        }
    }
}
