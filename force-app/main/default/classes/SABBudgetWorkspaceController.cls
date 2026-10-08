/**
 * G13B: Budget Workspace controller.
 *
 * Read layer for the sabBudgetWorkspace LWC. Every read runs in user mode after SAB_View_Budgets, the company grant and the
 * CRUD/FLS policy. Changes go through SABBudgetService; budget versus actual is read through SABBudgetVarianceService.
 */
public with sharing class SABBudgetWorkspaceController {
    public class BudgetWorkspaceException extends Exception {}

    private static final String VIEW = 'SAB_View_Budgets';
    private static final Integer ROW_LIMIT = 200;
    private static final List<String> STATES = new List<String>{'Draft', 'Submitted', 'Approved', 'Superseded'};

    public class Capabilities {
        @AuraEnabled public Boolean manage;
        @AuraEnabled public Boolean approve;
    }

    public class OptionDTO {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
    }

    public class PeriodDTO {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public Integer fiscalYear;
    }

    public class StateCount {
        @AuraEnabled public String state;
        @AuraEnabled public Integer count;
    }

    public class BudgetDTO {
        @AuraEnabled public Id budgetId;
        @AuraEnabled public String name;
        @AuraEnabled public Integer fiscalYear;
        @AuraEnabled public Decimal version;
        @AuraEnabled public String status;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public Integer lineCount;
    }

    public class WorkspaceDTO {
        @AuraEnabled public Id companyId;
        @AuraEnabled public String companyName;
        @AuraEnabled public String functionalCurrency;
        @AuraEnabled public Capabilities capabilities;
        @AuraEnabled public List<BudgetDTO> budgets;
        @AuraEnabled public List<StateCount> stateCounts;
        @AuraEnabled public List<Integer> fiscalYears;
        @AuraEnabled public List<PeriodDTO> periods;
        @AuraEnabled public List<OptionDTO> accounts;
        @AuraEnabled public List<OptionDTO> departments;
        @AuraEnabled public List<OptionDTO> costCenters;
    }

    public class LineDTO {
        @AuraEnabled public Id lineId;
        @AuraEnabled public Id accountingPeriodId;
        @AuraEnabled public String periodName;
        @AuraEnabled public Id glAccountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public Id departmentId;
        @AuraEnabled public String departmentName;
        @AuraEnabled public Id costCenterId;
        @AuraEnabled public String costCenterName;
        @AuraEnabled public Decimal amount;
    }

    public class BudgetDetailDTO {
        @AuraEnabled public BudgetDTO budget;
        @AuraEnabled public List<LineDTO> lines;
        @AuraEnabled public Decimal total;
    }

    @AuraEnabled
    public static WorkspaceDTO getWorkspace(Id companyId) {
        if (companyId == null) {
            throw new BudgetWorkspaceException('Select an Accounting Company first.');
        }
        authorize();
        SABCompanyAccessService.assertCompanyAccess(companyId);
        List<Accounting_Company__c> companies = [SELECT Id, Name__c, Functional_Currency__c FROM Accounting_Company__c
            WHERE Id = :companyId WITH USER_MODE];
        if (companies.isEmpty()) {
            throw new BudgetWorkspaceException('Accounting Company not found or not accessible.');
        }
        WorkspaceDTO result = new WorkspaceDTO();
        result.companyId = companyId;
        result.companyName = companies[0].Name__c;
        result.functionalCurrency = companies[0].Functional_Currency__c;
        result.capabilities = capabilities();
        Map<String, Integer> counts = new Map<String, Integer>();
        for (String s : STATES) {
            counts.put(s, 0);
        }
        result.budgets = new List<BudgetDTO>();
        for (Budget__c b : [SELECT Id, Name, Fiscal_Year__c, Version__c, Status__c, Currency__c, (SELECT Id FROM Budget_Line_Budget__r)
                FROM Budget__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Fiscal_Year__c DESC, Version__c DESC LIMIT :ROW_LIMIT]) {
            result.budgets.add(toBudget(b));
            if (counts.containsKey(b.Status__c)) {
                counts.put(b.Status__c, counts.get(b.Status__c) + 1);
            }
        }
        result.stateCounts = new List<StateCount>();
        for (String s : STATES) {
            StateCount c = new StateCount();
            c.state = s;
            c.count = counts.get(s);
            result.stateCounts.add(c);
        }
        result.periods = new List<PeriodDTO>();
        Set<Integer> years = new Set<Integer>();
        for (Accounting_Period__c p : [SELECT Id, Name, Fiscal_Year__c FROM Accounting_Period__c WHERE Company__c = :companyId WITH USER_MODE
                ORDER BY Start_Date__c LIMIT 500]) {
            PeriodDTO dto = new PeriodDTO();
            dto.label = p.Name;
            dto.value = p.Id;
            dto.fiscalYear = p.Fiscal_Year__c == null ? null : p.Fiscal_Year__c.intValue();
            result.periods.add(dto);
            if (dto.fiscalYear != null) {
                years.add(dto.fiscalYear);
            }
        }
        result.fiscalYears = new List<Integer>(years);
        result.fiscalYears.sort();
        result.accounts = new List<OptionDTO>();
        for (GL_Account__c a : [SELECT Id, Account_Code__c, Name FROM GL_Account__c WHERE Company__c = :companyId AND Is_Active__c = true
                WITH USER_MODE ORDER BY Account_Code__c LIMIT 1000]) {
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
        return result;
    }

    @AuraEnabled
    public static BudgetDetailDTO getBudgetDetail(Id budgetId) {
        if (budgetId == null) {
            throw new BudgetWorkspaceException('Select a budget first.');
        }
        authorize();
        List<Budget__c> rows = [SELECT Id, Name, Company__c, Fiscal_Year__c, Version__c, Status__c, Currency__c,
            (SELECT Id FROM Budget_Line_Budget__r) FROM Budget__c WHERE Id = :budgetId WITH USER_MODE];
        if (rows.isEmpty()) {
            throw new BudgetWorkspaceException('Budget not found or not accessible.');
        }
        SABCompanyAccessService.assertCompanyAccess(rows[0].Company__c);
        BudgetDetailDTO detail = new BudgetDetailDTO();
        detail.budget = toBudget(rows[0]);
        detail.lines = new List<LineDTO>();
        detail.total = 0;
        for (Budget_Line__c l : [SELECT Id, Accounting_Period__c, Accounting_Period__r.Name, GL_Account__c, GL_Account__r.Account_Code__c,
                GL_Account__r.Name, Department__c, Department__r.Name, Cost_Center__c, Cost_Center__r.Name, Amount__c FROM Budget_Line__c
                WHERE Budget__c = :budgetId WITH USER_MODE ORDER BY Accounting_Period__r.Start_Date__c, GL_Account__r.Account_Code__c
                LIMIT 2001]) {
            LineDTO dto = new LineDTO();
            dto.lineId = l.Id;
            dto.accountingPeriodId = l.Accounting_Period__c;
            dto.periodName = l.Accounting_Period__r.Name;
            dto.glAccountId = l.GL_Account__c;
            dto.accountName = l.GL_Account__r.Account_Code__c + ' ' + l.GL_Account__r.Name;
            dto.departmentId = l.Department__c;
            dto.departmentName = l.Department__r == null ? null : l.Department__r.Name;
            dto.costCenterId = l.Cost_Center__c;
            dto.costCenterName = l.Cost_Center__r == null ? null : l.Cost_Center__r.Name;
            dto.amount = l.Amount__c;
            detail.total += l.Amount__c == null ? 0 : l.Amount__c;
            detail.lines.add(dto);
        }
        return detail;
    }

    private static void authorize() {
        SABPermissionService.assertPermission(VIEW, 'Budget workspace permission is required.');
        SABAccessControlService.assertReadable(Budget__c.SObjectType, new List<Schema.SObjectField>{Budget__c.Company__c,
            Budget__c.Fiscal_Year__c, Budget__c.Version__c, Budget__c.Status__c, Budget__c.Currency__c});
        SABAccessControlService.assertReadable(Budget_Line__c.SObjectType, new List<Schema.SObjectField>{Budget_Line__c.Accounting_Period__c,
            Budget_Line__c.GL_Account__c, Budget_Line__c.Department__c, Budget_Line__c.Cost_Center__c, Budget_Line__c.Amount__c});
    }

    @TestVisible
    private static Capabilities capabilities() {
        Capabilities c = new Capabilities();
        c.manage = SABPermissionService.hasPermission('SAB_Manage_Budget');
        c.approve = SABPermissionService.hasPermission('SAB_Approve_Budget');
        return c;
    }

    private static BudgetDTO toBudget(Budget__c b) {
        BudgetDTO dto = new BudgetDTO();
        dto.budgetId = b.Id;
        dto.name = b.Name;
        dto.fiscalYear = b.Fiscal_Year__c == null ? null : b.Fiscal_Year__c.intValue();
        dto.version = b.Version__c;
        dto.status = b.Status__c;
        dto.currencyCode = b.Currency__c;
        dto.lineCount = b.Budget_Line_Budget__r == null ? 0 : b.Budget_Line_Budget__r.size();
        return dto;
    }

    private static OptionDTO option(String label, Id value) {
        OptionDTO o = new OptionDTO();
        o.label = label;
        o.value = value;
        return o;
    }
}
