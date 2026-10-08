/**
 * G14B: Allocation Workspace controller.
 *
 * Read layer for the sabAllocationWorkspace LWC. Every read runs in user mode after SAB_View_Allocations, the company
 * grant and the CRUD/FLS policy. All changes go through SABAllocationRuleService and SABAllocationRunService, which
 * enforce their own permissions, separation of duties and lifecycle rules.
 */
public with sharing class SABAllocationWorkspaceController {
    public class AllocationWorkspaceException extends Exception {}

    private static final String VIEW = 'SAB_View_Allocations';
    private static final Integer ROW_LIMIT = 200;
    private static final List<String> RULE_STATES = new List<String>{'Draft', 'Approved', 'Retired'};
    private static final List<String> RUN_STATES = new List<String>{'Preview', 'Approved', 'Posted', 'Failed'};

    // ------------------------------------------------------------------ DTOs

    public class Capabilities {
        @AuraEnabled public Boolean manage;
        @AuraEnabled public Boolean approve;
        @AuraEnabled public Boolean postJournal;
    }

    public class OptionDTO {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
    }

    public class StateCount {
        @AuraEnabled public String state;
        @AuraEnabled public Integer count;
    }

    public class RuleDTO {
        @AuraEnabled public Id ruleId;
        @AuraEnabled public String name;
        @AuraEnabled public String ruleKey;
        @AuraEnabled public Decimal version;
        @AuraEnabled public String status;
        @AuraEnabled public String driverType;
        @AuraEnabled public String roundingPolicy;
        @AuraEnabled public Date effectiveFrom;
        @AuraEnabled public Date effectiveTo;
        @AuraEnabled public Integer targetCount;
    }

    public class RunDTO {
        @AuraEnabled public Id runId;
        @AuraEnabled public String name;
        @AuraEnabled public Id ruleId;
        @AuraEnabled public String ruleKey;
        @AuraEnabled public String periodName;
        @AuraEnabled public Decimal ruleVersion;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal sourceAmount;
        @AuraEnabled public Id journalEntryId;
        @AuraEnabled public String journalName;
    }

    public class WorkspaceDTO {
        @AuraEnabled public Id companyId;
        @AuraEnabled public String companyName;
        @AuraEnabled public String functionalCurrency;
        @AuraEnabled public Capabilities capabilities;
        @AuraEnabled public List<RuleDTO> rules;
        @AuraEnabled public List<RunDTO> runs;
        @AuraEnabled public List<StateCount> ruleCounts;
        @AuraEnabled public List<StateCount> runCounts;
        @AuraEnabled public List<OptionDTO> accounts;
        @AuraEnabled public List<OptionDTO> departments;
        @AuraEnabled public List<OptionDTO> costCenters;
        @AuraEnabled public List<OptionDTO> openPeriods;
        @AuraEnabled public Boolean hasRoundingAccount;
    }

    public class TargetDTO {
        @AuraEnabled public Decimal sequence;
        @AuraEnabled public Id targetGlAccountId;
        @AuraEnabled public String targetAccountName;
        @AuraEnabled public Id targetDepartmentId;
        @AuraEnabled public String targetDepartmentName;
        @AuraEnabled public Id targetCostCenterId;
        @AuraEnabled public String targetCostCenterName;
        @AuraEnabled public Decimal percentage;
        @AuraEnabled public Decimal driverValue;
    }

    public class RuleDetailDTO {
        @AuraEnabled public RuleDTO rule;
        @AuraEnabled public List<OptionDTO> sourceAccounts;
        @AuraEnabled public Id sourceDepartmentId;
        @AuraEnabled public String sourceDepartmentName;
        @AuraEnabled public Id sourceCostCenterId;
        @AuraEnabled public String sourceCostCenterName;
        @AuraEnabled public List<TargetDTO> targets;
    }

    public class AllocationLineDTO {
        @AuraEnabled public String rowKey;
        @AuraEnabled public String sourceAccountName;
        @AuraEnabled public String targetAccountName;
        @AuraEnabled public String targetDepartmentName;
        @AuraEnabled public String targetCostCenterName;
        @AuraEnabled public Decimal amount;
    }

    public class RunDetailDTO {
        @AuraEnabled public RunDTO run;
        @AuraEnabled public List<AllocationLineDTO> lines;
    }

    // --------------------------------------------------------------- queries

    @AuraEnabled
    public static WorkspaceDTO getWorkspace(Id companyId) {
        if (companyId == null) {
            throw new AllocationWorkspaceException('Select an Accounting Company first.');
        }
        authorizeCompany(companyId);
        List<Accounting_Company__c> companies = [SELECT Id, Name__c, Functional_Currency__c, Default_Rounding_Account__c
            FROM Accounting_Company__c WHERE Id = :companyId WITH USER_MODE];
        if (companies.isEmpty()) {
            throw new AllocationWorkspaceException('Accounting Company not found or not accessible.');
        }
        WorkspaceDTO result = new WorkspaceDTO();
        result.companyId = companyId;
        result.companyName = companies[0].Name__c;
        result.functionalCurrency = companies[0].Functional_Currency__c;
        result.hasRoundingAccount = companies[0].Default_Rounding_Account__c != null;
        result.capabilities = capabilities();

        Map<String, Integer> ruleCounts = zeroCounts(RULE_STATES);
        result.rules = new List<RuleDTO>();
        for (Allocation_Rule__c r : [SELECT Id, Name, Rule_Key__c, Version__c, Status__c, Driver_Type__c, Rounding_Policy__c, Effective_From__c,
                Effective_To__c, (SELECT Id FROM Allocation_Rule_Line_Allocation_Rule__r) FROM Allocation_Rule__c WHERE Company__c = :companyId WITH USER_MODE
                ORDER BY Rule_Key__c, Version__c DESC LIMIT :ROW_LIMIT]) {
            result.rules.add(toRule(r));
            increment(ruleCounts, r.Status__c);
        }
        result.ruleCounts = toCounts(RULE_STATES, ruleCounts);

        Map<String, Integer> runCounts = zeroCounts(RUN_STATES);
        result.runs = new List<RunDTO>();
        for (Allocation_Run__c r : [SELECT Id, Name, Allocation_Rule__c, Allocation_Rule__r.Rule_Key__c, Accounting_Period__r.Name, Rule_Version__c,
                Status__c, Source_Amount_Snapshot__c, Journal_Entry__c, Journal_Entry__r.Name FROM Allocation_Run__c WHERE Company__c = :companyId
                WITH USER_MODE ORDER BY CreatedDate DESC LIMIT :ROW_LIMIT]) {
            result.runs.add(toRun(r));
            increment(runCounts, r.Status__c);
        }
        result.runCounts = toCounts(RUN_STATES, runCounts);

        result.accounts = new List<OptionDTO>();
        for (GL_Account__c a : [SELECT Id, Account_Code__c, Name FROM GL_Account__c WHERE Company__c = :companyId AND Is_Active__c = true
                AND Is_Control_Account__c = false WITH USER_MODE ORDER BY Account_Code__c LIMIT 1000]) {
            result.accounts.add(option(a.Account_Code__c + ' ' + a.Name, a.Id));
        }
        result.departments = new List<OptionDTO>();
        for (Department__c d : [SELECT Id, Name FROM Department__c WHERE Company__c = :companyId AND Is_Active__c = true WITH USER_MODE
                ORDER BY Name LIMIT :ROW_LIMIT]) {
            result.departments.add(option(d.Name, d.Id));
        }
        result.costCenters = new List<OptionDTO>();
        for (Cost_Center__c c : [SELECT Id, Name FROM Cost_Center__c WHERE Company__c = :companyId AND Is_Active__c = true WITH USER_MODE
                ORDER BY Name LIMIT :ROW_LIMIT]) {
            result.costCenters.add(option(c.Name, c.Id));
        }
        result.openPeriods = new List<OptionDTO>();
        for (Accounting_Period__c p : [SELECT Id, Name FROM Accounting_Period__c WHERE Company__c = :companyId AND Status__c = 'Open'
                WITH USER_MODE ORDER BY Start_Date__c DESC LIMIT 60]) {
            result.openPeriods.add(option(p.Name, p.Id));
        }
        return result;
    }

    @AuraEnabled
    public static RuleDetailDTO getRuleDetail(Id ruleId) {
        if (ruleId == null) {
            throw new AllocationWorkspaceException('Select an allocation rule first.');
        }
        authorizeView();
        List<Allocation_Rule__c> rows = [SELECT Id, Name, Company__c, Rule_Key__c, Version__c, Status__c, Driver_Type__c, Rounding_Policy__c,
            Effective_From__c, Effective_To__c, Source_Filter_JSON__c, (SELECT Id FROM Allocation_Rule_Line_Allocation_Rule__r) FROM Allocation_Rule__c
            WHERE Id = :ruleId WITH USER_MODE];
        if (rows.isEmpty()) {
            throw new AllocationWorkspaceException('Allocation rule not found or not accessible.');
        }
        Allocation_Rule__c r = rows[0];
        SABCompanyAccessService.assertCompanyAccess(r.Company__c);
        RuleDetailDTO detail = new RuleDetailDTO();
        detail.rule = toRule(r);
        SABAllocationRuleService.SourceFilter source = SABAllocationRuleService.parseSource(r.Source_Filter_JSON__c);
        Set<Id> accountIds = new Set<Id>(source.accountIds);
        Set<Id> departmentIds = new Set<Id>();
        Set<Id> costCenterIds = new Set<Id>();
        addIfPresent(departmentIds, source.departmentId);
        addIfPresent(costCenterIds, source.costCenterId);
        List<Allocation_Rule_Line__c> lines = [SELECT Sequence__c, Target_GL_Account__c, Target_Department__c, Target_Cost_Center__c,
            Percentage__c, Driver_Value__c FROM Allocation_Rule_Line__c WHERE Allocation_Rule__c = :ruleId WITH USER_MODE
            ORDER BY Sequence__c LIMIT :ROW_LIMIT];
        for (Allocation_Rule_Line__c line : lines) {
            addIfPresent(accountIds, line.Target_GL_Account__c);
            addIfPresent(departmentIds, line.Target_Department__c);
            addIfPresent(costCenterIds, line.Target_Cost_Center__c);
        }
        Map<Id, String> names = names(accountIds, departmentIds, costCenterIds);
        detail.sourceAccounts = new List<OptionDTO>();
        for (Id accountId : source.accountIds) {
            detail.sourceAccounts.add(option(names.get(accountId), accountId));
        }
        detail.sourceDepartmentId = source.departmentId;
        detail.sourceDepartmentName = names.get(source.departmentId);
        detail.sourceCostCenterId = source.costCenterId;
        detail.sourceCostCenterName = names.get(source.costCenterId);
        detail.targets = new List<TargetDTO>();
        for (Allocation_Rule_Line__c line : lines) {
            TargetDTO t = new TargetDTO();
            t.sequence = line.Sequence__c;
            t.targetGlAccountId = line.Target_GL_Account__c;
            t.targetAccountName = line.Target_GL_Account__c == null ? 'Same as source' : names.get(line.Target_GL_Account__c);
            t.targetDepartmentId = line.Target_Department__c;
            t.targetDepartmentName = names.get(line.Target_Department__c);
            t.targetCostCenterId = line.Target_Cost_Center__c;
            t.targetCostCenterName = names.get(line.Target_Cost_Center__c);
            t.percentage = line.Percentage__c;
            t.driverValue = line.Driver_Value__c;
            detail.targets.add(t);
        }
        return detail;
    }

    @AuraEnabled
    public static RunDetailDTO getRunDetail(Id runId) {
        if (runId == null) {
            throw new AllocationWorkspaceException('Select an allocation run first.');
        }
        authorizeView();
        List<Allocation_Run__c> rows = [SELECT Id, Name, Company__c, Allocation_Rule__c, Allocation_Rule__r.Rule_Key__c, Accounting_Period__r.Name,
            Rule_Version__c, Status__c, Source_Amount_Snapshot__c, Calculated_Output_JSON__c, Journal_Entry__c, Journal_Entry__r.Name
            FROM Allocation_Run__c WHERE Id = :runId WITH USER_MODE];
        if (rows.isEmpty()) {
            throw new AllocationWorkspaceException('Allocation run not found or not accessible.');
        }
        Allocation_Run__c r = rows[0];
        SABCompanyAccessService.assertCompanyAccess(r.Company__c);
        RunDetailDTO detail = new RunDetailDTO();
        detail.run = toRun(r);
        detail.lines = new List<AllocationLineDTO>();
        if (String.isBlank(r.Calculated_Output_JSON__c)) {
            return detail;
        }
        SABAllocationRunService.RunOutput output = (SABAllocationRunService.RunOutput) JSON.deserialize(r.Calculated_Output_JSON__c,
            SABAllocationRunService.RunOutput.class);
        Set<Id> accountIds = new Set<Id>();
        Set<Id> departmentIds = new Set<Id>();
        Set<Id> costCenterIds = new Set<Id>();
        addIfPresent(accountIds, output.roundingAccountId);
        for (SABAllocationRunService.SourceAllocation s : output.sources) {
            accountIds.add(s.sourceAccountId);
            for (SABAllocationRunService.Allocation a : s.allocations) {
                addIfPresent(accountIds, a.targetAccountId);
                addIfPresent(departmentIds, a.targetDepartmentId);
                addIfPresent(costCenterIds, a.targetCostCenterId);
            }
        }
        Map<Id, String> names = names(accountIds, departmentIds, costCenterIds);
        Integer n = 0;
        for (SABAllocationRunService.SourceAllocation s : output.sources) {
            for (SABAllocationRunService.Allocation a : s.allocations) {
                detail.lines.add(allocationLine('L' + n++, names.get(s.sourceAccountId), names.get(a.targetAccountId),
                    names.get(a.targetDepartmentId), names.get(a.targetCostCenterId), a.amount));
            }
            if (s.roundingResidual != null && s.roundingResidual != 0) {
                detail.lines.add(allocationLine('L' + n++, names.get(s.sourceAccountId), names.get(output.roundingAccountId) + ' (rounding)',
                    null, null, s.roundingResidual));
            }
        }
        return detail;
    }

    // --------------------------------------------------------------- helpers

    private static void authorizeView() {
        SABPermissionService.assertPermission(VIEW, 'Allocation workspace permission is required.');
        SABAllocationWorkspaceSecurityPolicy.assertReadAccess();
    }

    private static void authorizeCompany(Id companyId) {
        SABPermissionService.assertPermission(VIEW, 'Allocation workspace permission is required.');
        SABCompanyAccessService.assertCompanyAccess(companyId);
        SABAllocationWorkspaceSecurityPolicy.assertReadAccess();
    }

    @TestVisible
    private static Capabilities capabilities() {
        Capabilities c = new Capabilities();
        c.manage = SABPermissionService.hasPermission('SAB_Manage_Allocation');
        c.approve = SABPermissionService.hasPermission('SAB_Approve_Allocation');
        c.postJournal = SABPermissionService.hasPermission('SAB_Post_Journal');
        return c;
    }

    private static Map<Id, String> names(Set<Id> accountIds, Set<Id> departmentIds, Set<Id> costCenterIds) {
        Map<Id, String> result = new Map<Id, String>();
        if (!accountIds.isEmpty()) {
            for (GL_Account__c a : [SELECT Id, Account_Code__c, Name FROM GL_Account__c WHERE Id IN :accountIds WITH USER_MODE]) {
                result.put(a.Id, a.Account_Code__c + ' ' + a.Name);
            }
        }
        if (!departmentIds.isEmpty()) {
            for (Department__c d : [SELECT Id, Name FROM Department__c WHERE Id IN :departmentIds WITH USER_MODE]) {
                result.put(d.Id, d.Name);
            }
        }
        if (!costCenterIds.isEmpty()) {
            for (Cost_Center__c c : [SELECT Id, Name FROM Cost_Center__c WHERE Id IN :costCenterIds WITH USER_MODE]) {
                result.put(c.Id, c.Name);
            }
        }
        return result;
    }

    private static void addIfPresent(Set<Id> target, Id value) {
        if (value != null) {
            target.add(value);
        }
    }

    private static AllocationLineDTO allocationLine(String key, String source, String target, String department, String costCenter,
            Decimal amount) {
        AllocationLineDTO line = new AllocationLineDTO();
        line.rowKey = key;
        line.sourceAccountName = source;
        line.targetAccountName = target;
        line.targetDepartmentName = department;
        line.targetCostCenterName = costCenter;
        line.amount = amount;
        return line;
    }

    private static RuleDTO toRule(Allocation_Rule__c r) {
        RuleDTO dto = new RuleDTO();
        dto.ruleId = r.Id;
        dto.name = r.Name;
        dto.ruleKey = r.Rule_Key__c;
        dto.version = r.Version__c;
        dto.status = r.Status__c;
        dto.driverType = r.Driver_Type__c;
        dto.roundingPolicy = r.Rounding_Policy__c;
        dto.effectiveFrom = r.Effective_From__c;
        dto.effectiveTo = r.Effective_To__c;
        dto.targetCount = r.Allocation_Rule_Line_Allocation_Rule__r == null ? 0 : r.Allocation_Rule_Line_Allocation_Rule__r.size();
        return dto;
    }

    private static RunDTO toRun(Allocation_Run__c r) {
        RunDTO dto = new RunDTO();
        dto.runId = r.Id;
        dto.name = r.Name;
        dto.ruleId = r.Allocation_Rule__c;
        dto.ruleKey = r.Allocation_Rule__r == null ? null : r.Allocation_Rule__r.Rule_Key__c;
        dto.periodName = r.Accounting_Period__r == null ? null : r.Accounting_Period__r.Name;
        dto.ruleVersion = r.Rule_Version__c;
        dto.status = r.Status__c;
        dto.sourceAmount = r.Source_Amount_Snapshot__c;
        dto.journalEntryId = r.Journal_Entry__c;
        dto.journalName = r.Journal_Entry__r == null ? null : r.Journal_Entry__r.Name;
        return dto;
    }

    private static OptionDTO option(String label, Id value) {
        OptionDTO o = new OptionDTO();
        o.label = label;
        o.value = value;
        return o;
    }

    private static Map<String, Integer> zeroCounts(List<String> states) {
        Map<String, Integer> counts = new Map<String, Integer>();
        for (String s : states) {
            counts.put(s, 0);
        }
        return counts;
    }

    private static void increment(Map<String, Integer> counts, String state) {
        if (counts.containsKey(state)) {
            counts.put(state, counts.get(state) + 1);
        }
    }

    private static List<StateCount> toCounts(List<String> states, Map<String, Integer> counts) {
        List<StateCount> result = new List<StateCount>();
        for (String s : states) {
            StateCount c = new StateCount();
            c.state = s;
            c.count = counts.get(s);
            result.add(c);
        }
        return result;
    }
}
