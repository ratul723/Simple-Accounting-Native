/**
 * G14: Allocation rules.
 *
 *   saveDraft  SAB_Manage_Allocation   create or replace a Draft rule version and its target lines
 *   approve    SAB_Approve_Allocation  Draft -> Approved; approver differs from the creator; the previously Approved
 *                                      version of the same rule key becomes Retired
 *   retire     SAB_Manage_Allocation   Approved -> Retired with a reason
 *   revise     SAB_Manage_Allocation   Approved -> next Draft version with the source and lines copied
 *
 * Source (Source_Filter_JSON__c): {"accountIds":[...], "departmentId":..., "costCenterId":...}. Each source account's net
 * posted balance for a period is split across the targets. A target names a GL account (blank = the source account),
 * a department and/or a cost center, and a weight: a percentage for Percent rules (they must total 100) or a driver
 * value for Manual Driver rules. Control accounts are never sources or targets. Supported Metric drivers and project
 * targets are outside G14. Every lifecycle action is idempotent by request key and audited in Business_Action__c.
 */
public with sharing class SABAllocationRuleService {
    public class AllocationRuleException extends Exception {}

    private static final String MANAGE = 'SAB_Manage_Allocation';
    private static final String APPROVE = 'SAB_Approve_Allocation';
    public static final String DRAFT = 'Draft';
    public static final String APPROVED = 'Approved';
    public static final String RETIRED = 'Retired';
    public static final String PERCENT = 'Percent';
    public static final String MANUAL_DRIVER = 'Manual Driver';
    private static final Integer MAX_LINES = 200;
    private static final Integer MAX_SOURCE_ACCOUNTS = 50;
    private static final String SOURCE_TYPE = 'Allocation_Rule__c';

    // ------------------------------------------------------------------ DTOs

    public class TargetRequest {
        @AuraEnabled public Id targetGlAccountId { get; set; }
        @AuraEnabled public Id targetDepartmentId { get; set; }
        @AuraEnabled public Id targetCostCenterId { get; set; }
        @AuraEnabled public Decimal percentage { get; set; }
        @AuraEnabled public Decimal driverValue { get; set; }
    }

    public class RuleRequest {
        @AuraEnabled public Id ruleId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String ruleKey { get; set; }
        @AuraEnabled public String driverType { get; set; }
        @AuraEnabled public String roundingPolicy { get; set; }
        @AuraEnabled public Date effectiveFrom { get; set; }
        @AuraEnabled public Date effectiveTo { get; set; }
        @AuraEnabled public List<Id> sourceAccountIds { get; set; }
        @AuraEnabled public Id sourceDepartmentId { get; set; }
        @AuraEnabled public Id sourceCostCenterId { get; set; }
        @AuraEnabled public List<TargetRequest> targets { get; set; }
    }

    public class ActionResult {
        @AuraEnabled public Id ruleId;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal version;
        @AuraEnabled public Id retiredRuleId;
        @AuraEnabled public Boolean replay;
    }

    /** Parsed source filter of a rule. */
    public class SourceFilter {
        public List<Id> accountIds = new List<Id>();
        public Id departmentId;
        public Id costCenterId;
    }

    // ---------------------------------------------------------------- drafts

    @AuraEnabled
    public static Id saveDraft(RuleRequest request) {
        SABPermissionService.assertPermission(MANAGE, 'Allocation management permission is required.');
        if (request == null || request.companyId == null || String.isBlank(request.ruleKey) || String.isBlank(request.name)
            || String.isBlank(request.driverType) || request.effectiveFrom == null) {
            throw new AllocationRuleException('Company, rule key, name, driver type and effective-from date are required.');
        }
        SABCompanyAccessService.assertCompanyAccess(request.companyId);
        String ruleKey = request.ruleKey.trim().toUpperCase();
        String name = request.name.trim();
        if (ruleKey.length() > 80 || name.length() > 80) {
            throw new AllocationRuleException('Rule key and name cannot exceed 80 characters.');
        }
        if (request.effectiveTo != null && request.effectiveTo < request.effectiveFrom) {
            throw new AllocationRuleException('Effective-to cannot be before effective-from.');
        }
        String driver = request.driverType.trim();
        if (driver != PERCENT && driver != MANUAL_DRIVER) {
            throw new AllocationRuleException('G14 supports the Percent and Manual Driver driver types.');
        }
        String rounding = String.isBlank(request.roundingPolicy) ? SABAllocationCalculator.LARGEST_REMAINDER : request.roundingPolicy.trim();
        if (rounding != SABAllocationCalculator.LARGEST_REMAINDER && rounding != SABAllocationCalculator.LAST_TARGET
            && rounding != SABAllocationCalculator.ROUNDING_ACCOUNT) {
            throw new AllocationRuleException('Rounding policy must be Largest Remainder, Last Target or Rounding Account.');
        }
        Store store = new Store();
        if (rounding == SABAllocationCalculator.ROUNDING_ACCOUNT && store.roundingAccount(request.companyId) == null) {
            throw new AllocationRuleException('The Rounding Account policy needs a default rounding account on the company.');
        }
        SourceFilter source = new SourceFilter();
        source.accountIds = request.sourceAccountIds == null ? new List<Id>() : request.sourceAccountIds;
        source.departmentId = request.sourceDepartmentId;
        source.costCenterId = request.sourceCostCenterId;
        List<Allocation_Rule_Line__c> lines = toLines(request.targets);
        validate(request.companyId, driver, source, lines);

        Allocation_Rule__c rule;
        if (request.ruleId != null) {
            authorize(request.ruleId);
            rule = store.lockRule(request.ruleId);
            if (rule.Status__c != DRAFT) {
                throw new AllocationRuleException('Only Draft allocation rules can be edited.');
            }
            if (rule.Company__c != request.companyId || rule.Rule_Key__c != ruleKey) {
                throw new AllocationRuleException('A rule cannot move to another company or rule key.');
            }
        } else {
            if (store.draftExists(request.companyId, ruleKey)) {
                throw new AllocationRuleException('Rule ' + ruleKey + ' already has a Draft version.');
            }
            rule = new Allocation_Rule__c(Company__c = request.companyId, Rule_Key__c = ruleKey, Status__c = DRAFT,
                Version__c = store.latestVersion(request.companyId, ruleKey) + 1);
        }
        rule.Name = name;
        rule.Driver_Type__c = driver;
        rule.Rounding_Policy__c = rounding;
        rule.Effective_From__c = request.effectiveFrom;
        rule.Effective_To__c = request.effectiveTo;
        rule.Source_Filter_JSON__c = JSON.serialize(source);
        new Writer().saveDraft(rule, lines);
        return rule.Id;
    }

    // ------------------------------------------------------------- lifecycle

    @AuraEnabled
    public static ActionResult approve(Id ruleId, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(APPROVE, 'Allocation approval permission is required.');
        Allocation_Rule__c visible = authorize(ruleId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'ALLOCATION_RULE_APPROVED');
        }
        Allocation_Rule__c rule = store.lockRule(ruleId);
        if (rule.Status__c != DRAFT) {
            throw new AllocationRuleException('Only a Draft allocation rule can be approved.');
        }
        if (rule.CreatedById == UserInfo.getUserId()) {
            throw new AllocationRuleException('The creator of an allocation rule cannot approve it.');
        }
        SourceFilter source = parseSource(rule.Source_Filter_JSON__c);
        validate(rule.Company__c, rule.Driver_Type__c, source, store.lines(rule.Id));
        Allocation_Rule__c previous = store.approvedVersion(rule.Company__c, rule.Rule_Key__c, rule.Id);
        rule.Status__c = APPROVED;
        rule.Approved_By__c = UserInfo.getUserId();
        rule.Approved_At__c = System.now();
        ActionResult result = write(rule, previous, 'ALLOCATION_RULE_APPROVED', key,
            'Allocation rule approved' + (previous == null ? '.' : '; version ' + previous.Version__c + ' retired.'));
        result.retiredRuleId = previous == null ? null : previous.Id;
        return result;
    }

    @AuraEnabled
    public static ActionResult retire(Id ruleId, String reason, String requestKey) {
        String key = requireKey(requestKey);
        String why = requireReason(reason);
        SABPermissionService.assertPermission(MANAGE, 'Allocation management permission is required.');
        Allocation_Rule__c visible = authorize(ruleId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'ALLOCATION_RULE_RETIRED');
        }
        Allocation_Rule__c rule = store.lockRule(ruleId);
        if (rule.Status__c != APPROVED) {
            throw new AllocationRuleException('Only an Approved allocation rule can be retired.');
        }
        rule.Status__c = RETIRED;
        return write(rule, null, 'ALLOCATION_RULE_RETIRED', key, why);
    }

    @AuraEnabled
    public static ActionResult revise(Id ruleId, String reason, String requestKey) {
        String key = requireKey(requestKey);
        String why = requireReason(reason);
        SABPermissionService.assertPermission(MANAGE, 'Allocation management permission is required.');
        Allocation_Rule__c visible = authorize(ruleId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            if (prior.Action__c != 'ALLOCATION_RULE_REVISION_OPENED' || !String.valueOf(prior.Reason__c).startsWith(String.valueOf(visible.Id))) {
                throw new AllocationRuleException('Request key has already been used for a different allocation action.');
            }
            return result(store.lockRule(Id.valueOf(prior.Source_Record_Id__c)), true);
        }
        Allocation_Rule__c approvedRule = store.lockRule(ruleId);
        if (approvedRule.Status__c != APPROVED) {
            throw new AllocationRuleException('Only an Approved allocation rule can be revised.');
        }
        if (store.draftExists(approvedRule.Company__c, approvedRule.Rule_Key__c)) {
            throw new AllocationRuleException('Rule ' + approvedRule.Rule_Key__c + ' already has a Draft version.');
        }
        Allocation_Rule__c revision = approvedRule.clone(false, true, false, false);
        revision.Status__c = DRAFT;
        revision.Version__c = store.latestVersion(approvedRule.Company__c, approvedRule.Rule_Key__c) + 1;
        revision.Approved_By__c = null;
        revision.Approved_At__c = null;
        List<Allocation_Rule_Line__c> copies = new List<Allocation_Rule_Line__c>();
        for (Allocation_Rule_Line__c line : store.lines(approvedRule.Id)) {
            Allocation_Rule_Line__c copy = line.clone(false, true, false, false);
            copy.Allocation_Rule__c = null;
            copies.add(copy);
        }
        Writer writer = new Writer();
        writer.saveDraft(revision, copies);
        writer.audit(new Business_Action__c(Company__c = revision.Company__c, Action__c = 'ALLOCATION_RULE_REVISION_OPENED',
            Actor__c = UserInfo.getUserId(), Action_At__c = System.now(), Reason__c = String.valueOf(approvedRule.Id) + ': ' + why,
            Request_Key__c = key, Source_Type__c = SOURCE_TYPE, Source_Record_Id__c = String.valueOf(revision.Id),
            Source_Version__c = revision.Version__c));
        return result(revision, false);
    }

    // ------------------------------------------------------------ shared API

    public static SourceFilter parseSource(String sourceJson) {
        try {
            SourceFilter source = (SourceFilter) JSON.deserialize(sourceJson, SourceFilter.class);
            if (source == null || source.accountIds == null) {
                throw new AllocationRuleException('Allocation rule source filter is incomplete.');
            }
            return source;
        } catch (JSONException ex) {
            throw new AllocationRuleException('Allocation rule source filter is not valid JSON.');
        }
    }

    /** Validates source accounts, dimensions and target lines for a company and driver type. */
    public static void validate(Id companyId, String driverType, SourceFilter source, List<Allocation_Rule_Line__c> lines) {
        if (source.accountIds.isEmpty() || source.accountIds.size() > MAX_SOURCE_ACCOUNTS) {
            throw new AllocationRuleException('A rule needs between 1 and ' + MAX_SOURCE_ACCOUNTS + ' source GL accounts.');
        }
        if (lines.isEmpty() || lines.size() > MAX_LINES) {
            throw new AllocationRuleException('A rule needs between 1 and ' + MAX_LINES + ' target lines.');
        }
        Set<Id> accounts = new Set<Id>(source.accountIds);
        Set<Id> departments = new Set<Id>();
        Set<Id> costCenters = new Set<Id>();
        if (source.departmentId != null) {
            departments.add(source.departmentId);
        }
        if (source.costCenterId != null) {
            costCenters.add(source.costCenterId);
        }
        Decimal percentTotal = 0;
        for (Allocation_Rule_Line__c line : lines) {
            if (line.Target_Project__c != null) {
                throw new AllocationRuleException('Project targets are outside G14 allocation rules.');
            }
            if (driverType == PERCENT) {
                if (line.Percentage__c == null || line.Percentage__c <= 0 || line.Percentage__c > 100) {
                    throw new AllocationRuleException('Every Percent target needs a percentage above 0 and up to 100.');
                }
                percentTotal += line.Percentage__c;
            } else if (line.Driver_Value__c == null || line.Driver_Value__c <= 0) {
                throw new AllocationRuleException('Every Manual Driver target needs a driver value greater than zero.');
            }
            if (line.Target_GL_Account__c != null) {
                accounts.add(line.Target_GL_Account__c);
            }
            if (line.Target_Department__c != null) {
                departments.add(line.Target_Department__c);
            }
            if (line.Target_Cost_Center__c != null) {
                costCenters.add(line.Target_Cost_Center__c);
            }
            if (line.Target_GL_Account__c == null && line.Target_Department__c == null && line.Target_Cost_Center__c == null) {
                throw new AllocationRuleException('Every target needs a GL account, a department or a cost center.');
            }
        }
        if (driverType == PERCENT && percentTotal != 100) {
            throw new AllocationRuleException('Percent targets must total exactly 100; they total ' + percentTotal.stripTrailingZeros().toPlainString() + '.');
        }
        for (GL_Account__c a : [SELECT Id, Company__c, Is_Active__c, Is_Control_Account__c FROM GL_Account__c WHERE Id IN :accounts WITH USER_MODE]) {
            if (a.Company__c != companyId || a.Is_Active__c != true || a.Is_Control_Account__c == true) {
                throw new AllocationRuleException('Allocation GL accounts must be active, non-control accounts of the company.');
            }
            accounts.remove(a.Id);
        }
        for (Department__c d : [SELECT Id, Company__c, Is_Active__c FROM Department__c WHERE Id IN :departments WITH USER_MODE]) {
            if (d.Company__c != companyId || d.Is_Active__c != true) {
                throw new AllocationRuleException('Departments must be active and belong to the company.');
            }
            departments.remove(d.Id);
        }
        for (Cost_Center__c c : [SELECT Id, Company__c, Is_Active__c FROM Cost_Center__c WHERE Id IN :costCenters WITH USER_MODE]) {
            if (c.Company__c != companyId || c.Is_Active__c != true) {
                throw new AllocationRuleException('Cost centers must be active and belong to the company.');
            }
            costCenters.remove(c.Id);
        }
        if (!accounts.isEmpty() || !departments.isEmpty() || !costCenters.isEmpty()) {
            throw new AllocationRuleException('A GL account, department or cost center was not found or is not accessible.');
        }
    }

    // --------------------------------------------------------------- helpers

    private static Allocation_Rule__c authorize(Id ruleId) {
        if (ruleId == null) {
            throw new AllocationRuleException('Allocation rule is required.');
        }
        List<Allocation_Rule__c> visible = [SELECT Id, Company__c FROM Allocation_Rule__c WHERE Id = :ruleId WITH USER_MODE];
        if (visible.isEmpty()) {
            throw new AllocationRuleException('Allocation rule not found or not accessible.');
        }
        SABCompanyAccessService.assertCompanyAccess(visible[0].Company__c);
        return visible[0];
    }

    private static List<Allocation_Rule_Line__c> toLines(List<TargetRequest> targets) {
        List<Allocation_Rule_Line__c> lines = new List<Allocation_Rule_Line__c>();
        Integer sequence = 1;
        for (TargetRequest t : targets == null ? new List<TargetRequest>() : targets) {
            if (t == null) {
                throw new AllocationRuleException('Target lines cannot be empty.');
            }
            lines.add(new Allocation_Rule_Line__c(Sequence__c = sequence++, Target_GL_Account__c = t.targetGlAccountId,
                Target_Department__c = t.targetDepartmentId, Target_Cost_Center__c = t.targetCostCenterId, Percentage__c = t.percentage,
                Driver_Value__c = t.driverValue));
        }
        return lines;
    }

    private static String requireKey(String requestKey) {
        Integer maxLength = Business_Action__c.Request_Key__c.getDescribe().getLength();
        if (String.isBlank(requestKey) || requestKey.trim().length() > maxLength) {
            throw new AllocationRuleException('Request key is required and must not exceed ' + maxLength + ' characters.');
        }
        return requestKey.trim();
    }

    private static String requireReason(String reason) {
        if (String.isBlank(reason) || reason.trim().length() > 255) {
            throw new AllocationRuleException('A reason of up to 255 characters is required.');
        }
        return reason.trim();
    }

    private static ActionResult replay(Business_Action__c prior, Id ruleId, String expectedAction) {
        if (prior.Action__c != expectedAction || prior.Source_Record_Id__c != String.valueOf(ruleId)) {
            throw new AllocationRuleException('Request key has already been used for a different allocation action.');
        }
        return result(new Store().lockRule(ruleId), true);
    }

    private static ActionResult write(Allocation_Rule__c rule, Allocation_Rule__c previousRule, String actionName, String key, String reason) {
        new Writer().lifecycle(rule, previousRule, new Business_Action__c(Company__c = rule.Company__c, Action__c = actionName,
            Actor__c = UserInfo.getUserId(), Action_At__c = System.now(), Reason__c = reason, Request_Key__c = key,
            Source_Type__c = SOURCE_TYPE, Source_Record_Id__c = String.valueOf(rule.Id), Source_Version__c = rule.Version__c));
        return result(rule, false);
    }

    private static ActionResult result(Allocation_Rule__c rule, Boolean isReplay) {
        ActionResult r = new ActionResult();
        r.ruleId = rule.Id;
        r.status = rule.Status__c;
        r.version = rule.Version__c;
        r.replay = isReplay;
        return r;
    }

    /** Narrow system reads after the permission and company checks; versioning must see every rule of the key. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c, Reason__c FROM Business_Action__c
                WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        Id roundingAccount(Id companyId) {
            List<Accounting_Company__c> rows = [SELECT Default_Rounding_Account__c FROM Accounting_Company__c WHERE Id = :companyId
                WITH SYSTEM_MODE];
            return rows.isEmpty() ? null : rows[0].Default_Rounding_Account__c;
        }
        Allocation_Rule__c lockRule(Id ruleId) {
            List<Allocation_Rule__c> rows = [SELECT Id, Name, Company__c, Rule_Key__c, Version__c, Status__c, Driver_Type__c,
                Rounding_Policy__c, Effective_From__c, Effective_To__c, Source_Filter_JSON__c, Approved_By__c, Approved_At__c, CreatedById
                FROM Allocation_Rule__c WHERE Id = :ruleId WITH SYSTEM_MODE FOR UPDATE];
            if (rows.isEmpty()) {
                throw new AllocationRuleException('Allocation rule not found.');
            }
            return rows[0];
        }
        List<Allocation_Rule_Line__c> lines(Id ruleId) {
            return [SELECT Id, Sequence__c, Target_GL_Account__c, Target_Department__c, Target_Cost_Center__c, Target_Project__c,
                Percentage__c, Driver_Value__c FROM Allocation_Rule_Line__c WHERE Allocation_Rule__c = :ruleId WITH SYSTEM_MODE
                ORDER BY Sequence__c LIMIT 201];
        }
        Boolean draftExists(Id companyId, String ruleKey) {
            return [SELECT COUNT() FROM Allocation_Rule__c WHERE Company__c = :companyId AND Rule_Key__c = :ruleKey
                AND Status__c = :DRAFT WITH SYSTEM_MODE] > 0;
        }
        Integer latestVersion(Id companyId, String ruleKey) {
            List<Allocation_Rule__c> rows = [SELECT Version__c FROM Allocation_Rule__c WHERE Company__c = :companyId
                AND Rule_Key__c = :ruleKey WITH SYSTEM_MODE ORDER BY Version__c DESC LIMIT 1];
            return rows.isEmpty() || rows[0].Version__c == null ? 0 : rows[0].Version__c.intValue();
        }
        Allocation_Rule__c approvedVersion(Id companyId, String ruleKey, Id excludeId) {
            List<Allocation_Rule__c> rows = [SELECT Id, Version__c FROM Allocation_Rule__c WHERE Company__c = :companyId
                AND Rule_Key__c = :ruleKey AND Status__c = :APPROVED AND Id != :excludeId WITH SYSTEM_MODE FOR UPDATE];
            return rows.isEmpty() ? null : rows[0];
        }
    }

    /** Narrow system writes inside the allocation guard scope, after the service's checks (explicit system mode). */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void saveDraft(Allocation_Rule__c rule, List<Allocation_Rule_Line__c> lines) {
            SABAllocationGuard.beginWrite();
            try {
                upsert as system rule;
                delete as system [SELECT Id FROM Allocation_Rule_Line__c WHERE Allocation_Rule__c = :rule.Id WITH SYSTEM_MODE];
                for (Allocation_Rule_Line__c line : lines) {
                    line.Allocation_Rule__c = rule.Id;
                }
                insert as system lines;
            } finally {
                SABAllocationGuard.endWrite();
            }
        }
        void lifecycle(Allocation_Rule__c rule, Allocation_Rule__c previousRule, Business_Action__c audit) {
            SABAllocationGuard.beginWrite();
            try {
                List<Allocation_Rule__c> changes = new List<Allocation_Rule__c>();
                if (previousRule != null) {
                    changes.add(new Allocation_Rule__c(Id = previousRule.Id, Status__c = RETIRED));
                }
                changes.add(new Allocation_Rule__c(Id = rule.Id, Status__c = rule.Status__c, Approved_By__c = rule.Approved_By__c,
                    Approved_At__c = rule.Approved_At__c));
                update as system changes;
                insert as system audit;
            } finally {
                SABAllocationGuard.endWrite();
            }
        }
        void audit(Business_Action__c audit) {
            insert as system audit;
        }
    }
}
