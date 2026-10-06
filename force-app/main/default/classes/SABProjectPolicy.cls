/** G11A: rules shared by native UI, imports and Apex writes. No posting is performed. */
public with sharing class SABProjectPolicy {
    private static final Set<String> STATUSES = new Set<String>{'Planned', 'Active', 'Complete', 'Cancelled'};

    public static void handleTrigger() {
        if (Trigger.isDelete) {
            preventDelete((List<Project__c>) Trigger.old);
        } else if (Trigger.isUndelete) {
            afterUndelete((List<Project__c>) Trigger.new);
        } else {
            beforeSave((List<Project__c>) Trigger.new, Trigger.isUpdate ? (Map<Id, Project__c>) Trigger.oldMap : null);
        }
    }

    public static void beforeSave(List<Project__c> rows, Map<Id, Project__c> oldMap) {
        Boolean permitted = FeatureManagement.checkPermission('SAB_Manage_Projects');
        Set<Id> companies = SABCompanyAccessService.getAccessibleCompanyIds();
        for (Project__c row : rows) {
            if (!permitted || !companies.contains(row.Company__c)) {
                row.addError('Project management requires Manage Projects permission and active company access.');
                continue;
            }
            Project__c previous = oldMap == null ? null : oldMap.get(row.Id);
            String code = normalizeCode(row.Project_Code__c);
            if (String.isBlank(code)) {
                row.Project_Code__c.addError('Enter a project code.');
                continue;
            }
            if (previous != null && (row.Company__c != previous.Company__c || code != normalizeCode(previous.Project_Code__c))) {
                row.addError('Project company and code cannot change after creation. Create a new project instead.');
                continue;
            }
            row.Project_Code__c = code;
            // Never trust a supplied key. The database unique constraint arbitrates concurrent saves.
            row.Company_Project_Key__c = String.valueOf(row.Company__c) + ':' + code;
            if (previous == null && String.isBlank(row.Status__c)) {
                row.Status__c = 'Planned';
            }
            if (!STATUSES.contains(row.Status__c)) {
                row.Status__c.addError('Select a valid project status.');
            } else if (previous == null && row.Status__c != 'Planned') {
                row.Status__c.addError('New projects must start as Planned.');
            } else if (previous != null && !validTransition(previous.Status__c, row.Status__c)) {
                row.Status__c.addError('Allowed transitions: Planned to Active or Cancelled; Active to Complete or Cancelled.');
            }
            if (row.Start_Date__c != null && row.End_Date__c != null && row.End_Date__c < row.Start_Date__c) {
                row.End_Date__c.addError('Project end date must be on or after its start date.');
            }
        }
    }

    public static void preventDelete(List<Project__c> rows) {
        for (Project__c row : rows) {
            row.addError('Projects are retained for accounting history. Use Cancelled status instead of deleting.');
        }
    }

    public static void afterUndelete(List<Project__c> rows) {
        Boolean permitted = FeatureManagement.checkPermission('SAB_Manage_Projects');
        Set<Id> companies = SABCompanyAccessService.getAccessibleCompanyIds();
        for (Project__c row : rows) {
            if (!permitted || !companies.contains(row.Company__c)) {
                row.addError('Restoring projects requires Manage Projects permission and active company access.');
            }
        }
    }

    private static String normalizeCode(String value) {
        return String.isBlank(value) ? null : value.trim().toUpperCase();
    }

    private static Boolean validTransition(String beforeStatus, String afterStatus) {
        if (beforeStatus == afterStatus) { return true; }
        // Existing unclassified projects can be brought into the new lifecycle explicitly.
        if (String.isBlank(beforeStatus)) { return afterStatus == 'Planned'; }
        if (beforeStatus == 'Planned') { return afterStatus == 'Active' || afterStatus == 'Cancelled'; }
        if (beforeStatus == 'Active') { return afterStatus == 'Complete' || afterStatus == 'Cancelled'; }
        return false;
    }
}
