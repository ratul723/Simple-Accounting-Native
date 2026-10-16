import { LightningElement, api } from 'lwc';
import getSales from '@salesforce/apex/SABMoneyWorkspaceController.getSales';
import getPayments from '@salesforce/apex/SABMoneyWorkspaceController.getPayments';
import getDocumentDetail from '@salesforce/apex/SABMoneyWorkspaceController.getDocumentDetail';
import postInvoice from '@salesforce/apex/SABInvoicePostingService.postApprovedInvoice';
import submitInvoice from '@salesforce/apex/SABDocumentEntryService.submitInvoice';
import approveInvoice from '@salesforce/apex/SABDocumentEntryService.approveInvoice';
import { formatNumber, formatDate, chipClass, plural } from 'c/sabFormat';
import { reduceError, newKey, documentState, hsteps, toast } from 'c/sabMoneyShared';

const POSTABLE = ['Approved', 'Issued'];
const STEPS = ['Draft', 'Submitted', 'Approved', 'Posted'];

/**
 * Sales and receivables in the Harbourline demo layout (G22G-3): figures, receivables aging, invoices, credit notes,
 * customers and receipts, with an invoice drawer that posts approved invoices through SABInvoicePostingService.
 */
export default class SabSalesWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api periodKey;

    data;
    receipts;
    errorMessage;
    isLoading = false;
    activeTab = 'inv';
    drawerOpen = false;
    selected;
    detail;
    detailError;
    busy = false;
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
            this.receipts = undefined;
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
            this.openDocument(value);
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
            const result = await getSales({ companyId });
            if (sequence !== this.loadSequence) {
                return;
            }
            this.data = result;
            if (this.activeTab === 'rec') {
                await this.loadReceipts();
            }
            if (this.requestedRecordId) {
                this.openDocument(this.requestedRecordId);
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

    async loadReceipts() {
        try {
            const result = await getPayments({ companyId: this.currentCompanyId });
            this.receipts = (result.payments || []).filter((p) => p.direction === 'Receipt');
        } catch (error) {
            this.receipts = [];
            toast(this, reduceError(error), 'bad');
        }
    }

    get showLoading() {
        return this.isLoading && !this.data && !this.errorMessage;
    }

    get cur() {
        return (this.data && this.data.currencyCode) || this.currencyCode || '';
    }

    // ---------- figures ----------

    get awaitingPosting() {
        return ((this.data && this.data.invoices) || []).filter((i) => POSTABLE.includes(i.status));
    }

    get figures() {
        const d = this.data;
        return [
            { key: 'o', label: 'Outstanding', value: formatNumber(d.totalOutstanding, 0), unit: this.cur, sub: `${plural(d.openCount, 'open invoice')}` },
            { key: 'd', label: 'Overdue', value: formatNumber(d.overdueAmount, 0), unit: this.cur, bold: plural(d.overdueCount, 'invoice'), text: ' past due' },
            { key: 'c', label: 'Collected this month', value: formatNumber(d.collectedThisMonth, 0), unit: this.cur, sub: 'Receipts that cleared' },
            { key: 'p', label: 'Awaiting posting', value: String(this.awaitingPosting.length), unit: '', sub: 'Approved invoices not yet posted' }
        ].map((f) => ({ ...f, hasUnit: Boolean(f.unit), hasBold: Boolean(f.bold) }));
    }

    get agingSub() {
        return `As of ${formatDate(new Date().toISOString().slice(0, 10))}, posted invoices after receipts and credits`;
    }

    get canOpenReports() {
        return Array.isArray(this.visibleWorkspaces) && this.visibleWorkspaces.includes('reports');
    }

    handleOpenReports() {
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'reports' }, bubbles: true, composed: true }));
    }

    // ---------- tabs ----------

    get tabs() {
        const d = this.data || {};
        return [
            { id: 'inv', label: 'Invoices', count: (d.invoices || []).length },
            { id: 'cn', label: 'Credit notes', count: (d.credits || []).length },
            { id: 'cust', label: 'Customers', count: (d.customers || []).length },
            { id: 'rec', label: 'Receipts', count: this.receipts ? this.receipts.length : '' }
        ].map((t) => ({ ...t, hasCount: t.count !== '', className: t.id === this.activeTab ? 'tab active' : 'tab', selected: t.id === this.activeTab ? 'true' : 'false' }));
    }

    async handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
        if (this.activeTab === 'rec' && !this.receipts) {
            await this.loadReceipts();
        }
    }

    get isInvoices() {
        return this.activeTab === 'inv';
    }

    get isCredits() {
        return this.activeTab === 'cn';
    }

    get isCustomers() {
        return this.activeTab === 'cust';
    }

    get isReceipts() {
        return this.activeTab === 'rec';
    }

    // ---------- rows ----------

    get invoiceRows() {
        return ((this.data && this.data.invoices) || []).map((i) => {
            const state = documentState(i);
            const posted = i.status === 'Posted' && i.outstanding !== null && i.outstanding !== undefined;
            return {
                ...i,
                issuedText: formatDate(i.documentDate),
                dueText: formatDate(i.dueDate),
                lateText: state === 'Overdue' ? `${i.daysPastDue} days late` : '',
                totalText: formatNumber(i.total),
                paidText: posted && i.total - i.outstanding > 0 ? formatNumber(i.total - i.outstanding) : '\u2014',
                balanceText: posted ? formatNumber(i.outstanding) : '\u2014',
                state,
                chip: chipClass(state)
            };
        });
    }

    get creditRows() {
        return ((this.data && this.data.credits) || []).map((c) => ({
            ...c,
            dateText: formatDate(c.documentDate),
            amountText: formatNumber(-Math.abs(c.total)),
            chip: chipClass(c.status)
        }));
    }

    get customerRows() {
        return ((this.data && this.data.customers) || []).map((c) => {
            const used = c.creditLimit ? Math.min(100, (c.outstanding / c.creditLimit) * 100) : null;
            return {
                ...c,
                limitText: c.creditLimit ? formatNumber(c.creditLimit, 0) : '\u2014',
                outstandingText: formatNumber(c.outstanding),
                hasUsed: used !== null,
                usedText: used === null ? '' : `${used.toFixed(0)}%`,
                meterClass: used > 80 ? 'meter bad' : used > 50 ? 'meter warn' : 'meter',
                meterStyle: `width:${used || 0}%`
            };
        });
    }

    get receiptRows() {
        return (this.receipts || []).map((p) => ({
            ...p,
            dateText: formatDate(p.effectiveDate),
            amountText: formatNumber(p.amount),
            allocatedText: p.allocated >= p.amount ? 'Fully' : p.allocated ? formatNumber(p.allocated) : 'None',
            allocatedClass: p.allocated >= p.amount ? 'small up' : p.allocated ? 'num' : 'small down',
            chip: chipClass(p.state)
        }));
    }

    get hasInvoices() {
        return this.invoiceRows.length > 0;
    }

    get hasCredits() {
        return this.creditRows.length > 0;
    }

    get hasCustomers() {
        return this.customerRows.length > 0;
    }

    get hasReceipts() {
        return this.receiptRows.length > 0;
    }

    // ---------- drawer ----------

    handleRow(event) {
        if (event.type === 'keydown') {
            if (event.key !== 'Enter' && event.key !== ' ') {
                return;
            }
            event.preventDefault();
        }
        this.openDocument(event.currentTarget.dataset.id);
    }

    async openDocument(documentId) {
        const all = [...((this.data && this.data.invoices) || []), ...((this.data && this.data.credits) || [])];
        const doc = all.find((d) => d.documentId === documentId);
        if (!doc) {
            return;
        }
        this.selected = doc;
        this.detail = undefined;
        this.detailError = undefined;
        this.drawerOpen = true;
        try {
            this.detail = await getDocumentDetail({ companyId: this.currentCompanyId, documentId });
        } catch (error) {
            this.detailError = reduceError(error);
        }
    }

    handleCloseDrawer() {
        this.drawerOpen = false;
    }

    get drawerHeading() {
        return this.selected ? this.selected.documentNumber : '';
    }

    get drawerSub() {
        const s = this.selected;
        return s ? [s.partyName, `issued ${formatDate(s.documentDate)}`, s.dueDate ? `due ${formatDate(s.dueDate)}` : null].filter(Boolean).join(', ') : '';
    }

    get view() {
        const s = this.selected;
        const d = this.detail || { lines: [], allocations: [] };
        const state = documentState(s);
        const index = STEPS.indexOf(s.status);
        const paid = s.outstanding !== null && s.outstanding !== undefined ? s.total - s.outstanding : 0;
        return {
            steps: hsteps(STEPS, index < 0 ? 0 : index < 3 ? index : 4),
            overdue: state === 'Overdue',
            overdueTitle: `${s.daysPastDue} days overdue`,
            overdueText: `${formatNumber(s.outstanding)} ${this.cur} still owed.`,
            lines: (d.lines || []).map((l, i) => ({ ...l, key: `l${i}`, qtyText: l.quantity === null || l.quantity === undefined ? '' : String(l.quantity),
                priceText: formatNumber(l.unitPrice), netText: formatNumber(l.netAmount), account: [l.accountCode, l.accountName].filter(Boolean).join(' ') })),
            hasLines: (d.lines || []).length > 0,
            facts: [
                ['Subtotal', formatNumber(d.subtotal)], ['Tax', formatNumber(d.taxTotal)], ['Total', `${formatNumber(d.total === undefined ? s.total : d.total)} ${this.cur}`],
                ['Paid and credited', formatNumber(paid)], ['Balance', formatNumber(s.status === 'Posted' ? s.outstanding : s.total)]
            ].map(([label, value]) => ({ key: label, valueKey: `${label}-v`, label, value })),
            allocations: (d.allocations || []).map((a) => ({ ...a, key: a.allocationId, dateText: formatDate(a.allocationDate), amountText: formatNumber(a.amount) })),
            hasAllocations: (d.allocations || []).length > 0,
            canPost: POSTABLE.includes(s.status),
            isDraft: s.status === 'Draft',
            isSubmitted: s.status === 'Submitted'
        };
    }

    get postDisabled() {
        return this.busy || !(this.data && this.data.canPost);
    }

    get postTitle() {
        return this.data && this.data.canPost ? undefined : `${(this.persona && this.persona.label) || 'Your'} role cannot post invoices`;
    }

    async handlePost() {
        if (this.postDisabled) {
            return;
        }
        this.busy = true;
        try {
            const invoiceId = this.selected.documentId;
            const result = await postInvoice({ request: { invoiceId, requestKey: newKey('INV-POST', invoiceId) } });
            toast(this, result && result.replay ? `${this.selected.documentNumber} was already posted` : `${this.selected.documentNumber} posted`);
            this.drawerOpen = false;
            await this.load();
        } catch (error) {
            toast(this, reduceError(error), 'bad');
        } finally {
            this.busy = false;
        }
    }

    handleRetry() {
        this.load();
    }

    // ---------- document entry ----------

    editorOpen = false;
    editorKind = 'invoice';
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

    get canCreate() {
        return Boolean(this.caps && this.caps.canCreateInvoice);
    }

    get createTitle() {
        return this.canCreate ? undefined : `${(this.persona && this.persona.label) || 'Your'} role cannot create invoices`;
    }

    get createDisabled() {
        return !this.canCreate;
    }

    handleNewInvoice() {
        this.openEditor('invoice');
    }

    handleNewCredit() {
        this.openEditor('credit');
    }

    handleEditDocument() {
        this.openEditor(this.selected.documentType === 'Credit Note' ? 'credit' : 'invoice', this.selected.documentId);
    }

    get approveTitle() {
        return this.data && this.data.canApprove ? undefined : `${(this.persona && this.persona.label) || 'Your'} role cannot approve invoices`;
    }

    get approveDisabled() {
        return this.busy || !(this.data && this.data.canApprove);
    }

    async runTransition(call, message) {
        this.busy = true;
        try {
            await call();
            toast(this, message);
            this.requestedRecordId = this.selected.documentId;
            await this.load();
        } catch (error) {
            toast(this, reduceError(error), 'bad');
        } finally {
            this.busy = false;
        }
    }

    handleSubmitInvoice() {
        const invoiceId = this.selected.documentId;
        if (!this.transitionKeys[`S${invoiceId}`]) {
            this.transitionKeys = { ...this.transitionKeys, [`S${invoiceId}`]: newKey('INV-SUBMIT', invoiceId) };
        }
        this.runTransition(() => submitInvoice({ invoiceId, requestKey: this.transitionKeys[`S${invoiceId}`] }), `${this.selected.documentNumber} submitted for approval`);
    }

    handleApproveInvoice() {
        const invoiceId = this.selected.documentId;
        if (!this.transitionKeys[`A${invoiceId}`]) {
            this.transitionKeys = { ...this.transitionKeys, [`A${invoiceId}`]: newKey('INV-APPROVE', invoiceId) };
        }
        this.runTransition(() => approveInvoice({ invoiceId, requestKey: this.transitionKeys[`A${invoiceId}`] }), `${this.selected.documentNumber} approved`);
    }

    transitionKeys = {};
}