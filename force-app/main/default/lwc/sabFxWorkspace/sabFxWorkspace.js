import { LightningElement, api } from 'lwc';
import getDashboard from '@salesforce/apex/SABFXOperationsWorkspaceController.getDashboard';
import getTargets from '@salesforce/apex/SABFXOperationsWorkspaceController.getEligibleSettlementTargets';
import previewRevaluation from '@salesforce/apex/SABFXRevaluationPreviewService.preview';
import approveRun from '@salesforce/apex/SABFXRevaluationPostingService.approveRun';
import postApprovedRun from '@salesforce/apex/SABFXRevaluationPostingService.postApprovedRun';
import reversePostedRun from '@salesforce/apex/SABFXRevaluationReversalService.reversePostedRun';
import authorizeForeignPayment from '@salesforce/apex/SABForeignCurrencySettlementService.authorizeForeignPayment';
import submitForeignPayment from '@salesforce/apex/SABForeignCurrencySettlementService.submitForeignPayment';
import postForeignPayment from '@salesforce/apex/SABForeignCurrencySettlementService.postForeignPayment';
import allocateForeignPayment from '@salesforce/apex/SABForeignCurrencySettlementService.allocateForeignPayment';
import reverseForeignAllocation from '@salesforce/apex/SABForeignCurrencySettlementService.reverseForeignAllocation';
import { formatNumber, formatDate, chipClass } from 'c/sabFormat';
import { reduceError, newKey, todayIso, hsteps, toast } from 'c/sabMoneyShared';

const RUN_STEPS = ['Preview', 'Approved', 'Posted'];
const PAY_STEPS = ['Draft', 'Authorized', 'Submitted', 'Succeeded'];
const POLICIES = ['First Day of Next Period', 'Next Open Period', 'No Automatic Reversal'];

/**
 * Foreign exchange in the Harbourline demo layout (G22G-7c): unrealized revaluation runs from preview to posting and
 * reversal, foreign-currency payments and their allocations with realized gains and losses, on the FX revaluation and
 * foreign currency settlement services, unchanged.
 */
export default class SabFxWorkspace extends LightningElement {
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
    activeTab = 'runs';
    drawer;
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
            const data = await getDashboard({ companyId });
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

    get cur() {
        return (this.data && this.data.functionalCurrency) || this.currencyCode || '';
    }

    get personaLabel() {
        return (this.persona && this.persona.label) || 'Your';
    }

    reason(allowed, action) {
        return allowed ? undefined : `${this.personaLabel} role cannot ${action}`;
    }

    get runs() {
        return (this.data && this.data.revaluationRuns) || [];
    }

    get payments() {
        return (this.data && this.data.foreignPayments) || [];
    }

    get allocations() {
        return (this.data && this.data.allocations) || [];
    }

    // ---------- figures, banners and tabs ----------

    get figures() {
        const d = this.data;
        return [
            { key: 'r', label: 'Runs to approve', value: String(d.previewRunCount || 0), sub: `${d.approvedRunCount || 0} approved, ready to post` },
            { key: 'p', label: 'Revaluations posted', value: String(d.postedRunCount || 0), sub: `${d.reversedRunCount || 0} reversed` },
            { key: 'g', label: 'Realized gains', value: formatNumber(d.postedRealizedGainTotal, 0), unit: this.cur, sub: 'Posted from settlements' },
            { key: 'l', label: 'Realized losses', value: formatNumber(d.postedRealizedLossTotal, 0), unit: this.cur, sub: 'Posted from settlements' }
        ].map((f) => ({ ...f, hasUnit: Boolean(f.unit) }));
    }

    get setupWarnings() {
        const d = this.data;
        const missing = [];
        if (!d.unrealizedAccountsConfigured) {
            missing.push('unrealized gain and loss accounts (needed to post revaluations)');
        }
        if (!d.realizedAccountsConfigured) {
            missing.push('realized gain and loss accounts (needed to settle foreign payments)');
        }
        return missing.length ? `Set up the ${missing.join(' and the ')} in Company setup.` : undefined;
    }

    get tabs() {
        return [
            { id: 'runs', label: 'Revaluation', count: this.runs.length },
            { id: 'pay', label: 'Foreign payments', count: this.payments.length },
            { id: 'alloc', label: 'Settlements', count: this.allocations.length }
        ].map((t) => ({ ...t, className: t.id === this.activeTab ? 'tab active' : 'tab', selected: t.id === this.activeTab ? 'true' : 'false' }));
    }

    handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    get isRuns() {
        return this.activeTab === 'runs';
    }

    get isPayments() {
        return this.activeTab === 'pay';
    }

    get runRows() {
        return this.runs.map((r) => ({
            ...r,
            adjustmentText: formatNumber(r.signedAdjustmentTotal),
            adjustmentClass: Number(r.signedAdjustmentTotal) < 0 ? 'n num neg' : 'n num',
            linesText: `${r.lineCount || 0} (${r.arLineCount || 0} AR, ${r.apLineCount || 0} AP)`,
            chip: chipClass(r.status, r.status === 'Preview' ? 'info' : r.status === 'Reversed' ? 'neutral' : undefined)
        }));
    }

    get paymentRows() {
        return this.payments.map((p) => ({
            ...p,
            amountText: `${formatNumber(p.amount)} ${p.transactionCurrency}`,
            rateText: p.exchangeRate ? String(p.exchangeRate) : '\u2014',
            unallocatedText: formatNumber(p.unallocatedAmount),
            chip: chipClass(p.processingState)
        }));
    }

    get allocationRows() {
        return this.allocations.map((a) => ({
            ...a,
            dateText: formatDate(a.effectiveDate),
            amountText: `${formatNumber(a.documentAmount)} ${a.transactionCurrency || ''}`.trim(),
            fxText: formatNumber(a.realizedFXAmount),
            fxClass: Number(a.realizedFXAmount) < 0 ? 'n num neg' : 'n num',
            chip: chipClass(a.status, a.status === 'Reversed' ? 'neutral' : undefined),
            canReverse: a.status === 'Allocated' && !a.reversalOfId && this.data.canProcessForeignSettlement
        }));
    }

    get hasRuns() {
        return this.runRows.length > 0;
    }

    get hasPayments() {
        return this.paymentRows.length > 0;
    }

    get hasAllocations() {
        return this.allocationRows.length > 0;
    }

    get newRunDisabled() {
        return !(this.data && this.data.canRunRevaluation);
    }

    get newRunTitle() {
        return this.reason(this.data && this.data.canRunRevaluation, 'run revaluations');
    }

    // ---------- drawers ----------

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

    handleRun(event) {
        if (this.keyed(event)) {
            this.drawer = { kind: 'run', id: event.currentTarget.dataset.id };
        }
    }

    handlePayment(event) {
        if (this.keyed(event)) {
            this.drawer = { kind: 'payment', id: event.currentTarget.dataset.id };
        }
    }

    handleCloseDrawer() {
        this.drawer = undefined;
    }

    get drawerOpen() {
        return Boolean(this.drawer);
    }

    get run() {
        return this.drawer && this.drawer.kind === 'run' ? this.runs.find((r) => r.runId === this.drawer.id) : undefined;
    }

    get payment() {
        return this.drawer && this.drawer.kind === 'payment' ? this.payments.find((p) => p.paymentId === this.drawer.id) : undefined;
    }

    get drawerHeading() {
        return (this.run && this.run.name) || (this.payment && this.payment.name) || '';
    }

    get drawerSub() {
        if (this.run) {
            return `${this.run.accountingPeriodName}, rates ${this.run.rateSetKey || 'from the period end'}, ${this.run.reversalPolicy}`;
        }
        if (this.payment) {
            return `${this.payment.direction} ${this.payment.direction === 'Receipt' ? 'from' : 'to'} ${this.payment.partyProfileName || 'unknown party'}, ${formatDate(this.payment.effectiveDate)}`;
        }
        return '';
    }

    get runView() {
        const r = this.run;
        const d = this.data;
        const index = RUN_STEPS.indexOf(r.status);
        return {
            steps: hsteps(RUN_STEPS, r.status === 'Posted' ? 3 : Math.max(0, index)),
            reversed: r.status === 'Reversed',
            lines: (r.lines || []).map((l) => ({
                ...l,
                account: [l.sourceGLAccountCode, l.sourceGLAccountName].filter(Boolean).join(' '),
                outstandingText: `${formatNumber(l.outstandingAmount)} ${l.transactionCurrency}`,
                carryingText: formatNumber(l.carryingAmount),
                rateText: String(l.appliedRate),
                revaluedText: formatNumber(l.revaluedAmount),
                adjustmentText: formatNumber(l.adjustmentAmount),
                adjustmentClass: Number(l.adjustmentAmount) < 0 ? 'n num neg' : 'n num'
            })),
            hasLines: (r.lines || []).length > 0,
            totalText: formatNumber(r.signedAdjustmentTotal),
            facts: [['Approved by', r.approvedByName || '\u2014'], ['Posted', r.postedAt ? formatDate(r.postedAt.slice(0, 10)) : '\u2014'],
                ['Reversed', r.reversedAt ? formatDate(r.reversedAt.slice(0, 10)) : '\u2014']].map(([label, value]) => ({ key: label, valueKey: `${label}-v`, label, value })),
            isPreview: r.status === 'Preview',
            isApproved: r.status === 'Approved',
            isPosted: r.status === 'Posted',
            approveDisabled: this.busy || !d.canApproveRevaluation,
            approveTitle: this.reason(d.canApproveRevaluation, 'approve revaluations'),
            postDisabled: this.busy || !d.canPostRevaluation,
            postTitle: this.reason(d.canPostRevaluation, 'post revaluations'),
            reverseDisabled: this.busy || !d.canReverseRevaluation,
            reverseTitle: this.reason(d.canReverseRevaluation, 'reverse revaluations')
        };
    }

    get paymentView() {
        const p = this.payment;
        const d = this.data;
        const index = PAY_STEPS.indexOf(p.processingState);
        return {
            steps: hsteps(PAY_STEPS, index === 3 ? 4 : Math.max(0, index)),
            failed: p.processingState === 'Failed',
            facts: [['Amount', `${formatNumber(p.amount)} ${p.transactionCurrency}`], ['Rate', p.exchangeRate ? `${p.exchangeRate} ${p.functionalCurrency} per ${p.transactionCurrency}` : '\u2014'],
                ['Bank', p.bankAccountName || '\u2014'], ['Allocated', formatNumber(p.activeAllocatedAmount)], ['Unallocated', formatNumber(p.unallocatedAmount)],
                ['Reference', p.reference || '\u2014']].map(([label, value]) => ({ key: label, valueKey: `${label}-v`, label, value })),
            showAuthorize: p.processingState === 'Draft',
            showSubmit: p.processingState === 'Authorized',
            showPost: p.processingState === 'Submitted',
            showAllocate: p.processingState === 'Succeeded' && Number(p.unallocatedAmount) > 0,
            disabled: this.busy || !d.canProcessForeignSettlement,
            title: this.reason(d.canProcessForeignSettlement, 'process foreign payments'),
            postDisabled: this.busy || !d.canProcessForeignSettlement || !d.canPostRealizedFX,
            postTitle: !d.canProcessForeignSettlement ? this.reason(false, 'process foreign payments') : this.reason(d.canPostRealizedFX, 'post realized FX')
        };
    }

    // ---------- actions ----------

    keyFor(action, recordId) {
        const name = `${action}|${recordId}`;
        if (!this.requestKeys[name]) {
            this.requestKeys = { ...this.requestKeys, [name]: newKey(`FX-${action}`, recordId) };
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

    handleAuthorize() {
        const paymentId = this.drawer.id;
        this.execute('AUTH', paymentId, (requestKey) => authorizeForeignPayment({ paymentId, requestKey }), 'Foreign payment authorised');
    }

    handleSubmitPayment() {
        const paymentId = this.drawer.id;
        const providerRequestKey = this.keyFor('PROVIDER', paymentId);
        this.execute('SUBMIT', paymentId, (requestKey) => submitForeignPayment({ paymentId, providerRequestKey, requestKey }), 'Foreign payment released to the bank');
    }

    handlePostPayment() {
        const paymentId = this.drawer.id;
        this.execute('POST', paymentId, (requestKey) => postForeignPayment({ paymentId, requestKey }), 'Foreign payment cleared and posted');
    }

    // ---------- modals ----------

    openModal(kind, form) {
        this.form = form;
        this.formError = undefined;
        this.modal = kind;
    }

    handleNewRun() {
        const periods = (this.data.periods || []).filter((p) => p.status === 'Open');
        const last = periods[periods.length - 1] || (this.data.periods || [])[0] || {};
        this.openModal('preview', { periodId: last.periodId || '', runKey: `FXR-${last.name || 'RUN'}-${Date.now().toString(36).toUpperCase()}`, reversalPolicy: POLICIES[0] });
    }

    handleApproveRun() {
        this.openModal('approve', { reason: '' });
    }

    handlePostRun() {
        this.openModal('post', { reason: '' });
    }

    handleReverseRun() {
        this.openModal('reverse', { reason: '', manual: false, periodId: '', reversalDate: '' });
    }

    async handleAllocate() {
        this.targets = [];
        this.openModal('allocate', { targetId: '', amount: '', effectiveDate: this.payment.effectiveDate || todayIso(), notes: '', reason: '' });
        try {
            this.targets = (await getTargets({ paymentId: this.drawer.id })) || [];
            if (this.targets.length) {
                this.form = { ...this.form, targetId: this.targets[0].targetId, amount: String(Math.min(Number(this.targets[0].outstandingAmount) || 0, Number(this.payment.unallocatedAmount) || 0)) };
            }
        } catch (error) {
            this.formError = reduceError(error);
        }
    }

    handleReverseAllocation(event) {
        this.openModal('reverseAlloc', { allocationId: event.currentTarget.dataset.id, reversalDate: todayIso(), reason: '' });
    }

    get modalOpen() {
        return Boolean(this.modal);
    }

    get modalHeading() {
        return { preview: 'New revaluation', approve: 'Approve revaluation', post: 'Post revaluation', reverse: 'Reverse revaluation',
            allocate: 'Allocate foreign payment', reverseAlloc: 'Reverse settlement' }[this.modal];
    }

    get modalSub() {
        return {
            preview: 'Revalues open foreign-currency receivables and payables at the period-end rate. Nothing posts until approved and posted.',
            approve: 'Approves the previewed adjustments for posting.',
            post: 'Posts the unrealized gain or loss journal for the period.',
            reverse: 'Posts the reversing journal. A reason is required.',
            allocate: 'Settles an invoice or bill in the payment currency and posts the realized gain or loss.',
            reverseAlloc: 'Reverses the settlement and its realized FX. A reason is required.'
        }[this.modal];
    }

    get saveLabel() {
        return { preview: 'Preview run', approve: 'Approve', post: 'Post revaluation', reverse: 'Reverse', allocate: 'Allocate', reverseAlloc: 'Reverse settlement' }[this.modal];
    }

    get saveClass() {
        return this.modal === 'reverse' || this.modal === 'reverseAlloc' ? 'btn danger sab-modal-save' : 'btn primary sab-modal-save';
    }

    get isPreviewModal() {
        return this.modal === 'preview';
    }

    get isReverseModal() {
        return this.modal === 'reverse';
    }

    get isAllocateModal() {
        return this.modal === 'allocate';
    }

    get isReverseAllocModal() {
        return this.modal === 'reverseAlloc';
    }

    get showReason() {
        return this.modal !== 'preview';
    }

    get reasonLabel() {
        return this.modal === 'reverse' || this.modal === 'reverseAlloc' ? 'Reason' : 'Note (optional)';
    }

    get periodOptions() {
        return ((this.data && this.data.periods) || []).map((p) => ({ value: p.periodId, label: p.label || p.name, selected: p.periodId === this.form.periodId }));
    }

    get policyOptions() {
        return POLICIES.map((v) => ({ value: v, label: v, selected: v === this.form.reversalPolicy }));
    }

    get targetOptions() {
        return this.targets.map((t) => ({ value: t.targetId, label: t.label || `${t.targetType} ${t.documentNumber || t.name}, ${formatNumber(t.outstandingAmount)} ${t.transactionCurrency} open`,
            selected: t.targetId === this.form.targetId }));
    }

    get noTargets() {
        return this.isAllocateModal && !this.targets.length;
    }

    handleField(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        this.form = { ...this.form, [field]: value };
    }

    handleCloseModal() {
        if (!this.busy) {
            this.modal = undefined;
        }
    }

    async handleSave() {
        const f = this.form;
        const reasonText = String(f.reason || '').trim();
        if ((this.modal === 'reverse' || this.modal === 'reverseAlloc') && !reasonText) {
            this.formError = 'A reason is required.';
            return;
        }
        let ok;
        if (this.modal === 'preview') {
            ok = await this.execute('PREVIEW', f.runKey, () => previewRevaluation({ request: { companyId: this.currentCompanyId, accountingPeriodId: f.periodId || null,
                runKey: f.runKey, reversalPolicy: f.reversalPolicy } }), 'Revaluation previewed', (result) => {
                this.drawer = { kind: 'run', id: result.runId };
                this.activeTab = 'runs';
            });
        } else if (this.modal === 'approve') {
            const runId = this.drawer.id;
            ok = await this.execute('APPROVE', runId, (requestKey) => approveRun({ runId, requestKey, reason: reasonText || null }), 'Revaluation approved');
        } else if (this.modal === 'post') {
            const runId = this.drawer.id;
            ok = await this.execute('POSTRUN', runId, (requestKey) => postApprovedRun({ runId, requestKey, reason: reasonText || null }), 'Revaluation posted');
        } else if (this.modal === 'reverse') {
            const runId = this.drawer.id;
            ok = await this.execute('REVERSE', runId, (requestKey) => reversePostedRun({ runId, requestedReversalPeriodId: f.manual ? f.periodId || null : null,
                requestedReversalDate: f.manual ? f.reversalDate || null : null, requestKey, reason: reasonText }), 'Revaluation reversed');
        } else if (this.modal === 'allocate') {
            const target = this.targets.find((t) => t.targetId === f.targetId);
            if (!target || !(Number(f.amount) > 0)) {
                this.formError = 'Choose an open document and an amount above zero.';
                return;
            }
            const paymentId = this.drawer.id;
            ok = await this.execute('ALLOC', `${paymentId}|${target.targetId}`, (requestKey) => allocateForeignPayment({ paymentId, requests: [{
                invoiceId: target.targetType === 'Invoice' ? target.targetId : null, supplierBillId: target.targetType === 'Supplier Bill' ? target.targetId : null,
                amount: Number(f.amount), effectiveDate: f.effectiveDate || null, notes: f.notes || null }], requestKey, reason: reasonText || null }), 'Foreign payment allocated');
        } else {
            const allocationId = f.allocationId;
            ok = await this.execute('ALLOC-REV', allocationId, (requestKey) => reverseForeignAllocation({ allocationId, reversalDate: f.reversalDate || null, requestKey,
                reason: reasonText }), 'Settlement reversed');
        }
        if (ok) {
            this.modal = undefined;
        }
    }

    handleRetry() {
        this.load();
    }
}
