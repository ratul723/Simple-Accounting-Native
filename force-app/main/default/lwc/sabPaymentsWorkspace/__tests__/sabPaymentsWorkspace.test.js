import { createElement } from 'lwc';
import SabPaymentsWorkspace from 'c/sabPaymentsWorkspace';
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
import { friendly } from 'c/sabPaymentsWorkspace';

const MOCKS = ['SABMoneyWorkspaceController.getPayments', 'SABCustomerReceiptService.authorize', 'SABCustomerReceiptService.submitForProcessing',
    'SABCustomerReceiptService.markFailed', 'SABCustomerReceiptService.retryFailed', 'SABCustomerReceiptPostingService.recordSucceededAndPost',
    'SABSupplierPaymentService.authorize', 'SABSupplierPaymentService.submitForExecution', 'SABSupplierPaymentService.markFailed',
    'SABSupplierPaymentService.retryFailed', 'SABSupplierPaymentPostingService.recordSucceededAndPost', 'SABCustomerReceiptAllocationService.allocateToInvoices',
    'SABPaymentActionService.allocateDisbursement', 'SABForeignCurrencySettlementService.authorizeForeignPayment',
    'SABForeignCurrencySettlementService.submitForeignPayment', 'SABForeignCurrencySettlementService.postForeignPayment'];
jest.mock('@salesforce/apex/SABMoneyWorkspaceController.getPayments', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABCustomerReceiptService.authorize', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABCustomerReceiptService.submitForProcessing', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABCustomerReceiptService.markFailed', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABCustomerReceiptService.retryFailed', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABCustomerReceiptPostingService.recordSucceededAndPost', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSupplierPaymentService.authorize', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSupplierPaymentService.submitForExecution', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSupplierPaymentService.markFailed', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSupplierPaymentService.retryFailed', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSupplierPaymentPostingService.recordSucceededAndPost', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABCustomerReceiptAllocationService.allocateToInvoices', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPaymentActionService.allocateDisbursement', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABForeignCurrencySettlementService.authorizeForeignPayment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABForeignCurrencySettlementService.submitForeignPayment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABForeignCurrencySettlementService.postForeignPayment', () => ({ default: jest.fn() }), { virtual: true });

const pay = (id, direction, state, extra = {}) => ({ paymentId: id, paymentNumber: `PAY-${id}`, direction, partyProfileId: 'C1', partyName: 'Greenfield',
    effectiveDate: '2026-10-10', bankName: 'Operating', method: 'EFT', amount: 1000, currencyCode: 'AUD', state, allocated: 0, allocations: [], ...extra });

function data(overrides = {}) {
    return {
        currencyCode: 'AUD', canApprove: true, canPost: true, canEdit: true, receivedThisMonth: 5000, paidThisMonth: 2000, unallocatedReceipts: 600,
        unallocatedReceiptCount: 1, awaitingRelease: 1000, awaitingReleaseCount: 1,
        payments: [
            pay('R1', 'Receipt', 'Draft'), pay('D1', 'Disbursement', 'Authorized'), pay('R2', 'Receipt', 'Submitted'), pay('D2', 'Disbursement', 'Failed'),
            pay('R3', 'Receipt', 'Succeeded', { allocated: 400, allocations: [{ allocationId: 'AL1', documentNumber: 'INV-1', allocationDate: '2026-10-10', amount: 400 }] }),
            pay('D3', 'Disbursement', 'Submitted', { managedBy: 'Payroll' }), pay('D4', 'Disbursement', 'Draft'), pay('R4', 'Receipt', 'Succeeded', { partyProfileId: 'X' })
        ],
        openInvoices: [{ documentId: 'I1', documentNumber: 'INV-2', partyProfileId: 'C1', dueDate: '2026-10-31', outstanding: 500 },
            { documentId: 'I2', documentNumber: 'INV-3', partyProfileId: 'C1', dueDate: '2026-11-30', outstanding: 300 }],
        ...overrides
    };
}

async function flush() {
    for (let i = 0; i < 8; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-payments-workspace', { is: SabPaymentsWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', persona: { label: 'Treasury' }, ...props });
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

function open(root, id) {
    Array.from(root.querySelectorAll('.sab-payments tbody tr')).find((r) => r.dataset.id === id).click();
}

describe('c-sab-payments-workspace', () => {
    beforeEach(() => {
        getPayments.mockResolvedValue(data());
        [authorizeReceipt, submitReceipt, failReceipt, retryReceipt, postReceipt, authorizePayment, submitPayment, failPayment, retryPayment, postPayment, allocateReceipt]
            .forEach((m) => m.mockResolvedValue({}));
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders figures, the failed banner and filtered tabs', async () => {
        expect(MOCKS.length).toBe(16);
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(Array.from(root.querySelectorAll('.fig .v')).map((v) => v.textContent)).toEqual(['5,000AUD', '2,000AUD', '600AUD', '1,000AUD']);
        expect(root.querySelector('.failed-banner').textContent).toContain('1 payment failed at the bank');
        expect(root.querySelectorAll('.sab-payments tbody tr').length).toBe(8);
        const tabs = root.querySelectorAll('.tab');
        expect(tabs[3].textContent).toContain('2');
        tabs[1].click();
        await flush();
        expect(root.querySelectorAll('.sab-payments tbody tr').length).toBe(4);
        tabs[2].click();
        await flush();
        expect(root.querySelectorAll('.sab-payments tbody tr').length).toBe(4);
        tabs[3].click();
        await flush();
        expect(root.querySelectorAll('.sab-payments tbody tr').length).toBe(2);
        root.querySelector('.sab-review-failed').click();
        await flush();
        expect(root.querySelector('c-sab-drawer').heading).toBe('PAY-D2');
    });

    it('runs the receipt lifecycle', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        open(root, 'R1');
        await flush();
        root.querySelector('.sab-authorize').click();
        await flush();
        expect(authorizeReceipt).toHaveBeenCalledWith({ paymentId: 'R1', requestKey: expect.stringMatching(/^PAY-AUTH-R1-/) });
        open(root, 'R2');
        await flush();
        root.querySelector('.sab-clear').click();
        await flush();
        expect(postReceipt.mock.calls[0][0].request).toMatchObject({ paymentId: 'R2' });
        open(root, 'R2');
        await flush();
        root.querySelector('.sab-fail').click();
        await flush();
        root.querySelector('.sab-fail-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('A reason is required.');
        const area = root.querySelector('.sab-fail-reason');
        area.value = 'Account closed';
        area.dispatchEvent(new CustomEvent('input'));
        root.querySelector('.sab-fail-save').click();
        await flush();
        expect(failReceipt.mock.calls[0][0]).toMatchObject({ paymentId: 'R2', reason: 'Account closed' });
    });

    it('runs the disbursement lifecycle', async () => {
        submitPayment.mockRejectedValueOnce({ body: { message: 'Bank account is inactive.' } });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        open(root, 'D4');
        await flush();
        root.querySelector('.sab-authorize').click();
        await flush();
        expect(authorizePayment).toHaveBeenCalled();
        open(root, 'D1');
        await flush();
        root.querySelector('.sab-release').click();
        await flush();
        expect(submitPayment.mock.calls[0][0]).toMatchObject({ paymentId: 'D1', providerRequestKey: expect.stringMatching(/^PROVIDER-D1-/) });
        expect(toast.mock.calls[1][0].detail).toEqual({ message: 'Bank account is inactive.', tone: 'bad' });
        open(root, 'D2');
        await flush();
        expect(root.querySelector('c-sab-drawer .banner').textContent).toContain('Bank rejected this payment');
        root.querySelector('.sab-retry').click();
        await flush();
        expect(retryPayment).toHaveBeenCalled();
        const submitted = data().payments.map((p) => (p.paymentId === 'D1' ? { ...p, state: 'Submitted' } : p));
        getPayments.mockResolvedValue(data({ payments: submitted }));
        await el.shadowRoot.querySelector('c-sab-drawer');
        el.recordId = 'D1';
        await flush();
    });

    it('allocates a receipt and shows payroll and empty cases', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        open(root, 'R3');
        await flush();
        expect(root.querySelector('.sab-allocations tbody tr').textContent).toContain('INV-1');
        const inputs = root.querySelectorAll('.sab-open-invoices input');
        expect(inputs.length).toBe(2);
        root.querySelector('.sab-allocate').click();
        await flush();
        inputs[0].value = '500';
        inputs[0].dispatchEvent(new CustomEvent('input'));
        inputs[1].value = '100';
        inputs[1].dispatchEvent(new CustomEvent('input'));
        root.querySelector('.sab-allocate').click();
        await flush();
        expect(allocateReceipt.mock.calls[0][0].receiptId).toBe('R3');
        expect(allocateReceipt.mock.calls[0][0].requests.map((r) => [r.invoiceId, r.allocatedAmount])).toEqual([['I1', 500], ['I2', 100]]);
        open(root, 'R4');
        await flush();
        expect(root.querySelector('c-sab-drawer p.small:last-of-type').textContent).toContain('no open posted invoices');
        open(root, 'D3');
        await flush();
        expect(root.querySelector('c-sab-drawer .banner').textContent).toContain('People & payroll');
        expect(root.querySelector('.sab-clear')).toBeNull();
        root.querySelector('c-sab-drawer').dispatchEvent(new CustomEvent('close'));
        await flush();
        expect(root.querySelector('c-sab-drawer').open).toBe(false);
    });

    it('explains permission limits and handles errors', async () => {
        getPayments.mockResolvedValue(data({ canApprove: false, canPost: false, canEdit: false, payments: [pay('R1', 'Receipt', 'Draft'),
            pay('R2', 'Receipt', 'Submitted'), pay('D9', 'Disbursement', 'Succeeded', { managedBy: 'Equity' })] }));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.failed-banner')).toBeNull();
        open(root, 'R1');
        await flush();
        expect(root.querySelector('.sab-authorize').title).toBe('Treasury role cannot authorise payments');
        open(root, 'R2');
        await flush();
        expect(root.querySelector('.sab-clear').title).toBe('Treasury role cannot post payments');
        expect(root.querySelector('.sab-fail').title).toBe('Treasury role cannot change payments');
        open(root, 'D9');
        await flush();
        expect(root.querySelector('c-sab-drawer .banner').textContent).toContain('Capital & equity');
        root.querySelectorAll('.tab')[3].click();
        await flush();
        expect(root.querySelector('.panel-b.muted').textContent).toBe('No payments match this view.');
        el.recordId = 'missing';

        getPayments.mockRejectedValueOnce({ body: { message: 'You do not have active access to this Accounting Company.' } });
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have active access to this Accounting Company.');
        el2.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        el2.shadowRoot.querySelectorAll('.sab-payments tbody tr')[0].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        el2.shadowRoot.querySelectorAll('.sab-payments tbody tr')[0].dispatchEvent(new KeyboardEvent('keydown', { key: 'a' }));
        await flush();
        expect(el2.shadowRoot.querySelector('c-sab-drawer').open).toBe(true);
    });

    it('records receipts and payments and edits drafts in the document editor', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        const editor = root.querySelector('c-sab-document-editor');
        root.querySelector('.sab-new-receipt').click();
        await flush();
        expect(editor.kind).toBe('receipt');
        root.querySelector('.sab-new-payment').click();
        await flush();
        expect(editor.kind).toBe('payment');
        editor.dispatchEvent(new CustomEvent('close'));
        open(root, 'D4');
        await flush();
        root.querySelector('.sab-edit-payment').click();
        await flush();
        expect(editor.kind).toBe('payment');
        expect(editor.recordId).toBe('D4');
        editor.dispatchEvent(new CustomEvent('saved', { detail: { recordId: 'D4' } }));
        await flush();
        expect(root.querySelector('c-sab-drawer').heading).toBe('PAY-D4');
    });

    it('allocates a cleared supplier payment to open bills', async () => {
        getPayments.mockResolvedValue(data({ canAllocate: true, payments: [pay('D9', 'Disbursement', 'Succeeded', { partyProfileId: 'S1', partyName: 'Fuel Co' })],
            openBills: [{ documentId: 'B1', documentNumber: 'BILL-1 (F-9)', partyProfileId: 'S1', dueDate: '2026-10-31', outstanding: 600 },
                { documentId: 'B2', documentNumber: 'BILL-2', partyProfileId: 'OTHER', outstanding: 50 }] }));
        allocateDisbursement.mockResolvedValue(1);
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelectorAll('.tab')[3].textContent).toContain('1');
        open(root, 'D9');
        await flush();
        expect(root.querySelector('.allocate-title').textContent).toBe('Allocate 1,000.00 to open bills');
        const rows = root.querySelectorAll('.sab-open-invoices tbody tr');
        expect(rows.length).toBe(1);
        expect(root.querySelector('.sab-open-invoices thead').textContent).toContain('Bill');
        const input = rows[0].querySelector('input');
        input.value = '600';
        input.dispatchEvent(new CustomEvent('input'));
        root.querySelector('.sab-allocate').click();
        await flush();
        expect(allocateDisbursement.mock.calls[0][0]).toMatchObject({ paymentId: 'D9', lines: [{ supplierBillId: 'B1', amount: 600 }] });

        getPayments.mockResolvedValue(data({ canAllocate: false, payments: [pay('D8', 'Disbursement', 'Succeeded', { partyProfileId: 'S2' })], openBills: [] }));
        const el2 = mount();
        await flush();
        open(el2.shadowRoot, 'D8');
        await flush();
        expect(Array.from(el2.shadowRoot.querySelectorAll('c-sab-drawer p.muted.small')).map((x) => x.textContent)).toContain('This supplier has no open posted bills to allocate to.');
    });

    it('sends foreign-currency payments through the foreign-currency service', async () => {
        getPayments.mockResolvedValue(data({ payments: [pay('F1', 'Disbursement', 'Draft', { currencyCode: 'USD' }), pay('F2', 'Disbursement', 'Authorized', { currencyCode: 'USD' }),
            pay('F3', 'Disbursement', 'Submitted', { currencyCode: 'USD' }), pay('F4', 'Disbursement', 'Succeeded', { currencyCode: 'USD' })] }));
        authorizeForeign.mockRejectedValueOnce({ body: { message: 'No approved Spot exchange rate exists for USD to AUD at or before 2026-10-14 23:59:59.' } })
            .mockResolvedValue({});
        [submitForeign, postForeign].forEach((m) => m.mockResolvedValue({}));
        const el = mount();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const nav = jest.fn();
        el.addEventListener('sabnavigate', nav);
        await flush();
        const root = el.shadowRoot;
        open(root, 'F1');
        await flush();
        expect(root.querySelector('.sab-foreign-note').textContent).toContain('USD');
        root.querySelector('.sab-authorize').click();
        await flush();
        expect(toast.mock.calls[0][0].detail.message).toBe('No approved Spot rate from USD to AUD for this date. Add one in Foreign exchange > Exchange rates.');
        root.querySelector('.sab-authorize').click();
        await flush();
        expect(authorizePayment).not.toHaveBeenCalled();
        expect(authorizeForeign).toHaveBeenCalledTimes(2);
        open(root, 'F2');
        await flush();
        root.querySelector('.sab-release').click();
        await flush();
        expect(submitForeign.mock.calls[0][0]).toMatchObject({ paymentId: 'F2' });
        open(root, 'F3');
        await flush();
        root.querySelector('.sab-clear').click();
        await flush();
        expect(postForeign.mock.calls[0][0]).toMatchObject({ paymentId: 'F3' });
        open(root, 'F4');
        await flush();
        expect(root.querySelector('.sab-open-invoices')).toBeNull();
        root.querySelector('.sab-open-fx').click();
        expect(nav.mock.calls[0][0].detail.workspace).toBe('fx');
    });

    it('shortens long settlement messages', () => {
        expect(friendly('Payment currency must match the bank account currency; same-currency supplier disbursements only are supported.'))
            .toContain('approved exchange rate');
        expect(friendly('No approved rate anywhere.')).toBe('No approved exchange rate for this date. Add one in Foreign exchange > Exchange rates.');
        expect(friendly('Other message.')).toBe('Other message.');
    });
});
