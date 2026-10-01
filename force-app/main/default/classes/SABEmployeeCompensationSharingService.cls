/**
 * G10A - company-scoped sharing for employee compensation records.
 *
 * Employment__c and Pay_Component__c expose Company__c directly and can use
 * SABCompanyRecordSharingService. Employee__c, Employee_Pay_Component__c and
 * Benefit_Award__c inherit company context through Employment__c, so this
 * service maintains Manual shares for those records.
 *
 * Employee records are intentionally shared to the union of users who have an
 * effective company grant for any company in which the employee has an
 * employment. This preserves historical HR visibility when an employment ends.
 */
public without sharing class SABEmployeeCompensationSharingService {
    private static final String READ_ACCESS = 'Read';

    public static void afterEmploymentChange(
        List<Employment__c> newRecords,
        Map<Id, Employment__c> oldMap
    ) {
        if (newRecords == null || newRecords.isEmpty()) return;
        if (oldMap != null && !oldMap.isEmpty()) {
            Boolean relevant = false;
            for (Employment__c row : newRecords) {
                Employment__c oldRow = oldMap.get(row.Id);
                if (oldRow != null && (oldRow.Employee__c != row.Employee__c || oldRow.Company__c != row.Company__c)) {
                    relevant = true;
                    break;
                }
            }
            if (!relevant) return;
        }

        Set<Id> employmentIds = new Set<Id>();
        for (Employment__c row : newRecords) {
            if (row.Id != null) employmentIds.add(row.Id);
        }
        reconcileFromEmployments(employmentIds);
    }

    public static void afterEmploymentDelete(List<Employment__c> oldRecords) {
        if (oldRecords == null || oldRecords.isEmpty()) return;
        Set<Id> employeeIds = new Set<Id>();
        for (Employment__c row : oldRecords) {
            if (row.Employee__c != null) employeeIds.add(row.Employee__c);
        }
        reconcileEmployees(employeeIds);
    }

    public static void afterPayComponentChange(
        List<Employee_Pay_Component__c> newRecords,
        Map<Id, Employee_Pay_Component__c> oldMap
    ) {
        if (newRecords == null || newRecords.isEmpty()) return;
        if (oldMap != null && !oldMap.isEmpty()) {
            Boolean relevant = false;
            for (Employee_Pay_Component__c row : newRecords) {
                Employee_Pay_Component__c oldRow = oldMap.get(row.Id);
                if (oldRow != null && oldRow.Employment__c != row.Employment__c) {
                    relevant = true;
                    break;
                }
            }
            if (!relevant) return;
        }
        Set<Id> assignmentIds = new Set<Id>();
        for (Employee_Pay_Component__c row : newRecords) {
            if (row.Id != null) assignmentIds.add(row.Id);
        }
        reconcileAssignments(assignmentIds);
    }

    public static void afterBenefitAwardChange(
        List<Benefit_Award__c> newRecords,
        Map<Id, Benefit_Award__c> oldMap
    ) {
        if (newRecords == null || newRecords.isEmpty()) return;
        if (oldMap != null && !oldMap.isEmpty()) {
            Boolean relevant = false;
            for (Benefit_Award__c row : newRecords) {
                Benefit_Award__c oldRow = oldMap.get(row.Id);
                if (oldRow != null && oldRow.Employment__c != row.Employment__c) {
                    relevant = true;
                    break;
                }
            }
            if (!relevant) return;
        }
        Set<Id> awardIds = new Set<Id>();
        for (Benefit_Award__c row : newRecords) {
            if (row.Id != null) awardIds.add(row.Id);
        }
        reconcileAwards(awardIds);
    }

    @TestVisible
    private static void reconcileFromEmployments(Set<Id> employmentIds) {
        if (employmentIds == null || employmentIds.isEmpty()) return;

        List<Employment__c> employments = [
            SELECT Id, Employee__c
            FROM Employment__c
            WHERE Id IN :employmentIds
        ];

        Set<Id> employeeIds = new Set<Id>();
        for (Employment__c row : employments) {
            if (row.Employee__c != null) employeeIds.add(row.Employee__c);
        }
        reconcileEmployees(employeeIds);
    }

    @TestVisible
    private static void reconcileEmployees(Set<Id> employeeIds) {
        if (employeeIds == null || employeeIds.isEmpty()) return;

        Map<Id, Set<Id>> usersByEmployee = new Map<Id, Set<Id>>();
        Set<Id> companyIds = new Set<Id>();

        for (Employment__c employment : [
            SELECT Employee__c, Company__c
            FROM Employment__c
            WHERE Employee__c IN :employeeIds
              AND Company__c != null
        ]) {
            companyIds.add(employment.Company__c);
            if (!usersByEmployee.containsKey(employment.Employee__c)) {
                usersByEmployee.put(employment.Employee__c, new Set<Id>());
            }
        }

        if (companyIds.isEmpty()) return;

        Map<Id, Set<Id>> usersByCompany = effectiveUsersByCompany(companyIds);
        for (Employment__c employment : [
            SELECT Employee__c, Company__c
            FROM Employment__c
            WHERE Employee__c IN :employeeIds
              AND Company__c IN :companyIds
        ]) {
            if (usersByCompany.containsKey(employment.Company__c)) {
                usersByEmployee.get(employment.Employee__c)
                    .addAll(usersByCompany.get(employment.Company__c));
            }
        }

        reconcileShareTable(
            'Employee__c',
            employeeIds,
            usersByEmployee
        );
    }

    @TestVisible
    private static void reconcileAssignments(Set<Id> assignmentIds) {
        if (assignmentIds == null || assignmentIds.isEmpty()) return;

        Map<Id, Set<Id>> usersByRecord = new Map<Id, Set<Id>>();
        Set<Id> companyIds = new Set<Id>();

        for (Employee_Pay_Component__c row : [
            SELECT Id, Employment__r.Company__c
            FROM Employee_Pay_Component__c
            WHERE Id IN :assignmentIds
        ]) {
            if (row.Employment__r.Company__c != null) {
                companyIds.add(row.Employment__r.Company__c);
                usersByRecord.put(row.Id, new Set<Id>());
            }
        }

        if (companyIds.isEmpty()) return;
        Map<Id, Set<Id>> usersByCompany = effectiveUsersByCompany(companyIds);

        for (Employee_Pay_Component__c row : [
            SELECT Id, Employment__r.Company__c
            FROM Employee_Pay_Component__c
            WHERE Id IN :assignmentIds
        ]) {
            if (usersByCompany.containsKey(row.Employment__r.Company__c)) {
                usersByRecord.get(row.Id)
                    .addAll(usersByCompany.get(row.Employment__r.Company__c));
            }
        }

        reconcileShareTable(
            'Employee_Pay_Component__c',
            assignmentIds,
            usersByRecord
        );
    }

    @TestVisible
    private static void reconcileAwards(Set<Id> awardIds) {
        if (awardIds == null || awardIds.isEmpty()) return;

        Map<Id, Set<Id>> usersByRecord = new Map<Id, Set<Id>>();
        Set<Id> companyIds = new Set<Id>();

        for (Benefit_Award__c row : [
            SELECT Id, Employment__r.Company__c
            FROM Benefit_Award__c
            WHERE Id IN :awardIds
        ]) {
            if (row.Employment__r.Company__c != null) {
                companyIds.add(row.Employment__r.Company__c);
                usersByRecord.put(row.Id, new Set<Id>());
            }
        }

        if (companyIds.isEmpty()) return;
        Map<Id, Set<Id>> usersByCompany = effectiveUsersByCompany(companyIds);

        for (Benefit_Award__c row : [
            SELECT Id, Employment__r.Company__c
            FROM Benefit_Award__c
            WHERE Id IN :awardIds
        ]) {
            if (usersByCompany.containsKey(row.Employment__r.Company__c)) {
                usersByRecord.get(row.Id)
                    .addAll(usersByCompany.get(row.Employment__r.Company__c));
            }
        }

        reconcileShareTable(
            'Benefit_Award__c',
            awardIds,
            usersByRecord
        );
    }

    private static Map<Id, Set<Id>> effectiveUsersByCompany(Set<Id> companyIds) {
        Map<Id, Set<Id>> result = new Map<Id, Set<Id>>();
        if (companyIds == null || companyIds.isEmpty()) return result;

        // Resolve binds explicitly instead of relying on generated tmpVar bindings
        // in the inline SOQL loop. This internal sharing-maintenance query must
        // see company grants independently of the initiating user's visibility.
        Map<String, Object> grantBinds = new Map<String, Object>{
            'companyIds' => companyIds,
            'asOfDate' => Date.today()
        };
        List<Company_User_Access__c> effectiveGrants = Database.queryWithBinds(
            'SELECT Company__c, User__c FROM Company_User_Access__c'
            + ' WHERE Company__c IN :companyIds'
            + ' AND User__c != null'
            + ' AND Is_Active__c = true'
            + ' AND Effective_From__c <= :asOfDate'
            + ' AND (Effective_To__c = null OR Effective_To__c >= :asOfDate)',
            grantBinds,
            AccessLevel.SYSTEM_MODE
        );

        for (Company_User_Access__c grant : effectiveGrants) {
            if (!result.containsKey(grant.Company__c)) {
                result.put(grant.Company__c, new Set<Id>());
            }
            result.get(grant.Company__c).add(grant.User__c);
        }
        return result;
    }

    private static void reconcileShareTable(
        String objectApiName,
        Set<Id> recordIds,
        Map<Id, Set<Id>> expectedUsersByRecord
    ) {
        if (recordIds.isEmpty()) return;

        String shareObject = objectApiName.replace('__c', '__Share');
        Map<String, Schema.SObjectType> describeMap = Schema.getGlobalDescribe();
        if (!describeMap.containsKey(shareObject)) return;

        Set<Id> allUsers = new Set<Id>();
        for (Set<Id> ids : expectedUsersByRecord.values()) allUsers.addAll(ids);
        if (allUsers.isEmpty()) return;

        List<SObject> currentShares = Database.query(
            'SELECT Id, ParentId, UserOrGroupId, AccessLevel, RowCause '
            + 'FROM ' + shareObject
            + ' WHERE ParentId IN :recordIds'
            + ' AND UserOrGroupId IN :allUsers'
            + ' AND RowCause = \'Manual\''
        );

        Map<String, SObject> existing = new Map<String, SObject>();
        for (SObject share : currentShares) {
            existing.put(
                key((Id)share.get('ParentId'), (Id)share.get('UserOrGroupId')),
                share
            );
        }

        List<SObject> toInsert = new List<SObject>();
        Schema.SObjectType shareType = describeMap.get(shareObject);

        for (Id recordId : recordIds) {
            Set<Id> expected = expectedUsersByRecord.get(recordId);
            if (expected == null) continue;
            for (Id userId : expected) {
                String shareKey = key(recordId, userId);
                if (existing.containsKey(shareKey)) continue;

                SObject share = shareType.newSObject();
                share.put('ParentId', recordId);
                share.put('UserOrGroupId', userId);
                share.put('AccessLevel', READ_ACCESS);
                share.put('RowCause', 'Manual');
                toInsert.add(share);
            }
        }

        if (!toInsert.isEmpty()) Database.insert(toInsert, false);
    }

    private static String key(Id recordId, Id userId) {
        return String.valueOf(recordId) + ':' + String.valueOf(userId);
    }
}
