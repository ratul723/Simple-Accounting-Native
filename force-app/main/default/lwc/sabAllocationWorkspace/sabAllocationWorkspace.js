import { LightningElement, wire } from 'lwc';
import { subscribe, unsubscribe, MessageContext, APPLICATION_SCOPE } from 'lightning/messageService';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import COMPANY_CONTEXT_CHANNEL from '@salesforce/messageChannel/SABCompanyContext__c';

import getWorkspace from '@salesforce/apex/SABAllocationWorkspaceController.getWorkspace';
import getRuleDetail from '@salesforce/apex/SABAllocationWorkspaceController.getRuleDetail';
import getRunDetail from '@salesforce/apex/SABAllocationWorkspaceController.getRunDetail';
import saveDraft from '@salesforce/apex/SABAllocationRuleService.saveDraft';
import approveRule from '@salesforce/apex/SABAllocationRuleService.approve';
import reviseRule from '@salesforce/apex/SABAllocationRuleService.revise';
import retireRule from '@salesforce/apex/SABAllocationRuleService.retire';
import previewRun from '@salesforce/apex/SABAllocationRunService.preview';
import approveRun from '@salesforce/apex/SABAllocationRunService.approve';
import postRun from '@salesforce/apex/SABAllocationRunService.post';
import discardRun from '@salesforce/apex/SABAllocationRunService.discard';

const STORAGE_KEY = 'sabSelectedAccountingCompanyId';
const MONEY = { type: 'number', typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 2 } };

const RULE_COLUMNS = [
    { label: 'Rule Key', fieldName: 'ruleKey' },
    { label: 'Name', fieldName: 'name' },
    { label: 'Version', fieldName: 'version', type: 'number' },
    { label: 'Status', fieldName: 'status' },
    { label: 'Driver', fieldName: 'driverType' },
    { label: 'Rounding', fieldName: 'roundingPolicy' },
    { label: 'Effective From', fieldName: 'effectiveFrom', type: 'date-local' },
    { label: 'Targets', fieldName: 'targetCount', type: 'number' }
];

const TARGET_COLUMNS = [
    { label: '#', fieldName: 'sequence', type: 'number', initialWidth: 60 },
    { label: 'GL Account', fieldName: 'targetAccountName' },
    { label: 'Department', fieldName: 'targetDepartmentName' },
    { label: 'Cost Center', fieldName: 'targetCostCenterName' },
    { label: 'Weight', fieldName: 'weight', type: 'number' }
];

const RUN_COLUMNS = [
    { label: 'Run', fieldName: 'name' },
    { label: 'Rule', fieldName: 'ruleKey' },
    { label: 'Version', fieldName: 'ruleVersion', type: 'number' },
    { label: 'Period', fieldName: 'periodName' },
    { label: 'Status', fieldName: 'status' },
    { label: 'Source Amount', fieldName: 'sourceAmount', ...MONEY },
    { label: 'Journal', fieldName: 'journalName' }
];

const LINE_COLUMNS = [
    { label: 'Source Account', fieldName: 'sourceAccountName' },
    { label: 'Target Account', fieldName: 'targetAccountName' },
    { label: 'Department', fieldName: 'targetDepartmentName' },
    { label: 'Cost Center', fieldName: 'targetCostCenterName' },
    { label: 'Amount', fieldName: 'amount', ...MONEY }
];

const DRIVER_OPTIONS = [
    { label: 'Percent', value: 'Percent' },
    { label: 'Manual Driver', value: 'Manual Driver' }
];

const ROUNDING_OPTIONS = [
    { label: 'Largest Remainder', value: 'Largest Remainder' },
    { label: 'Last Target', value: 'Last Target' },
    { label: 'Rounding Account', value: 'Rounding Account' }
];

let targetCounter = 0;

function emptyTarget() {
    targetCounter += 1;
    return { key: `t${targetCounter}`, targetGlAccountId: '', targetDepartmentId: '', targetCostCenterId: '', weight: '' };
}

function emptyForm() {
    return { ruleId: undefined, name: '', ruleKey: '', driverType: 'Percent', roundingPolicy: 'Largest Remainder', effectiveFrom: '',
        effectiveTo: '', sourceAccountIds: [], sourceDepartmentId: '', sourceCostCenterId: '', targets: [emptyTarget()] };
}

export default class SabAllocationWorkspace extends LightningElement {
    ruleColumns = RULE_COLUMNS;
    targetColumns = TARGET_COLUMNS;
    runColumns = RUN_COLUMNS;
    lineColumns = LINE_COLUMNS;
    driverOptions = DRIVER_OPTIONS;
    roundingOptions = ROUNDING_OPTIONS;

    companyId;
    workspace;
    subscription;
    isLoading = false;
    errorMessage;

    ruleForm = emptyForm();
    showRuleForm = false;
    selectedRuleId;
    ruleDetail;
    selectedRunId;
    runDetail;
    previewRuleId;
    previewPeriodId;
    reason = '';

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
            this.resetSelections();
            return;
        }
        if (message.companyId && message.companyId !== this.companyId) {
            this.companyId = message.companyId;
            this.requestKeys = {};
            this.resetSelections();
            this.refresh();
        }
    }

    resetSelections() {
        this.selectedRuleId = undefined;
        this.ruleDetail = undefined;
        this.selectedRunId = undefined;
        this.runDetail = undefined;
        this.showRuleForm = false;
        this.ruleForm = emptyForm();
        this.reason = '';
    }

    // ------------------------------------------------------------- loading

    async refresh() {
        if (!this.companyId) {
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            this.workspace = await getWorkspace({ companyId: this.companyId });
            if (this.selectedRuleId) {
                this.ruleDetail = await getRuleDetail({ ruleId: this.selectedRuleId });
            }
            if (this.selectedRunId) {
                this.runDetail = await getRunDetail({ runId: this.selectedRunId });
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

    get rules() {
        return (this.workspace && this.workspace.rules) || [];
    }

    get hasRules() {
        return this.rules.length > 0;
    }

    get runs() {
        return (this.workspace && this.workspace.runs) || [];
    }

    get hasRuns() {
        return this.runs.length > 0;
    }

    get ruleCounts() {
        return (this.workspace && this.workspace.ruleCounts) || [];
    }

    get runCounts() {
        return (this.workspace && this.workspace.runCounts) || [];
    }

    get accountOptions() {
        return (this.workspace && this.workspace.accounts) || [];
    }

    get targetAccountOptions() {
        return [{ label: 'Same as source', value: '' }, ...this.accountOptions];
    }

    get departmentOptions() {
        return [{ label: 'None', value: '' }, ...((this.workspace && this.workspace.departments) || [])];
    }

    get costCenterOptions() {
        return [{ label: 'None', value: '' }, ...((this.workspace && this.workspace.costCenters) || [])];
    }

    get approvedRuleOptions() {
        return this.rules.filter((r) => r.status === 'Approved').map((r) => ({ label: `${r.ruleKey} v${r.version} — ${r.name}`, value: r.ruleId }));
    }

    get periodOptions() {
        return (this.workspace && this.workspace.openPeriods) || [];
    }

    get selectedRuleRows() {
        return this.selectedRuleId ? [this.selectedRuleId] : [];
    }

    get selectedRunRows() {
        return this.selectedRunId ? [this.selectedRunId] : [];
    }

    get rule() {
        return this.ruleDetail ? this.ruleDetail.rule : undefined;
    }

    get hasSelectedRule() {
        return Boolean(this.rule);
    }

    get ruleTargets() {
        if (!this.ruleDetail) {
            return [];
        }
        const percent = this.rule.driverType === 'Percent';
        return this.ruleDetail.targets.map((t) => ({ ...t, weight: percent ? t.percentage : t.driverValue }));
    }

    get sourceAccountNames() {
        return this.ruleDetail ? this.ruleDetail.sourceAccounts.map((a) => a.label).join(', ') : '';
    }

    get ruleIsDraft() {
        return this.rule && this.rule.status === 'Draft';
    }

    get ruleIsApproved() {
        return this.rule && this.rule.status === 'Approved';
    }

    get run() {
        return this.runDetail ? this.runDetail.run : undefined;
    }

    get hasSelectedRun() {
        return Boolean(this.run);
    }

    get runLines() {
        return (this.runDetail && this.runDetail.lines) || [];
    }

    get runIsPreview() {
        return this.run && this.run.status === 'Preview';
    }

    get runIsApproved() {
        return this.run && this.run.status === 'Approved';
    }

    get runIsOpen() {
        return this.runIsPreview || this.runIsApproved;
    }

    get weightLabel() {
        return this.ruleForm.driverType === 'Percent' ? 'Percent' : 'Driver value';
    }

    get percentTotal() {
        if (this.ruleForm.driverType !== 'Percent') {
            return null;
        }
        return this.ruleForm.targets.reduce((sum, t) => sum + (Number(t.weight) || 0), 0);
    }

    get percentTotalLabel() {
        const total = this.percentTotal;
        return total === null ? '' : `Total: ${Number(total.toFixed(4))}% (must be 100)`;
    }

    get roundingAccountWarning() {
        return this.ruleForm.roundingPolicy === 'Rounding Account' && this.workspace && !this.workspace.hasRoundingAccount;
    }

    // Disabled flags: permission AND inputs AND not busy. The services re-check everything.
    get newRuleDisabled() {
        return this.isLoading || !this.can.manage;
    }

    get saveRuleDisabled() {
        const f = this.ruleForm;
        const weightsValid = f.targets.length > 0 && f.targets.every((t) => Number(t.weight) > 0);
        const percentValid = f.driverType !== 'Percent' || Math.abs(this.percentTotal - 100) < 0.00001;
        return this.isLoading || !this.can.manage || !f.name.trim() || !f.ruleKey.trim() || !f.effectiveFrom
            || f.sourceAccountIds.length === 0 || !weightsValid || !percentValid;
    }

    get approveRuleDisabled() {
        return this.isLoading || !this.can.approve;
    }

    get reviseRuleDisabled() {
        return this.isLoading || !this.can.manage || !this.reason.trim();
    }

    get previewDisabled() {
        return this.isLoading || !this.can.manage || !this.previewRuleId || !this.previewPeriodId;
    }

    get approveRunDisabled() {
        return this.isLoading || !this.can.approve;
    }

    get postRunDisabled() {
        return this.isLoading || !this.can.manage || !this.can.postJournal;
    }

    get discardRunDisabled() {
        return this.isLoading || !this.can.manage || !this.reason.trim();
    }

    // ------------------------------------------------------------- handlers

    handleRefresh() {
        this.refresh();
    }

    handleReasonChange(event) {
        this.reason = event.detail.value;
    }

    handlePreviewField(event) {
        this[event.target.dataset.field] = event.detail.value;
    }

    handleNewRule() {
        this.ruleForm = emptyForm();
        this.showRuleForm = true;
    }

    handleEditRule() {
        const d = this.ruleDetail;
        const percent = d.rule.driverType === 'Percent';
        this.ruleForm = {
            ruleId: d.rule.ruleId, name: d.rule.name, ruleKey: d.rule.ruleKey, driverType: d.rule.driverType,
            roundingPolicy: d.rule.roundingPolicy, effectiveFrom: d.rule.effectiveFrom || '', effectiveTo: d.rule.effectiveTo || '',
            sourceAccountIds: d.sourceAccounts.map((a) => a.value), sourceDepartmentId: d.sourceDepartmentId || '',
            sourceCostCenterId: d.sourceCostCenterId || '',
            targets: d.targets.map((t) => ({ ...emptyTarget(), targetGlAccountId: t.targetGlAccountId || '',
                targetDepartmentId: t.targetDepartmentId || '', targetCostCenterId: t.targetCostCenterId || '',
                weight: percent ? t.percentage : t.driverValue }))
        };
        this.showRuleForm = true;
    }

    handleCancelForm() {
        this.showRuleForm = false;
    }

    handleFormField(event) {
        this.ruleForm = { ...this.ruleForm, [event.target.dataset.field]: event.detail.value };
    }

    handleTargetField(event) {
        const key = event.target.dataset.key;
        const field = event.target.dataset.field;
        this.ruleForm = { ...this.ruleForm,
            targets: this.ruleForm.targets.map((t) => (t.key === key ? { ...t, [field]: event.detail.value } : t)) };
    }

    handleAddTarget() {
        this.ruleForm = { ...this.ruleForm, targets: [...this.ruleForm.targets, emptyTarget()] };
    }

    handleRemoveTarget(event) {
        const key = event.target.dataset.key;
        this.ruleForm = { ...this.ruleForm, targets: this.ruleForm.targets.filter((t) => t.key !== key) };
    }

    async handleRuleSelection(event) {
        const rows = event.detail.selectedRows || [];
        this.selectedRuleId = rows.length ? rows[0].ruleId : undefined;
        this.reason = '';
        await this.loadDetail(() => (this.selectedRuleId ? getRuleDetail({ ruleId: this.selectedRuleId }) : undefined), 'ruleDetail');
    }

    async handleRunSelection(event) {
        const rows = event.detail.selectedRows || [];
        this.selectedRunId = rows.length ? rows[0].runId : undefined;
        this.reason = '';
        await this.loadDetail(() => (this.selectedRunId ? getRunDetail({ runId: this.selectedRunId }) : undefined), 'runDetail');
    }

    async loadDetail(loader, target) {
        this.isLoading = true;
        try {
            this[target] = await loader();
        } catch (error) {
            this.notifyError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleSaveRule() {
        const f = this.ruleForm;
        const percent = f.driverType === 'Percent';
        const request = {
            ruleId: f.ruleId, companyId: this.companyId, name: f.name.trim(), ruleKey: f.ruleKey.trim(), driverType: f.driverType,
            roundingPolicy: f.roundingPolicy, effectiveFrom: f.effectiveFrom, effectiveTo: f.effectiveTo || null,
            sourceAccountIds: f.sourceAccountIds, sourceDepartmentId: f.sourceDepartmentId || null,
            sourceCostCenterId: f.sourceCostCenterId || null,
            targets: f.targets.map((t) => ({ targetGlAccountId: t.targetGlAccountId || null, targetDepartmentId: t.targetDepartmentId || null,
                targetCostCenterId: t.targetCostCenterId || null, percentage: percent ? Number(t.weight) : null,
                driverValue: percent ? null : Number(t.weight) }))
        };
        return this.runAction(null, async () => {
            this.selectedRuleId = await saveDraft({ request });
            this.showRuleForm = false;
            return 'Allocation rule saved as Draft.';
        });
    }

    handleApproveRule() {
        return this.runAction(`APPROVE_RULE|${this.selectedRuleId}`, async (key) => {
            await approveRule({ ruleId: this.selectedRuleId, requestKey: key });
            return 'Allocation rule approved.';
        });
    }

    handleReviseRule() {
        return this.runAction(`REVISE_RULE|${this.selectedRuleId}`, async (key) => {
            const result = await reviseRule({ ruleId: this.selectedRuleId, reason: this.reason.trim(), requestKey: key });
            this.selectedRuleId = result.ruleId;
            return `Draft version ${result.version} opened.`;
        });
    }

    handleRetireRule() {
        return this.runAction(`RETIRE_RULE|${this.selectedRuleId}`, async (key) => {
            await retireRule({ ruleId: this.selectedRuleId, reason: this.reason.trim(), requestKey: key });
            return 'Allocation rule retired.';
        });
    }

    handlePreview() {
        return this.runAction(`PREVIEW|${this.previewRuleId}|${this.previewPeriodId}`, async (key) => {
            const result = await previewRun({ ruleId: this.previewRuleId, periodId: this.previewPeriodId, requestKey: key });
            this.selectedRunId = result.runId;
            return 'Allocation previewed.';
        });
    }

    handleApproveRun() {
        return this.runAction(`APPROVE_RUN|${this.selectedRunId}`, async (key) => {
            await approveRun({ runId: this.selectedRunId, requestKey: key });
            return 'Allocation run approved.';
        });
    }

    handlePostRun() {
        return this.runAction(`POST_RUN|${this.selectedRunId}`, async (key) => {
            await postRun({ runId: this.selectedRunId, requestKey: key });
            return 'Allocation journal posted.';
        });
    }

    handleDiscardRun() {
        return this.runAction(`DISCARD_RUN|${this.selectedRunId}`, async (key) => {
            await discardRun({ runId: this.selectedRunId, reason: this.reason.trim(), requestKey: key });
            return 'Allocation run discarded.';
        });
    }

    // ------------------------------------------------------------- actions

    requestKey(name) {
        if (!this.requestKeys[name]) {
            this.requestKeys[name] = `G14B|${name}|${Date.now()}`.slice(0, 120);
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
            this.dispatchEvent(new ShowToastEvent({ title: 'Allocations', message, variant: 'success' }));
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
        this.dispatchEvent(new ShowToastEvent({ title: 'Allocations', message, variant: 'error' }));
    }

    reduceError(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        if (error && error.message) {
            return error.message;
        }
        return 'An unexpected Allocation Workspace error occurred.';
    }
}
