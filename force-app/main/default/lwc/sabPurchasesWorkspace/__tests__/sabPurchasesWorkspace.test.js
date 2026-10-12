import { createElement } from 'lwc';
import SabPurchasesWorkspace from 'c/sabPurchasesWorkspace';
import getWorkspace from '@salesforce/apex/SABAccountsPayableWorkspaceController.getWorkspace';
import getPurchaseExtras from '@salesforce/apex/SABMoneyWorkspaceController.getPurchaseExtras';
import getDocumentDetail from '@salesforce/apex/SABMoneyWorkspaceController.getDocumentDetail';
import submitBill from '@salesforce/apex/SABSupplierBillService.submit';
import approveBill from '@salesforce/apex/SABSupplierBillService.approve';
import returnBill from '@salesforce/apex/SABSupplierBillService.returnToDraft';
import cancelBill from '@salesforce/apex/SABSupplierBillService.cancel';
import postBill from '@salesforce/apex/SABSupplierBillPostingService.postApprovedBill';

jest.mock('@salesforce/apex/SABAccountsPayableWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABMoneyWorkspaceController.getPurchaseExtras', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABMoneyWorkspaceController.getDocumentDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSupplierBillService.submit', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSupplierBillService.approve', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSupplierBillService.returnToDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSupplierBillService.cancel', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSupplierBillPostingService.postApprovedBill', () => ({ default: jest.fn() }), { virtual: true });

const iso = (offset) => {
    const d = new Date();
    d.setDate(d.getDate() + offset);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
};

const WS = {
    functionalCurrency: 'AUD', totalOutstanding: 16720, currentAmount: 10000, days1To30Amount: 6720, days31To60Amount: 0, days61To90Amount: 0, days91PlusAmount: 0,
    bills: [
        { billId: 'B1', billNumber: 'BILL-000397', vendorReference: 'INV-88', supplierName: 'Fuel Co', supplierProfileId: 'S1', status: 'Posted',
            documentDate: iso(-40), dueDate: iso(-5), totalAmount: 6720, allocatedAmount: 0, outstandingAmount: 6720, isOverdue: true, daysPastDue: 5 },
        { billId: 'B2', billNumber: 'BILL-000398', supplierName: 'Pack Co', supplierProfileId: 'S2', status: 'Posted', dueDate: iso(3), totalAmount: 10000,
            allocatedAmount: 2000, outstandingAmount: 8000, isOverdue: false },
        { billId: 'B3', billNumber: 'BILL-000399', supplierName: 'Pack Co', status: 'Draft', dueDate: iso(30), totalAmount: 400, allocatedAmount: 0, outstandingAmount: 400 },
        { billId: 'B4', billNumber: 'BILL-000400', supplierName: 'Fuel Co', status: 'Submitted', dueDate: iso(30), totalAmount: 900, allocatedAmount: 0, outstandingAmount: 900 },
        { billId: 'B5', billNumber: 'BILL-000401', supplierName: 'Fuel Co', status: 'Approved', dueDate: iso(30), totalAmount: 300, allocatedAmount: 0, outstandingAmount: 300 },
        { billId: 'B6', billNumber: 'BILL-000396', supplierName: 'Old Co', supplierProfileId: 'S1', status: 'Posted', dueDate: iso(20), totalAmount: 50,
            allocatedAmount: 50, outstandingAmount: 0 },
        { billId: 'B7', billNumber: 'BILL-000395', supplierName: 'Pack Co', supplierProfileId: 'S2', status: 'Posted', dueDate: iso(10), totalAmount: 70,
            allocatedAmount: 0, outstandingAmount: 70 },
        { billId: 'B8', billNumber: 'BILL-000394', supplierName: 'Pack Co', supplierProfileId: 'S2', status: 'Posted', dueDate: iso(40), totalAmount: 80,
            allocatedAmount: 0, outstandingAmount: 80 },
        { billId: 'B9', billNumber: 'BILL-000393', supplierName: 'Pack Co', status: 'Cancelled', totalAmount: 10, allocatedAmount: 0, outstandingAmount: 10 }
    ]
};

const EXTRAS = { canApprove: true, canPost: true, canEdit: true, suppliers: [{ partyProfileId: 'S1', name: 'Fuel Co', paymentTerm: 'Net 30', paymentMethod: 'EFT' },
    { partyProfileId: 'S2', name: 'Pack Co' }] };

async function flush() {
    for (let i = 0; i < 8; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-purchases-workspace', { is: SabPurchasesWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', persona: { label: 'Bookkeeper' }, ...props });
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

function openRow(root, index) {
    root.querySelectorAll('.sab-bills tbody tr')[index].click();
}

describe('c-sab-purchases-workspace', () => {
    beforeEach(() => {
        getWorkspace.mockResolvedValue(WS);
        getPurchaseExtras.mockResolvedValue(EXTRAS);
        getDocumentDetail.mockResolvedValue({ subtotal: 6109, taxTotal: 611, total: 6720,
            lines: [{ description: 'Diesel', quantity: 1, unitPrice: 6109, netAmount: 6109, accountCode: '6200', accountName: 'Fuel', taxCode: 'GST' }],
            allocations: [{ allocationId: 'A1', documentNumber: 'PAY-000210', allocationDate: iso(-1), amount: 100 }] });
        [submitBill, approveBill, returnBill, cancelBill, postBill].forEach((m) => m.mockResolvedValue({}));
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders figures, bills, schedule and suppliers', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(getWorkspace.mock.calls[0][0]).toMatchObject({ statusFilter: 'All', includeSettled: true });
        expect(Array.from(root.querySelectorAll('.fig .v')).map((v) => v.textContent)).toEqual(['16,720AUD', '14,720AUD', '1', '6,720AUD']);
        expect(root.querySelectorAll('.fig .s')[3].textContent).toBe('1 bill past due');
        const states = Array.from(root.querySelectorAll('.sab-bills tbody .chip')).map((c) => c.textContent);
        expect(states.slice(0, 6)).toEqual(['Overdue', 'Part Paid', 'Draft', 'Submitted', 'Approved', 'Paid']);
        root.querySelectorAll('.tab')[1].click();
        await flush();
        expect(Array.from(root.querySelectorAll('.sab-schedule h2')).map((h) => h.textContent)).toEqual(['Overdue', 'This week', 'Next week', 'Later']);
        root.querySelectorAll('.tab')[2].click();
        await flush();
        expect(root.querySelectorAll('.sab-suppliers tbody tr')[1].textContent).toContain('8,150.00');
    });

    it('submits and cancels a draft bill', async () => {
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        openRow(root, 2);
        await flush();
        root.querySelector('.sab-submit-bill').click();
        await flush();
        expect(submitBill).toHaveBeenCalledWith({ billId: 'B3', requestKey: expect.stringMatching(/^BILL-SUBMIT-B3-/) });
        expect(toast.mock.calls[0][0].detail.message).toBe('BILL-000399 submitted for approval');
        openRow(root, 2);
        await flush();
        root.querySelector('.sab-cancel-bill').click();
        await flush();
        root.querySelector('.sab-reason-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('A reason is required.');
        const area = root.querySelector('.sab-reason');
        area.value = 'Duplicate of BILL-000398';
        area.dispatchEvent(new CustomEvent('input'));
        root.querySelector('.sab-reason-save').click();
        await flush();
        expect(cancelBill.mock.calls[0][0]).toMatchObject({ billId: 'B3', reason: 'Duplicate of BILL-000398' });
        expect(root.querySelector('c-sab-modal').open).toBe(false);
    });

    it('approves or returns a submitted bill and posts an approved bill', async () => {
        returnBill.mockRejectedValueOnce({ body: { message: 'Bill changed.' } });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        openRow(root, 3);
        await flush();
        root.querySelector('.sab-return-bill').click();
        await flush();
        expect(root.querySelector('c-sab-modal').heading).toBe('Return bill to draft');
        const area = root.querySelector('.sab-reason');
        area.value = 'Wrong amount';
        area.dispatchEvent(new CustomEvent('input'));
        root.querySelector('.sab-reason-save').click();
        await flush();
        expect(toast.mock.calls[0][0].detail.tone).toBe('bad');
        expect(root.querySelector('c-sab-modal').open).toBe(true);
        root.querySelector('.sab-reason-close').click();
        await flush();
        root.querySelector('.sab-approve-bill').click();
        await flush();
        expect(approveBill.mock.calls[0][0]).toMatchObject({ billId: 'B4', reason: null });
        openRow(root, 4);
        await flush();
        root.querySelector('.sab-post-bill').click();
        await flush();
        expect(postBill.mock.calls[0][0].request).toMatchObject({ supplierBillId: 'B5', requestKey: expect.stringMatching(/^BILL-POST-B5-/) });
    });

    it('shows overdue and cancelled drawers and permission limits', async () => {
        getPurchaseExtras.mockResolvedValue({ ...EXTRAS, canApprove: false, canPost: false, canEdit: false });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        openRow(root, 0);
        await flush();
        expect(root.querySelector('c-sab-drawer').subheading).toContain('ref INV-88');
        expect(root.querySelector('c-sab-drawer .banner').textContent).toContain('5 days overdue');
        expect(root.querySelector('.sab-lines tbody tr').textContent).toContain('6200 Fuel');
        openRow(root, 3);
        await flush();
        expect(root.querySelector('.sab-approve-bill').title).toBe('Bookkeeper role cannot approve bills');
        expect(root.querySelector('.sab-return-bill').title).toBe('Bookkeeper role cannot change bills');
        openRow(root, 4);
        await flush();
        expect(root.querySelector('.sab-post-bill').title).toBe('Bookkeeper role cannot post bills');
        openRow(root, 8);
        await flush();
        expect(root.querySelector('c-sab-drawer .banner').textContent).toContain('Cancelled');
        root.querySelector('c-sab-drawer').dispatchEvent(new CustomEvent('close'));
        await flush();
        expect(root.querySelector('c-sab-drawer').open).toBe(false);
    });

    it('handles empty data, requested records and errors', async () => {
        getWorkspace.mockResolvedValueOnce({ ...WS, bills: [] });
        getPurchaseExtras.mockResolvedValueOnce({ ...EXTRAS, suppliers: [] });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.panel-b.muted').textContent).toBe('No supplier bills yet.');
        root.querySelectorAll('.tab')[1].click();
        await flush();
        expect(root.querySelector('.panel-b.muted').textContent).toBe('No posted bills are waiting for payment.');
        root.querySelectorAll('.tab')[2].click();
        await flush();
        expect(root.querySelector('.panel-b.muted').textContent).toBe('No supplier profiles yet.');

        getDocumentDetail.mockRejectedValueOnce({ body: { message: 'No lines.' } });
        const el2 = mount();
        el2.recordId = 'B1';
        await flush();
        expect(el2.shadowRoot.querySelector('c-sab-drawer').heading).toBe('BILL-000397');
        expect(el2.shadowRoot.querySelectorAll('c-sab-drawer .banner')[1].textContent).toBe('No lines.');
        el2.recordId = 'missing';

        getWorkspace.mockRejectedValueOnce({ body: { message: 'You do not have permission to view the AP workspace.' } });
        const el3 = mount();
        await flush();
        expect(el3.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have permission to view the AP workspace.');
        el3.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        expect(el3.shadowRoot.querySelector('.figs')).not.toBeNull();
        el3.shadowRoot.querySelectorAll('.sab-bills tbody tr')[0].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        el3.shadowRoot.querySelectorAll('.sab-bills tbody tr')[0].dispatchEvent(new KeyboardEvent('keydown', { key: 'a' }));
    });
});
