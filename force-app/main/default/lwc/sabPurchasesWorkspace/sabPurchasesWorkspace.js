import { LightningElement, api } from 'lwc';
import getWorkspace from '@salesforce/apex/SABAccountsPayableWorkspaceController.getWorkspace';
import getPurchaseExtras from '@salesforce/apex/SABMoneyWorkspaceController.getPurchaseExtras';
import getDocumentDetail from '@salesforce/apex/SABMoneyWorkspaceController.getDocumentDetail';
import submitBill from '@salesforce/apex/SABSupplierBillService.submit';
import approveBill from '@salesforce/apex/SABSupplierBillService.approve';
import returnBill from '@salesforce/apex/SABSupplierBillService.returnToDraft';
import cancelBill from '@salesforce/apex/SABSupplierBillService.cancel';
import postBill from '@salesforce/apex/SABSupplierBillPostingService.postApprovedBill';
import { formatNumber, formatDate, chipClass, plural } from 'c/sabFormat';
import { reduceError, newKey, todayIso, daysBetween, hsteps, toast } from 'c/sabMoneyShared';

const STEPS = ['Draft', 'Submitted', 'Approved', 'Posted'];
const GROUPS = ['Overdue', 'This week', 'Next week', 'Later'];

/**
 * Purchases and payables in the Harbourline demo layout (G22G-3): figures, bills, payment schedule and suppliers, with a
 * bill drawer for submit, approve, return, cancel and post on SABSupplierBillService and SABSupplierBillPostingService.
 */
export default class SabPurchasesWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api periodKey;

    data;
    extras;
    errorMessage;
    isLoading = false;
    activeTab = 'bills';
    drawerOpen = false;
    selected;
    detail;
    detailError;
    busy = false;
    reasonOpen = false;
    reasonAction;
    reasonText = '';
    reasonError;
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
            this.openBill(value);
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
            const [ws, extras] = await Promise.all([
                getWorkspace({ companyId, asOfDate: todayIso(), statusFilter: 'All', supplierProfileId: null, includeSettled: true }),
                getPurchaseExtras({ companyId })
            ]);
            if (sequence !== this.loadSequence) {
                return;
            }
            this.data = ws;
            this.extras = extras;
            if (this.requestedRecordId) {
                this.openBill(this.requestedRecordId);
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

    get bills() {
        return (this.data && this.data.bills) || [];
    }

    get openPosted() {
        return this.bills.filter((b) => b.status === 'Posted' && b.outstandingAmount > 0);
    }

    // ---------- figures ----------

    get figures() {
        const today = todayIso();
        const due7 = this.openPosted.filter((b) => b.dueDate && daysBetween(today, b.dueDate) <= 7);
        const pending = this.bills.filter((b) => b.status === 'Submitted');
        const overdue = this.openPosted.filter((b) => b.isOverdue);
        const sum = (list, field) => list.reduce((s, b) => s + (Number(b[field]) || 0), 0);
        return [
            { key: 'o', label: 'Payables outstanding', value: formatNumber(this.data.totalOutstanding, 0), unit: this.cur, sub: `${plural(this.openPosted.length, 'posted bill')} unpaid` },
            { key: 'd', label: 'Due in the next 7 days', value: formatNumber(sum(due7, 'outstandingAmount'), 0), unit: this.cur, sub: plural(due7.length, 'bill') },
            { key: 'a', label: 'Waiting for approval', value: String(pending.length), unit: '', sub: `${formatNumber(sum(pending, 'totalAmount'), 0)} ${this.cur} in total` },
            { key: 'v', label: 'Overdue', value: formatNumber(sum(overdue, 'outstandingAmount'), 0), unit: this.cur,
                bold: overdue.length ? plural(overdue.length, 'bill') : '', text: overdue.length ? ' past due' : 'Nothing overdue' }
        ].map((f) => ({ ...f, hasUnit: Boolean(f.unit), hasBold: Boolean(f.bold), subText: f.sub || f.text }));
    }

    get buckets() {
        const d = this.data;
        return [d.currentAmount, d.days1To30Amount, d.days31To60Amount, d.days61To90Amount, d.days91PlusAmount];
    }

    // ---------- tabs ----------

    get tabs() {
        return [
            { id: 'bills', label: 'Bills', count: this.bills.length },
            { id: 'sched', label: 'Payment schedule', count: '' },
            { id: 'sup', label: 'Suppliers', count: ((this.extras && this.extras.suppliers) || []).length },
            { id: 'po', label: 'Purchase orders', count: '' }
        ].filter((t) => t.id !== 'po' || this.purchasingOn).map((t) => ({ ...t, hasCount: t.count !== '', className: t.id === this.activeTab ? 'tab active' : 'tab', selected: t.id === this.activeTab ? 'true' : 'false' }));
    }

    handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    get isBills() {
        return this.activeTab === 'bills';
    }

    get isSchedule() {
        return this.activeTab === 'sched';
    }

    get purchasingOn() {
        return !((this.caps && this.caps.disabledFeatures) || []).includes('PURCHASING');
    }

    get isOrders() {
        return this.activeTab === 'po';
    }

    billState(b) {
        if (b.status !== 'Posted') {
            return b.status;
        }
        if (b.outstandingAmount <= 0) {
            return 'Paid';
        }
        if (b.isOverdue) {
            return 'Overdue';
        }
        return b.allocatedAmount > 0 ? 'Part Paid' : 'Posted';
    }

    get billRows() {
        return this.bills.map((b) => {
            const state = this.billState(b);
            return {
                ...b,
                dateText: formatDate(b.documentDate),
                dueText: formatDate(b.dueDate),
                totalText: formatNumber(b.totalAmount),
                balanceText: b.status === 'Posted' ? formatNumber(b.outstandingAmount) : '\u2014',
                approvalText: b.status === 'Submitted' ? 'Waiting for approval' : '\u2014',
                state,
                chip: chipClass(state)
            };
        });
    }

    get hasBills() {
        return this.billRows.length > 0;
    }

    get scheduleGroups() {
        const today = todayIso();
        const week = (due) => {
            const n = daysBetween(today, due);
            if (n < 0) {
                return 'Overdue';
            }
            return n <= 7 ? 'This week' : n <= 14 ? 'Next week' : 'Later';
        };
        const open = [...this.openPosted].sort((a, b) => (a.dueDate < b.dueDate ? -1 : 1));
        return GROUPS.map((g) => {
            const rows = open.filter((b) => week(b.dueDate) === g).map((b) => ({ ...b, dueText: formatDate(b.dueDate), amountText: formatNumber(b.outstandingAmount) }));
            return { name: g, rows, totalText: formatNumber(rows.reduce((s, b) => s + b.outstandingAmount, 0)) };
        }).filter((g) => g.rows.length);
    }

    get hasSchedule() {
        return this.scheduleGroups.length > 0;
    }

    get supplierRows() {
        const owed = {};
        const count = {};
        this.openPosted.forEach((b) => {
            owed[b.supplierProfileId] = (owed[b.supplierProfileId] || 0) + b.outstandingAmount;
            count[b.supplierProfileId] = (count[b.supplierProfileId] || 0) + 1;
        });
        return ((this.extras && this.extras.suppliers) || []).map((s) => ({
            ...s,
            openText: String(count[s.partyProfileId] || 0),
            owedText: formatNumber(owed[s.partyProfileId] || 0)
        }));
    }

    get hasSuppliers() {
        return this.supplierRows.length > 0;
    }

    // ---------- drawer ----------

    handleRow(event) {
        if (event.type === 'keydown') {
            if (event.key !== 'Enter' && event.key !== ' ') {
                return;
            }
            event.preventDefault();
        }
        this.openBill(event.currentTarget.dataset.id);
    }

    async openBill(billId) {
        const bill = this.bills.find((b) => b.billId === billId);
        if (!bill) {
            return;
        }
        this.selected = bill;
        this.detail = undefined;
        this.detailError = undefined;
        this.drawerOpen = true;
        try {
            this.detail = await getDocumentDetail({ companyId: this.currentCompanyId, documentId: billId });
        } catch (error) {
            this.detailError = reduceError(error);
        }
    }

    handleCloseDrawer() {
        this.drawerOpen = false;
    }

    get drawerHeading() {
        return this.selected ? this.selected.billNumber : '';
    }

    get drawerSub() {
        const b = this.selected;
        return b ? [b.supplierName, b.vendorReference ? `ref ${b.vendorReference}` : null, `due ${formatDate(b.dueDate)}`].filter(Boolean).join(', ') : '';
    }

    get personaLabel() {
        return (this.persona && this.persona.label) || 'Your';
    }

    get view() {
        const b = this.selected;
        const d = this.detail || { lines: [], allocations: [] };
        const index = STEPS.indexOf(b.status);
        const ex = this.extras || {};
        const approveReason = !ex.canApprove ? `${this.personaLabel} role cannot approve bills` : undefined;
        const postReason = !ex.canPost ? `${this.personaLabel} role cannot post bills` : undefined;
        const editReason = !ex.canEdit ? `${this.personaLabel} role cannot change bills` : undefined;
        return {
            steps: hsteps(STEPS, index < 0 ? 0 : index < 3 ? index : 4),
            cancelled: b.status === 'Cancelled',
            overdue: this.billState(b) === 'Overdue',
            overdueText: `${b.daysPastDue} days overdue, ${formatNumber(b.outstandingAmount)} ${this.cur} still owed.`,
            lines: (d.lines || []).map((l, i) => ({ ...l, key: `l${i}`, qtyText: l.quantity === null || l.quantity === undefined ? '' : String(l.quantity),
                priceText: formatNumber(l.unitPrice), netText: formatNumber(l.netAmount), account: [l.accountCode, l.accountName].filter(Boolean).join(' ') })),
            hasLines: (d.lines || []).length > 0,
            facts: [['Subtotal', formatNumber(d.subtotal)], ['Tax', formatNumber(d.taxTotal)], ['Total', `${formatNumber(b.totalAmount)} ${b.transactionCurrency || this.cur}`],
                ['Paid', formatNumber(b.allocatedAmount)], ['Balance', formatNumber(b.status === 'Posted' ? b.outstandingAmount : b.totalAmount)]]
                .map(([label, value]) => ({ key: label, valueKey: `${label}-v`, label, value })),
            allocations: (d.allocations || []).map((a) => ({ ...a, key: a.allocationId, dateText: formatDate(a.allocationDate), amountText: formatNumber(a.amount) })),
            hasAllocations: (d.allocations || []).length > 0,
            isDraft: b.status === 'Draft',
            isSubmitted: b.status === 'Submitted',
            isApproved: b.status === 'Approved',
            editDisabled: this.busy || Boolean(editReason),
            editTitle: editReason,
            canEdit: !editReason,
            approveDisabled: this.busy || Boolean(approveReason),
            approveTitle: approveReason,
            postDisabled: this.busy || Boolean(postReason),
            postTitle: postReason
        };
    }

    async run(call, message) {
        this.busy = true;
        try {
            await call();
            toast(this, message);
            this.drawerOpen = false;
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
        const billId = this.selected.billId;
        this.run(() => submitBill({ billId, requestKey: newKey('BILL-SUBMIT', billId) }), `${this.selected.billNumber} submitted for approval`);
    }

    handleApprove() {
        const billId = this.selected.billId;
        this.run(() => approveBill({ billId, requestKey: newKey('BILL-APPROVE', billId), reason: null }), `${this.selected.billNumber} approved`);
    }

    handlePost() {
        const billId = this.selected.billId;
        this.run(() => postBill({ request: { supplierBillId: billId, requestKey: newKey('BILL-POST', billId) } }), `${this.selected.billNumber} posted`);
    }

    handleReturn() {
        this.openReason('return');
    }

    handleCancel() {
        this.openReason('cancel');
    }

    openReason(action) {
        this.reasonAction = action;
        this.reasonText = '';
        this.reasonError = undefined;
        this.reasonOpen = true;
        return Promise.resolve().then(() => {
            const area = this.template.querySelector('.sab-reason');
            if (area) {
                area.value = '';
            }
        });
    }

    get reasonHeading() {
        return this.reasonAction === 'cancel' ? 'Cancel bill' : 'Return bill to draft';
    }

    get reasonSaveLabel() {
        return this.reasonAction === 'cancel' ? 'Cancel bill' : 'Return to draft';
    }

    handleReasonInput(event) {
        this.reasonText = event.target.value;
    }

    handleCloseReason() {
        if (!this.busy) {
            this.reasonOpen = false;
        }
    }

    async handleReasonSave() {
        const billId = this.selected.billId;
        const reason = this.reasonText.trim();
        if (!reason) {
            this.reasonError = 'A reason is required.';
            return;
        }
        const ok = this.reasonAction === 'cancel'
            ? await this.run(() => cancelBill({ billId, requestKey: newKey('BILL-CANCEL', billId), reason }), `${this.selected.billNumber} cancelled`)
            : await this.run(() => returnBill({ billId, requestKey: newKey('BILL-RETURN', billId), reason }), `${this.selected.billNumber} returned to draft`);
        if (ok) {
            this.reasonOpen = false;
        }
    }

    handleRetry() {
        this.load();
    }

    // ---------- document entry ----------

    editorOpen = false;
    editorKind = 'bill';
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
        this.activeTab = 'bills';
        await this.load();
    }

    get createDisabled() {
        return !(this.extras && this.extras.canEdit);
    }

    get createTitle() {
        return this.createDisabled ? `${this.personaLabel} role cannot create bills` : undefined;
    }

    handleNewBill() {
        this.openEditor('bill');
    }

    handleEditBill() {
        this.openEditor(this.selected.documentType === 'Supplier Credit' ? 'supplierCredit' : 'bill', this.selected.billId);
    }
}
