import { createElement } from 'lwc';
import SabSetupWorkspace from 'c/sabSetupWorkspace';
import getSetupState from '@salesforce/apex/SABCompanySetupWizardController.getSetupState';
import getSetupRecords from '@salesforce/apex/SABSetupRecordService.getSetupRecords';
import getAccessibleCompanies from '@salesforce/apex/SABCompanyContextController.getAccessibleCompanies';

jest.mock('@salesforce/apex/SABCompanySetupWizardController.getSetupState', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABCompanyContextController.getAccessibleCompanies', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.getSetupRecords', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.canManageSetup', () => ({ default: jest.fn().mockResolvedValue(true) }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.createCompany', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.saveCompany', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.savePeriod', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.saveAccount', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.saveSequence', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.saveFeature', () => ({ default: jest.fn() }), { virtual: true });

const COMPANY = 'a01000000000001AAA';
const READY = {
    companyId: COMPANY, companyName: 'Ratuls Company Ltd', companyKey: 'com2', countryCode: 'US', functionalCurrency: 'USD',
    fiscalCalendarType: 'Calendar', fiscalYearStartMonth: 1, setupStatus: 'Validated', companyActive: true, readyForCoreAccounting: true,
    errors: [], warnings: [], periodCount: 13, openPeriodCount: 12, activeGLAccountCount: 56, activeSequenceCount: 1, enabledFeatureCount: 1
};

async function flush() {
    for (let i = 0; i < 8; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-setup-workspace', { is: SabSetupWorkspace });
    Object.assign(el, { companyName: 'Ratuls Company Ltd', caps: { canCreateCompany: true }, ...props });
    el.companyId = COMPANY;
    document.body.appendChild(el);
    return el;
}

describe('c-sab-setup-workspace', () => {
    beforeEach(() => {
        getSetupState.mockResolvedValue(READY);
        getAccessibleCompanies.mockResolvedValue([
            { companyId: COMPANY, companyName: 'Ratuls Company Ltd', companyKey: 'com2', functionalCurrency: 'USD', setupStatus: 'Validated' },
            { companyId: 'a01B', companyName: 'Radwanul Habib Ratul', companyKey: 'company-01', functionalCurrency: 'BDT', setupStatus: 'In Progress' }
        ]);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows progress steps, readiness and the profile for a ready company', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelectorAll('.step.done').length).toBe(6);
        expect(root.querySelector('.progress .sub').textContent).toBe('All steps complete');
        expect(root.querySelector('.banner').textContent).toContain('Core accounting readiness passed');
        expect(root.querySelector('.continue')).toBeNull();
        const fields = Array.from(root.querySelectorAll('.profile .field')).map((f) => f.textContent);
        expect(fields).toContain('Legal nameRatuls Company Ltd');
        expect(fields).toContain('Fiscal year startsJanuary');
        root.querySelector('.edit-profile').click();
        await flush();
        const editor = root.querySelector('c-sab-setup-records');
        expect(editor.open).toBe(true);
        expect(editor.kind).toBe('company');
        editor.dispatchEvent(new CustomEvent('close'));
        await flush();
        expect(editor.open).toBe(false);
    });

    it('continues setup at the first unfinished step and validates', async () => {
        getSetupState.mockResolvedValue({ ...READY, setupStatus: 'In Progress', readyForCoreAccounting: false, openPeriodCount: 0, periodCount: 0,
            errors: ['At least one Open period is required.'] });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.step.now .t').textContent).toBe('Accounting periods');
        expect(root.querySelector('.banner').textContent).toContain('1 item to finish before posting');
        root.querySelector('.continue').click();
        await flush();
        expect(root.querySelector('c-sab-setup-records').kind).toBe('period');
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        root.querySelector('.validate').click();
        await flush();
        expect(toast.mock.calls[0][0].detail).toEqual({ message: 'Core setup still has items to finish', tone: 'bad' });
        getSetupState.mockResolvedValue(READY);
        root.querySelector('c-sab-setup-records').dispatchEvent(new CustomEvent('saved', { detail: {} }));
        await flush();
        expect(root.querySelectorAll('.step.done').length).toBe(6);
        root.querySelector('.validate').click();
        await flush();
        expect(toast.mock.calls[1][0].detail.message).toBe('Core setup checks passed');
    });

    it('lists periods, accounts, numbering and features and opens their editors', async () => {
        getSetupRecords.mockImplementation(({ kind }) => Promise.resolve({
            period: [{ Id: 'P1', Period_Key__c: '2026-10', Start_Date__c: '2026-10-01', End_Date__c: '2026-10-31', Fiscal_Year__c: 2026, Fiscal_Quarter__c: 4, Status__c: 'Open' }],
            account: [{ Id: 'G1', Account_Code__c: '1000', Name: 'Bank', Account_Type__c: 'Asset', Normal_Balance__c: 'Debit', Control_Type__c: 'Bank', Is_Active__c: true }],
            sequence: [{ Id: 'S1', Document_Type__c: 'Invoice', Prefix__c: 'INV-', Next_Number__c: 148, Minimum_Digits__c: 6, Fiscal_Series__c: 'FY27', Is_Active__c: true }],
            feature: [{ Id: 'F1', Feature_Key__c: 'FIXED_ASSETS', Enabled__c: true, Configuration_Status__c: 'Valid' }]
        }[kind]));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        const tabs = root.querySelectorAll('.tab');
        tabs[1].click();
        await flush();
        expect(root.querySelector('.records tbody tr').textContent).toBe('2026-101 Oct 202631 Oct 20262026Q4Open');
        root.querySelector('.manage').click();
        await flush();
        expect(root.querySelector('c-sab-setup-records').kind).toBe('period');
        tabs[2].click();
        await flush();
        expect(root.querySelector('.records tbody tr').textContent).toContain('Bank');
        tabs[3].click();
        await flush();
        expect(root.querySelector('.records tbody tr').textContent).toContain('INV-000148');
        tabs[4].click();
        await flush();
        expect(root.querySelector('.records tbody tr').textContent).toContain('Fixed assets');
        getSetupRecords.mockRejectedValueOnce({ body: { message: 'No access' } });
        tabs[1].click();
        await flush();
        expect(root.querySelector('.records .banner').textContent).toBe('No access');
    });

    it('lists companies and raises switch and add events', async () => {
        getSetupRecords.mockResolvedValue([]);
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[5].click();
        await flush();
        const rows = root.querySelectorAll('.companies tbody tr');
        expect(rows[0].querySelector('.tag').textContent).toBe('Current');
        const events = jest.fn();
        el.addEventListener('sabswitchcompany', events);
        el.addEventListener('sabnewcompany', events);
        rows[1].querySelector('.switch').click();
        root.querySelector('.add-company').click();
        expect(events.mock.calls[0][0].detail.companyId).toBe('a01B');
        expect(events).toHaveBeenCalledTimes(2);
        root.querySelectorAll('.tab')[2].click();
        await flush();
        expect(root.querySelector('.records .panel-b.muted').textContent).toBe('No chart of accounts yet.');
    });

    it('disables adding companies without permission and shows load errors', async () => {
        getSetupState.mockRejectedValueOnce({ body: { message: 'You do not have access.' } });
        const el = mount({ caps: {} });
        await flush();
        expect(el.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have access.');
        el.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        el.shadowRoot.querySelectorAll('.tab')[5].click();
        await flush();
        expect(el.shadowRoot.querySelector('.add-company').title).toBe('Your role cannot add companies');
    });
});
