/**
 * G22F: controller for c/sabImportsWorkspace (Import and integration center).
 *
 * Read only. Actions call the G20 service directly, unchanged: SABImportService.stage / validate / commitImport
 * (commit with a request key; staging the same file replays its job by file hash). The integration outbox is
 * SABIntegrationLogService.getRequests; retries stay with the scheduler (dueForRetry), so the log is read only.
 */
public with sharing class SABImportsWorkspaceController {

    private static final Integer MAX_JOBS = 50;
    private static final Integer MAX_ROWS = 500;
    private static final Integer MAX_REQUESTS = 100;

    public class WorkspaceData {
        @AuraEnabled public Boolean canManage { get; set; }
        @AuraEnabled public Boolean canCommit { get; set; }
        @AuraEnabled public Boolean canViewLog { get; set; }
        @AuraEnabled public List<String> importTypes { get; set; }
        @AuraEnabled public List<JobRow> jobs { get; set; }
        @AuraEnabled public List<SABIntegrationLogService.LogView> requests { get; set; }
    }

    public class JobRow {
        @AuraEnabled public Id importJobId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String importType { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Integer rowCount { get; set; }
        @AuraEnabled public Integer validCount { get; set; }
        @AuraEnabled public Integer errorCount { get; set; }
        @AuraEnabled public String requestedBy { get; set; }
        @AuraEnabled public Datetime requestedAt { get; set; }
    }

    public class RowView {
        @AuraEnabled public Id rowId { get; set; }
        @AuraEnabled public Integer rowNumber { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String message { get; set; }
        @AuraEnabled public String valuesJson { get; set; }
        @AuraEnabled public String committedRecordId { get; set; }
    }

    @AuraEnabled
    public static WorkspaceData getWorkspace(Id companyId) {
        assertView(companyId);
        try {
            WorkspaceData data = new WorkspaceData();
            data.canManage = SABPermissionService.hasPermission('SAB_Manage_Imports');
            data.canCommit = SABPermissionService.hasPermission('SAB_Commit_Imports');
            data.canViewLog = SABPermissionService.hasPermission('SAB_View_Integration_Log');
            data.importTypes = new List<String>{ 'Chart of Accounts', 'Journal Entries', 'Opening Balances' };
            data.jobs = jobs(companyId);
            data.requests = data.canViewLog ? SABIntegrationLogService.getRequests(companyId, MAX_REQUESTS)
                : new List<SABIntegrationLogService.LogView>();
            return data;
        } catch (QueryException ex) {
            throw auraError('The Import and integration center could not be loaded: ' + ex.getMessage());
        }
    }

    /** Rows of one import job, errors first, then by row number. */
    @AuraEnabled
    public static List<RowView> getRows(Id companyId, Id importJobId) {
        assertView(companyId);
        if (importJobId == null) {
            throw auraError('Import job is required.');
        }
        try {
            List<Import_Job__c> owners = [SELECT Company__c FROM Import_Job__c WHERE Id = :importJobId WITH USER_MODE LIMIT 1];
            if (owners.isEmpty() || owners[0].Company__c != companyId) {
                throw auraError('The import job does not belong to this company.');
            }
            List<RowView> errors = new List<RowView>();
            List<RowView> others = new List<RowView>();
            for (Import_Row__c row : [
                SELECT Id, Row_Number__c, Validation_Status__c, Validation_Message__c, Parsed_Value_JSON__c, Committed_Record_Id__c
                FROM Import_Row__c
                WHERE Import_Job__c = :importJobId
                WITH USER_MODE
                ORDER BY Row_Number__c
                LIMIT :MAX_ROWS
            ]) {
                RowView view = new RowView();
                view.rowId = row.Id;
                view.rowNumber = row.Row_Number__c == null ? null : row.Row_Number__c.intValue();
                view.status = row.Validation_Status__c;
                view.message = row.Validation_Message__c;
                view.valuesJson = row.Parsed_Value_JSON__c;
                view.committedRecordId = row.Committed_Record_Id__c;
                if (view.status == 'Error') {
                    errors.add(view);
                } else {
                    others.add(view);
                }
            }
            errors.addAll(others);
            return errors;
        } catch (QueryException ex) {
            throw auraError('Import rows could not be loaded: ' + ex.getMessage());
        }
    }

    private static List<JobRow> jobs(Id companyId) {
        List<JobRow> rows = new List<JobRow>();
        for (Import_Job__c job : [
            SELECT Id, Name, Import_Type__c, Status__c, Row_Count__c, Valid_Row_Count__c, Error_Row_Count__c, Requested_At__c,
                   Requested_By__r.Name, CreatedDate
            FROM Import_Job__c
            WHERE Company__c = :companyId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT :MAX_JOBS
        ]) {
            JobRow row = new JobRow();
            row.importJobId = job.Id;
            row.name = job.Name;
            row.importType = job.Import_Type__c;
            row.status = job.Status__c;
            row.rowCount = toInteger(job.Row_Count__c);
            row.validCount = toInteger(job.Valid_Row_Count__c);
            row.errorCount = toInteger(job.Error_Row_Count__c);
            row.requestedBy = job.Requested_By__r == null ? null : job.Requested_By__r.Name;
            row.requestedAt = job.Requested_At__c == null ? job.CreatedDate : job.Requested_At__c;
            rows.add(row);
        }
        return rows;
    }

    private static Integer toInteger(Decimal value) {
        return value == null ? 0 : value.intValue();
    }

    private static void assertView(Id companyId) {
        try {
            SABImportsReadPolicy.assertCanView(companyId);
        } catch (SABImportsReadPolicy.ImportsAccessException ex) {
            throw auraError(ex.getMessage());
        }
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}