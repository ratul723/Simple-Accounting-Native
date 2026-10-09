import { createElement } from 'lwc';
import SabFinanceHome from 'c/sabFinanceHome';
import getHome from '@salesforce/apex/SABFinanceHomeController.getHome';

jest.mock('@salesforce/apex/SABFinanceHomeController.getHome', () => ({ default: jest.fn() }), { virtual: true });

const ACTIVE = {
    companyName: 'Harbourline Trading', currencyCode: 'AUD', setupStatus: 'Active', companyActive: true, hasPeriod: true,
    periodKey: 'FY27-P03', periodStart: '2026-09-01', periodStatus: 'Open',
    cash: { available: true, amount: 217430.5, count: 2 },
    receivables: { available: true, amount: 48210, count: 2, secondaryAmount: 9120 },
    payables: { available: true, amount: 16720, count: 3, nextDate: '2026-09-29' },
    profit: { available: true, amount: 61250, hasComparison: true, comparison: -1200 },
    cashTrend: [
        { pointDate: '2026-07-03', balance: 100 }, { pointDate: '2026-07-10', balance: 150 },
        { pointDate: '2026-08-07', balance: 120 }
    ],
    monthly: [{ monthStart: '2026-07-01', income: 1000, expense: 800 }, { monthStart: '2026-08-01', income: 1200, expense: 900 }],
    attention: [
        { key: 'approvals', icon: 'check', tone: 'info', title: '2 approvals waiting for you', detail: 'APR-1, APR-2', workspace: 'home' },
        { key: 'overdue', icon: 'sales', tone: 'bad', title: '2 overdue invoices', detail: '9,120.00 outstanding past due date', workspace: 'sales' },
        { key: 'close', icon: 'close', tone: 'accent', title: 'September close is 50% complete', detail: '2 of 4 close tasks done', workspace: 'close' }
    ],
    roleCard: { kind: 'drafts', caption: 'Your drafts', items: [{ recordId: 'a0J1', name: 'JE-000318', detail: 'Accrual' }], actionWorkspace: 'journal' },
    recentAvailable: true,
    recent: [{ recordId: 'a0J2', name: 'JE-000317', description: 'Payroll', accountingDate: '2026-09-25', postedBy: 'Alex Morgan', status: 'Posted' }],
    approvalsAvailable: true,
    approvals: [{ recordId: 'a0A1', name: 'APR-1', sourceType: 'Supplier_Bill__c', sourceKey: 'BILL-000397', requestedBy: 'Priya Nair', requestedAt: '2026-09-24T02:00:00.000Z' }]
};

async function flush() {
    for (let i = 0; i < 6; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-finance-home', { is: SabFinanceHome });
    Object.assign(el, {
        companyName: 'Harbourline Trading',
        currencyCode: 'AUD',
        persona: { key: 'BOOKKEEPER', label: 'Bookkeeper', firstName: 'Priya' },
        caps: { canCreateJournal: true, canCreateInvoice: false },
        visibleWorkspaces: ['home', 'journal', 'close', 'setup'],
        ...props
    });
    document.body.appendChild(el);
    return el;
}

describe('c-sab-finance-home', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders figures, charts, attention, role card, postings and approvals', async () => {
        getHome.mockResolvedValue(ACTIVE);
        const el = mount({ companyId: 'a01000000000001AAA' });
        await flush();
        const root = el.shadowRoot;
        const header = root.querySelector('c-sab-workspace-header');
        expect(header.heading).toMatch(/^Good (morning|afternoon|evening), Priya$/);
        expect(header.description).toBe('Here is where Harbourline Trading stands for Sep 2026, period FY27-P03.');
        const values = Array.from(root.querySelectorAll('.fig .v')).map((v) => v.textContent);
        expect(values).toEqual(['217,431AUD', '48,210AUD', '16,720AUD', '61,250AUD']);
        const subs = Array.from(root.querySelectorAll('.fig .s')).map((s) => s.textContent);
        expect(subs).toEqual(['2 accounts, book balance', '2 overdue totalling 9,120', '3 bills, next due 29 Sep', '(1,200) against budget']);
        expect(root.querySelector('c-sab-line-chart').labels).toEqual(['3 Jul', '10', '7 Aug']);
        expect(root.querySelector('c-sab-bar-chart').groups[0]).toEqual({ label: 'Jul', values: [1000, 800] });
        expect(root.querySelectorAll('.list .li').length).toBeGreaterThanOrEqual(4);
        expect(root.querySelector('.role-card h2').textContent).toBe('For your role: Bookkeeper');
        expect(root.querySelector('.draft-row .id').textContent).toBe('JE-000318');
        expect(root.querySelector('.tbl tbody td .id').textContent).toBe('APR-1');
        const journal = root.querySelector('.new-journal');
        const invoice = root.querySelector('.new-invoice');
        expect(journal.disabled).toBe(false);
        expect(invoice.disabled).toBe(true);
        expect(invoice.title).toBe('Bookkeeper role cannot create invoices');
    });

    it('raises navigation events from actions and rows', async () => {
        getHome.mockResolvedValue(ACTIVE);
        const el = mount({ companyId: 'a01000000000001AAA' });
        await flush();
        const handler = jest.fn();
        el.addEventListener('sabnavigate', handler);
        const root = el.shadowRoot;
        root.querySelector('.new-journal').click();
        root.querySelector('.draft-row .link').click();
        const rows = root.querySelectorAll('.li.click');
        rows[0].dispatchEvent(new CustomEvent('click'));
        rows[1].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        rows[1].dispatchEvent(new KeyboardEvent('keydown', { key: 'x' }));
        const recent = Array.from(rows).find((r) => r.dataset.id === 'a0J2');
        recent.dispatchEvent(new KeyboardEvent('keydown', { key: ' ' }));
        const detail = handler.mock.calls.map((c) => c[0].detail);
        expect(detail).toEqual([
            { workspace: 'journal', recordId: undefined },
            { workspace: 'journal', recordId: 'a0J1' },
            { workspace: 'close', recordId: undefined },
            { workspace: 'journal', recordId: 'a0J2' }
        ]);
    });

    it('shows unavailable figures and empty lists', async () => {
        getHome.mockResolvedValue({
            ...ACTIVE, hasPeriod: false, cash: { available: false }, receivables: { available: true, amount: 0, count: 0 },
            payables: { available: true, amount: 0, count: 0 }, profit: { available: true, amount: 0, hasComparison: false },
            cashTrend: [], monthly: [], attention: [], recent: [], approvals: [],
            roleCard: { kind: 'release', caption: 'Payments to release', isMoney: true, valueAmount: 16720, detail: '1 payment', actionLabel: 'Open payments', actionWorkspace: 'payments' }
        });
        const el = mount({ companyId: 'a01000000000001AAA', persona: { key: 'TREASURY', label: 'Treasury' } });
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('c-sab-workspace-header').description).toBe('Here is where Harbourline Trading stands today.');
        expect(root.querySelector('.fig .s').textContent).toBe('Not available for your access');
        const subs = Array.from(root.querySelectorAll('.fig .s')).map((s) => s.textContent);
        expect(subs.slice(1)).toEqual(['Nothing overdue', 'Nothing due in the next 14 days', 'No approved budget to compare']);
        expect(root.querySelector('c-sab-line-chart')).toBeNull();
        expect(root.querySelector('c-sab-bar-chart')).toBeNull();
        expect(root.querySelector('.list .t').textContent).toBe('You are all caught up');
        expect(root.querySelector('.empty-row')).not.toBeNull();
        expect(root.querySelector('.role-value').textContent).toBe('16,720.00 AUD');
        expect(root.querySelector('.role-action')).toBeNull();
    });

    it('shows the role meter and action', async () => {
        getHome.mockResolvedValue({ ...ACTIVE, roleCard: { kind: 'close', caption: 'Close progress', valueText: '2 of 4 tasks', showMeter: true, meterPercent: 50, actionLabel: 'Open period close', actionWorkspace: 'close' } });
        const el = mount({ companyId: 'a01000000000001AAA' });
        await flush();
        const handler = jest.fn();
        el.addEventListener('sabnavigate', handler);
        expect(el.shadowRoot.querySelector('.meter i').getAttribute('style')).toBe('width:50%');
        el.shadowRoot.querySelector('.role-action .btn').click();
        expect(handler.mock.calls[0][0].detail.workspace).toBe('close');
    });

    it('renders the setup view for companies in setup', async () => {
        getHome.mockResolvedValue({ companyName: 'Harbourline NZ', currencyCode: 'NZD', setupStatus: 'In Progress', companyActive: false,
            setup: { accountCount: 12, periodCount: 0, bankAccountCount: 1 } });
        const el = mount({ companyId: 'a01000000000002AAA' });
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('c-sab-workspace-header').heading).toBe('Harbourline NZ');
        expect(Array.from(root.querySelectorAll('.cardlet .big')).map((b) => b.textContent)).toEqual(['In Progress', '12 GL accounts', '0 periods', '1 bank account']);
        const handler = jest.fn();
        el.addEventListener('sabnavigate', handler);
        root.querySelector('.cardlet').click();
        root.querySelector('c-sab-workspace-header .btn.primary').click();
        expect(handler).toHaveBeenCalledTimes(2);
    });

    it('shows an error with retry and reloads on refresh', async () => {
        getHome.mockRejectedValueOnce({ body: { message: 'You do not have permission to view Finance home.' } });
        const el = mount({ companyId: 'a01000000000001AAA' });
        await flush();
        expect(el.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have permission to view Finance home.');
        getHome.mockResolvedValue(ACTIVE);
        el.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        expect(el.shadowRoot.querySelector('.figs')).not.toBeNull();
        await el.refresh();
        expect(getHome).toHaveBeenCalledTimes(3);
    });

    it('shows the no company state', async () => {
        const el = mount();
        await flush();
        expect(el.shadowRoot.querySelector('.empty h3').textContent).toBe('No accounting company yet');
        expect(getHome).not.toHaveBeenCalled();
    });
});
