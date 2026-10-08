import { createElement } from 'lwc';
import SabBudgetWorkspace from 'c/sabBudgetWorkspace';
import getWorkspace from '@salesforce/apex/SABBudgetWorkspaceController.getWorkspace';
import getBudgetDetail from '@salesforce/apex/SABBudgetWorkspaceController.getBudgetDetail';
import saveDraft from '@salesforce/apex/SABBudgetService.saveDraft';
import approveBudget from '@salesforce/apex/SABBudgetService.approve';
import reviseBudget from '@salesforce/apex/SABBudgetService.revise';
import getBudgetVsActual from '@salesforce/apex/SABBudgetVarianceService.getBudgetVsActual';

jest.mock('@salesforce/apex/SABBudgetWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBudgetWorkspaceController.getBudgetDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBudgetService.saveDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBudgetService.submit', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBudgetService.approve', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBudgetService.returnToDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBudgetService.revise', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBudgetVarianceService.getBudgetVsActual', () => ({ default: jest.fn() }), { virtual: true });

const COMPANY_ID = 'a00000000000001AAA';
const BUDGET_ID = 'a0B000000000001AAA';
const OCT = 'a0P000000000001AAA';
const NOV = 'a0P000000000002AAA';
const SALES = 'a0G000000000001AAA';

function workspace(caps) {
    return {
        companyId: COMPANY_ID, companyName: 'Harbourline Trading', functionalCurrency: 'BDT',
        capabilities: { manage: true, approve: true, ...caps },
        budgets: [{ budgetId: BUDGET_ID, name: 'FY2026 Budget v1', fiscalYear: 2026, version: 1, status: 'Approved', lineCount: 1 }],
        stateCounts: [{ state: 'Approved', count: 1 }], fiscalYears: [2025, 2026],
        periods: [{ label: 'Oct 2026', value: OCT, fiscalYear: 2026 }, { label: 'Nov 2026', value: NOV, fiscalYear: 2026 },
            { label: 'Dec 2025', value: 'a0P000000000003AAA', fiscalYear: 2025 }],
        accounts: [{ label: '4000 Sales', value: SALES }], departments: [], costCenters: []
    };
}

function detail(status) {
    return {
        budget: { budgetId: BUDGET_ID, name: 'FY2026 Budget v1', fiscalYear: 2026, version: 1, status, currencyCode: 'BDT' },
        lines: [{ lineId: 'a0C000000000001AAA', accountingPeriodId: OCT, periodName: 'Oct 2026', glAccountId: SALES, accountName: '4000 Sales',
            amount: 1200 }],
        total: 1200
    };
}

// Test-only: let pending Apex promises and re-renders settle.
// eslint-disable-next-line @lwc/lwc/no-async-operation
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
const q = (el, s) => el.shadowRoot.querySelector(s);
const qa = (el, s) => Array.from(el.shadowRoot.querySelectorAll(s));

async function mount() {
    const element = createElement('c-sab-budget-workspace', { is: SabBudgetWorkspace });
    document.body.appendChild(element);
    await flush();
    await flush();
    return element;
}

async function change(target, value) {
    target.dispatchEvent(new CustomEvent('change', { detail: { value } }));
    await flush();
}

async function selectBudget(element) {
    qa(element, 'lightning-datatable')[0].dispatchEvent(new CustomEvent('rowselection', { detail: { selectedRows: [{ budgetId: BUDGET_ID }] } }));
    await flush();
    await flush();
}

describe('c-sab-budget-workspace', () => {
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
        expect(getWorkspace).not.toHaveBeenCalled();
    });

    it('filters budgets by fiscal year', async () => {
        getWorkspace.mockResolvedValue(workspace());
        const element = await mount();
        expect(qa(element, 'lightning-datatable')[0].data).toHaveLength(1);
        await change(q(element, 'lightning-combobox.year-filter'), '2025');
        expect(q(element, '.empty-state').textContent).toContain('No budgets');
    });

    it('offers only the chosen year\'s periods and saves the service request shape', async () => {
        getWorkspace.mockResolvedValue(workspace());
        getBudgetDetail.mockResolvedValue(detail('Draft'));
        saveDraft.mockResolvedValue(BUDGET_ID);
        const element = await mount();
        q(element, 'lightning-button.new-budget').click();
        await flush();
        const periodBox = q(element, '.line-row [data-field="accountingPeriodId"]');
        expect(periodBox.options.map((o) => o.value)).toEqual([OCT, NOV]);
        await change(periodBox, OCT);
        await change(q(element, '.line-row [data-field="glAccountId"]'), SALES);
        expect(q(element, 'lightning-button.save-budget').disabled).toBe(true);
        await change(q(element, '.line-row [data-field="amount"]'), '1200');
        q(element, 'lightning-button.save-budget').click();
        await flush();
        await flush();
        expect(saveDraft.mock.calls[0][0].request).toEqual({ budgetId: null, companyId: COMPANY_ID, fiscalYear: 2026, name: null,
            lines: [{ accountingPeriodId: OCT, glAccountId: SALES, departmentId: null, costCenterId: null, amount: 1200 }] });
    });

    it('approves a Submitted budget and reports the supersede', async () => {
        getWorkspace.mockResolvedValue(workspace());
        getBudgetDetail.mockResolvedValue(detail('Submitted'));
        approveBudget.mockResolvedValue({ status: 'Approved', supersededBudgetId: 'a0B000000000002AAA' });
        const element = await mount();
        await selectBudget(element);
        q(element, 'lightning-button.approve-budget').click();
        await flush();
        expect(approveBudget).toHaveBeenCalledWith({ budgetId: BUDGET_ID, requestKey: expect.stringMatching(/^G13B\|APPROVE\|/) });
    });

    it('revises an Approved budget only with a reason', async () => {
        getWorkspace.mockResolvedValue(workspace());
        getBudgetDetail.mockResolvedValue(detail('Approved'));
        reviseBudget.mockResolvedValue({ budgetId: 'a0B000000000002AAA', version: 2 });
        const element = await mount();
        await selectBudget(element);
        expect(q(element, 'lightning-button.revise-budget').disabled).toBe(true);
        await change(q(element, '.action-panel [data-field="reason"]'), 'Q4 reforecast');
        q(element, 'lightning-button.revise-budget').click();
        await flush();
        expect(reviseBudget).toHaveBeenCalledWith({ budgetId: BUDGET_ID, reason: 'Q4 reforecast',
            requestKey: expect.stringMatching(/^G13B\|REVISE\|/) });
    });

    it('compares budget with actuals and labels the result', async () => {
        getWorkspace.mockResolvedValue(workspace());
        getBudgetVsActual.mockResolvedValue({ budgetName: 'FY2026 Budget v1', budgetVersion: 1, budgetStatus: 'Approved',
            totalRevenueBudget: 1200, totalRevenueActual: 1000, totalExpenseBudget: 0, totalExpenseActual: 0,
            rows: [{ glAccountId: SALES, accountCode: '4000', accountName: 'Sales', budget: 1200, actual: 1000, variance: -200,
                variancePercent: -16.67, favourable: false, unbudgeted: false },
                { glAccountId: 'a0G000000000002AAA', accountCode: '1100', accountName: 'Bank', budget: 0, actual: 700, variance: 700,
                    favourable: null, unbudgeted: true }] });
        const element = await mount();
        q(element, 'lightning-button.run-variance').click();
        await flush();
        await flush();
        expect(getBudgetVsActual).toHaveBeenCalledWith({ companyId: COMPANY_ID, fiscalYear: 2026, budgetId: null, periodIds: [],
            groupBy: 'ACCOUNT' });
        const rows = qa(element, 'lightning-datatable').pop().data;
        expect(rows.map((r) => r.resultLabel)).toEqual(['Unfavourable', 'Unbudgeted']);
    });

    it('disables actions the user has no permission for', async () => {
        getWorkspace.mockResolvedValue(workspace({ manage: false, approve: false }));
        getBudgetDetail.mockResolvedValue(detail('Submitted'));
        const element = await mount();
        expect(q(element, 'lightning-button.new-budget').disabled).toBe(true);
        await selectBudget(element);
        expect(q(element, 'lightning-button.approve-budget').disabled).toBe(true);
        expect(approveBudget).not.toHaveBeenCalled();
    });
});
