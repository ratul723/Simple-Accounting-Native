import { LightningElement, api } from 'lwc';
import getSummary from '@salesforce/apex/SABPayrollSummaryController.getSummary';
import getWorkspace from '@salesforce/apex/SABPayrollWorkspaceController.getWorkspace';
import getRunDetail from '@salesforce/apex/SABPayrollWorkspaceController.getRunDetail';
import getHrQueue from '@salesforce/apex/SABPayrollWorkspaceController.getHrQueue';
import createDraftForWorkspace from '@salesforce/apex/SABPayrollCalculationService.createDraftForWorkspace';
import calculateRun from '@salesforce/apex/SABPayrollCalculationService.calculate';
import submitRun from '@salesforce/apex/SABPayrollReviewService.submit';
import approveRun from '@salesforce/apex/SABPayrollReviewService.approve';
import cancelRun from '@salesforce/apex/SABPayrollReviewService.cancel';
import postRun from '@salesforce/apex/SABPayrollPostingService.post';
import preparePayment from '@salesforce/apex/SABPayrollSettlementService.preparePayment';
import authorizePayment from '@salesforce/apex/SABPayrollSettlementService.authorizePayment';
import submitPayment from '@salesforce/apex/SABPayrollSettlementService.submitPayment';
import recordPaymentSucceeded from '@salesforce/apex/SABPayrollSettlementService.recordPaymentSucceeded';
import recordPaymentFailed from '@salesforce/apex/SABPayrollSettlementService.recordPaymentFailed';
import recordLineReturn from '@salesforce/apex/SABPayrollSettlementService.recordLineReturn';
import approveAssignment from '@salesforce/apex/SABEmployeeCompensationService.approveAssignment';
import approveBenefitAward from '@salesforce/apex/SABEmployeeCompensationService.approveBenefitAward';
import cancelBenefitAward from '@salesforce/apex/SABEmployeeCompensationService.cancelBenefitAward';
import { formatNumber, formatDate, formatDateTime, chipClass, plural } from 'c/sabFormat';
import { reduceError, newKey, todayIso, hsteps, toast } from 'c/sabMoneyShared';

const STATES = ['Draft', 'Calculated', 'Submitted', 'Approved', 'Posted', 'Settled'];
const VIEWS = [
    { id: 'prep', label: 'HR preparation' },
    { id: 'post', label: 'Finance posting' },
    { id: 'settle', label: 'Treasury settlement' }
];
const MASK = '\u2022\u2022\u2022\u2022\u2022\u2022';

/**
 * People and payroll in the Harbourline demo layout (G22G-5): HR preparation, finance posting and treasury settlement
 * views of a payroll run with the run stepper, on SABPayrollWorkspaceController and the payroll services (unchanged)
 * plus the aggregate SABPayrollSummaryController for users without payroll detail access.
 */
export default class SabPeopleWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api recordId;
    @api periodKey;

    summary;
    workspace;
    detail;
    queue;
    errorMessage;
    isLoading = false;
    view;
    selectedRunId;
    busy = false;
    requestKeys = {};
    modal;
    form = {};
    formError;
    loadSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.selectedRunId = undefined;
            this.load();
        }
    }

    connectedCallback() {
        const key = this.persona && this.persona.key;
        this.view = key === 'HR' ? 'prep' : key === 'TREASURY' ? 'settle' : 'post';
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
            const summary = await getSummary({ companyId, runId: this.selectedRunId || null });
            if (sequence !== this.loadSequence) {
                return;
            }
            this.summary = summary;
            this.selectedRunId = summary.selectedRunId;
            if (summary.canViewDetail) {
                const [workspace, detail, queue] = await Promise.all([
                    getWorkspace({ companyId }),
                    summary.selectedRunId ? getRunDetail({ runId: summary.selectedRunId }) : Promise.resolve(undefined),
                    getHrQueue({ companyId }).catch(() => undefined)
                ]);
                if (sequence === this.loadSequence) {
                    this.workspace = workspace;
                    this.detail = detail;
                    this.queue = queue;
                }
            } else {
                this.workspace = undefined;
                this.detail = undefined;
                this.queue = undefined;
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

    // ---------- state ----------

    get showLoading() {
        return this.isLoading && !this.summary && !this.errorMessage;
    }

    get cur() {
        return (this.summary && this.summary.currencyCode) || this.currencyCode || '';
    }

    get detailAccess() {
        return Boolean(this.summary && this.summary.canViewDetail);
    }

    get can() {
        return (this.workspace && this.workspace.capabilities) || {};
    }

    get isDirector() {
        return Boolean(this.persona && this.persona.key === 'DIRECTOR');
    }

    get restrictedBanner() {
        return !this.detailAccess && !this.isDirector;
    }

    get personaLabel() {
        return (this.persona && this.persona.label) || 'Your';
    }

    get run() {
        return ((this.summary && this.summary.runs) || []).find((r) => r.runId === this.selectedRunId);
    }

    get hasRun() {
        return Boolean(this.run);
    }

    get runOptions() {
        return ((this.summary && this.summary.runs) || []).map((r) => ({
            value: r.runId,
            label: `${r.name}, ${formatDate(r.periodStart)} to ${formatDate(r.periodEnd)}, ${r.state.toLowerCase()}`,
            selected: r.runId === this.selectedRunId
        }));
    }

    async handleRun(event) {
        this.selectedRunId = event.target.value;
        await this.load();
    }

    get viewButtons() {
        return VIEWS.map((v) => ({ ...v, className: v.id === this.view ? 'on' : '', pressed: v.id === this.view ? 'true' : 'false' }));
    }

    handleView(event) {
        this.view = event.currentTarget.dataset.id;
    }

    get isPrep() {
        return this.view === 'prep';
    }

    get isPost() {
        return this.view === 'post';
    }

    get isSettle() {
        return this.view === 'settle';
    }

    get runCard() {
        const r = this.run;
        const index = STATES.indexOf(r.state);
        return {
            title: r.name,
            sub: `${formatDate(r.periodStart)} to ${formatDate(r.periodEnd)}${r.accountingDate ? `, accounting date ${formatDate(r.accountingDate)}` : ''}`,
            chip: chipClass(r.state),
            steps: hsteps(STATES, r.state === 'Settled' ? 6 : index < 0 ? 0 : index + 1),
            cancelled: r.state === 'Cancelled'
        };
    }

    get figures() {
        const r = this.run;
        return [
            { key: 'e', label: 'Employees paid', value: String(r.employeeCount || 0), unit: '', sub: `${plural(r.employeeCount || 0, 'payroll line')}` },
            { key: 'g', label: 'Gross pay', value: formatNumber(r.grossTotal, 0), unit: this.cur, sub: 'Salary, allowances, incentives' },
            { key: 'd', label: 'Deductions withheld', value: formatNumber(r.deductionTotal, 0), unit: this.cur, sub: 'Tax and other deductions' },
            { key: 'n', label: 'Net pay', value: formatNumber(r.netTotal, 0), unit: this.cur, sub: `Employer contributions ${formatNumber(r.employerTotal, 0)}` }
        ].map((f) => ({ ...f, hasUnit: Boolean(f.unit) }));
    }

    money(value) {
        return this.detailAccess ? formatNumber(value) : MASK;
    }

    // ---------- HR preparation ----------

    get lineRows() {
        return ((this.detail && this.detail.lines) || []).map((l) => ({
            ...l,
            grossText: formatNumber(l.grossAmount),
            deductionText: formatNumber(l.deductionAmount),
            employerText: formatNumber(l.employerContribution),
            netText: formatNumber(l.netAmount)
        }));
    }

    get hasLines() {
        return this.lineRows.length > 0;
    }

    get lineTotals() {
        const lines = (this.detail && this.detail.lines) || [];
        const sum = (f) => formatNumber(lines.reduce((s, l) => s + (Number(l[f]) || 0), 0));
        return { gross: sum('grossAmount'), deduction: sum('deductionAmount'), employer: sum('employerContribution'), net: sum('netAmount') };
    }

    get awardRows() {
        const canApprove = Boolean(this.can.approveCompensation);
        return ((this.queue && this.queue.awards) || []).map((a) => ({
            ...a,
            amountText: formatNumber(a.amount),
            chip: chipClass(a.status, a.status === 'Proposed' ? 'info' : a.status === 'Consumed' ? 'good' : undefined),
            canApprove: canApprove && a.status === 'Proposed',
            canCancel: canApprove && (a.status === 'Proposed' || a.status === 'Approved')
        }));
    }

    get hasAwards() {
        return this.awardRows.length > 0;
    }

    get assignmentRows() {
        const canApprove = Boolean(this.can.approveCompensation);
        return ((this.queue && this.queue.pendingAssignments) || []).map((a) => ({
            ...a,
            amountText: formatNumber(a.amount),
            fromText: formatDate(a.effectiveFrom),
            chip: chipClass(a.status, 'info'),
            canApprove
        }));
    }

    get hasAssignments() {
        return this.assignmentRows.length > 0;
    }

    get prepActions() {
        const r = this.run;
        const c = this.can;
        const reason = (allowed, action) => (allowed ? undefined : `${this.personaLabel} role cannot ${action}`);
        const activeEmployments = ((this.workspace && this.workspace.employments) || []).filter((e) => e.status === 'Active');
        return {
            showCalculate: r.state === 'Draft' || r.state === 'Calculated',
            calculateDisabled: this.busy || !c.calculate || !activeEmployments.length,
            calculateTitle: !activeEmployments.length ? 'There are no active employments to calculate' : reason(c.calculate, 'calculate payroll'),
            calculateLabel: r.state === 'Calculated' ? 'Recalculate' : 'Calculate',
            showSubmit: r.state === 'Calculated',
            submitDisabled: this.busy || !c.submit,
            submitTitle: reason(c.submit, 'submit payroll'),
            showApprove: r.state === 'Submitted',
            approveDisabled: this.busy || !c.approve,
            approveTitle: reason(c.approve, 'approve payroll'),
            showCancel: ['Draft', 'Calculated', 'Submitted', 'Approved'].includes(r.state),
            cancelDisabled: this.busy || !c.cancel,
            cancelTitle: reason(c.cancel, 'cancel payroll')
        };
    }

    get newRunDisabled() {
        return this.busy || !this.detailAccess || !this.can.calculate;
    }

    get newRunTitle() {
        if (!this.detailAccess) {
            return 'Payroll detail permission is required';
        }
        return this.can.calculate ? undefined : `${this.personaLabel} role cannot create payroll runs`;
    }

    // ---------- finance posting ----------

    get journalRows() {
        return ((this.summary && this.summary.journalLines) || []).map((l, i) => ({
            ...l,
            key: `j${i}`,
            debitText: l.debit ? formatNumber(l.debit) : '',
            creditText: l.credit ? formatNumber(l.credit) : ''
        }));
    }

    get hasJournal() {
        return this.journalRows.length > 0;
    }

    get journalTitle() {
        return this.summary && this.summary.journalName ? `Payroll journal ${this.summary.journalName}` : 'Payroll journal';
    }

    get journalSub() {
        const s = this.summary || {};
        return s.journalName ? `Posted ${formatDateTime(s.postedAt)}${s.postedBy ? ` by ${s.postedBy}` : ''}` : 'Posted when the approved run is posted';
    }

    get journalTotals() {
        const lines = (this.summary && this.summary.journalLines) || [];
        return { debit: formatNumber(lines.reduce((t, l) => t + (Number(l.debit) || 0), 0)), credit: formatNumber(lines.reduce((t, l) => t + (Number(l.credit) || 0), 0)) };
    }

    get canOpenJournal() {
        return Boolean(this.summary && this.summary.journalId) && Array.isArray(this.visibleWorkspaces) && this.visibleWorkspaces.includes('journal');
    }

    handleOpenJournal() {
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'journal', recordId: this.summary.journalId }, bubbles: true, composed: true }));
    }

    get departmentRows() {
        return ((this.summary && this.summary.departments) || []).map((d, i) => ({ ...d, key: `d${i}`, grossText: formatNumber(d.gross),
            meterStyle: `width:${Math.min(100, Number(d.share) || 0)}%`, shareText: `${d.share}%` }));
    }

    get hasDepartments() {
        return this.departmentRows.length > 0;
    }

    get postAction() {
        const c = this.can;
        const allowed = c.postPayroll && c.postJournal;
        return {
            show: this.run && this.run.state === 'Approved',
            disabled: this.busy || !allowed || !this.detailAccess,
            title: !this.detailAccess ? 'Payroll detail permission is required' : allowed ? undefined : `${this.personaLabel} role cannot post payroll`
        };
    }

    // ---------- treasury settlement ----------

    get payment() {
        return this.detail && this.detail.payment;
    }

    get settlementBanner() {
        const r = this.run;
        if (r.state === 'Settled') {
            return { className: 'banner t-good', icon: 'check', title: 'Net pay released',
                text: `${formatNumber(r.settledAmount)} ${this.cur} paid. Payroll payable is settled.` };
        }
        if (r.state === 'Posted') {
            return { className: 'banner t-warn', icon: 'alert', title: 'Net pay is ready to release',
                text: `${formatNumber(r.netTotal - r.settledAmount)} ${this.cur} to ${plural(r.employeeCount || 0, 'employee')}. Releasing posts Dr Payroll payable / Cr Bank through a payroll settlement.` };
        }
        return { className: 'banner t-info', icon: 'info', title: 'Not ready to pay', text: 'Net pay is released after the run is approved and posted.' };
    }

    get settlementRows() {
        const r = this.run;
        const returnAllowed = Boolean(this.can.processPayment) && (r.state === 'Posted' || r.state === 'Settled');
        return ((this.detail && this.detail.lines) || []).map((l) => ({
            ...l,
            netText: this.money(l.netAmount),
            settledText: this.money(l.settledAmount),
            outstandingText: this.money(l.outstandingAmount),
            chip: chipClass(l.outstandingAmount > 0 ? (l.settledAmount > 0 ? 'Part Settled' : 'Ready') : 'Settled', l.outstandingAmount > 0 && !l.settledAmount ? 'info' : undefined),
            statusText: l.outstandingAmount > 0 ? (l.settledAmount > 0 ? 'Part Settled' : 'Ready') : 'Settled',
            canReturn: returnAllowed && Boolean(l.effectiveSettlementId)
        }));
    }

    get hasSettlementRows() {
        return this.settlementRows.length > 0;
    }

    get paymentView() {
        const p = this.payment;
        const r = this.run;
        const c = this.can;
        const process = (allowed) => this.busy || !allowed;
        const title = (allowed, action) => (allowed ? undefined : `${this.personaLabel} role cannot ${action}`);
        if (!p) {
            return {
                hasPayment: false,
                showPrepare: r.state === 'Posted',
                prepareDisabled: process(c.processPayment),
                prepareTitle: title(c.processPayment, 'prepare payroll payments')
            };
        }
        return {
            hasPayment: true,
            facts: [['Payment', p.name], ['State', p.state], ['Amount', `${formatNumber(p.amount)} ${this.cur}`], ['Value date', formatDate(p.effectiveDate)],
                ['Bank', p.bankAccountName || '\u2014'], ['Method', p.method || '\u2014'], ['Reference', p.reference || '\u2014']]
                .map(([label, value]) => ({ key: label, valueKey: `${label}-v`, label, value })),
            showAuthorize: p.state === 'Draft',
            authorizeDisabled: process(c.authorizePayment),
            authorizeTitle: title(c.authorizePayment, 'authorise payroll payments'),
            showSubmit: p.state === 'Authorized',
            submitDisabled: process(c.processPayment),
            submitTitle: title(c.processPayment, 'release payroll payments'),
            showResult: p.state === 'Submitted',
            resultDisabled: process(c.processPayment),
            resultTitle: title(c.processPayment, 'record payment results')
        };
    }

    // ---------- actions ----------

    keyFor(action, recordId) {
        const name = `${action}|${recordId}`;
        if (!this.requestKeys[name]) {
            this.requestKeys = { ...this.requestKeys, [name]: newKey(`PAYROLL-${action}`, recordId) };
        }
        return this.requestKeys[name];
    }

    async execute(action, recordId, call, message) {
        const name = `${action}|${recordId}`;
        this.busy = true;
        try {
            await call(this.keyFor(action, recordId));
            const keys = { ...this.requestKeys };
            delete keys[name];
            this.requestKeys = keys;
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

    handleCalculate() {
        const runId = this.selectedRunId;
        const employmentIds = this.workspace.employments.filter((e) => e.status === 'Active').map((e) => e.employmentId);
        this.execute('CALCULATE', runId, () => calculateRun({ runId, employmentIds, minorUnits: 2 }), 'Payroll calculated');
    }

    handleSubmit() {
        const runId = this.selectedRunId;
        this.execute('SUBMIT', runId, () => submitRun({ runId }), 'Payroll submitted for approval');
    }

    handleApprove() {
        const runId = this.selectedRunId;
        this.execute('APPROVE', runId, () => approveRun({ runId }), 'Payroll approved');
    }

    handleAuthorize() {
        const runId = this.selectedRunId;
        this.execute('AUTHORIZE', this.payment.paymentId, (key) => authorizePayment({ runId, requestKey: key }), 'Payment authorised');
    }

    handleSubmitPayment() {
        const runId = this.selectedRunId;
        const providerRequestKey = newKey('PROVIDER', this.payment.paymentId);
        this.execute('PAYSUBMIT', this.payment.paymentId, (key) => submitPayment({ runId, providerRequestKey, requestKey: key }), 'Net pay released to the bank');
    }

    handleSucceeded() {
        const runId = this.selectedRunId;
        this.execute('SUCCEEDED', this.payment.paymentId, (key) => recordPaymentSucceeded({ runId, requestKey: key }), 'Payment succeeded, payroll settled');
    }

    handleApproveAssignment(event) {
        const assignmentId = event.currentTarget.dataset.id;
        this.execute('APPROVEASSIGN', assignmentId, () => approveAssignment({ assignmentId }), 'Compensation approved');
    }

    handleApproveAward(event) {
        const awardId = event.currentTarget.dataset.id;
        this.execute('APPROVEAWARD', awardId, () => approveBenefitAward({ awardId }), 'Benefit award approved');
    }

    handleCancelAward(event) {
        const awardId = event.currentTarget.dataset.id;
        this.execute('CANCELAWARD', awardId, () => cancelBenefitAward({ awardId }), 'Benefit award cancelled');
    }

    // ---------- modals ----------

    openModal(kind, form) {
        this.form = form;
        this.formError = undefined;
        this.modal = kind;
    }

    handleNewRun() {
        const d = new Date();
        const start = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`;
        const last = new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate();
        this.openModal('new', { periodStart: start, periodEnd: `${start.slice(0, 8)}${String(last).padStart(2, '0')}` });
    }

    handleCancelRun() {
        this.openModal('cancel', { reason: '' });
    }

    handlePost() {
        const r = this.run;
        const w = this.workspace || {};
        const date = r.accountingDate || r.periodEnd;
        const period = (w.openPeriods || []).find((p) => p.startDate <= date && p.endDate >= date);
        this.openModal('post', { periodId: period ? period.value : '', accountingDate: date, payableAccountId: ((w.payableAccounts || [])[0] || {}).value || '' });
    }

    handlePrepare() {
        const w = this.workspace || {};
        this.openModal('prepare', { bankAccountId: ((w.bankAccounts || [])[0] || {}).value || '', paymentDate: todayIso(),
            method: ((w.paymentMethods || [])[0] || {}).value || '', reference: `${this.run.name} net pay` });
    }

    handleFailed() {
        this.openModal('fail', { reason: '' });
    }

    handleReturnLine(event) {
        this.openModal('return', { settlementId: event.currentTarget.dataset.id, returnDate: todayIso(), reason: '' });
    }

    get modalOpen() {
        return Boolean(this.modal);
    }

    get modalHeading() {
        return { new: 'New payroll run', cancel: 'Cancel payroll run', post: 'Post payroll', prepare: 'Prepare net pay payment', fail: 'Record payment failure',
            return: 'Record bank return' }[this.modal];
    }

    get modalSub() {
        return {
            new: 'Creates a draft run for the period. Calculate it next.',
            cancel: 'Consumed benefit awards are released. A reason is required.',
            post: 'Posts Dr payroll expense / Cr payroll payable and deductions.',
            prepare: 'One disbursement for the run net pay, tagged to the payroll run.',
            fail: 'The bank rejected the payment. A reason is required.',
            return: 'The bank returned one employee payment; the line reopens for payment.'
        }[this.modal];
    }

    get saveLabel() {
        return { new: 'Create draft', cancel: 'Cancel run', post: 'Post payroll', prepare: 'Prepare payment', fail: 'Record failure', return: 'Record return' }[this.modal];
    }

    get saveClass() {
        return this.modal === 'cancel' || this.modal === 'fail' || this.modal === 'return' ? 'btn danger sab-modal-save' : 'btn primary sab-modal-save';
    }

    get isNewModal() {
        return this.modal === 'new';
    }

    get isReasonModal() {
        return this.modal === 'cancel' || this.modal === 'fail' || this.modal === 'return';
    }

    get isReturnModal() {
        return this.modal === 'return';
    }

    get isPostModal() {
        return this.modal === 'post';
    }

    get isPrepareModal() {
        return this.modal === 'prepare';
    }

    options(list, selected) {
        return (list || []).map((o) => ({ value: o.value, label: o.label, selected: o.value === selected }));
    }

    get periodOptions() {
        return this.options(this.workspace && this.workspace.openPeriods, this.form.periodId);
    }

    get payableOptions() {
        return this.options(this.workspace && this.workspace.payableAccounts, this.form.payableAccountId);
    }

    get bankOptions() {
        return this.options(this.workspace && this.workspace.bankAccounts, this.form.bankAccountId);
    }

    get methodOptions() {
        return this.options(this.workspace && this.workspace.paymentMethods, this.form.method);
    }

    handleField(event) {
        this.form = { ...this.form, [event.target.dataset.field]: event.target.value };
    }

    handleCloseModal() {
        if (!this.busy) {
            this.modal = undefined;
        }
    }

    async handleSave() {
        const f = this.form;
        const runId = this.selectedRunId;
        if (this.isReasonModal && !String(f.reason || '').trim()) {
            this.formError = 'A reason is required.';
            return;
        }
        let ok;
        if (this.modal === 'new') {
            this.busy = true;
            try {
                this.selectedRunId = await createDraftForWorkspace({ companyId: this.currentCompanyId, periodStart: f.periodStart, periodEnd: f.periodEnd,
                    currencyCode: this.cur });
                toast(this, 'Draft payroll run created');
                this.modal = undefined;
                this.busy = false;
                await this.load();
                return;
            } catch (error) {
                this.formError = reduceError(error);
                this.busy = false;
                return;
            }
        } else if (this.modal === 'cancel') {
            ok = await this.execute('CANCEL', runId, () => cancelRun({ runId, reason: f.reason.trim() }), 'Payroll cancelled, consumed awards released');
        } else if (this.modal === 'post') {
            ok = await this.execute('POST', runId, (key) => postRun({ runId, periodId: f.periodId || null, accountingDate: f.accountingDate || null,
                payableAccountId: f.payableAccountId || null, requestKey: key }), 'Payroll accrual posted');
        } else if (this.modal === 'prepare') {
            ok = await this.execute('PREPARE', runId, (key) => preparePayment({ runId, bankAccountId: f.bankAccountId || null, paymentDate: f.paymentDate || null,
                method: f.method || null, reference: f.reference || null, requestKey: key }), 'Net pay payment prepared');
        } else if (this.modal === 'fail') {
            ok = await this.execute('FAILED', this.payment.paymentId, (key) => recordPaymentFailed({ runId, reason: f.reason.trim(), requestKey: key }),
                'Payment recorded as failed');
        } else {
            ok = await this.execute('RETURN', f.settlementId, (key) => recordLineReturn({ settlementId: f.settlementId, returnDate: f.returnDate || null,
                reason: f.reason.trim(), requestKey: key }), 'Bank return recorded, line reopened');
        }
        if (ok) {
            this.modal = undefined;
        }
    }

    handleRetry() {
        this.load();
    }
}