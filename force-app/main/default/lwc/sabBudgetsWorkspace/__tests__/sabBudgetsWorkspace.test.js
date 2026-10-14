import { createElement } from 'lwc';
import SabBudgetsWorkspace from 'c/sabBudgetsWorkspace';
import getWorkspace from '@salesforce/apex/SABBudgetWorkspaceController.getWorkspace';
import getBudgetDetail from '@salesforce/apex/SABBudgetWorkspaceController.getBudgetDetail';
import getBudgetVsActual from '@salesforce/apex/SABBudgetVarianceService.getBudgetVsActual';
import saveDraft from '@salesforce/apex/SABBudgetService.saveDraft';
import submitBudget from '@salesforce/apex/SABBudgetService.submit';
import approveBudget from '@salesforce/apex/SABBudgetService.approve';
import returnBudget from '@salesforce/apex/SABBudgetService.returnToDraft';
import reviseBudget from '@salesforce/apex/SABBudgetService.revise';

jest.mock('@salesforce/apex/SABBudgetWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBudgetWorkspaceController.getBudgetDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBudgetVarianceService.getBudgetVsActual', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBudgetService.saveDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBudgetService.submit', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBudgetService.approve', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBudgetService.returnToDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBudgetService.revise', () => ({ default: jest.fn() }), { virtual: true });

function ws(overrides = {}) {
    return {
        functionalCurrency: 'AUD', capabilities: { manage: true, approve: true }, fiscalYears: [2027],
        budgets: [{ budgetId: 'B1', name: 'FY27', fiscalYear: 2027, version: 1, status: 'Approved' }, { budgetId: 'B2', name: 'FY27', fiscalYear: 2027, version: 2, status: 'Draft' }],
        periods: [{ value: 'P1', label: 'Jul 2026', fiscalYear: 2027 }, { value: 'P2', label: 'Aug 2026', fiscalYear: 2027 }],
        accounts: [{ value: 'G1', label: '4000 Sales' }, { value: 'G2', label: '6000 Wages' }],
        departments: [{ value: 'D1', label: 'Operations' }], costCenters: [{ value: 'K1', label: 'CC-1' }],
        ...overrides
    };
}

const VARIANCE = {
    totalRevenueActual: 100, totalRevenueBudget: 90,
    rows: [
        { glAccountId: 'G1', accountCode: '4000', accountName: 'Sales', accountType: 'Revenue', budget: 1000, actual: 1100, variance: 100, variancePercent: 10, favourable: true },
        { glAccountId: 'G2', accountCode: '6000', accountName: 'Wages', accountType: 'Expense', dimensionId: 'D1', dimensionName: 'Operations', budget: 500, actual: 600,
            variance: -100, variancePercent: -20, favourable: false },
        { glAccountId: 'G3', accountCode: '6100', accountName: 'Rent', accountType: 'Expense', budget: 0, actual: 50, variance: -50, favourable: false }
    ]
};

async function flush() {
    for (let i = 0; i < 12; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-budgets-workspace', { is: SabBudgetsWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', persona: { label: 'Bookkeeper' }, ...props });
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

function setModal(root, field, value) {
    const input = root.querySelector(`c-sab-modal [data-field="${field}"]`);
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-budgets-workspace', () => {
    beforeEach(() => {
        getWorkspace.mockResolvedValue(ws());
        getBudgetVsActual.mockResolvedValue(VARIANCE);
        getBudgetDetail.mockResolvedValue({ total: 1500, lines: [{ accountingPeriodId: 'P1', glAccountId: 'G1', amount: 1000 }, { accountingPeriodId: 'P1', glAccountId: 'G2', departmentId: 'D1', amount: 500 }] });
        [saveDraft, submitBudget, approveBudget, returnBudget, reviseBudget].forEach((m) => m.mockResolvedValue({ budgetId: 'B2' }));
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows versions, figures, grouped variance and monthly chart', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(Array.from(root.querySelectorAll('.sab-versions button')).map((b) => b.className)).toEqual(['', 'on']);
        expect(getBudgetVsActual.mock.calls[0][0]).toMatchObject({ fiscalYear: 2027, budgetId: 'B2', groupBy: 'ACCOUNT', periodIds: null });
        expect(Array.from(root.querySelectorAll('.fig .v')).map((v) => v.textContent)).toEqual(['1,100AUD', '650AUD', '-50AUD', '1,500AUD']);
        const rows = root.querySelectorAll('.sab-variance tbody tr');
        expect(rows[0].textContent).toBe('Income');
        expect(rows[1].textContent).toContain('+100.00');
        expect(rows[3].querySelector('.neg').textContent).toBe('-100.00');
        expect(rows[3].textContent).toContain('Operations');
        expect(rows[4].textContent).toContain('\u2014');
        expect(rows[5].textContent).toContain('Net profit');
        expect(root.querySelector('c-sab-bar-chart').groups).toEqual([{ label: 'Jul 2026', values: [100, 90] }, { label: 'Aug 2026', values: [100, 90] }]);
        expect(root.querySelector('.sab-submit')).not.toBeNull();
    });

    it('switches version, filters department and revises an approved budget', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.sab-versions button')[0].click();
        await flush();
        expect(root.querySelector('.sab-revise')).not.toBeNull();
        root.querySelectorAll('.sab-group button')[1].click();
        await flush();
        const dept = root.querySelector('.sab-dimension');
        dept.value = 'D1';
        dept.dispatchEvent(new CustomEvent('change'));
        await flush();
        expect(getBudgetVsActual.mock.calls.find((c) => c[0].groupBy === 'ACCOUNT_DEPARTMENT')).toBeDefined();
        expect(root.querySelectorAll('.sab-variance tbody tr').length).toBe(4);
        root.querySelector('.sab-revise').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('A reason is required.');
        setModal(root, 'reason', 'Q1 reforecast');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(reviseBudget.mock.calls[0][0]).toMatchObject({ budgetId: 'B1', reason: 'Q1 reforecast', requestKey: expect.stringMatching(/^BUDGET-REVISE-B1-/) });
    });

    it('submits, approves and returns budgets', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.sab-submit').click();
        await flush();
        expect(submitBudget.mock.calls[0][0]).toMatchObject({ budgetId: 'B2' });
        getWorkspace.mockResolvedValue(ws({ budgets: [{ budgetId: 'B2', name: 'FY27', fiscalYear: 2027, version: 2, status: 'Submitted' }] }));
        approveBudget.mockRejectedValueOnce({ body: { message: 'Approver must differ from preparer.' } });
        const el2 = mount();
        const toast = jest.fn();
        el2.addEventListener('sabtoast', toast);
        await flush();
        el2.shadowRoot.querySelector('.sab-approve').click();
        await flush();
        expect(toast.mock.calls[0][0].detail.tone).toBe('bad');
        el2.shadowRoot.querySelector('.sab-return').click();
        await flush();
        setModal(el2.shadowRoot, 'reason', 'Fix wages');
        el2.shadowRoot.querySelector('.sab-modal-save').click();
        await flush();
        expect(returnBudget.mock.calls[0][0]).toMatchObject({ budgetId: 'B2', reason: 'Fix wages' });
    });

    it('creates a budget and edits lines', async () => {
        saveDraft.mockResolvedValueOnce('B9');
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.sab-new-budget').click();
        await flush();
        setModal(root, 'name', 'FY27 Stretch');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(saveDraft.mock.calls[0][0].request).toMatchObject({ budgetId: null, fiscalYear: 2027, name: 'FY27 Stretch', lines: [] });
        root.querySelector('.sab-edit-lines').click();
        await flush();
        expect(root.querySelectorAll('.sab-lines tbody tr').length).toBe(2);
        root.querySelector('.sab-add-line').click();
        await flush();
        const rows = root.querySelectorAll('.sab-lines tbody tr');
        const account = rows[2].querySelector('[data-field="glAccountId"]');
        account.value = 'G2';
        account.dispatchEvent(new CustomEvent('change'));
        const amount = rows[2].querySelector('[data-field="amount"]');
        amount.value = '250';
        amount.dispatchEvent(new CustomEvent('input'));
        await flush();
        expect(root.querySelector('.sab-lines tfoot').textContent).toContain('1,750.00');
        root.querySelectorAll('.sab-remove-line')[0].click();
        await flush();
        saveDraft.mockRejectedValueOnce({ body: { message: 'Duplicate line.' } });
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('Duplicate line.');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(saveDraft.mock.calls[2][0].request.lines).toEqual([
            { accountingPeriodId: 'P1', glAccountId: 'G2', departmentId: 'D1', costCenterId: null, amount: 500 },
            { accountingPeriodId: 'P1', glAccountId: 'G2', departmentId: null, costCenterId: null, amount: 250 }]);
    });

    it('handles permissions, empty years, variance errors and load errors', async () => {
        getWorkspace.mockResolvedValue(ws({ capabilities: { manage: false, approve: false } }));
        getBudgetVsActual.mockRejectedValueOnce({ body: { message: 'Budget not found.' } });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-new-budget').title).toBe('Bookkeeper role cannot manage budgets');
        expect(root.querySelector('.banner.t-bad').textContent).toBe('Budget not found.');

        getWorkspace.mockResolvedValue(ws({ budgets: [], fiscalYears: [2028] }));
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty h3').textContent).toBe('No budget for this year');
        const year = el2.shadowRoot.querySelector('.sab-year');
        year.value = '2028';
        year.dispatchEvent(new CustomEvent('change'));
        await flush();

        getWorkspace.mockRejectedValueOnce({ body: { message: 'Budget permission is required.' } });
        const el3 = mount();
        await flush();
        expect(el3.shadowRoot.querySelector('.empty p').textContent).toBe('Budget permission is required.');
        el3.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        el3.shadowRoot.querySelector('.sab-new-budget').click();
        await flush();
        el3.shadowRoot.querySelector('.sab-modal-close').click();
    });

    it('reviews the approved version by period range and dimension for directors', async () => {
        getWorkspace.mockResolvedValue(ws({ budgets: [{ budgetId: 'B1', name: 'FY27', fiscalYear: 2027, version: 1, status: 'Approved', currencyCode: 'AUD', lineCount: 4,
            approvedByName: 'Daniel', approvedAt: '2026-07-02T01:00:00.000Z' }, { budgetId: 'B2', name: 'FY27', fiscalYear: 2027, version: 2, status: 'Draft' }] }));
        const el = mount({ persona: { key: 'DIRECTOR', label: 'Director' } });
        await flush();
        const root = el.shadowRoot;
        expect(getBudgetVsActual.mock.calls[0][0]).toMatchObject({ budgetId: 'B1', periodIds: null, groupBy: 'ACCOUNT' });
        expect(root.querySelector('.sab-version-facts').textContent).toContain('Daniel');
        expect(root.querySelector('.sab-approved-version')).toBeNull();
        const to = root.querySelector('.sab-to');
        to.value = 'P1';
        to.dispatchEvent(new CustomEvent('change'));
        await flush();
        expect(getBudgetVsActual.mock.calls.find((c) => Array.isArray(c[0].periodIds) && c[0].periodIds.join() === 'P1')).toBeDefined();
        root.querySelectorAll('.sab-group button')[2].click();
        await flush();
        expect(getBudgetVsActual.mock.calls.find((c) => c[0].groupBy === 'ACCOUNT_COST_CENTER')).toBeDefined();
        expect(root.querySelector('.sab-dimension option:nth-child(2)').textContent).toBe('CC-1');
        root.querySelectorAll('.sab-versions button')[1].click();
        await flush();
        root.querySelector('.sab-approved-version').click();
        await flush();
        expect(root.querySelectorAll('.sab-versions button')[0].className).toBe('on');
    });

    it('creates a budget by copying a version and spreads an annual amount', async () => {
        getBudgetDetail.mockResolvedValue({ total: 1500, lines: [{ accountingPeriodId: 'P1', glAccountId: 'G1', amount: 1000 }, { accountingPeriodId: 'PX', glAccountId: 'G2', amount: 5 }] });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.sab-new-budget').click();
        await flush();
        expect(root.querySelector('c-sab-modal .ro').textContent).toBe('AUD');
        setModal(root, 'name', 'FY27 Stretch');
        setModal(root, 'copyFrom', 'B1');
        setModal(root, 'adjustPercent', '10');
        root.querySelector('.sab-modal-save').click();
        await flush();
        const request = saveDraft.mock.calls[0][0].request;
        expect(request.lines).toEqual([{ accountingPeriodId: 'P1', glAccountId: 'G1', departmentId: null, costCenterId: null, amount: 1100 }]);
        root.querySelector('.sab-edit-lines').click();
        await flush();
        root.querySelector('.sab-spread').click();
        await flush();
        root.querySelector('.sab-spread-apply').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toContain('annual amount');
        const spread = root.querySelector('.spread');
        const account = spread.querySelector('[data-field="glAccountId"]');
        account.value = 'G2';
        account.dispatchEvent(new CustomEvent('change'));
        const amount = spread.querySelector('.sab-spread-amount');
        amount.value = '1000.01';
        amount.dispatchEvent(new CustomEvent('input'));
        root.querySelector('.sab-spread-apply').click();
        await flush();
        const amounts = Array.from(root.querySelectorAll('.sab-lines [data-field="amount"]')).map((i) => i.value);
        expect(amounts.slice(-2)).toEqual(['500', '500.01']);

        getWorkspace.mockResolvedValue(ws({ periods: [{ value: 'P1', label: 'Jul 2026', fiscalYear: 2027 }] }));
        const el2 = mount();
        await flush();
        el2.shadowRoot.querySelector('.sab-new-budget').click();
        await flush();
        setModal(el2.shadowRoot, 'fiscalYear', '2030');
        setModal(el2.shadowRoot, 'copyFrom', 'B1');
        el2.shadowRoot.querySelector('.sab-modal-save').click();
        await flush();
        expect(el2.shadowRoot.querySelector('.form-error').textContent).toContain('FY 2030 has no accounting periods');
    });
});
