/**
 * G13: Budget versions.
 *
 *   saveDraft      SAB_Manage_Budget   create or replace a Draft version and its lines
 *   submit         SAB_Manage_Budget   Draft -> Submitted (re-validates every line)
 *   approve        SAB_Approve_Budget  Submitted -> Approved; approver differs from creator and submitter;
 *                                      the previously Approved version of the same company and year becomes Superseded
 *   returnToDraft  SAB_Approve_Budget  Submitted -> Draft with a reason
 *   revise         SAB_Manage_Budget   Approved -> new Draft version with the approved lines copied
 *
 * A budget is one company's fiscal-year plan in its functional currency: amounts per accounting period and GL account,
 * optionally by department and cost center, entered in each account's normal-balance direction. Only one Draft or
 * Submitted version per company and year may be open at a time. Budgets have no ledger impact; actuals are compared
 * by SABBudgetVarianceService. Every lifecycle action is idempotent by request key and audited in Business_Action__c.
 */
public with sharing class SABBudgetService {
    public class BudgetException extends Exception {}

    private static final String MANAGE = 'SAB_Manage_Budget';
    private static final String APPROVE = 'SAB_Approve_Budget';
    public static final String DRAFT = 'Draft';
    public static final String SUBMITTED = 'Submitted';
    public static final String APPROVED = 'Approved';
    public static final String SUPERSEDED = 'Superseded';
    private static final Set<String> OPEN_STATES = new Set<String>{DRAFT, SUBMITTED};
    private static final Integer MAX_LINES = 2000;
    private static final Integer MAX_REASON = 255;
    private static final String SOURCE_TYPE = 'Budget__c';

    // ------------------------------------------------------------------ DTOs

    public class LineRequest {
        @AuraEnabled public Id accountingPeriodId { get; set; }
        @AuraEnabled public Id glAccountId { get; set; }
        @AuraEnabled public Id departmentId { get; set; }
        @AuraEnabled public Id costCenterId { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
    }

    public class BudgetRequest {
        @AuraEnabled public Id budgetId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public Integer fiscalYear { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public List<LineRequest> lines { get; set; }
    }

    public class ActionResult {
        @AuraEnabled public Id budgetId;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal version;
        @AuraEnabled public Id supersededBudgetId;
        @AuraEnabled public Boolean replay;
    }

    // ---------------------------------------------------------------- drafts

    @AuraEnabled
    public static Id saveDraft(BudgetRequest request) {
        SABPermissionService.assertPermission(MANAGE, 'Budget management permission is required.');
        if (request == null || request.companyId == null || request.fiscalYear == null) {
            throw new BudgetException('Company and fiscal year are required.');
        }
        SABCompanyAccessService.assertCompanyAccess(request.companyId);
        Store store = new Store();
        Accounting_Company__c company = store.company(request.companyId);
        Budget__c budget;
        if (request.budgetId != null) {
            authorize(request.budgetId);
            budget = store.lockBudget(request.budgetId);
            if (budget.Status__c != DRAFT) {
                throw new BudgetException('Only Draft budgets can be edited.');
            }
            if (budget.Company__c != request.companyId || budget.Fiscal_Year__c != request.fiscalYear) {
                throw new BudgetException('A budget cannot move to another company or fiscal year.');
            }
        } else {
            if (store.openVersionExists(request.companyId, request.fiscalYear, null)) {
                throw new BudgetException('This company already has a Draft or Submitted budget for ' + request.fiscalYear + '.');
            }
            Integer version = store.latestVersion(request.companyId, request.fiscalYear) + 1;
            budget = new Budget__c(Company__c = request.companyId, Fiscal_Year__c = request.fiscalYear, Version__c = version,
                Currency__c = company.Functional_Currency__c, Status__c = DRAFT,
                Budget_Key__c = String.valueOf(request.companyId) + '|' + request.fiscalYear + '|V' + version);
        }
        String name = String.isBlank(request.name) ? 'FY' + request.fiscalYear + ' Budget v' + budget.Version__c : request.name.trim();
        if (name.length() > 80) {
            throw new BudgetException('Budget name cannot exceed 80 characters.');
        }
        budget.Name = name;
        List<Budget_Line__c> lines = validateLines(request.companyId, request.fiscalYear, toLines(request.lines));
        new Writer().saveDraft(budget, lines);
        return budget.Id;
    }

    // ------------------------------------------------------------- lifecycle

    @AuraEnabled
    public static ActionResult submit(Id budgetId, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(MANAGE, 'Budget management permission is required.');
        Budget__c visible = authorize(budgetId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'BUDGET_SUBMITTED');
        }
        Budget__c budget = store.lockBudget(budgetId);
        requireStatus(budget, DRAFT, 'Only a Draft budget can be submitted.');
        validateLines(budget.Company__c, budget.Fiscal_Year__c.intValue(), store.lines(budget.Id));
        budget.Status__c = SUBMITTED;
        budget.Submitted_By__c = UserInfo.getUserId();
        budget.Submitted_At__c = System.now();
        return write(budget, null, 'BUDGET_SUBMITTED', key, 'Budget submitted for approval.');
    }

    @AuraEnabled
    public static ActionResult approve(Id budgetId, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(APPROVE, 'Budget approval permission is required.');
        Budget__c visible = authorize(budgetId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'BUDGET_APPROVED');
        }
        Budget__c budget = store.lockBudget(budgetId);
        requireStatus(budget, SUBMITTED, 'Only a Submitted budget can be approved.');
        Id actor = UserInfo.getUserId();
        if (actor == budget.CreatedById || actor == budget.Submitted_By__c) {
            throw new BudgetException('The creator or submitter of a budget cannot approve it.');
        }
        Budget__c previous = store.approvedVersion(budget.Company__c, budget.Fiscal_Year__c, budget.Id);
        budget.Status__c = APPROVED;
        budget.Approved_By__c = actor;
        budget.Approved_At__c = System.now();
        ActionResult result = write(budget, previous, 'BUDGET_APPROVED', key, 'Budget approved'
            + (previous == null ? '.' : '; version ' + previous.Version__c + ' superseded.'));
        result.supersededBudgetId = previous == null ? null : previous.Id;
        return result;
    }

    @AuraEnabled
    public static ActionResult returnToDraft(Id budgetId, String reason, String requestKey) {
        String key = requireKey(requestKey);
        String why = requireReason(reason);
        SABPermissionService.assertPermission(APPROVE, 'Budget approval permission is required.');
        Budget__c visible = authorize(budgetId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'BUDGET_RETURNED');
        }
        Budget__c budget = store.lockBudget(budgetId);
        requireStatus(budget, SUBMITTED, 'Only a Submitted budget can be returned to Draft.');
        budget.Status__c = DRAFT;
        budget.Submitted_By__c = null;
        budget.Submitted_At__c = null;
        return write(budget, null, 'BUDGET_RETURNED', key, why);
    }

    /** Opens the next Draft version with the approved lines copied; the approved version stays in force until it is replaced. */
    @AuraEnabled
    public static ActionResult revise(Id budgetId, String reason, String requestKey) {
        String key = requireKey(requestKey);
        String why = requireReason(reason);
        SABPermissionService.assertPermission(MANAGE, 'Budget management permission is required.');
        Budget__c visible = authorize(budgetId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            if (prior.Action__c != 'BUDGET_REVISION_OPENED' || !String.valueOf(prior.Reason__c).startsWith(String.valueOf(visible.Id))) {
                throw new BudgetException('Request key has already been used for a different budget action.');
            }
            Budget__c created = store.lockBudget(Id.valueOf(prior.Source_Record_Id__c));
            return result(created, true);
        }
        Budget__c approvedBudget = store.lockBudget(budgetId);
        requireStatus(approvedBudget, APPROVED, 'Only the Approved budget can be revised.');
        if (store.openVersionExists(approvedBudget.Company__c, approvedBudget.Fiscal_Year__c.intValue(), null)) {
            throw new BudgetException('Finish or return the open Draft or Submitted budget for this year before revising.');
        }
        Integer version = store.latestVersion(approvedBudget.Company__c, approvedBudget.Fiscal_Year__c.intValue()) + 1;
        Budget__c revisionBudget = new Budget__c(Company__c = approvedBudget.Company__c, Fiscal_Year__c = approvedBudget.Fiscal_Year__c, Version__c = version,
            Currency__c = approvedBudget.Currency__c, Status__c = DRAFT, Name = ('FY' + approvedBudget.Fiscal_Year__c + ' Budget v' + version).left(80),
            Budget_Key__c = String.valueOf(approvedBudget.Company__c) + '|' + approvedBudget.Fiscal_Year__c + '|V' + version);
        List<Budget_Line__c> copies = new List<Budget_Line__c>();
        for (Budget_Line__c line : store.lines(approvedBudget.Id)) {
            copies.add(new Budget_Line__c(Accounting_Period__c = line.Accounting_Period__c, GL_Account__c = line.GL_Account__c,
                Department__c = line.Department__c, Cost_Center__c = line.Cost_Center__c, Amount__c = line.Amount__c));
        }
        Writer writer = new Writer();
        writer.saveDraft(revisionBudget, copies);
        writer.audit(new Business_Action__c(Company__c = revisionBudget.Company__c, Action__c = 'BUDGET_REVISION_OPENED', Actor__c = UserInfo.getUserId(),
            Action_At__c = System.now(), Reason__c = String.valueOf(approvedBudget.Id) + ': ' + why, Request_Key__c = key,
            Source_Type__c = SOURCE_TYPE, Source_Record_Id__c = String.valueOf(revisionBudget.Id), Source_Version__c = version));
        return result(revisionBudget, false);
    }

    // --------------------------------------------------------------- helpers

    private static Budget__c authorize(Id budgetId) {
        if (budgetId == null) {
            throw new BudgetException('Budget is required.');
        }
        List<Budget__c> visible = [SELECT Id, Company__c FROM Budget__c WHERE Id = :budgetId WITH USER_MODE];
        if (visible.isEmpty()) {
            throw new BudgetException('Budget not found or not accessible.');
        }
        SABCompanyAccessService.assertCompanyAccess(visible[0].Company__c);
        return visible[0];
    }

    private static void requireStatus(Budget__c budget, String status, String message) {
        if (budget.Status__c != status) {
            throw new BudgetException(message);
        }
    }

    private static List<Budget_Line__c> toLines(List<LineRequest> requests) {
        List<Budget_Line__c> lines = new List<Budget_Line__c>();
        for (LineRequest r : requests == null ? new List<LineRequest>() : requests) {
            if (r == null) {
                throw new BudgetException('Budget lines cannot be empty.');
            }
            lines.add(new Budget_Line__c(Accounting_Period__c = r.accountingPeriodId, GL_Account__c = r.glAccountId,
                Department__c = r.departmentId, Cost_Center__c = r.costCenterId, Amount__c = r.amount));
        }
        return lines;
    }

    /**
     * Line rules shared by saveDraft and submit: periods of the company's fiscal year, active GL accounts, departments
     * and cost centers of the company, an amount on every line, and one line per period/account/department/cost center.
     */
    private static List<Budget_Line__c> validateLines(Id companyId, Integer fiscalYear, List<Budget_Line__c> lines) {
        if (lines.isEmpty() || lines.size() > MAX_LINES) {
            throw new BudgetException('A budget needs between 1 and ' + MAX_LINES + ' lines.');
        }
        Set<Id> periods = new Set<Id>();
        Set<Id> accounts = new Set<Id>();
        Set<Id> departments = new Set<Id>();
        Set<Id> costCenters = new Set<Id>();
        Set<String> keys = new Set<String>();
        for (Budget_Line__c line : lines) {
            if (line.Accounting_Period__c == null || line.GL_Account__c == null || line.Amount__c == null) {
                throw new BudgetException('Every budget line needs a period, a GL account and an amount.');
            }
            if (!keys.add(lineKey(null, line))) {
                throw new BudgetException('Each period, account, department and cost center combination can appear only once.');
            }
            periods.add(line.Accounting_Period__c);
            accounts.add(line.GL_Account__c);
            if (line.Department__c != null) {
                departments.add(line.Department__c);
            }
            if (line.Cost_Center__c != null) {
                costCenters.add(line.Cost_Center__c);
            }
        }
        for (Accounting_Period__c p : [SELECT Id, Company__c, Fiscal_Year__c FROM Accounting_Period__c WHERE Id IN :periods WITH USER_MODE]) {
            if (p.Company__c != companyId || p.Fiscal_Year__c != fiscalYear) {
                throw new BudgetException('Budget periods must belong to the company\'s fiscal year ' + fiscalYear + '.');
            }
            periods.remove(p.Id);
        }
        for (GL_Account__c a : [SELECT Id, Company__c, Is_Active__c FROM GL_Account__c WHERE Id IN :accounts WITH USER_MODE]) {
            if (a.Company__c != companyId || a.Is_Active__c != true) {
                throw new BudgetException('Budget GL accounts must be active and belong to the company.');
            }
            accounts.remove(a.Id);
        }
        for (Department__c d : [SELECT Id, Company__c, Is_Active__c FROM Department__c WHERE Id IN :departments WITH USER_MODE]) {
            if (d.Company__c != companyId || d.Is_Active__c != true) {
                throw new BudgetException('Departments must be active and belong to the company.');
            }
            departments.remove(d.Id);
        }
        for (Cost_Center__c c : [SELECT Id, Company__c, Is_Active__c FROM Cost_Center__c WHERE Id IN :costCenters WITH USER_MODE]) {
            if (c.Company__c != companyId || c.Is_Active__c != true) {
                throw new BudgetException('Cost centers must be active and belong to the company.');
            }
            costCenters.remove(c.Id);
        }
        if (!periods.isEmpty() || !accounts.isEmpty() || !departments.isEmpty() || !costCenters.isEmpty()) {
            throw new BudgetException('A period, GL account, department or cost center was not found or is not accessible.');
        }
        return lines;
    }

    @TestVisible
    private static String lineKey(Id budgetId, Budget_Line__c line) {
        return String.valueOf(budgetId) + '|' + line.Accounting_Period__c + '|' + line.GL_Account__c + '|'
            + line.Department__c + '|' + line.Cost_Center__c;
    }

    private static String requireKey(String requestKey) {
        Integer maxLength = Business_Action__c.Request_Key__c.getDescribe().getLength();
        if (String.isBlank(requestKey) || requestKey.trim().length() > maxLength) {
            throw new BudgetException('Request key is required and must not exceed ' + maxLength + ' characters.');
        }
        return requestKey.trim();
    }

    private static String requireReason(String reason) {
        if (String.isBlank(reason) || reason.trim().length() > MAX_REASON) {
            throw new BudgetException('A reason of up to ' + MAX_REASON + ' characters is required.');
        }
        return reason.trim();
    }

    private static ActionResult replay(Business_Action__c prior, Id budgetId, String expectedAction) {
        if (prior.Action__c != expectedAction || prior.Source_Record_Id__c != String.valueOf(budgetId)) {
            throw new BudgetException('Request key has already been used for a different budget action.');
        }
        return result(new Store().lockBudget(budgetId), true);
    }

    private static ActionResult write(Budget__c budget, Budget__c previousBudget, String actionName, String key, String reason) {
        new Writer().lifecycle(budget, previousBudget, new Business_Action__c(Company__c = budget.Company__c, Action__c = actionName,
            Actor__c = UserInfo.getUserId(), Action_At__c = System.now(), Reason__c = reason, Request_Key__c = key,
            Source_Type__c = SOURCE_TYPE, Source_Record_Id__c = String.valueOf(budget.Id), Source_Version__c = budget.Version__c));
        return result(budget, false);
    }

    private static ActionResult result(Budget__c budget, Boolean isReplay) {
        ActionResult r = new ActionResult();
        r.budgetId = budget.Id;
        r.status = budget.Status__c;
        r.version = budget.Version__c;
        r.replay = isReplay;
        return r;
    }

    /**
     * Narrow system reads after the permission and company checks. Version numbering, open-version and approved-version
     * checks must see every budget of the company and year, whatever the running user's sharing.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c, Reason__c FROM Business_Action__c
                WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        Accounting_Company__c company(Id companyId) {
            List<Accounting_Company__c> rows = [SELECT Id, Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE];
            if (rows.isEmpty()) {
                throw new BudgetException('Accounting Company not found.');
            }
            return rows[0];
        }
        Budget__c lockBudget(Id budgetId) {
            List<Budget__c> rows = [SELECT Id, Name, Company__c, Fiscal_Year__c, Version__c, Currency__c, Status__c, Budget_Key__c,
                Submitted_By__c, Submitted_At__c, Approved_By__c, Approved_At__c, CreatedById FROM Budget__c WHERE Id = :budgetId
                WITH SYSTEM_MODE FOR UPDATE];
            if (rows.isEmpty()) {
                throw new BudgetException('Budget not found.');
            }
            return rows[0];
        }
        List<Budget_Line__c> lines(Id budgetId) {
            return [SELECT Id, Accounting_Period__c, GL_Account__c, Department__c, Cost_Center__c, Amount__c FROM Budget_Line__c
                WHERE Budget__c = :budgetId WITH SYSTEM_MODE LIMIT 2001];
        }
        Boolean openVersionExists(Id companyId, Integer fiscalYear, Id excludeId) {
            return [SELECT COUNT() FROM Budget__c WHERE Company__c = :companyId AND Fiscal_Year__c = :fiscalYear
                AND Status__c IN :OPEN_STATES AND Id != :excludeId WITH SYSTEM_MODE] > 0;
        }
        Integer latestVersion(Id companyId, Integer fiscalYear) {
            List<Budget__c> rows = [SELECT Version__c FROM Budget__c WHERE Company__c = :companyId AND Fiscal_Year__c = :fiscalYear
                WITH SYSTEM_MODE ORDER BY Version__c DESC LIMIT 1];
            return rows.isEmpty() || rows[0].Version__c == null ? 0 : rows[0].Version__c.intValue();
        }
        Budget__c approvedVersion(Id companyId, Decimal fiscalYear, Id excludeId) {
            List<Budget__c> rows = [SELECT Id, Version__c, Status__c FROM Budget__c WHERE Company__c = :companyId
                AND Fiscal_Year__c = :fiscalYear AND Status__c = :APPROVED AND Id != :excludeId WITH SYSTEM_MODE FOR UPDATE];
            return rows.isEmpty() ? null : rows[0];
        }
    }

    /** Narrow system writes inside the budget guard scope, after the service's checks. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void saveDraft(Budget__c budget, List<Budget_Line__c> lines) {
            SABBudgetGuard.beginWrite();
            try {
                upsert as system budget;
                delete as system [SELECT Id FROM Budget_Line__c WHERE Budget__c = :budget.Id WITH SYSTEM_MODE];
                for (Budget_Line__c line : lines) {
                    line.Budget__c = budget.Id;
                    line.Line_Key__c = lineKey(budget.Id, line);
                }
                insert as system lines;
            } finally {
                SABBudgetGuard.endWrite();
            }
        }
        void lifecycle(Budget__c budget, Budget__c previousBudget, Business_Action__c audit) {
            SABBudgetGuard.beginWrite();
            try {
                List<Budget__c> changes = new List<Budget__c>();
                if (previousBudget != null) {
                    changes.add(new Budget__c(Id = previousBudget.Id, Status__c = SUPERSEDED));
                }
                changes.add(new Budget__c(Id = budget.Id, Status__c = budget.Status__c, Submitted_By__c = budget.Submitted_By__c,
                    Submitted_At__c = budget.Submitted_At__c, Approved_By__c = budget.Approved_By__c, Approved_At__c = budget.Approved_At__c));
                update as system changes;
                insert as system audit;
            } finally {
                SABBudgetGuard.endWrite();
            }
        }
        void audit(Business_Action__c audit) {
            insert as system audit;
        }
    }
}
