import { LightningElement, wire } from 'lwc';
import { subscribe, unsubscribe, MessageContext, APPLICATION_SCOPE } from 'lightning/messageService';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import COMPANY_CONTEXT_CHANNEL from '@salesforce/messageChannel/SABCompanyContext__c';

import getWorkspace from '@salesforce/apex/SABPurchasingWorkspaceController.getWorkspace';
import getPurchaseOrderDetail from '@salesforce/apex/SABPurchasingWorkspaceController.getPurchaseOrderDetail';
import saveDraft from '@salesforce/apex/SABPurchaseOrderService.saveDraft';
import submitOrder from '@salesforce/apex/SABPurchaseOrderService.submit';
import approveOrder from '@salesforce/apex/SABPurchaseOrderService.approve';
import returnToDraft from '@salesforce/apex/SABPurchaseOrderService.returnToDraft';
import cancelOrder from '@salesforce/apex/SABPurchaseOrderService.cancel';
import closeOrder from '@salesforce/apex/SABPurchaseOrderService.close';
import createReceipt from '@salesforce/apex/SABGoodsReceiptService.createReceipt';
import acceptReceipt from '@salesforce/apex/SABGoodsReceiptService.acceptReceipt';
import cancelReceipt from '@salesforce/apex/SABGoodsReceiptService.cancelReceipt';

const STORAGE_KEY = 'sabSelectedAccountingCompanyId';
const MONEY = { type: 'number', typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 2 } };
const QTY = { type: 'number', typeAttributes: { maximumFractionDigits: 4 } };
const CANCELLABLE = ['Draft', 'Submitted', 'Approved'];
const CLOSABLE = ['Approved', 'Part Received', 'Received'];
const RECEIVABLE = ['Approved', 'Part Received'];

const ORDER_COLUMNS = [
    { label: 'Order', fieldName: 'name' },
    { label: 'Supplier', fieldName: 'supplierName' },
    { label: 'Order Date', fieldName: 'orderDate', type: 'date-local' },
    { label: 'Currency', fieldName: 'currencyCode' },
    { label: 'Status', fieldName: 'status' },
    { label: 'Total', fieldName: 'total', ...MONEY }
];

const LINE_COLUMNS = [
    { label: '#', fieldName: 'lineNumber', type: 'number', initialWidth: 60 },
    { label: 'Description', fieldName: 'description' },
    { label: 'Ordered', fieldName: 'quantity', ...QTY },
    { label: 'Unit Price', fieldName: 'unitPrice', ...MONEY },
    { label: 'Received', fieldName: 'receivedQuantity', ...QTY },
    { label: 'Remaining', fieldName: 'remainingQuantity', ...QTY },
    { label: 'Billed', fieldName: 'billedQuantity', ...QTY },
    { label: 'Match', fieldName: 'matchStatus' }
];

const RECEIPT_COLUMNS = [
    { label: 'Receipt', fieldName: 'name' },
    { label: 'Date', fieldName: 'receiptDate', type: 'date-local' },
    { label: 'Status', fieldName: 'status' },
    { label: 'Quantity', fieldName: 'totalQuantity', ...QTY }
];

const BILL_COLUMNS = [
    { label: 'Bill', fieldName: 'name' },
    { label: 'Type', fieldName: 'documentType' },
    { label: 'Status', fieldName: 'status' }
];

let lineCounter = 0;

function emptyLine() {
    lineCounter += 1;
    return { key: `l${lineCounter}`, description: '', quantity: '', unitPrice: '', departmentId: '', costCenterId: '' };
}

function today() {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export default class SabPurchasingWorkspace extends LightningElement {
    orderColumns = ORDER_COLUMNS;
    lineColumns = LINE_COLUMNS;
    receiptColumns = RECEIPT_COLUMNS;
    billColumns = BILL_COLUMNS;

    companyId;
    workspace;
    subscription;
    isLoading = false;
    errorMessage;

    showOrderForm = false;
    orderForm;
    selectedOrderId;
    detail;
    selectedReceiptId;
    receiptDate = today();
    receiptQuantities = {};
    reason = '';

    // Request keys survive a failed attempt (a retry replays) and are discarded after success.
    requestKeys = {};

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        this.subscribeToCompanyContext();
        const stored = window.sessionStorage.getItem(STORAGE_KEY);
        if (stored) {
            this.companyId = stored;
            this.refresh();
        }
    }

    disconnectedCallback() {
        if (this.subscription) {
            unsubscribe(this.subscription);
            this.subscription = undefined;
        }
    }

    subscribeToCompanyContext() {
        if (this.subscription || !this.messageContext) {
            return;
        }
        this.subscription = subscribe(this.messageContext, COMPANY_CONTEXT_CHANNEL,
            (message) => this.handleCompanyContext(message), { scope: APPLICATION_SCOPE });
    }

    handleCompanyContext(message) {
        if (!message || message.companyCleared) {
            this.companyId = undefined;
            this.workspace = undefined;
            this.resetSelection();
            return;
        }
        if (message.companyId && message.companyId !== this.companyId) {
            this.companyId = message.companyId;
            this.requestKeys = {};
            this.resetSelection();
            this.refresh();
        }
    }

    resetSelection() {
        this.selectedOrderId = undefined;
        this.detail = undefined;
        this.selectedReceiptId = undefined;
        this.showOrderForm = false;
        this.reason = '';
        this.receiptQuantities = {};
    }

    async refresh() {
        if (!this.companyId) {
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            this.workspace = await getWorkspace({ companyId: this.companyId });
            if (this.selectedOrderId) {
                await this.loadDetail();
            }
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async loadDetail() {
        this.detail = await getPurchaseOrderDetail({ purchaseOrderId: this.selectedOrderId });
        const quantities = {};
        this.detail.lines.forEach((l) => {
            quantities[l.lineId] = l.remainingQuantity > 0 ? String(l.remainingQuantity) : '';
        });
        this.receiptQuantities = quantities;
    }

    // ------------------------------------------------------------- getters

    get hasCompany() {
        return Boolean(this.companyId);
    }

    get hasWorkspace() {
        return Boolean(this.workspace);
    }

    get companyName() {
        return this.workspace ? this.workspace.companyName : '';
    }

    get functionalCurrency() {
        return this.workspace ? this.workspace.functionalCurrency : '';
    }

    get openCommitment() {
        return this.workspace ? this.workspace.openCommitment : 0;
    }

    get can() {
        return (this.workspace && this.workspace.capabilities) || {};
    }

    get orders() {
        return (this.workspace && this.workspace.orders) || [];
    }

    get hasOrders() {
        return this.orders.length > 0;
    }

    get stateCounts() {
        return (this.workspace && this.workspace.stateCounts) || [];
    }

    get supplierOptions() {
        return (this.workspace && this.workspace.suppliers) || [];
    }

    get departmentOptions() {
        return [{ label: 'None', value: '' }, ...((this.workspace && this.workspace.departments) || [])];
    }

    get costCenterOptions() {
        return [{ label: 'None', value: '' }, ...((this.workspace && this.workspace.costCenters) || [])];
    }

    get selectedOrderRows() {
        return this.selectedOrderId ? [this.selectedOrderId] : [];
    }

    get selectedReceiptRows() {
        return this.selectedReceiptId ? [this.selectedReceiptId] : [];
    }

    get order() {
        return this.detail ? this.detail.purchaseOrder : undefined;
    }

    get hasSelectedOrder() {
        return Boolean(this.order);
    }

    get lines() {
        return (this.detail && this.detail.lines) || [];
    }

    get receipts() {
        return (this.detail && this.detail.receipts) || [];
    }

    get hasReceipts() {
        return this.receipts.length > 0;
    }

    get bills() {
        return (this.detail && this.detail.bills) || [];
    }

    get hasBills() {
        return this.bills.length > 0;
    }

    get status() {
        return this.order ? this.order.status : undefined;
    }

    get isDraft() {
        return this.status === 'Draft';
    }

    get isSubmitted() {
        return this.status === 'Submitted';
    }

    get isCancellable() {
        return CANCELLABLE.includes(this.status);
    }

    get isClosable() {
        return CLOSABLE.includes(this.status);
    }

    get isReceivable() {
        return RECEIVABLE.includes(this.status);
    }

    get receiveLines() {
        return this.lines.map((l) => ({ ...l, receiveQuantity: this.receiptQuantities[l.lineId] || '' }));
    }

    get selectedReceipt() {
        return this.receipts.find((r) => r.goodsReceiptId === this.selectedReceiptId);
    }

    get receiptIsDraft() {
        return this.selectedReceipt && this.selectedReceipt.status === 'Draft';
    }

    get receiptIsCancellable() {
        return this.selectedReceipt && (this.selectedReceipt.status === 'Draft' || this.selectedReceipt.status === 'Accepted');
    }

    get formTotal() {
        if (!this.orderForm) {
            return 0;
        }
        return this.orderForm.lines.reduce((sum, l) => sum + (Number(l.quantity) || 0) * (Number(l.unitPrice) || 0), 0);
    }

    get formTotalLabel() {
        return `Total: ${this.formTotal.toFixed(2)} ${this.orderForm ? this.orderForm.currencyCode : ''}`;
    }

    // Disabled flags: permission AND inputs AND not busy. The services re-check everything.
    get newOrderDisabled() {
        return this.isLoading || !this.can.manage;
    }

    get saveOrderDisabled() {
        const f = this.orderForm;
        if (!f) {
            return true;
        }
        const linesValid = f.lines.length > 0 && f.lines.every((l) => l.description.trim() && Number(l.quantity) > 0
            && l.unitPrice !== '' && Number(l.unitPrice) >= 0);
        return this.isLoading || !this.can.manage || !f.supplierProfileId || !f.orderDate || !f.currencyCode.trim() || !linesValid;
    }

    get manageDisabled() {
        return this.isLoading || !this.can.manage;
    }

    get approveDisabled() {
        return this.isLoading || !this.can.approve;
    }

    get returnDisabled() {
        return this.isLoading || !this.can.approve || !this.reason.trim();
    }

    get reasonActionDisabled() {
        return this.isLoading || !this.can.manage || !this.reason.trim();
    }

    get createReceiptDisabled() {
        return this.isLoading || !this.can.receive || !this.receiptDate
            || !Object.values(this.receiptQuantities).some((q) => Number(q) > 0);
    }

    get receiptActionDisabled() {
        return this.isLoading || !this.can.receive;
    }

    get cancelReceiptDisabled() {
        return this.isLoading || !this.can.receive || !this.reason.trim();
    }

    // ------------------------------------------------------------- handlers

    handleRefresh() {
        this.refresh();
    }

    handleReasonChange(event) {
        this.reason = event.detail.value;
    }

    handleNewOrder() {
        this.orderForm = { purchaseOrderId: undefined, supplierProfileId: '', orderDate: today(), currencyCode: this.functionalCurrency,
            lines: [emptyLine()] };
        this.showOrderForm = true;
    }

    handleEditOrder() {
        const o = this.order;
        this.orderForm = { purchaseOrderId: o.purchaseOrderId, supplierProfileId: o.supplierProfileId, orderDate: o.orderDate,
            currencyCode: o.currencyCode,
            lines: this.lines.map((l) => ({ ...emptyLine(), description: l.description, quantity: String(l.quantity),
                unitPrice: String(l.unitPrice), departmentId: l.departmentId || '', costCenterId: l.costCenterId || '' })) };
        this.showOrderForm = true;
    }

    handleCancelForm() {
        this.showOrderForm = false;
    }

    handleFormField(event) {
        this.orderForm = { ...this.orderForm, [event.target.dataset.field]: event.detail.value };
    }

    handleLineField(event) {
        const { key, field } = event.target.dataset;
        this.orderForm = { ...this.orderForm,
            lines: this.orderForm.lines.map((l) => (l.key === key ? { ...l, [field]: event.detail.value } : l)) };
    }

    handleAddLine() {
        this.orderForm = { ...this.orderForm, lines: [...this.orderForm.lines, emptyLine()] };
    }

    handleRemoveLine(event) {
        const key = event.target.dataset.key;
        this.orderForm = { ...this.orderForm, lines: this.orderForm.lines.filter((l) => l.key !== key) };
    }

    async handleOrderSelection(event) {
        const rows = event.detail.selectedRows || [];
        this.selectedOrderId = rows.length ? rows[0].purchaseOrderId : undefined;
        this.selectedReceiptId = undefined;
        this.reason = '';
        this.isLoading = true;
        try {
            if (this.selectedOrderId) {
                await this.loadDetail();
            } else {
                this.detail = undefined;
            }
        } catch (error) {
            this.notifyError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleReceiptSelection(event) {
        const rows = event.detail.selectedRows || [];
        this.selectedReceiptId = rows.length ? rows[0].goodsReceiptId : undefined;
    }

    handleReceiptDate(event) {
        this.receiptDate = event.detail.value;
    }

    handleReceiveQuantity(event) {
        this.receiptQuantities = { ...this.receiptQuantities, [event.target.dataset.lineId]: event.detail.value };
    }

    handleSaveOrder() {
        const f = this.orderForm;
        const request = {
            purchaseOrderId: f.purchaseOrderId || null, companyId: this.companyId, supplierProfileId: f.supplierProfileId,
            orderDate: f.orderDate, currencyCode: f.currencyCode.trim(),
            lines: f.lines.map((l, index) => ({ lineNumber: index + 1, description: l.description.trim(), quantity: Number(l.quantity),
                unitPrice: Number(l.unitPrice), departmentId: l.departmentId || null, costCenterId: l.costCenterId || null }))
        };
        return this.runAction(null, async () => {
            this.selectedOrderId = await saveDraft({ request });
            this.showOrderForm = false;
            return 'Purchase order saved as Draft.';
        });
    }

    handleSubmit() {
        return this.runAction(`SUBMIT|${this.selectedOrderId}`, async (key) => {
            await submitOrder({ purchaseOrderId: this.selectedOrderId, requestKey: key });
            return 'Purchase order submitted for approval.';
        });
    }

    handleApprove() {
        return this.runAction(`APPROVE|${this.selectedOrderId}`, async (key) => {
            await approveOrder({ purchaseOrderId: this.selectedOrderId, requestKey: key });
            return 'Purchase order approved.';
        });
    }

    handleReturn() {
        return this.runAction(`RETURN|${this.selectedOrderId}`, async (key) => {
            await returnToDraft({ purchaseOrderId: this.selectedOrderId, reason: this.reason.trim(), requestKey: key });
            return 'Purchase order returned to Draft.';
        });
    }

    handleCancelOrder() {
        return this.runAction(`CANCEL|${this.selectedOrderId}`, async (key) => {
            await cancelOrder({ purchaseOrderId: this.selectedOrderId, reason: this.reason.trim(), requestKey: key });
            return 'Purchase order cancelled.';
        });
    }

    handleCloseOrder() {
        return this.runAction(`CLOSE|${this.selectedOrderId}`, async (key) => {
            await closeOrder({ purchaseOrderId: this.selectedOrderId, reason: this.reason.trim(), requestKey: key });
            return 'Purchase order closed.';
        });
    }

    handleCreateReceipt() {
        const request = {
            purchaseOrderId: this.selectedOrderId, receiptDate: this.receiptDate,
            lines: this.lines.filter((l) => Number(this.receiptQuantities[l.lineId]) > 0)
                .map((l) => ({ purchaseOrderLineId: l.lineId, acceptedQuantity: Number(this.receiptQuantities[l.lineId]),
                    serviceAccepted: false, comment: null }))
        };
        return this.runAction(null, async () => {
            this.selectedReceiptId = await createReceipt({ request });
            return 'Draft goods receipt created; accept it to update the order.';
        });
    }

    handleAcceptReceipt() {
        return this.runAction(`ACCEPT_RECEIPT|${this.selectedReceiptId}`, async (key) => {
            await acceptReceipt({ goodsReceiptId: this.selectedReceiptId, requestKey: key });
            return 'Goods receipt accepted.';
        });
    }

    handleCancelReceipt() {
        return this.runAction(`CANCEL_RECEIPT|${this.selectedReceiptId}`, async (key) => {
            await cancelReceipt({ goodsReceiptId: this.selectedReceiptId, reason: this.reason.trim(), requestKey: key });
            return 'Goods receipt cancelled.';
        });
    }

    // ------------------------------------------------------------- actions

    requestKey(name) {
        if (!this.requestKeys[name]) {
            this.requestKeys[name] = `G12B|${name}|${Date.now()}`.slice(0, 120);
        }
        return this.requestKeys[name];
    }

    async runAction(name, call) {
        const key = name ? this.requestKey(name) : undefined;
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const message = await call(key);
            if (name) {
                delete this.requestKeys[name];
            }
            this.reason = '';
            this.dispatchEvent(new ShowToastEvent({ title: 'Purchasing', message, variant: 'success' }));
            this.isLoading = false;
            await this.refresh();
        } catch (error) {
            this.notifyError(error);
        } finally {
            this.isLoading = false;
        }
    }

    notifyError(error) {
        const message = this.reduceError(error);
        this.errorMessage = message;
        this.dispatchEvent(new ShowToastEvent({ title: 'Purchasing', message, variant: 'error' }));
    }

    reduceError(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        if (error && error.message) {
            return error.message;
        }
        return 'An unexpected Purchasing Workspace error occurred.';
    }
}
