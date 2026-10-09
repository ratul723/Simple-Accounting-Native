/**
 * G19: Generic approval engine for company-scoped records.
 *
 *   submit      SAB_Request_Approval              Pending request with ordered steps (1-10 distinct approvers who hold a
 *                                                 grant to the company and are not the requester); one Pending request per record
 *   decide      SAB_Approve_Financial_Document    the assignee of the current (lowest pending) step approves or rejects;
 *                                                 the last approval approves the request; a rejection (comment required)
 *                                                 rejects it and skips the remaining steps
 *   cancel      SAB_Request_Approval              the requester cancels a Pending request; remaining steps are skipped
 *   invalidate  module API                        Pending requests for an older source version become Invalidated
 *   isApproved  module API                        true when the record version has an Approved request
 *   getInbox    read                              current steps waiting on the running user
 *
 * The source record must have a Company__c field matching the request company. Every user action is idempotent by
 * request key and audited in Business_Action__c.
 */
public with sharing class SABApprovalService {
    public class ApprovalException extends Exception {}

    private static final String REQUEST_PERMISSION = 'SAB_Request_Approval';
    private static final String DECIDE_PERMISSION = 'SAB_Approve_Financial_Document';
    private static final Integer MAX_STEPS = 10;
    private static final String SOURCE_TYPE = 'Approval_Request__c';

    public class SubmissionRequest {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String sourceType { get; set; }
        @AuraEnabled public Id sourceRecordId { get; set; }
        @AuraEnabled public Integer sourceVersion { get; set; }
        @AuraEnabled public String sourceBusinessKey { get; set; }
        @AuraEnabled public String policyVersion { get; set; }
        @AuraEnabled public List<Id> approverIds { get; set; }
    }

    public class ActionResult {
        @AuraEnabled public Id approvalRequestId;
        @AuraEnabled public String status;
        @AuraEnabled public Integer pendingSteps;
        @AuraEnabled public Boolean replay;
    }

    public class InboxItem {
        @AuraEnabled public Id approvalStepId;
        @AuraEnabled public Id approvalRequestId;
        @AuraEnabled public String sourceType;
        @AuraEnabled public String sourceRecordId;
        @AuraEnabled public String sourceBusinessKey;
        @AuraEnabled public Decimal sequence;
        @AuraEnabled public String requestedByName;
        @AuraEnabled public Datetime requestedAt;
    }

    // ---------------------------------------------------------------- submit

    @AuraEnabled
    public static ActionResult submit(SubmissionRequest request, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(REQUEST_PERMISSION, 'Approval request permission is required.');
        if (request == null || request.companyId == null || String.isBlank(request.sourceType) || request.sourceRecordId == null
            || request.sourceVersion == null || String.isBlank(request.policyVersion) || request.approverIds == null) {
            throw new ApprovalException('Company, source type, source record, source version, policy version and approvers are required.');
        }
        SABCompanyAccessService.assertCompanyAccess(request.companyId);
        Store store = new Store();
        Approval_Request__c existing = store.requestByKey(key);
        if (existing != null) {
            if (existing.Source_Record_Id__c != String.valueOf(request.sourceRecordId)) {
                throw new ApprovalException('Request key has already been used for a different approval.');
            }
            return result(existing, store.pendingCount(existing.Id), true);
        }
        assertSource(request, store);
        List<Id> approvers = new List<Id>();
        Set<Id> seen = new Set<Id>();
        for (Id approver : request.approverIds) {
            if (approver == null || !seen.add(approver)) {
                throw new ApprovalException('Approvers must be distinct users.');
            }
            if (approver == UserInfo.getUserId()) {
                throw new ApprovalException('The requester cannot be an approver.');
            }
            approvers.add(approver);
        }
        if (approvers.isEmpty() || approvers.size() > MAX_STEPS) {
            throw new ApprovalException('An approval needs between 1 and ' + MAX_STEPS + ' approvers.');
        }
        Set<Id> granted = store.grantedUsers(request.companyId, seen);
        if (!granted.containsAll(seen)) {
            throw new ApprovalException('Every approver needs an active grant to the company.');
        }
        if (store.pendingFor(request.sourceType, String.valueOf(request.sourceRecordId)) != null) {
            throw new ApprovalException('This record already has a Pending approval request.');
        }
        Approval_Request__c approval = new Approval_Request__c(Company__c = request.companyId, Source_Type__c = request.sourceType,
            Source_Record_Id__c = String.valueOf(request.sourceRecordId), Source_Version__c = request.sourceVersion,
            Source_Business_Key__c = request.sourceBusinessKey == null ? null : request.sourceBusinessKey.left(180),
            Policy_Version__c = request.policyVersion.trim().left(80), Request_Key__c = key, Requested_By__c = UserInfo.getUserId(),
            Requested_At__c = System.now(), Status__c = 'Pending');
        List<Approval_Step__c> steps = new List<Approval_Step__c>();
        for (Integer i = 0; i < approvers.size(); i++) {
            steps.add(new Approval_Step__c(Sequence__c = i + 1, Assignee_User__c = approvers[i], Decision__c = 'Pending'));
        }
        new Writer().submit(approval, steps, audit(request.companyId, 'APPROVAL_SUBMITTED', key, null,
            request.sourceType + ' ' + request.sourceRecordId + ' submitted to ' + steps.size() + ' approvers.'));
        return result(approval, steps.size(), false);
    }

    // ---------------------------------------------------------------- decide

    @AuraEnabled
    public static ActionResult decide(Id approvalStepId, String decision, String comment, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(DECIDE_PERMISSION, 'Approval decision permission is required.');
        if (approvalStepId == null || (decision != 'Approved' && decision != 'Rejected')) {
            throw new ApprovalException('An approval step and a decision of Approved or Rejected are required.');
        }
        if (decision == 'Rejected' && String.isBlank(comment)) {
            throw new ApprovalException('A rejection needs a comment.');
        }
        Store store = new Store();
        Approval_Step__c step = store.lockStep(approvalStepId);
        Approval_Request__c approval = store.lockRequest(step.Approval_Request__c);
        SABCompanyAccessService.assertCompanyAccess(approval.Company__c);
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            if (prior.Action__c != 'APPROVAL_DECIDED' || prior.Source_Record_Id__c != String.valueOf(approval.Id)) {
                throw new ApprovalException('Request key has already been used for a different approval action.');
            }
            return result(approval, store.pendingCount(approval.Id), true);
        }
        if (approval.Status__c != 'Pending' || step.Decision__c != 'Pending') {
            throw new ApprovalException('Only a pending step of a Pending request can be decided.');
        }
        if (step.Assignee_User__c != UserInfo.getUserId()) {
            throw new ApprovalException('Only the assignee of this step can decide it.');
        }
        List<Approval_Step__c> pending = store.pendingSteps(approval.Id);
        if (pending[0].Id != step.Id) {
            throw new ApprovalException('Earlier approval steps must be decided first.');
        }
        List<Approval_Step__c> changes = new List<Approval_Step__c>{new Approval_Step__c(Id = step.Id, Decision__c = decision,
            Decision_By__c = UserInfo.getUserId(), Decision_At__c = System.now(), Comment__c = comment)};
        String newStatus = 'Pending';
        if (decision == 'Rejected') {
            newStatus = 'Rejected';
            for (Integer i = 1; i < pending.size(); i++) {
                changes.add(new Approval_Step__c(Id = pending[i].Id, Decision__c = 'Skipped'));
            }
        } else if (pending.size() == 1) {
            newStatus = 'Approved';
        }
        Approval_Request__c requestChange = newStatus == 'Pending' ? null
            : new Approval_Request__c(Id = approval.Id, Status__c = newStatus, Completed_At__c = System.now());
        new Writer().decide(changes, requestChange, audit(approval.Company__c, 'APPROVAL_DECIDED', key, approval.Id,
            'Step ' + step.Sequence__c + ' ' + decision.toLowerCase() + (String.isBlank(comment) ? '.' : ': ' + comment.left(200))));
        approval.Status__c = newStatus;
        return result(approval, newStatus == 'Pending' ? pending.size() - 1 : 0, false);
    }

    // ---------------------------------------------------------------- cancel

    @AuraEnabled
    public static ActionResult cancel(Id approvalRequestId, String reason, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(REQUEST_PERMISSION, 'Approval request permission is required.');
        if (approvalRequestId == null || String.isBlank(reason) || reason.trim().length() > 255) {
            throw new ApprovalException('An approval request and a reason of up to 255 characters are required.');
        }
        Store store = new Store();
        Approval_Request__c approval = store.lockRequest(approvalRequestId);
        SABCompanyAccessService.assertCompanyAccess(approval.Company__c);
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            if (prior.Action__c != 'APPROVAL_CANCELLED' || prior.Source_Record_Id__c != String.valueOf(approval.Id)) {
                throw new ApprovalException('Request key has already been used for a different approval action.');
            }
            return result(approval, 0, true);
        }
        if (approval.Status__c != 'Pending') {
            throw new ApprovalException('Only a Pending approval request can be cancelled.');
        }
        if (approval.Requested_By__c != UserInfo.getUserId()) {
            throw new ApprovalException('Only the requester can cancel an approval request.');
        }
        closePending(approval, 'Cancelled', store, audit(approval.Company__c, 'APPROVAL_CANCELLED', key, approval.Id, reason.trim()));
        approval.Status__c = 'Cancelled';
        return result(approval, 0, false);
    }

    // ------------------------------------------------------------ module API

    /** Invalidates Pending requests for the record whose source version differs from currentVersion; returns how many. */
    public static Integer invalidate(String sourceType, Id sourceRecordId, Integer currentVersion) {
        Store store = new Store();
        Approval_Request__c pending = store.pendingFor(sourceType, String.valueOf(sourceRecordId));
        if (pending == null || pending.Source_Version__c == currentVersion) {
            return 0;
        }
        closePending(store.lockRequest(pending.Id), 'Invalidated', store, audit(pending.Company__c, 'APPROVAL_INVALIDATED',
            ('INVALIDATE|' + pending.Id + '|V' + currentVersion).left(120), pending.Id,
            'Source changed to version ' + currentVersion + '; approval must be requested again.'));
        return 1;
    }

    /** True when this exact source version has an Approved request. */
    public static Boolean isApproved(String sourceType, Id sourceRecordId, Integer sourceVersion) {
        return new Store().approvedExists(sourceType, String.valueOf(sourceRecordId), sourceVersion);
    }

    @AuraEnabled
    public static List<InboxItem> getInbox() {
        List<InboxItem> items = new List<InboxItem>();
        Store store = new Store();
        for (Approval_Step__c step : store.myPendingSteps(UserInfo.getUserId())) {
            List<Approval_Step__c> pending = store.pendingSteps(step.Approval_Request__c);
            if (pending.isEmpty() || pending[0].Id != step.Id || !SABCompanyAccessService.hasCompanyAccess(step.Approval_Request__r.Company__c)) {
                continue;
            }
            InboxItem item = new InboxItem();
            item.approvalStepId = step.Id;
            item.approvalRequestId = step.Approval_Request__c;
            item.sourceType = step.Approval_Request__r.Source_Type__c;
            item.sourceRecordId = step.Approval_Request__r.Source_Record_Id__c;
            item.sourceBusinessKey = step.Approval_Request__r.Source_Business_Key__c;
            item.sequence = step.Sequence__c;
            item.requestedByName = step.Approval_Request__r.Requested_By__r == null ? null : step.Approval_Request__r.Requested_By__r.Name;
            item.requestedAt = step.Approval_Request__r.Requested_At__c;
            items.add(item);
        }
        return items;
    }

    // --------------------------------------------------------------- helpers

    private static void closePending(Approval_Request__c approval, String status, Store store, Business_Action__c audit) {
        List<Approval_Step__c> changes = new List<Approval_Step__c>();
        for (Approval_Step__c s : store.pendingSteps(approval.Id)) {
            changes.add(new Approval_Step__c(Id = s.Id, Decision__c = 'Skipped'));
        }
        new Writer().decide(changes, new Approval_Request__c(Id = approval.Id, Status__c = status, Completed_At__c = System.now()), audit);
    }

    // The source must be a company-scoped record of the request company; the type name is checked against the schema.
    private static void assertSource(SubmissionRequest request, Store store) {
        Schema.SObjectType type = Schema.getGlobalDescribe().get(request.sourceType);
        if (type == null || request.sourceRecordId.getSObjectType() != type) {
            throw new ApprovalException('The source record does not match the source type.');
        }
        if (!type.getDescribe(SObjectDescribeOptions.DEFERRED).fields.getMap().containsKey('company__c')) {
            throw new ApprovalException('Approvals need a company-scoped source record (a Company__c field).');
        }
        Id companyOfSource = store.sourceCompany(type.getDescribe(SObjectDescribeOptions.DEFERRED).getName(), request.sourceRecordId);
        if (companyOfSource != request.companyId) {
            throw new ApprovalException('The source record does not belong to the request company.');
        }
    }

    private static String requireKey(String requestKey) {
        Integer maxLength = Business_Action__c.Request_Key__c.getDescribe().getLength();
        if (String.isBlank(requestKey) || requestKey.trim().length() > maxLength) {
            throw new ApprovalException('Request key is required and must not exceed ' + maxLength + ' characters.');
        }
        return requestKey.trim();
    }

    private static Business_Action__c audit(Id companyId, String actionName, String key, Id approvalId, String reason) {
        return new Business_Action__c(Company__c = companyId, Action__c = actionName, Actor__c = UserInfo.getUserId(),
            Action_At__c = System.now(), Reason__c = reason.left(255), Request_Key__c = key, Source_Type__c = SOURCE_TYPE,
            Source_Record_Id__c = approvalId == null ? null : String.valueOf(approvalId), Source_Version__c = 1);
    }

    private static ActionResult result(Approval_Request__c approval, Integer pendingSteps, Boolean isReplay) {
        ActionResult r = new ActionResult();
        r.approvalRequestId = approval.Id;
        r.status = approval.Status__c;
        r.pendingSteps = pendingSteps;
        r.replay = isReplay;
        return r;
    }

    /** Narrow system reads after the permission and company checks; approvals and steps are read completely. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c FROM Business_Action__c WHERE Request_Key__c = :key
                WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        Approval_Request__c requestByKey(String key) {
            List<Approval_Request__c> rows = [SELECT Id, Status__c, Source_Record_Id__c FROM Approval_Request__c WHERE Request_Key__c = :key
                WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        Approval_Request__c lockRequest(Id requestId) {
            List<Approval_Request__c> rows = [SELECT Id, Company__c, Status__c, Requested_By__c, Source_Type__c, Source_Record_Id__c,
                Source_Version__c FROM Approval_Request__c WHERE Id = :requestId WITH SYSTEM_MODE FOR UPDATE];
            if (rows.isEmpty()) {
                throw new ApprovalException('Approval request not found.');
            }
            return rows[0];
        }
        Approval_Step__c lockStep(Id stepId) {
            List<Approval_Step__c> rows = [SELECT Id, Approval_Request__c, Sequence__c, Assignee_User__c, Decision__c FROM Approval_Step__c
                WHERE Id = :stepId WITH SYSTEM_MODE FOR UPDATE];
            if (rows.isEmpty()) {
                throw new ApprovalException('Approval step not found.');
            }
            return rows[0];
        }
        List<Approval_Step__c> pendingSteps(Id requestId) {
            return [SELECT Id, Sequence__c FROM Approval_Step__c WHERE Approval_Request__c = :requestId AND Decision__c = 'Pending'
                WITH SYSTEM_MODE ORDER BY Sequence__c LIMIT 20];
        }
        Integer pendingCount(Id requestId) {
            return [SELECT COUNT() FROM Approval_Step__c WHERE Approval_Request__c = :requestId AND Decision__c = 'Pending' WITH SYSTEM_MODE];
        }
        Approval_Request__c pendingFor(String sourceType, String sourceRecordId) {
            List<Approval_Request__c> rows = [SELECT Id, Company__c, Source_Version__c FROM Approval_Request__c WHERE Source_Type__c = :sourceType
                AND Source_Record_Id__c = :sourceRecordId AND Status__c = 'Pending' WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        Boolean approvedExists(String sourceType, String sourceRecordId, Integer sourceVersion) {
            return [SELECT COUNT() FROM Approval_Request__c WHERE Source_Type__c = :sourceType AND Source_Record_Id__c = :sourceRecordId
                AND Source_Version__c = :sourceVersion AND Status__c = 'Approved' WITH SYSTEM_MODE] > 0;
        }
        Set<Id> grantedUsers(Id companyId, Set<Id> userIds) {
            Set<Id> result = new Set<Id>();
            Date today = Date.today();
            for (Company_User_Access__c g : [SELECT User__c FROM Company_User_Access__c WHERE Company__c = :companyId AND User__c IN :userIds
                    AND Is_Active__c = true AND Effective_From__c <= :today AND (Effective_To__c = null OR Effective_To__c >= :today)
                    WITH SYSTEM_MODE]) {
                result.add(g.User__c);
            }
            return result;
        }
        Id sourceCompany(String objectName, Id recordId) {
            List<SObject> rows = Database.queryWithBinds('SELECT Company__c FROM ' + objectName + ' WHERE Id = :recordId LIMIT 1',
                new Map<String, Object>{'recordId' => recordId}, AccessLevel.SYSTEM_MODE);
            if (rows.isEmpty()) {
                throw new ApprovalException('The source record was not found.');
            }
            return (Id) rows[0].get('Company__c');
        }
        List<Approval_Step__c> myPendingSteps(Id userId) {
            return [SELECT Id, Approval_Request__c, Sequence__c, Approval_Request__r.Company__c, Approval_Request__r.Source_Type__c,
                Approval_Request__r.Source_Record_Id__c, Approval_Request__r.Source_Business_Key__c, Approval_Request__r.Requested_By__r.Name,
                Approval_Request__r.Requested_At__c FROM Approval_Step__c WHERE Assignee_User__c = :userId AND Decision__c = 'Pending'
                AND Approval_Request__r.Status__c = 'Pending' WITH SYSTEM_MODE ORDER BY Approval_Request__r.Requested_At__c LIMIT 200];
        }
    }

    /** Narrow system writes inside the G19 guard scope, after the service's checks (explicit system mode). */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void submit(Approval_Request__c approval, List<Approval_Step__c> steps, Business_Action__c audit) {
            SABApprovalCloseGuard.beginWrite();
            try {
                insert as system approval;
                for (Approval_Step__c s : steps) {
                    s.Approval_Request__c = approval.Id;
                }
                insert as system steps;
                audit.Source_Record_Id__c = String.valueOf(approval.Id);
                insert as system audit;
            } finally {
                SABApprovalCloseGuard.endWrite();
            }
        }
        void decide(List<Approval_Step__c> steps, Approval_Request__c approval, Business_Action__c audit) {
            SABApprovalCloseGuard.beginWrite();
            try {
                if (!steps.isEmpty()) {
                    update as system steps;
                }
                if (approval != null) {
                    update as system approval;
                }
                insert as system audit;
            } finally {
                SABApprovalCloseGuard.endWrite();
            }
        }
    }
}
