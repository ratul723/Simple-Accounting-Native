@IsTest
private class SABCloseTaskServiceTest {

    @TestSetup
    static void setupData() {
        SABApprovalCloseTestFixture.createFixture();
    }

    private static Close_Task__c task(String key, Integer month) {
        Id periodId = SABApprovalCloseTestFixture.periodId(month);
        return [SELECT Id, Status__c, Due_Date__c, Sequence__c, Evidence_Required__c FROM Close_Task__c WHERE Task_Key__c = :key
            AND Accounting_Period__c = :periodId WITH SYSTEM_MODE];
    }

    private static List<SAB_Close_Task_Template__mdt> twoTemplates() {
        return new List<SAB_Close_Task_Template__mdt>{
            SABApprovalCloseTestFixture.template('{"MasterLabel":"Sign off","Task_Key__c":"signoff","Sequence__c":20,"Due_Offset_Days__c":5,'
                + '"Evidence_Required__c":true,"Is_Active__c":true}'),
            SABApprovalCloseTestFixture.template('{"MasterLabel":"Bank rec","Task_Key__c":"BANK","Sequence__c":10,"Due_Offset_Days__c":2,'
                + '"Evidence_Required__c":false,"Is_Active__c":true}'),
            SABApprovalCloseTestFixture.template('{"MasterLabel":"Retired","Task_Key__c":"OLD","Sequence__c":5,"Is_Active__c":false}')};
    }

    @IsTest
    static void generatesDefaultAndConfiguredChecklistsIdempotently() {
        Integer defaults;
        Integer again;
        Integer configured;
        SABTestGovernor.startTest();
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.MANAGER)) {
            defaults = SABCloseTaskService.generateChecklist(SABApprovalCloseTestFixture.periodId(1));
            again = SABCloseTaskService.generateChecklist(SABApprovalCloseTestFixture.periodId(1));
            SABCloseTaskService.templateOverride = twoTemplates();
            configured = SABCloseTaskService.generateChecklist(SABApprovalCloseTestFixture.periodId(2));
        }
        SABTestGovernor.stopTest();
        System.assertEquals(10, defaults, 'The built-in checklist has ten tasks.');
        System.assertEquals(0, again, 'Re-running adds nothing.');
        System.assertEquals(2, configured, 'Only active templates are generated.');
        Close_Task__c bank = task('BANK', 2);
        System.assertEquals(10, bank.Sequence__c, 'Sequence from the template.');
        System.assertEquals(Date.newInstance(2026, 3, 2), bank.Due_Date__c, 'Due two days after the 28 Feb period end.');
        System.assertEquals(true, task('SIGNOFF', 2).Evidence_Required__c, 'Keys are normalized and evidence flags kept.');
        System.assertEquals(true, task('BANK_REC', 1).Evidence_Required__c, 'Default bank reconciliation needs evidence.');
    }

    @IsTest
    static void statusFlowEnforcesEvidenceReasonsAndRoles() {
        List<String> messages = new List<String>();
        SABCloseTaskService.TaskView completed;
        SABCloseTaskService.TaskView reopened;
        SABCloseTaskService.TaskView blocked;
        Database.SaveResult direct;
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.MANAGER)) {
            SABCloseTaskService.generateChecklist(SABApprovalCloseTestFixture.periodId(1));
        }
        Id bankRec = task('BANK_REC', 1).Id;
        SABTestGovernor.startTest();
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.MANAGER)) {
            SABCloseTaskService.assign(bankRec, SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.APPROVER_A).Id, null);
        }
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.APPROVER_A)) {
            try {
                SABCloseTaskService.updateStatus(bankRec, 'Complete', null, null, 'A19-NO-EVIDENCE');
            } catch (SABCloseTaskService.CloseTaskException ex) {
                messages.add(ex.getMessage());
            }
            completed = SABCloseTaskService.updateStatus(bankRec, 'Complete', 'Bank rec Jan signed (DMS-114)', null, 'A19-COMPLETE');
            try {
                SABCloseTaskService.updateStatus(bankRec, 'In Progress', null, null, 'A19-SELF-REOPEN');
            } catch (SABCloseTaskService.CloseTaskException ex) {
                messages.add(ex.getMessage());
            }
            direct = Database.update(new Close_Task__c(Id = bankRec, Status__c = 'Not Started'), false, AccessLevel.SYSTEM_MODE);
        }
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.APPROVER_B)) {
            try {
                SABCloseTaskService.updateStatus(bankRec, 'In Progress', null, null, 'A19-NOT-ASSIGNEE');
            } catch (SABCloseTaskService.CloseTaskException ex) {
                messages.add(ex.getMessage());
            }
        }
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.MANAGER)) {
            reopened = SABCloseTaskService.updateStatus(bankRec, 'In Progress', null, null, 'A19-REOPEN');
            try {
                SABCloseTaskService.updateStatus(bankRec, 'Blocked', null, null, 'A19-BLOCK-NOREASON');
            } catch (SABCloseTaskService.CloseTaskException ex) {
                messages.add(ex.getMessage());
            }
            blocked = SABCloseTaskService.updateStatus(bankRec, 'Blocked', null, 'Statement not received', 'A19-BLOCK');
            try {
                SABCloseTaskService.updateStatus(bankRec, 'Complete', 'x', null, 'A19-BLOCKED-COMPLETE');
            } catch (SABCloseTaskService.CloseTaskException ex) {
                messages.add(ex.getMessage());
            }
        }
        SABTestGovernor.stopTest();
        List<String> fragments = new List<String>{'needs an evidence reference', 'Only a close manager can reopen', 'Only the assignee or a close manager',
            'needs a reason', 'Blocked task cannot move to Complete'};
        System.assertEquals(fragments.size(), messages.size(), 'Every invalid update was refused: ' + messages);
        for (Integer i = 0; i < fragments.size(); i++) {
            System.assert(messages[i].contains(fragments[i]), 'Expected "' + fragments[i] + '" but got: ' + messages[i]);
        }
        System.assertEquals('Complete', completed.status, 'The assignee completes with evidence.');
        System.assertEquals('In Progress', reopened.status, 'Managers reopen.');
        System.assertEquals('Statement not received', blocked.blockedReason, 'Blocked reason recorded.');
        System.assertEquals(false, direct.isSuccess(), 'Status changes only through the service.');
    }

    @IsTest
    static void periodCloseWaitsForTheChecklist() {
        String refused;
        SABCloseTaskService.Checklist before;
        SABCloseTaskService.Checklist ready;
        String afterClose;
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.MANAGER)) {
            SABCloseTaskService.templateOverride = new List<SAB_Close_Task_Template__mdt>{SABApprovalCloseTestFixture.template(
                '{"MasterLabel":"Sign off","Task_Key__c":"SIGNOFF","Sequence__c":10,"Is_Active__c":true}')};
            SABCloseTaskService.generateChecklist(SABApprovalCloseTestFixture.periodId(1));
        }
        Id signoff = task('SIGNOFF', 1).Id;
        SABTestGovernor.startTest();
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.MANAGER)) {
            before = SABCloseTaskService.getChecklist(SABApprovalCloseTestFixture.periodId(1));
            try {
                SABPeriodService.closePeriod(closeRequest(1, 'A19-CLOSE-EARLY'));
            } catch (Exception ex) {
                refused = ex.getMessage();
            }
            SABCloseTaskService.updateStatus(signoff, 'Complete', null, null, 'A19-SIGNOFF');
            ready = SABCloseTaskService.getChecklist(SABApprovalCloseTestFixture.periodId(1));
            SABPeriodService.closePeriod(closeRequest(1, 'A19-CLOSE'));
            SABPeriodService.closePeriod(closeRequest(2, 'A19-CLOSE-FEB'));
            try {
                SABCloseTaskService.updateStatus(signoff, 'In Progress', null, null, 'A19-AFTER-CLOSE');
            } catch (SABCloseTaskService.CloseTaskException ex) {
                afterClose = ex.getMessage();
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals(false, before.readyToClose, 'Not ready with an open task.');
        System.assert(refused != null && refused.contains('0 of 1 tasks are done'), 'Close is refused: ' + refused);
        System.assertEquals(true, ready.readyToClose, 'Ready once every task is complete.');
        System.assertEquals('Closed', [SELECT Status__c FROM Accounting_Period__c WHERE Id = :SABApprovalCloseTestFixture.periodId(1) WITH SYSTEM_MODE]
            .Status__c, 'January closes after its checklist.');
        System.assertEquals('Closed', [SELECT Status__c FROM Accounting_Period__c WHERE Id = :SABApprovalCloseTestFixture.periodId(2) WITH SYSTEM_MODE]
            .Status__c, 'A period without a checklist closes as before.');
        System.assert(afterClose != null && afterClose.contains('closed period'), 'Tasks freeze when the period closes: ' + afterClose);
    }

    private static SABPeriodService.PeriodActionRequest closeRequest(Integer month, String key) {
        SABPeriodService.PeriodActionRequest r = new SABPeriodService.PeriodActionRequest();
        r.periodId = SABApprovalCloseTestFixture.periodId(month);
        r.requestKey = key;
        r.reason = 'Month-end close';
        return r;
    }
}
