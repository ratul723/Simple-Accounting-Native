import { createElement } from 'lwc';
import SabChartWorkspace from 'c/sabChartWorkspace';
import getChart from '@salesforce/apex/SABAdminWorkspaceController.getChart';
import saveAccount from '@salesforce/apex/SABSetupRecordService.saveAccount';
import saveDepartment from '@salesforce/apex/SABAdminWorkspaceService.saveDepartment';
import saveCostCenter from '@salesforce/apex/SABAdminWorkspaceService.saveCostCenter';

jest.mock('@salesforce/apex/SABAdminWorkspaceController.getChart', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.saveAccount', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAdminWorkspaceService.saveDepartment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAdminWorkspaceService.saveCostCenter', () => ({ default: jest.fn() }), { virtual: true });

function chart(overrides = {}) {
    return {
        currencyCode: 'AUD', canManageSetup: true, canManageProjects: true,
        accounts: [
            { accountId: 'A1', code: '1000', name: 'Operating account', accountType: 'Asset', normalBalance: 'Debit', controlType: 'Bank', isControlAccount: true,
                manualPostingAllowed: false, active: true, reportGroup: 'Cash', balance: 217430.5 },
            { accountId: 'A2', code: '4000', name: 'Sales', accountType: 'Revenue', normalBalance: 'Credit', controlType: 'None', isControlAccount: false,
                manualPostingAllowed: true, active: false, balance: -1200 }
        ],
        departments: [{ recordId: 'D1', code: 'OPS', name: 'Operations', active: true, personName: 'Alex' }, { recordId: 'D2', code: 'FIN', name: 'Finance', parentId: 'D1',
            parentName: 'Operations', active: false, activeFrom: '2026-01-01', activeTo: '2026-06-30' }],
        costCenters: [{ recordId: 'C1', code: 'CC1', name: 'Head office', active: true }],
        projects: [{ projectId: 'P1', code: 'PRJ-1', name: 'Fit-out', status: 'Planned' }],
        definitions: [
            { definitionId: 'R1', reportType: 'P&L', version: 3, status: 'Active', effectiveFrom: '2026-07-01',
                rows: [{ rowKey: 'REVENUE', groupKey: 'INCOME', displayOrder: 10, sign: -1, accounts: ['4000 Sales', '4100 Services'] }] },
            { definitionId: 'R2', reportType: 'Balance Sheet', version: 1, status: 'Draft', rows: [] }
        ],
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
    const el = createElement('c-sab-chart-workspace', { is: SabChartWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', persona: { label: 'Bookkeeper' }, visibleWorkspaces: ['import', 'projects'], ...props });
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

function set(root, field, value) {
    const input = root.querySelector(`c-sab-modal [data-field="${field}"]`);
    if (input.type === 'checkbox') {
        input.checked = value;
        input.dispatchEvent(new CustomEvent('change'));
        return;
    }
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-chart-workspace', () => {
    beforeEach(() => {
        getChart.mockResolvedValue(chart());
        [saveAccount, saveDepartment, saveCostCenter].forEach((m) => m.mockResolvedValue('X'));
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('lists GL accounts with control flags and balances and filters by type', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        const rows = root.querySelectorAll('.sab-accounts tbody tr');
        expect(rows.length).toBe(2);
        expect(rows[0].textContent).toContain('Bank');
        expect(rows[0].querySelector('.lock')).not.toBeNull();
        expect(rows[0].textContent).toContain('217,430.50');
        expect(rows[1].className).toBe('click inactive');
        root.querySelectorAll('.seg button')[4].click();
        await flush();
        expect(root.querySelectorAll('.sab-accounts tbody tr').length).toBe(1);
        root.querySelectorAll('.seg button')[2].click();
        await flush();
        expect(root.querySelector('.panel-b.muted').textContent).toBe('No accounts of this type.');
        const nav = jest.fn();
        el.addEventListener('sabnavigate', nav);
        root.querySelector('.sab-import').click();
        expect(nav.mock.calls[0][0].detail.workspace).toBe('import');
    });

    it('creates and edits GL accounts', async () => {
        saveAccount.mockRejectedValueOnce({ body: { message: 'Control Type must be None unless the account is marked as a Control Account.' } });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.sab-new-account').click();
        await flush();
        expect(root.querySelector('c-sab-modal').heading).toBe('New GL account');
        set(root, 'code', '6500');
        set(root, 'name', 'Freight');
        set(root, 'accountType', 'Revenue');
        await flush();
        expect(root.querySelector('c-sab-modal [data-field="normalBalance"]').value).toBe('Credit');
        set(root, 'accountType', 'Expense');
        set(root, 'controlType', 'AP');
        set(root, 'isControlAccount', false);
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toContain('Control Type must be None');
        set(root, 'controlType', 'None');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(saveAccount.mock.calls[1][0].request).toMatchObject({ accountId: null, code: '6500', name: 'Freight', accountType: 'Expense', normalBalance: 'Debit',
            controlType: 'None', isControlAccount: false, manualPostingAllowed: true });
        expect(saveAccount.mock.calls[1][0].requestKey).toBe(saveAccount.mock.calls[0][0].requestKey);
        root.querySelector('.sab-accounts tbody tr').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        expect(root.querySelector('c-sab-modal').heading).toBe('Edit GL account');
        expect(root.querySelector('c-sab-modal [data-field="code"]').value).toBe('1000');
        root.querySelector('.sab-modal-close').click();
        root.querySelector('.sab-accounts tbody tr').dispatchEvent(new KeyboardEvent('keydown', { key: 'x' }));
    });

    it('adds and edits departments and cost centers', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[1].click();
        await flush();
        const rows = root.querySelectorAll('.sab-departments tbody tr');
        expect(rows[1].textContent).toContain('Operations');
        expect(rows[1].textContent).toContain('to 30 Jun 2026');
        root.querySelector('.sab-new-department').click();
        await flush();
        set(root, 'code', 'SAL');
        set(root, 'name', 'Sales');
        set(root, 'parentId', 'D1');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(saveDepartment.mock.calls[0][0].request).toMatchObject({ recordId: null, code: 'SAL', name: 'Sales', parentId: 'D1', active: true });
        root.querySelectorAll('.sab-departments tbody tr')[0].click();
        await flush();
        expect(root.querySelector('c-sab-modal [data-field="code"]').disabled).toBe(true);
        expect(Array.from(root.querySelectorAll('c-sab-modal [data-field="parentId"] option')).map((o) => o.value)).toEqual(['', 'D2']);
        root.querySelector('.sab-modal-close').click();
        root.querySelectorAll('.tab')[2].click();
        await flush();
        root.querySelector('.sab-cost-centers tbody tr').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        set(root, 'name', 'Head office east');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(saveCostCenter.mock.calls[0][0].request).toMatchObject({ recordId: 'C1', name: 'Head office east' });
        root.querySelector('.sab-new-cost-center').click();
        await flush();
        expect(root.querySelector('c-sab-modal').heading).toBe('New cost center');
    });

    it('shows projects and report mappings', async () => {
        const el = mount();
        await flush();
        const nav = jest.fn();
        el.addEventListener('sabnavigate', nav);
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[3].click();
        await flush();
        expect(root.querySelector('.sab-projects tbody tr').textContent).toContain('PRJ-1');
        root.querySelector('.sab-open-projects').click();
        expect(nav.mock.calls[0][0].detail.workspace).toBe('projects');
        root.querySelectorAll('.tab')[4].click();
        await flush();
        expect(root.querySelector('.banner').textContent).toContain('P&L definition v3 is active');
        expect(root.querySelector('.sab-mapping tbody tr').textContent).toContain('4100 Services');
        const select = root.querySelector('.sab-definition');
        select.value = 'R2';
        select.dispatchEvent(new CustomEvent('change'));
        await flush();
        expect(root.querySelector('.banner').className).toContain('t-warn');
        expect(root.querySelector('.panel-b.muted').textContent).toBe('This definition has no mapped rows yet.');
    });

    it('handles permissions, empty data and errors', async () => {
        getChart.mockResolvedValueOnce(chart({ canManageSetup: false, departments: [], costCenters: [], projects: [], definitions: [] }));
        const el = mount({ visibleWorkspaces: [] });
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-new-account').title).toBe('Bookkeeper role cannot manage the chart');
        expect(root.querySelector('.sab-import')).toBeNull();
        for (let i = 1; i <= 4; i++) {
            root.querySelectorAll('.tab')[i].click();
            // eslint-disable-next-line no-await-in-loop
            await flush();
            expect(root.querySelector('.panel-b.muted')).not.toBeNull();
        }
        getChart.mockRejectedValueOnce({ body: { message: 'You do not have active access to this Accounting Company.' } });
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have active access to this Accounting Company.');
        el2.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        expect(el2.shadowRoot.querySelector('.sab-accounts')).not.toBeNull();
    });
});
