import { LightningElement, api } from 'lwc';
import getDashboard from '@salesforce/apex/SABExpenseOperationsWorkspaceController.getDashboard';
import getClaimDetail from '@salesforce/apex/SABExpenseOperationsWorkspaceController.getClaimDetail';
import submitClaim from '@salesforce/apex/SABExpenseClaimLifecycleService.submitClaim';
import approveClaim from '@salesforce/apex/SABExpenseClaimLifecycleService.approveClaim';
import rejectClaim from '@salesforce/apex/SABExpenseClaimLifecycleService.rejectClaim';
import postApprovedClaim from '@salesforce/apex/SABExpenseClaimPostingService.postApprovedClaim';
import authorizePayment from '@salesforce/apex/SABExpenseReimbursementPaymentService.authorizePayment';
import submitPayment from '@salesforce/apex/SABExpenseReimbursementPaymentService.submitPayment';
import postPayment from '@salesforce/apex/SABExpenseReimbursementPaymentService.recordSucceededAndPost';
import settleClaim from '@salesforce/apex/SABExpenseClaimSettlementService.settleClaim';
import reverseSettlement from '@salesforce/apex/SABExpenseClaimSettlementService.reverseSettlement';
import { formatNumber, formatDate, chipClass } from 'c/sabFormat';
import { reduceError, newKey, hsteps, toast } from 'c/sabMoneyShared';

const STEPS = ['Draft', 'Submitted', 'Approved', 'Posted', 'Paid'];
const STEP_INDEX = { Draft: 0, Submitted: 1, Approved: 2, Posted: 3, 'Part Paid': 4, Paid: 5 };
const PAY_STEPS = ['Draft', 'Authorized', 'Submitted', 'Succeeded'];

/**
 * Expense claims in the Harbourline demo layout (G22G-7c): claims from submission to reimbursement and settlement, and
 * reimbursement payments, on the expense claim lifecycle, posting, reimbursement and settlement services, unchanged.
 */
export default class SabExpensesWorkspace extends LightningElement {
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
    activeTab = 'claims';
    drawer;
    detail;
    detailError;
    busy = false;
    modal;
    form = {};
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
            if (sequence !== this.loadSequence) {
                return;
            }
            this.data = data;
            if (this.drawer && this.drawer.kind === 'claim') {
                await this.openClaim(this.drawer.id);
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

    get claims() {
        return (this.data && this.data.claims) || [];
    }

    get payments() {
        return (this.data && this.data.reimbursementPayments) || [];
    }

    // ---------- figures and tabs ----------

    get figures() {
        const d = this.data;
        return [
            { key: 's', label: 'Waiting for review', value: String(d.submittedCount || 0), sub: 'Submitted claims' },
            { key: 'a', label: 'Approved, not posted', value: String(d.approvedCount || 0), sub: 'Post to record the liability' },
            { key: 'o', label: 'Owed to staff', value: formatNumber(d.reimbursementOutstanding, 0), unit: this.cur, sub: `${(d.postedCount || 0) + (d.partPaidCount || 0)} claims to reimburse` },
            { key: 'p', label: 'Paid', value: String(d.paidCount || 0), sub: `${d.rejectedCount || 0} rejected` }
        ].map((f) => ({ ...f, hasUnit: Boolean(f.unit) }));
    }

    get tabs() {
        return [
            { id: 'claims', label: 'Claims', count: this.claims.length },
            { id: 'pay', label: 'Reimbursement payments', count: this.payments.length }
        ].map((t) => ({ ...t, className: t.id === this.activeTab ? 'tab active' : 'tab', selected: t.id === this.activeTab ? 'true' : 'false' }));
    }

    handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    get isClaims() {
        return this.activeTab === 'claims';
    }

    get claimRows() {
        return this.claims.map((c) => ({
            ...c,
            dateText: formatDate(c.claimDate),
            totalText: formatNumber(c.totalAmount),
            paidText: c.paidAmount ? formatNumber(c.paidAmount) : '\u2014',
            remainingText: ['Posted', 'Part Paid'].includes(c.status) ? formatNumber(c.remainingAmount) : '\u2014',
            chip: chipClass(c.status, c.status === 'Draft' ? 'neutral' : undefined)
        }));
    }

    get paymentRows() {
        return this.payments.map((p) => ({
            ...p,
            dateText: formatDate(p.effectiveDate),
            amountText: formatNumber(p.amount),
            remainingText: formatNumber(p.remainingAmount),
            chip: chipClass(p.processingState)
        }));
    }

    get hasClaims() {
        return this.claimRows.length > 0;
    }

    get hasPayments() {
        return this.paymentRows.length > 0;
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

    handleClaim(event) {
        if (this.keyed(event)) {
            this.openClaim(event.currentTarget.dataset.id);
        }
    }

    handlePayment(event) {
        if (this.keyed(event)) {
            this.drawer = { kind: 'payment', id: event.currentTarget.dataset.id };
        }
    }

    async openClaim(claimId) {
        this.drawer = { kind: 'claim', id: claimId };
        this.detailError = undefined;
        try {
            this.detail = await getClaimDetail({ claimId });
        } catch (error) {
            this.detail = undefined;
            this.detailError = reduceError(error);
        }
    }

    handleCloseDrawer() {
        this.drawer = undefined;
    }

    get drawerOpen() {
        return Boolean(this.drawer);
    }

    get claim() {
        return this.drawer && this.drawer.kind === 'claim' ? this.claims.find((c) => c.claimId === this.drawer.id) : undefined;
    }

    get payment() {
        return this.drawer && this.drawer.kind === 'payment' ? this.payments.find((p) => p.paymentId === this.drawer.id) : undefined;
    }

    get isClaimDrawer() {
        return Boolean(this.claim && this.detail && this.detail.claimId === this.claim.claimId);
    }

    get isPaymentDrawer() {
        return Boolean(this.payment);
    }

    get drawerHeading() {
        if (this.claim) {
            return this.claim.name;
        }
        return this.payment ? this.payment.name : '';
    }

    get drawerSub() {
        if (this.claim) {
            return `${this.claim.claimantName || 'Claimant'}, claimed ${formatDate(this.claim.claimDate)}, ${formatNumber(this.claim.totalAmount)} ${this.claim.currencyCode || this.cur}`;
        }
        if (this.payment) {
            return `${this.payment.reference || 'Reimbursement'}, ${formatDate(this.payment.effectiveDate)}`;
        }
        return '';
    }

    get claimView() {
        const c = this.claim;
        const d = this.data;
        const index = STEP_INDEX[c.status] === undefined ? 0 : STEP_INDEX[c.status];
        const payable = this.payments.filter((p) => p.processingState === 'Succeeded' && Number(p.remainingAmount) > 0);
        return {
            steps: hsteps(STEPS, index),
            rejected: c.status === 'Rejected',
            lines: (this.detail.lines || []).map((l) => ({
                ...l,
                dateText: formatDate(l.expenseDate),
                account: [l.expenseAccountCode, l.expenseAccountName].filter(Boolean).join(' '),
                taxText: l.taxAmount ? formatNumber(l.taxAmount) : '\u2014',
                amountText: formatNumber(l.amount)
            })),
            hasLines: (this.detail.lines || []).length > 0,
            settlements: (this.detail.settlements || []).map((s) => ({
                ...s,
                dateText: formatDate(s.effectiveDate),
                amountText: formatNumber(s.allocatedAmount),
                chip: chipClass(s.status, s.status === 'Reversed' ? 'neutral' : undefined),
                canReverse: s.status === 'Effective' && !s.reversalOfId && d.canProcessReimbursement
            })),
            hasSettlements: (this.detail.settlements || []).length > 0,
            facts: [['Total', `${formatNumber(c.totalAmount)} ${c.currencyCode || this.cur}`], ['Paid', formatNumber(c.paidAmount)], ['Remaining', formatNumber(c.remainingAmount)],
                ['Accounting date', c.accountingDate ? formatDate(c.accountingDate) : '\u2014']].map(([label, value]) => ({ key: label, valueKey: `${label}-v`, label, value })),
            isDraft: c.status === 'Draft',
            isSubmitted: c.status === 'Submitted',
            isApproved: c.status === 'Approved',
            canSettle: ['Posted', 'Part Paid'].includes(c.status) && Number(c.remainingAmount) > 0,
            noPayment: payable.length === 0,
            submitDisabled: this.busy || !d.canSubmitClaim,
            submitTitle: this.reason(d.canSubmitClaim, 'submit expense claims'),
            reviewDisabled: this.busy || !d.canReviewClaim,
            reviewTitle: this.reason(d.canReviewClaim, 'review expense claims'),
            postDisabled: this.busy || !d.canPostClaim,
            postTitle: this.reason(d.canPostClaim, 'post expense claims'),
            settleDisabled: this.busy || !d.canProcessReimbursement || payable.length === 0,
            settleTitle: !d.canProcessReimbursement ? this.reason(false, 'settle reimbursements') : payable.length === 0 ? 'No cleared reimbursement payment has money left to apply' : undefined
        };
    }

    get paymentView() {
        const p = this.payment;
        const d = this.data;
        const index = PAY_STEPS.indexOf(p.processingState);
        const disabled = this.busy || !d.canProcessReimbursement;
        return {
            steps: hsteps(PAY_STEPS, index === 3 ? 4 : Math.max(0, index)),
            failed: p.processingState === 'Failed',
            facts: [['Amount', `${formatNumber(p.amount)} ${p.currencyCode || this.cur}`], ['Bank', p.bankAccountName || '\u2014'], ['Applied to claims', formatNumber(p.allocatedAmount)],
                ['Not yet applied', formatNumber(p.remainingAmount)], ['Provider key', p.providerRequestKey || '\u2014']]
                .map(([label, value]) => ({ key: label, valueKey: `${label}-v`, label, value })),
            showAuthorize: p.processingState === 'Draft',
            showRelease: p.processingState === 'Authorized',
            showClear: p.processingState === 'Submitted',
            disabled,
            title: this.reason(d.canProcessReimbursement, 'process reimbursements')
        };
    }

    // ---------- actions ----------

    keyFor(action, recordId) {
        const name = `${action}|${recordId}`;
        if (!this.requestKeys[name]) {
            this.requestKeys = { ...this.requestKeys, [name]: newKey(`EXP-${action}`, recordId) };
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

    handleSubmit() {
        const claimId = this.drawer.id;
        this.execute('SUBMIT', claimId, (requestKey) => submitClaim({ claimId, requestKey }), 'Expense claim submitted');
    }

    handlePost() {
        const claimId = this.drawer.id;
        this.execute('POST', claimId, (requestKey) => postApprovedClaim({ request: { expenseClaimId: claimId, requestKey } }), 'Expense claim posted');
    }

    handleAuthorize() {
        const paymentId = this.drawer.id;
        this.execute('PAYAUTH', paymentId, (requestKey) => authorizePayment({ paymentId, requestKey }), 'Reimbursement authorised');
    }

    handleRelease() {
        const paymentId = this.drawer.id;
        const providerRequestKey = this.keyFor('PROVIDER', paymentId);
        this.execute('PAYSUBMIT', paymentId, (requestKey) => submitPayment({ paymentId, providerRequestKey, requestKey }), 'Reimbursement released to the bank');
    }

    handleClear() {
        const paymentId = this.drawer.id;
        this.execute('PAYPOST', paymentId, (requestKey) => postPayment({ paymentId, requestKey }), 'Reimbursement cleared and posted');
    }

    handleReverseSettlement(event) {
        const settlementId = event.currentTarget.dataset.id;
        this.execute('SETTLE-REV', settlementId, (key) => reverseSettlement({ settlementId, reversalSettlementKey: key }), 'Settlement reversed');
    }

    // ---------- modals ----------

    openModal(kind, form) {
        this.form = form;
        this.formError = undefined;
        this.modal = kind;
    }

    handleApprove() {
        this.openModal('approve', { reason: '' });
    }

    handleReject() {
        this.openModal('reject', { reason: '' });
    }

    handleSettle() {
        const first = this.payableOptions[0];
        this.openModal('settle', { paymentId: first ? first.value : '', amount: String(this.settleDefault(first ? first.value : undefined)) });
    }

    settleDefault(paymentId) {
        const p = this.payments.find((x) => x.paymentId === paymentId);
        const remaining = Number(this.claim.remainingAmount) || 0;
        return p ? Math.min(remaining, Number(p.remainingAmount) || 0) : remaining;
    }

    get payableOptions() {
        return this.payments.filter((p) => p.processingState === 'Succeeded' && Number(p.remainingAmount) > 0)
            .map((p) => ({ value: p.paymentId, label: `${p.name}, ${formatNumber(p.remainingAmount)} left`, selected: p.paymentId === this.form.paymentId }));
    }

    get modalOpen() {
        return Boolean(this.modal);
    }

    get modalHeading() {
        return { approve: 'Approve expense claim', reject: 'Reject expense claim', settle: 'Apply reimbursement' }[this.modal];
    }

    get modalSub() {
        return {
            approve: 'Approved claims can be posted to record the amount owed to the claimant.',
            reject: 'The claimant sees your reason. A reason is required.',
            settle: 'Applies a cleared reimbursement payment to this claim.'
        }[this.modal];
    }

    get saveLabel() {
        return { approve: 'Approve', reject: 'Reject', settle: 'Apply payment' }[this.modal];
    }

    get saveClass() {
        return this.modal === 'reject' ? 'btn danger sab-modal-save' : 'btn primary sab-modal-save';
    }

    get isSettleModal() {
        return this.modal === 'settle';
    }

    get reasonLabel() {
        return this.modal === 'approve' ? 'Note (optional)' : 'Reason';
    }

    get isReasonModal() {
        return this.modal === 'approve' || this.modal === 'reject';
    }

    handleField(event) {
        const field = event.target.dataset.field;
        const form = { ...this.form, [field]: event.target.value };
        if (field === 'paymentId') {
            form.amount = String(this.settleDefault(event.target.value));
        }
        this.form = form;
    }

    handleCloseModal() {
        if (!this.busy) {
            this.modal = undefined;
        }
    }

    async handleSave() {
        const f = this.form;
        const claimId = this.drawer.id;
        const reasonText = String(f.reason || '').trim();
        let ok;
        if (this.modal === 'reject') {
            if (!reasonText) {
                this.formError = 'A reason is required.';
                return;
            }
            ok = await this.execute('REJECT', claimId, (requestKey) => rejectClaim({ claimId, requestKey, reason: reasonText }), 'Expense claim rejected');
        } else if (this.modal === 'approve') {
            ok = await this.execute('APPROVE', claimId, (requestKey) => approveClaim({ claimId, requestKey, reason: reasonText || null }), 'Expense claim approved');
        } else {
            if (!f.paymentId || !(Number(f.amount) > 0)) {
                this.formError = 'Choose a payment and an amount above zero.';
                return;
            }
            ok = await this.execute('SETTLE', `${claimId}|${f.paymentId}`, (settlementKey) => settleClaim({ request: { expenseClaimId: claimId, paymentId: f.paymentId,
                amount: Number(f.amount), settlementKey } }), 'Reimbursement applied to the claim');
        }
        if (ok) {
            this.modal = undefined;
        }
    }

    handleRetry() {
        this.load();
    }

    // ---------- document entry ----------

    editorOpen = false;
    editorKind = 'claim';
    editorRecordId;

    openEditor(kind, recordId) {
        this.editorKind = kind;
        this.editorRecordId = recordId;
        this.editorOpen = true;
    }

    handleEditorClose() {
        this.editorOpen = false;
    }

    async handleEditorSaved(event) {
        this.activeTab = 'claims';
        await this.load();
        await this.openClaim(event.detail.recordId);
    }

    get createDisabled() {
        return !(this.data && this.data.canSubmitClaim);
    }

    get createTitle() {
        return this.createDisabled ? `${this.personaLabel} role cannot create expense claims` : undefined;
    }

    handleNewClaim() {
        this.openEditor('claim');
    }

    handleEditClaim() {
        this.openEditor('claim', this.drawer.id);
    }
}
