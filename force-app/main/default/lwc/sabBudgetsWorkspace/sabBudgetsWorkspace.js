import { LightningElement, api } from 'lwc';
import getWorkspace from '@salesforce/apex/SABBudgetWorkspaceController.getWorkspace';
import getBudgetDetail from '@salesforce/apex/SABBudgetWorkspaceController.getBudgetDetail';
import getBudgetVsActual from '@salesforce/apex/SABBudgetVarianceService.getBudgetVsActual';
import saveDraft from '@salesforce/apex/SABBudgetService.saveDraft';
import submitBudget from '@salesforce/apex/SABBudgetService.submit';
import approveBudget from '@salesforce/apex/SABBudgetService.approve';
import returnBudget from '@salesforce/apex/SABBudgetService.returnToDraft';
import reviseBudget from '@salesforce/apex/SABBudgetService.revise';
import { formatNumber, formatDate, chipClass } from 'c/sabFormat';
import { reduceError, newKey, toast } from 'c/sabMoneyShared';

const INCOME = ['Revenue', 'Income'];

/**
 * Budgets in the Harbourline demo layout (G22G-6): budget versions with a department filter, actual against budget
 * grouped into income and expenses with used meters, monthly revenue chart, and draft, submit, approve, return, revise
 * and line editing on SABBudgetService, unchanged.
 */
export default class SabBudgetsWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api recordId;
    @api periodKey;

    data;
    variance;
    detail;
    monthly = [];
    errorMessage;
    varianceError;
    isLoading = false;
    fiscalYear;
    budgetId;
    departmentId = '';
    groupBy = 'ACCOUNT';
    spread;
    dimensionId = '';
    fromPeriod = '';
    toPeriod = '';
    busy = false;
    modal;
    form = {};
    lines = [];
    formError;
    requestKeys = {};
    loadSequence = 0;
    varianceSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.budgetId = undefined;
            this.fiscalYear = undefined;
            this.load();
        }
    }

    async load() {
        const companyId = this.currentCompanyId;
        const sequence = ++this.loadSequence;
        if (!companyId) {
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const data = await getWorkspace({ companyId });
            if (sequence !== this.loadSequence) {
                return;
            }
            this.data = data;
            const budgets = data.budgets || [];
            if (!budgets.some((b) => b.budgetId === this.budgetId)) {
                const sorted = [...budgets].sort((a, b) => b.fiscalYear - a.fiscalYear || b.version - a.version);
                const approved = sorted.find((b) => b.status === 'Approved');
                // Directors review performance against the approved version; preparers start on the latest version.
                const latest = this.isDirector && approved ? approved : sorted[0];
                this.budgetId = latest ? latest.budgetId : undefined;
            }
            const selected = budgets.find((b) => b.budgetId === this.budgetId);
            this.fiscalYear = selected ? selected.fiscalYear : this.fiscalYear || (data.fiscalYears || [])[0] || new Date().getFullYear();
            await this.loadBudget();
        } catch (error) {
            if (sequence === this.loadSequence) {
                this.errorMessage = reduceError(error);
            }
        } finally {
            if (sequence === this.loadSequence) {
                this.isLoading = false;
            }
        }
    }

    async loadBudget() {
        const sequence = ++this.varianceSequence;
        this.varianceError = undefined;
        this.monthly = [];
        if (!this.budgetId) {
            this.variance = undefined;
            this.detail = undefined;
            return;
        }
        try {
            const [variance, detail] = await Promise.all([
                getBudgetVsActual({ companyId: this.currentCompanyId, fiscalYear: this.fiscalYear, budgetId: this.budgetId,
                    periodIds: this.rangePeriodIds, groupBy: this.groupBy }),
                getBudgetDetail({ budgetId: this.budgetId })
            ]);
            if (sequence !== this.varianceSequence) {
                return;
            }
            this.variance = variance;
            this.detail = detail;
            await this.loadMonthly(sequence);
        } catch (error) {
            if (sequence === this.varianceSequence) {
                this.variance = undefined;
                this.varianceError = reduceError(error);
            }
        }
    }

    async loadMonthly(sequence) {
        const periods = ((this.data && this.data.periods) || []).filter((p) => p.fiscalYear === this.fiscalYear).slice(0, 12);
        const months = [];
        for (const period of periods) {
            // eslint-disable-next-line no-await-in-loop
            const result = await getBudgetVsActual({ companyId: this.currentCompanyId, fiscalYear: this.fiscalYear, budgetId: this.budgetId,
                periodIds: [period.value], groupBy: 'ACCOUNT' });
            if (sequence !== this.varianceSequence) {
                return;
            }
            months.push({ label: period.label, values: [Number(result.totalRevenueActual) || 0, Number(result.totalRevenueBudget) || 0] });
        }
        this.monthly = months;
    }

    // ---------- header ----------

    get showLoading() {
        return this.isLoading && !this.data && !this.errorMessage;
    }

    get cur() {
        return (this.data && this.data.functionalCurrency) || this.currencyCode || '';
    }

    get can() {
        return (this.data && this.data.capabilities) || {};
    }

    get personaLabel() {
        return (this.persona && this.persona.label) || 'Your';
    }

    get budget() {
        return ((this.data && this.data.budgets) || []).find((b) => b.budgetId === this.budgetId);
    }

    get hasBudget() {
        return Boolean(this.budget);
    }

    get yearOptions() {
        const years = new Set([...(this.data.fiscalYears || []), ...(this.data.budgets || []).map((b) => b.fiscalYear)]);
        return [...years].sort((a, b) => b - a).map((y) => ({ value: String(y), label: `FY ${y}`, selected: y === this.fiscalYear }));
    }

    async handleYear(event) {
        this.fiscalYear = Number(event.target.value);
        this.fromPeriod = '';
        this.toPeriod = '';
        const first = ((this.data && this.data.budgets) || []).filter((b) => b.fiscalYear === this.fiscalYear).sort((a, b) => b.version - a.version)[0];
        this.budgetId = first ? first.budgetId : undefined;
        await this.loadBudget();
    }

    get versionButtons() {
        return ((this.data && this.data.budgets) || [])
            .filter((b) => b.fiscalYear === this.fiscalYear)
            .sort((a, b) => a.version - b.version)
            .map((b) => ({ id: b.budgetId, label: `${b.name} v${b.version}`, className: b.budgetId === this.budgetId ? 'on' : '', pressed: b.budgetId === this.budgetId ? 'true' : 'false' }));
    }

    async handleVersion(event) {
        this.budgetId = event.currentTarget.dataset.id;
        await this.loadBudget();
    }

    get statusChip() {
        return chipClass(this.budget.status, this.budget.status === 'Draft' ? 'neutral' : undefined);
    }

    get isDirector() {
        return Boolean(this.persona && this.persona.key === 'DIRECTOR');
    }

    // ---------- review filters: period range and dimension ----------

    get fyPeriods() {
        return ((this.data && this.data.periods) || []).filter((p) => p.fiscalYear === this.fiscalYear);
    }

    /** Selected periods between From and To, or null for the whole year. */
    get rangePeriodIds() {
        const list = this.fyPeriods;
        if (!this.fromPeriod && !this.toPeriod) {
            return null;
        }
        const start = this.fromPeriod ? list.findIndex((p) => p.value === this.fromPeriod) : 0;
        const end = this.toPeriod ? list.findIndex((p) => p.value === this.toPeriod) : list.length - 1;
        return list.slice(Math.max(0, start), end < 0 ? list.length : end + 1).map((p) => p.value);
    }

    get fromOptions() {
        return this.fyPeriods.map((p) => ({ ...p, selected: p.value === this.fromPeriod }));
    }

    get toOptions() {
        return this.fyPeriods.map((p) => ({ ...p, selected: p.value === this.toPeriod }));
    }

    get groupButtons() {
        return [['ACCOUNT', 'Account'], ['ACCOUNT_DEPARTMENT', 'Department'], ['ACCOUNT_COST_CENTER', 'Cost center'], ['ACCOUNT_PROJECT', 'Project']].map(([id, label]) => ({
            id, label, className: id === this.groupBy ? 'on' : '', pressed: id === this.groupBy ? 'true' : 'false' }));
    }

    get showDimensionFilter() {
        return this.groupBy !== 'ACCOUNT';
    }

    get dimensionLabel() {
        return this.groupBy === 'ACCOUNT_COST_CENTER' ? 'Cost center' : this.groupBy === 'ACCOUNT_PROJECT' ? 'Project' : 'Department';
    }

    get dimensionOptions() {
        const list = this.groupBy === 'ACCOUNT_COST_CENTER' ? this.data.costCenters : this.groupBy === 'ACCOUNT_PROJECT' ? this.data.projects : this.data.departments;
        return (list || []).map((d) => ({ ...d, selected: d.value === this.dimensionId }));
    }

    async handleGroup(event) {
        this.groupBy = event.currentTarget.dataset.id;
        this.dimensionId = '';
        await this.loadBudget();
    }

    handleDimension(event) {
        this.dimensionId = event.target.value;
    }

    async handleRange(event) {
        this[event.target.dataset.field] = event.target.value;
        await this.loadBudget();
    }

    handleApprovedVersion() {
        const approved = ((this.data && this.data.budgets) || []).find((b) => b.fiscalYear === this.fiscalYear && b.status === 'Approved');
        if (approved) {
            this.budgetId = approved.budgetId;
            this.loadBudget();
        }
    }

    get hasApprovedVersion() {
        return ((this.data && this.data.budgets) || []).some((b) => b.fiscalYear === this.fiscalYear && b.status === 'Approved');
    }

    get showApprovedButton() {
        return this.hasApprovedVersion && !(this.budget && this.budget.status === 'Approved');
    }

    get versionFacts() {
        const b = this.budget;
        if (!b) {
            return [];
        }
        return [['Version', `v${b.version}`], ['Currency', b.currencyCode || '\u2014'], ['Lines', String(b.lineCount || 0)],
            ['Submitted', b.submittedAt ? `${b.submittedByName || ''}, ${formatDate(String(b.submittedAt).slice(0, 10))}` : '\u2014'],
            ['Approved', b.approvedAt ? `${b.approvedByName || ''}, ${formatDate(String(b.approvedAt).slice(0, 10))}` : '\u2014']]
            .map(([label, value]) => ({ key: label, label, value }));
    }


    get actions() {
        const b = this.budget || {};
        const manageReason = this.can.manage ? undefined : `${this.personaLabel} role cannot manage budgets`;
        const approveReason = this.can.approve ? undefined : `${this.personaLabel} role cannot approve budgets`;
        return {
            showSubmit: b.status === 'Draft',
            showEdit: b.status === 'Draft',
            showEditButton: b.status === 'Draft' && Boolean(this.can.manage),
            showApprove: b.status === 'Submitted',
            showReturn: b.status === 'Submitted',
            showRevise: b.status === 'Approved',
            manageDisabled: this.busy || !this.can.manage,
            canManage: Boolean(this.can.manage),
            manageTitle: manageReason,
            approveDisabled: this.busy || !this.can.approve,
            approveTitle: approveReason
        };
    }

    // ---------- variance ----------

    get rows() {
        const rows = ((this.variance && this.variance.rows) || []).filter((r) => !this.dimensionId || r.dimensionId === this.dimensionId);
        return rows.map((r) => {
            const used = r.budget ? (r.actual / r.budget) * 100 : 0;
            const positive = r.favourable !== false;
            return {
                ...r,
                key: `${r.glAccountId}-${r.dimensionId || ''}`,
                income: INCOME.includes(r.accountType),
                actualText: formatNumber(r.actual),
                budgetText: formatNumber(r.budget),
                varianceText: `${positive ? '+' : '-'}${formatNumber(Math.abs(Number(r.variance) || 0))}`,
                varianceClass: positive ? 'n up' : 'n neg',
                pctText: r.budget ? `${positive ? '+' : '-'}${Math.abs(Number(r.variancePercent) || 0).toFixed(1)}%` : '\u2014',
                meterClass: positive ? 'meter' : 'meter warn',
                meterStyle: `width:${Math.min(100, Math.max(0, used))}%`
            };
        });
    }

    get incomeRows() {
        return this.rows.filter((r) => r.income);
    }

    get expenseRows() {
        return this.rows.filter((r) => !r.income);
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get totals() {
        const sum = (list, f) => list.reduce((s, r) => s + (Number(r[f]) || 0), 0);
        const ra = sum(this.incomeRows, 'actual');
        const rb = sum(this.incomeRows, 'budget');
        const ea = sum(this.expenseRows, 'actual');
        const eb = sum(this.expenseRows, 'budget');
        const np = ra - ea;
        const npb = rb - eb;
        return { ra, rb, ea, eb, np, npb, diff: np - npb };
    }

    get netRow() {
        const t = this.totals;
        return { actual: formatNumber(t.np), budget: formatNumber(t.npb), variance: `${t.diff >= 0 ? '+' : '-'}${formatNumber(Math.abs(t.diff))}`,
            varianceClass: t.diff >= 0 ? 'n up' : 'n neg' };
    }

    get figures() {
        const t = this.totals;
        return [
            { key: 'r', label: 'Revenue, year to date', value: formatNumber(t.ra, 0), sub: `Budget ${formatNumber(t.rb, 0)}` },
            { key: 'e', label: 'Expenses, year to date', value: formatNumber(t.ea, 0), sub: `Budget ${formatNumber(t.eb, 0)}` },
            { key: 'n', label: 'Net profit variance', value: `${t.diff >= 0 ? '+' : '-'}${formatNumber(Math.abs(t.diff), 0)}`, sub: `Actual ${formatNumber(t.np, 0)} against ${formatNumber(t.npb, 0)}` },
            { key: 'f', label: 'Budget total', value: formatNumber(this.detail ? this.detail.total : 0, 0), sub: `${(this.detail && this.detail.lines ? this.detail.lines.length : 0)} budget lines` }
        ];
    }

    get chartSeries() {
        return [{ name: 'Actual', color: 'var(--chart-1)' }, { name: 'Budget', color: 'var(--chart-2)' }];
    }

    get hasMonthly() {
        return this.monthly.length > 0;
    }

    get tableTitle() {
        return `Actual against budget, FY ${this.fiscalYear}`;
    }

    // ---------- actions ----------

    keyFor(action, recordId) {
        const name = `${action}|${recordId}`;
        if (!this.requestKeys[name]) {
            this.requestKeys = { ...this.requestKeys, [name]: newKey(`BUDGET-${action}`, recordId) };
        }
        return this.requestKeys[name];
    }

    async execute(action, call, message) {
        const name = `${action}|${this.budgetId}`;
        this.busy = true;
        try {
            const result = await call(this.keyFor(action, this.budgetId));
            const keys = { ...this.requestKeys };
            delete keys[name];
            this.requestKeys = keys;
            if (result && result.budgetId) {
                this.budgetId = result.budgetId;
            }
            toast(this, message);
            await this.load();
            return true;
        } catch (error) {
            toast(this, reduceError(error), 'bad');
            return false;
        } finally {
            this.busy = false;
        }
    }

    handleSubmit() {
        const budgetId = this.budgetId;
        this.execute('SUBMIT', (requestKey) => submitBudget({ budgetId, requestKey }), 'Budget submitted for approval');
    }

    handleApprove() {
        const budgetId = this.budgetId;
        this.execute('APPROVE', (requestKey) => approveBudget({ budgetId, requestKey }), 'Budget approved');
    }

    openModal(kind, form) {
        this.form = form;
        this.formError = undefined;
        this.modal = kind;
    }

    handleReturn() {
        this.openModal('return', { reason: '' });
    }

    handleRevise() {
        this.openModal('revise', { reason: '' });
    }

    handleNew() {
        this.openModal('new', { name: '', fiscalYear: String(this.fiscalYear || new Date().getFullYear()), copyFrom: '', adjustPercent: '0' });
    }

    get copyOptions() {
        return ((this.data && this.data.budgets) || []).map((b) => ({ value: b.budgetId, label: `FY ${b.fiscalYear} ${b.name} v${b.version} (${b.status})`,
            selected: b.budgetId === this.form.copyFrom }));
    }

    get currencyText() {
        return (this.data && this.data.functionalCurrency) || '';
    }

    /** Lines of another version moved to the new year by period position and adjusted by a percentage. */
    async copiedLines(sourceId, fiscalYear, percent) {
        const source = (this.data.budgets || []).find((b) => b.budgetId === sourceId);
        const detail = await getBudgetDetail({ budgetId: sourceId });
        const periods = this.data.periods || [];
        const from = periods.filter((p) => p.fiscalYear === source.fiscalYear).map((p) => p.value);
        const to = periods.filter((p) => p.fiscalYear === fiscalYear).map((p) => p.value);
        const factor = 1 + (Number(percent) || 0) / 100;
        const lines = [];
        for (const l of detail.lines || []) {
            const index = from.indexOf(l.accountingPeriodId);
            if (index < 0 || index >= to.length) {
                continue;
            }
            lines.push({ accountingPeriodId: to[index], glAccountId: l.glAccountId, departmentId: l.departmentId || null, costCenterId: l.costCenterId || null,
                projectId: l.projectId || null,
                amount: Math.round((Number(l.amount) || 0) * factor * 100) / 100 });
        }
        if (!to.length) {
            throw new Error(`FY ${fiscalYear} has no accounting periods yet. Generate them in Company setup first.`);
        }
        return lines;
    }

    // ---------- spread an annual amount ----------

    get spreadOpen() {
        return Boolean(this.spread);
    }

    handleSpreadToggle() {
        this.spread = this.spread ? undefined : { glAccountId: '', departmentId: '', costCenterId: '', projectId: '', annual: '' };
    }

    get spreadAccountOptions() {
        return ((this.data && this.data.accounts) || []).map((o) => ({ ...o, selected: this.spread && o.value === this.spread.glAccountId }));
    }

    get spreadProjectOptions() {
        return ((this.data && this.data.projects) || []).map((o) => ({ ...o, selected: this.spread && o.value === this.spread.projectId }));
    }

    get hasProjects() {
        return ((this.data && this.data.projects) || []).length > 0;
    }

    get spreadDepartmentOptions() {
        return ((this.data && this.data.departments) || []).map((o) => ({ ...o, selected: this.spread && o.value === this.spread.departmentId }));
    }

    handleSpreadField(event) {
        this.spread = { ...this.spread, [event.target.dataset.field]: event.target.value };
    }

    handleSpreadApply() {
        const periods = this.fyPeriods;
        const annual = Number(this.spread.annual) || 0;
        if (!this.spread.glAccountId || !annual || !periods.length) {
            this.formError = 'Choose an account and an annual amount to spread across the periods.';
            return;
        }
        const each = Math.floor((annual / periods.length) * 100) / 100;
        const last = Math.round((annual - each * (periods.length - 1)) * 100) / 100;
        const added = periods.map((p, i) => ({ key: `s${Date.now()}${i}`, accountingPeriodId: p.value, glAccountId: this.spread.glAccountId,
            departmentId: this.spread.departmentId || '', costCenterId: '', projectId: this.spread.projectId || '', amount: String(i === periods.length - 1 ? last : each) }));
        const kept = this.lines.filter((l) => l.glAccountId || l.amount);
        this.lines = [...kept, ...added];
        this.spread = undefined;
        this.formError = undefined;
    }

    handleEdit() {
        this.spread = undefined;
        this.lines = ((this.detail && this.detail.lines) || []).map((l, i) => ({ key: `l${i}`, accountingPeriodId: l.accountingPeriodId, glAccountId: l.glAccountId,
            departmentId: l.departmentId || '', costCenterId: l.costCenterId || '', projectId: l.projectId || '',
            amount: l.amount === null || l.amount === undefined ? '' : String(l.amount) }));
        if (!this.lines.length) {
            this.lines = [this.blankLine()];
        }
        this.openModal('lines', {});
    }

    blankLine() {
        const period = ((this.data && this.data.periods) || []).find((p) => p.fiscalYear === this.fiscalYear);
        return { key: `n${Date.now()}${Math.random()}`, accountingPeriodId: period ? period.value : '', glAccountId: '', departmentId: this.departmentId || '', costCenterId: '', projectId: '', amount: '' };
    }

    get modalOpen() {
        return Boolean(this.modal);
    }

    get modalHeading() {
        return { new: 'New budget', return: 'Return budget to draft', revise: 'New version', lines: 'Budget lines' }[this.modal];
    }

    get modalSub() {
        return {
            new: 'Creates a draft budget for the fiscal year. Add lines next.',
            return: 'Sends the budget back to its preparer. A reason is required.',
            revise: 'Creates a new draft version from this approved budget. A reason is required.',
            lines: 'One amount per period, account and optional department or cost center.'
        }[this.modal];
    }

    get isNewModal() {
        return this.modal === 'new';
    }

    get isReasonModal() {
        return this.modal === 'return' || this.modal === 'revise';
    }

    get isLinesModal() {
        return this.modal === 'lines';
    }

    get saveLabel() {
        return { new: 'Create budget', return: 'Return to draft', revise: 'Create version', lines: 'Save lines' }[this.modal];
    }

    get lineRows() {
        const opts = (list, value) => (list || []).map((o) => ({ value: o.value, label: o.label, selected: o.value === value }));
        const periods = ((this.data && this.data.periods) || []).filter((p) => p.fiscalYear === this.fiscalYear);
        return this.lines.map((l, i) => ({
            ...l,
            index: i,
            periodOptions: opts(periods, l.accountingPeriodId),
            accountOptions: opts(this.data.accounts, l.glAccountId),
            departmentOptions: opts(this.data.departments, l.departmentId),
            costCenterOptions: opts(this.data.costCenters, l.costCenterId),
            projectOptions: opts(this.data.projects, l.projectId),
            label: `line ${i + 1}`
        }));
    }

    get linesTotal() {
        return formatNumber(this.lines.reduce((s, l) => s + (Number(l.amount) || 0), 0));
    }

    handleLineField(event) {
        const index = Number(event.target.dataset.index);
        const field = event.target.dataset.field;
        this.lines = this.lines.map((l, i) => (i === index ? { ...l, [field]: event.target.value } : l));
    }

    handleAddLine() {
        this.lines = [...this.lines, this.blankLine()];
    }

    handleRemoveLine(event) {
        const index = Number(event.currentTarget.dataset.index);
        this.lines = this.lines.filter((l, i) => i !== index);
    }

    handleField(event) {
        this.form = { ...this.form, [event.target.dataset.field]: event.target.value };
    }

    handleCloseModal() {
        if (!this.busy) {
            this.modal = undefined;
        }
    }

    async handleSave() {
        const f = this.form;
        if (this.isReasonModal && !String(f.reason || '').trim()) {
            this.formError = 'A reason is required.';
            return;
        }
        let ok = false;
        const budgetId = this.budgetId;
        if (this.modal === 'new') {
            this.busy = true;
            try {
                const year = Number(f.fiscalYear);
                const lines = f.copyFrom ? await this.copiedLines(f.copyFrom, year, f.adjustPercent) : [];
                this.budgetId = await saveDraft({ request: { budgetId: null, companyId: this.currentCompanyId, fiscalYear: year, name: f.name, lines } });
                this.fiscalYear = Number(f.fiscalYear);
                toast(this, f.copyFrom ? 'Draft budget created from the copied version' : 'Draft budget created');
                ok = true;
            } catch (error) {
                this.formError = reduceError(error);
            } finally {
                this.busy = false;
            }
            if (ok) {
                this.modal = undefined;
                await this.load();
            }
            return;
        }
        if (this.modal === 'lines') {
            this.busy = true;
            try {
                await saveDraft({ request: { budgetId, companyId: this.currentCompanyId, fiscalYear: this.budget.fiscalYear, name: this.budget.name,
                    lines: this.lines.filter((l) => l.glAccountId && l.accountingPeriodId).map((l) => ({ accountingPeriodId: l.accountingPeriodId, glAccountId: l.glAccountId,
                        departmentId: l.departmentId || null, costCenterId: l.costCenterId || null, projectId: l.projectId || null,
                        amount: l.amount === '' ? null : Number(l.amount) })) } });
                toast(this, 'Budget lines saved');
                ok = true;
            } catch (error) {
                this.formError = reduceError(error);
            } finally {
                this.busy = false;
            }
            if (ok) {
                this.modal = undefined;
                await this.load();
            }
            return;
        }
        ok = this.modal === 'return'
            ? await this.execute('RETURN', (requestKey) => returnBudget({ budgetId, reason: f.reason.trim(), requestKey }), 'Budget returned to draft')
            : await this.execute('REVISE', (requestKey) => reviseBudget({ budgetId, reason: f.reason.trim(), requestKey }), 'New draft version created');
        if (ok) {
            this.modal = undefined;
        }
    }

    handleRetry() {
        this.load();
    }
}
