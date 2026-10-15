import { createElement } from 'lwc';
import SabReportsWorkspace, { labelOf } from 'c/sabReportsWorkspace';
import getDashboard from '@salesforce/apex/SABManagementDashboardService.getDashboard';
import getCashFlow from '@salesforce/apex/SABCashFlowService.getCashFlow';
import getPnlFilters from '@salesforce/apex/SABProfitLossController.getFilters';
import runProfitLoss from '@salesforce/apex/SABProfitLossController.runProfitLoss';
import getPnlDrilldown from '@salesforce/apex/SABProfitLossController.getRowDrilldown';
import getBsFilters from '@salesforce/apex/SABBalanceSheetController.getFilters';
import runBalanceSheet from '@salesforce/apex/SABBalanceSheetController.runBalanceSheet';
import getBsDrilldown from '@salesforce/apex/SABBalanceSheetController.getRowDrilldown';
import runTrialBalance from '@salesforce/apex/SABTrialBalanceController.runTrialBalance';
import getMovementLines from '@salesforce/apex/SABTrialBalanceController.getMovementLines';
import getGlFilters from '@salesforce/apex/SABGeneralLedgerController.getFilters';
import runGeneralLedger from '@salesforce/apex/SABGeneralLedgerController.runGeneralLedger';

jest.mock('@salesforce/apex/SABManagementDashboardService.getDashboard', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABCashFlowService.getCashFlow', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABProfitLossController.getFilters', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABProfitLossController.runProfitLoss', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABProfitLossController.getRowDrilldown', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBalanceSheetController.getFilters', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBalanceSheetController.runBalanceSheet', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBalanceSheetController.getRowDrilldown', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABTrialBalanceController.runTrialBalance', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABTrialBalanceController.getMovementLines', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABGeneralLedgerController.getFilters', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABGeneralLedgerController.runGeneralLedger', () => ({ default: jest.fn() }), { virtual: true });

jest.mock('@salesforce/apex/SABARAgingController.runAging', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAccountsPayableWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBankReconciliationWorkspaceController.getDashboard', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollSummaryController.getSummary', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFixedAssetWorkspaceController.getDashboard', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBudgetVarianceService.getBudgetVsActual', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABTaxReturnWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
import runArAging from '@salesforce/apex/SABARAgingController.runAging';
import getPayables from '@salesforce/apex/SABAccountsPayableWorkspaceController.getWorkspace';
import getBankDashboard from '@salesforce/apex/SABBankReconciliationWorkspaceController.getDashboard';
import getPayrollSummary from '@salesforce/apex/SABPayrollSummaryController.getSummary';
import getAssetDashboard from '@salesforce/apex/SABFixedAssetWorkspaceController.getDashboard';
import getBudgetVsActual from '@salesforce/apex/SABBudgetVarianceService.getBudgetVsActual';
import getTaxWorkspace from '@salesforce/apex/SABTaxReturnWorkspaceController.getWorkspace';

const d = new Date();
const y = d.getFullYear();
const mm = String(d.getMonth() + 1).padStart(2, '0');
const PERIODS = [
    { value: 'P0', label: `Jan ${y}`, startDate: `${y}-01-01`, endDate: `${y}-01-31` },
    { value: 'PC', label: 'Current', startDate: `${y}-${mm}-01`, endDate: `${y}-${mm}-28` }
];

const LINES = [{ journalLineId: 'JL1', journalId: 'J1', journalName: 'JE-000318', accountingDate: `${y}-${mm}-02`, accountCode: '4000', accountName: 'Sales',
    debit: 0, credit: 500, explanation: 'Invoice' }];

async function flush() {
    for (let i = 0; i < 12; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-reports-workspace', { is: SabReportsWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', visibleWorkspaces: ['journal', 'sales'], ...props });
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

function pick(root, id) {
    root.querySelector(`.sab-report-list .li[data-id="${id}"]`).click();
}

describe('c-sab-reports-workspace', () => {
    beforeEach(() => {
        getPnlFilters.mockResolvedValue({ definitions: [{ value: 'DEF1', label: 'Standard P&L' }], periods: PERIODS, departments: [{ value: 'D1', label: 'Operations' }] });
        getDashboard.mockResolvedValue({ currencyCode: 'AUD', cashBalance: 217430, receivables: 48210, payables: 16720, netYearToDate: 21800, budgetRevenueYearToDate: 90000,
            trend: [{ label: 'Jul', revenue: 100, expense: 80 }], recentRuns: [{ reportType: 'Cash Flow', generatedByName: 'Alex', generatedAt: '2026-10-01T02:00:00.000Z' }] });
        runProfitLoss.mockResolvedValue({ functionalCurrency: 'AUD', reportDefinitionId: 'DEF1', fromDate: `${y}-01-01`, toDate: `${y}-${mm}-28`, hasComparison: false,
            currentNetProfitLoss: 300, groups: [
                { groupKey: 'OPERATING_EXPENSES', displayOrder: 2, currentTotal: 200, rows: [{ rowKey: 'RENT', displayOrder: 1, currentAmount: 200, currentLineCount: 1 }] },
                { groupKey: 'REVENUE', displayOrder: 1, currentTotal: 500, rows: [{ rowKey: 'SALES.PRODUCT', displayOrder: 1, currentAmount: 500, currentLineCount: 2 },
                    { rowKey: 'OTHER', displayOrder: 2, currentAmount: 0, currentLineCount: 0 }] }] });
        getPnlDrilldown.mockResolvedValue(LINES);
        getBsFilters.mockResolvedValue({ definitions: [{ value: 'BS1', label: 'Standard BS' }] });
        runBalanceSheet.mockResolvedValue({ reportDefinitionId: 'BS1', asOfDate: `${y}-${mm}-28`, currentBalanced: true, currentAssets: 1000, currentLiabilitiesAndEquity: 1000,
            groups: [{ groupKey: 'ASSETS', displayOrder: 1, currentTotal: 1000, rows: [{ rowKey: 'CASH', displayOrder: 1, currentAmount: 1000, currentLineCount: 3 }] },
                { groupKey: 'EQUITY', displayOrder: 3, currentTotal: 1000, rows: [{ rowKey: 'CYE', syntheticCurrentYearEarnings: true, currentAmount: 300 }] }] });
        getBsDrilldown.mockResolvedValue(LINES);
        runTrialBalance.mockResolvedValue({ functionalCurrency: 'AUD', fromDate: `${y}-01-01`, toDate: `${y}-${mm}-28`, balanced: true, totalClosingDebit: 700, totalClosingCredit: 700,
            rows: [{ glAccountId: 'G1', accountCode: '1000', accountName: 'Bank', accountType: 'Asset', closingDebit: 700 },
                { glAccountId: 'G2', accountCode: '4000', accountName: 'Sales', accountType: 'Revenue', closingCredit: 700 }] });
        getMovementLines.mockResolvedValue(LINES);
        getGlFilters.mockResolvedValue({ accounts: [{ value: 'G1', label: '1000 Bank' }, { value: 'G2', label: '4000 Sales' }] });
        runGeneralLedger.mockResolvedValue({ accounts: [{ accountCode: '1000', accountName: 'Bank', openingDebit: 100, openingCredit: 0, closingDebit: 350, closingCredit: 0,
            displayedLineCount: 2, movementLineCount: 2, lines: [{ journalLineId: 'L1', journalId: 'J1', journalName: 'JE-1', accountingDate: `${y}-01-05`, debit: 300 },
                { journalLineId: 'L2', journalId: 'J2', journalName: 'JE-2', accountingDate: `${y}-01-06`, credit: 50 }] }] });
        getCashFlow.mockResolvedValue({ currencyCode: 'AUD', reconciled: true, netChange: 200, openingCash: 1000, closingCash: 1200,
            sections: [{ name: 'Operating', total: 200, lines: [{ accountCode: '4000', accountName: 'Sales', amount: 200 }] }] });
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('labels mapping keys', () => {
        expect(labelOf('OPERATING_EXPENSES')).toBe('Operating expenses');
        expect(labelOf('Sales.Product')).toBe('Sales product');
        expect(labelOf(null)).toBe('');
    });

    it('opens on the management overview with the current period selected', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(getDashboard).toHaveBeenCalledWith({ companyId: 'a01000000000001AAA', asOfDate: `${y}-${mm}-28` });
        expect(root.querySelector('.sab-from').value).toBe('P0');
        expect(root.querySelector('.sab-to').value).toBe('PC');
        expect(Array.from(root.querySelectorAll('.fig .v')).map((v) => v.textContent)[0]).toBe('217,430.00AUD');
        expect(root.querySelector('c-sab-bar-chart').groups).toEqual([{ label: 'Jul', values: [100, 80] }]);
        expect(root.querySelector('.runs .li').textContent).toContain('Cash Flow');
    });

    it('runs the profit and loss with groups, comparison and drill-down', async () => {
        const el = mount();
        await flush();
        const nav = jest.fn();
        el.addEventListener('sabnavigate', nav);
        const root = el.shadowRoot;
        pick(root, 'pnl');
        await flush();
        expect(runProfitLoss.mock.calls[0][0]).toMatchObject({ reportDefinitionId: 'DEF1', fromDate: `${y}-01-01`, comparisonFromDate: null, departmentId: null });
        const rows = Array.from(root.querySelectorAll('.sab-pnl tbody tr')).map((r) => r.textContent);
        expect(rows[0]).toBe('Revenue');
        expect(rows[1]).toBe('Sales product500.00');
        expect(rows).toContain('Net profit300.00');
        const department = root.querySelector('.sab-department');
        department.value = 'D1';
        department.dispatchEvent(new CustomEvent('change'));
        await flush();
        expect(runProfitLoss.mock.calls[1][0].departmentId).toBe('D1');
        const compare = root.querySelector('.sab-compare');
        compare.checked = true;
        compare.dispatchEvent(new CustomEvent('change'));
        await flush();
        expect(runProfitLoss.mock.calls[2][0].comparisonFromDate).toBe(`${y - 1}-01-01`);
        root.querySelectorAll('.sab-pnl tbody tr.click')[0].click();
        await flush();
        expect(getPnlDrilldown.mock.calls[0][0]).toMatchObject({ rowKey: 'SALES.PRODUCT', departmentId: 'D1' });
        expect(root.querySelector('c-sab-drawer').heading).toBe('Sales product');
        root.querySelector('.sab-drill-journal').click();
        expect(nav.mock.calls[0][0].detail).toEqual({ workspace: 'journal', recordId: 'J1' });
    });

    it('runs the balance sheet and trial balance with drill-down', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        pick(root, 'bs');
        await flush();
        expect(root.querySelector('.banner.t-good').textContent).toContain('Balance sheet balances');
        expect(root.querySelector('.sab-bs').textContent).toContain('Current year earnings');
        root.querySelector('.sab-bs tbody tr.click').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        expect(getBsDrilldown.mock.calls[0][0]).toMatchObject({ rowKey: 'CASH', reportDefinitionId: 'BS1' });
        root.querySelector('.sab-bs tbody tr.click').dispatchEvent(new KeyboardEvent('keydown', { key: 'x' }));
        const asof = root.querySelector('.sab-asof');
        asof.value = 'P0';
        asof.dispatchEvent(new CustomEvent('change'));
        await flush();
        expect(runBalanceSheet.mock.calls[1][0].asOfDate).toBe(`${y}-01-31`);
        pick(root, 'tb');
        await flush();
        expect(root.querySelector('.banner.t-good').textContent).toContain('Debits and credits both total 700.00 AUD.');
        expect(root.querySelector('.sab-tb tfoot').textContent).toBe('Total700.00700.00');
        root.querySelectorAll('.sab-tb tbody tr')[1].click();
        await flush();
        expect(getMovementLines.mock.calls[0][0]).toMatchObject({ glAccountId: 'G2' });
        expect(root.querySelector('c-sab-drawer').heading).toBe('4000 Sales');
        root.querySelector('c-sab-drawer').dispatchEvent(new CustomEvent('close'));
        await flush();
        expect(root.querySelector('c-sab-drawer').open).toBe(false);
    });

    it('runs the general ledger and cash flow and exports', async () => {
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        pick(root, 'gl');
        await flush();
        const rows = root.querySelectorAll('.sab-gl tbody tr');
        expect(rows[0].textContent).toContain('100.00');
        expect(rows[1].textContent).toContain('400.00');
        expect(rows[2].textContent).toContain('350.00');
        expect(root.querySelector('.sab-gl tfoot').textContent).toContain('350.00');
        const link = root.querySelector('.sab-download');
        link.click = jest.fn();
        root.querySelector('.sab-export').click();
        expect(link.download).toBe('general-ledger.csv');
        expect(decodeURIComponent(link.href)).toContain('"JE-1"');
        const account = root.querySelector('.sab-account');
        account.value = 'G2';
        account.dispatchEvent(new CustomEvent('change'));
        await flush();
        expect(runGeneralLedger.mock.calls[1][0].glAccountId).toBe('G2');
        pick(root, 'cf');
        await flush();
        expect(root.querySelector('.banner.t-good').textContent).toContain('Cash flow reconciles');
        expect(root.querySelector('.sab-cf').textContent).toContain('Net cash from operating');
        root.querySelector('.sab-export').click();
        expect(link.download).toBe('cash-flow-statement.csv');
        pick(root, 'pnl');
        await flush();
        root.querySelector('.sab-export').click();
        expect(decodeURIComponent(link.href)).toContain('Revenue: Sales product');
        pick(root, 'tb');
        await flush();
        root.querySelector('.sab-export').click();
        pick(root, 'overview');
        await flush();
        root.querySelector('.sab-export').click();
        expect(toast).toHaveBeenCalledTimes(5);
    });

    it('handles errors and missing definitions', async () => {
        const el = mount({ visibleWorkspaces: [] });
        await flush();
        const nav = jest.fn();
        el.addEventListener('sabnavigate', nav);
        const root = el.shadowRoot;
        runTrialBalance.mockResolvedValueOnce({ balanced: false, closingDifference: 10, rows: [] });
        pick(root, 'tb');
        await flush();
        expect(root.querySelector('.banner.t-bad').textContent).toContain('Trial balance is out');
        expect(root.querySelector('.sab-report .panel-b > .muted').textContent).toBe('No balances in this range.');
        getMovementLines.mockRejectedValueOnce({ body: { message: 'No access' } });
        runTrialBalance.mockResolvedValueOnce({ balanced: true, rows: [{ glAccountId: 'G1', accountCode: '1000', accountName: 'Bank', closingDebit: 1 }] });
        root.querySelector('.sab-from').dispatchEvent(new CustomEvent('change'));
        await flush();
        root.querySelector('.sab-tb tbody tr').click();
        await flush();
        expect(root.querySelector('c-sab-drawer .banner').textContent).toBe('No access');
        getBsFilters.mockResolvedValueOnce({ definitions: [] });
        pick(root, 'bs');
        await flush();
        expect(root.querySelector('.banner.t-bad').textContent).toContain('No balance sheet report definition');
        runGeneralLedger.mockRejectedValueOnce({ body: { message: 'General ledger permission is required.' } });
        pick(root, 'gl');
        await flush();
        expect(root.querySelector('.banner.t-bad').textContent).toContain('General ledger permission is required.');
        root.querySelector('.banner .btn').click();
        await flush();
        expect(root.querySelector('.sab-gl')).not.toBeNull();
        expect(root.querySelector('.linkish')).toBeNull();
        getPnlFilters.mockResolvedValueOnce({ definitions: [], periods: PERIODS });
        const el2 = mount();
        await flush();
        el2.shadowRoot.querySelector('.sab-report-list .li[data-id="pnl"]').click();
        await flush();
        expect(el2.shadowRoot.querySelector('.banner.t-bad').textContent).toContain('No profit and loss report definition');
    });

    it('lists every report on the left and runs the table reports', async () => {
        runArAging.mockResolvedValue({ totalOutstanding: 900, rows: [{ customerName: 'Greenfield', legalNumber: 'INV-1', dueDate: '2026-09-01', daysPastDue: 40,
            agingBucket: '31-60', outstandingDocumentAmount: 900 }, { customerName: 'Paid', outstandingDocumentAmount: 0 }] });
        getPayables.mockResolvedValue({ totalOutstanding: 500, bills: [{ supplierName: 'Fuel Co', billNumber: 'BILL-1', vendorReference: 'F-9', status: 'Posted', outstandingAmount: 500,
            daysPastDue: 0, agingBucket: 'Current' }, { status: 'Draft', outstandingAmount: 10 }] });
        getBankDashboard.mockResolvedValue({ bankAccounts: [{ name: 'Operating', bankName: 'CBA', currencyCode: 'AUD', glAccountCode: '1000', glAccountName: 'Bank', currentBookBalance: 1200 }] });
        getPayrollSummary.mockResolvedValue({ runs: [{ name: 'PAY-1', periodStart: '2026-09-01', periodEnd: '2026-09-30', state: 'Posted', employeeCount: 5, grossTotal: 1000,
            deductionTotal: 100, employerTotal: 50, netTotal: 900 }] });
        getAssetDashboard.mockResolvedValue({ netBookValue: 40000, assets: [{ assetTag: 'FA-1', name: 'Forklift', categoryName: 'Equipment', status: 'In Service', cost: 50000,
            postedDepreciation: 10000, netBookValue: 40000 }] });
        getBudgetVsActual.mockRejectedValueOnce({ body: { message: 'No Approved budget exists for 2026.' } }).mockResolvedValue({ rows: [{ accountCode: '4000', accountName: 'Sales',
            budget: 100, actual: 110, variance: 10, variancePercent: 10 }] });
        getTaxWorkspace.mockResolvedValue({ returns: [{ name: 'BAS Q1', returnVersion: 2, registrationName: 'GST', periodStart: '2026-07-01', periodEnd: '2026-09-30', status: 'Prepared',
            netTaxDue: 1240 }] });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(Array.from(root.querySelectorAll('.sab-report-list .t')).map((t) => t.textContent)).toEqual(['Management overview', 'Trial balance', 'General ledger',
            'Profit & loss', 'Balance sheet', 'AR aging', 'AP aging', 'Cash & bank', 'Payroll cost', 'Asset register', 'Budget vs actual', 'Tax summary', 'Cash flow statement']);
        const checks = [['ar', 'Greenfield', '900.00'], ['ap', 'BILL-1 (F-9)', '500.00'], ['cash', 'Operating', '1,200.00'], ['payroll', 'PAY-1', '900.00'],
            ['assets', 'FA-1 Forklift', '40,000.00']];
        for (const [id, text, total] of checks) {
            pick(root, id);
            // eslint-disable-next-line no-await-in-loop
            await flush();
            const rows = root.querySelectorAll('.sab-table-report tbody tr');
            expect(rows.length).toBe(1);
            expect(rows[0].textContent).toContain(text);
            expect(root.querySelector('.sab-table-report tfoot').textContent).toContain(total);
        }
        pick(root, 'tax');
        await flush();
        expect(root.querySelector('.sab-table-report tbody tr').textContent).toContain('BAS Q1 v2');
        expect(root.querySelector('.sab-table-report tfoot')).toBeNull();
        const link = root.querySelector('.sab-download');
        link.click = jest.fn();
        root.querySelector('.sab-export').click();
        expect(link.download).toBe('tax-summary.csv');
        pick(root, 'bva');
        await flush();
        expect(root.querySelector('.banner.t-bad').textContent).toContain('No Approved budget');
        root.querySelector('.banner .btn').click();
        await flush();
        expect(root.querySelector('.sab-table-report tbody tr').textContent).toContain('10.0%');
        getTaxWorkspace.mockResolvedValueOnce({ returns: [] });
        pick(root, 'tax');
        await flush();
        expect(root.querySelector('.sab-report .panel-b > div.muted').textContent).toBe('Nothing to report for this selection.');
    });
});
