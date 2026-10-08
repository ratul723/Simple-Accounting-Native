import { LightningElement, wire } from 'lwc';
import { subscribe, unsubscribe, MessageContext, APPLICATION_SCOPE } from 'lightning/messageService';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import COMPANY_CONTEXT_CHANNEL from '@salesforce/messageChannel/SABCompanyContext__c';

import getWorkspace from '@salesforce/apex/SABBudgetWorkspaceController.getWorkspace';
import getBudgetDetail from '@salesforce/apex/SABBudgetWorkspaceController.getBudgetDetail';
import saveDraft from '@salesforce/apex/SABBudgetService.saveDraft';
import submitBudget from '@salesforce/apex/SABBudgetService.submit';
import approveBudget from '@salesforce/apex/SABBudgetService.approve';
import returnToDraft from '@salesforce/apex/SABBudgetService.returnToDraft';
import reviseBudget from '@salesforce/apex/SABBudgetService.revise';
import getBudgetVsActual from '@salesforce/apex/SABBudgetVarianceService.getBudgetVsActual';

const STORAGE_KEY = 'sabSelectedAccountingCompanyId';
const MONEY = { type: 'number', typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 2 } };

const BUDGET_COLUMNS = [
    { label: 'Budget', fieldName: 'name' },
    { label: 'Fiscal Year', fieldName: 'fiscalYear', type: 'number', typeAttributes: { useGrouping: false } },
    { label: 'Version', fieldName: 'version', type: 'number' },
    { label: 'Status', fieldName: 'status' },
    { label: 'Currency', fieldName: 'currencyCode' },
    { label: 'Lines', fieldName: 'lineCount', type: 'number' }
];

const LINE_COLUMNS = [
    { label: 'Period', fieldName: 'periodName' },
    { label: 'GL Account', fieldName: 'accountName' },
    { label: 'Department', fieldName: 'departmentName' },
    { label: 'Cost Center', fieldName: 'costCenterName' },
    { label: 'Amount', fieldName: 'amount', ...MONEY }
];

const VARIANCE_COLUMNS = [
    { label: 'Account', fieldName: 'accountLabel' },
    { label: 'Dimension', fieldName: 'dimensionName' },
    { label: 'Budget', fieldName: 'budget', ...MONEY },
    { label: 'Actual', fieldName: 'actual', ...MONEY },
    { label: 'Variance', fieldName: 'variance', ...MONEY },
    { label: 'Variance %', fieldName: 'variancePercent', type: 'number', typeAttributes: { maximumFractionDigits: 2 } },
    { label: 'Result', fieldName: 'resultLabel' }
];

const GROUPING_OPTIONS = [
    { label: 'By account', value: 'ACCOUNT' },
    { label: 'By account and department', value: 'ACCOUNT_DEPARTMENT' },
    { label: 'By account and cost center', value: 'ACCOUNT_COST_CENTER' }
];

let lineCounter = 0;

function emptyLine() {
    lineCounter += 1;
    return { key: `b${lineCounter}`, accountingPeriodId: '', glAccountId: '', departmentId: '', costCenterId: '', amount: '' };
}

function resultLabel(row) {
    if (row.unbudgeted) {
        return 'Unbudgeted';
    }
    if (row.favourable === true) {
        return 'Favourable';
    }
    return row.favourable === false ? 'Unfavourable' : '';
}

export default class SabBudgetWorkspace extends LightningElement {
    budgetColumns = BUDGET_COLUMNS;
    lineColumns = LINE_COLUMNS;
    varianceColumns = VARIANCE_COLUMNS;
    groupingOptions = GROUPING_OPTIONS;

    companyId;
    workspace;
    subscription;
    isLoading = false;
    errorMessage;

    yearFilter = '';
    showBudgetForm = false;
    budgetForm;
    selectedBudgetId;
    detail;
    reason = '';

    varianceYear = '';
    varianceBudgetId = '';
    varianceGrouping = 'ACCOUNT';
    variancePeriodIds = [];
    variance;

    // Request keys survive a failed attempt (a retry replays) and are discarded after success.
    requestKeys = {};

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        this.subscribeToCompanyContext();
        const stored = window.sessionStorage.getItem(STORAGE_KEY);
        if (stored) {
            this.companyId = stored;
            this.refresh();
        }
    }

    disconnectedCallback() {
        if (this.subscription) {
            unsubscribe(this.subscription);
            this.subscription = undefined;
        }
    }

    subscribeToCompanyContext() {
        if (this.subscription || !this.messageContext) {
            return;
        }
        this.subscription = subscribe(this.messageContext, COMPANY_CONTEXT_CHANNEL,
            (message) => this.handleCompanyContext(message), { scope: APPLICATION_SCOPE });
    }

    handleCompanyContext(message) {
        if (!message || message.companyCleared) {
            this.companyId = undefined;
            this.workspace = undefined;
            this.resetSelection();
            return;
        }
        if (message.companyId && message.companyId !== this.companyId) {
            this.companyId = message.companyId;
            this.requestKeys = {};
            this.resetSelection();
            this.refresh();
        }
    }

    resetSelection() {
        this.selectedBudgetId = undefined;
        this.detail = undefined;
        this.showBudgetForm = false;
        this.variance = undefined;
        this.reason = '';
        this.yearFilter = '';
        this.varianceYear = '';
        this.varianceBudgetId = '';
        this.variancePeriodIds = [];
    }

    async refresh() {
        if (!this.companyId) {
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            this.workspace = await getWorkspace({ companyId: this.companyId });
            const years = this.workspace.fiscalYears || [];
            if (!this.varianceYear && years.length) {
                this.varianceYear = String(years[years.length - 1]);
            }
            if (this.selectedBudgetId) {
                this.detail = await getBudgetDetail({ budgetId: this.selectedBudgetId });
            }
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    // ------------------------------------------------------------- getters

    get hasCompany() {
        return Boolean(this.companyId);
    }

    get hasWorkspace() {
        return Boolean(this.workspace);
    }

    get companyName() {
        return this.workspace ? this.workspace.companyName : '';
    }

    get functionalCurrency() {
        return this.workspace ? this.workspace.functionalCurrency : '';
    }

    get can() {
        return (this.workspace && this.workspace.capabilities) || {};
    }

    get stateCounts() {
        return (this.workspace && this.workspace.stateCounts) || [];
    }

    get yearOptions() {
        return ((this.workspace && this.workspace.fiscalYears) || []).map((y) => ({ label: String(y), value: String(y) }));
    }

    get yearFilterOptions() {
        return [{ label: 'All years', value: '' }, ...this.yearOptions];
    }

    get budgets() {
        const all = (this.workspace && this.workspace.budgets) || [];
        return this.yearFilter ? all.filter((b) => String(b.fiscalYear) === this.yearFilter) : all;
    }

    get hasBudgets() {
        return this.budgets.length > 0;
    }

    get selectedBudgetRows() {
        return this.selectedBudgetId ? [this.selectedBudgetId] : [];
    }

    get accountOptions() {
        return (this.workspace && this.workspace.accounts) || [];
    }

    get departmentOptions() {
        return [{ label: 'None', value: '' }, ...((this.workspace && this.workspace.departments) || [])];
    }

    get costCenterOptions() {
        return [{ label: 'None', value: '' }, ...((this.workspace && this.workspace.costCenters) || [])];
    }

    periodsFor(year) {
        return ((this.workspace && this.workspace.periods) || []).filter((p) => String(p.fiscalYear) === String(year))
            .map((p) => ({ label: p.label, value: p.value }));
    }

    get formPeriodOptions() {
        return this.budgetForm ? this.periodsFor(this.budgetForm.fiscalYear) : [];
    }

    get formTotalLabel() {
        const total = this.budgetForm ? this.budgetForm.lines.reduce((sum, l) => sum + (Number(l.amount) || 0), 0) : 0;
        return `Total: ${total.toFixed(2)} ${this.functionalCurrency}`;
    }

    get budget() {
        return this.detail ? this.detail.budget : undefined;
    }

    get hasSelectedBudget() {
        return Boolean(this.budget);
    }

    get detailLines() {
        return (this.detail && this.detail.lines) || [];
    }

    get isDraft() {
        return this.budget && this.budget.status === 'Draft';
    }

    get isSubmitted() {
        return this.budget && this.budget.status === 'Submitted';
    }

    get isApproved() {
        return this.budget && this.budget.status === 'Approved';
    }

    get varianceBudgetOptions() {
        const all = (this.workspace && this.workspace.budgets) || [];
        return [{ label: 'Approved budget', value: '' }, ...all.filter((b) => String(b.fiscalYear) === this.varianceYear)
            .map((b) => ({ label: `${b.name} (v${b.version}, ${b.status})`, value: b.budgetId }))];
    }

    get variancePeriodOptions() {
        return this.periodsFor(this.varianceYear);
    }

    get varianceRows() {
        if (!this.variance) {
            return [];
        }
        return this.variance.rows.map((r) => ({ ...r, rowKey: `${r.glAccountId}|${r.dimensionId || ''}`,
            accountLabel: `${r.accountCode} ${r.accountName}`, resultLabel: resultLabel(r) }));
    }

    get hasVariance() {
        return Boolean(this.variance);
    }

    get varianceTitle() {
        return this.variance ? `${this.variance.budgetName} (v${this.variance.budgetVersion}, ${this.variance.budgetStatus})` : '';
    }

    // Disabled flags: permission AND inputs AND not busy. The services re-check everything.
    get newBudgetDisabled() {
        return this.isLoading || !this.can.manage || this.yearOptions.length === 0;
    }

    get saveBudgetDisabled() {
        const f = this.budgetForm;
        if (!f) {
            return true;
        }
        const linesValid = f.lines.length > 0 && f.lines.every((l) => l.accountingPeriodId && l.glAccountId && l.amount !== ''
            && !Number.isNaN(Number(l.amount)));
        return this.isLoading || !this.can.manage || !f.fiscalYear || !linesValid;
    }

    get manageDisabled() {
        return this.isLoading || !this.can.manage;
    }

    get approveDisabled() {
        return this.isLoading || !this.can.approve;
    }

    get returnDisabled() {
        return this.isLoading || !this.can.approve || !this.reason.trim();
    }

    get reviseDisabled() {
        return this.isLoading || !this.can.manage || !this.reason.trim();
    }

    get runVarianceDisabled() {
        return this.isLoading || !this.varianceYear;
    }

    // ------------------------------------------------------------- handlers

    handleRefresh() {
        this.refresh();
    }

    handleYearFilter(event) {
        this.yearFilter = event.detail.value;
    }

    handleReasonChange(event) {
        this.reason = event.detail.value;
    }

    handleNewBudget() {
        const years = this.yearOptions;
        this.budgetForm = { budgetId: undefined, fiscalYear: this.yearFilter || years[years.length - 1].value, name: '', lines: [emptyLine()] };
        this.showBudgetForm = true;
    }

    handleEditBudget() {
        this.budgetForm = {
            budgetId: this.budget.budgetId, fiscalYear: String(this.budget.fiscalYear), name: this.budget.name,
            lines: this.detailLines.map((l) => ({ ...emptyLine(), accountingPeriodId: l.accountingPeriodId, glAccountId: l.glAccountId,
                departmentId: l.departmentId || '', costCenterId: l.costCenterId || '', amount: String(l.amount) }))
        };
        this.showBudgetForm = true;
    }

    handleCancelForm() {
        this.showBudgetForm = false;
    }

    handleFormField(event) {
        const field = event.target.dataset.field;
        const changes = { [field]: event.detail.value };
        if (field === 'fiscalYear') {
            changes.lines = this.budgetForm.lines.map((l) => ({ ...l, accountingPeriodId: '' }));
        }
        this.budgetForm = { ...this.budgetForm, ...changes };
    }

    handleLineField(event) {
        const { key, field } = event.target.dataset;
        this.budgetForm = { ...this.budgetForm,
            lines: this.budgetForm.lines.map((l) => (l.key === key ? { ...l, [field]: event.detail.value } : l)) };
    }

    handleAddLine() {
        this.budgetForm = { ...this.budgetForm, lines: [...this.budgetForm.lines, emptyLine()] };
    }

    handleRemoveLine(event) {
        const key = event.target.dataset.key;
        this.budgetForm = { ...this.budgetForm, lines: this.budgetForm.lines.filter((l) => l.key !== key) };
    }

    async handleBudgetSelection(event) {
        const rows = event.detail.selectedRows || [];
        this.selectedBudgetId = rows.length ? rows[0].budgetId : undefined;
        this.reason = '';
        this.isLoading = true;
        try {
            this.detail = this.selectedBudgetId ? await getBudgetDetail({ budgetId: this.selectedBudgetId }) : undefined;
        } catch (error) {
            this.notifyError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleVarianceField(event) {
        const field = event.target.dataset.field;
        this[field] = event.detail.value;
        if (field === 'varianceYear') {
            this.varianceBudgetId = '';
            this.variancePeriodIds = [];
        }
    }

    async handleRunVariance() {
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            this.variance = await getBudgetVsActual({ companyId: this.companyId, fiscalYear: Number(this.varianceYear),
                budgetId: this.varianceBudgetId || null, periodIds: this.variancePeriodIds, groupBy: this.varianceGrouping });
        } catch (error) {
            this.variance = undefined;
            this.notifyError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleSaveBudget() {
        const f = this.budgetForm;
        const request = {
            budgetId: f.budgetId || null, companyId: this.companyId, fiscalYear: Number(f.fiscalYear), name: f.name.trim() || null,
            lines: f.lines.map((l) => ({ accountingPeriodId: l.accountingPeriodId, glAccountId: l.glAccountId,
                departmentId: l.departmentId || null, costCenterId: l.costCenterId || null, amount: Number(l.amount) }))
        };
        return this.runAction(null, async () => {
            this.selectedBudgetId = await saveDraft({ request });
            this.showBudgetForm = false;
            return 'Budget saved as Draft.';
        });
    }

    handleSubmit() {
        return this.runAction(`SUBMIT|${this.selectedBudgetId}`, async (key) => {
            await submitBudget({ budgetId: this.selectedBudgetId, requestKey: key });
            return 'Budget submitted for approval.';
        });
    }

    handleApprove() {
        return this.runAction(`APPROVE|${this.selectedBudgetId}`, async (key) => {
            const result = await approveBudget({ budgetId: this.selectedBudgetId, requestKey: key });
            return result && result.supersededBudgetId ? 'Budget approved; the previous version is superseded.' : 'Budget approved.';
        });
    }

    handleReturn() {
        return this.runAction(`RETURN|${this.selectedBudgetId}`, async (key) => {
            await returnToDraft({ budgetId: this.selectedBudgetId, reason: this.reason.trim(), requestKey: key });
            return 'Budget returned to Draft.';
        });
    }

    handleRevise() {
        return this.runAction(`REVISE|${this.selectedBudgetId}`, async (key) => {
            const result = await reviseBudget({ budgetId: this.selectedBudgetId, reason: this.reason.trim(), requestKey: key });
            this.selectedBudgetId = result.budgetId;
            return `Draft version ${result.version} opened with the approved lines.`;
        });
    }

    // ------------------------------------------------------------- actions

    requestKey(name) {
        if (!this.requestKeys[name]) {
            this.requestKeys[name] = `G13B|${name}|${Date.now()}`.slice(0, 120);
        }
        return this.requestKeys[name];
    }

    async runAction(name, call) {
        const key = name ? this.requestKey(name) : undefined;
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const message = await call(key);
            if (name) {
                delete this.requestKeys[name];
            }
            this.reason = '';
            this.dispatchEvent(new ShowToastEvent({ title: 'Budgets', message, variant: 'success' }));
            this.isLoading = false;
            await this.refresh();
        } catch (error) {
            this.notifyError(error);
        } finally {
            this.isLoading = false;
        }
    }

    notifyError(error) {
        const message = this.reduceError(error);
        this.errorMessage = message;
        this.dispatchEvent(new ShowToastEvent({ title: 'Budgets', message, variant: 'error' }));
    }

    reduceError(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        if (error && error.message) {
            return error.message;
        }
        return 'An unexpected Budget Workspace error occurred.';
    }
}
