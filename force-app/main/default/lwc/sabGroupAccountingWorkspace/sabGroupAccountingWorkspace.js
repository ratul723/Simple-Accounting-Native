import { LightningElement, api } from 'lwc';
import getWorkspace from '@salesforce/apex/SABGroupAccountingWorkspaceController.getWorkspace';
import getCompanyOptions from '@salesforce/apex/SABGroupAccountingWorkspaceController.getCompanyOptions';
import getAccountOptions from '@salesforce/apex/SABGroupAccountingWorkspaceController.getAccountOptions';
import recordIntercompany from '@salesforce/apex/SABIntercompanyService.recordTransaction';
import saveGroup from '@salesforce/apex/SABConsolidationService.saveGroup';
import saveMember from '@salesforce/apex/SABConsolidationService.saveMember';
import calculateRun from '@salesforce/apex/SABConsolidationService.calculate';
import approveRun from '@salesforce/apex/SABConsolidationService.approve';
import publishRun from '@salesforce/apex/SABConsolidationService.publish';
import getTrialBalance from '@salesforce/apex/SABConsolidationService.getTrialBalance';
import { formatNumber, formatDate, formatDateTime, chipClass, plural } from 'c/sabFormat';

const CONTROL_TYPES = ['Subsidiary', 'Joint Venture', 'Associate', 'Other'];

function reduceError(error) {
    if (!error) {
        return 'Something went wrong.';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return (error.body && error.body.message) || error.message || 'Something went wrong.';
}

function newKey(prefix, id) {
    const random = typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    return `${prefix}-${id || 'new'}-${random}`;
}

function toOptions(values, selected) {
    return values.map((v) => {
        const value = typeof v === 'string' ? v : v.value;
        const label = typeof v === 'string' ? v : v.label;
        return { value, label, selected: value === selected };
    });
}

function todayIso() {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/**
 * Group accounting workspace (G22D): intercompany transactions of the selected company and the consolidation groups
 * it belongs to, with members, runs, approval, publishing and the consolidated trial balance, on
 * SABIntercompanyService and SABConsolidationService.
 */
export default class SabGroupAccountingWorkspace extends LightningElement {
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
    activeTab = 'ic';
    busyKey;
    companies;
    ownAccounts;
    otherAccounts = [];
    modal;
    form = {};
    formError;
    saving = false;
    trialBalance;
    trialBalanceOpen = false;
    loadSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.companies = undefined;
            this.ownAccounts = undefined;
            this.load();
        }
    }

    async load() {
        const companyId = this.currentCompanyId;
        const sequence = ++this.loadSequence;
        if (!companyId) {
            this.data = undefined;
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const result = await getWorkspace({ companyId });
            if (sequence === this.loadSequence) {
                this.data = result;
            }
        } catch (error) {
            if (sequence === this.loadSequence) {
                this.data = undefined;
                this.errorMessage = reduceError(error);
            }
        } finally {
            if (sequence === this.loadSequence) {
                this.isLoading = false;
            }
        }
    }

    // ---------- permissions ----------

    get cur() {
        return (this.data && this.data.currencyCode) || this.currencyCode || '';
    }

    get icReason() {
        if (!this.data || !this.data.canManageIntercompany) {
            return 'Your role cannot record intercompany transactions';
        }
        return this.data.canPostJournal ? undefined : 'Recording posts journals and needs journal posting permission';
    }

    get icDisabled() {
        return Boolean(this.icReason);
    }

    get manageReason() {
        return this.data && this.data.canManageConsolidation ? undefined : 'Your role cannot manage consolidation';
    }

    get manageDisabled() {
        return Boolean(this.manageReason);
    }

    get calculateReason() {
        if (this.manageReason) {
            return this.manageReason;
        }
        return this.groups.length ? undefined : 'Add a consolidation group first';
    }

    get calculateDisabled() {
        return Boolean(this.calculateReason);
    }

    get showLoading() {
        return this.isLoading && !this.data && !this.errorMessage;
    }

    // ---------- figures and tabs ----------

    get figures() {
        const d = this.data;
        const runs = this.groups.flatMap((g) => g.runs || []);
        const latest = runs[0];
        return [
            { key: 'r', label: 'Charged to other companies', value: formatNumber(d.receivableTotal, 0), unit: this.cur,
                sub: `${plural(d.transactions.filter((t) => t.direction === 'Receivable').length, 'transaction')}` },
            { key: 'p', label: 'Charged by other companies', value: formatNumber(d.payableTotal, 0), unit: this.cur,
                sub: `${plural(d.transactions.filter((t) => t.direction === 'Payable').length, 'transaction')}` },
            { key: 'v', label: 'Intercompany this year', value: formatNumber(d.volumeThisYear, 0), unit: this.cur,
                sub: d.unmatchedCount ? `${plural(d.unmatchedCount, 'transaction')} not matched` : 'All transactions matched' },
            { key: 'g', label: 'Consolidation groups', value: String(this.groups.length), unit: '',
                sub: latest ? `Latest run ${latest.status.toLowerCase()}, as of ${formatDate(latest.asOfDate)}` : 'No runs yet' }
        ].map((f) => ({ ...f, hasUnit: Boolean(f.unit) }));
    }

    get groups() {
        return (this.data && this.data.groups) || [];
    }

    get isIntercompanyTab() {
        return this.activeTab === 'ic';
    }

    get tabs() {
        return [
            { id: 'ic', label: 'Intercompany', count: ((this.data && this.data.transactions) || []).length },
            { id: 'cons', label: 'Consolidation', count: this.groups.length }
        ].map((t) => ({ ...t, className: t.id === this.activeTab ? 'tab active' : 'tab', selected: t.id === this.activeTab ? 'true' : 'false' }));
    }

    handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    // ---------- intercompany ----------

    get transactionRows() {
        return ((this.data && this.data.transactions) || []).map((t) => ({
            ...t,
            dateText: formatDate(t.transactionDate),
            amountText: formatNumber(t.amount),
            chip: chipClass(t.state, t.state === 'Difference' ? 'bad' : t.state === 'Open' ? 'warn' : undefined)
        }));
    }

    get hasTransactions() {
        return this.transactionRows.length > 0;
    }

    // ---------- consolidation ----------

    get groupPanels() {
        return this.groups.map((g) => ({
            ...g,
            chip: chipClass(g.active ? 'Active' : 'Inactive'),
            statusText: g.active ? 'Active' : 'Inactive',
            meta: `Presentation currency ${g.presentationCurrency}, policy ${g.policyVersion}`,
            memberRows: (g.members || []).map((m) => ({
                ...m,
                ownershipText: m.ownershipPercent === null || m.ownershipPercent === undefined ? '' : `${formatNumber(m.ownershipPercent, 2)}%`,
                fromText: formatDate(m.effectiveFrom),
                toText: m.effectiveTo ? formatDate(m.effectiveTo) : 'Open'
            })),
            runRows: (g.runs || []).map((r) => this.runRow(r)),
            hasRuns: (g.runs || []).length > 0
        }));
    }

    runRow(run) {
        const transitionReason = !this.data.canApproveConsolidation
            ? 'Your role cannot approve or publish consolidation runs'
            : run.calculatedByMe
              ? 'The user who calculated a run cannot approve or publish it'
              : undefined;
        const busy = this.busyKey === `run-${run.runId}`;
        return {
            ...run,
            asOfText: formatDate(run.asOfDate),
            calculatedText: formatDateTime(run.calculatedAt),
            chip: chipClass(run.status, run.status === 'Published' ? 'good' : run.status === 'Calculated' ? 'info' : undefined),
            canApprove: run.status === 'Calculated',
            canPublish: run.status === 'Approved',
            transitionDisabled: Boolean(transitionReason) || busy,
            transitionTitle: transitionReason
        };
    }

    get hasGroups() {
        return this.groups.length > 0;
    }

    get showConsolidation() {
        return Boolean(this.data && this.data.consolidationAvailable);
    }

    handleApproveRun(event) {
        const runId = event.currentTarget.dataset.id;
        this.runAction(`run-${runId}`, () => approveRun({ runId, requestKey: newKey('CONS-APPROVE', runId) }), 'Consolidation run approved');
    }

    handlePublishRun(event) {
        const runId = event.currentTarget.dataset.id;
        this.runAction(`run-${runId}`, () => publishRun({ runId, requestKey: newKey('CONS-PUBLISH', runId) }), 'Consolidation run published');
    }

    async handleTrialBalance(event) {
        const runId = event.currentTarget.dataset.id;
        try {
            this.trialBalance = await getTrialBalance({ runId });
            this.trialBalanceOpen = true;
        } catch (error) {
            this.toast(reduceError(error), 'bad');
        }
    }

    handleCloseTrialBalance() {
        this.trialBalanceOpen = false;
    }

    get tb() {
        const t = this.trialBalance;
        if (!t) {
            return undefined;
        }
        const rows = (t.rows || []).map((r) => ({
            ...r,
            key: r.accountCode,
            memberText: formatNumber(r.memberTotal),
            eliminationText: formatNumber(r.eliminations),
            consolidatedText: formatNumber(r.consolidated)
        }));
        const sum = (field) => (t.rows || []).reduce((s, r) => s + (Number(r[field]) || 0), 0);
        return {
            ...t,
            rows,
            heading: `Consolidated trial balance as of ${formatDate(t.asOfDate)}`,
            sub: `${t.status}, ${t.presentationCurrency}. Debit positive.`,
            companiesText: (t.consolidatedCompanies || []).join(', ') || 'None',
            hasExcluded: (t.excludedMembers || []).length > 0,
            excludedText: (t.excludedMembers || []).join(', '),
            memberTotal: formatNumber(sum('memberTotal')),
            eliminationTotal: formatNumber(sum('eliminations')),
            consolidatedTotal: formatNumber(sum('consolidated'))
        };
    }

    get tbHeading() {
        return this.tb ? this.tb.heading : '';
    }

    get tbSub() {
        return this.tb ? this.tb.sub : '';
    }

    async runAction(busyKey, call, message) {
        if (this.busyKey) {
            return;
        }
        this.busyKey = busyKey;
        try {
            await call();
            this.toast(message);
            await this.load();
        } catch (error) {
            this.toast(reduceError(error), 'bad');
        } finally {
            this.busyKey = undefined;
        }
    }

    // ---------- forms ----------

    get modalOpen() {
        return Boolean(this.modal);
    }

    get isIntercompanyModal() {
        return this.modal === 'ic';
    }

    get isGroupModal() {
        return this.modal === 'group';
    }

    get isMemberModal() {
        return this.modal === 'member';
    }

    get isCalculateModal() {
        return this.modal === 'calculate';
    }

    get modalHeading() {
        return { ic: 'Record Intercompany Transaction', group: 'New consolidation group', member: 'Add group member',
            calculate: 'Calculate consolidation' }[this.modal];
    }

    get modalSub() {
        return {
            ic: 'Posts both sides on the transaction date, so the transaction is matched. Both companies must share the currency.',
            group: 'Members must share the presentation currency and the same account codes.',
            member: this.form.groupName,
            calculate: 'Creates a calculated run with eliminations. Another user approves and publishes it.'
        }[this.modal];
    }

    get saveLabel() {
        return { ic: 'Record and post', group: 'Save group', member: 'Save member', calculate: 'Calculate' }[this.modal];
    }

    get counterpartyOptions() {
        return toOptions((this.companies || []).filter((c) => c.value !== this.currentCompanyId), this.form.toCompanyId);
    }

    get memberCompanyOptions() {
        return toOptions(this.companies || [], this.form.companyId);
    }

    accountOptions(list, kinds, selected) {
        return toOptions((list || []).filter((a) => !kinds || kinds.includes(a.kind)), selected);
    }

    get receivableOptions() {
        return this.accountOptions(this.ownAccounts, ['Asset'], this.form.fromReceivableAccountId);
    }

    get fromCounterOptions() {
        return this.accountOptions(this.ownAccounts, ['Revenue', 'Expense'], this.form.fromCounterAccountId);
    }

    get payableOptions() {
        return this.accountOptions(this.otherAccounts, ['Liability'], this.form.toPayableAccountId);
    }

    get toCounterOptions() {
        return this.accountOptions(this.otherAccounts, ['Expense', 'Revenue'], this.form.toCounterAccountId);
    }

    get controlTypeOptions() {
        return toOptions(CONTROL_TYPES, this.form.controlType);
    }

    get groupOptions() {
        return toOptions(this.groups.map((g) => ({ value: g.groupId, label: g.name })), this.form.groupId);
    }

    async ensureCompanies() {
        if (!this.companies) {
            this.companies = await getCompanyOptions({ companyId: this.currentCompanyId });
        }
    }

    async openForm(kind, form) {
        this.formError = undefined;
        try {
            await this.ensureCompanies();
            if (kind === 'ic' && !this.ownAccounts) {
                this.ownAccounts = await getAccountOptions({ companyId: this.currentCompanyId, accountCompanyId: this.currentCompanyId });
            }
            this.otherAccounts = [];
            this.form = form;
            this.modal = kind;
        } catch (error) {
            this.toast(reduceError(error), 'bad');
        }
    }

    handleRecordIntercompany() {
        this.openForm('ic', { transactionDate: todayIso(), requestKey: newKey('IC', this.currentCompanyId) });
    }

    handleNewGroup() {
        this.openForm('group', { presentationCurrency: this.cur, policyVersion: 'v1' });
    }

    handleAddMember(event) {
        const group = this.groups.find((g) => g.groupId === event.currentTarget.dataset.id);
        this.openForm('member', { groupId: group.groupId, groupName: group.name, controlType: 'Subsidiary', ownershipPercent: '100',
            effectiveFrom: todayIso(), mappingVersion: 'v1' });
    }

    handleCalculate() {
        this.openForm('calculate', { groupId: (this.groups[0] || {}).groupId, asOfDate: todayIso(), requestKey: newKey('CONS-CALC', this.currentCompanyId) });
    }

    async handleField(event) {
        const field = event.target.dataset.field;
        const value = event.target.value;
        this.form = { ...this.form, [field]: value };
        if (field === 'toCompanyId') {
            this.otherAccounts = [];
            this.form = { ...this.form, toPayableAccountId: '', toCounterAccountId: '' };
            if (value) {
                try {
                    this.otherAccounts = await getAccountOptions({ companyId: this.currentCompanyId, accountCompanyId: value });
                } catch (error) {
                    this.formError = reduceError(error);
                }
            }
        }
    }

    handleCloseModal() {
        if (!this.saving) {
            this.modal = undefined;
            this.formError = undefined;
        }
    }

    num(value) {
        return value === '' || value === null || value === undefined ? null : Number(value);
    }

    async submit() {
        const f = this.form;
        if (this.modal === 'ic') {
            await recordIntercompany({
                request: { fromCompanyId: this.currentCompanyId, toCompanyId: f.toCompanyId || null, transactionDate: f.transactionDate || null,
                    amount: this.num(f.amount), description: f.description || null, fromReceivableAccountId: f.fromReceivableAccountId || null,
                    fromCounterAccountId: f.fromCounterAccountId || null, toPayableAccountId: f.toPayableAccountId || null,
                    toCounterAccountId: f.toCounterAccountId || null },
                requestKey: f.requestKey
            });
            this.activeTab = 'ic';
            return 'Intercompany transaction recorded and posted in both companies';
        }
        if (this.modal === 'group') {
            await saveGroup({ groupId: null, name: f.name, presentationCurrency: f.presentationCurrency, policyVersion: f.policyVersion });
            this.activeTab = 'cons';
            return 'Consolidation group saved';
        }
        if (this.modal === 'member') {
            await saveMember({ request: { groupId: f.groupId, companyId: f.companyId || null, controlType: f.controlType,
                ownershipPercent: this.num(f.ownershipPercent), effectiveFrom: f.effectiveFrom || null, effectiveTo: f.effectiveTo || null,
                mappingVersion: f.mappingVersion } });
            return 'Group member saved';
        }
        const result = await calculateRun({ groupId: f.groupId || null, asOfDate: f.asOfDate || null, requestKey: f.requestKey });
        this.activeTab = 'cons';
        return `Consolidation calculated with ${plural((result && result.eliminationCount) || 0, 'elimination')}`;
    }

    async handleSave() {
        if (this.saving) {
            return;
        }
        this.saving = true;
        this.formError = undefined;
        try {
            const message = await this.submit();
            this.modal = undefined;
            this.toast(message);
            await this.load();
        } catch (error) {
            this.formError = reduceError(error);
        } finally {
            this.saving = false;
        }
    }

    toast(message, tone) {
        this.dispatchEvent(new CustomEvent('sabtoast', { detail: { message, tone }, bubbles: true, composed: true }));
    }

    handleRetry() {
        this.load();
    }
}