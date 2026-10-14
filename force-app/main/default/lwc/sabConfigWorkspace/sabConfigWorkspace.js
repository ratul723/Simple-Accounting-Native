import { LightningElement, api } from 'lwc';
import getConfiguration from '@salesforce/apex/SABAdminWorkspaceController.getConfiguration';
import searchUsers from '@salesforce/apex/SABAdminWorkspaceController.searchUsers';
import saveFeature from '@salesforce/apex/SABSetupRecordService.saveFeature';
import saveGrant from '@salesforce/apex/SABAdminWorkspaceService.saveGrant';
import { formatNumber, formatDate, formatDateTime, chipClass } from 'c/sabFormat';
import { reduceError, newKey, todayIso, toast } from 'c/sabMoneyShared';

const FEATURES = {
    PAYROLL: ['Payroll', 'Employees, pay components, payroll runs, posting and net pay settlement.'],
    FIXED_ASSETS: ['Fixed assets', 'Asset register, depreciation schedules, transfers, impairment and disposal.'],
    BUDGETS: ['Budgets', 'Budget versions by account and department with actual against budget.'],
    PURCHASING: ['Purchasing', 'Purchase orders, goods receipts and three-way matching.'],
    PROJECTS: ['Projects', 'Project dimension on journal, invoice and bill lines with project financials.'],
    EQUITY: ['Capital & equity', 'Share register, equity transactions and distributions.'],
    LOANS_INVESTMENTS: ['Investments & loans', 'Loans with schedules and investments with income and revaluation.'],
    GROUP_ACCOUNTING: ['Group accounting', 'Intercompany transactions and group consolidation.']
};
const TONE = { Pass: 'good', Warning: 'warn', Fail: 'bad' };

function sentence(key) {
    const text = String(key || '').replace(/_+/g, ' ').trim().toLowerCase();
    return text ? text.charAt(0).toUpperCase() + text.slice(1) : '';
}

/**
 * Configuration and diagnostics in the Harbourline demo layout (G22H-0): company features, access grants, approval
 * activity, configuration checks and sanitised processing health. Features save through SABSetupRecordService and
 * access grants through SABAdminWorkspaceService.
 */
export default class SabConfigWorkspace extends LightningElement {
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
    activeTab = 'feat';
    busyKey;
    modalOpen = false;
    form = {};
    formError;
    saving = false;
    userResults = [];
    requestKey;
    loadSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
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
            const data = await getConfiguration({ companyId });
            if (sequence === this.loadSequence) {
                this.data = data;
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

    get personaLabel() {
        return (this.persona && this.persona.label) || 'Your';
    }

    get tabs() {
        const d = this.data || {};
        return [
            { id: 'feat', label: 'Features', count: (d.features || []).length },
            { id: 'access', label: 'Access grants', count: (d.grants || []).length },
            { id: 'appr', label: 'Approval activity', count: '' },
            { id: 'checks', label: 'Checks', count: (d.checks || []).length },
            { id: 'diag', label: 'Diagnostics', count: '' }
        ].map((t) => ({ ...t, hasCount: t.count !== '', className: t.id === this.activeTab ? 'tab active' : 'tab', selected: t.id === this.activeTab ? 'true' : 'false' }));
    }

    handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    get isFeat() {
        return this.activeTab === 'feat';
    }

    get isAccess() {
        return this.activeTab === 'access';
    }

    get isAppr() {
        return this.activeTab === 'appr';
    }

    get isChecks() {
        return this.activeTab === 'checks';
    }

    // ---------- features ----------

    get featureCards() {
        const can = Boolean(this.data && this.data.canManageSetup);
        return [...((this.data && this.data.features) || [])]
            .sort((a, b) => (a.featureKey < b.featureKey ? -1 : 1))
            .map((f) => {
                const meta = FEATURES[f.featureKey] || [sentence(f.featureKey), 'Company feature switch.'];
                return {
                    ...f,
                    title: meta[0],
                    note: meta[1],
                    switchClass: f.enabled ? 'switch on' : 'switch',
                    checked: f.enabled ? 'true' : 'false',
                    disabled: !can || this.busyKey === f.featureKey,
                    title2: can ? undefined : `${this.personaLabel} role cannot change features`,
                    chip: chipClass(f.configurationStatus || 'Not Configured', f.configurationStatus === 'Valid' ? 'good' : f.configurationStatus === 'Blocked' ? 'bad' : 'neutral'),
                    statusText: f.enabled ? f.configurationStatus || 'Not Configured' : 'Off'
                };
            });
    }

    async handleFeature(event) {
        const key = event.currentTarget.dataset.key;
        const feature = this.data.features.find((f) => f.featureKey === key);
        if (this.busyKey) {
            return;
        }
        this.busyKey = key;
        try {
            await saveFeature({ request: { featureId: feature.featureId || null, companyId: this.currentCompanyId, featureKey: key, enabled: !feature.enabled,
                configurationStatus: feature.configurationStatus || 'Not Configured' }, requestKey: newKey('FEATURE', key) });
            toast(this, `${(FEATURES[key] || [sentence(key)])[0]} turned ${feature.enabled ? 'off' : 'on'}`);
            await this.load();
        } catch (error) {
            toast(this, reduceError(error), 'bad');
        } finally {
            this.busyKey = undefined;
        }
    }

    // ---------- access ----------

    get grantRows() {
        return ((this.data && this.data.grants) || []).map((g) => ({
            ...g,
            effectiveText: `${formatDate(g.effectiveFrom)}${g.effectiveTo ? ` to ${formatDate(g.effectiveTo)}` : ''}`,
            limitText: g.approvalLimit === null || g.approvalLimit === undefined ? 'No limit' : formatNumber(g.approvalLimit, 0),
            chip: chipClass(g.active ? 'Active' : 'Inactive', g.active ? 'good' : 'neutral'),
            statusText: g.active ? 'Active' : 'Inactive'
        }));
    }

    get canManageAccess() {
        return Boolean(this.data && this.data.canManageAccess);
    }

    get accessDisabled() {
        return !this.canManageAccess;
    }

    get accessTitle() {
        return this.canManageAccess ? undefined : `${this.personaLabel} role cannot grant access`;
    }

    handleNewGrant() {
        this.userResults = [];
        this.openModal({ grantId: null, userId: '', search: '', role: 'Bookkeeper', effectiveFrom: todayIso(), effectiveTo: '', approvalLimit: '', active: true });
    }

    handleGrant(event) {
        if (!this.canManageAccess) {
            return;
        }
        if (event.type === 'keydown') {
            if (event.key !== 'Enter' && event.key !== ' ') {
                return;
            }
            event.preventDefault();
        }
        const g = this.data.grants.find((x) => x.grantId === event.currentTarget.dataset.id);
        this.openModal({ grantId: g.grantId, userId: g.userId, userName: g.userName, role: g.role, effectiveFrom: g.effectiveFrom, effectiveTo: g.effectiveTo || '',
            approvalLimit: g.approvalLimit === null || g.approvalLimit === undefined ? '' : String(g.approvalLimit), active: g.active });
    }

    openModal(form) {
        this.form = form;
        this.formError = undefined;
        this.requestKey = newKey('GRANT', form.grantId);
        this.modalOpen = true;
    }

    get modalHeading() {
        return this.form.grantId ? `Edit access for ${this.form.userName}` : 'Grant access';
    }

    get isNewGrant() {
        return !this.form.grantId;
    }

    get roleOptions() {
        return ((this.data && this.data.roles) || []).map((r) => ({ value: r, label: r, selected: r === this.form.role }));
    }

    get userOptions() {
        return this.userResults.map((u) => ({ ...u, selected: u.value === this.form.userId }));
    }

    get hasUserResults() {
        return this.userResults.length > 0;
    }

    async handleSearch(event) {
        const term = event.target.value;
        this.form = { ...this.form, search: term };
        if (!term || term.length < 2) {
            this.userResults = [];
            return;
        }
        try {
            this.userResults = (await searchUsers({ companyId: this.currentCompanyId, term })) || [];
            if (this.userResults.length && !this.userResults.some((u) => u.value === this.form.userId)) {
                this.form = { ...this.form, userId: this.userResults[0].value };
            }
        } catch (error) {
            this.formError = reduceError(error);
        }
    }

    handleField(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        this.form = { ...this.form, [field]: value };
    }

    handleClose() {
        if (!this.saving) {
            this.modalOpen = false;
        }
    }

    async handleSave() {
        const f = this.form;
        this.saving = true;
        this.formError = undefined;
        try {
            await saveGrant({ request: { grantId: f.grantId, companyId: this.currentCompanyId, userId: f.userId || null, role: f.role, effectiveFrom: f.effectiveFrom || null,
                effectiveTo: f.effectiveTo || null, approvalLimit: f.approvalLimit === '' ? null : Number(f.approvalLimit), active: f.active }, requestKey: this.requestKey });
            toast(this, f.grantId ? 'Access updated' : 'Access granted');
            this.modalOpen = false;
            await this.load();
        } catch (error) {
            this.formError = reduceError(error);
        } finally {
            this.saving = false;
        }
    }

    // ---------- approvals, checks, diagnostics ----------

    get approvalRows() {
        return ((this.data && this.data.approvals) || []).map((a) => ({ ...a, label: sentence(String(a.sourceType || 'Other').replace(/__c$/, '')) }))
            .sort((a, b) => (a.label < b.label ? -1 : 1));
    }

    get hasApprovals() {
        return this.approvalRows.length > 0;
    }

    get checkRows() {
        return ((this.data && this.data.checks) || []).map((c, i) => ({
            ...c,
            key: `c${i}`,
            iconClass: `ic t-${TONE[c.status] || 'neutral'}`,
            icon: c.status === 'Pass' ? 'check' : 'alert',
            chip: chipClass(c.status, TONE[c.status])
        }));
    }

    get checkSummary() {
        const rows = (this.data && this.data.checks) || [];
        const count = (s) => rows.filter((c) => c.status === s).length;
        return `${count('Pass')} passed, ${count('Warning')} warnings, ${count('Fail')} failed`;
    }

    async handleRunChecks() {
        await this.load();
        toast(this, 'Configuration checks completed');
    }

    get runRows() {
        return ((this.data && this.data.runs) || []).map((r) => {
            const start = r.startedAt ? new Date(r.startedAt).getTime() : null;
            const end = r.completedAt ? new Date(r.completedAt).getTime() : null;
            const seconds = start && end ? Math.max(0, Math.round((end - start) / 1000)) : null;
            return {
                ...r,
                startedText: r.startedAt ? formatDateTime(r.startedAt) : '\u2014',
                durationText: seconds === null ? '\u2014' : seconds < 60 ? `${seconds}s` : `${Math.floor(seconds / 60)}m ${seconds % 60}s`,
                processedText: formatNumber(r.processed || 0, 0),
                failureText: r.failures ? `${formatNumber(r.failures, 0)} failed${r.retries ? `, ${formatNumber(r.retries, 0)} retries` : ''}` : '',
                chip: chipClass(r.status, r.status === 'Queued' || r.status === 'Paused' ? 'neutral' : undefined)
            };
        });
    }

    get hasRuns() {
        return this.runRows.length > 0;
    }

    handleRetry() {
        this.load();
    }
}
