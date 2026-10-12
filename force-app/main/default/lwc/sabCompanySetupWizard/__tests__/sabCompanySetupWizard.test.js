import { createElement } from 'lwc';
import SabCompanySetupWizard from 'c/sabCompanySetupWizard';
import getSetupState from '@salesforce/apex/SABCompanySetupWizardController.getSetupState';

jest.mock('@salesforce/apex/SABCompanySetupWizardController.getSetupState', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.getSetupRecords', () => ({ default: jest.fn().mockResolvedValue([]) }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.canManageSetup', () => ({ default: jest.fn().mockResolvedValue(true) }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.createCompany', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.saveCompany', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.savePeriod', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.saveAccount', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.saveSequence', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.saveFeature', () => ({ default: jest.fn() }), { virtual: true });

async function flush() {
    for (let i = 0; i < 8; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

describe('c-sab-company-setup-wizard', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        window.sessionStorage.clear();
        jest.clearAllMocks();
    });

    it('opens the in-app setup editor instead of navigating away and reloads after a save', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', 'a01000000000001AAA');
        getSetupState.mockResolvedValue({ companyId: 'a01000000000001AAA', companyName: 'Ratuls Company Ltd' });
        const el = createElement('c-sab-company-setup-wizard', { is: SabCompanySetupWizard });
        document.body.appendChild(el);
        await flush();
        const editor = el.shadowRoot.querySelector('c-sab-setup-records');
        expect(editor.open).toBe(false);
        const buttons = Array.from(el.shadowRoot.querySelectorAll('[data-object-api]'));
        const periods = buttons.find((b) => b.dataset.objectApi === 'Accounting_Period__c');
        periods.click();
        await flush();
        expect(editor.open).toBe(true);
        expect(editor.kind).toBe('period');
        const company = buttons.find((b) => b.dataset.objectApi === 'Accounting_Company__c');
        company.click();
        await flush();
        expect(editor.kind).toBe('company');
        editor.dispatchEvent(new CustomEvent('saved', { detail: { recordId: 'a01000000000001AAA' } }));
        await flush();
        expect(getSetupState).toHaveBeenCalledTimes(2);
        editor.dispatchEvent(new CustomEvent('close'));
        await flush();
        expect(editor.open).toBe(false);
    });
});
