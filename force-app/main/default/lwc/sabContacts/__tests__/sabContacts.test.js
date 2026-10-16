import { createElement } from 'lwc';
import SabContacts from 'c/sabContacts';
import getContacts from '@salesforce/apex/SABContactService.getContacts';
import getContact from '@salesforce/apex/SABContactService.getContact';
import setActive from '@salesforce/apex/SABContactService.setActive';

jest.mock('@salesforce/apex/SABContactService.getContacts', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABContactService.getContact', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABContactService.setActive', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABContactService.getFormOptions', () => ({ default: jest.fn(() => Promise.resolve({})) }), { virtual: true });
jest.mock('@salesforce/apex/SABContactService.saveContact', () => ({ default: jest.fn() }), { virtual: true });

const LIST = { canManage: true, functionalCurrency: 'AUD', rows: [
    { profileId: 'P1', name: 'Fuel Co', email: 'a@fuel.example', phone: '555', isCustomer: false, isSupplier: true, active: true, outstanding: 1000, overdue: 400 },
    { profileId: 'P2', name: 'Riverside', isCustomer: true, isSupplier: true, active: true, outstanding: 0, overdue: 0 },
    { profileId: 'P3', name: 'Old Supplier', isSupplier: true, active: false, outstanding: 0, overdue: 0 }] };
const DETAIL = { active: true, canManage: true, paymentTermName: 'Net 14', taxCodeName: 'GST',
    contact: { profileId: 'P1', name: 'Fuel Co', isSupplier: true, isCustomer: false, email: 'a@fuel.example', billingCity: 'Newcastle', bankAccountNumber: '123456789' },
    documents: [{ recordId: 'B1', reference: 'BILL-1', kind: 'Bill', documentDate: '2026-10-01', amount: 1000, status: 'Posted' }],
    payments: [{ recordId: 'PM1', reference: 'PMT-1', kind: 'Disbursement', documentDate: '2026-10-05', amount: 600, status: 'Succeeded' }],
    statement: [{ entryDate: '2026-10-01', reference: 'BILL-1', description: 'Bill', charge: 1000, paid: 0, balance: 1000 },
        { entryDate: '2026-10-05', reference: 'PMT-1', description: 'Payment', charge: 0, paid: 600, balance: 400 }] };

async function flush() {
    for (let i = 0; i < 6; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-contacts', { is: SabContacts });
    Object.assign(el, { kind: 'supplier', companyName: 'Harbourline', ...props });
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

describe('c-sab-contacts', () => {
    beforeEach(() => {
        getContacts.mockResolvedValue(LIST);
        getContact.mockResolvedValue(DETAIL);
        setActive.mockResolvedValue('P1');
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('lists, filters and searches contacts with balances', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(getContacts).toHaveBeenCalledWith({ companyId: 'a01000000000001AAA', kind: 'supplier' });
        const rows = root.querySelectorAll('.sab-contacts tbody tr');
        expect(rows.length).toBe(2);
        expect(rows[0].textContent).toContain('a@fuel.example \u00b7 555');
        expect(rows[0].querySelector('.down').textContent).toBe('400.00');
        expect(rows[1].textContent).toContain('Customer and supplier');
        expect(root.querySelector('.sub').textContent).toBe('2 active suppliers, 1,000.00 AUD outstanding');
        root.querySelectorAll('.sab-contact-filter button')[1].click();
        await flush();
        expect(root.querySelector('.sab-contacts tbody tr').textContent).toContain('Old Supplier');
        root.querySelectorAll('.sab-contact-filter button')[2].click();
        const search = root.querySelector('.sab-contact-search');
        search.value = 'zzz';
        search.dispatchEvent(new CustomEvent('input'));
        await flush();
        expect(root.querySelector('.sab-contacts-empty').textContent).toBe('No suppliers match "zzz".');
        expect(root.querySelector('.sab-new-contact').textContent).toContain('New supplier');
    });

    it('opens the detail panel with tabs, edits and deactivates', async () => {
        const el = mount();
        await flush();
        const nav = jest.fn();
        el.addEventListener('sabnavigate', nav);
        const root = el.shadowRoot;
        root.querySelector('.sab-contacts tbody tr').click();
        await flush();
        expect(root.querySelector('c-sab-drawer').heading).toBe('Fuel Co');
        expect(root.querySelector('.sab-contact-facts').textContent).toContain('Net 14');
        const tabs = root.querySelectorAll('c-sab-drawer .tab');
        expect(tabs[1].textContent).toBe('Bills');
        tabs[1].click();
        await flush();
        root.querySelector('.sab-contact-docs tr').click();
        expect(nav.mock.calls[0][0].detail).toEqual({ workspace: 'purchases', recordId: 'B1' });
        root.querySelectorAll('c-sab-drawer .tab')[2].click();
        await flush();
        root.querySelector('.sab-contact-payments tr').click();
        expect(nav.mock.calls[1][0].detail.workspace).toBe('payments');
        root.querySelectorAll('c-sab-drawer .tab')[3].click();
        await flush();
        expect(root.querySelectorAll('.sab-contact-statement tbody tr')[1].textContent).toContain('400.00');
        root.querySelector('.sab-detail-edit').click();
        await flush();
        expect(root.querySelector('c-sab-contact-form').profileId).toBe('P1');
        expect(root.querySelector('c-sab-contact-form').open).toBe(true);
        root.querySelector('c-sab-contact-form').dispatchEvent(new CustomEvent('saved', { detail: { profileId: 'P1' } }));
        await flush();
        root.querySelector('.sab-row-toggle').click();
        await flush();
        expect(setActive.mock.calls[0][0]).toMatchObject({ profileId: 'P1', active: false });
        setActive.mockRejectedValueOnce({ body: { message: 'Denied.' } });
        root.querySelector('.sab-detail-toggle').click();
        await flush();
        root.querySelector('c-sab-drawer').dispatchEvent(new CustomEvent('close'));
        await flush();
        expect(root.querySelector('c-sab-drawer').open).toBe(false);
    });

    it('handles no permission, a record from search, keyboard and errors', async () => {
        getContacts.mockResolvedValueOnce({ ...LIST, canManage: false, balanceNote: 'Balances are not shown: no access.' });
        const el = mount({ recordId: 'P1' });
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-new-contact').disabled).toBe(true);
        expect(root.querySelector('.sab-row-edit')).toBeNull();
        expect(root.querySelector('.banner.t-warn').textContent).toContain('no access');
        expect(root.querySelector('c-sab-drawer').open).toBe(true);
        const row = root.querySelectorAll('.sab-contacts tbody tr')[1];
        row.dispatchEvent(new KeyboardEvent('keydown', { key: 'x' }));
        row.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        getContact.mockRejectedValueOnce({ body: { message: 'Gone.' } });
        root.querySelector('.sab-contacts tbody tr').click();
        await flush();
        expect(root.querySelector('c-sab-drawer .banner').textContent).toBe('Gone.');
        getContacts.mockRejectedValueOnce({ body: { message: 'Down.' } });
        const el2 = mount({ kind: 'customer' });
        await flush();
        expect(el2.shadowRoot.querySelector('.empty p').textContent).toBe('Down.');
        el2.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        expect(el2.shadowRoot.querySelector('.sab-new-contact').textContent).toContain('New customer');
        el2.shadowRoot.querySelector('.sab-new-contact').click();
        await flush();
        el2.shadowRoot.querySelector('c-sab-contact-form').dispatchEvent(new CustomEvent('close'));
    });
});
