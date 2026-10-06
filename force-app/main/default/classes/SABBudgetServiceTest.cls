@IsTest
private class SABBudgetServiceTest {

    @TestSetup
    static void setupData() {
        SABBudgetTestFixture.createFixture();
    }

    private static SABBudgetService.LineRequest line(String periodKey, String accountCode, String deptCode, Decimal amount) {
        SABBudgetService.LineRequest l = new SABBudgetService.LineRequest();
        l.accountingPeriodId = SABBudgetTestFixture.periodId(periodKey);
        l.glAccountId = SABBudgetTestFixture.accountId(accountCode);
        l.departmentId = deptCode == null ? null : SABBudgetTestFixture.departmentId(deptCode);
        l.amount = amount;
        return l;
    }

    private static SABBudgetService.BudgetRequest request(Id budgetId, List<SABBudgetService.LineRequest> lines) {
        SABBudgetService.BudgetRequest r = new SABBudgetService.BudgetRequest();
        r.budgetId = budgetId;
        r.companyId = SABBudgetTestFixture.companyId();
        r.fiscalYear = 2026;
        r.lines = lines;
        return r;
    }

    private static List<SABBudgetService.LineRequest> standardLines() {
        return new List<SABBudgetService.LineRequest>{line('B13-2026-10', '4000', null, 1200), line('B13-2026-10', '6000', 'SAL', 250)};
    }

    private static String failure(SABBudgetService.BudgetRequest r) {
        try {
            SABBudgetService.saveDraft(r);
        } catch (Exception ex) {
            return ex.getMessage();
        }
        return null;
    }

    private static Boolean matches(String message, String fragment) {
        return message != null && message.contains(fragment);
    }

    @IsTest
    static void draftSubmitAndApproveWithReplay() {
        Id budgetId;
        SABBudgetService.ActionResult submitted;
        SABBudgetService.ActionResult replay;
        SABBudgetService.ActionResult approved;
        SABTestGovernor.startTest();
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.PLANNER)) {
            budgetId = SABBudgetService.saveDraft(request(null, standardLines()));
            List<SABBudgetService.LineRequest> edited = standardLines();
            edited.add(line('B13-2026-11', '6000', null, 100));
            SABBudgetService.saveDraft(request(budgetId, edited));
            submitted = SABBudgetService.submit(budgetId, 'B13-SUBMIT');
            replay = SABBudgetService.submit(budgetId, 'B13-SUBMIT');
        }
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.APPROVER)) {
            approved = SABBudgetService.approve(budgetId, 'B13-APPROVE');
        }
        SABTestGovernor.stopTest();
        System.assertEquals('Submitted', submitted.status, 'Draft is submitted.');
        System.assertEquals(true, replay.replay, 'Same key replays.');
        System.assertEquals('Approved', approved.status, 'Approver approves.');
        System.assertEquals(null, approved.supersededBudgetId, 'First approved version supersedes nothing.');
        Budget__c budget = [SELECT Name, Version__c, Currency__c, Budget_Key__c, Approved_By__c, Submitted_By__c FROM Budget__c
            WHERE Id = :budgetId WITH SYSTEM_MODE];
        System.assertEquals(1, budget.Version__c, 'First version.');
        System.assertEquals('BDT', budget.Currency__c, 'Functional currency is used.');
        System.assertEquals('FY2026 Budget v1', budget.Name, 'Default name.');
        System.assertEquals(SABBudgetTestFixture.user(SABBudgetTestFixture.APPROVER).Id, budget.Approved_By__c, 'Approver recorded.');
        System.assertEquals(3, [SELECT COUNT() FROM Budget_Line__c WHERE Budget__c = :budgetId WITH SYSTEM_MODE], 'Edit replaced the lines.');
        System.assertEquals(2, [SELECT COUNT() FROM Business_Action__c WHERE Source_Record_Id__c = :String.valueOf(budgetId) WITH SYSTEM_MODE],
            'Submit and approve are audited once each.');
    }

    @IsTest
    static void revisionSupersedesTheApprovedVersion() {
        Id original;
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.APPROVER)) {
            original = SABBudgetTestFixture.seedBudget('Approved', 1, new List<List<Object>>{
                new List<Object>{'B13-2026-10', '4000', null, (Decimal) 1200}, new List<Object>{'B13-2026-10', '6000', 'SAL', (Decimal) 250}});
        }
        SABBudgetService.ActionResult revision;
        SABBudgetService.ActionResult revisionReplay;
        SABBudgetService.ActionResult approved;
        SABTestGovernor.startTest();
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.PLANNER)) {
            revision = SABBudgetService.revise(original, 'Q4 reforecast', 'B13-REVISE');
            revisionReplay = SABBudgetService.revise(original, 'Q4 reforecast', 'B13-REVISE');
            SABBudgetService.submit(revision.budgetId, 'B13-REVISE-SUBMIT');
        }
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.APPROVER)) {
            approved = SABBudgetService.approve(revision.budgetId, 'B13-REVISE-APPROVE');
        }
        SABTestGovernor.stopTest();
        System.assertEquals('Draft', revision.status, 'Revision opens a Draft.');
        System.assertEquals(2, revision.version, 'Revision is version 2.');
        System.assertEquals(revision.budgetId, revisionReplay.budgetId, 'Replay returns the same revision.');
        System.assertEquals(original, approved.supersededBudgetId, 'Approving v2 supersedes v1.');
        System.assertEquals('Superseded', [SELECT Status__c FROM Budget__c WHERE Id = :original WITH SYSTEM_MODE].Status__c, 'v1 is Superseded.');
        System.assertEquals(2, [SELECT COUNT() FROM Budget_Line__c WHERE Budget__c = :revision.budgetId WITH SYSTEM_MODE],
            'Approved lines were copied.');
        System.assertEquals(1, [SELECT COUNT() FROM Budget__c WHERE Company__c = :SABBudgetTestFixture.companyId() AND Status__c = 'Approved'
            WITH SYSTEM_MODE], 'Exactly one Approved budget per company and year.');
    }

    @IsTest
    static void enforcesPermissionsAndSeparationOfDuties() {
        List<String> refused = new List<String>();
        Id submittedId;
        SABTestGovernor.startTest();
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.PLANNER)) {
            submittedId = SABBudgetService.saveDraft(request(null, standardLines()));
            SABBudgetService.submit(submittedId, 'B13-SOD-SUBMIT');
            try {
                SABBudgetService.approve(submittedId, 'B13-SOD-SELF');
            } catch (SABPermissionService.PermissionDeniedException ex) {
                refused.add('planner-cannot-approve');
            }
        }
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.APPROVER)) {
            try {
                SABBudgetService.saveDraft(request(null, standardLines()));
            } catch (SABPermissionService.PermissionDeniedException ex) {
                refused.add('approver-cannot-create');
            }
            SABBudgetService.returnToDraft(submittedId, 'Revenue too optimistic', 'B13-SOD-RETURN');
        }
        Id ownBudget;
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.PLANNER)) {
            delete as system [SELECT Id FROM Budget__c WHERE Id = :submittedId WITH SYSTEM_MODE];
        }
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.APPROVER)) {
            ownBudget = SABBudgetTestFixture.seedBudget('Submitted', 3, new List<List<Object>>{
                new List<Object>{'B13-2026-10', '4000', null, (Decimal) 10}});
            try {
                SABBudgetService.approve(ownBudget, 'B13-SOD-OWN');
            } catch (SABBudgetService.BudgetException ex) {
                refused.add(matches(ex.getMessage(), 'cannot approve it') ? 'creator-cannot-approve' : ex.getMessage());
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals(new List<String>{'planner-cannot-approve', 'approver-cannot-create', 'creator-cannot-approve'}, refused,
            'Permissions and separation of duties are enforced.');
        System.assertEquals(0, [SELECT COUNT() FROM Budget__c WHERE Id = :submittedId WITH SYSTEM_MODE], 'Returned Draft could be deleted.');
    }

    @IsTest
    static void validatesBudgetContent() {
        List<String> messages = new List<String>();
        SABTestGovernor.startTest();
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.PLANNER)) {
            messages.add(failure(request(null, new List<SABBudgetService.LineRequest>())));
            messages.add(failure(request(null, new List<SABBudgetService.LineRequest>{line('B13-2025-12', '4000', null, 1)})));
            messages.add(failure(request(null, new List<SABBudgetService.LineRequest>{line('B13-2026-10', '6100', null, 1)})));
            messages.add(failure(request(null, new List<SABBudgetService.LineRequest>{line('B13-2026-10', '4000', null, 1),
                line('B13-2026-10', '4000', null, 2)})));
            messages.add(failure(request(null, new List<SABBudgetService.LineRequest>{line('B13-2026-10', '4000', null, null)})));
            SABBudgetService.BudgetRequest longName = request(null, standardLines());
            longName.name = 'X'.repeat(81);
            messages.add(failure(longName));
            SABBudgetService.saveDraft(request(null, standardLines()));
            messages.add(failure(request(null, standardLines())));
        }
        SABTestGovernor.stopTest();
        List<String> fragments = new List<String>{'between 1 and', 'fiscal year 2026', 'active and belong', 'only once',
            'a period, a GL account and an amount', 'cannot exceed 80', 'already has a Draft or Submitted'};
        System.assertEquals(fragments.size(), messages.size(), 'Every invalid request was checked.');
        for (Integer i = 0; i < fragments.size(); i++) {
            System.assert(matches(messages[i], fragments[i]), 'Expected "' + fragments[i] + '" but got: ' + messages[i]);
        }
    }

    @IsTest
    static void guardsBlockDirectLifecycleChanges() {
        System.runAs(SABBudgetTestFixture.user(SABBudgetTestFixture.PLANNER)) {
            Id approvedId = SABBudgetTestFixture.seedBudget('Approved', 1, new List<List<Object>>{
                new List<Object>{'B13-2026-10', '4000', null, (Decimal) 1200}});
            Id approvedLine = [SELECT Id FROM Budget_Line__c WHERE Budget__c = :approvedId WITH SYSTEM_MODE LIMIT 1].Id;
            SABTestGovernor.startTest();
            Budget__c draft = new Budget__c(Name = 'Direct', Company__c = SABBudgetTestFixture.companyId(), Fiscal_Year__c = 2026, Version__c = 9,
                Currency__c = 'BDT', Budget_Key__c = 'B13-DIRECT');
            System.assert(Database.insert(draft, false).isSuccess(), 'A Draft budget may be inserted directly.');
            System.assertEquals('Draft', [SELECT Status__c FROM Budget__c WHERE Id = :draft.Id WITH SYSTEM_MODE].Status__c,
                'A blank status becomes Draft.');
            List<Database.SaveResult> blocked = new List<Database.SaveResult>{
                Database.insert(new Budget__c(Name = 'Forged', Company__c = SABBudgetTestFixture.companyId(), Fiscal_Year__c = 2026,
                    Version__c = 8, Currency__c = 'BDT', Status__c = 'Approved', Budget_Key__c = 'B13-FORGED'), false),
                Database.update(new Budget__c(Id = draft.Id, Status__c = 'Approved'), false),
                Database.update(new Budget__c(Id = draft.Id, Fiscal_Year__c = 2027), false),
                Database.update(new Budget__c(Id = approvedId, Name = 'Renamed'), false),
                Database.update(new Budget_Line__c(Id = approvedLine, Amount__c = 1), false)};
            Database.DeleteResult approvedDelete = Database.delete(approvedId, false);
            SABTestGovernor.stopTest();
            for (Integer i = 0; i < blocked.size(); i++) {
                System.assertEquals(false, blocked[i].isSuccess(), 'Direct change ' + i + ' must be blocked.');
            }
            System.assertEquals(false, approvedDelete.isSuccess(), 'Approved budgets cannot be deleted.');
        }
    }
}
