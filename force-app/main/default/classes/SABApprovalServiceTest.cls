@IsTest
private class SABApprovalServiceTest {

    @TestSetup
    static void setupData() {
        SABApprovalCloseTestFixture.createFixture();
    }

    private static Map<Decimal, Approval_Step__c> steps(Id requestId) {
        Map<Decimal, Approval_Step__c> result = new Map<Decimal, Approval_Step__c>();
        for (Approval_Step__c s : [SELECT Id, Sequence__c, Decision__c, Decision_By__c FROM Approval_Step__c WHERE Approval_Request__c = :requestId
                WITH SYSTEM_MODE]) {
            result.put(s.Sequence__c, s);
        }
        return result;
    }

    @IsTest
    static void approvesInSequence() {
        SABApprovalService.ActionResult submitted;
        SABApprovalService.ActionResult replay;
        String outOfOrder;
        List<SABApprovalService.InboxItem> inboxA;
        List<SABApprovalService.InboxItem> inboxB;
        SABApprovalService.ActionResult first;
        SABApprovalService.ActionResult last;
        SABTestGovernor.startTest();
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.REQUESTER)) {
            submitted = SABApprovalService.submit(SABApprovalCloseTestFixture.submission(new List<String>{
                SABApprovalCloseTestFixture.APPROVER_A, SABApprovalCloseTestFixture.APPROVER_B}, 1), 'A19-SUBMIT');
            replay = SABApprovalService.submit(SABApprovalCloseTestFixture.submission(new List<String>{
                SABApprovalCloseTestFixture.APPROVER_A, SABApprovalCloseTestFixture.APPROVER_B}, 1), 'A19-SUBMIT');
        }
        Map<Decimal, Approval_Step__c> s = steps(submitted.approvalRequestId);
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.APPROVER_B)) {
            inboxB = SABApprovalService.getInbox();
            try {
                SABApprovalService.decide(s.get(2).Id, 'Approved', null, 'A19-B-EARLY');
            } catch (SABApprovalService.ApprovalException ex) {
                outOfOrder = ex.getMessage();
            }
        }
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.APPROVER_A)) {
            inboxA = SABApprovalService.getInbox();
            first = SABApprovalService.decide(s.get(1).Id, 'Approved', 'Looks right', 'A19-A-APPROVE');
        }
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.APPROVER_B)) {
            last = SABApprovalService.decide(s.get(2).Id, 'Approved', null, 'A19-B-APPROVE');
        }
        SABTestGovernor.stopTest();
        System.assertEquals('Pending', submitted.status, 'Submitted.');
        System.assertEquals(2, submitted.pendingSteps, 'Two steps.');
        System.assertEquals(true, replay.replay, 'Same key replays.');
        System.assertEquals(1, inboxA.size(), 'The first approver sees the request.');
        System.assertEquals(0, inboxB.size(), 'The second approver waits for the first.');
        System.assert(outOfOrder != null && outOfOrder.contains('Earlier approval steps'), 'Steps are decided in order: ' + outOfOrder);
        System.assertEquals('Pending', first.status, 'Still pending after the first approval.');
        System.assertEquals('Approved', last.status, 'The last approval approves the request.');
        System.assertEquals(true, SABApprovalService.isApproved('GL_Account__c', SABApprovalCloseTestFixture.sourceId(), 1), 'Version 1 approved.');
        System.assertEquals(false, SABApprovalService.isApproved('GL_Account__c', SABApprovalCloseTestFixture.sourceId(), 2), 'Version 2 is not.');
    }

    @IsTest
    static void rejectionSkipsRemainingStepsAndRequesterCanCancel() {
        SABApprovalService.ActionResult rejected;
        SABApprovalService.ActionResult cancelled;
        String noComment;
        Id firstRequest;
        SABTestGovernor.startTest();
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.REQUESTER)) {
            firstRequest = SABApprovalService.submit(SABApprovalCloseTestFixture.submission(new List<String>{
                SABApprovalCloseTestFixture.APPROVER_A, SABApprovalCloseTestFixture.APPROVER_B}, 1), 'A19-REJ-SUBMIT').approvalRequestId;
        }
        Map<Decimal, Approval_Step__c> s = steps(firstRequest);
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.APPROVER_A)) {
            try {
                SABApprovalService.decide(s.get(1).Id, 'Rejected', ' ', 'A19-REJ-NOCOMMENT');
            } catch (SABApprovalService.ApprovalException ex) {
                noComment = ex.getMessage();
            }
            rejected = SABApprovalService.decide(s.get(1).Id, 'Rejected', 'Wrong account mapping', 'A19-REJ');
        }
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.REQUESTER)) {
            Id second = SABApprovalService.submit(SABApprovalCloseTestFixture.submission(new List<String>{SABApprovalCloseTestFixture.APPROVER_A}, 2),
                'A19-RESUBMIT').approvalRequestId;
            cancelled = SABApprovalService.cancel(second, 'Submitted by mistake', 'A19-CANCEL');
        }
        SABTestGovernor.stopTest();
        System.assert(noComment != null && noComment.contains('needs a comment'), 'Rejections need a comment: ' + noComment);
        System.assertEquals('Rejected', rejected.status, 'Rejected.');
        Map<Decimal, Approval_Step__c> after = steps(firstRequest);
        System.assertEquals('Rejected', after.get(1).Decision__c, 'Step 1 rejected.');
        System.assertEquals('Skipped', after.get(2).Decision__c, 'Remaining steps are skipped.');
        System.assertEquals('Cancelled', cancelled.status, 'The requester cancels.');
    }

    @IsTest
    static void invalidatesStaleRequestsAndValidatesSubmissions() {
        List<String> messages = new List<String>();
        Integer invalidated;
        String wrongAssignee;
        Database.SaveResult direct;
        SABTestGovernor.startTest();
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.REQUESTER)) {
            Id requestId = SABApprovalService.submit(SABApprovalCloseTestFixture.submission(new List<String>{SABApprovalCloseTestFixture.APPROVER_A}, 1),
                'A19-INV-SUBMIT').approvalRequestId;
            List<SABApprovalService.SubmissionRequest> bad = new List<SABApprovalService.SubmissionRequest>{
                SABApprovalCloseTestFixture.submission(new List<String>{SABApprovalCloseTestFixture.APPROVER_B}, 1),
                SABApprovalCloseTestFixture.submission(new List<String>{SABApprovalCloseTestFixture.REQUESTER}, 1),
                SABApprovalCloseTestFixture.submission(new List<String>{SABApprovalCloseTestFixture.APPROVER_A, SABApprovalCloseTestFixture.APPROVER_A}, 1),
                SABApprovalCloseTestFixture.submission(new List<String>{SABApprovalCloseTestFixture.OUTSIDER}, 1)};
            SABApprovalService.SubmissionRequest wrongType = SABApprovalCloseTestFixture.submission(new List<String>{SABApprovalCloseTestFixture.APPROVER_A}, 1);
            wrongType.sourceType = 'Budget__c';
            bad.add(wrongType);
            SABApprovalService.SubmissionRequest noCompany = SABApprovalCloseTestFixture.submission(new List<String>{SABApprovalCloseTestFixture.APPROVER_A}, 1);
            noCompany.sourceType = 'User';
            noCompany.sourceRecordId = UserInfo.getUserId();
            bad.add(noCompany);
            Integer n = 0;
            for (SABApprovalService.SubmissionRequest r : bad) {
                try {
                    SABApprovalService.submit(r, 'A19-BAD-' + n++);
                } catch (SABApprovalService.ApprovalException ex) {
                    messages.add(ex.getMessage());
                }
            }
            invalidated = SABApprovalService.invalidate('GL_Account__c', SABApprovalCloseTestFixture.sourceId(), 2);
            direct = Database.update(new Approval_Request__c(Id = requestId, Status__c = 'Approved'), false, AccessLevel.SYSTEM_MODE);
        }
        Id freshRequest;
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.REQUESTER)) {
            freshRequest = SABApprovalService.submit(SABApprovalCloseTestFixture.submission(new List<String>{SABApprovalCloseTestFixture.APPROVER_A}, 2),
                'A19-INV-RESUBMIT').approvalRequestId;
        }
        System.runAs(SABApprovalCloseTestFixture.user(SABApprovalCloseTestFixture.APPROVER_B)) {
            try {
                SABApprovalService.decide(steps(freshRequest).get(1).Id, 'Approved', null, 'A19-NOT-MINE');
            } catch (SABApprovalService.ApprovalException ex) {
                wrongAssignee = ex.getMessage();
            }
        }
        SABTestGovernor.stopTest();
        List<String> fragments = new List<String>{'already has a Pending approval', 'requester cannot be an approver', 'distinct users',
            'active grant to the company', 'does not match the source type', 'company-scoped source record'};
        System.assertEquals(fragments.size(), messages.size(), 'Every invalid submission was refused: ' + messages);
        for (Integer i = 0; i < fragments.size(); i++) {
            System.assert(messages[i].contains(fragments[i]), 'Expected "' + fragments[i] + '" but got: ' + messages[i]);
        }
        System.assertEquals(1, invalidated, 'The version-1 request is invalidated by version 2.');
        System.assertEquals(1, [SELECT COUNT() FROM Approval_Request__c WHERE Status__c = 'Invalidated' WITH SYSTEM_MODE], 'Invalidated status.');
        System.assertEquals(false, direct.isSuccess(), 'Approval requests are system records.');
        System.assert(wrongAssignee != null && wrongAssignee.contains('Only the assignee'), 'Only the assignee decides: ' + wrongAssignee);
    }
}
