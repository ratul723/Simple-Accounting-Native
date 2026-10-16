import { LightningElement, api } from 'lwc';
import getWorkspace from '@salesforce/apex/SABAllocationWorkspaceController.getWorkspace';
import getRuleDetail from '@salesforce/apex/SABAllocationWorkspaceController.getRuleDetail';
import getRunDetail from '@salesforce/apex/SABAllocationWorkspaceController.getRunDetail';
import saveRule from '@salesforce/apex/SABAllocationRuleService.saveDraft';
import approveRule from '@salesforce/apex/SABAllocationRuleService.approve';
import reviseRule from '@salesforce/apex/SABAllocationRuleService.revise';
import retireRule from '@salesforce/apex/SABAllocationRuleService.retire';
import previewRun from '@salesforce/apex/SABAllocationRunService.preview';
import approveRun from '@salesforce/apex/SABAllocationRunService.approve';
import postRun from '@salesforce/apex/SABAllocationRunService.post';
import discardRun from '@salesforce/apex/SABAllocationRunService.discard';
import { formatNumber, formatDate, chipClass, plural } from 'c/sabFormat';
import { reduceError, newKey, todayIso, toast } from 'c/sabMoneyShared';

const DRIVERS = ['Percent', 'Manual Driver', 'Supported Metric'];
const ROUNDING = ['Largest Remainder', 'Last Target', 'Rounding Account'];

let targetSequence = 0;
const blankTarget = () => ({ key: `t${++targetSequence}`, targetGlAccountId: '', targetDepartmentId: '', targetCostCenterId: '', percentage: '', driverValue: '' });

/**
 * Allocations in the Harbourline demo layout (G22G-7b): allocation rules with their source and targets, and allocation
 * runs from preview to approval and posting, on SABAllocationRuleService and SABAllocationRunService, unchanged.
 */
export default class SabAllocationsWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api recordId;
    @api periodKey;

    data;
    errorMessage;
    isLoading = false;
    activeTab = 'rules';
    drawer;
    ruleDetail;
    runDetail;
    detailError;
    busy = false;
    modal;
    form = {};
    targets = [];
    formError;
    requestKeys = {};
    loadSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.drawer = undefined;
            this.load();
        }
    }

    async load() {
        const companyId = this.currentCompanyId;
        const sequence = ++this.loadSequence;
        if (!companyId) {
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const data = await getWorkspace({ companyId });
            if (sequence !== this.loadSequence) {
                return;
            }
            this.data = data;
            if (this.drawer) {
                await this.openDrawer(this.drawer.kind, this.drawer.id);
            }
        } catch (error) {
            if (sequence === this.loadSequence) {
                this.errorMessage = reduceError(error);
            }
        } finally {
            if (sequence === this.loadSequence) {
                this.isLoading = false;
            }
        }
    }

    get showLoading() {
        return this.isLoading && !this.data && !this.errorMessage;
    }

    get cur() {
        return (this.data && this.data.functionalCurrency) || this.currencyCode || '';
    }

    get can() {
        return (this.data && this.data.capabilities) || {};
    }

    get personaLabel() {
        return (this.persona && this.persona.label) || 'Your';
    }

    reason(allowed, action) {
        return allowed ? undefined : `${this.personaLabel} role cannot ${action}`;
    }

    get rules() {
        return (this.data && this.data.rules) || [];
    }

    get runs() {
        return (this.data && this.data.runs) || [];
    }

    // ---------- figures and tabs ----------

    get figures() {
        const year = String(new Date().getFullYear());
        const posted = this.runs.filter((r) => r.status === 'Posted');
        return [
            { key: 'a', label: 'Active rules', value: String(this.rules.filter((r) => r.status === 'Approved').length), sub: `${this.rules.filter((r) => r.status === 'Draft').length} in draft` },
            { key: 'p', label: 'Runs to approve', value: String(this.runs.filter((r) => r.status === 'Preview').length), sub: 'Previewed, not yet approved' },
            { key: 'r', label: 'Ready to post', value: String(this.runs.filter((r) => r.status === 'Approved').length), sub: 'Approved runs' },
            { key: 't', label: 'Allocated', value: formatNumber(posted.reduce((s, r) => s + (Number(r.sourceAmount) || 0), 0), 0), unit: this.cur,
                sub: `${plural(posted.filter((r) => String(r.periodName || '').includes(year)).length || posted.length, 'posted run')}` }
        ].map((f) => ({ ...f, hasUnit: Boolean(f.unit) }));
    }

    get roundingWarning() {
        return this.data && this.data.hasRoundingAccount === false;
    }

    get tabs() {
        return [
            { id: 'rules', label: 'Rules', count: this.rules.length },
            { id: 'runs', label: 'Runs', count: this.runs.length }
        ].map((t) => ({ ...t, className: t.id === this.activeTab ? 'tab active' : 'tab', selected: t.id === this.activeTab ? 'true' : 'false' }));
    }

    handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    get isRules() {
        return this.activeTab === 'rules';
    }

    get ruleRows() {
        return this.rules.map((r) => ({
            ...r,
            effectiveText: `${formatDate(r.effectiveFrom)}${r.effectiveTo ? ` to ${formatDate(r.effectiveTo)}` : ''}`,
            chip: chipClass(r.status, r.status === 'Draft' ? 'neutral' : r.status === 'Retired' ? 'neutral' : undefined)
        }));
    }

    get runRows() {
        return this.runs.map((r) => ({
            ...r,
            amountText: formatNumber(r.sourceAmount),
            chip: chipClass(r.status, r.status === 'Preview' ? 'info' : r.status === 'Failed' ? 'bad' : undefined)
        }));
    }

    get hasRules() {
        return this.ruleRows.length > 0;
    }

    get hasRuns() {
        return this.runRows.length > 0;
    }

    get newDisabled() {
        return !this.can.manage;
    }

    get newTitle() {
        return this.reason(this.can.manage, 'manage allocation rules');
    }

    // ---------- drawer ----------

    keyed(event) {
        if (event.type !== 'keydown') {
            return true;
        }
        if (event.key !== 'Enter' && event.key !== ' ') {
            return false;
        }
        event.preventDefault();
        return true;
    }

    handleRule(event) {
        if (this.keyed(event)) {
            this.openDrawer('rule', event.currentTarget.dataset.id);
        }
    }

    handleRun(event) {
        if (this.keyed(event)) {
            this.openDrawer('run', event.currentTarget.dataset.id);
        }
    }

    async openDrawer(kind, id) {
        this.drawer = { kind, id };
        this.detailError = undefined;
        try {
            if (kind === 'rule') {
                this.ruleDetail = await getRuleDetail({ ruleId: id });
            } else {
                this.runDetail = await getRunDetail({ runId: id });
            }
        } catch (error) {
            this.detailError = reduceError(error);
        }
    }

    handleCloseDrawer() {
        this.drawer = undefined;
    }

    get drawerOpen() {
        return Boolean(this.drawer);
    }

    get isRuleDrawer() {
        return Boolean(this.drawer && this.drawer.kind === 'rule' && this.ruleDetail && this.ruleDetail.rule && this.ruleDetail.rule.ruleId === this.drawer.id);
    }

    get isRunDrawer() {
        return Boolean(this.drawer && this.drawer.kind === 'run' && this.runDetail && this.runDetail.run && this.runDetail.run.runId === this.drawer.id);
    }

    get drawerHeading() {
        if (this.isRuleDrawer) {
            return this.ruleDetail.rule.name;
        }
        return this.isRunDrawer ? this.runDetail.run.name : '';
    }

    get drawerSub() {
        if (this.isRuleDrawer) {
            const r = this.ruleDetail.rule;
            return `${r.ruleKey} v${r.version}, ${r.driverType}, ${r.status}`;
        }
        if (this.isRunDrawer) {
            const r = this.runDetail.run;
            return `${r.ruleKey} v${r.ruleVersion}, ${r.periodName}, ${r.status}`;
        }
        return '';
    }

    get ruleView() {
        const d = this.ruleDetail;
        const r = d.rule;
        const percent = r.driverType === 'Percent';
        return {
            sources: (d.sourceAccounts || []).map((a) => ({ key: a.value, label: a.label })),
            facts: [['Source department', d.sourceDepartmentName || 'Any'], ['Source cost center', d.sourceCostCenterName || 'Any'], ['Driver', r.driverType],
                ['Rounding', r.roundingPolicy], ['Effective', `${formatDate(r.effectiveFrom)}${r.effectiveTo ? ` to ${formatDate(r.effectiveTo)}` : ''}`]]
                .map(([label, value]) => ({ key: label, valueKey: `${label}-v`, label, value })),
            weightLabel: percent ? 'Share' : 'Driver',
            targets: (d.targets || []).map((t, i) => ({ ...t, key: `t${i}`, dimension: [t.targetDepartmentName, t.targetCostCenterName].filter(Boolean).join(', ') || '\u2014',
                weightText: percent ? `${formatNumber(t.percentage)}%` : formatNumber(t.driverValue) })),
            isDraft: r.status === 'Draft',
            isApproved: r.status === 'Approved',
            manageDisabled: this.busy || !this.can.manage,
            manageTitle: this.reason(this.can.manage, 'manage allocation rules'),
            canManage: Boolean(this.can.manage),
            approveDisabled: this.busy || !this.can.approve,
            approveTitle: this.reason(this.can.approve, 'approve allocation rules')
        };
    }

    get runView() {
        const d = this.runDetail;
        const r = d.run;
        return {
            lines: (d.lines || []).map((l) => ({ ...l, dimension: [l.targetDepartmentName, l.targetCostCenterName].filter(Boolean).join(', ') || '\u2014', amountText: formatNumber(l.amount) })),
            hasLines: (d.lines || []).length > 0,
            totalText: formatNumber((d.lines || []).reduce((s, l) => s + (Number(l.amount) || 0), 0)),
            sourceText: `${formatNumber(r.sourceAmount)} ${this.cur}`,
            isPreview: r.status === 'Preview',
            isApproved: r.status === 'Approved',
            isPosted: r.status === 'Posted',
            journalName: r.journalName,
            journalId: r.journalEntryId,
            canOpenJournal: Boolean(r.journalEntryId) && Array.isArray(this.visibleWorkspaces) && this.visibleWorkspaces.includes('journal'),
            approveDisabled: this.busy || !this.can.approve,
            approveTitle: this.reason(this.can.approve, 'approve allocation runs'),
            manageDisabled: this.busy || !this.can.manage,
            manageTitle: this.reason(this.can.manage, 'manage allocation runs'),
            postDisabled: this.busy || !this.can.postJournal,
            postTitle: this.reason(this.can.postJournal, 'post journals')
        };
    }

    handleOpenJournal() {
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'journal', recordId: this.runDetail.run.journalEntryId }, bubbles: true, composed: true }));
    }

    // ---------- actions ----------

    keyFor(action, recordId) {
        const name = `${action}|${recordId}`;
        if (!this.requestKeys[name]) {
            this.requestKeys = { ...this.requestKeys, [name]: newKey(`ALLOC-${action}`, recordId) };
        }
        return this.requestKeys[name];
    }

    async execute(action, recordId, call, message, after) {
        const name = `${action}|${recordId}`;
        this.busy = true;
        try {
            const result = await call(this.keyFor(action, recordId));
            const keys = { ...this.requestKeys };
            delete keys[name];
            this.requestKeys = keys;
            if (after) {
                after(result);
            }
            toast(this, message);
            await this.load();
            return true;
        } catch (error) {
            toast(this, reduceError(error), 'bad');
            return false;
        } finally {
            this.busy = false;
        }
    }

    handleApproveRule() {
        const ruleId = this.drawer.id;
        this.execute('RULE-APPROVE', ruleId, (requestKey) => approveRule({ ruleId, requestKey }), 'Allocation rule approved');
    }

    handleApproveRun() {
        const runId = this.drawer.id;
        this.execute('RUN-APPROVE', runId, (requestKey) => approveRun({ runId, requestKey }), 'Allocation run approved');
    }

    handlePostRun() {
        const runId = this.drawer.id;
        this.execute('RUN-POST', runId, (requestKey) => postRun({ runId, requestKey }), 'Allocation posted');
    }

    // ---------- modals ----------

    openModal(kind, form) {
        this.form = form;
        this.formError = undefined;
        this.modal = kind;
    }

    handleNewRule() {
        this.targets = [blankTarget(), blankTarget()];
        this.openModal('rule', { ruleId: null, name: '', ruleKey: '', driverType: 'Percent', roundingPolicy: 'Largest Remainder', effectiveFrom: todayIso(),
            effectiveTo: '', sourceAccountIds: [], sourceDepartmentId: '', sourceCostCenterId: '' });
    }

    handleEditRule() {
        const d = this.ruleDetail;
        const r = d.rule;
        this.targets = (d.targets || []).map((t) => ({ ...blankTarget(), targetGlAccountId: t.targetGlAccountId || '', targetDepartmentId: t.targetDepartmentId || '',
            targetCostCenterId: t.targetCostCenterId || '', percentage: t.percentage === null || t.percentage === undefined ? '' : String(t.percentage),
            driverValue: t.driverValue === null || t.driverValue === undefined ? '' : String(t.driverValue) }));
        this.openModal('rule', { ruleId: r.ruleId, name: r.name, ruleKey: r.ruleKey, driverType: r.driverType, roundingPolicy: r.roundingPolicy,
            effectiveFrom: r.effectiveFrom, effectiveTo: r.effectiveTo || '', sourceAccountIds: (d.sourceAccounts || []).map((a) => a.value),
            sourceDepartmentId: d.sourceDepartmentId || '', sourceCostCenterId: d.sourceCostCenterId || '' });
    }

    handlePreview() {
        const open = (this.data && this.data.openPeriods) || [];
        this.openModal('preview', { periodId: (open[open.length - 1] || {}).value || '' });
    }

    handleRevise() {
        this.openModal('revise', { reason: '' });
    }

    handleRetire() {
        this.openModal('retire', { reason: '' });
    }

    handleDiscard() {
        this.openModal('discard', { reason: '' });
    }

    get modalOpen() {
        return Boolean(this.modal);
    }

    get modalHeading() {
        return { rule: this.form.ruleId ? 'Edit allocation rule' : 'New allocation rule', preview: 'Run allocation', revise: 'New rule version',
            retire: 'Retire rule', discard: 'Discard run' }[this.modal];
    }

    get modalSub() {
        return {
            rule: 'Choose the source balances and where they are spread. Percent targets must total 100.',
            preview: 'Calculates the allocation for the period. Nothing posts until the run is approved and posted.',
            revise: 'Creates a draft version from this approved rule. A reason is required.',
            retire: 'Stops the rule from being used for new runs. A reason is required.',
            discard: 'Discards this run so it cannot be posted. A reason is required.'
        }[this.modal];
    }

    get saveLabel() {
        return { rule: 'Save draft', preview: 'Preview run', revise: 'Create version', retire: 'Retire', discard: 'Discard' }[this.modal];
    }

    get saveClass() {
        return this.modal === 'retire' || this.modal === 'discard' ? 'btn danger sab-modal-save' : 'btn primary sab-modal-save';
    }

    get isRuleModal() {
        return this.modal === 'rule';
    }

    get isPreviewModal() {
        return this.modal === 'preview';
    }

    get isReasonModal() {
        return ['revise', 'retire', 'discard'].includes(this.modal);
    }

    choices(list, selected) {
        return (list || []).map((o) => ({ value: o.value, label: o.label, selected: Array.isArray(selected) ? selected.includes(o.value) : o.value === selected }));
    }

    get driverOptions() {
        return DRIVERS.map((v) => ({ value: v, label: v, selected: v === this.form.driverType }));
    }

    get roundingOptions() {
        return ROUNDING.map((v) => ({ value: v, label: v, selected: v === this.form.roundingPolicy }));
    }

    get sourceAccountOptions() {
        return this.choices(this.data && this.data.accounts, this.form.sourceAccountIds);
    }

    get departmentOptions() {
        return this.choices(this.data && this.data.departments, this.form.sourceDepartmentId);
    }

    get costCenterOptions() {
        return this.choices(this.data && this.data.costCenters, this.form.sourceCostCenterId);
    }

    get periodOptions() {
        return this.choices(this.data && this.data.openPeriods, this.form.periodId);
    }

    get isPercent() {
        return this.form.driverType === 'Percent';
    }

    get targetRows() {
        return this.targets.map((t, i) => ({
            ...t,
            index: i,
            accountOptions: this.choices(this.data.accounts, t.targetGlAccountId),
            departmentOptions: this.choices(this.data.departments, t.targetDepartmentId),
            costCenterOptions: this.choices(this.data.costCenters, t.targetCostCenterId),
            weight: this.isPercent ? t.percentage : t.driverValue,
            weightField: this.isPercent ? 'percentage' : 'driverValue'
        }));
    }

    get weightLabel() {
        return this.isPercent ? 'Share %' : 'Driver';
    }

    get targetTotal() {
        const total = this.targets.reduce((s, t) => s + (Number(this.isPercent ? t.percentage : t.driverValue) || 0), 0);
        return this.isPercent ? `${formatNumber(total)}%` : formatNumber(total);
    }

    get targetTotalClass() {
        if (!this.isPercent) {
            return 'n num';
        }
        const total = this.targets.reduce((s, t) => s + (Number(t.percentage) || 0), 0);
        return Math.round(total * 100) === 10000 ? 'n num up' : 'n num down';
    }

    handleField(event) {
        const field = event.target.dataset.field;
        if (field === 'sourceAccountIds') {
            this.form = { ...this.form, sourceAccountIds: Array.from(event.target.selectedOptions || []).map((o) => o.value) };
            return;
        }
        this.form = { ...this.form, [field]: event.target.value };
    }

    handleTargetField(event) {
        const index = Number(event.target.dataset.index);
        const field = event.target.dataset.field;
        this.targets = this.targets.map((t, i) => (i === index ? { ...t, [field]: event.target.value } : t));
    }

    handleAddTarget() {
        this.targets = [...this.targets, blankTarget()];
    }

    handleRemoveTarget(event) {
        const index = Number(event.currentTarget.dataset.index);
        this.targets = this.targets.filter((t, i) => i !== index);
    }

    handleCloseModal() {
        if (!this.busy) {
            this.modal = undefined;
        }
    }

    num(v) {
        return v === '' || v === undefined || v === null ? null : Number(v);
    }

    async handleSave() {
        const f = this.form;
        if (this.isReasonModal && !String(f.reason || '').trim()) {
            this.formError = 'A reason is required.';
            return;
        }
        let ok;
        if (this.modal === 'rule') {
            this.busy = true;
            try {
                const ruleId = await saveRule({ request: {
                    ruleId: f.ruleId, companyId: this.currentCompanyId, name: f.name, ruleKey: f.ruleKey, driverType: f.driverType, roundingPolicy: f.roundingPolicy,
                    effectiveFrom: f.effectiveFrom || null, effectiveTo: f.effectiveTo || null, sourceAccountIds: f.sourceAccountIds,
                    sourceDepartmentId: f.sourceDepartmentId || null, sourceCostCenterId: f.sourceCostCenterId || null,
                    targets: this.targets.filter((t) => t.targetGlAccountId).map((t) => ({ targetGlAccountId: t.targetGlAccountId, targetDepartmentId: t.targetDepartmentId || null,
                        targetCostCenterId: t.targetCostCenterId || null, percentage: this.isPercent ? this.num(t.percentage) : null,
                        driverValue: this.isPercent ? null : this.num(t.driverValue) }))
                } });
                toast(this, 'Allocation rule saved as draft');
                this.modal = undefined;
                this.drawer = { kind: 'rule', id: ruleId };
                this.activeTab = 'rules';
                ok = true;
            } catch (error) {
                this.formError = reduceError(error);
            } finally {
                this.busy = false;
            }
            if (ok) {
                await this.load();
            }
            return;
        }
        const id = this.drawer.id;
        const reasonText = String(f.reason || '').trim();
        if (this.modal === 'preview') {
            ok = await this.execute('PREVIEW', `${id}|${f.periodId}`, (requestKey) => previewRun({ ruleId: id, periodId: f.periodId || null, requestKey }),
                'Allocation previewed', (result) => {
                    this.drawer = { kind: 'run', id: result.runId };
                    this.activeTab = 'runs';
                });
        } else if (this.modal === 'revise') {
            ok = await this.execute('RULE-REVISE', id, (requestKey) => reviseRule({ ruleId: id, reason: reasonText, requestKey }), 'New draft version created',
                (result) => {
                    this.drawer = { kind: 'rule', id: result.ruleId };
                });
        } else if (this.modal === 'retire') {
            ok = await this.execute('RULE-RETIRE', id, (requestKey) => retireRule({ ruleId: id, reason: reasonText, requestKey }), 'Allocation rule retired');
        } else {
            ok = await this.execute('RUN-DISCARD', id, (requestKey) => discardRun({ runId: id, reason: reasonText, requestKey }), 'Allocation run discarded');
        }
        if (ok) {
            this.modal = undefined;
        }
    }

    handleRetry() {
        this.load();
    }
}