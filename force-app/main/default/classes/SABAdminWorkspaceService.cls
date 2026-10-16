/**
 * G22H-0: writes for the Chart of accounts, Projects and Configuration and diagnostics workspaces.
 *
 *   saveDepartment  SAB_Manage_Company_Setup   create or edit a department (key from the company key and code)
 *   saveCostCenter  SAB_Manage_Company_Setup   create or edit a cost center
 *   saveProject     SAB_Manage_Projects        create or edit a project; SABProjectPolicy still validates every save
 *   saveGrant       SAB_Manage_Company_Access  grant, change or end a user's access to the company
 *
 * GL accounts and company features are saved through SABSetupRecordService, unchanged. Every save checks the company
 * grant, is idempotent by request key and is audited in Business_Action__c. Users cannot change or end their own grant,
 * so nobody can lock themselves out or raise their own role.
 */
public with sharing class SABAdminWorkspaceService {
    public class AdminWorkspaceException extends Exception {}

    private static final String SETUP_PERMISSION = 'SAB_Manage_Company_Setup';
    private static final String PROJECT_PERMISSION = 'SAB_Manage_Projects';
    private static final String ACCESS_PERMISSION = 'SAB_Manage_Company_Access';
    private static final String SOURCE_TYPE = 'Administration';

    public class DimensionRequest {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String code { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public Id parentId { get; set; }
        @AuraEnabled public Id personId { get; set; }
        @AuraEnabled public Boolean active { get; set; }
        @AuraEnabled public Date activeFrom { get; set; }
        @AuraEnabled public Date activeTo { get; set; }
    }

    public class ProjectRequest {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String code { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date endDate { get; set; }
        @AuraEnabled public Id managerId { get; set; }
        @AuraEnabled public Id customerAccountId { get; set; }
    }

    public class GrantRequest {
        @AuraEnabled public Id grantId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public Id userId { get; set; }
        @AuraEnabled public String role { get; set; }
        @AuraEnabled public Date effectiveFrom { get; set; }
        @AuraEnabled public Date effectiveTo { get; set; }
        @AuraEnabled public Decimal approvalLimit { get; set; }
        @AuraEnabled public Boolean active { get; set; }
    }

    @AuraEnabled
    public static Id saveDepartment(DimensionRequest request, String requestKey) {
        String key = requireKey(requestKey);
        DimensionRequest r = requireDimension(request);
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replay(prior, 'DEPARTMENT_SAVED');
        }
        Department__c row = new Department__c(Id = r.recordId, Name = requireText(r.name, 'Name').left(80), Parent_Department__c = r.parentId, Manager__c = r.personId,
            Is_Active__c = r.active != false, Active_From__c = r.activeFrom, Active_To__c = r.activeTo);
        if (r.parentId != null && r.parentId == r.recordId) {
            throw new AdminWorkspaceException('A department cannot be its own parent.');
        }
        if (r.recordId == null) {
            String code = requireText(r.code, 'Code');
            row.Company__c = r.companyId;
            row.Code__c = code;
            row.Company_Department_Key__c = (new Store().companyKey(r.companyId) + '-' + code).left(120);
        } else {
            new Store().assertBelongs(Department__c.SObjectType, r.recordId, r.companyId);
        }
        new Writer().save(row, audit(r.companyId, 'DEPARTMENT_SAVED', key, 'Department ' + row.Name + ' saved'));
        return row.Id;
    }

    @AuraEnabled
    public static Id saveCostCenter(DimensionRequest request, String requestKey) {
        String key = requireKey(requestKey);
        DimensionRequest r = requireDimension(request);
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replay(prior, 'COST_CENTER_SAVED');
        }
        Cost_Center__c row = new Cost_Center__c(Id = r.recordId, Name = requireText(r.name, 'Name').left(80), Owner_User__c = r.personId,
            Is_Active__c = r.active != false, Active_From__c = r.activeFrom, Active_To__c = r.activeTo);
        if (r.recordId == null) {
            String code = requireText(r.code, 'Code');
            row.Company__c = r.companyId;
            row.Code__c = code;
            row.Company_Cost_Center_Key__c = (new Store().companyKey(r.companyId) + '-' + code).left(120);
        } else {
            new Store().assertBelongs(Cost_Center__c.SObjectType, r.recordId, r.companyId);
        }
        new Writer().save(row, audit(r.companyId, 'COST_CENTER_SAVED', key, 'Cost center ' + row.Name + ' saved'));
        return row.Id;
    }

    @AuraEnabled
    public static Id saveProject(ProjectRequest request, String requestKey) {
        String key = requireKey(requestKey);
        if (request == null || request.companyId == null) {
            throw new AdminWorkspaceException('Accounting Company is required.');
        }
        assertCompany(request.companyId);
        SABPermissionService.assertPermission(PROJECT_PERMISSION, 'You do not have permission to manage projects.');
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replay(prior, 'PROJECT_SAVED');
        }
        if (request.startDate != null && request.endDate != null && request.endDate < request.startDate) {
            throw new AdminWorkspaceException('The end date cannot be before the start date.');
        }
        Project__c row = new Project__c(Id = request.recordId, Name = requireText(request.name, 'Name').left(80),
            Status__c = String.isBlank(request.status) ? 'Planned' : request.status, Start_Date__c = request.startDate, End_Date__c = request.endDate,
            Manager__c = request.managerId, Customer_Account__c = request.customerAccountId);
        if (request.recordId == null) {
            row.Company__c = request.companyId;
            row.Project_Code__c = requireText(request.code, 'Project code');
        } else {
            new Store().assertBelongs(Project__c.SObjectType, request.recordId, request.companyId);
        }
        new Writer().save(row, audit(request.companyId, 'PROJECT_SAVED', key, 'Project ' + row.Name + ' saved'));
        return row.Id;
    }

    @AuraEnabled
    public static Id saveGrant(GrantRequest request, String requestKey) {
        String key = requireKey(requestKey);
        if (request == null || request.companyId == null) {
            throw new AdminWorkspaceException('Accounting Company is required.');
        }
        assertCompany(request.companyId);
        SABPermissionService.assertPermission(ACCESS_PERMISSION, 'You do not have permission to manage company access.');
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replay(prior, 'ACCESS_GRANT_SAVED');
        }
        Store store = new Store();
        Id userId = request.userId;
        if (request.grantId != null) {
            Company_User_Access__c existing = store.grant(request.grantId);
            if (existing == null || existing.Company__c != request.companyId) {
                throw new AdminWorkspaceException('The access grant does not belong to this Accounting Company.');
            }
            userId = existing.User__c;
        }
        if (userId == null) {
            throw new AdminWorkspaceException('Choose a user.');
        }
        if (userId == UserInfo.getUserId()) {
            throw new AdminWorkspaceException('You cannot change your own access. Ask another administrator.');
        }
        String role = requireText(request.role, 'Role');
        Date effectiveFrom = request.effectiveFrom == null ? Date.today() : request.effectiveFrom;
        if (request.effectiveTo != null && request.effectiveTo < effectiveFrom) {
            throw new AdminWorkspaceException('The end date cannot be before the start date.');
        }
        if (request.approvalLimit != null && request.approvalLimit < 0) {
            throw new AdminWorkspaceException('The approval limit cannot be negative.');
        }
        if (request.grantId == null && store.hasActiveGrant(request.companyId, userId)) {
            throw new AdminWorkspaceException('This user already has an active grant. Edit that grant instead.');
        }
        Company_User_Access__c grant = new Company_User_Access__c(Id = request.grantId, Role__c = role, Effective_From__c = effectiveFrom,
            Effective_To__c = request.effectiveTo, Approval_Limit__c = request.approvalLimit, Is_Active__c = request.active != false);
        if (request.grantId == null) {
            grant.Company__c = request.companyId;
            grant.User__c = userId;
            grant.Grant_Key__c = (store.companyKey(request.companyId) + '-' + userId + '-' + System.now().getTime()).left(160);
        }
        new Writer().save(grant, audit(request.companyId, 'ACCESS_GRANT_SAVED', key, 'Access grant saved for ' + userId + ' as ' + role));
        return grant.Id;
    }

    // ---------------------------------------------------------------- helpers

    private static DimensionRequest requireDimension(DimensionRequest request) {
        if (request == null || request.companyId == null) {
            throw new AdminWorkspaceException('Accounting Company is required.');
        }
        assertCompany(request.companyId);
        SABPermissionService.assertPermission(SETUP_PERMISSION, 'You do not have permission to manage company setup.');
        if (request.activeFrom != null && request.activeTo != null && request.activeTo < request.activeFrom) {
            throw new AdminWorkspaceException('The end date cannot be before the start date.');
        }
        return request;
    }

    private static void assertCompany(Id companyId) {
        if (!SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw new AdminWorkspaceException('You do not have active access to this Accounting Company.');
        }
    }

    private static String requireText(String value, String label) {
        if (String.isBlank(value)) {
            throw new AdminWorkspaceException(label + ' is required.');
        }
        return value.trim();
    }

    private static String requireKey(String requestKey) {
        if (String.isBlank(requestKey) || requestKey.trim().length() > 160) {
            throw new AdminWorkspaceException('A request key of up to 160 characters is required.');
        }
        return requestKey.trim();
    }

    private static Id replay(Business_Action__c prior, String actionName) {
        if (prior.Action__c != actionName) {
            throw new AdminWorkspaceException('Request key has already been used for a different action.');
        }
        return Id.valueOf(prior.Source_Record_Id__c);
    }

    private static Business_Action__c audit(Id companyId, String actionName, String key, String reason) {
        return new Business_Action__c(Company__c = companyId, Action__c = actionName, Actor__c = UserInfo.getUserId(), Action_At__c = System.now(),
            Reason__c = reason, Request_Key__c = key, Source_Type__c = SOURCE_TYPE, Source_Version__c = 1);
    }

    // System reads after the permission and company checks above.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c FROM Business_Action__c WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }

        String companyKey(Id companyId) {
            return [SELECT Company_Key__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE LIMIT 1].Company_Key__c;
        }

        Company_User_Access__c grant(Id grantId) {
            List<Company_User_Access__c> rows = [SELECT Id, Company__c, User__c FROM Company_User_Access__c WHERE Id = :grantId WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }

        Boolean hasActiveGrant(Id companyId, Id userId) {
            return [SELECT COUNT() FROM Company_User_Access__c WHERE Company__c = :companyId AND User__c = :userId AND Is_Active__c = true WITH SYSTEM_MODE] > 0;
        }

        void assertBelongs(Schema.SObjectType objectType, Id recordId, Id companyId) {
            String objectName = objectType.getDescribe(SObjectDescribeOptions.DEFERRED).getName();
            List<SObject> rows = Database.queryWithBinds('SELECT Company__c FROM ' + objectName + ' WHERE Id = :recordId LIMIT 1',
                new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.SYSTEM_MODE);
            if (rows.isEmpty() || (Id) rows[0].get('Company__c') != companyId) {
                throw new AdminWorkspaceException('The record does not belong to this Accounting Company.');
            }
        }
    }

    // System writes after the permission and company checks above; triggers (project policy, grant sharing) still run.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void save(SObject record, Business_Action__c audit) {
            if (record.Id == null) {
                insert as system record;
            } else {
                update as system record;
            }
            audit.Source_Record_Id__c = String.valueOf(record.Id);
            insert as system audit;
        }
    }
}