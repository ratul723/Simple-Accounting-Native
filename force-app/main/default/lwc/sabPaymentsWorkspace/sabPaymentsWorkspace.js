import { LightningElement, api } from 'lwc';
import getPayments from '@salesforce/apex/SABMoneyWorkspaceController.getPayments';
import authorizeReceipt from '@salesforce/apex/SABCustomerReceiptService.authorize';
import submitReceipt from '@salesforce/apex/SABCustomerReceiptService.submitForProcessing';
import failReceipt from '@salesforce/apex/SABCustomerReceiptService.markFailed';
import retryReceipt from '@salesforce/apex/SABCustomerReceiptService.retryFailed';
import postReceipt from '@salesforce/apex/SABCustomerReceiptPostingService.recordSucceededAndPost';
import authorizePayment from '@salesforce/apex/SABSupplierPaymentService.authorize';
import submitPayment from '@salesforce/apex/SABSupplierPaymentService.submitForExecution';
import failPayment from '@salesforce/apex/SABSupplierPaymentService.markFailed';
import retryPayment from '@salesforce/apex/SABSupplierPaymentService.retryFailed';
import postPayment from '@salesforce/apex/SABSupplierPaymentPostingService.recordSucceededAndPost';
import allocateReceipt from '@salesforce/apex/SABCustomerReceiptAllocationService.allocateToInvoices';
import allocateDisbursement from '@salesforce/apex/SABPaymentActionService.allocateDisbursement';
import authorizeForeign from '@salesforce/apex/SABForeignCurrencySettlementService.authorizeForeignPayment';
import submitForeign from '@salesforce/apex/SABForeignCurrencySettlementService.submitForeignPayment';
import postForeign from '@salesforce/apex/SABForeignCurrencySettlementService.postForeignPayment';
import { formatNumber, formatDate, chipClass, plural } from 'c/sabFormat';
import { reduceError, newKey, todayIso, hsteps, toast } from 'c/sabMoneyShared';

const STATES = ['Draft', 'Authorized', 'Submitted', 'Succeeded'];

/** Shorter wording for the long settlement-service messages users hit most often. */
export function friendly(message) {
    const text = String(message || '');
    if (/must match the bank account currency/i.test(text)) {
        return 'This payment is in a foreign currency, so it uses an approved exchange rate rather than the bank currency. Add a rate in Foreign exchange > Exchange rates if none exists.';
    }
    const rate = text.match(/No approved (\w+) exchange rate exists for ([A-Z]{3}) to ([A-Z]{3})/);
    if (rate) {
        return `No approved ${rate[1]} rate from ${rate[2]} to ${rate[3]} for this date. Add one in Foreign exchange > Exchange rates.`;
    }
    if (/^No approved/i.test(text)) {
        return 'No approved exchange rate for this date. Add one in Foreign exchange > Exchange rates.';
    }
    return text;
}

/**
 * Payments in the Harbourline demo layout (G22G-3): receipts and disbursements with their processing lifecycle
 * (authorise, release, clear and post, fail, retry) and receipt allocation to invoices, on the existing receipt and
 * supplier payment services, unchanged.
 */
export default class SabPaymentsWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api periodKey;

    data;
    errorMessage;
    isLoading = false;
    activeTab = 'all';
    drawerOpen = false;
    selectedId;
    busy = false;
    allocations = {};
    failOpen = false;
    failReason = '';
    failError;
    loadSequence = 0;
    currentCompanyId;
    requestedRecordId;

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

    @api
    get recordId() {
        return this.requestedRecordId;
    }
    set recordId(value) {
        this.requestedRecordId = value;
        if (value && this.data) {
            this.openPayment(value);
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
            const result = await getPayments({ companyId });
            if (sequence !== this.loadSequence) {
                return;
            }
            this.data = result;
            if (this.requestedRecordId) {
                this.openPayment(this.requestedRecordId);
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
        return (this.data && this.data.currencyCode) || this.currencyCode || '';
    }

    get payments() {
        return (this.data && this.data.payments) || [];
    }

    needsAllocation(p) {
        return p.state === 'Succeeded' && !p.managedBy && p.amount - p.allocated > 0;
    }

    /** Payments in another currency are processed by the foreign-currency settlement service with an approved rate. */
    isForeign(p) {
        return Boolean(p && p.currencyCode && this.data && this.data.currencyCode && p.currencyCode !== this.data.currencyCode);
    }

    // ---------- figures, banner, tabs ----------

    get figures() {
        const d = this.data;
        return [
            { key: 'r', label: 'Received this month', value: formatNumber(d.receivedThisMonth, 0), unit: this.cur, sub: 'Cleared receipts' },
            { key: 'p', label: 'Paid out this month', value: formatNumber(d.paidThisMonth, 0), unit: this.cur, sub: 'Submitted and cleared' },
            { key: 'u', label: 'Unallocated receipts', value: formatNumber(d.unallocatedReceipts, 0), unit: this.cur, sub: `${plural(d.unallocatedReceiptCount, 'receipt')} to apply` },
            { key: 'a', label: 'Awaiting release', value: formatNumber(d.awaitingRelease, 0), unit: this.cur, sub: `${d.awaitingReleaseCount} authorised by finance` }
        ];
    }

    get failed() {
        return this.payments.filter((p) => p.state === 'Failed');
    }

    get hasFailed() {
        return this.failed.length > 0;
    }

    get failedTitle() {
        return `${plural(this.failed.length, 'payment')} failed at the bank`;
    }

    get failedText() {
        return `${this.failed.map((p) => p.paymentNumber).join(', ')} needs attention. Fix the payee details and retry, or leave it failed.`;
    }

    handleReviewFailed() {
        this.openPayment(this.failed[0].paymentId);
    }

    get tabs() {
        const p = this.payments;
        return [
            { id: 'all', label: 'All', count: p.length },
            { id: 'rec', label: 'Receipts', count: '' },
            { id: 'dis', label: 'Disbursements', count: '' },
            { id: 'un', label: 'Needs allocation', count: p.filter((x) => this.needsAllocation(x)).length }
        ].map((t) => ({ ...t, hasCount: t.count !== '', className: t.id === this.activeTab ? 'tab active' : 'tab', selected: t.id === this.activeTab ? 'true' : 'false' }));
    }

    handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    get rows() {
        return this.payments
            .filter((p) => this.activeTab === 'all' || (this.activeTab === 'rec' && p.direction === 'Receipt') ||
                (this.activeTab === 'dis' && p.direction === 'Disbursement') || (this.activeTab === 'un' && this.needsAllocation(p)))
            .map((p) => ({
                ...p,
                dateText: formatDate(p.effectiveDate),
                amountText: formatNumber(p.direction === 'Receipt' ? p.amount : -p.amount),
                allocatedText: p.allocated >= p.amount ? 'Fully' : p.allocated ? formatNumber(p.allocated) : 'None',
                allocatedClass: p.allocated >= p.amount ? 'small up' : p.allocated ? 'num' : 'small down',
                chip: chipClass(p.state)
            }));
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    // ---------- drawer ----------

    handleRow(event) {
        if (event.type === 'keydown') {
            if (event.key !== 'Enter' && event.key !== ' ') {
                return;
            }
            event.preventDefault();
        }
        this.openPayment(event.currentTarget.dataset.id);
    }

    openPayment(paymentId) {
        const p = this.payments.find((x) => x.paymentId === paymentId);
        if (!p) {
            return;
        }
        this.selectedId = paymentId;
        this.allocations = {};
        this.drawerOpen = true;
    }

    handleCloseDrawer() {
        this.drawerOpen = false;
    }

    get selected() {
        return this.payments.find((p) => p.paymentId === this.selectedId);
    }

    get drawerHeading() {
        return this.selected ? this.selected.paymentNumber : '';
    }

    get drawerSub() {
        const p = this.selected;
        return p ? `${p.direction} ${p.direction === 'Receipt' ? 'from' : 'to'} ${p.partyName || 'unknown party'}, ${formatDate(p.effectiveDate)}` : '';
    }

    get personaLabel() {
        return (this.persona && this.persona.label) || 'Your';
    }

    get view() {
        const p = this.selected;
        const d = this.data;
        const index = STATES.indexOf(p.state);
        const remaining = p.amount - p.allocated;
        const managed = Boolean(p.managedBy);
        const approveReason = !d.canApprove ? `${this.personaLabel} role cannot authorise payments` : undefined;
        const postReason = !d.canPost ? `${this.personaLabel} role cannot post payments` : undefined;
        const editReason = !d.canEdit ? `${this.personaLabel} role cannot change payments` : undefined;
        const foreign = this.isForeign(p);
        const receipt = p.direction === 'Receipt';
        const documents = receipt ? d.openInvoices : d.openBills;
        const noun = receipt ? 'invoice' : 'bill';
        const openInvoices = p.state === 'Succeeded' && !managed && !foreign
            ? (documents || []).filter((i) => i.partyProfileId === p.partyProfileId).map((i) => ({
                ...i,
                dueText: formatDate(i.dueDate),
                outstandingText: formatNumber(i.outstanding),
                value: this.allocations[i.documentId] === undefined ? '' : this.allocations[i.documentId],
                label: `Allocate to ${i.documentNumber}`
            }))
            : [];
        const allocateReason = !receipt && d.canAllocate === false ? `${this.personaLabel} role cannot allocate payments` : undefined;
        return {
            steps: hsteps(STATES, index === 3 ? 4 : Math.max(0, index)),
            failed: p.state === 'Failed',
            managed,
            managedText: `This payment belongs to ${p.managedBy === 'Payroll' ? 'a payroll run' : 'an equity distribution'} and is processed from ${p.managedBy === 'Payroll' ? 'People & payroll' : 'Capital & equity'}.`,
            facts: [['Direction', p.direction], ['Party', p.partyName || '\u2014'], ['Value date', formatDate(p.effectiveDate)], ['Bank', p.bankName || '\u2014'],
                ['Method', p.method || '\u2014'], ['Reference', p.reference || '\u2014'], ['Amount', `${formatNumber(p.amount)} ${p.currencyCode || this.cur}`],
                ['Allocated', formatNumber(p.allocated)], ['Remaining', formatNumber(remaining)]]
                .map(([label, value]) => ({ key: label, valueKey: `${label}-v`, label, value })),
            allocations: (p.allocations || []).map((a) => ({ ...a, key: a.allocationId, dateText: formatDate(a.allocationDate), amountText: formatNumber(a.amount) })),
            hasAllocations: (p.allocations || []).length > 0,
            openInvoices,
            showAllocate: openInvoices.length > 0 && remaining > 0,
            noOpenInvoices: p.state === 'Succeeded' && !managed && !foreign && remaining > 0 && openInvoices.length === 0,
            noOpenText: receipt ? 'This customer has no open posted invoices to allocate to.' : 'This supplier has no open posted bills to allocate to.',
            allocateTitleText: `Allocate ${formatNumber(remaining)} to open ${noun}s`,
            documentLabel: receipt ? 'Invoice' : 'Bill',
            allocateDisabled: this.busy || Boolean(allocateReason),
            allocateTitle: allocateReason,
            foreign,
            foreignText: `This payment is in ${p.currencyCode}. Authorising it takes the approved Spot rate to ${d.currencyCode} for the value date, and it is allocated in Foreign exchange, which also posts the realized gain or loss.`,
            showForeignAllocate: foreign && p.state === 'Succeeded' && remaining > 0,
            remainingText: formatNumber(remaining),
            canAuthorize: !managed && p.state === 'Draft',
            canRelease: !managed && p.state === 'Authorized',
            canClear: !managed && p.state === 'Submitted',
            canRetry: !managed && !foreign && p.state === 'Failed',
            approveDisabled: this.busy || Boolean(approveReason),
            approveTitle: approveReason,
            editDisabled: this.busy || Boolean(editReason),
            editTitle: editReason,
            canEdit: !editReason,
            postDisabled: this.busy || Boolean(postReason),
            postTitle: postReason
        };
    }

    async run(call, message) {
        this.busy = true;
        try {
            await call();
            toast(this, message);
            await this.load();
            return true;
        } catch (error) {
            toast(this, friendly(reduceError(error)), 'bad');
            return false;
        } finally {
            this.busy = false;
        }
    }

    handleOpenFx() {
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'fx' }, bubbles: true, composed: true }));
    }

    get isReceipt() {
        return this.selected && this.selected.direction === 'Receipt';
    }

    get isForeignSelected() {
        return this.isForeign(this.selected);
    }

    handleAuthorize() {
        const paymentId = this.selectedId;
        const requestKey = newKey('PAY-AUTH', paymentId);
        if (this.isForeignSelected) {
            this.run(() => authorizeForeign({ paymentId, requestKey }), 'Foreign-currency payment authorised at the approved rate');
            return;
        }
        this.run(() => (this.isReceipt ? authorizeReceipt({ paymentId, requestKey }) : authorizePayment({ paymentId, requestKey })), 'Payment authorised');
    }

    handleRelease() {
        const paymentId = this.selectedId;
        const requestKey = newKey('PAY-SUBMIT', paymentId);
        const providerRequestKey = newKey('PROVIDER', paymentId);
        if (this.isForeignSelected) {
            this.run(() => submitForeign({ paymentId, providerRequestKey, requestKey }), 'Released to the bank');
            return;
        }
        this.run(() => (this.isReceipt ? submitReceipt({ paymentId, providerRequestKey, requestKey }) : submitPayment({ paymentId, providerRequestKey, requestKey })),
            'Released to the bank');
    }

    handleClear() {
        const paymentId = this.selectedId;
        const request = { paymentId, requestKey: newKey('PAY-POST', paymentId) };
        if (this.isForeignSelected) {
            this.run(() => postForeign({ paymentId, requestKey: request.requestKey }), 'Marked as cleared and posted');
            return;
        }
        this.run(() => (this.isReceipt ? postReceipt({ request }) : postPayment({ request })), 'Marked as cleared and posted');
    }

    handleRetry() {
        const paymentId = this.selectedId;
        const requestKey = newKey('PAY-RETRY', paymentId);
        this.run(() => (this.isReceipt ? retryReceipt({ paymentId, requestKey }) : retryPayment({ paymentId, requestKey })), 'Payment back to authorised for another attempt');
    }

    handleAllocationInput(event) {
        this.allocations = { ...this.allocations, [event.target.dataset.id]: event.target.value };
    }

    async handleAllocate() {
        const entries = Object.entries(this.allocations).filter(([, v]) => Number(v) > 0);
        const noun = this.isReceipt ? 'invoice' : 'bill';
        if (!entries.length) {
            toast(this, `Enter an amount for at least one ${noun}.`, 'bad');
            return;
        }
        const paymentId = this.selectedId;
        const call = this.isReceipt
            ? () => allocateReceipt({ receiptId: paymentId, requests: entries.map(([invoiceId, v]) => ({ invoiceId, allocatedAmount: Number(v), allocationDate: todayIso(),
                effectiveDate: todayIso(), notes: null })) })
            : () => allocateDisbursement({ paymentId, lines: entries.map(([supplierBillId, v]) => ({ supplierBillId, amount: Number(v) })),
                requestKey: newKey('PAY-ALLOC', paymentId) });
        const ok = await this.run(call, `Allocated to ${plural(entries.length, noun)}`);
        if (ok) {
            this.allocations = {};
        }
    }

    // ---------- fail modal ----------

    handleOpenFail() {
        this.failReason = '';
        this.failError = undefined;
        this.failOpen = true;
        return Promise.resolve().then(() => {
            const area = this.template.querySelector('.sab-fail-reason');
            if (area) {
                area.value = '';
            }
        });
    }

    handleFailInput(event) {
        this.failReason = event.target.value;
    }

    handleCloseFail() {
        if (!this.busy) {
            this.failOpen = false;
        }
    }

    async handleFailSave() {
        const reason = this.failReason.trim();
        if (!reason) {
            this.failError = 'A reason is required.';
            return;
        }
        const paymentId = this.selectedId;
        const requestKey = newKey('PAY-FAIL', paymentId);
        const ok = await this.run(() => (this.isReceipt ? failReceipt({ paymentId, requestKey, reason }) : failPayment({ paymentId, requestKey, reason })),
            'Payment marked as failed');
        if (ok) {
            this.failOpen = false;
        }
    }

    handleReload() {
        this.load();
    }

    // ---------- document entry ----------

    editorOpen = false;
    editorKind = 'receipt';
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
        this.requestedRecordId = event.detail.recordId;
        await this.load();
    }

    get createDisabled() {
        return !(this.data && this.data.canEdit);
    }

    get createTitle() {
        return this.createDisabled ? `${this.personaLabel} role cannot record payments` : undefined;
    }

    handleNewReceipt() {
        this.openEditor('receipt');
    }

    handleNewPayment() {
        this.openEditor('payment');
    }

    handleEditPayment() {
        this.openEditor(this.selected.direction === 'Receipt' ? 'receipt' : 'payment', this.selected.paymentId);
    }
}