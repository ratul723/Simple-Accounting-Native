import { LightningElement, api } from 'lwc';
import getHome from '@salesforce/apex/SABFinanceHomeController.getHome';
import {
    formatNumber,
    formatDate,
    formatDateShort,
    formatDateTime,
    formatMonth,
    monthName,
    chipClass,
    greeting,
    guardTitle,
    plural
} from 'c/sabFormat';

const UNAVAILABLE_TEXT = 'Not available for your access';

function reduceError(error) {
    if (!error) {
        return 'Finance home could not be loaded.';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return (error.body && error.body.message) || error.message || 'Finance home could not be loaded.';
}

/**
 * Finance home: figure strip, cash trend, income and expenses, approvals queue, needs attention,
 * persona card and recent postings for the selected company; setup summary while in setup.
 */
export default class SabFinanceHome extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api recordId;
    @api periodKey;

    data;
    errorMessage;
    isLoading = false;
    loadSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.load();
        }
    }

    @api
    refresh() {
        return this.load();
    }

    async load() {
        const companyId = this.currentCompanyId;
        const sequence = ++this.loadSequence;
        if (!companyId) {
            this.data = undefined;
            this.isLoading = false;
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const result = await getHome({ companyId });
            if (sequence === this.loadSequence) {
                this.data = result;
            }
        } catch (error) {
            if (sequence === this.loadSequence) {
                this.data = undefined;
                this.errorMessage = reduceError(error);
            }
        } finally {
            if (sequence === this.loadSequence) {
                this.isLoading = false;
            }
        }
    }

    // ---------- state ----------

    get hasCompany() {
        return Boolean(this.currentCompanyId);
    }

    get showNoCompany() {
        return !this.currentCompanyId;
    }

    get isReady() {
        return Boolean(this.data);
    }

    get isActive() {
        return Boolean(this.data && this.data.companyActive);
    }

    get isSetup() {
        return Boolean(this.data && !this.data.companyActive);
    }

    get showLoadingPanel() {
        return this.isLoading && !this.data && !this.errorMessage;
    }

    get currency() {
        return (this.data && this.data.currencyCode) || this.currencyCode || '';
    }

    get displayCompany() {
        return (this.data && this.data.companyName) || this.companyName || '';
    }

    get personaLabel() {
        return (this.persona && this.persona.label) || 'Your';
    }

    canGo(workspace) {
        return Array.isArray(this.visibleWorkspaces) && this.visibleWorkspaces.includes(workspace);
    }

    // ---------- header ----------

    get heading() {
        const name = this.persona && this.persona.firstName;
        const hello = greeting(new Date().getHours());
        return name ? `${hello}, ${name}` : hello;
    }

    get description() {
        if (this.data && this.data.hasPeriod) {
            return `Here is where ${this.displayCompany} stands for ${formatMonth(this.data.periodStart)}, period ${this.data.periodKey}.`;
        }
        return `Here is where ${this.displayCompany} stands today.`;
    }

    get journalAllowed() {
        return Boolean(this.caps && this.caps.canCreateJournal) && this.canGo('journal');
    }

    get invoiceAllowed() {
        return Boolean(this.caps && this.caps.canCreateInvoice) && this.canGo('sales');
    }

    get journalDisabled() {
        return !this.journalAllowed;
    }

    get invoiceDisabled() {
        return !this.invoiceAllowed;
    }

    get journalTitle() {
        return guardTitle(this.journalAllowed, this.personaLabel, 'create journals');
    }

    get invoiceTitle() {
        return guardTitle(this.invoiceAllowed, this.personaLabel, 'create invoices');
    }

    get canContinueSetup() {
        return this.canGo('setup');
    }

    // ---------- figures ----------

    get figures() {
        const d = this.data;
        if (!d) {
            return [];
        }
        const cur = this.currency;
        const figure = (key, label, f, sub) => {
            if (!f || !f.available) {
                return { key, label, value: '\u2014', unit: '', sub: { text: UNAVAILABLE_TEXT } };
            }
            return { key, label, value: formatNumber(f.amount, 0), unit: cur, valueClass: f.amount < 0 ? 'v neg' : 'v', sub };
        };
        const cash = d.cash || {};
        const ar = d.receivables || {};
        const ap = d.payables || {};
        const pr = d.profit || {};
        const list = [
            figure('cash', 'Cash at bank', cash, { text: `${plural(cash.count, 'account')}, book balance` }),
            figure('ar', 'Receivables outstanding', ar, ar.count > 0
                ? { bold: `${ar.count} overdue`, boldClass: 'down', text: ` totalling ${formatNumber(ar.secondaryAmount, 0)}` }
                : { text: 'Nothing overdue' }),
            figure('ap', 'Payables due in 14 days', ap, ap.count > 0
                ? { text: `${plural(ap.count, 'bill')}, next due ${formatDateShort(ap.nextDate)}` }
                : { text: 'Nothing due in the next 14 days' }),
            figure('np', 'Net profit, year to date', pr, pr.hasComparison
                ? { bold: `${pr.comparison >= 0 ? '+' : ''}${formatNumber(pr.comparison, 0)}`, boldClass: pr.comparison >= 0 ? 'up' : 'down',
                    text: ' against budget' }
                : { text: 'No approved budget to compare' })
        ];
        return list.map((f) => ({ ...f, valueClass: f.valueClass || 'v', hasUnit: Boolean(f.unit) }));
    }

    // ---------- charts ----------

    get hasCashTrend() {
        return Boolean(this.data && this.data.cash && this.data.cash.available && (this.data.cashTrend || []).length > 1);
    }

    get cashSeries() {
        return [{ values: (this.data.cashTrend || []).map((p) => p.balance), color: 'var(--chart-1)' }];
    }

    get cashLabels() {
        let previousMonth;
        return (this.data.cashTrend || []).map((p) => {
            const month = monthName(p.pointDate);
            const text = month !== previousMonth ? formatDateShort(p.pointDate) : String(Number(String(p.pointDate).slice(8, 10)));
            previousMonth = month;
            return text;
        });
    }

    get cashSub() {
        return `Bank accounts in ${this.currency}, weekly book balance`;
    }

    get hasMonthly() {
        return Boolean(this.data && this.data.profit && this.data.profit.available && (this.data.monthly || []).length);
    }

    get monthlyGroups() {
        return (this.data.monthly || []).map((m) => ({ label: monthName(m.monthStart), values: [m.income, m.expense] }));
    }

    get monthlySeries() {
        return [
            { name: 'Income', color: 'var(--chart-1)' },
            { name: 'Cost of sales and expenses', color: 'var(--chart-2)' }
        ];
    }

    // ---------- lists ----------

    get attentionItems() {
        return ((this.data && this.data.attention) || []).map((a) => {
            const clickable = a.workspace === 'home' || this.canGo(a.workspace);
            return {
                ...a,
                iconClass: `ic t-${a.tone}`,
                rowClass: clickable ? 'li click' : 'li',
                role: clickable ? 'button' : undefined,
                tabIndex: clickable ? '0' : undefined
            };
        });
    }

    get hasAttention() {
        return this.attentionItems.length > 0;
    }

    get roleTitle() {
        return `For your role: ${this.personaLabel}`;
    }

    get role() {
        const card = (this.data && this.data.roleCard) || {};
        const items = (card.items || []).map((i) => ({ ...i, canOpen: this.canGo('journal') }));
        return {
            ...card,
            value: card.isMoney ? formatNumber(card.valueAmount) : card.valueText,
            unit: card.isMoney ? this.currency : '',
            hasValue: Boolean(card.isMoney || card.valueText),
            meterStyle: `width:${Math.max(0, Math.min(100, Number(card.meterPercent) || 0))}%`,
            showAction: Boolean(card.actionLabel && this.canGo(card.actionWorkspace)),
            items,
            hasItems: items.length > 0
        };
    }

    get recentRows() {
        const canOpen = this.canGo('journal');
        return ((this.data && this.data.recent) || []).map((r) => ({
            ...r,
            chip: chipClass(r.status),
            meta: [formatDate(r.accountingDate), r.postedBy].filter(Boolean).join(', '),
            rowClass: canOpen ? 'li click' : 'li',
            role: canOpen ? 'button' : undefined,
            tabIndex: canOpen ? '0' : undefined
        }));
    }

    get hasRecent() {
        return this.recentRows.length > 0;
    }

    get showRecentPanel() {
        return Boolean(this.data && this.data.recentAvailable);
    }

    get showApprovals() {
        return Boolean(this.data && this.data.approvalsAvailable);
    }

    get approvalRows() {
        return ((this.data && this.data.approvals) || []).map((a) => ({
            ...a,
            requestedAtText: formatDateTime(a.requestedAt),
            needsText: a.needs || 'Next approver'
        }));
    }

    get hasApprovals() {
        return this.approvalRows.length > 0;
    }

    get setupCards() {
        const s = (this.data && this.data.setup) || {};
        return [
            { key: 'status', big: this.data ? this.data.setupStatus : '', text: 'setup status' },
            { key: 'accounts', big: plural(s.accountCount, 'GL account'), text: 'in the chart of accounts' },
            { key: 'periods', big: plural(s.periodCount, 'period'), text: 'created for this company' },
            { key: 'banks', big: plural(s.bankAccountCount, 'bank account'), text: 'linked to the ledger' }
        ].map((c) => ({ ...c, className: this.canContinueSetup ? 'cardlet click' : 'cardlet' }));
    }

    // ---------- events ----------

    navigate(workspace, recordId) {
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace, recordId }, bubbles: true, composed: true }));
    }

    handleNewJournal() {
        this.navigate('journal');
    }

    handleNewInvoice() {
        this.navigate('sales');
    }

    handleContinueSetup() {
        this.navigate('setup');
    }

    handleRoleAction() {
        this.navigate(this.role.actionWorkspace);
    }

    handleOpenDraft(event) {
        this.navigate('journal', event.currentTarget.dataset.id);
    }

    activate(event, callback) {
        if (event.type === 'click' || event.key === 'Enter' || event.key === ' ') {
            if (event.type === 'keydown') {
                event.preventDefault();
            }
            callback();
        }
    }

    handleAttention(event) {
        const workspace = event.currentTarget.dataset.workspace;
        this.activate(event, () => {
            if (workspace === 'home') {
                const panel = this.template.querySelector('.approvals-panel');
                if (panel && typeof panel.scrollIntoView === 'function') {
                    panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
                }
            } else if (this.canGo(workspace)) {
                this.navigate(workspace);
            }
        });
    }

    handleRecent(event) {
        const id = event.currentTarget.dataset.id;
        this.activate(event, () => {
            if (this.canGo('journal')) {
                this.navigate('journal', id);
            }
        });
    }

    handleSetupCard() {
        if (this.canContinueSetup) {
            this.navigate('setup');
        }
    }

    handleRetry() {
        this.load();
    }
}
