import { LightningElement, api } from 'lwc';
import getProjects from '@salesforce/apex/SABAdminWorkspaceController.getProjects';
import getReport from '@salesforce/apex/SABProjectFinancialService.getReport';
import getLedgerPage from '@salesforce/apex/SABProjectFinancialService.getLedgerPage';
import saveProject from '@salesforce/apex/SABAdminWorkspaceService.saveProject';
import { formatNumber, formatDate, formatDateShort, chipClass } from 'c/sabFormat';
import { reduceError, newKey, todayIso, toast } from 'c/sabMoneyShared';

const COLORS = ['var(--chart-1)', 'var(--chart-3)', 'var(--chart-4)', 'var(--chart-5)', 'var(--chart-2)'];
const STATUSES = ['Planned', 'Active', 'Complete', 'Cancelled'];
const PAGE = 25;

/**
 * Projects in the Harbourline demo layout (G22H-0): project cards with revenue, cost and margin from lines tagged with
 * the project, a project panel with cost by account and the tagged ledger, and project create and edit. Figures come
 * from SABProjectFinancialService; saves go through SABAdminWorkspaceService.
 */
export default class SabProjectsWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api recordId;
    @api periodKey;

    data;
    report;
    ledger = [];
    hasMore = false;
    nextCursor;
    errorMessage;
    reportError;
    isLoading = false;
    selectedId;
    modalOpen = false;
    form = {};
    formError;
    saving = false;
    requestKey;
    loadSequence = 0;
    reportSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.selectedId = undefined;
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
            const data = await getProjects({ companyId });
            if (sequence !== this.loadSequence) {
                return;
            }
            this.data = data;
            const projects = data.projects || [];
            if (!projects.some((p) => p.projectId === this.selectedId)) {
                const first = projects.find((p) => p.status === 'Active') || projects[0];
                this.selectedId = first ? first.projectId : undefined;
            }
            await this.loadReport();
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

    get range() {
        const p = this.project;
        const today = todayIso();
        return { fromDate: (p && p.startDate) || `${today.slice(0, 4)}-01-01`, toDate: today };
    }

    async loadReport() {
        const sequence = ++this.reportSequence;
        this.report = undefined;
        this.ledger = [];
        this.reportError = undefined;
        if (!this.selectedId || !(this.data && this.data.canViewFinancials)) {
            return;
        }
        try {
            const report = await getReport({ projectId: this.selectedId, ...this.range });
            if (sequence !== this.reportSequence) {
                return;
            }
            this.report = report;
            const page = report.ledger || {};
            this.ledger = page.lines || [];
            this.hasMore = Boolean(page.hasMore);
            this.nextCursor = { afterDate: page.nextDate, afterId: page.nextId };
        } catch (error) {
            if (sequence === this.reportSequence) {
                this.reportError = reduceError(error);
            }
        }
    }

    async handleMore() {
        try {
            const page = await getLedgerPage({ projectId: this.selectedId, ...this.range, afterDate: this.nextCursor.afterDate, afterId: this.nextCursor.afterId, pageSize: PAGE });
            this.ledger = [...this.ledger, ...(page.lines || [])];
            this.hasMore = Boolean(page.hasMore);
            this.nextCursor = { afterDate: page.nextDate, afterId: page.nextId };
        } catch (error) {
            toast(this, reduceError(error), 'bad');
        }
    }

    // ---------- view ----------

    get showLoading() {
        return this.isLoading && !this.data && !this.errorMessage;
    }

    get cur() {
        return (this.data && this.data.currencyCode) || this.currencyCode || '';
    }

    get personaLabel() {
        return (this.persona && this.persona.label) || 'Your';
    }

    get canManage() {
        return Boolean(this.data && this.data.canManageProjects);
    }

    get manageDisabled() {
        return !this.canManage;
    }

    get manageTitle() {
        return this.canManage ? undefined : `${this.personaLabel} role cannot manage projects`;
    }

    get disabledBanner() {
        return this.data && !this.data.projectsEnabled;
    }

    get noFinancials() {
        return this.data && !this.data.canViewFinancials;
    }

    get cards() {
        const showMoney = Boolean(this.data && this.data.canViewFinancials);
        return ((this.data && this.data.projects) || []).map((p) => {
            const margin = (Number(p.revenue) || 0) - (Number(p.cost) || 0);
            const pct = p.revenue ? (margin / p.revenue) * 100 : null;
            return {
                ...p,
                className: p.projectId === this.selectedId ? 'cardlet click sel' : 'cardlet click',
                pressed: p.projectId === this.selectedId ? 'true' : 'false',
                chip: chipClass(p.status, p.status === 'Planned' ? 'info' : p.status === 'Cancelled' ? 'neutral' : undefined),
                showMoney,
                moneyText: `Revenue ${formatNumber(p.revenue, 0)}, cost ${formatNumber(p.cost, 0)}`,
                marginText: pct === null ? `${p.lineCount || 0} lines` : `${pct.toFixed(0)}% margin`,
                meterClass: pct !== null && pct < 0 ? 'meter bad' : pct !== null && pct < 15 ? 'meter warn' : 'meter',
                meterStyle: `width:${pct === null ? 0 : Math.max(0, Math.min(100, pct))}%`
            };
        });
    }

    get hasProjects() {
        return this.cards.length > 0;
    }

    handlePick(event) {
        if (event.type === 'keydown') {
            if (event.key !== 'Enter' && event.key !== ' ') {
                return;
            }
            event.preventDefault();
        }
        this.selectedId = event.currentTarget.dataset.id;
        this.loadReport();
    }

    get project() {
        return ((this.data && this.data.projects) || []).find((p) => p.projectId === this.selectedId);
    }

    get panelTitle() {
        return this.project ? `${this.project.code} ${this.project.name}` : '';
    }

    get panelSub() {
        const r = this.range;
        return `Posted lines tagged with this project, ${formatDate(r.fromDate)} to ${formatDate(r.toDate)}`;
    }

    get view() {
        const r = this.report;
        const p = this.project;
        const expenses = (r.accounts || []).filter((a) => a.accountType === 'Expense' && Number(a.amount) !== 0);
        const total = expenses.reduce((s, a) => s + Math.abs(Number(a.amount) || 0), 0);
        return {
            revenueText: formatNumber(r.revenue, 0),
            costText: formatNumber(r.expense, 0),
            profitText: formatNumber(r.profit, 0),
            profitClass: Number(r.profit) < 0 ? 'big neg' : 'big',
            marginText: r.marginPercent === null || r.marginPercent === undefined ? '\u2014' : `${Number(r.marginPercent).toFixed(1)}%`,
            hasCosts: expenses.length > 0,
            segments: expenses.map((a, i) => ({ key: a.accountId, style: `width:${total ? (Math.abs(a.amount) / total) * 100 : 0}%;background:${COLORS[i % COLORS.length]}`,
                title: a.accountName })),
            legend: expenses.map((a, i) => ({ key: a.accountId, swatch: `background:${COLORS[i % COLORS.length]}`, text: `${a.accountName} ${formatNumber(Math.abs(a.amount), 0)}` })),
            facts: [['Manager', p.managerName || '\u2014'], ['Customer', p.customerName || '\u2014'], ['Status', p.status], ['Start', p.startDate ? formatDate(p.startDate) : '\u2014'],
                ['Target end', p.endDate ? formatDate(p.endDate) : '\u2014']].map(([label, value]) => ({ key: label, valueKey: `${label}-v`, label, value }))
        };
    }

    get ledgerRows() {
        return this.ledger.map((l) => ({
            ...l,
            dateText: formatDateShort(l.accountingDate),
            detail: [l.accountName, l.explanation].filter(Boolean).join(', '),
            amountText: formatNumber((Number(l.debit) || 0) - (Number(l.credit) || 0))
        }));
    }

    get hasLedger() {
        return this.ledgerRows.length > 0;
    }

    get canOpenJournal() {
        return Array.isArray(this.visibleWorkspaces) && this.visibleWorkspaces.includes('journal');
    }

    handleOpenJournal(event) {
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'journal', recordId: event.currentTarget.dataset.id }, bubbles: true, composed: true }));
    }

    handleOpenConfig() {
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'config' }, bubbles: true, composed: true }));
    }

    get canOpenConfig() {
        return Array.isArray(this.visibleWorkspaces) && this.visibleWorkspaces.includes('config');
    }

    // ---------- modal ----------

    handleNew() {
        this.openModal({ recordId: null, code: '', name: '', status: 'Planned', startDate: todayIso(), endDate: '', customerAccountId: '' });
    }

    handleEdit() {
        const p = this.project;
        this.openModal({ recordId: p.projectId, code: p.code, name: p.name, status: p.status, startDate: p.startDate || '', endDate: p.endDate || '',
            customerAccountId: p.customerAccountId || '' });
    }

    openModal(form) {
        this.form = form;
        this.formError = undefined;
        this.requestKey = newKey('PROJECT', form.recordId);
        this.modalOpen = true;
    }

    get modalHeading() {
        return this.form.recordId ? 'Edit project' : 'New project';
    }

    get isEditing() {
        return Boolean(this.form.recordId);
    }

    get statusOptions() {
        return STATUSES.map((s) => ({ value: s, label: s, selected: s === this.form.status }));
    }

    get customerOptions() {
        return ((this.data && this.data.customers) || []).map((c) => ({ ...c, selected: c.value === this.form.customerAccountId }));
    }

    handleField(event) {
        this.form = { ...this.form, [event.target.dataset.field]: event.target.value };
    }

    handleClose() {
        if (!this.saving) {
            this.modalOpen = false;
        }
    }

    async handleSave() {
        const f = this.form;
        this.saving = true;
        this.formError = undefined;
        try {
            const id = await saveProject({ request: { recordId: f.recordId, companyId: this.currentCompanyId, code: f.code, name: f.name, status: f.status,
                startDate: f.startDate || null, endDate: f.endDate || null, managerId: null, customerAccountId: f.customerAccountId || null }, requestKey: this.requestKey });
            toast(this, f.recordId ? 'Project saved' : 'Project created');
            this.modalOpen = false;
            this.selectedId = id;
            await this.load();
        } catch (error) {
            this.formError = reduceError(error);
        } finally {
            this.saving = false;
        }
    }

    handleRetry() {
        this.load();
    }
}
