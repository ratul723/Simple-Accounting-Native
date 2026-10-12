import { createElement } from 'lwc';
import SabSetupRecords from 'c/sabSetupRecords';
import getSetupRecords from '@salesforce/apex/SABSetupRecordService.getSetupRecords';
import canManageSetup from '@salesforce/apex/SABSetupRecordService.canManageSetup';
import createCompany from '@salesforce/apex/SABSetupRecordService.createCompany';
import saveCompany from '@salesforce/apex/SABSetupRecordService.saveCompany';
import savePeriod from '@salesforce/apex/SABSetupRecordService.savePeriod';
import saveAccount from '@salesforce/apex/SABSetupRecordService.saveAccount';
import saveSequence from '@salesforce/apex/SABSetupRecordService.saveSequence';
import saveFeature from '@salesforce/apex/SABSetupRecordService.saveFeature';

jest.mock('@salesforce/apex/SABSetupRecordService.getSetupRecords', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.canManageSetup', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.createCompany', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.saveCompany', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.savePeriod', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.saveAccount', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.saveSequence', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.saveFeature', () => ({ default: jest.fn() }), { virtual: true });

const COMPANY = 'a01000000000001AAA';

async function flush() {
    for (let i = 0; i < 8; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(kind) {
    const el = createElement('c-sab-setup-records', { is: SabSetupRecords });
    el.companyId = COMPANY;
    el.kind = kind;
    document.body.appendChild(el);
    el.open = true;
    return el;
}

function setField(root, field, value) {
    const input = root.querySelector(`[data-field="${field}"]`);
    if (input.type === 'checkbox') {
        input.checked = value;
        input.dispatchEvent(new CustomEvent('change'));
        return;
    }
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-setup-records', () => {
    beforeEach(() => {
        canManageSetup.mockResolvedValue(true);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('creates a new accounting company', async () => {
        createCompany.mockRejectedValueOnce({ body: { message: 'Company key HLT is already used.' } }).mockResolvedValueOnce('a01NEW');
        const el = mount('newCompany');
        const saved = jest.fn();
        el.addEventListener('saved', saved);
        const closed = jest.fn();
        el.addEventListener('close', closed);
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('c-sab-modal').heading).toBe('New accounting company');
        expect(canManageSetup).not.toHaveBeenCalled();
        setField(root, 'companyKey', 'HLT');
        setField(root, 'name', 'Harbourline Trading');
        setField(root, 'countryCode', 'AU');
        setField(root, 'functionalCurrency', 'AUD');
        setField(root, 'fiscalYearStartMonth', '7');
        root.querySelector('.save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('Company key HLT is already used.');
        root.querySelector('.save').click();
        await flush();
        expect(createCompany.mock.calls[1][0]).toEqual({
            request: { companyKey: 'HLT', name: 'Harbourline Trading', countryCode: 'AU', functionalCurrency: 'AUD', fiscalYearStartMonth: 7,
                fiscalCalendarType: 'Calendar' },
            requestKey: createCompany.mock.calls[0][0].requestKey
        });
        expect(saved.mock.calls[0][0].detail).toEqual({ recordId: 'a01NEW', kind: 'newCompany' });
        expect(closed).toHaveBeenCalled();
    });

    it('edits the company profile with the key locked', async () => {
        getSetupRecords.mockResolvedValue([{ Id: COMPANY, Name__c: 'Ratuls Company Ltd', Company_Key__c: 'com2', Country_Code__c: 'US',
            Functional_Currency__c: 'USD', Fiscal_Calendar_Type__c: 'Calendar', Fiscal_Year_Start_Month__c: 1, Setup_Status__c: 'Validated', Is_Active__c: true }]);
        saveCompany.mockResolvedValue(COMPANY);
        const el = mount('company');
        await flush();
        const root = el.shadowRoot;
        expect(getSetupRecords).toHaveBeenCalledWith({ companyId: COMPANY, kind: 'company' });
        expect(root.querySelector('[data-field="companyKey"]')).toBeNull();
        expect(root.querySelector('[data-field="name"]').value).toBe('Ratuls Company Ltd');
        setField(root, 'name', 'Ratuls Company Limited');
        setField(root, 'isActive', false);
        root.querySelector('.save').click();
        await flush();
        expect(saveCompany.mock.calls[0][0].request).toMatchObject({ companyId: COMPANY, name: 'Ratuls Company Limited', setupStatus: 'Validated',
            isActive: false, fiscalYearStartMonth: 1 });
    });

    it('lists periods, locks closed ones and creates a new period', async () => {
        getSetupRecords.mockResolvedValue([
            { Id: 'P1', Period_Key__c: 'FY27-P01', Start_Date__c: '2026-07-01', End_Date__c: '2026-07-31', Fiscal_Year__c: 2027, Period_Number__c: 1, Status__c: 'Closed' },
            { Id: 'P2', Period_Key__c: 'FY27-P02', Start_Date__c: '2026-08-01', End_Date__c: '2026-08-31', Fiscal_Year__c: 2027, Period_Number__c: 2, Status__c: 'Open' }
        ]);
        savePeriod.mockResolvedValue('P3');
        const el = mount('period');
        await flush();
        const root = el.shadowRoot;
        const rows = root.querySelectorAll('tbody tr');
        expect(rows[0].textContent).toContain('1 Jul 2026');
        expect(rows[0].querySelector('.edit').disabled).toBe(true);
        expect(rows[0].querySelector('.edit').title).toBe('Closed periods are changed through period reopen');
        rows[1].querySelector('.edit').click();
        await flush();
        expect(root.querySelector('c-sab-modal').heading).toBe('Edit accounting periods');
        root.querySelector('.back').click();
        await flush();
        root.querySelector('.new').click();
        await flush();
        setField(root, 'periodKey', 'FY27-P03');
        setField(root, 'startDate', '2026-09-01');
        setField(root, 'endDate', '2026-09-30');
        setField(root, 'fiscalYear', '2027');
        setField(root, 'periodNumber', '3');
        root.querySelector('.save').click();
        await flush();
        expect(savePeriod.mock.calls[0][0].request).toEqual({ companyId: COMPANY, periodId: null, periodKey: 'FY27-P03', startDate: '2026-09-01',
            endDate: '2026-09-30', fiscalYear: 2027, periodNumber: 3, fiscalQuarter: null });
        expect(getSetupRecords).toHaveBeenCalledTimes(2);
        expect(root.querySelector('tbody')).not.toBeNull();
    });

    it('saves accounts, sequences and features', async () => {
        getSetupRecords.mockResolvedValue([]);
        saveAccount.mockResolvedValue('G1');
        saveSequence.mockResolvedValue('S1');
        saveFeature.mockResolvedValue('F1');
        const account = mount('account');
        await flush();
        expect(account.shadowRoot.querySelector('.empty-list').textContent).toBe('No chart of accounts yet.');
        account.shadowRoot.querySelector('.new').click();
        await flush();
        setField(account.shadowRoot, 'code', '1000');
        setField(account.shadowRoot, 'name', 'Operating bank');
        setField(account.shadowRoot, 'cashFlowCategory', 'Cash');
        account.shadowRoot.querySelector('.save').click();
        await flush();
        expect(saveAccount.mock.calls[0][0].request).toMatchObject({ code: '1000', name: 'Operating bank', accountType: 'Asset', normalBalance: 'Debit',
            controlType: 'None', cashFlowCategory: 'Cash', manualPostingAllowed: true, isActive: true, isControlAccount: false });

        const sequence = mount('sequence');
        await flush();
        sequence.shadowRoot.querySelector('.new').click();
        await flush();
        setField(sequence.shadowRoot, 'fiscalSeries', 'FY27');
        setField(sequence.shadowRoot, 'prefix', 'INV-');
        sequence.shadowRoot.querySelector('.save').click();
        await flush();
        expect(saveSequence.mock.calls[0][0].request).toMatchObject({ documentType: 'Invoice', fiscalSeries: 'FY27', prefix: 'INV-', nextNumber: 1, minimumDigits: 6 });

        const feature = mount('feature');
        await flush();
        feature.shadowRoot.querySelector('.new').click();
        await flush();
        setField(feature.shadowRoot, 'featureKey', 'BUDGETS');
        feature.shadowRoot.querySelector('.save').click();
        await flush();
        expect(saveFeature.mock.calls[0][0].request).toMatchObject({ featureKey: 'BUDGETS', enabled: true, configurationStatus: 'Not Configured' });
    });

    it('locks create-only fields when editing and respects missing permission', async () => {
        canManageSetup.mockResolvedValue(false);
        getSetupRecords.mockResolvedValue([{ Id: 'S1', Document_Type__c: 'Invoice', Fiscal_Series__c: 'FY27', Prefix__c: 'INV-', Minimum_Digits__c: 6,
            Next_Number__c: 12, Is_Active__c: true }]);
        const el = mount('sequence');
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('tbody tr').textContent).toContain('Yes');
        expect(root.querySelector('.new').disabled).toBe(true);
        expect(root.querySelector('.edit').title).toBe('Your role cannot manage company setup');
    });

    it('shows load errors and closes', async () => {
        getSetupRecords.mockRejectedValue({ body: { message: 'You do not have active access to this Accounting Company.' } });
        const el = mount('feature');
        const closed = jest.fn();
        el.addEventListener('close', closed);
        await flush();
        expect(el.shadowRoot.querySelector('.banner').textContent).toBe('You do not have active access to this Accounting Company.');
        el.shadowRoot.querySelector('.close').click();
        expect(closed).toHaveBeenCalled();
        el.open = false;
        expect(el.open).toBe(false);
        expect(el.kind).toBe('feature');
    });
});
