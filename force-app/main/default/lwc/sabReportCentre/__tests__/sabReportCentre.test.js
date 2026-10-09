import { createElement } from 'lwc';
import SabReportCentre from 'c/sabReportCentre';
import getDashboard from '@salesforce/apex/SABManagementDashboardService.getDashboard';
import getCashFlow from '@salesforce/apex/SABCashFlowService.getCashFlow';

jest.mock('@salesforce/apex/SABManagementDashboardService.getDashboard', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABCashFlowService.getCashFlow', () => ({ default: jest.fn() }), { virtual: true });

const COMPANY_ID = 'a00000000000001AAA';

const DASHBOARD = {
    currencyCode: 'USD', cashBalance: 1600, receivables: 200, payables: 150, netMonthToDate: -150, revenueYearToDate: 800,
    expenseYearToDate: 350, netYearToDate: 450, budgetRevenueYearToDate: 1000, budgetExpenseYearToDate: null,
    trend: [{ label: 'Feb 2026', year: 2026, month: 2, revenue: 800, expense: 200, net: 600 },
        { label: 'Mar 2026', year: 2026, month: 3, revenue: 0, expense: 150, net: -150 }],
    recentRuns: []
};

const CASH_FLOW = {
    currencyCode: 'USD', openingCash: 1000, netChange: 600, closingCash: 1600, reconciled: true,
    sections: [{ name: 'Operating', total: 400, lines: [{ accountCode: '4000', accountName: 'Sales', amount: 500 }] },
        { name: 'Investing', total: -400, lines: [] }, { name: 'Financing', total: 600, lines: [] }]
};

// Test-only: let pending Apex promises and re-renders settle.
// eslint-disable-next-line @lwc/lwc/no-async-operation
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
const q = (el, s) => el.shadowRoot.querySelector(s);

async function mount() {
    const element = createElement('c-sab-report-centre', { is: SabReportCentre });
    document.body.appendChild(element);
    await flush();
    await flush();
    return element;
}

async function activate(element, value) {
    const tab = Array.from(element.shadowRoot.querySelectorAll('lightning-tab')).find((t) => t.value === value);
    tab.dispatchEvent(new CustomEvent('active'));
    await flush();
}

describe('c-sab-report-centre', () => {
    beforeEach(() => window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANY_ID));
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        window.sessionStorage.clear();
        jest.clearAllMocks();
    });

    it('asks for a company when none is selected', async () => {
        window.sessionStorage.clear();
        const element = await mount();
        expect(q(element, '.empty-state').textContent).toContain('Select an Accounting Company');
        expect(getDashboard).not.toHaveBeenCalled();
    });

    it('loads the dashboard with KPIs, budget and trend bars', async () => {
        getDashboard.mockResolvedValue(DASHBOARD);
        const element = await mount();
        expect(getDashboard).toHaveBeenCalledWith({ companyId: COMPANY_ID, asOfDate: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/) });
        expect(q(element, 'lightning-formatted-number.cash').value).toBe(1600);
        expect(q(element, 'lightning-formatted-number.net-ytd').value).toBe(450);
        expect(q(element, '.budget-panel')).not.toBeNull();
        expect(q(element, '.bar.revenue').style.width).toBe('100%');
    });

    it('runs the cash flow statement for the chosen range and shows reconciliation', async () => {
        getDashboard.mockResolvedValue(DASHBOARD);
        getCashFlow.mockResolvedValue(CASH_FLOW);
        const element = await mount();
        await activate(element, 'cashflow');
        const inputs = element.shadowRoot.querySelectorAll('lightning-input[data-field]');
        inputs[0].dispatchEvent(new CustomEvent('change', { detail: { value: '2026-02-01' } }));
        inputs[1].dispatchEvent(new CustomEvent('change', { detail: { value: '2026-03-31' } }));
        await flush();
        q(element, 'lightning-button.run-cash-flow').click();
        await flush();
        await flush();
        expect(getCashFlow).toHaveBeenCalledWith({ companyId: COMPANY_ID, fromDate: '2026-02-01', toDate: '2026-03-31' });
        expect(q(element, '.badge.ok').textContent).toContain('Reconciled');
        expect(q(element, 'lightning-formatted-number.closing-cash').value).toBe(1600);
        expect(element.shadowRoot.querySelectorAll('.cash-section')).toHaveLength(3);
    });

    it('disables an inverted date range and shows server errors', async () => {
        getDashboard.mockRejectedValue({ body: { message: 'Management report permission is required.' } });
        const element = await mount();
        expect(q(element, '.error-banner').textContent).toContain('permission is required');
        await activate(element, 'cashflow');
        const inputs = element.shadowRoot.querySelectorAll('lightning-input[data-field]');
        inputs[0].dispatchEvent(new CustomEvent('change', { detail: { value: '2026-03-31' } }));
        inputs[1].dispatchEvent(new CustomEvent('change', { detail: { value: '2026-02-01' } }));
        await flush();
        expect(q(element, 'lightning-button.run-cash-flow').disabled).toBe(true);
    });

    it('renders an embedded report only when its tab is opened', async () => {
        getDashboard.mockResolvedValue(DASHBOARD);
        const element = await mount();
        expect(q(element, 'c-sab-trial-balance-report')).toBeNull();
        await activate(element, 'trialbalance');
        expect(q(element, 'c-sab-trial-balance-report')).not.toBeNull();
        expect(q(element, 'c-sab-profit-loss-report')).toBeNull();
    });
});
