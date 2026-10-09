import { createElement } from 'lwc';
import SabAppShell from 'c/sabAppShell';
import { CurrentPageReference } from 'lightning/navigation';
import { publish } from 'lightning/messageService';
import getAccessibleCompanies from '@salesforce/apex/SABCompanyContextController.getAccessibleCompanies';
import getCompanyContext from '@salesforce/apex/SABCompanyContextController.getCompanyContext';
import getShellContext from '@salesforce/apex/SABAppShellController.getShellContext';
import searchRecords from '@salesforce/apex/SABAppShellController.search';
import getHome from '@salesforce/apex/SABFinanceHomeController.getHome';

jest.mock('@salesforce/apex/SABCompanyContextController.getAccessibleCompanies', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABCompanyContextController.getCompanyContext', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAppShellController.getShellContext', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAppShellController.search', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFinanceHomeController.getHome', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('c/sabJournalWorkspace', () => jest.requireActual('c/sabIcon'));
jest.mock('c/sabAccountingPeriodWorkspace', () => jest.requireActual('c/sabIcon'));
jest.mock('c/sabCompanySetupWizard', () => jest.requireActual('c/sabIcon'));

const COMPANIES = [
    { companyId: 'a01000000000001AAA', companyName: 'Harbourline Trading', companyKey: 'HLT-AU', functionalCurrency: 'AUD', setupStatus: 'Active' },
    { companyId: 'a01000000000002AAA', companyName: 'Harbourline NZ', companyKey: 'HLT-NZ', functionalCurrency: 'NZD', setupStatus: 'In Progress' }
];

const SHELL = {
    userId: '005000000000001AAA',
    persona: { key: 'FINANCE_MANAGER', label: 'Finance Manager', userName: 'Alex Morgan', firstName: 'Alex', initials: 'AM' },
    visibleWorkspaces: ['home', 'journal', 'close', 'setup', 'reports'],
    hasPeriod: true,
    periodKey: 'FY27-P03',
    periodStart: '2026-09-01',
    periodStatus: 'Open',
    canCreateJournal: true,
    canCreateInvoice: false
};

const HOME = {
    companyName: 'Harbourline Trading', currencyCode: 'AUD', setupStatus: 'Active', companyActive: true, hasPeriod: true,
    periodKey: 'FY27-P03', periodStart: '2026-09-01', periodStatus: 'Open',
    cash: { available: true, amount: 100, count: 1 }, receivables: { available: false }, payables: { available: false },
    profit: { available: false }, cashTrend: [], monthly: [], attention: [], roleCard: { kind: 'close', caption: 'Close' },
    recentAvailable: false, recent: [], approvalsAvailable: false, approvals: []
};

async function flush(times = 8) {
    for (let i = 0; i < times; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

async function settle() {
    await flush();
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    await new Promise((resolve) => setTimeout(resolve, 0));
    await flush();
}

function mount() {
    const el = createElement('c-sab-app-shell', { is: SabAppShell });
    document.body.appendChild(el);
    return el;
}

describe('c-sab-app-shell', () => {
    beforeEach(() => {
        window.sessionStorage.clear();
        window.localStorage.clear();
        getAccessibleCompanies.mockResolvedValue(COMPANIES);
        getCompanyContext.mockImplementation(({ companyId }) => Promise.resolve(COMPANIES.find((c) => c.companyId === companyId)));
        getShellContext.mockResolvedValue(SHELL);
        getHome.mockResolvedValue(HOME);
        searchRecords.mockResolvedValue([
            { kind: 'journal', recordId: 'a0J000000000001AAA', companyId: COMPANIES[0].companyId, title: 'JE-000318', detail: 'Accrual, Posted', workspace: 'journal', icon: 'journal' },
            { kind: 'invoice', recordId: 'a0I000000000001AAA', companyId: COMPANIES[0].companyId, title: 'INV-1', detail: 'Invoice', workspace: 'sales', icon: 'sales' }
        ]);
    });

    afterEach(() => {
        jest.useRealTimers();
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders the top bar, period pill and grouped sidebar', async () => {
        const el = mount();
        await settle();
        const root = el.shadowRoot;
        expect(root.querySelector('.company-name').textContent).toBe('Harbourline Trading');
        expect(root.querySelector('.ctx-btn .sub').textContent).toBe('HLT-AU, AUD');
        expect(root.querySelector('.period-pill').textContent).toBe('FY27-P03 Sep 2026, open');
        expect(root.querySelector('.period-pill .dot').className).toBe('dot open');
        expect(Array.from(root.querySelectorAll('.nav-group h3')).map((h) => h.textContent)).toEqual(['Overview', 'Ledger', 'Administration']);
        expect(Array.from(root.querySelectorAll('.nav-item .lbl')).map((l) => l.textContent)).toEqual(['Finance home', 'Journals', 'Period close', 'Company setup']);
        expect(root.querySelector('.avatar').textContent).toBe('AM');
        expect(root.querySelector('.persona').textContent).toBe('Finance Manager');
        expect(root.querySelector('.workspace.aware')).not.toBeNull();
        expect(window.sessionStorage.getItem('sabSelectedAccountingCompanyId')).toBe(COMPANIES[0].companyId);
        expect(publish).toHaveBeenCalled();
        expect(publish.mock.calls[0][2]).toMatchObject({ companyId: COMPANIES[0].companyId, companySwitched: false, companyCleared: false });
    });

    it('restores the stored company and navigates from the sidebar and page state', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANIES[0].companyId);
        const el = mount();
        await settle();
        const root = el.shadowRoot;
        root.querySelector('.nav-item[data-id="journal"]').click();
        await settle();
        expect(root.querySelector('.nav-item[data-id="journal"]').getAttribute('aria-current')).toBe('page');
        expect(root.querySelector('c-sab-workspace-header').heading).toBe('Journals');
        expect(root.querySelector('.workspace.legacy-ws')).not.toBeNull();

        CurrentPageReference.emit({ type: 'standard__navItemPage', attributes: { apiName: 'SAB_Home' }, state: { c__ws: 'close' } });
        await settle();
        expect(root.querySelector('c-sab-workspace-header').heading).toBe('Period close & reopen');

        root.querySelector('.nav-item[data-id="journal"]').click();
        await settle();
        expect(root.querySelector('c-sab-workspace-header').heading).toBe('Journals');

        CurrentPageReference.emit({ type: 'standard__navItemPage', attributes: { apiName: 'SAB_Home' }, state: { c__ws: 'reports' } });
        await settle();
        expect(root.querySelector('.workspace.aware')).not.toBeNull();
    });

    it('toggles and persists the theme', async () => {
        const el = mount();
        await settle();
        el.shadowRoot.querySelector('.theme-btn').click();
        expect(el.getAttribute('data-theme')).toBe('dark');
        expect(window.localStorage.getItem('sabTheme:005000000000001AAA')).toBe('dark');
        el.shadowRoot.querySelector('.theme-btn').click();
        expect(el.getAttribute('data-theme')).toBe('light');
    });

    it('applies a stored theme on load', async () => {
        window.localStorage.setItem('sabTheme:005000000000001AAA', 'dark');
        const el = mount();
        await settle();
        expect(el.getAttribute('data-theme')).toBe('dark');
    });

    it('searches after a pause, hides results for hidden workspaces and opens a result', async () => {
        const el = mount();
        await settle();
        jest.useFakeTimers();
        const input = el.shadowRoot.querySelector('.search-input');
        input.value = 'JE';
        input.dispatchEvent(new CustomEvent('input'));
        await flush();
        expect(el.shadowRoot.querySelector('.search-pop').className).toContain('open');
        jest.advanceTimersByTime(300);
        jest.useRealTimers();
        await settle();
        expect(searchRecords).toHaveBeenCalledWith({ term: 'JE' });
        const titles = Array.from(el.shadowRoot.querySelectorAll('.search-pop .t')).map((t) => t.textContent);
        expect(titles).toEqual(['JE-000318']);
        input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await settle();
        expect(el.shadowRoot.querySelector('c-sab-workspace-header').heading).toBe('Journals');
        expect(el.shadowRoot.querySelector('.search-pop').className).not.toContain('open');
    });

    it('matches workspaces locally for short terms and shows an empty state', async () => {
        const el = mount();
        await settle();
        const input = el.shadowRoot.querySelector('.search-input');
        input.value = 'p';
        input.dispatchEvent(new CustomEvent('input'));
        await flush();
        const titles = Array.from(el.shadowRoot.querySelectorAll('.search-pop .t')).map((t) => t.textContent);
        expect(titles).toContain('Period close');
        el.shadowRoot.querySelector('.search-pop .pop-item').click();
        await settle();
        input.value = 'zz';
        searchRecords.mockResolvedValue([]);
        input.dispatchEvent(new CustomEvent('input'));
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        await new Promise((resolve) => setTimeout(resolve, 300));
        await settle();
        expect(el.shadowRoot.querySelector('.empty-res').textContent).toBe('No matches for "zz"');
        input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
        await flush();
        expect(el.shadowRoot.querySelector('.search-pop').className).not.toContain('open');
    });

    it('focuses search with the slash key and closes popovers with Escape', async () => {
        const el = mount();
        await settle();
        el.shadowRoot.querySelector('.company-btn').click();
        await flush();
        expect(el.shadowRoot.querySelector('.company-pop').className).toContain('open');
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
        await flush();
        expect(el.shadowRoot.querySelector('.company-pop').className).not.toContain('open');
        document.body.dispatchEvent(new KeyboardEvent('keydown', { key: '/', bubbles: true }));
        expect(el.shadowRoot.activeElement).toBe(el.shadowRoot.querySelector('.search-input'));
        el.shadowRoot.querySelector('.user-btn').click();
        await flush();
        expect(el.shadowRoot.querySelector('.user-pop').className).toContain('open');
        el.shadowRoot.querySelector('.app').click();
        await flush();
        expect(el.shadowRoot.querySelector('.user-pop').className).not.toContain('open');
    });

    it('switches company and shows the setup state for workspaces of a company in setup', async () => {
        const el = mount();
        await settle();
        el.shadowRoot.querySelector('.nav-item[data-id="journal"]').click();
        await settle();
        el.shadowRoot.querySelector('.company-btn').click();
        await flush();
        el.shadowRoot.querySelectorAll('.company-pop .pop-item')[1].click();
        await settle();
        const root = el.shadowRoot;
        expect(root.querySelector('.period-pill').textContent).toBe('Setup in progress');
        expect(root.querySelector('.empty h3').textContent).toBe('Finish setup to start using journals');
        expect(publish.mock.calls[publish.mock.calls.length - 1][2]).toMatchObject({ companySwitched: true });
        root.querySelector('.empty .btn.primary').click();
        await settle();
        expect(root.querySelector('c-sab-workspace-header').heading).toBe('Company setup');
        root.querySelector('.nav-item[data-id="close"]').click();
        await settle();
        const switchButton = Array.from(root.querySelectorAll('.empty .btn')).find((b) => b.textContent.startsWith('Switch to'));
        switchButton.click();
        await settle();
        expect(root.querySelector('.company-name').textContent).toBe('Harbourline Trading');
    });

    it('opens and closes the mobile sidebar', async () => {
        const el = mount();
        await settle();
        el.shadowRoot.querySelector('.menu-btn').click();
        await flush();
        expect(el.shadowRoot.querySelector('.sidebar').className).toBe('sidebar open');
        el.shadowRoot.querySelector('.scrim').click();
        await flush();
        expect(el.shadowRoot.querySelector('.sidebar').className).toBe('sidebar');
        el.shadowRoot.querySelector('.brand').click();
        await settle();
        expect(el.shadowRoot.querySelector('.workspace.aware')).not.toBeNull();
    });

    it('handles workspace navigate and toast events', async () => {
        const el = mount();
        await settle();
        const home = el.shadowRoot.querySelector('.workspace.aware');
        home.dispatchEvent(new CustomEvent('sabtoast', { detail: { message: 'Saved' }, bubbles: true, composed: true }));
        await flush();
        expect(el.shadowRoot.querySelector('c-sab-toast').shadowRoot.querySelector('.toast').textContent).toBe('Saved');
        home.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'close' }, bubbles: true, composed: true }));
        await settle();
        expect(el.shadowRoot.querySelector('c-sab-workspace-header').heading).toBe('Period close & reopen');
    });

    it('shows a message when the user has no companies', async () => {
        getAccessibleCompanies.mockResolvedValue([]);
        getShellContext.mockResolvedValue({ ...SHELL, visibleWorkspaces: [], hasPeriod: false });
        const el = mount();
        await settle();
        expect(el.shadowRoot.querySelector('.period-pill').textContent).toBe('No company selected');
        expect(el.shadowRoot.querySelector('.empty h3').textContent).toBe('No workspaces available');
        expect(publish.mock.calls[0][2]).toMatchObject({ companyCleared: true });
    });

    it('shows an error with retry when loading fails', async () => {
        getAccessibleCompanies.mockRejectedValueOnce({ body: { message: 'No access' } });
        const el = mount();
        await settle();
        expect(el.shadowRoot.querySelector('.empty p').textContent).toBe('No access');
        el.shadowRoot.querySelector('.empty .btn').click();
        await settle();
        expect(el.shadowRoot.querySelector('.workspace.aware')).not.toBeNull();
    });

    it('shows a missing period message', async () => {
        getShellContext.mockResolvedValue({ ...SHELL, hasPeriod: false });
        const el = mount();
        await settle();
        expect(el.shadowRoot.querySelector('.period-pill').textContent).toBe('No period for today');
    });
});
