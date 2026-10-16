import { createElement } from 'lwc';
import SabCustomersWorkspace from 'c/sabCustomersWorkspace';

jest.mock('@salesforce/apex/SABContactService.getContacts', () => ({ default: jest.fn(() => Promise.resolve({ rows: [] })) }), { virtual: true });
jest.mock('@salesforce/apex/SABContactService.getContact', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABContactService.setActive', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABContactService.getFormOptions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABContactService.saveContact', () => ({ default: jest.fn() }), { virtual: true });

describe('c-sab-customers-workspace', () => {
    it('passes the company to the customers list', () => {
        const el = createElement('c-sab-customers-workspace', { is: SabCustomersWorkspace });
        el.companyId = 'a01000000000001AAA';
        el.companyName = 'Harbourline';
        document.body.appendChild(el);
        const list = el.shadowRoot.querySelector('c-sab-contacts');
        expect(list.companyId).toBe('a01000000000001AAA');
        expect(list.kind).toBe('customer');
        expect(el.shadowRoot.querySelector('c-sab-workspace-header').heading).toBe('Customers');
        document.body.removeChild(el);
    });
});
