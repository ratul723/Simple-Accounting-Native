import { createElement } from 'lwc';
import SabPurchasingWorkspace from 'c/sabPurchasingWorkspace';
import getWorkspace from '@salesforce/apex/SABPurchasingWorkspaceController.getWorkspace';
import getPurchaseOrderDetail from '@salesforce/apex/SABPurchasingWorkspaceController.getPurchaseOrderDetail';
import saveDraft from '@salesforce/apex/SABPurchaseOrderService.saveDraft';
import submitOrder from '@salesforce/apex/SABPurchaseOrderService.submit';
import cancelOrder from '@salesforce/apex/SABPurchaseOrderService.cancel';
import createReceipt from '@salesforce/apex/SABGoodsReceiptService.createReceipt';
import acceptReceipt from '@salesforce/apex/SABGoodsReceiptService.acceptReceipt';

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

const COMPANY_ID = 'a00000000000001AAA';
const PO_ID = 'a0O000000000001AAA';
const SUPPLIER = 'a0P000000000001AAA';
const LINE1 = 'a0L000000000001AAA';
const LINE2 = 'a0L000000000002AAA';
const RECEIPT = 'a0G000000000001AAA';

function workspace(caps) {
    return {
        companyId: COMPANY_ID, companyName: 'Harbourline Trading', functionalCurrency: 'BDT', openCommitment: 1200,
        capabilities: { manage: true, approve: true, receive: true, ...caps },
        orders: [{ purchaseOrderId: PO_ID, name: 'PO-0001', supplierName: 'Acme', status: 'Approved', total: 1200, currencyCode: 'BDT' }],
        stateCounts: [{ state: 'Approved', count: 1 }], suppliers: [{ label: 'Acme', value: SUPPLIER }], departments: [], costCenters: []
    };
}

function detail(status, receipts) {
    return {
        purchaseOrder: { purchaseOrderId: PO_ID, name: 'PO-0001', status, supplierName: 'Acme', supplierProfileId: SUPPLIER,
            orderDate: '2026-09-01', currencyCode: 'BDT', total: 1200 },
        lines: [{ lineId: LINE1, lineNumber: 1, description: 'Paper', quantity: 10, unitPrice: 100, receivedQuantity: 4, remainingQuantity: 6,
            billedQuantity: 0, matchStatus: 'Awaiting bill' },
            { lineId: LINE2, lineNumber: 2, description: 'Toner', quantity: 5, unitPrice: 40, receivedQuantity: 5, remainingQuantity: 0,
                billedQuantity: 5, matchStatus: 'Fully billed' }],
        receipts: receipts || [], bills: []
    };
}

// Test-only: let pending Apex promises and re-renders settle.
// eslint-disable-next-line @lwc/lwc/no-async-operation
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
const q = (el, s) => el.shadowRoot.querySelector(s);
const qa = (el, s) => Array.from(el.shadowRoot.querySelectorAll(s));

async function mount() {
    const element = createElement('c-sab-purchasing-workspace', { is: SabPurchasingWorkspace });
    document.body.appendChild(element);
    await flush();
    await flush();
    return element;
}

async function change(target, value) {
    target.dispatchEvent(new CustomEvent('change', { detail: { value } }));
    await flush();
}

async function selectOrder(element) {
    qa(element, 'lightning-datatable')[0].dispatchEvent(new CustomEvent('rowselection', { detail: { selectedRows: [{ purchaseOrderId: PO_ID }] } }));
    await flush();
    await flush();
}

describe('c-sab-purchasing-workspace', () => {
    beforeEach(() => window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANY_ID));
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        window.sessionStorage.clear();
        jest.clearAllMocks();
    });

    it('asks for a company when none is selected', async () => {
        window.sessionStorage.clear();
        const element = await mount();
        expect(q(element, '.empty-state').textContent).toContain('Select an Accounting Company');
        expect(getWorkspace).not.toHaveBeenCalled();
    });

    it('loads orders and the open commitment', async () => {
        getWorkspace.mockResolvedValue(workspace());
        const element = await mount();
        expect(getWorkspace).toHaveBeenCalledWith({ companyId: COMPANY_ID });
        expect(q(element, '.emphasized lightning-formatted-number').value).toBe(1200);
    });

    it('saves a draft order with numbered lines in the service request shape', async () => {
        getWorkspace.mockResolvedValue(workspace());
        getPurchaseOrderDetail.mockResolvedValue(detail('Draft'));
        saveDraft.mockResolvedValue(PO_ID);
        const element = await mount();
        q(element, 'lightning-button.new-order').click();
        await flush();
        await change(q(element, '[data-field="supplierProfileId"]'), SUPPLIER);
        expect(q(element, 'lightning-button.save-order').disabled).toBe(true);
        await change(q(element, '.line-row [data-field="description"]'), ' Paper ');
        await change(q(element, '.line-row [data-field="quantity"]'), '10');
        await change(q(element, '.line-row [data-field="unitPrice"]'), '100');
        expect(q(element, '.order-form .hint').textContent).toContain('1000.00 BDT');
        q(element, 'lightning-button.save-order').click();
        await flush();
        await flush();
        expect(saveDraft.mock.calls[0][0].request).toMatchObject({ companyId: COMPANY_ID, supplierProfileId: SUPPLIER, currencyCode: 'BDT',
            lines: [{ lineNumber: 1, description: 'Paper', quantity: 10, unitPrice: 100, departmentId: null, costCenterId: null }] });
    });

    it('submits a Draft order with a request key', async () => {
        getWorkspace.mockResolvedValue(workspace());
        getPurchaseOrderDetail.mockResolvedValue(detail('Draft'));
        submitOrder.mockResolvedValue({ status: 'Submitted' });
        const element = await mount();
        await selectOrder(element);
        q(element, 'lightning-button.submit-order').click();
        await flush();
        expect(submitOrder).toHaveBeenCalledWith({ purchaseOrderId: PO_ID, requestKey: expect.stringMatching(/^G12B\|SUBMIT\|/) });
    });

    it('receives only the outstanding quantities that are entered, then accepts the receipt', async () => {
        getWorkspace.mockResolvedValue(workspace());
        getPurchaseOrderDetail.mockResolvedValue(detail('Part Received', [{ goodsReceiptId: RECEIPT, name: 'GR-0001', status: 'Draft' }]));
        createReceipt.mockResolvedValue(RECEIPT);
        acceptReceipt.mockResolvedValue({ status: 'Accepted' });
        const element = await mount();
        await selectOrder(element);
        const inputs = qa(element, '.receive-panel lightning-input[data-line-id]');
        expect(inputs[0].value).toBe('6');
        expect(inputs[1].value).toBe('');
        q(element, 'lightning-button.create-receipt').click();
        await flush();
        await flush();
        expect(createReceipt.mock.calls[0][0].request.lines).toEqual([{ purchaseOrderLineId: LINE1, acceptedQuantity: 6,
            serviceAccepted: false, comment: null }]);
        qa(element, 'lightning-datatable')[2].dispatchEvent(new CustomEvent('rowselection',
            { detail: { selectedRows: [{ goodsReceiptId: RECEIPT }] } }));
        await flush();
        q(element, 'lightning-button.accept-receipt').click();
        await flush();
        expect(acceptReceipt).toHaveBeenCalledWith({ goodsReceiptId: RECEIPT, requestKey: expect.stringMatching(/^G12B\|ACCEPT_RECEIPT\|/) });
    });

    it('reuses the request key after a failed cancel and requires a reason', async () => {
        getWorkspace.mockResolvedValue(workspace());
        getPurchaseOrderDetail.mockResolvedValue(detail('Approved'));
        cancelOrder.mockRejectedValueOnce({ body: { message: 'has goods receipts' } }).mockResolvedValue({ status: 'Cancelled' });
        const element = await mount();
        await selectOrder(element);
        expect(q(element, 'lightning-button.cancel-order').disabled).toBe(true);
        await change(q(element, '.action-panel [data-field="reason"]'), 'Supplier failed');
        q(element, 'lightning-button.cancel-order').click();
        await flush();
        await flush();
        expect(q(element, '.error-banner').textContent).toContain('has goods receipts');
        q(element, 'lightning-button.cancel-order').click();
        await flush();
        expect(cancelOrder.mock.calls[1][0].requestKey).toBe(cancelOrder.mock.calls[0][0].requestKey);
    });

    it('disables actions the user has no permission for', async () => {
        getWorkspace.mockResolvedValue(workspace({ manage: false, approve: false, receive: false }));
        getPurchaseOrderDetail.mockResolvedValue(detail('Approved'));
        const element = await mount();
        expect(q(element, 'lightning-button.new-order').disabled).toBe(true);
        await selectOrder(element);
        expect(q(element, 'lightning-button.create-receipt').disabled).toBe(true);
    });
});
