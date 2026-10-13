import { LightningElement, api } from 'lwc';
import getWorkspace from '@salesforce/apex/SABPurchasingWorkspaceController.getWorkspace';
import getDetail from '@salesforce/apex/SABPurchasingWorkspaceController.getPurchaseOrderDetail';
import saveDraft from '@salesforce/apex/SABPurchaseOrderService.saveDraft';
import submitOrder from '@salesforce/apex/SABPurchaseOrderService.submit';
import approveOrder from '@salesforce/apex/SABPurchaseOrderService.approve';
import returnOrder from '@salesforce/apex/SABPurchaseOrderService.returnToDraft';
import cancelOrder from '@salesforce/apex/SABPurchaseOrderService.cancel';
import closeOrder from '@salesforce/apex/SABPurchaseOrderService.close';
import createReceipt from '@salesforce/apex/SABGoodsReceiptService.createReceipt';
import acceptReceipt from '@salesforce/apex/SABGoodsReceiptService.acceptReceipt';
import cancelReceipt from '@salesforce/apex/SABGoodsReceiptService.cancelReceipt';
import { formatNumber, formatDate, chipClass, plural } from 'c/sabFormat';
import { reduceError, newKey, todayIso, hsteps, toast } from 'c/sabMoneyShared';

const STEPS = ['Draft', 'Submitted', 'Approved', 'Received'];
const STEP_INDEX = { Draft: 0, Submitted: 1, Approved: 2, 'Part Received': 3, Received: 4, Closed: 4 };
const RECEIVABLE = ['Approved', 'Part Received'];

let lineSequence = 0;
const blankLine = () => ({ key: `p${++lineSequence}`, description: '', quantity: '1', unitPrice: '', departmentId: '', costCenterId: '' });

/**
 * Purchase orders and goods receipts for the Purchases and payables workspace (G22G-7b): order list, order drawer with
 * three-way match lines, receipts and bills, and draft, submit, approve, return, cancel, close and receive actions on
 * SABPurchaseOrderService and SABGoodsReceiptService, unchanged.
 */
export default class SabPurchaseOrders extends LightningElement {
    @api persona;

    data;
    errorMessage;
    isLoading = false;
    selectedId;
    detail;
    detailError;
    busy = false;
    modal;
    form = {};
    lines = [];
    receiptLines = [];
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
            this.selectedId = undefined;
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
            if (this.selectedId) {
                await this.openOrder(this.selectedId);
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
        return (this.data && this.data.functionalCurrency) || '';
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

    get summary() {
        const orders = (this.data && this.data.orders) || [];
        return `${plural(orders.filter((o) => RECEIVABLE.includes(o.status)).length, 'order')} waiting for goods, open commitment ${formatNumber(this.data.openCommitment)} ${this.cur}`;
    }

    get orderRows() {
        return ((this.data && this.data.orders) || []).map((o) => ({
            ...o,
            dateText: formatDate(o.orderDate),
            totalText: formatNumber(o.total),
            chip: chipClass(o.status, o.status === 'Draft' || o.status === 'Closed' || o.status === 'Cancelled' ? 'neutral' : o.status === 'Part Received' ? 'warn' : undefined)
        }));
    }

    get hasOrders() {
        return this.orderRows.length > 0;
    }

    get newDisabled() {
        return !this.can.manage;
    }

    get newTitle() {
        return this.reason(this.can.manage, 'create purchase orders');
    }

    // ---------- drawer ----------

    handleRow(event) {
        if (event.type === 'keydown') {
            if (event.key !== 'Enter' && event.key !== ' ') {
                return;
            }
            event.preventDefault();
        }
        this.openOrder(event.currentTarget.dataset.id);
    }

    async openOrder(purchaseOrderId) {
        this.selectedId = purchaseOrderId;
        this.detailError = undefined;
        try {
            this.detail = await getDetail({ purchaseOrderId });
        } catch (error) {
            this.detail = undefined;
            this.detailError = reduceError(error);
        }
    }

    handleCloseDrawer() {
        this.selectedId = undefined;
    }

    get drawerOpen() {
        return Boolean(this.selectedId);
    }

    get order() {
        return this.detail && this.detail.purchaseOrder;
    }

    get drawerHeading() {
        return this.order ? this.order.name : '';
    }

    get drawerSub() {
        const o = this.order;
        return o ? `${o.supplierName}, ordered ${formatDate(o.orderDate)}, ${formatNumber(o.total)} ${o.currencyCode || this.cur}` : '';
    }

    get view() {
        const o = this.order;
        const d = this.detail;
        const index = STEP_INDEX[o.status] === undefined ? 0 : STEP_INDEX[o.status];
        return {
            steps: hsteps(STEPS, index),
            cancelled: o.status === 'Cancelled',
            lines: (d.lines || []).map((l) => ({
                ...l,
                qtyText: formatNumber(l.quantity, 2),
                priceText: formatNumber(l.unitPrice),
                amountText: formatNumber(l.lineAmount),
                receivedText: formatNumber(l.receivedQuantity, 2),
                remainingText: formatNumber(l.remainingQuantity, 2),
                billedText: formatNumber(l.billedQuantity, 2),
                matchChip: chipClass(l.matchStatus || 'Open', l.matchStatus === 'Matched' ? 'good' : 'neutral'),
                matchText: l.matchStatus || 'Open'
            })),
            receipts: (d.receipts || []).map((r) => ({
                ...r,
                dateText: formatDate(r.receiptDate),
                qtyText: formatNumber(r.totalQuantity, 2),
                chip: chipClass(r.status, r.status === 'Draft' ? 'neutral' : undefined),
                isDraft: r.status === 'Draft'
            })),
            hasReceipts: (d.receipts || []).length > 0,
            bills: (d.bills || []).map((b) => ({ ...b, chip: chipClass(b.status) })),
            hasBills: (d.bills || []).length > 0,
            isDraft: o.status === 'Draft',
            isSubmitted: o.status === 'Submitted',
            canReceive: RECEIVABLE.includes(o.status),
            canCancel: ['Draft', 'Submitted', 'Approved'].includes(o.status),
            manageDisabled: this.busy || !this.can.manage,
            manageTitle: this.reason(this.can.manage, 'change purchase orders'),
            approveDisabled: this.busy || !this.can.approve,
            approveTitle: this.reason(this.can.approve, 'approve purchase orders'),
            receiveDisabled: this.busy || !this.can.receive,
            receiveTitle: this.reason(this.can.receive, 'receive goods')
        };
    }

    // ---------- actions ----------

    keyFor(action, recordId) {
        const name = `${action}|${recordId}`;
        if (!this.requestKeys[name]) {
            this.requestKeys = { ...this.requestKeys, [name]: newKey(`PO-${action}`, recordId) };
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
        const id = this.selectedId;
        this.execute('SUBMIT', id, (requestKey) => submitOrder({ purchaseOrderId: id, requestKey }), `${this.order.name} submitted for approval`);
    }

    handleApprove() {
        const id = this.selectedId;
        this.execute('APPROVE', id, (requestKey) => approveOrder({ purchaseOrderId: id, requestKey }), `${this.order.name} approved`);
    }

    handleAcceptReceipt(event) {
        const goodsReceiptId = event.currentTarget.dataset.id;
        this.execute('ACCEPT', goodsReceiptId, (requestKey) => acceptReceipt({ goodsReceiptId, requestKey }), 'Goods receipt accepted');
    }

    // ---------- modals ----------

    openModal(kind, form) {
        this.form = form;
        this.formError = undefined;
        this.modal = kind;
    }

    handleNew() {
        this.lines = [blankLine()];
        this.openModal('order', { purchaseOrderId: null, supplierProfileId: ((this.data.suppliers || [])[0] || {}).value || '', orderDate: todayIso(), currencyCode: this.cur });
    }

    handleEdit() {
        const o = this.order;
        this.lines = (this.detail.lines || []).map((l) => ({ ...blankLine(), description: l.description || '', quantity: l.quantity === null || l.quantity === undefined ? '' : String(l.quantity),
            unitPrice: l.unitPrice === null || l.unitPrice === undefined ? '' : String(l.unitPrice), departmentId: l.departmentId || '', costCenterId: l.costCenterId || '' }));
        if (!this.lines.length) {
            this.lines = [blankLine()];
        }
        this.openModal('order', { purchaseOrderId: o.purchaseOrderId, supplierProfileId: o.supplierProfileId, orderDate: o.orderDate, currencyCode: o.currencyCode || this.cur });
    }

    handleReceive() {
        this.receiptLines = (this.detail.lines || []).filter((l) => Number(l.remainingQuantity) > 0).map((l) => ({
            purchaseOrderLineId: l.lineId, description: l.description, remainingText: formatNumber(l.remainingQuantity, 2), acceptedQuantity: String(l.remainingQuantity), label: `Quantity for ${l.description}`
        }));
        this.openModal('receive', { receiptDate: todayIso() });
    }

    handleReasonAction(event) {
        const kind = event.currentTarget.dataset.kind;
        this.openModal(kind, { reason: '', recordId: event.currentTarget.dataset.id || this.selectedId });
    }

    get modalOpen() {
        return Boolean(this.modal);
    }

    get modalHeading() {
        return { order: this.form.purchaseOrderId ? 'Edit purchase order' : 'New purchase order', receive: 'Receive goods', return: 'Return to draft',
            cancel: 'Cancel purchase order', close: 'Close purchase order', cancelReceipt: 'Cancel goods receipt' }[this.modal];
    }

    get modalSub() {
        return {
            order: 'Draft orders can be edited. Submitting sends the order for approval.',
            receive: 'Record what arrived. Accepting the receipt updates received quantities for the three-way match.',
            return: 'Sends the order back to its preparer. A reason is required.',
            cancel: 'Cancels the order and its open commitment. A reason is required.',
            close: 'Closes the order to further receipts and bills. A reason is required.',
            cancelReceipt: 'Cancels this draft receipt. A reason is required.'
        }[this.modal];
    }

    get saveLabel() {
        return { order: 'Save draft', receive: 'Create receipt', return: 'Return to draft', cancel: 'Cancel order', close: 'Close order', cancelReceipt: 'Cancel receipt' }[this.modal];
    }

    get saveClass() {
        return ['cancel', 'close', 'cancelReceipt'].includes(this.modal) ? 'btn danger sab-modal-save' : 'btn primary sab-modal-save';
    }

    get isOrderModal() {
        return this.modal === 'order';
    }

    get isReceiveModal() {
        return this.modal === 'receive';
    }

    get isReasonModal() {
        return ['return', 'cancel', 'close', 'cancelReceipt'].includes(this.modal);
    }

    choices(list, selected) {
        return (list || []).map((o) => ({ value: o.value, label: o.label, selected: o.value === selected }));
    }

    get supplierOptions() {
        return this.choices(this.data && this.data.suppliers, this.form.supplierProfileId);
    }

    get lineRows() {
        return this.lines.map((l, i) => ({
            ...l,
            index: i,
            amountText: formatNumber((Number(l.quantity) || 0) * (Number(l.unitPrice) || 0)),
            departmentOptions: this.choices(this.data.departments, l.departmentId),
            costCenterOptions: this.choices(this.data.costCenters, l.costCenterId)
        }));
    }

    get linesTotal() {
        return formatNumber(this.lines.reduce((s, l) => s + (Number(l.quantity) || 0) * (Number(l.unitPrice) || 0), 0));
    }

    handleField(event) {
        this.form = { ...this.form, [event.target.dataset.field]: event.target.value };
    }

    handleLineField(event) {
        const index = Number(event.target.dataset.index);
        const field = event.target.dataset.field;
        this.lines = this.lines.map((l, i) => (i === index ? { ...l, [field]: event.target.value } : l));
    }

    handleAddLine() {
        this.lines = [...this.lines, blankLine()];
    }

    handleRemoveLine(event) {
        const index = Number(event.currentTarget.dataset.index);
        this.lines = this.lines.filter((l, i) => i !== index);
    }

    handleReceiptQty(event) {
        const id = event.target.dataset.id;
        this.receiptLines = this.receiptLines.map((l) => (l.purchaseOrderLineId === id ? { ...l, acceptedQuantity: event.target.value } : l));
    }

    handleCloseModal() {
        if (!this.busy) {
            this.modal = undefined;
        }
    }

    async handleSave() {
        const f = this.form;
        if (this.isReasonModal && !String(f.reason || '').trim()) {
            this.formError = 'A reason is required.';
            return;
        }
        if (this.modal === 'order' || this.modal === 'receive') {
            this.busy = true;
            let id;
            try {
                if (this.modal === 'order') {
                    id = await saveDraft({ request: { purchaseOrderId: f.purchaseOrderId, companyId: this.currentCompanyId, supplierProfileId: f.supplierProfileId || null,
                        orderDate: f.orderDate || null, currencyCode: f.currencyCode || null,
                        lines: this.lines.filter((l) => l.description || l.unitPrice).map((l, i) => ({ lineNumber: i + 1, description: l.description,
                            quantity: l.quantity === '' ? null : Number(l.quantity), unitPrice: l.unitPrice === '' ? null : Number(l.unitPrice),
                            departmentId: l.departmentId || null, costCenterId: l.costCenterId || null })) } });
                    toast(this, 'Purchase order saved as draft');
                } else {
                    id = this.selectedId;
                    await createReceipt({ request: { purchaseOrderId: id, receiptDate: f.receiptDate || null,
                        lines: this.receiptLines.filter((l) => Number(l.acceptedQuantity) > 0).map((l) => ({ purchaseOrderLineId: l.purchaseOrderLineId,
                            acceptedQuantity: Number(l.acceptedQuantity), serviceAccepted: null, comment: null })) } });
                    toast(this, 'Goods receipt created, accept it to update the order');
                }
                this.modal = undefined;
                this.selectedId = id;
            } catch (error) {
                this.formError = reduceError(error);
                this.busy = false;
                return;
            }
            this.busy = false;
            await this.load();
            return;
        }
        const recordId = f.recordId;
        const reasonText = f.reason.trim();
        const calls = {
            return: ['RETURN', () => returnOrder({ purchaseOrderId: recordId, reason: reasonText, requestKey: this.keyFor('RETURN', recordId) }), 'Purchase order returned to draft'],
            cancel: ['CANCEL', () => cancelOrder({ purchaseOrderId: recordId, reason: reasonText, requestKey: this.keyFor('CANCEL', recordId) }), 'Purchase order cancelled'],
            close: ['CLOSE', () => closeOrder({ purchaseOrderId: recordId, reason: reasonText, requestKey: this.keyFor('CLOSE', recordId) }), 'Purchase order closed'],
            cancelReceipt: ['RECEIPT-CANCEL', () => cancelReceipt({ goodsReceiptId: recordId, reason: reasonText, requestKey: this.keyFor('RECEIPT-CANCEL', recordId) }),
                'Goods receipt cancelled']
        }[this.modal];
        const ok = await this.execute(calls[0], recordId, calls[1], calls[2]);
        if (ok) {
            this.modal = undefined;
        }
    }

    handleRetry() {
        this.load();
    }
}
