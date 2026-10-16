import { createElement } from 'lwc';
import SabContactForm from 'c/sabContactForm';
import getFormOptions from '@salesforce/apex/SABContactService.getFormOptions';
import getContact from '@salesforce/apex/SABContactService.getContact';
import saveContact from '@salesforce/apex/SABContactService.saveContact';

jest.mock('@salesforce/apex/SABContactService.getFormOptions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABContactService.getContact', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABContactService.saveContact', () => ({ default: jest.fn() }), { virtual: true });

const OPTIONS = { canManage: true, functionalCurrency: 'AUD', arControls: [{ value: 'AR1', label: '1100 Receivables' }], apControls: [{ value: 'AP1', label: '2000 Payables' }],
    revenueAccounts: [{ value: 'R1', label: '4000 Sales' }], expenseAccounts: [{ value: 'E1', label: '6200 Fuel' }], taxCodes: [{ value: 'T1', label: 'GST' }],
    paymentTerms: [{ value: 'N30', label: 'Net 30 (30 days)' }], paymentMethods: ['Bank Transfer', 'Card'], defaultArControlId: 'AR1', defaultApControlId: 'AP1',
    defaultPaymentTermId: 'N30' };

async function flush() {
    for (let i = 0; i < 6; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-contact-form', { is: SabContactForm });
    Object.assign(el, { companyId: 'a01000000000001AAA', kind: 'supplier', ...props });
    document.body.appendChild(el);
    el.open = true;
    return el;
}

function set(root, field, value) {
    const input = root.querySelector(`[data-field="${field}"]`);
    if (input.type === 'checkbox') {
        input.checked = value;
        input.dispatchEvent(new CustomEvent('change'));
        return;
    }
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-contact-form', () => {
    beforeEach(() => {
        getFormOptions.mockResolvedValue(OPTIONS);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('creates a supplier with company defaults and asks before saving a duplicate', async () => {
        saveContact.mockResolvedValueOnce({ duplicateWarning: 'A supplier called Fuel Co already exists.' }).mockResolvedValueOnce({ profileId: 'P1' });
        const el = mount({ prefill: { name: 'Fuel Co', email: 'a@fuel.example' } });
        const saved = jest.fn();
        el.addEventListener('saved', saved);
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('c-sab-modal').heading).toBe('New supplier');
        expect(root.querySelector('[data-field="name"]').value).toBe('Fuel Co');
        expect(root.querySelector('[data-field="shippingStreet"]')).toBeNull();
        expect(root.querySelector('[data-field="bankAccountNumber"]')).not.toBeNull();
        set(root, 'bankAccountNumber', '123456789');
        set(root, 'taxNumber', '53 004');
        root.querySelector('.sab-contact-save').click();
        await flush();
        expect(root.querySelector('.duplicate').textContent).toContain('already exists');
        expect(saveContact.mock.calls[0][0].request).toMatchObject({ name: 'Fuel Co', email: 'a@fuel.example', isSupplier: true, isCustomer: false,
            apControlId: 'AP1', paymentTermId: 'N30', bankAccountNumber: '123456789', taxNumber: '53 004' });
        expect(saveContact.mock.calls[0][0].confirmDuplicate).toBe(false);
        root.querySelector('.sab-save-anyway').click();
        await flush();
        expect(saveContact.mock.calls[1][0].confirmDuplicate).toBe(true);
        expect(saveContact.mock.calls[1][0].requestKey).toBe(saveContact.mock.calls[0][0].requestKey);
        expect(saved.mock.calls[0][0].detail.profileId).toBe('P1');
    });

    it('edits a customer, can make it a supplier too, and reports errors', async () => {
        getContact.mockResolvedValue({ contact: { profileId: 'P2', name: 'Greenfield', isCustomer: true, isSupplier: false, creditLimit: 5000, arControlId: 'AR1' } });
        saveContact.mockRejectedValueOnce({ body: { message: 'Name is required.' } });
        const el = mount({ kind: 'customer', profileId: 'P2' });
        const closed = jest.fn();
        el.addEventListener('close', closed);
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('c-sab-modal').heading).toBe('Edit customer');
        expect(root.querySelector('[data-field="shippingStreet"]')).not.toBeNull();
        set(root, 'isSupplier', true);
        await flush();
        expect(root.querySelector('[data-field="apControlId"]')).not.toBeNull();
        set(root, 'creditLimit', '');
        set(root, 'paymentMethod', 'Card');
        root.querySelector('.sab-contact-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('Name is required.');
        expect(saveContact.mock.calls[0][0].request).toMatchObject({ profileId: 'P2', isCustomer: true, isSupplier: true, creditLimit: null, paymentMethod: 'Card' });
        root.querySelector('.sab-contact-cancel').click();
        expect(closed).toHaveBeenCalled();
        expect(el.open).toBe(false);
    });

    it('stays read-only without the permission and shows load errors', async () => {
        getFormOptions.mockResolvedValueOnce({ ...OPTIONS, canManage: false });
        const el = mount({ kind: 'customer' });
        await flush();
        expect(el.shadowRoot.querySelector('.sab-contact-save').disabled).toBe(true);
        expect(el.shadowRoot.querySelector('.sab-contact-save').title).toContain('SAB Manage Contacts Action');
        getFormOptions.mockRejectedValueOnce({ body: { message: 'No access.' } });
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.form-error').textContent).toBe('No access.');
        el2.open = false;
        expect(el2.open).toBe(false);
    });
});
