/**
 * G19: Month-end close checklist.
 *
 *   generateChecklist  SAB_Manage_Close_Tasks       creates the period's tasks from SAB_Close_Task_Template__mdt (or the
 *                                                  built-in default list); re-running adds only missing tasks
 *   assign             SAB_Manage_Close_Tasks       sets the assignee (must hold a grant) and optionally the due date
 *   updateStatus       assignee, or SAB_Manage_Close_Tasks
 *                        Not Started -> In Progress / Complete / Blocked; In Progress -> Complete / Blocked;
 *                        Blocked -> In Progress; Complete -> In Progress (reopen, managers only).
 *                        Complete needs evidence when the task requires it; Blocked needs a reason.
 *   getChecklist       read                         tasks, counts and whether the period is ready to close
 *   assertReadyToClose period close gate            called by SABPeriodService.closePeriod: a period with a checklist
 *                                                  closes only when every task is Complete (no checklist: no gate)
 * Tasks can change only while their period is Open. Every status change is idempotent by request key and audited.
 */
public with sharing class SABCloseTaskService {
    public class CloseTaskException extends Exception {}

    private static final String MANAGE = 'SAB_Manage_Close_Tasks';
    private static final String SOURCE_TYPE = 'Close_Task__c';
    private static final Map<String, Set<String>> TRANSITIONS = new Map<String, Set<String>>{
        'Not Started' => new Set<String>{'In Progress', 'Complete', 'Blocked'},
        'In Progress' => new Set<String>{'Complete', 'Blocked'},
        'Blocked' => new Set<String>{'In Progress'},
        'Complete' => new Set<String>{'In Progress'}};

    // Built-in checklist used when no active SAB_Close_Task_Template__mdt records exist: key, name, due offset, evidence.
    private static final List<List<Object>> DEFAULT_TEMPLATE = new List<List<Object>>{
        new List<Object>{'BANK_REC', 'Reconcile every bank account', 3, true},
        new List<Object>{'AP_CUTOFF', 'Review supplier bills and accruals at cut-off', 3, false},
        new List<Object>{'AR_REVIEW', 'Review receivables and aging', 4, false},
        new List<Object>{'PAYROLL', 'Post payroll and settle net pay', 4, false},
        new List<Object>{'DEPRECIATION', 'Post fixed asset depreciation', 5, false},
        new List<Object>{'FX_REVAL', 'Run foreign currency revaluation', 5, false},
        new List<Object>{'ALLOCATIONS', 'Post cost allocations', 6, false},
        new List<Object>{'INTERCOMPANY', 'Agree intercompany balances', 6, true},
        new List<Object>{'TAX', 'Prepare the period tax return', 7, false},
        new List<Object>{'TB_REVIEW', 'Review the trial balance and sign off', 8, true}};

    // Test seam: templates supplied in memory (custom metadata cannot be inserted in tests).
    @TestVisible private static List<SAB_Close_Task_Template__mdt> templateOverride;

    public class TaskView {
        @AuraEnabled public Id taskId;
        @AuraEnabled public String name;
        @AuraEnabled public String taskKey;
        @AuraEnabled public Decimal sequence;
        @AuraEnabled public String status;
        @AuraEnabled public Id assigneeId;
        @AuraEnabled public Date dueDate;
        @AuraEnabled public Boolean evidenceRequired;
        @AuraEnabled public String evidenceReference;
        @AuraEnabled public String blockedReason;
    }

    public class Checklist {
        @AuraEnabled public Id periodId;
        @AuraEnabled public List<TaskView> tasks = new List<TaskView>();
        @AuraEnabled public Integer total = 0;
        @AuraEnabled public Integer complete = 0;
        @AuraEnabled public Integer blocked = 0;
        @AuraEnabled public Boolean readyToClose = false;
    }

    // -------------------------------------------------------------- generate

    @AuraEnabled
    public static Integer generateChecklist(Id periodId) {
        SABPermissionService.assertPermission(MANAGE, 'Close task management permission is required.');
        Store store = new Store();
        Accounting_Period__c period = store.period(periodId);
        SABCompanyAccessService.assertCompanyAccess(period.Company__c);
        if (period.Status__c != 'Open') {
            throw new CloseTaskException('A checklist can be generated only for an Open period.');
        }
        Set<String> existing = store.taskKeys(period.Id);
        List<Close_Task__c> created = new List<Close_Task__c>();
        for (List<Object> t : templates()) {
            String key = (String) t[0];
            if (existing.contains(key)) {
                continue;
            }
            created.add(new Close_Task__c(Name = ((String) t[1]).left(80), Company__c = period.Company__c, Accounting_Period__c = period.Id,
                Task_Key__c = key, Close_Task_Key__c = (period.Id + '|' + key).left(180), Sequence__c = (Integer) t[4],
                Due_Date__c = period.End_Date__c.addDays((Integer) t[2]), Evidence_Required__c = (Boolean) t[3], Status__c = 'Not Started'));
        }
        if (!created.isEmpty()) {
            new Writer().insertTasks(created);
        }
        return created.size();
    }

    // Active templates in order as {key, name, offsetDays, evidenceRequired, sequence}; defaults when none are configured.
    @TestVisible
    private static List<List<Object>> templates() {
        List<SAB_Close_Task_Template__mdt> rows = new List<SAB_Close_Task_Template__mdt>();
        for (SAB_Close_Task_Template__mdt row : templateOverride != null ? templateOverride : SAB_Close_Task_Template__mdt.getAll().values()) {
            if (row.Is_Active__c == true && String.isNotBlank(row.Task_Key__c)) {
                rows.add(row);
            }
        }
        List<List<Object>> result = new List<List<Object>>();
        if (rows.isEmpty()) {
            Integer sequence = 10;
            for (List<Object> d : DEFAULT_TEMPLATE) {
                result.add(new List<Object>{d[0], d[1], d[2], d[3], sequence});
                sequence += 10;
            }
            return result;
        }
        Map<Integer, List<SAB_Close_Task_Template__mdt>> bySequence = new Map<Integer, List<SAB_Close_Task_Template__mdt>>();
        for (SAB_Close_Task_Template__mdt row : rows) {
            Integer sequence = row.Sequence__c == null ? 9999 : row.Sequence__c.intValue();
            if (!bySequence.containsKey(sequence)) {
                bySequence.put(sequence, new List<SAB_Close_Task_Template__mdt>());
            }
            bySequence.get(sequence).add(row);
        }
        List<Integer> order = new List<Integer>(bySequence.keySet());
        order.sort();
        for (Integer sequence : order) {
            for (SAB_Close_Task_Template__mdt row : bySequence.get(sequence)) {
                result.add(new List<Object>{row.Task_Key__c.trim().toUpperCase(), String.isBlank(row.MasterLabel) ? row.Task_Key__c : row.MasterLabel,
                    row.Due_Offset_Days__c == null ? 0 : row.Due_Offset_Days__c.intValue(), row.Evidence_Required__c == true, sequence});
            }
        }
        return result;
    }

    // ---------------------------------------------------------------- assign

    @AuraEnabled
    public static void assign(Id taskId, Id assigneeId, Date dueDate) {
        SABPermissionService.assertPermission(MANAGE, 'Close task management permission is required.');
        Store store = new Store();
        Close_Task__c task = store.lockTask(taskId);
        SABCompanyAccessService.assertCompanyAccess(task.Company__c);
        if (task.Accounting_Period__r.Status__c != 'Open') {
            throw new CloseTaskException('Tasks of a closed period cannot change.');
        }
        if (assigneeId != null && !store.hasGrant(task.Company__c, assigneeId)) {
            throw new CloseTaskException('The assignee needs an active grant to the company.');
        }
        new Writer().updateTask(new Close_Task__c(Id = task.Id, Assignee__c = assigneeId, Due_Date__c = dueDate == null ? task.Due_Date__c : dueDate),
            null);
    }

    // ---------------------------------------------------------------- status

    @AuraEnabled
    public static TaskView updateStatus(Id taskId, String status, String evidenceReference, String blockedReason, String requestKey) {
        String key = requireKey(requestKey);
        Store store = new Store();
        Close_Task__c task = store.lockTask(taskId);
        SABCompanyAccessService.assertCompanyAccess(task.Company__c);
        Boolean manager = SABPermissionService.hasPermission(MANAGE);
        if (!manager && task.Assignee__c != UserInfo.getUserId()) {
            throw new CloseTaskException('Only the assignee or a close manager can update this task.');
        }
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            if (prior.Action__c != 'CLOSE_TASK_UPDATED' || prior.Source_Record_Id__c != String.valueOf(task.Id)) {
                throw new CloseTaskException('Request key has already been used for a different close task action.');
            }
            return view(task);
        }
        if (task.Accounting_Period__r.Status__c != 'Open') {
            throw new CloseTaskException('Tasks of a closed period cannot change.');
        }
        String current = task.Status__c == null ? 'Not Started' : task.Status__c;
        if (!TRANSITIONS.containsKey(current) || !TRANSITIONS.get(current).contains(status)) {
            throw new CloseTaskException('A ' + current + ' task cannot move to ' + status + '.');
        }
        if (current == 'Complete' && !manager) {
            throw new CloseTaskException('Only a close manager can reopen a completed task.');
        }
        Close_Task__c change = new Close_Task__c(Id = task.Id, Status__c = status);
        if (status == 'Complete') {
            String evidence = evidenceReference == null ? task.Evidence_Reference__c : evidenceReference.trim();
            if (task.Evidence_Required__c == true && String.isBlank(evidence)) {
                throw new CloseTaskException('This task needs an evidence reference to be completed.');
            }
            change.Evidence_Reference__c = evidence == null ? null : evidence.left(255);
            change.Completed_By__c = UserInfo.getUserId();
            change.Completed_At__c = System.now();
            change.Blocked_Reason__c = null;
        } else if (status == 'Blocked') {
            if (String.isBlank(blockedReason)) {
                throw new CloseTaskException('A blocked task needs a reason.');
            }
            change.Blocked_Reason__c = blockedReason.trim().left(255);
        } else {
            change.Blocked_Reason__c = null;
            change.Completed_By__c = null;
            change.Completed_At__c = null;
        }
        new Writer().updateTask(change, new Business_Action__c(Company__c = task.Company__c, Action__c = 'CLOSE_TASK_UPDATED',
            Actor__c = UserInfo.getUserId(), Action_At__c = System.now(), Request_Key__c = key, Source_Type__c = SOURCE_TYPE,
            Source_Record_Id__c = String.valueOf(task.Id), Source_Version__c = 1, Reason__c = (task.Task_Key__c + ': ' + current + ' -> ' + status).left(255)));
        return view(store.lockTask(task.Id));
    }

    // ------------------------------------------------------------- checklist

    @AuraEnabled
    public static Checklist getChecklist(Id periodId) {
        Store store = new Store();
        Accounting_Period__c period = store.period(periodId);
        SABCompanyAccessService.assertCompanyAccess(period.Company__c);
        Checklist c = new Checklist();
        c.periodId = period.Id;
        for (Close_Task__c t : store.tasks(period.Id)) {
            c.tasks.add(view(t));
            c.total++;
            c.complete += t.Status__c == 'Complete' ? 1 : 0;
            c.blocked += t.Status__c == 'Blocked' ? 1 : 0;
        }
        c.readyToClose = c.total == 0 || c.complete == c.total;
        return c;
    }

    /** Period close gate: refuses when the period has a checklist that is not fully complete. One aggregate query. */
    public static void assertReadyToClose(Id periodId) {
        List<AggregateResult> counts = new Store().statusCounts(periodId);
        Integer total = 0;
        Integer complete = 0;
        for (AggregateResult ar : counts) {
            Integer n = (Integer) ar.get('n');
            total += n;
            complete += (String) ar.get('status') == 'Complete' ? n : 0;
        }
        if (total > 0 && complete < total) {
            throw new CloseTaskException('The close checklist is not complete: ' + complete + ' of ' + total + ' tasks are done.');
        }
    }

    // --------------------------------------------------------------- helpers

    private static TaskView view(Close_Task__c t) {
        TaskView v = new TaskView();
        v.taskId = t.Id;
        v.name = t.Name;
        v.taskKey = t.Task_Key__c;
        v.sequence = t.Sequence__c;
        v.status = t.Status__c;
        v.assigneeId = t.Assignee__c;
        v.dueDate = t.Due_Date__c;
        v.evidenceRequired = t.Evidence_Required__c;
        v.evidenceReference = t.Evidence_Reference__c;
        v.blockedReason = t.Blocked_Reason__c;
        return v;
    }

    private static String requireKey(String requestKey) {
        Integer maxLength = Business_Action__c.Request_Key__c.getDescribe().getLength();
        if (String.isBlank(requestKey) || requestKey.trim().length() > maxLength) {
            throw new CloseTaskException('Request key is required and must not exceed ' + maxLength + ' characters.');
        }
        return requestKey.trim();
    }

    /** Narrow system reads after the company checks; the close gate counts every task of the period. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c FROM Business_Action__c WHERE Request_Key__c = :key
                WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        Accounting_Period__c period(Id periodId) {
            List<Accounting_Period__c> rows = [SELECT Id, Company__c, Status__c, End_Date__c FROM Accounting_Period__c WHERE Id = :periodId
                WITH SYSTEM_MODE];
            if (rows.isEmpty()) {
                throw new CloseTaskException('Accounting period not found.');
            }
            return rows[0];
        }
        Set<String> taskKeys(Id periodId) {
            Set<String> keys = new Set<String>();
            for (Close_Task__c t : [SELECT Task_Key__c FROM Close_Task__c WHERE Accounting_Period__c = :periodId WITH SYSTEM_MODE LIMIT 500]) {
                keys.add(t.Task_Key__c);
            }
            return keys;
        }
        Close_Task__c lockTask(Id taskId) {
            List<Close_Task__c> rows = [SELECT Id, Name, Company__c, Accounting_Period__c, Accounting_Period__r.Status__c, Task_Key__c, Sequence__c,
                Status__c, Assignee__c, Due_Date__c, Evidence_Required__c, Evidence_Reference__c, Blocked_Reason__c FROM Close_Task__c
                WHERE Id = :taskId WITH SYSTEM_MODE FOR UPDATE];
            if (rows.isEmpty()) {
                throw new CloseTaskException('Close task not found.');
            }
            return rows[0];
        }
        List<Close_Task__c> tasks(Id periodId) {
            return [SELECT Id, Name, Task_Key__c, Sequence__c, Status__c, Assignee__c, Due_Date__c, Evidence_Required__c, Evidence_Reference__c,
                Blocked_Reason__c FROM Close_Task__c WHERE Accounting_Period__c = :periodId WITH SYSTEM_MODE ORDER BY Sequence__c, Name LIMIT 500];
        }
        List<AggregateResult> statusCounts(Id periodId) {
            return [SELECT Status__c status, COUNT(Id) n FROM Close_Task__c WHERE Accounting_Period__c = :periodId WITH SYSTEM_MODE
                GROUP BY Status__c];
        }
        Boolean hasGrant(Id companyId, Id userId) {
            Date today = Date.today();
            return [SELECT COUNT() FROM Company_User_Access__c WHERE Company__c = :companyId AND User__c = :userId AND Is_Active__c = true
                AND Effective_From__c <= :today AND (Effective_To__c = null OR Effective_To__c >= :today) WITH SYSTEM_MODE] > 0;
        }
    }

    /** Narrow system writes inside the G19 guard scope, after the service's checks (explicit system mode). */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void insertTasks(List<Close_Task__c> tasks) {
            SABApprovalCloseGuard.beginWrite();
            try {
                insert as system tasks;
            } finally {
                SABApprovalCloseGuard.endWrite();
            }
        }
        void updateTask(Close_Task__c task, Business_Action__c audit) {
            SABApprovalCloseGuard.beginWrite();
            try {
                update as system task;
                if (audit != null) {
                    insert as system audit;
                }
            } finally {
                SABApprovalCloseGuard.endWrite();
            }
        }
    }
}
