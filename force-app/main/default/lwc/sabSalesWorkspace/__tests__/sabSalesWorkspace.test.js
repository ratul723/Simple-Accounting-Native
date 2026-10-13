import { createElement } from 'lwc';
import SabSalesWorkspace from 'c/sabSalesWorkspace';
import getSales from '@salesforce/apex/SABMoneyWorkspaceController.getSales';
import getPayments from '@salesforce/apex/SABMoneyWorkspaceController.getPayments';
import getDocumentDetail from '@salesforce/apex/SABMoneyWorkspaceController.getDocumentDetail';
import postInvoice from '@salesforce/apex/SABInvoicePostingService.postApprovedInvoice';

jest.mock('@salesforce/apex/SABMoneyWorkspaceController.getSales', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABMoneyWorkspaceController.getPayments', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABMoneyWorkspaceController.getDocumentDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABInvoicePostingService.postApprovedInvoice', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABDocumentEntryService.submitInvoice', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABDocumentEntryService.approveInvoice', () => ({ default: jest.fn() }), { virtual: true });
import submitInvoice from '@salesforce/apex/SABDocumentEntryService.submitInvoice';
import approveInvoice from '@salesforce/apex/SABDocumentEntryService.approveInvoice';

const SALES = {
    currencyCode: 'AUD', canPost: true, agingAvailable: true, totalOutstanding: 48210, overdueAmount: 9120, overdueCount: 2, openCount: 5,
    collectedThisMonth: 31000, buckets: [30000, 9000, 120, 0, 0],
    invoices: [
        { documentId: 'I1', documentNumber: 'INV-000141', partyName: 'Greenfield Produce', documentDate: '2026-08-01', dueDate: '2026-08-31', total: 9120,
            status: 'Posted', outstanding: 9120, daysPastDue: 41 },
        { documentId: 'I2', documentNumber: 'INV-000148', partyName: 'Coastal Foods', documentDate: '2026-10-01', dueDate: '2026-10-31', total: 2000, status: 'Approved' },
        { documentId: 'I3', documentNumber: 'INV-000140', partyName: 'Coastal Foods', documentDate: '2026-07-01', dueDate: '2026-07-31', total: 500,
            status: 'Posted', outstanding: 0, daysPastDue: 0 }
    ],
    credits: [{ documentId: 'C1', documentNumber: 'CN-000013', partyName: 'Coastal Foods', documentDate: '2026-09-02', total: -120, status: 'Posted', originalNumber: 'INV-000140' }],
    customers: [{ partyProfileId: 'P1', name: 'Greenfield Produce', creditLimit: 10000, outstanding: 9120, paymentTerm: 'Net 30' },
        { partyProfileId: 'P2', name: 'Walk-in', outstanding: 0 }]
};

async function flush() {
    for (let i = 0; i < 8; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-sales-workspace', { is: SabSalesWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', persona: { label: 'Bookkeeper' }, visibleWorkspaces: ['reports'], ...props });
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

describe('c-sab-sales-workspace', () => {
    beforeEach(() => {
        getSales.mockResolvedValue(SALES);
        getPayments.mockResolvedValue({ payments: [
            { paymentId: 'R1', paymentNumber: 'PAY-000201', direction: 'Receipt', partyName: 'Greenfield', amount: 500, allocated: 500, state: 'Succeeded' },
            { paymentId: 'R2', paymentNumber: 'PAY-000202', direction: 'Receipt', amount: 300, allocated: 100, state: 'Succeeded' },
            { paymentId: 'D1', paymentNumber: 'PAY-000203', direction: 'Disbursement', amount: 100, allocated: 0, state: 'Draft' }] });
        getDocumentDetail.mockResolvedValue({ subtotal: 8291, taxTotal: 829, total: 9120,
            lines: [{ description: 'Grain', quantity: 2, unitPrice: 4145.5, netAmount: 8291, accountCode: '4000', accountName: 'Sales', taxCode: 'GST' }],
            allocations: [{ allocationId: 'AL1', documentNumber: 'PAY-000201', allocationDate: '2026-09-02', amount: 500 }] });
        postInvoice.mockResolvedValue({ replay: false });
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders figures, aging and invoices with states', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(Array.from(root.querySelectorAll('.fig .v')).map((v) => v.textContent)).toEqual(['48,210AUD', '9,120AUD', '31,000AUD', '1']);
        expect(root.querySelectorAll('.fig .s')[1].textContent).toBe('2 invoices past due');
        expect(root.querySelector('c-sab-aging-bar').buckets).toEqual([30000, 9000, 120, 0, 0]);
        const rows = root.querySelectorAll('.sab-invoices tbody tr');
        expect(rows[0].textContent).toContain('41 days late');
        expect(rows[0].querySelector('.chip').textContent).toBe('Overdue');
        expect(rows[1].textContent).toContain('\u2014');
        expect(rows[2].querySelector('.chip').textContent).toBe('Paid');
        const nav = jest.fn();
        el.addEventListener('sabnavigate', nav);
        root.querySelector('.sab-open-reports').click();
        expect(nav.mock.calls[0][0].detail.workspace).toBe('reports');
    });

    it('switches tabs to credits, customers and receipts', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        const tabs = root.querySelectorAll('.tab');
        tabs[1].click();
        await flush();
        expect(root.querySelector('.sab-credits tbody tr').textContent).toContain('INV-000140');
        tabs[2].click();
        await flush();
        const customers = root.querySelectorAll('.sab-customers tbody tr');
        expect(customers[0].querySelector('.meter').className).toBe('meter bad');
        expect(customers[0].textContent).toContain('91%');
        expect(customers[1].querySelector('.meter')).toBeNull();
        tabs[3].click();
        await flush();
        expect(getPayments).toHaveBeenCalled();
        const receipts = root.querySelectorAll('.sab-receipts tbody tr');
        expect(receipts.length).toBe(2);
        expect(receipts[0].textContent).toContain('Fully');
        expect(root.querySelectorAll('.tab')[3].textContent).toContain('2');
    });

    it('opens an overdue invoice drawer with lines and settlement', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.sab-invoices tbody tr').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        const drawer = root.querySelector('c-sab-drawer');
        expect(drawer.open).toBe(true);
        expect(drawer.heading).toBe('INV-000141');
        expect(drawer.subheading).toBe('Greenfield Produce, issued 1 Aug 2026, due 31 Aug 2026');
        expect(root.querySelector('.overdue').textContent).toContain('41 days overdue');
        expect(root.querySelector('.sab-lines tbody tr').textContent).toContain('4000 Sales');
        expect(root.querySelector('.sab-allocations tbody tr').textContent).toContain('PAY-000201');
        expect(root.querySelector('.sab-post-invoice')).toBeNull();
        drawer.dispatchEvent(new CustomEvent('close'));
        await flush();
        expect(root.querySelector('c-sab-drawer').open).toBe(false);
    });

    it('posts an approved invoice and reports errors', async () => {
        postInvoice.mockRejectedValueOnce({ body: { message: 'Accounting period is closed.' } });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelectorAll('.sab-invoices tbody tr')[1].click();
        await flush();
        root.querySelector('.sab-post-invoice').click();
        await flush();
        expect(toast.mock.calls[0][0].detail.tone).toBe('bad');
        root.querySelector('.sab-post-invoice').click();
        await flush();
        expect(postInvoice.mock.calls[1][0].request).toMatchObject({ invoiceId: 'I2', requestKey: expect.stringMatching(/^INV-POST-I2-/) });
        expect(toast.mock.calls[1][0].detail.message).toBe('INV-000148 posted');
    });

    it('handles permissions, empty data, record requests and errors', async () => {
        getSales.mockResolvedValue({ ...SALES, canPost: false, agingAvailable: false, invoices: [{ ...SALES.invoices[1] }], credits: [], customers: [] });
        getDocumentDetail.mockRejectedValueOnce({ body: { message: 'No access to lines.' } });
        const el = mount({ visibleWorkspaces: [] });
        el.recordId = 'I2';
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.aging')).toBeNull();
        expect(root.querySelector('.sab-post-invoice').title).toBe('Bookkeeper role cannot post invoices');
        expect(root.querySelector('c-sab-drawer .banner').textContent).toBe('No access to lines.');
        root.querySelectorAll('.tab')[1].click();
        await flush();
        expect(root.querySelector('.panel-b.muted').textContent).toBe('No credit notes yet.');
        root.querySelectorAll('.tab')[2].click();
        await flush();
        expect(root.querySelector('.panel-b.muted').textContent).toBe('No customer profiles yet.');
        getPayments.mockRejectedValueOnce({ body: { message: 'boom' } });
        root.querySelectorAll('.tab')[3].click();
        await flush();
        expect(root.querySelector('.panel-b.muted').textContent).toBe('No receipts yet.');

        getSales.mockRejectedValueOnce({ body: { message: 'You do not have active access to this Accounting Company.' } });
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have active access to this Accounting Company.');
        el2.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        expect(el2.shadowRoot.querySelector('.figs')).not.toBeNull();
        el2.recordId = 'missing';
    });

    it('opens the document editor, submits drafts and approves submitted invoices', async () => {
        getSales.mockResolvedValue({ ...SALES, canApprove: true, invoices: [...SALES.invoices,
            { documentId: 'I4', documentNumber: 'INV-DRAFT', documentType: 'Invoice', partyName: 'Coastal Foods', documentDate: '2026-10-02', dueDate: '2026-11-01', total: 100, status: 'Draft' },
            { documentId: 'I5', documentNumber: 'INV-SUB', documentType: 'Invoice', partyName: 'Coastal Foods', documentDate: '2026-10-02', dueDate: '2026-11-01', total: 100, status: 'Submitted' }] });
        submitInvoice.mockResolvedValue('Submitted');
        approveInvoice.mockRejectedValueOnce({ body: { message: 'An invoice must be approved by someone other than the person who created it.' } }).mockResolvedValue('Approved');
        const el = mount({ caps: { canCreateInvoice: true } });
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelector('.sab-new-invoice').click();
        await flush();
        const editor = root.querySelector('c-sab-document-editor');
        expect(editor.open).toBe(true);
        expect(editor.kind).toBe('invoice');
        editor.dispatchEvent(new CustomEvent('close'));
        root.querySelector('.sab-new-credit').click();
        await flush();
        expect(editor.kind).toBe('credit');
        editor.dispatchEvent(new CustomEvent('saved', { detail: { recordId: 'I4' } }));
        await flush();
        expect(root.querySelector('c-sab-drawer').heading).toBe('INV-DRAFT');
        root.querySelector('.sab-edit-invoice').click();
        await flush();
        expect(editor.recordId).toBe('I4');
        root.querySelector('.sab-submit-invoice').click();
        await flush();
        expect(submitInvoice.mock.calls[0][0]).toMatchObject({ invoiceId: 'I4', requestKey: expect.stringMatching(/^INV-SUBMIT-I4-/) });
        root.querySelectorAll('.sab-invoices tbody tr')[4].click();
        await flush();
        root.querySelector('.sab-approve-invoice').click();
        await flush();
        expect(toast.mock.calls[toast.mock.calls.length - 1][0].detail.tone).toBe('bad');
        root.querySelector('.sab-approve-invoice').click();
        await flush();
        expect(approveInvoice.mock.calls[1][0].requestKey).toBe(approveInvoice.mock.calls[0][0].requestKey);
    });

    it('explains when the role cannot create or approve invoices', async () => {
        getSales.mockResolvedValue({ ...SALES, canApprove: false, invoices: [{ documentId: 'I5', documentNumber: 'INV-SUB', status: 'Submitted', total: 1 }] });
        const el = mount({ caps: {} });
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-new-invoice').title).toBe('Bookkeeper role cannot create invoices');
        root.querySelector('.sab-invoices tbody tr').click();
        await flush();
        expect(root.querySelector('.sab-approve-invoice').title).toBe('Bookkeeper role cannot approve invoices');
    });
});
