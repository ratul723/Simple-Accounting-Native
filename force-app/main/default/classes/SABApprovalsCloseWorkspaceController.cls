/**
 * G22E: controller for c/sabApprovalsWorkspace (approvals inbox and month-end close checklist).
 *
 * Read only. Actions call the G19 services directly, unchanged: SABApprovalService.decide / cancel and
 * SABCloseTaskService.generateChecklist / assign / updateStatus, each status change with a request key.
 *
 * The inbox is SABApprovalService.getInbox (current steps waiting on the running user) narrowed to the selected
 * company. "Submitted by you" lists the user's Pending requests in the company with their next approver. The
 * checklist is SABCloseTaskService.getChecklist with assignee names and the grant holders who can be assigned.
 */
public with sharing class SABApprovalsCloseWorkspaceController {

    private static final String STATUS_PENDING = 'Pending';

    public class WorkspaceData {
        @AuraEnabled public Boolean canDecide { get; set; }
        @AuraEnabled public Boolean canRequest { get; set; }
        @AuraEnabled public Boolean canManageClose { get; set; }
        @AuraEnabled public Id currentPeriodId { get; set; }
        @AuraEnabled public List<InboxRow> inbox { get; set; }
        @AuraEnabled public List<RequestRow> myRequests { get; set; }
        @AuraEnabled public List<PeriodRow> periods { get; set; }
    }

    public class InboxRow {
        @AuraEnabled public Id approvalStepId { get; set; }
        @AuraEnabled public Id approvalRequestId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String sourceType { get; set; }
        @AuraEnabled public String sourceLabel { get; set; }
        @AuraEnabled public String sourceBusinessKey { get; set; }
        @AuraEnabled public Decimal sequence { get; set; }
        @AuraEnabled public String requestedByName { get; set; }
        @AuraEnabled public Datetime requestedAt { get; set; }
    }

    public class RequestRow {
        @AuraEnabled public Id approvalRequestId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String sourceLabel { get; set; }
        @AuraEnabled public String sourceBusinessKey { get; set; }
        @AuraEnabled public Datetime requestedAt { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String nextApprover { get; set; }
    }

    public class PeriodRow {
        @AuraEnabled public Id periodId { get; set; }
        @AuraEnabled public String periodKey { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date endDate { get; set; }
        @AuraEnabled public String status { get; set; }
    }

    public class ChecklistData {
        @AuraEnabled public Id periodId { get; set; }
        @AuraEnabled public String periodKey { get; set; }
        @AuraEnabled public String periodStatus { get; set; }
        @AuraEnabled public Integer total { get; set; }
        @AuraEnabled public Integer complete { get; set; }
        @AuraEnabled public Integer blocked { get; set; }
        @AuraEnabled public Boolean readyToClose { get; set; }
        @AuraEnabled public List<TaskRow> tasks { get; set; }
        @AuraEnabled public List<Option> assignees { get; set; }
    }

    public class TaskRow {
        @AuraEnabled public Id taskId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String taskKey { get; set; }
        @AuraEnabled public Decimal sequence { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Id assigneeId { get; set; }
        @AuraEnabled public String assigneeName { get; set; }
        @AuraEnabled public Boolean assignedToMe { get; set; }
        @AuraEnabled public Date dueDate { get; set; }
        @AuraEnabled public Boolean evidenceRequired { get; set; }
        @AuraEnabled public String evidenceReference { get; set; }
        @AuraEnabled public String blockedReason { get; set; }
    }

    public class Option {
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public String label { get; set; }

        Option(String value, String label) {
            this.value = value;
            this.label = label;
        }
    }

    @AuraEnabled
    public static WorkspaceData getWorkspace(Id companyId) {
        assertView(companyId);
        try {
            WorkspaceData data = new WorkspaceData();
            data.canDecide = SABPermissionService.hasPermission('SAB_Approve_Financial_Document');
            data.canRequest = SABPermissionService.hasPermission('SAB_Request_Approval');
            data.canManageClose = SABPermissionService.hasPermission('SAB_Manage_Close_Tasks');
            data.inbox = inbox(companyId);
            data.myRequests = myRequests(companyId);
            data.periods = periods(companyId);
            Date today = Date.today();
            for (PeriodRow period : data.periods) {
                if (period.startDate <= today && period.endDate >= today) {
                    data.currentPeriodId = period.periodId;
                }
            }
            if (data.currentPeriodId == null && !data.periods.isEmpty()) {
                data.currentPeriodId = data.periods[data.periods.size() - 1].periodId;
            }
            return data;
        } catch (QueryException ex) {
            throw auraError('Approvals and close could not be loaded: ' + ex.getMessage());
        }
    }

    @AuraEnabled
    public static ChecklistData getChecklist(Id companyId, Id periodId) {
        assertView(companyId);
        if (periodId == null) {
            throw auraError('Accounting period is required.');
        }
        try {
            List<Accounting_Period__c> periods = [
                SELECT Id, Period_Key__c, Status__c, Company__c
                FROM Accounting_Period__c
                WHERE Id = :periodId
                WITH USER_MODE
                LIMIT 1
            ];
            if (periods.isEmpty() || periods[0].Company__c != companyId) {
                throw auraError('The accounting period does not belong to this company.');
            }
            SABCloseTaskService.Checklist checklist = SABCloseTaskService.getChecklist(periodId);
            ChecklistData data = new ChecklistData();
            data.periodId = periodId;
            data.periodKey = periods[0].Period_Key__c;
            data.periodStatus = periods[0].Status__c;
            data.total = checklist.total;
            data.complete = checklist.complete;
            data.blocked = checklist.blocked;
            data.readyToClose = checklist.readyToClose;
            data.assignees = new List<Option>();
            Map<Id, String> names = new Map<Id, String>();
            for (Company_User_Access__c grant : [
                SELECT User__c, User__r.Name
                FROM Company_User_Access__c
                WHERE Company__c = :companyId AND Is_Active__c = true
                WITH USER_MODE
                ORDER BY User__r.Name
                LIMIT 500
            ]) {
                if (!names.containsKey(grant.User__c)) {
                    names.put(grant.User__c, grant.User__r.Name);
                    data.assignees.add(new Option(grant.User__c, grant.User__r.Name));
                }
            }
            data.tasks = new List<TaskRow>();
            Id userId = UserInfo.getUserId();
            for (SABCloseTaskService.TaskView task : checklist.tasks) {
                data.tasks.add(taskRow(task, names, userId));
            }
            return data;
        } catch (SABCloseTaskService.CloseTaskException ex) {
            throw auraError(ex.getMessage());
        } catch (QueryException ex) {
            throw auraError('The close checklist could not be loaded: ' + ex.getMessage());
        }
    }

    private static TaskRow taskRow(SABCloseTaskService.TaskView task, Map<Id, String> names, Id userId) {
        TaskRow row = new TaskRow();
        row.taskId = task.taskId;
        row.name = task.name;
        row.taskKey = task.taskKey;
        row.sequence = task.sequence;
        row.status = task.status;
        row.assigneeId = task.assigneeId;
        row.assigneeName = task.assigneeId == null ? null : names.get(task.assigneeId);
        row.assignedToMe = task.assigneeId == userId;
        row.dueDate = task.dueDate;
        row.evidenceRequired = task.evidenceRequired == true;
        row.evidenceReference = task.evidenceReference;
        row.blockedReason = task.blockedReason;
        return row;
    }

    private static List<InboxRow> inbox(Id companyId) {
        List<InboxRow> rows = new List<InboxRow>();
        List<SABApprovalService.InboxItem> items = SABApprovalService.getInbox();
        if (items.isEmpty()) {
            return rows;
        }
        Set<Id> requestIds = new Set<Id>();
        for (SABApprovalService.InboxItem item : items) {
            requestIds.add(item.approvalRequestId);
        }
        Map<Id, Approval_Request__c> requests = new Map<Id, Approval_Request__c>([
            SELECT Id, Name, Company__c
            FROM Approval_Request__c
            WHERE Id IN :requestIds
            WITH USER_MODE
        ]);
        for (SABApprovalService.InboxItem item : items) {
            Approval_Request__c request = requests.get(item.approvalRequestId);
            if (request == null || request.Company__c != companyId) {
                continue;
            }
            InboxRow row = new InboxRow();
            row.approvalStepId = item.approvalStepId;
            row.approvalRequestId = item.approvalRequestId;
            row.name = request.Name;
            row.sourceType = item.sourceType;
            row.sourceLabel = sourceLabel(item.sourceType);
            row.sourceBusinessKey = item.sourceBusinessKey;
            row.sequence = item.sequence;
            row.requestedByName = item.requestedByName;
            row.requestedAt = item.requestedAt;
            rows.add(row);
        }
        return rows;
    }

    private static List<RequestRow> myRequests(Id companyId) {
        List<RequestRow> rows = new List<RequestRow>();
        Id userId = UserInfo.getUserId();
        Map<Id, RequestRow> byId = new Map<Id, RequestRow>();
        for (Approval_Request__c request : [
            SELECT Id, Name, Source_Type__c, Source_Business_Key__c, Requested_At__c, Status__c
            FROM Approval_Request__c
            WHERE Company__c = :companyId AND Requested_By__c = :userId AND Status__c = :STATUS_PENDING
            WITH USER_MODE
            ORDER BY Requested_At__c DESC
            LIMIT 50
        ]) {
            RequestRow row = new RequestRow();
            row.approvalRequestId = request.Id;
            row.name = request.Name;
            row.sourceLabel = sourceLabel(request.Source_Type__c);
            row.sourceBusinessKey = request.Source_Business_Key__c;
            row.requestedAt = request.Requested_At__c;
            row.status = request.Status__c;
            byId.put(request.Id, row);
            rows.add(row);
        }
        if (byId.isEmpty()) {
            return rows;
        }
        Set<Id> requestIds = byId.keySet();
        for (Approval_Step__c step : [
            SELECT Approval_Request__c, Assignee_User__r.Name
            FROM Approval_Step__c
            WHERE Approval_Request__c IN :requestIds AND Decision__c = :STATUS_PENDING
            WITH USER_MODE
            ORDER BY Sequence__c ASC
        ]) {
            RequestRow row = byId.get(step.Approval_Request__c);
            if (row.nextApprover == null && step.Assignee_User__r != null) {
                row.nextApprover = step.Assignee_User__r.Name;
            }
        }
        return rows;
    }

    private static List<PeriodRow> periods(Id companyId) {
        List<PeriodRow> rows = new List<PeriodRow>();
        Date today = Date.today();
        Date fromDate = today.addMonths(-12);
        Date toDate = today.addMonths(3);
        for (Accounting_Period__c period : [
            SELECT Id, Period_Key__c, Start_Date__c, End_Date__c, Status__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId AND Start_Date__c >= :fromDate AND Start_Date__c <= :toDate
            WITH USER_MODE
            ORDER BY Start_Date__c ASC
            LIMIT 24
        ]) {
            PeriodRow row = new PeriodRow();
            row.periodId = period.Id;
            row.periodKey = period.Period_Key__c;
            row.startDate = period.Start_Date__c;
            row.endDate = period.End_Date__c;
            row.status = period.Status__c;
            rows.add(row);
        }
        return rows;
    }

    @TestVisible
    private static String sourceLabel(String sourceType) {
        if (String.isBlank(sourceType)) {
            return null;
        }
        Schema.SObjectType type = Schema.getGlobalDescribe().get(sourceType);
        return type == null ? sourceType : type.getDescribe(SObjectDescribeOptions.DEFERRED).getLabel();
    }

    private static void assertView(Id companyId) {
        try {
            SABApprovalsCloseReadPolicy.assertCanView(companyId);
        } catch (SABApprovalsCloseReadPolicy.ApprovalsCloseAccessException ex) {
            throw auraError(ex.getMessage());
        }
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}