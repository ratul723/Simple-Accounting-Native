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
import { formatNumber, formatDate, formatDateTime } from 'c/sabFormat';
import { reduceError, todayIso, toast } from 'c/sabMoneyShared';

const REPORTS = [
    { id: 'overview', label: 'Management overview', tag: 'Available' },
    { id: 'pnl', label: 'Profit and loss', tag: 'Available' },
    { id: 'bs', label: 'Balance sheet', tag: 'Available' },
    { id: 'tb', label: 'Trial balance', tag: 'Available' },
    { id: 'gl', label: 'General ledger', tag: 'Available' },
    { id: 'cf', label: 'Cash flow', tag: 'Available' },
    { id: 'aging', label: 'Receivables aging', tag: 'In Sales' }
];

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
        if (id === 'aging') {
            this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'sales' }, bubbles: true, composed: true }));
            return;
        }
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
