import { createElement } from 'lwc';
import SabPurchaseOrders from 'c/sabPurchaseOrders';
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

jest.mock('@salesforce/apex/SABPurchasingWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPurchasingWorkspaceController.getPurchaseOrderDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPurchaseOrderService.saveDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPurchaseOrderService.submit', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPurchaseOrderService.approve', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPurchaseOrderService.returnToDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPurchaseOrderService.cancel', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPurchaseOrderService.close', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABGoodsReceiptService.createReceipt', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABGoodsReceiptService.acceptReceipt', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABGoodsReceiptService.cancelReceipt', () => ({ default: jest.fn() }), { virtual: true });

const order = (id, status) => ({ purchaseOrderId: id, name: `PO-${id}`, supplierProfileId: 'S1', supplierName: 'Pack Co', orderDate: '2026-09-01', currencyCode: 'AUD', status, total: 1000 });

function ws(overrides = {}) {
    return {
        functionalCurrency: 'AUD', capabilities: { manage: true, approve: true, receive: true }, openCommitment: 1500,
        orders: [order('O1', 'Draft'), order('O2', 'Submitted'), order('O3', 'Part Received'), order('O4', 'Cancelled')],
        suppliers: [{ value: 'S1', label: 'Pack Co' }], departments: [{ value: 'D1', label: 'Operations' }], costCenters: [{ value: 'K1', label: 'CC-1' }],
        ...overrides
    };
}

function detail(id, status) {
    return {
        purchaseOrder: order(id, status),
        lines: [{ lineId: 'L1', description: 'Boxes', quantity: 10, unitPrice: 50, lineAmount: 500, departmentId: 'D1', departmentName: 'Operations', receivedQuantity: 4,
            remainingQuantity: 6, billedQuantity: 4, matchStatus: 'Matched' },
            { lineId: 'L2', description: 'Tape', quantity: 5, unitPrice: 100, lineAmount: 500, receivedQuantity: 5, remainingQuantity: 0, billedQuantity: 0 }],
        receipts: [{ goodsReceiptId: 'G1', name: 'GR-1', receiptDate: '2026-09-10', status: 'Draft', totalQuantity: 4 },
            { goodsReceiptId: 'G2', name: 'GR-0', receiptDate: '2026-09-05', status: 'Accepted', totalQuantity: 5 }],
        bills: [{ supplierBillId: 'B1', name: 'BILL-1', documentType: 'Bill', status: 'Posted' }]
    };
}

async function flush() {
    for (let i = 0; i < 10; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-purchase-orders', { is: SabPurchaseOrders });
    Object.assign(el, { persona: { label: 'Bookkeeper' }, ...props });
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

function openRow(root, index) {
    root.querySelectorAll('.sab-orders tbody tr')[index].click();
}

function setModal(root, field, value) {
    const input = root.querySelector(`c-sab-modal [data-field="${field}"]`);
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-purchase-orders', () => {
    beforeEach(() => {
        getWorkspace.mockResolvedValue(ws());
        getDetail.mockImplementation(({ purchaseOrderId }) => Promise.resolve(detail(purchaseOrderId,
            { O1: 'Draft', O2: 'Submitted', O3: 'Part Received', O4: 'Cancelled' }[purchaseOrderId] || 'Draft')));
        [submitOrder, approveOrder, returnOrder, cancelOrder, closeOrder, acceptReceipt, cancelReceipt].forEach((m) => m.mockResolvedValue({}));
        saveDraft.mockResolvedValue('O9');
        createReceipt.mockResolvedValue('G9');
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('lists orders and shows the part received drawer with match, receipts and bills', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.panel-h .sub').textContent).toBe('1 order waiting for goods, open commitment 1,500.00 AUD');
        expect(root.querySelectorAll('.sab-orders tbody tr').length).toBe(4);
        root.querySelectorAll('.sab-orders tbody tr')[2].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        expect(root.querySelector('c-sab-drawer').heading).toBe('PO-O3');
        expect(Array.from(root.querySelectorAll('.hstep')).map((s) => s.className)).toEqual(['hstep done', 'hstep done', 'hstep done', 'hstep now']);
        expect(root.querySelector('.sab-po-lines tbody tr').textContent).toContain('Matched');
        expect(root.querySelector('.list .li').textContent).toContain('BILL-1');
        root.querySelector('.sab-accept-receipt').click();
        await flush();
        expect(acceptReceipt.mock.calls[0][0]).toMatchObject({ goodsReceiptId: 'G1', requestKey: expect.stringMatching(/^PO-ACCEPT-G1-/) });
        root.querySelector('.sab-cancel-receipt').click();
        await flush();
        setModal(root, 'reason', 'Damaged');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(cancelReceipt.mock.calls[0][0]).toMatchObject({ goodsReceiptId: 'G1', reason: 'Damaged' });
        root.querySelectorAll('.sab-orders tbody tr')[2].dispatchEvent(new KeyboardEvent('keydown', { key: 'x' }));
    });

    it('receives goods and closes an order', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        openRow(root, 2);
        await flush();
        root.querySelector('.sab-receive').click();
        await flush();
        const qty = root.querySelectorAll('.sab-receive-grid input');
        expect(qty.length).toBe(1);
        expect(qty[0].value).toBe('6');
        qty[0].value = '3';
        qty[0].dispatchEvent(new CustomEvent('input'));
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(createReceipt.mock.calls[0][0].request).toMatchObject({ purchaseOrderId: 'O3', lines: [{ purchaseOrderLineId: 'L1', acceptedQuantity: 3, serviceAccepted: null, comment: null }] });
        root.querySelector('.sab-close-po').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('A reason is required.');
        setModal(root, 'reason', 'Supplier short');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(closeOrder.mock.calls[0][0]).toMatchObject({ purchaseOrderId: 'O3', reason: 'Supplier short' });
    });

    it('submits, edits and cancels drafts and approves or returns submitted orders', async () => {
        returnOrder.mockRejectedValueOnce({ body: { message: 'Order changed.' } });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        openRow(root, 0);
        await flush();
        root.querySelector('.sab-submit-po').click();
        await flush();
        expect(submitOrder.mock.calls[0][0]).toMatchObject({ purchaseOrderId: 'O1' });
        root.querySelector('.sab-edit-po').click();
        await flush();
        expect(root.querySelectorAll('.sab-po-grid tbody tr').length).toBe(2);
        root.querySelectorAll('.sab-remove-line')[1].click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(saveDraft.mock.calls[0][0].request).toMatchObject({ purchaseOrderId: 'O1', lines: [{ lineNumber: 1, description: 'Boxes', quantity: 10, unitPrice: 50, departmentId: 'D1' }] });
        root.querySelector('.sab-cancel-po').click();
        await flush();
        setModal(root, 'reason', 'Not needed');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(cancelOrder.mock.calls[0][0]).toMatchObject({ purchaseOrderId: 'O9', reason: 'Not needed' });
        openRow(root, 1);
        await flush();
        root.querySelector('.sab-approve-po').click();
        await flush();
        expect(approveOrder.mock.calls[0][0]).toMatchObject({ purchaseOrderId: 'O2' });
        root.querySelector('.sab-return-po').click();
        await flush();
        setModal(root, 'reason', 'Wrong supplier');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(toast.mock.calls[toast.mock.calls.length - 1][0].detail.tone).toBe('bad');
        expect(root.querySelector('c-sab-modal').open).toBe(true);
    });

    it('creates a new order with lines', async () => {
        saveDraft.mockRejectedValueOnce({ body: { message: 'Supplier is required.' } });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.sab-new-po').click();
        await flush();
        const row = root.querySelector('.sab-po-grid tbody tr');
        const set = (field, value) => {
            const input = row.querySelector(`[data-field="${field}"]`);
            input.value = value;
            input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
        };
        set('description', 'Pallets');
        set('quantity', '4');
        set('unitPrice', '25');
        set('costCenterId', 'K1');
        await flush();
        expect(root.querySelector('.sab-po-grid tfoot').textContent).toContain('100.00');
        root.querySelector('.sab-add-line').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('Supplier is required.');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(saveDraft.mock.calls[1][0].request).toMatchObject({ purchaseOrderId: null, supplierProfileId: 'S1', currencyCode: 'AUD',
            lines: [{ lineNumber: 1, description: 'Pallets', quantity: 4, unitPrice: 25, costCenterId: 'K1', departmentId: null }] });
        expect(getDetail).toHaveBeenLastCalledWith({ purchaseOrderId: 'O9' });
    });

    it('handles cancelled orders, permissions, empty lists and errors', async () => {
        getWorkspace.mockResolvedValue(ws({ capabilities: { manage: false, approve: false, receive: false } }));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-new-po').title).toBe('Bookkeeper role cannot create purchase orders');
        openRow(root, 3);
        await flush();
        expect(root.querySelector('c-sab-drawer .banner').textContent).toContain('Cancelled');
        openRow(root, 2);
        await flush();
        expect(root.querySelector('.sab-receive').title).toBe('Bookkeeper role cannot receive goods');
        root.querySelector('c-sab-drawer').dispatchEvent(new CustomEvent('close'));
        await flush();

        getWorkspace.mockResolvedValueOnce(ws({ orders: [] }));
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.panel-b.muted').textContent).toBe('No purchase orders yet.');

        getDetail.mockRejectedValueOnce({ body: { message: 'Order not accessible.' } });
        const el3 = mount();
        await flush();
        openRow(el3.shadowRoot, 0);
        await flush();
        expect(el3.shadowRoot.querySelector('c-sab-drawer .banner').textContent).toBe('Order not accessible.');

        getWorkspace.mockRejectedValueOnce({ body: { message: 'Purchasing permission is required.' } });
        const el4 = mount();
        await flush();
        expect(el4.shadowRoot.querySelector('.banner').textContent).toContain('Purchasing permission is required.');
        el4.shadowRoot.querySelector('.banner .btn').click();
        await flush();
        expect(el4.shadowRoot.querySelector('.sab-orders')).not.toBeNull();
        el4.shadowRoot.querySelector('.sab-new-po').click();
        await flush();
        el4.shadowRoot.querySelector('.sab-modal-close').click();
    });
});
