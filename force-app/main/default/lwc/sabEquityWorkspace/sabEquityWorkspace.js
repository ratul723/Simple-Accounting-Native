import { LightningElement, api } from 'lwc';
import getWorkspace from '@salesforce/apex/SABEquityWorkspaceController.getWorkspace';
import getFormOptions from '@salesforce/apex/SABEquityWorkspaceController.getFormOptions';
import saveStakeholder from '@salesforce/apex/SABEquityService.saveStakeholder';
import saveClass from '@salesforce/apex/SABEquityService.saveClass';
import saveTransaction from '@salesforce/apex/SABEquityService.saveTransaction';
import approveTransaction from '@salesforce/apex/SABEquityService.approveTransaction';
import cancelTransaction from '@salesforce/apex/SABEquityService.cancelTransaction';
import saveDistribution from '@salesforce/apex/SABDistributionService.saveDraft';
import approveDistribution from '@salesforce/apex/SABDistributionService.approve';
import settleDistribution from '@salesforce/apex/SABDistributionService.settle';
import cancelDistribution from '@salesforce/apex/SABDistributionService.cancel';
import { formatNumber, formatDate, chipClass, plural } from 'c/sabFormat';

const TX_TYPES = ['Issue', 'Transfer', 'Redemption', 'Capital Contribution'];
const DIST_TYPES = ['Dividend', 'Owner Distribution', 'Other'];
const COLORS = ['var(--chart-1)', 'var(--chart-2)', 'var(--chart-3)', 'var(--chart-4)', 'var(--chart-5)'];
const OPEN_DISTRIBUTION = ['Posted Payable', 'Part Settled'];

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

function units(value) {
    return formatNumber(value, 4).replace(/\.?0+$/, '') || '0';
}

/**
 * Capital & equity workspace (G22C): share register with cap table, equity transactions and distributions with
 * settlement, on SABEquityService and SABDistributionService.
 */
export default class SabEquityWorkspace extends LightningElement {
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
    selectedClassId;
    selectedDistributionId;
    busyKey;
    options;
    modal;
    form = {};
    formError;
    saving = false;
    loadSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.options = undefined;
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
                this.ensureSelection();
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

    ensureSelection() {
        const classes = this.data.classes || [];
        if (!classes.some((c) => c.classId === this.selectedClassId)) {
            this.selectedClassId = (classes.find((c) => c.unitsOutstanding > 0) || classes[0] || {}).classId;
        }
        const list = this.data.distributions || [];
        if (!list.some((d) => d.distributionId === this.selectedDistributionId)) {
            this.selectedDistributionId = (list[0] || {}).distributionId;
        }
    }

    // ---------- permissions ----------

    get cur() {
        return (this.data && this.data.currencyCode) || this.currencyCode || '';
    }

    get canManage() {
        return Boolean(this.data && this.data.canManage);
    }

    get manageReason() {
        return this.canManage ? undefined : 'Your role cannot manage equity';
    }

    get manageDisabled() {
        return !this.canManage;
    }

    approveReason(createdByMe, what) {
        if (!this.data.canApprove) {
            return 'Your role cannot approve equity records';
        }
        if (!this.data.canPostJournal) {
            return 'Approving posts a journal and needs journal posting permission';
        }
        if (createdByMe) {
            return `The creator of a ${what} cannot approve it`;
        }
        return undefined;
    }

    get showLoading() {
        return this.isLoading && !this.data && !this.errorMessage;
    }

    // ---------- figures ----------

    get figures() {
        const d = this.data;
        const latest = (d.distributions || []).find((x) => x.status !== 'Draft' && x.status !== 'Cancelled');
        return [
            { key: 'cap', label: 'Share capital', value: formatNumber(d.shareCapital, 0), unit: this.cur,
                sub: `${units(d.unitsOutstanding)} shares in ${plural((d.classes || []).length, 'class', 'classes')}` },
            { key: 'hold', label: 'Shareholders', value: String(d.holderCount || 0), unit: '',
                sub: `${plural((d.stakeholders || []).length, 'stakeholder')} on record` },
            { key: 'dec', label: 'Declared this year', value: formatNumber(d.declaredThisYear, 0), unit: this.cur,
                sub: latest ? `${latest.name}, ${latest.distributionType.toLowerCase()}` : 'Nothing declared yet' },
            { key: 'unpaid', label: 'Unpaid distributions', value: formatNumber(d.unpaid, 0), unit: this.cur,
                sub: d.nextPaymentDue ? `Payable by ${formatDate(d.nextPaymentDue)}` : 'Nothing unpaid' }
        ].map((f) => ({ ...f, hasUnit: Boolean(f.unit) }));
    }

    // ---------- register ----------

    get classTabs() {
        const classes = (this.data && this.data.classes) || [];
        return classes.map((c) => ({
            ...c,
            className: c.classId === this.selectedClassId ? 'on' : '',
            pressed: c.classId === this.selectedClassId ? 'true' : 'false'
        }));
    }

    get hasManyClasses() {
        return this.classTabs.length > 1;
    }

    get selectedClass() {
        return ((this.data && this.data.classes) || []).find((c) => c.classId === this.selectedClassId);
    }

    get hasHoldings() {
        return Boolean(this.selectedClass && this.selectedClass.holdings.length);
    }

    get holdingRows() {
        const c = this.selectedClass;
        return (c ? c.holdings : []).map((h, i) => ({
            ...h,
            swatch: `background:${COLORS[i % COLORS.length]}`,
            unitsText: units(h.units),
            percentText: `${Math.round(h.percent)}%`
        }));
    }

    get donutParts() {
        return this.holdingRows.map((h, i) => ({ value: h.units, color: COLORS[i % COLORS.length], label: h.stakeholderName }));
    }

    get donutValue() {
        return this.selectedClass ? units(this.selectedClass.unitsOutstanding) : '';
    }

    get registerSub() {
        const c = this.selectedClass;
        if (!c) {
            return 'Add a share class to start the register.';
        }
        const par = c.parValue ? `par ${formatNumber(c.parValue, 2)}` : 'no par value';
        return `${c.name} (${c.classCode}), ${par}, posted transactions to today`;
    }

    handleClassSelect(event) {
        this.selectedClassId = event.currentTarget.dataset.id;
    }

    // ---------- transactions ----------

    get transactionRows() {
        return ((this.data && this.data.transactions) || []).map((t) => {
            const isDraft = t.status === 'Draft';
            const approveTitle = isDraft ? this.approveReason(t.createdByMe, 'transaction') : undefined;
            return {
                ...t,
                dateText: formatDate(t.transactionDate),
                party: t.toStakeholderName ? `${t.stakeholderName} to ${t.toStakeholderName}` : t.stakeholderName,
                unitsText: t.units === null || t.units === undefined ? '' : units(t.units),
                valueText: formatNumber(t.value),
                chip: chipClass(t.status),
                isDraft,
                approveDisabled: Boolean(approveTitle) || this.busyKey === `tx-${t.transactionId}`,
                approveTitle,
                cancelDisabled: !this.canManage,
                cancelTitle: this.manageReason
            };
        });
    }

    get hasTransactions() {
        return this.transactionRows.length > 0;
    }

    handleApproveTransaction(event) {
        const transactionId = event.currentTarget.dataset.id;
        this.runAction(`tx-${transactionId}`, () => approveTransaction({ transactionId, requestKey: newKey('EQ-APPROVE', transactionId) }),
            'Equity transaction approved and posted');
    }

    // ---------- distributions ----------

    get distributionOptions() {
        return toOptions(((this.data && this.data.distributions) || []).map((d) => ({
            value: d.distributionId, label: `${d.name}, ${d.distributionType}, ${formatDate(d.declarationDate)}`
        })), this.selectedDistributionId);
    }

    get hasManyDistributions() {
        return this.distributionOptions.length > 1;
    }

    get showDistributionPanel() {
        return Boolean(this.data && this.data.distributionsAvailable);
    }

    get distribution() {
        const d = ((this.data && this.data.distributions) || []).find((x) => x.distributionId === this.selectedDistributionId);
        if (!d) {
            return undefined;
        }
        const remaining = (d.totalAmount || 0) - (d.paidAmount || 0);
        const isDraft = d.status === 'Draft';
        const isOpen = OPEN_DISTRIBUTION.includes(d.status);
        const approveTitle = isDraft ? this.approveReason(d.createdByMe, 'distribution') : undefined;
        const payTitle = !this.canManage
            ? 'Your role cannot settle distributions'
            : !this.data.canPostJournal
              ? 'Paying posts a journal and needs journal posting permission'
              : undefined;
        return {
            ...d,
            title: `${d.name} ${d.distributionType}${d.className ? `, ${d.className}` : ''}`,
            chip: chipClass(d.status),
            dates: `Declared ${formatDate(d.declarationDate)}, record date ${formatDate(d.recordDate)}${d.paymentDueDate ? `, pay by ${formatDate(d.paymentDueDate)}` : ''}`,
            lines: (d.lines || []).map((l) => ({
                ...l,
                entitledText: formatNumber(l.entitledAmount),
                paidText: formatNumber(l.paidAmount),
                chip: chipClass(l.state)
            })),
            hasLines: (d.lines || []).length > 0,
            totalText: formatNumber(d.totalAmount),
            paidTotalText: formatNumber(d.paidAmount),
            declarationPosting: `Dr ${d.sourceAccount || 'source equity account'} / Cr ${d.payableAccount || 'payable account'}`,
            settlementPosting: `Dr ${d.payableAccount || 'payable account'} / Cr ${d.bankAccount || 'bank'} per payment`,
            isDraft,
            isOpen,
            approveDisabled: Boolean(approveTitle) || this.busyKey === `dist-${d.distributionId}`,
            approveTitle,
            payLabel: `Pay remaining ${formatNumber(remaining, 0)}`,
            payDisabled: Boolean(payTitle) || remaining <= 0 || this.busyKey === `dist-${d.distributionId}`,
            payTitle
        };
    }

    handleDistributionSelect(event) {
        this.selectedDistributionId = event.target.value;
    }

    handleApproveDistribution() {
        const distributionId = this.selectedDistributionId;
        this.runAction(`dist-${distributionId}`, () => approveDistribution({ distributionId, requestKey: newKey('DIST-APPROVE', distributionId) }),
            'Distribution approved and declaration posted');
    }

    handlePayRemaining() {
        const distributionId = this.selectedDistributionId;
        this.runAction(`dist-${distributionId}`,
            () => settleDistribution({ distributionId, lineIds: null, paymentDate: todayIso(), requestKey: newKey('DIST-SETTLE', distributionId) }),
            'Distribution payment recorded and posted');
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

    get isStakeholderModal() {
        return this.modal === 'stakeholder';
    }

    get isClassModal() {
        return this.modal === 'class';
    }

    get isTransactionModal() {
        return this.modal === 'transaction';
    }

    get isDistributionModal() {
        return this.modal === 'distribution';
    }

    get isCancelModal() {
        return this.modal === 'cancel';
    }

    get modalHeading() {
        return {
            stakeholder: 'Add stakeholder',
            class: 'Add share class',
            transaction: 'New equity transaction',
            distribution: 'Declare distribution',
            cancel: this.form.heading
        }[this.modal];
    }

    get modalSub() {
        return {
            stakeholder: 'Saving with an existing reference updates that stakeholder.',
            class: 'Capital and premium accounts must be Equity accounts of this company.',
            transaction: 'Saved as a draft. Another user with approval rights approves and posts it.',
            distribution: 'Saved as a draft. Approval splits it by holdings at the record date and posts the declaration.',
            cancel: 'A reason is required and kept in the audit history.'
        }[this.modal];
    }

    get saveLabel() {
        if (this.modal === 'cancel') {
            return 'Cancel record';
        }
        return this.modal === 'transaction' || this.modal === 'distribution' ? 'Save draft' : 'Save';
    }

    get saveClass() {
        return this.modal === 'cancel' ? 'btn danger save' : 'btn primary save';
    }

    get txTypeOptions() {
        return toOptions(TX_TYPES, this.form.transactionType);
    }

    get distTypeOptions() {
        return toOptions(DIST_TYPES, this.form.distributionType);
    }

    get classOptions() {
        return toOptions(((this.data && this.data.classes) || []).filter((c) => c.active).map((c) => ({
            value: c.classId, label: `${c.name} (${c.classCode})`
        })), this.form.classId);
    }

    get stakeholderOptions() {
        return toOptions(((this.data && this.data.stakeholders) || []).filter((s) => s.status !== 'Inactive').map((s) => ({
            value: s.stakeholderId, label: `${s.name} (${s.reference})`
        })), this.form.stakeholderId);
    }

    get toStakeholderOptions() {
        return this.stakeholderOptions.map((o) => ({ ...o, selected: o.value === this.form.toStakeholderId }));
    }

    get accountOptions() {
        return toOptions((this.options && this.options.accounts) || [], this.form.accountId);
    }

    get bankOptions() {
        return toOptions((this.options && this.options.bankAccounts) || [], this.form.bankAccountId);
    }

    glOptions(kinds, selected) {
        return toOptions(((this.options && this.options.glAccounts) || []).filter((a) => kinds.includes(a.kind)), selected);
    }

    get capitalOptions() {
        return this.glOptions(['Equity'], this.form.capitalAccountId);
    }

    get premiumOptions() {
        return this.glOptions(['Equity'], this.form.premiumAccountId);
    }

    get sourceOptions() {
        return this.glOptions(['Equity'], this.form.sourceAccountId);
    }

    get payableOptions() {
        return this.glOptions(['Liability'], this.form.payableAccountId);
    }

    get isTransfer() {
        return this.form.transactionType === 'Transfer';
    }

    get needsUnits() {
        return this.form.transactionType !== 'Capital Contribution';
    }

    get needsCash() {
        return !this.isTransfer;
    }

    async openForm(kind, form) {
        this.formError = undefined;
        try {
            if (kind !== 'cancel' && !this.options) {
                this.options = await getFormOptions({ companyId: this.currentCompanyId });
            }
            this.form = form;
            this.modal = kind;
        } catch (error) {
            this.toast(reduceError(error), 'bad');
        }
    }

    handleAddStakeholder() {
        this.openForm('stakeholder', {});
    }

    handleAddClass() {
        this.openForm('class', { parValue: '1' });
    }

    handleNewTransaction() {
        this.openForm('transaction', { transactionType: 'Issue', transactionDate: todayIso(), classId: this.selectedClassId });
    }

    handleDeclare() {
        this.openForm('distribution', {
            distributionType: 'Dividend', declarationDate: todayIso(), recordDate: todayIso(), classId: this.selectedClassId
        });
    }

    handleCancelTransaction(event) {
        const id = event.currentTarget.dataset.id;
        this.openForm('cancel', { target: 'transaction', recordId: id, heading: 'Cancel equity transaction', requestKey: newKey('EQ-CANCEL', id) });
    }

    handleCancelDistribution() {
        const id = this.selectedDistributionId;
        this.openForm('cancel', { target: 'distribution', recordId: id, heading: 'Cancel distribution', requestKey: newKey('DIST-CANCEL', id) });
    }

    handleField(event) {
        this.form = { ...this.form, [event.target.dataset.field]: event.target.value };
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
        const companyId = this.currentCompanyId;
        if (this.modal === 'stakeholder') {
            await saveStakeholder({ companyId, name: f.name, reference: f.reference, accountId: f.accountId || null });
            return 'Stakeholder saved';
        }
        if (this.modal === 'class') {
            const id = await saveClass({ request: { companyId, name: f.name, classCode: f.classCode, parValue: this.num(f.parValue),
                capitalAccountId: f.capitalAccountId || null, premiumAccountId: f.premiumAccountId || null, rightsMetadata: f.rightsMetadata || null } });
            this.selectedClassId = id;
            return 'Share class saved';
        }
        if (this.modal === 'transaction') {
            await saveTransaction({ request: { companyId, classId: f.classId || null, stakeholderId: f.stakeholderId || null,
                toStakeholderId: this.isTransfer ? f.toStakeholderId || null : null, transactionType: f.transactionType,
                transactionDate: f.transactionDate || null, units: this.needsUnits ? this.num(f.units) : null,
                value: this.isTransfer ? 0 : this.num(f.value), bankAccountId: this.needsCash ? f.bankAccountId || null : null } });
            return 'Equity transaction drafted';
        }
        if (this.modal === 'distribution') {
            const id = await saveDistribution({ request: { companyId, classId: f.classId || null, distributionType: f.distributionType,
                declarationDate: f.declarationDate || null, recordDate: f.recordDate || null, paymentDueDate: f.paymentDueDate || null,
                totalAmount: this.num(f.totalAmount), sourceAccountId: f.sourceAccountId || null, payableAccountId: f.payableAccountId || null,
                bankAccountId: f.bankAccountId || null } });
            this.selectedDistributionId = id;
            return 'Distribution drafted';
        }
        if (f.target === 'transaction') {
            await cancelTransaction({ transactionId: f.recordId, reason: f.reason || '', requestKey: f.requestKey });
            return 'Equity transaction cancelled';
        }
        await cancelDistribution({ distributionId: f.recordId, reason: f.reason || '', requestKey: f.requestKey });
        return 'Distribution cancelled';
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