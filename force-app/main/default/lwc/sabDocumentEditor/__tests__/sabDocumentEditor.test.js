import { createElement } from 'lwc';
import SabDocumentEditor from 'c/sabDocumentEditor';
import getEntryOptions from '@salesforce/apex/SABDocumentEntryService.getEntryOptions';
import getDraft from '@salesforce/apex/SABDocumentEntryService.getDraft';
import saveInvoice from '@salesforce/apex/SABDocumentEntryService.saveInvoice';
import saveBill from '@salesforce/apex/SABDocumentEntryService.saveBill';
import savePayment from '@salesforce/apex/SABDocumentEntryService.savePayment';
import saveExpenseClaim from '@salesforce/apex/SABDocumentEntryService.saveExpenseClaim';

jest.mock('@salesforce/apex/SABDocumentEntryService.getEntryOptions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABDocumentEntryService.getDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABDocumentEntryService.saveInvoice', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABDocumentEntryService.saveBill', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABDocumentEntryService.savePayment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABDocumentEntryService.saveExpenseClaim', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABContactService.quickAdd', () => ({ default: jest.fn() }), { virtual: true });
import saveParty from '@salesforce/apex/SABContactService.quickAdd';

const OPTIONS = {
    currencyCode: 'AUD', customers: [{ value: 'C1', label: 'Greenfield' }, { value: 'C2', label: 'Coastal' }], suppliers: [{ value: 'S1', label: 'Fuel Co' }],
    revenueAccounts: [{ value: 'R1', label: '4000 Sales' }], expenseAccounts: [{ value: 'E1', label: '6000 Office' }], taxCodes: [{ value: 'T1', label: 'GST Goods and services' }],
    bankAccounts: [{ value: 'B1', label: 'Operating' }], departments: [{ value: 'D1', label: 'Operations' }], costCenters: [{ value: 'K1', label: 'CC-1' }],
    methods: [{ value: 'Bank Transfer', label: 'Bank Transfer' }, { value: 'Cash', label: 'Cash' }], projects: [{ value: 'P1', label: 'PRJ-1 Fit-out' }], employments: [{ value: 'M1', label: 'Maya Chen (EMP-1)' }], myEmploymentId: 'M1',
    creditableInvoices: [{ value: 'I1', label: 'INV-000141|C1' }, { value: 'I2', label: 'INV-000150|C2' }]
};

async function flush() {
    for (let i = 0; i < 10; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(kind, recordId) {
    const el = createElement('c-sab-document-editor', { is: SabDocumentEditor });
    el.companyId = 'a01000000000001AAA';
    el.kind = kind;
    el.recordId = recordId;
    document.body.appendChild(el);
    el.open = true;
    return el;
}

function set(root, selector, value) {
    const input = root.querySelector(selector);
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-document-editor', () => {
    beforeEach(() => {
        getEntryOptions.mockResolvedValue(OPTIONS);
        saveInvoice.mockResolvedValue('INV9');
        saveBill.mockResolvedValue('BILL9');
        savePayment.mockResolvedValue('PAY9');
        saveExpenseClaim.mockResolvedValue('CLAIM9');
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('creates an invoice with lines, a running total and a foreign rate', async () => {
        saveInvoice.mockRejectedValueOnce({ body: { message: 'Revenue account is required.' } });
        const el = mount('invoice');
        const saved = jest.fn();
        el.addEventListener('saved', saved);
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('c-sab-modal').heading).toBe('New invoice');
        expect(root.querySelector('[data-field="partyProfileId"]').value).toBe('C1');
        set(root, '[data-index="0"][data-field="description"]', 'Consulting');
        set(root, '[data-index="0"][data-field="quantity"]', '2');
        set(root, '[data-index="0"][data-field="unitPrice"]', '150');
        set(root, '[data-index="0"][data-field="discount"]', '10');
        root.querySelector('.sab-add-line').click();
        await flush();
        set(root, '[data-index="1"][data-field="description"]', 'Travel');
        set(root, '[data-index="1"][data-field="unitPrice"]', '50');
        await flush();
        expect(root.querySelector('.total').textContent).toBe('340.00');
        set(root, '[data-field="currencyCode"]', 'USD');
        await flush();
        set(root, '[data-field="exchangeRate"]', '1.52');
        root.querySelector('.sab-doc-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('Revenue account is required.');
        set(root, '[data-index="0"][data-field="accountId"]', 'R1');
        set(root, '[data-index="0"][data-field="taxCodeId"]', 'T1');
        set(root, '[data-index="1"][data-field="accountId"]', 'R1');
        root.querySelector('.sab-doc-save').click();
        await flush();
        const call = saveInvoice.mock.calls[1][0];
        expect(call.requestKey).toBe(saveInvoice.mock.calls[0][0].requestKey);
        expect(call.request).toMatchObject({ recordId: null, documentType: 'Invoice', partyProfileId: 'C1', currencyCode: 'USD', exchangeRate: 1.52 });
        expect(call.request.lines).toEqual([
            { description: 'Consulting', quantity: 2, unitPrice: 150, discount: 10, amount: null, accountId: 'R1', taxCodeId: 'T1', departmentId: null, costCenterId: null,
                projectId: null, category: null, expenseDate: null },
            { description: 'Travel', quantity: 1, unitPrice: 50, discount: null, amount: null, accountId: 'R1', taxCodeId: null, departmentId: null, costCenterId: null,
                projectId: null, category: null, expenseDate: null }]);
        expect(saved.mock.calls[0][0].detail).toEqual({ recordId: 'INV9', kind: 'invoice' });
    });

    it('creates a credit note against an invoice of the chosen customer', async () => {
        const el = mount('credit');
        await flush();
        const root = el.shadowRoot;
        expect(Array.from(root.querySelectorAll('[data-field="originalInvoiceId"] option')).map((o) => o.textContent)).toEqual(['Select', 'INV-000141']);
        set(root, '[data-field="partyProfileId"]', 'C2');
        await flush();
        expect(Array.from(root.querySelectorAll('[data-field="originalInvoiceId"] option')).map((o) => o.textContent)).toEqual(['Select', 'INV-000150']);
        set(root, '[data-field="originalInvoiceId"]', 'I2');
        const date = root.querySelector('[data-field="documentDate"]');
        date.value = '2026-10-01';
        date.dispatchEvent(new CustomEvent('input'));
        await flush();
        expect(root.querySelector('[data-field="dueDate"]').value).toBe('2026-10-31');
        root.querySelector('.sab-doc-save').click();
        await flush();
        expect(saveInvoice.mock.calls[0][0].request).toMatchObject({ documentType: 'Credit Note', originalInvoiceId: 'I2', partyProfileId: 'C2' });
    });

    it('edits a draft bill keeping its document type', async () => {
        getDraft.mockResolvedValue({ document: { recordId: 'BILL1', documentType: 'Supplier Credit', partyProfileId: 'S1', documentDate: '2026-09-01', dueDate: '2026-09-30',
            reference: 'SUP-9', currencyCode: 'AUD', lines: [{ description: 'Paper', quantity: 10, unitPrice: 5, accountId: 'E1' }] } });
        const el = mount('bill', 'BILL1');
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('c-sab-modal').heading).toBe('Edit supplier bill');
        expect(root.querySelector('[data-field="reference"]').value).toBe('SUP-9');
        expect(root.querySelector('[data-field="discount"]')).toBeNull();
        root.querySelectorAll('.sab-remove-line')[0].click();
        root.querySelector('.sab-add-line').click();
        await flush();
        set(root, '[data-index="0"][data-field="description"]', 'Ink');
        set(root, '[data-index="0"][data-field="unitPrice"]', '30');
        set(root, '[data-index="0"][data-field="accountId"]', 'E1');
        set(root, '[data-index="0"][data-field="departmentId"]', 'D1');
        root.querySelector('.sab-doc-save').click();
        await flush();
        expect(saveBill.mock.calls[0][0].request).toMatchObject({ recordId: 'BILL1', documentType: 'Supplier Credit', reference: 'SUP-9',
            lines: [{ description: 'Ink', unitPrice: 30, accountId: 'E1', departmentId: 'D1' }] });
    });

    it('records receipts and supplier payments and edits a draft payment', async () => {
        const el = mount('receipt');
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('c-sab-modal').subheading).toContain('Authorise and release it from Payments');
        set(root, '[data-field="amount"]', '420');
        set(root, '[data-field="method"]', 'Cash');
        set(root, '[data-field="reference"]', 'Counter');
        root.querySelector('.sab-doc-save').click();
        await flush();
        expect(savePayment.mock.calls[0][0].request).toMatchObject({ direction: 'Receipt', partyProfileId: 'C1', bankAccountId: 'B1', amount: 420, method: 'Cash', reference: 'Counter' });
        getDraft.mockResolvedValue({ payment: { partyProfileId: 'S1', bankAccountId: 'B1', amount: 99, effectiveDate: '2026-09-02', method: 'Bank Transfer', currencyCode: 'AUD' } });
        const el2 = mount('payment', 'PAY1');
        await flush();
        expect(el2.shadowRoot.querySelector('[data-field="amount"]').value).toBe('99');
        el2.shadowRoot.querySelector('.sab-doc-save').click();
        await flush();
        expect(savePayment.mock.calls[1][0].request).toMatchObject({ recordId: 'PAY1', direction: 'Disbursement', amount: 99 });
    });

    it('creates an expense claim for the current employee', async () => {
        const el = mount('claim');
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('[data-field="employmentId"]').value).toBe('M1');
        set(root, '[data-index="0"][data-field="category"]', 'Travel');
        set(root, '[data-index="0"][data-field="description"]', 'Taxi');
        set(root, '[data-index="0"][data-field="amount"]', '45');
        set(root, '[data-index="0"][data-field="accountId"]', 'E1');
        set(root, '[data-index="0"][data-field="expenseDate"]', '2026-09-20');
        await flush();
        expect(root.querySelector('.total').textContent).toBe('45.00');
        root.querySelector('.sab-doc-save').click();
        await flush();
        expect(saveExpenseClaim.mock.calls[0][0].request).toMatchObject({ employmentId: 'M1', currencyCode: 'AUD',
            lines: [{ category: 'Travel', description: 'Taxi', amount: 45, accountId: 'E1', expenseDate: '2026-09-20' }] });
        getDraft.mockResolvedValue({ claim: { employmentId: 'M1', claimDate: '2026-09-21', currencyCode: 'AUD',
            lines: [{ category: 'Meals', description: 'Lunch', amount: 20, accountId: 'E1' }] } });
        const el2 = mount('claim', 'CLAIM1');
        await flush();
        expect(el2.shadowRoot.querySelector('[data-index="0"][data-field="category"]').value).toBe('Meals');
    });

    it('shows load errors and closes', async () => {
        getEntryOptions.mockRejectedValueOnce({ body: { message: 'You do not have active access to this Accounting Company.' } });
        const el = mount('invoice');
        const closed = jest.fn();
        el.addEventListener('close', closed);
        await flush();
        expect(el.shadowRoot.querySelector('.form-error').textContent).toBe('You do not have active access to this Accounting Company.');
        expect(el.shadowRoot.querySelector('.sab-doc-save').disabled).toBe(true);
        el.shadowRoot.querySelector('.sab-doc-cancel').click();
        expect(closed).toHaveBeenCalled();
        el.open = false;
        expect(el.open).toBe(false);
    });

    it('adds a new supplier from the bill and a new customer from a receipt', async () => {
        saveParty.mockRejectedValueOnce({ body: { message: 'Add an active accounts payable control account in Chart of accounts first.' } })
            .mockResolvedValueOnce({ duplicateWarning: 'A supplier called Riverside Property already exists.' }).mockResolvedValueOnce({ profileId: 'S9' });
        const el = mount('bill');
        await flush();
        const root = el.shadowRoot;
        const partySelect = root.querySelector('[data-field="partyProfileId"]');
        partySelect.value = '__new__';
        partySelect.dispatchEvent(new CustomEvent('change'));
        await flush();
        const name = root.querySelector('.sab-party-name');
        name.value = 'Riverside Property';
        name.dispatchEvent(new CustomEvent('input'));
        root.querySelector('.sab-party-save').click();
        await flush();
        expect(root.querySelector('.party-error').textContent).toContain('accounts payable control account');
        root.querySelector('.sab-party-save').click();
        await flush();
        expect(root.querySelector('.party-duplicate').textContent).toContain('already exists');
        getEntryOptions.mockResolvedValueOnce({ ...OPTIONS, suppliers: [...OPTIONS.suppliers, { value: 'S9', label: 'Riverside Property' }] });
        root.querySelector('.sab-party-anyway').click();
        await flush();
        expect(saveParty.mock.calls[2][0]).toMatchObject({ companyId: 'a01000000000001AAA', name: 'Riverside Property', email: null, isCustomer: false,
            isSupplier: true, confirmDuplicate: true });
        expect(root.querySelector('[data-field="partyProfileId"]').value).toBe('S9');
        expect(root.querySelector('.sab-party-name')).toBeNull();

        saveParty.mockResolvedValueOnce({ profileId: 'C9' });
        const el2 = mount('receipt');
        await flush();
        const picker = el2.shadowRoot.querySelector('c-sab-party-picker');
        expect(picker.addLabel).toBe('Add new customer');
        picker.dispatchEvent(new CustomEvent('change', { detail: { value: 'C1' } }));
        await flush();
        expect(picker.value).toBe('C1');
        picker.dispatchEvent(new CustomEvent('addnew'));
        await flush();
        el2.shadowRoot.querySelector('.sab-party-save').click();
        await flush();
        expect(saveParty.mock.calls[3][0]).toMatchObject({ isCustomer: true, isSupplier: false, confirmDuplicate: false });
        expect(picker.value).toBe('C9');
        picker.dispatchEvent(new CustomEvent('addnew'));
        await flush();
        const email = el2.shadowRoot.querySelector('.sab-party-email');
        email.value = 'ap@x.example';
        email.dispatchEvent(new CustomEvent('input'));
        el2.shadowRoot.querySelector('.sab-party-more').click();
        await flush();
        const form = el2.shadowRoot.querySelector('c-sab-contact-form');
        expect(form.open).toBe(true);
        expect(form.kind).toBe('customer');
        expect(form.prefill).toEqual({ name: '', email: 'ap@x.example' });
        getEntryOptions.mockResolvedValueOnce({ ...OPTIONS, customers: [...OPTIONS.customers, { value: 'C10', label: 'Full form customer' }] });
        form.dispatchEvent(new CustomEvent('saved', { detail: { profileId: 'C10' } }));
        await flush();
        expect(picker.value).toBe('C10');
        form.dispatchEvent(new CustomEvent('close'));
    });

    it('tags lines with a project and cost center and points to People when there are no employees', async () => {
        const el = mount('invoice');
        await flush();
        const root = el.shadowRoot;
        set(root, '[data-index="0"][data-field="description"]', 'Fit-out');
        set(root, '[data-index="0"][data-field="unitPrice"]', '100');
        set(root, '[data-index="0"][data-field="accountId"]', 'R1');
        set(root, '[data-index="0"][data-field="projectId"]', 'P1');
        set(root, '[data-index="0"][data-field="costCenterId"]', 'K1');
        root.querySelector('.sab-doc-save').click();
        await flush();
        expect(saveInvoice.mock.calls[0][0].request.lines[0]).toMatchObject({ projectId: 'P1', costCenterId: 'K1' });

        getEntryOptions.mockResolvedValueOnce({ ...OPTIONS, employments: [], myEmploymentId: null });
        const el2 = mount('claim');
        await flush();
        const nav = jest.fn();
        el2.addEventListener('sabnavigate', nav);
        const closed = jest.fn();
        el2.addEventListener('close', closed);
        expect(el2.shadowRoot.querySelector('[data-field="costCenterId"]')).toBeNull();
        el2.shadowRoot.querySelector('.sab-open-people').click();
        expect(nav.mock.calls[0][0].detail).toEqual({ workspace: 'payroll', recordId: 'staff' });
        expect(closed).toHaveBeenCalled();
    });
});
