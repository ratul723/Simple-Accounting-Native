import { LightningElement, api } from 'lwc';
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
import { formatNumber, formatDate, formatDateTime, chipClass } from 'c/sabFormat';
import { reduceError, todayIso, toast } from 'c/sabMoneyShared';
import runArAging from '@salesforce/apex/SABARAgingController.runAging';
import getPayables from '@salesforce/apex/SABAccountsPayableWorkspaceController.getWorkspace';
import getBankDashboard from '@salesforce/apex/SABBankReconciliationWorkspaceController.getDashboard';
import getPayrollSummary from '@salesforce/apex/SABPayrollSummaryController.getSummary';
import getAssetDashboard from '@salesforce/apex/SABFixedAssetWorkspaceController.getDashboard';
import getBudgetVsActual from '@salesforce/apex/SABBudgetVarianceService.getBudgetVsActual';
import getTaxWorkspace from '@salesforce/apex/SABTaxReturnWorkspaceController.getWorkspace';
import getReconciliation from '@salesforce/apex/SABBalanceSheetReconciliationService.getReconciliation';

const REPORTS = [
    { id: 'overview', label: 'Management overview', tag: 'Available' },
    { id: 'tb', label: 'Trial balance', tag: 'Available' },
    { id: 'gl', label: 'General ledger', tag: 'Available' },
    { id: 'pnl', label: 'Profit & loss', tag: 'Available' },
    { id: 'bs', label: 'Balance sheet', tag: 'Available' },
    { id: 'ar', label: 'AR aging', tag: 'Available' },
    { id: 'ap', label: 'AP aging', tag: 'Available' },
    { id: 'cash', label: 'Cash & bank', tag: 'Available' },
    { id: 'payroll', label: 'Payroll cost', tag: 'Available' },
    { id: 'assets', label: 'Asset register', tag: 'Available' },
    { id: 'bva', label: 'Budget vs actual', tag: 'Available' },
    { id: 'tax', label: 'Tax summary', tag: 'Available' },
    { id: 'cf', label: 'Cash flow statement', tag: 'Available' }
];

/** Reports drawn as one table from another workspace's service. */
const TABLE_REPORTS = ['ar', 'ap', 'cash', 'payroll', 'assets', 'bva', 'tax'];

/** Readable label for a mapping key such as OPERATING_EXPENSES or Revenue.Sales. */
export function labelOf(key) {
    const text = String(key || '').replace(/[_.]+/g, ' ').trim().toLowerCase();
    return text ? text.charAt(0).toUpperCase() + text.slice(1) : '';
}

function money(value) {
    return formatNumber(Number(value) || 0);
}

/**
 * Report center in the Harbourline demo layout (G22G-7): report list on the left, period and department filters, and
 * profit and loss, balance sheet, trial balance, general ledger, cash flow and the management overview on the right,
 * with drill-down to journal lines. Reports come from the existing report controllers, unchanged.
 */
export default class SabReportsWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api recordId;
    @api periodKey;

    report = 'overview';
    filters;
    bsFilters;
    glFilters;
    result;
    errorMessage;
    isLoading = false;
    fromPeriod;
    toPeriod;
    asOfPeriod;
    departmentId = '';
    compare = false;
    glAccountId;
    drillOpen = false;
    drillTitle = '';
    drillLines = [];
    drillError;
    loadSequence = 0;
    bsMode = 'statement';
    recon;
    reconError;
    reconSection;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.filters = undefined;
            this.bsFilters = undefined;
            this.glFilters = undefined;
            this.run();
        }
    }

    // ---------- loading ----------

    async ensureFilters() {
        if (!this.filters) {
            this.filters = await getPnlFilters({ companyId: this.currentCompanyId });
            const periods = this.periods;
            const today = todayIso();
            const current = periods.find((p) => p.startDate <= today && p.endDate >= today) || periods[periods.length - 1];
            if (current) {
                const yearStart = periods.find((p) => p.startDate.slice(0, 4) === current.startDate.slice(0, 4)) || current;
                this.fromPeriod = yearStart.value;
                this.toPeriod = current.value;
                this.asOfPeriod = current.value;
            }
        }
    }

    async run() {
        const companyId = this.currentCompanyId;
        const sequence = ++this.loadSequence;
        if (!companyId) {
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            await this.ensureFilters();
            const result = await this.fetch(companyId);
            if (sequence === this.loadSequence) {
                this.result = result;
            }
        } catch (error) {
            if (sequence === this.loadSequence) {
                this.result = undefined;
                this.errorMessage = reduceError(error);
            }
        } finally {
            if (sequence === this.loadSequence) {
                this.isLoading = false;
            }
        }
    }

    async fetch(companyId) {
        const from = this.periodById(this.fromPeriod);
        const to = this.periodById(this.toPeriod);
        const fromDate = from ? from.startDate : null;
        const toDate = to ? to.endDate : todayIso();
        if (TABLE_REPORTS.includes(this.report)) {
            return this.fetchTable(companyId, toDate, to);
        }
        if (this.report === 'overview') {
            return getDashboard({ companyId, asOfDate: toDate });
        }
        if (this.report === 'cf') {
            return getCashFlow({ companyId, fromDate, toDate });
        }
        if (this.report === 'tb') {
            return runTrialBalance({ companyId, fromDate, toDate, includeZeroBalance: false });
        }
        if (this.report === 'gl') {
            if (!this.glFilters) {
                this.glFilters = await getGlFilters({ companyId });
                this.glAccountId = ((this.glFilters.accounts || [])[0] || {}).value;
            }
            if (!this.glAccountId) {
                return { accounts: [] };
            }
            return runGeneralLedger({ companyId, fromDate, toDate, glAccountId: this.glAccountId });
        }
        if (this.report === 'bs') {
            if (!this.bsFilters) {
                this.bsFilters = await getBsFilters({ companyId });
            }
            const definition = ((this.bsFilters.definitions || [])[0] || {}).value;
            if (!definition) {
                throw new Error('No balance sheet report definition is set up for this company.');
            }
            const asOf = this.periodById(this.asOfPeriod);
            return runBalanceSheet({ companyId, reportDefinitionId: definition, asOfDate: asOf ? asOf.endDate : todayIso(),
                comparisonAsOfDate: this.compare ? this.priorDate(asOf ? asOf.endDate : todayIso(), 12) : null });
        }
        const definition = this.pnlDefinition;
        if (!definition) {
            throw new Error('No profit and loss report definition is set up for this company.');
        }
        const comparison = this.comparisonRange(fromDate, toDate);
        return runProfitLoss({ companyId, reportDefinitionId: definition, fromDate, toDate, comparisonFromDate: comparison.from, comparisonToDate: comparison.to,
            departmentId: this.departmentId || null, costCenterId: null, projectId: null });
    }

    priorDate(iso, months) {
        const d = new Date(`${iso}T00:00:00`);
        d.setMonth(d.getMonth() - months);
        return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    }

    comparisonRange(fromDate, toDate) {
        if (!this.compare || !fromDate || !toDate) {
            return { from: null, to: null };
        }
        return { from: this.priorDate(fromDate, 12), to: this.priorDate(toDate, 12) };
    }

    get pnlDefinition() {
        return ((this.filters && this.filters.definitions) || [])[0] ? this.filters.definitions[0].value : undefined;
    }

    get periods() {
        return [...((this.filters && this.filters.periods) || [])].sort((a, b) => (a.startDate < b.startDate ? -1 : 1));
    }

    periodById(id) {
        return this.periods.find((p) => p.value === id);
    }

    // ---------- navigation and filters ----------

    get reportItems() {
        return REPORTS.map((r) => ({
            ...r,
            className: r.id === this.report ? 'li click sel' : 'li click',
            current: r.id === this.report ? 'true' : 'false',
            tagClass: r.tag === 'Available' ? 'tag' : 'chip t-neutral'
        }));
    }

    handleReport(event) {
        const id = event.currentTarget.dataset.id;
        this.report = id;
        this.result = undefined;
        this.run();
    }

    get reportTitle() {
        return REPORTS.find((r) => r.id === this.report).label;
    }

    get reportSub() {
        const generated = this.result && this.result.generatedAt ? formatDateTime(this.result.generatedAt) : formatDateTime(new Date().toISOString());
        const drill = ['pnl', 'bs', 'tb'].includes(this.report) ? ' Select a row to see its journal lines.' : '';
        return `Posted ledger, generated ${generated}.${drill}`;
    }

    get showRange() {
        return this.report !== 'bs';
    }

    get showAsOf() {
        return this.report === 'bs';
    }

    get showDepartment() {
        return this.report === 'pnl';
    }

    get showCompare() {
        return this.report === 'pnl' || this.report === 'bs';
    }

    get showAccount() {
        return this.report === 'gl';
    }

    optionsFor(selected) {
        return this.periods.map((p) => ({ value: p.value, label: p.label, selected: p.value === selected }));
    }

    get fromOptions() {
        return this.optionsFor(this.fromPeriod);
    }

    get toOptions() {
        return this.optionsFor(this.toPeriod);
    }

    get asOfOptions() {
        return this.optionsFor(this.asOfPeriod);
    }

    get departmentOptions() {
        return ((this.filters && this.filters.departments) || []).map((d) => ({ ...d, selected: d.value === this.departmentId }));
    }

    get accountOptions() {
        return ((this.glFilters && this.glFilters.accounts) || []).map((a) => ({ ...a, selected: a.value === this.glAccountId }));
    }

    handleFilter(event) {
        const field = event.target.dataset.field;
        this[field] = field === 'compare' ? event.target.checked : event.target.value;
        this.run();
        if (this.report === 'bs' && this.bsMode === 'recon') {
            this.loadRecon();
        }
    }

    get showLoading() {
        return this.isLoading && !this.result && !this.errorMessage;
    }

    get cur() {
        return (this.result && (this.result.functionalCurrency || this.result.currencyCode)) || this.currencyCode || '';
    }

    get isOverview() {
        return this.report === 'overview' && Boolean(this.result);
    }

    get isPnl() {
        return this.report === 'pnl' && Boolean(this.result);
    }

    get isBs() {
        return this.report === 'bs' && Boolean(this.result);
    }

    get isTb() {
        return this.report === 'tb' && Boolean(this.result);
    }

    get isGl() {
        return this.report === 'gl' && Boolean(this.result);
    }

    // ---------- table reports from other workspaces ----------

    async fetchTable(companyId, asOfDate, toPeriod) {
        const amount = (v) => formatNumber(Number(v) || 0);
        const date = (v) => (v ? formatDate(v) : '\u2014');
        const table = (columns, rows, total, note) => ({ kind: 'table', columns: columns.map((c) => ({ ...c, className: c.n ? 'n' : '' })), rows: rows.map((cells, i) => ({ key: `r${i}`,
            cells: cells.map((c, j) => ({ key: `c${i}-${j}`, value: c, className: columns[j].n ? 'n num' : '' })) })), total, note });
        if (this.report === 'ar') {
            const r = await runArAging({ companyId, asOfDate, partyProfileId: null, includeSettled: false });
            const rows = (r.rows || []).filter((x) => Number(x.outstandingDocumentAmount) > 0);
            return table([{ label: 'Customer' }, { label: 'Invoice' }, { label: 'Due' }, { label: 'Days past due', n: true }, { label: 'Bucket' }, { label: 'Outstanding', n: true }],
                rows.map((x) => [x.customerName, x.legalNumber, date(x.dueDate), String(x.daysPastDue || 0), x.agingBucket, amount(x.outstandingDocumentAmount)]),
                amount(r.totalOutstanding), 'Posted invoices and credit notes still open at the end of the period.');
        }
        if (this.report === 'ap') {
            const r = await getPayables({ companyId, asOfDate, statusFilter: null, supplierProfileId: null, includeSettled: false });
            const rows = (r.bills || []).filter((b) => b.status === 'Posted' && Number(b.outstandingAmount) > 0);
            return table([{ label: 'Supplier' }, { label: 'Bill' }, { label: 'Due' }, { label: 'Days past due', n: true }, { label: 'Bucket' }, { label: 'Outstanding', n: true }],
                rows.map((b) => [b.supplierName, b.vendorReference ? `${b.billNumber} (${b.vendorReference})` : b.billNumber, date(b.dueDate), String(b.daysPastDue || 0),
                    b.agingBucket, amount(b.outstandingAmount)]), amount(r.totalOutstanding), 'Posted bills still to pay at the end of the period.');
        }
        if (this.report === 'cash') {
            const r = await getBankDashboard({ companyId });
            const banks = r.bankAccounts || [];
            return table([{ label: 'Account' }, { label: 'Bank' }, { label: 'Currency' }, { label: 'Ledger account' }, { label: 'Latest statement' },
                { label: 'Statement closing', n: true }, { label: 'Book balance', n: true }],
            banks.map((b) => [b.name, b.bankName || '\u2014', b.currencyCode, [b.glAccountCode, b.glAccountName].filter(Boolean).join(' '),
                b.latestStatementName ? `${b.latestStatementName}, ${date(b.latestStatementEndDate)}` : '\u2014',
                b.latestStatementName ? amount(b.latestStatementClosingAmount) : '\u2014', amount(b.currentBookBalance)]),
            amount(banks.reduce((sum, b) => sum + (Number(b.currentBookBalance) || 0), 0)), 'Book balances from the posted ledger with the latest bank statement for each account.');
        }
        if (this.report === 'payroll') {
            const r = await getPayrollSummary({ companyId, runId: null });
            const runs = r.runs || [];
            return table([{ label: 'Run' }, { label: 'Period' }, { label: 'State' }, { label: 'Employees', n: true }, { label: 'Gross', n: true }, { label: 'Deductions', n: true },
                { label: 'Employer', n: true }, { label: 'Net', n: true }],
            runs.map((x) => [x.name, `${date(x.periodStart)} to ${date(x.periodEnd)}`, x.state, String(x.employeeCount || 0), amount(x.grossTotal), amount(x.deductionTotal),
                amount(x.employerTotal), amount(x.netTotal)]),
            amount(runs.reduce((sum, x) => sum + (Number(x.netTotal) || 0), 0)),
            'Total employment cost is gross pay plus employer contributions. Employee-level pay stays in People & payroll.');
        }
        if (this.report === 'assets') {
            const r = await getAssetDashboard({ companyId });
            const assets = r.assets || [];
            return table([{ label: 'Asset' }, { label: 'Category' }, { label: 'Status' }, { label: 'In service' }, { label: 'Cost', n: true }, { label: 'Depreciation', n: true },
                { label: 'Book value', n: true }],
            assets.map((a) => [`${a.assetTag || a.companyAssetKey || ''} ${a.name}`.trim(), a.categoryName, a.status, date(a.inServiceDate), amount(a.cost),
                amount(a.postedDepreciation), amount(a.netBookValue)]), amount(r.netBookValue), 'Net book value after posted depreciation, impairment and disposals.');
        }
        if (this.report === 'bva') {
            const year = toPeriod ? Number(String(toPeriod.endDate).slice(0, 4)) : new Date().getFullYear();
            const r = await getBudgetVsActual({ companyId, fiscalYear: year, budgetId: null, periodIds: null, groupBy: 'ACCOUNT' });
            const rows = r.rows || [];
            return table([{ label: 'Account' }, { label: 'Budget', n: true }, { label: 'Actual', n: true }, { label: 'Variance', n: true }, { label: 'Variance %', n: true }],
                rows.map((x) => [`${x.accountCode} ${x.accountName}`, amount(x.budget), amount(x.actual), amount(x.variance),
                    x.budget ? `${Number(x.variancePercent || 0).toFixed(1)}%` : '\u2014']),
                undefined, `Approved budget for ${year} against posted actuals. Open Budgets to compare by period or department.`);
        }
        const r = await getTaxWorkspace({ companyId });
        const returns = r.returns || [];
        return table([{ label: 'Return' }, { label: 'Registration' }, { label: 'Period' }, { label: 'Status' }, { label: 'Net due', n: true }],
            returns.map((x) => [`${x.name}${x.returnVersion > 1 ? ` v${x.returnVersion}` : ''}`, x.registrationName, `${date(x.periodStart)} to ${date(x.periodEnd)}`,
                x.status, amount(x.netTaxDue)]), undefined, 'Tax returns prepared from posted tax lines. Prepare and lodge them in Tax.');
    }

    // ---------- balance sheet reconciliation ----------

    get bsModeButtons() {
        return [['statement', 'Statement'], ['recon', 'Reconciliation']].map(([id, label]) => ({ id, label, className: id === this.bsMode ? 'on' : '',
            pressed: id === this.bsMode ? 'true' : 'false' }));
    }

    get isRecon() {
        return this.bsMode === 'recon';
    }

    async handleBsMode(event) {
        this.bsMode = event.currentTarget.dataset.id;
        if (this.bsMode === 'recon') {
            await this.loadRecon();
        }
    }

    async loadRecon() {
        const period = this.periodById(this.asOfPeriod);
        this.reconError = undefined;
        this.recon = undefined;
        try {
            this.recon = await getReconciliation({ companyId: this.currentCompanyId, asOfDate: period ? period.endDate : todayIso() });
        } catch (error) {
            this.reconError = reduceError(error);
        }
    }

    get reconRows() {
        const amountOrDash = (v) => (v === null || v === undefined ? '\u2014' : formatNumber(v));
        return ((this.recon && this.recon.sections) || []).map((sec) => ({
            ...sec,
            ledgerText: amountOrDash(sec.ledger),
            subledgerText: amountOrDash(sec.subledger),
            differenceText: sec.difference === null || sec.difference === undefined ? '\u2014' : formatNumber(sec.difference),
            differenceClass: sec.difference ? 'n num down' : 'n num',
            chip: chipClass(sec.status, { Agreed: 'good', Difference: 'bad', 'Ledger only': 'neutral', 'Not available': 'warn', Dependency: 'neutral' }[sec.status])
        }));
    }

    get reconSummary() {
        const r = this.recon;
        if (!r) {
            return '';
        }
        const diffs = (r.sections || []).filter((x) => x.status === 'Difference').length;
        return `Total assets ${formatNumber(r.totalAssets)} ${this.cur}, liabilities and equity ${formatNumber(r.totalLiabilitiesAndEquity)} ${this.cur}. `
            + (diffs ? `${diffs} ${diffs === 1 ? 'section differs' : 'sections differ'} from its source.` : 'Every matched section agrees with its source.');
    }

    handleReconRow(event) {
        if (event.type === 'keydown' && event.key !== 'Enter' && event.key !== ' ') {
            return;
        }
        this.reconSection = this.reconRows.find((x) => x.key === event.currentTarget.dataset.key);
    }

    get reconDrawerOpen() {
        return Boolean(this.reconSection);
    }

    get reconDrawer() {
        const sec = this.reconSection;
        if (!sec) {
            return {};
        }
        const visible = this.visibleWorkspaces || [];
        return {
            title: sec.label,
            sub: `${sec.sourceLabel || 'Ledger'}: ${sec.status}`,
            note: sec.note,
            accounts: (sec.accounts || []).map((a) => ({ ...a, key: a.accountId, amountText: formatNumber(a.balance) })),
            hasAccounts: (sec.accounts || []).length > 0,
            sources: (sec.sources || []).map((x, i) => ({ ...x, key: x.recordId || `s${i}`, amountText: formatNumber(x.amount) })),
            hasSources: (sec.sources || []).length > 0,
            canOpen: Boolean(sec.workspace) && visible.includes(sec.workspace),
            openLabel: `Open ${sec.sourceLabel || 'workspace'}`
        };
    }

    handleCloseRecon() {
        this.reconSection = undefined;
    }

    handleOpenSource(event) {
        const sec = this.reconSection;
        const recordId = event.currentTarget.dataset.id || undefined;
        this.reconSection = undefined;
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: sec.workspace, recordId }, bubbles: true, composed: true }));
    }

    get isTable() {
        return TABLE_REPORTS.includes(this.report) && Boolean(this.result) && this.result.kind === 'table';
    }

    get tableReport() {
        const t = this.result;
        return { ...t, hasRows: (t.rows || []).length > 0, hasTotal: t.total !== undefined, totalSpan: Math.max(1, (t.columns || []).length - 1) };
    }

    get isCf() {
        return this.report === 'cf' && Boolean(this.result);
    }

    // ---------- overview ----------

    get overview() {
        const d = this.result;
        return {
            figures: [
                { key: 'c', label: 'Cash', value: money(d.cashBalance) },
                { key: 'r', label: 'Receivables', value: money(d.receivables) },
                { key: 'p', label: 'Payables', value: money(d.payables) },
                { key: 'n', label: 'Net profit, year to date', value: money(d.netYearToDate),
                    sub: d.budgetRevenueYearToDate !== null && d.budgetRevenueYearToDate !== undefined ? `Budget revenue ${money(d.budgetRevenueYearToDate)}` : 'No approved budget' }
            ],
            groups: (d.trend || []).map((m) => ({ label: m.label, values: [Number(m.revenue) || 0, Number(m.expense) || 0] })),
            series: [{ name: 'Revenue', color: 'var(--chart-1)' }, { name: 'Expenses', color: 'var(--chart-3)' }],
            hasTrend: (d.trend || []).length > 0,
            runs: (d.recentRuns || []).map((r, i) => ({ key: `r${i}`, title: r.reportType, detail: [r.generatedByName, formatDateTime(r.generatedAt)].filter(Boolean).join(', ') })),
            hasRuns: (d.recentRuns || []).length > 0
        };
    }

    // ---------- statements ----------

    statementGroups(kind) {
        const r = this.result;
        return [...(r.groups || [])].sort((a, b) => a.displayOrder - b.displayOrder).map((g) => ({
            key: g.groupKey,
            label: labelOf(g.groupKey),
            totalLabel: `Total ${labelOf(g.groupKey).toLowerCase()}`,
            currentText: money(g.currentTotal),
            comparisonText: money(g.comparisonTotal),
            varianceText: money(g.varianceTotal),
            varianceClass: Number(g.varianceTotal) < 0 ? 'n neg' : 'n',
            rows: [...(g.rows || [])].sort((a, b) => a.displayOrder - b.displayOrder).map((row) => ({
                key: `${kind}-${row.rowKey}`,
                rowKey: row.rowKey,
                label: row.syntheticCurrentYearEarnings ? 'Current year earnings' : labelOf(row.rowKey),
                currentText: money(row.currentAmount),
                comparisonText: money(row.comparisonAmount),
                varianceText: money(row.varianceAmount),
                varianceClass: Number(row.varianceAmount) < 0 ? 'n neg' : 'n',
                drillable: !row.syntheticCurrentYearEarnings && (row.currentLineCount > 0 || row.comparisonLineCount > 0),
                rowClass: !row.syntheticCurrentYearEarnings && (row.currentLineCount > 0 || row.comparisonLineCount > 0) ? 'pl-row click' : 'pl-row'
            }))
        }));
    }

    get pnl() {
        const r = this.result;
        return {
            groups: this.statementGroups('pnl'),
            hasComparison: Boolean(r.hasComparison),
            netText: money(r.currentNetProfitLoss),
            comparisonNetText: money(r.comparisonNetProfitLoss),
            varianceText: money(r.netProfitVariance),
            rangeText: `${formatDate(r.fromDate)} to ${formatDate(r.toDate)}`,
            comparisonRangeText: r.hasComparison ? `${formatDate(r.comparisonFromDate)} to ${formatDate(r.comparisonToDate)}` : '',
            empty: !(r.groups || []).length
        };
    }

    get bs() {
        const r = this.result;
        return {
            groups: this.statementGroups('bs'),
            hasComparison: Boolean(r.hasComparison),
            asOfText: `As at ${formatDate(r.asOfDate)}`,
            comparisonText: r.hasComparison ? `As at ${formatDate(r.comparisonAsOfDate)}` : '',
            bannerClass: r.currentBalanced ? 'banner t-good gap' : 'banner t-bad gap',
            bannerIcon: r.currentBalanced ? 'check' : 'alert',
            bannerTitle: r.currentBalanced ? 'Balance sheet balances' : 'Balance sheet does not balance',
            bannerText: r.currentBalanced
                ? `Assets ${money(r.currentAssets)} equal liabilities and equity ${money(r.currentLiabilitiesAndEquity)}.`
                : `Difference of ${money(r.currentEquationDifference)}. Check the report mappings before relying on it.`,
            earningsText: money(r.currentYearEarnings),
            totalText: money(r.currentLiabilitiesAndEquity),
            empty: !(r.groups || []).length
        };
    }

    get tb() {
        const r = this.result;
        return {
            bannerClass: r.balanced ? 'banner t-good gap' : 'banner t-bad gap',
            bannerIcon: r.balanced ? 'check' : 'alert',
            bannerTitle: r.balanced ? 'Trial balance agrees' : 'Trial balance is out',
            bannerText: r.balanced ? `Debits and credits both total ${money(r.totalClosingDebit)} ${this.cur}.` : `Difference of ${money(r.closingDifference)}. Investigate before closing.`,
            rows: (r.rows || []).map((row) => ({ ...row, debitText: row.closingDebit ? money(row.closingDebit) : '', creditText: row.closingCredit ? money(row.closingCredit) : '' })),
            debitText: money(r.totalClosingDebit),
            creditText: money(r.totalClosingCredit),
            empty: !(r.rows || []).length
        };
    }

    get gl() {
        const account = ((this.result && this.result.accounts) || [])[0];
        if (!account) {
            return { empty: true };
        }
        const opening = (Number(account.openingDebit) || 0) - (Number(account.openingCredit) || 0);
        let running = opening;
        const lines = (account.lines || []).map((l) => {
            running += (Number(l.debit) || 0) - (Number(l.credit) || 0);
            return { ...l, dateText: formatDate(l.accountingDate), debitText: l.debit ? money(l.debit) : '', creditText: l.credit ? money(l.credit) : '', balanceText: money(running) };
        });
        return {
            empty: false,
            title: `${account.accountCode} ${account.accountName}`,
            openingText: money(opening),
            closingText: money((Number(account.closingDebit) || 0) - (Number(account.closingCredit) || 0)),
            lines,
            truncated: Boolean(this.result.truncated),
            truncatedText: `Showing ${account.displayedLineCount} of ${account.movementLineCount} lines. Narrow the period to see the rest.`
        };
    }

    get cf() {
        const r = this.result;
        return {
            sections: (r.sections || []).map((s, i) => ({
                key: `s${i}`, name: s.name, totalText: money(s.total), totalLabel: `Net cash from ${String(s.name || '').toLowerCase()}`,
                lines: (s.lines || []).map((l, j) => ({ key: `s${i}l${j}`, label: [l.accountCode, l.accountName].filter(Boolean).join(' '), amountText: money(l.amount) }))
            })),
            netText: money(r.netChange),
            openingText: money(r.openingCash),
            closingText: money(r.closingCash),
            bannerClass: r.reconciled ? 'banner t-good gap' : 'banner t-warn gap',
            bannerTitle: r.reconciled ? 'Cash flow reconciles to the ledger' : 'Cash flow does not reconcile',
            bannerText: r.reconciled ? `Closing cash ${money(r.closingCash)} agrees to the cash accounts.` : `Statement closing cash ${money(r.closingCash)} against ledger ${money(r.ledgerClosingCash)}. Accounts without a cash flow category report as operating.`
        };
    }

    // ---------- drill-down ----------

    async handleDrill(event) {
        const rowKey = event.currentTarget.dataset.key;
        const accountId = event.currentTarget.dataset.account;
        if (!rowKey && !accountId) {
            return;
        }
        const companyId = this.currentCompanyId;
        this.drillOpen = true;
        this.drillLines = [];
        this.drillError = undefined;
        try {
            let lines;
            if (this.report === 'tb') {
                const row = this.result.rows.find((r) => r.glAccountId === accountId);
                this.drillTitle = `${row.accountCode} ${row.accountName}`;
                lines = await getMovementLines({ companyId, glAccountId: accountId, fromDate: this.result.fromDate, toDate: this.result.toDate });
            } else if (this.report === 'bs') {
                this.drillTitle = labelOf(rowKey);
                lines = await getBsDrilldown({ companyId, reportDefinitionId: this.result.reportDefinitionId, asOfDate: this.result.asOfDate,
                    comparisonAsOfDate: this.result.comparisonAsOfDate || null, rowKey, comparison: false });
            } else {
                this.drillTitle = labelOf(rowKey);
                const r = this.result;
                lines = await getPnlDrilldown({ companyId, reportDefinitionId: r.reportDefinitionId, fromDate: r.fromDate, toDate: r.toDate,
                    comparisonFromDate: r.comparisonFromDate || null, comparisonToDate: r.comparisonToDate || null, departmentId: this.departmentId || null,
                    costCenterId: null, projectId: null, rowKey, comparison: false });
            }
            this.drillLines = (lines || []).map((l) => ({
                ...l,
                dateText: formatDate(l.accountingDate),
                account: [l.accountCode, l.accountName].filter(Boolean).join(' '),
                debitText: l.debit ? money(l.debit) : '',
                creditText: l.credit ? money(l.credit) : ''
            }));
        } catch (error) {
            this.drillError = reduceError(error);
        }
    }

    handleDrillKey(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleDrill(event);
        }
    }

    get hasDrillLines() {
        return this.drillLines.length > 0;
    }

    handleCloseDrill() {
        this.drillOpen = false;
    }

    get canOpenJournal() {
        return Array.isArray(this.visibleWorkspaces) && this.visibleWorkspaces.includes('journal');
    }

    handleOpenJournal(event) {
        this.drillOpen = false;
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'journal', recordId: event.currentTarget.dataset.id }, bubbles: true, composed: true }));
    }

    // ---------- export ----------

    get exportRows() {
        if (this.isTable) {
            return [this.result.columns.map((c) => c.label), ...this.result.rows.map((r) => r.cells.map((c) => c.value))];
        }
        if (this.isPnl || this.isBs) {
            const rows = [['Line', 'Current', 'Comparison', 'Variance']];
            this.statementGroups(this.report).forEach((g) => {
                g.rows.forEach((r) => rows.push([`${g.label}: ${r.label}`, r.currentText, r.comparisonText, r.varianceText]));
                rows.push([g.totalLabel, g.currentText, g.comparisonText, g.varianceText]);
            });
            return rows;
        }
        if (this.isTb) {
            return [['Code', 'Account', 'Type', 'Debit', 'Credit'], ...this.tb.rows.map((r) => [r.accountCode, r.accountName, r.accountType, r.debitText, r.creditText])];
        }
        if (this.isGl && !this.gl.empty) {
            return [['Date', 'Journal', 'Description', 'Debit', 'Credit', 'Balance'], ...this.gl.lines.map((l) => [l.dateText, l.journalName, l.explanation, l.debitText, l.creditText, l.balanceText])];
        }
        if (this.isCf) {
            const rows = [['Section', 'Line', 'Amount']];
            this.cf.sections.forEach((s) => s.lines.forEach((l) => rows.push([s.name, l.label, l.amountText])));
            return rows;
        }
        if (this.isOverview) {
            return [['Figure', 'Value'], ...this.overview.figures.map((f) => [f.label, f.value])];
        }
        return [];
    }

    get exportDisabled() {
        return !this.result;
    }

    handleExport() {
        const quote = (v) => `"${String(v === null || v === undefined ? '' : v).replace(/"/g, '""')}"`;
        const csv = this.exportRows.map((r) => r.map(quote).join(',')).join('\n');
        const link = this.template.querySelector('.sab-download');
        link.href = `data:text/csv;charset=utf-8,${encodeURIComponent(csv)}`;
        link.download = `${this.reportTitle.toLowerCase().replace(/\s+/g, '-')}.csv`;
        link.click();
        toast(this, `${this.reportTitle} exported`);
    }

    handleRetry() {
        this.run();
    }
}
