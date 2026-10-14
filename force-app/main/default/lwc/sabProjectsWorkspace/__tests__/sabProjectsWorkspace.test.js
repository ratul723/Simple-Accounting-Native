import { createElement } from 'lwc';
import SabProjectsWorkspace from 'c/sabProjectsWorkspace';
import getProjects from '@salesforce/apex/SABAdminWorkspaceController.getProjects';
import getReport from '@salesforce/apex/SABProjectFinancialService.getReport';
import getLedgerPage from '@salesforce/apex/SABProjectFinancialService.getLedgerPage';
import saveProject from '@salesforce/apex/SABAdminWorkspaceService.saveProject';

jest.mock('@salesforce/apex/SABAdminWorkspaceController.getProjects', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABProjectFinancialService.getReport', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABProjectFinancialService.getLedgerPage', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAdminWorkspaceService.saveProject', () => ({ default: jest.fn() }), { virtual: true });

function data(overrides = {}) {
    return {
        currencyCode: 'AUD', canManageProjects: true, canViewFinancials: true, projectsEnabled: true,
        projects: [
            { projectId: 'P1', code: 'PRJ-001', name: 'Warehouse fit-out', status: 'Planned', revenue: 0, cost: 0, lineCount: 0 },
            { projectId: 'P2', code: 'PRJ-002', name: 'Cold store', status: 'Active', revenue: 10000, cost: 9500, lineCount: 4, startDate: '2026-07-01',
                customerName: 'Greenfield', customerAccountId: 'ACC1', managerName: 'Alex' },
            { projectId: 'P3', code: 'PRJ-003', name: 'Loss maker', status: 'Complete', revenue: 100, cost: 200 }
        ],
        customers: [{ value: 'ACC1', label: 'Greenfield' }],
        ...overrides
    };
}

const REPORT = { revenue: 10000, expense: 9500, profit: 500, marginPercent: 5,
    accounts: [{ accountId: 'E1', accountName: 'Materials', accountType: 'Expense', amount: 7000 }, { accountId: 'E2', accountName: 'Labour', accountType: 'Expense', amount: 2500 },
        { accountId: 'R1', accountName: 'Sales', accountType: 'Revenue', amount: 10000 }],
    ledger: { lines: [{ lineId: 'L1', journalId: 'J1', journalName: 'JE-000311', accountingDate: '2026-09-16', accountName: 'Labour', explanation: 'Internal allocation',
        debit: 820, credit: 0 }], hasMore: true, nextDate: '2026-09-16', nextId: 'L1' } };

async function flush() {
    for (let i = 0; i < 10; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-projects-workspace', { is: SabProjectsWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', persona: { label: 'Bookkeeper' }, visibleWorkspaces: ['journal', 'config'], ...props });
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

function set(root, field, value) {
    const input = root.querySelector(`c-sab-modal [data-field="${field}"]`);
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-projects-workspace', () => {
    beforeEach(() => {
        getProjects.mockResolvedValue(data());
        getReport.mockResolvedValue(REPORT);
        getLedgerPage.mockResolvedValue({ lines: [{ lineId: 'L2', journalId: 'J2', journalName: 'JE-000300', accountingDate: '2026-09-10', debit: 0, credit: 100 }], hasMore: false });
        saveProject.mockResolvedValue('P9');
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows project cards and the active project with figures, cost mix and tagged lines', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        const cards = root.querySelectorAll('.cards .cardlet');
        expect(cards.length).toBe(3);
        expect(cards[1].className).toBe('cardlet click sel');
        expect(cards[1].textContent).toContain('5% margin');
        expect(cards[2].querySelector('.meter').className).toBe('meter bad');
        expect(getReport.mock.calls[0][0]).toMatchObject({ projectId: 'P2', fromDate: '2026-07-01' });
        expect(Array.from(root.querySelectorAll('.totals .big')).map((b) => b.textContent)).toEqual(['10,000', '9,500', '500', '5.0%']);
        expect(root.querySelectorAll('.stackbar i').length).toBe(2);
        expect(root.querySelector('.legend').textContent).toContain('Materials 7,000');
        expect(root.querySelector('.kv').textContent).toContain('Greenfield');
        expect(root.querySelector('.sab-tagged tbody tr').textContent).toContain('Labour, Internal allocation');
        root.querySelector('.sab-more').click();
        await flush();
        expect(getLedgerPage.mock.calls[0][0]).toMatchObject({ projectId: 'P2', afterDate: '2026-09-16', afterId: 'L1', pageSize: 25 });
        expect(root.querySelectorAll('.sab-tagged tbody tr').length).toBe(2);
        expect(root.querySelector('.sab-more')).toBeNull();
        const nav = jest.fn();
        el.addEventListener('sabnavigate', nav);
        root.querySelector('.sab-open-journal').click();
        expect(nav.mock.calls[0][0].detail).toEqual({ workspace: 'journal', recordId: 'J1' });
    });

    it('selects another project and creates and edits projects', async () => {
        saveProject.mockRejectedValueOnce({ body: { message: 'Enter a project code.' } });
        getReport.mockResolvedValueOnce(REPORT).mockResolvedValueOnce({ revenue: 0, expense: 0, profit: 0, accounts: [], ledger: { lines: [] } });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.cards .cardlet')[0].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        expect(root.querySelector('.sab-project h2').textContent).toBe('PRJ-001 Warehouse fit-out');
        expect(root.querySelector('.sab-project p.muted').textContent).toContain('No costs recorded yet');
        expect(root.querySelector('.sab-tagged .panel-b.muted').textContent).toBe('No tagged lines yet.');
        root.querySelectorAll('.cards .cardlet')[0].dispatchEvent(new KeyboardEvent('keydown', { key: 'x' }));
        root.querySelector('.sab-new-project').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('Enter a project code.');
        set(root, 'code', 'PRJ-005');
        set(root, 'name', 'Solar roof');
        set(root, 'customerAccountId', 'ACC1');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(saveProject.mock.calls[1][0].request).toMatchObject({ recordId: null, code: 'PRJ-005', name: 'Solar roof', status: 'Planned', customerAccountId: 'ACC1' });
        expect(saveProject.mock.calls[1][0].requestKey).toBe(saveProject.mock.calls[0][0].requestKey);
        root.querySelector('.sab-edit-project').click();
        await flush();
        expect(root.querySelector('c-sab-modal').heading).toBe('Edit project');
        expect(root.querySelector('c-sab-modal [data-field="code"]').disabled).toBe(true);
        root.querySelector('.sab-modal-close').click();
    });

    it('explains disabled projects, restricted financials, empty lists and errors', async () => {
        getProjects.mockResolvedValueOnce(data({ projectsEnabled: false, canViewFinancials: false, canManageProjects: false }));
        const el = mount();
        await flush();
        const nav = jest.fn();
        el.addEventListener('sabnavigate', nav);
        const root = el.shadowRoot;
        expect(root.querySelector('.banner.t-warn').textContent).toContain('turned off');
        root.querySelector('.sab-open-config').click();
        expect(nav.mock.calls[0][0].detail.workspace).toBe('config');
        expect(root.querySelector('.banner.t-info').textContent).toContain('Bookkeeper users can see projects');
        expect(root.querySelector('.cards .meter')).toBeNull();
        expect(getReport).not.toHaveBeenCalled();
        expect(root.querySelector('.sab-new-project').title).toBe('Bookkeeper role cannot manage projects');

        getProjects.mockResolvedValueOnce(data({ projects: [] }));
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty h3').textContent).toBe('No projects yet');

        getReport.mockRejectedValueOnce({ body: { message: 'Project financials are restricted.' } });
        getLedgerPage.mockRejectedValueOnce({ body: { message: 'boom' } });
        const el3 = mount();
        await flush();
        expect(el3.shadowRoot.querySelector('.sab-project .banner').textContent).toBe('Project financials are restricted.');

        getProjects.mockRejectedValueOnce({ body: { message: 'You do not have active access to this Accounting Company.' } });
        const el4 = mount();
        await flush();
        expect(el4.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have active access to this Accounting Company.');
        el4.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        const toast = jest.fn();
        el4.addEventListener('sabtoast', toast);
        el4.shadowRoot.querySelector('.sab-more').click();
        await flush();
        expect(toast.mock.calls[0][0].detail.tone).toBe('bad');
    });
});
