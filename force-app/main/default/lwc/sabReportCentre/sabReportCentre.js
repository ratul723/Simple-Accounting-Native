import { LightningElement, wire } from 'lwc';
import { subscribe, unsubscribe, MessageContext, APPLICATION_SCOPE } from 'lightning/messageService';
import COMPANY_CONTEXT_CHANNEL from '@salesforce/messageChannel/SABCompanyContext__c';

import getDashboard from '@salesforce/apex/SABManagementDashboardService.getDashboard';
import getCashFlow from '@salesforce/apex/SABCashFlowService.getCashFlow';

const STORAGE_KEY = 'sabSelectedAccountingCompanyId';
const MONEY = { type: 'number', typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 2 } };
const TREND_COLUMNS = [
    { label: 'Month', fieldName: 'label' },
    { label: 'Revenue', fieldName: 'revenue', ...MONEY },
    { label: 'Expenses', fieldName: 'expense', ...MONEY },
    { label: 'Net', fieldName: 'net', ...MONEY }
];
const CASH_COLUMNS = [
    { label: 'Account', fieldName: 'accountCode', initialWidth: 120 },
    { label: 'Name', fieldName: 'accountName' },
    { label: 'Amount', fieldName: 'amount', ...MONEY }
];
const RUN_COLUMNS = [
    { label: 'Report', fieldName: 'reportType' },
    { label: 'Generated', fieldName: 'generatedAt', type: 'date', typeAttributes: { year: 'numeric', month: 'short', day: '2-digit',
        hour: '2-digit', minute: '2-digit' } },
    { label: 'By', fieldName: 'generatedByName' }
];

function isoDate(d) {
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export default class SabReportCentre extends LightningElement {
    trendColumns = TREND_COLUMNS;
    cashColumns = CASH_COLUMNS;
    runColumns = RUN_COLUMNS;

    companyId;
    subscription;
    isLoading = false;
    errorMessage;
    activeTab = 'dashboard';

    asOfDate = isoDate(new Date());
    dashboard;
    fromDate;
    toDate;
    cashFlow;

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        const today = new Date();
        this.fromDate = isoDate(new Date(today.getFullYear(), today.getMonth(), 1));
        this.toDate = isoDate(today);
        this.subscribeToCompanyContext();
        const stored = window.sessionStorage.getItem(STORAGE_KEY);
        if (stored) {
            this.companyId = stored;
            this.loadDashboard();
        }
    }

    disconnectedCallback() {
        if (this.subscription) {
            unsubscribe(this.subscription);
            this.subscription = undefined;
        }
    }

    subscribeToCompanyContext() {
        if (this.subscription || !this.messageContext) {
            return;
        }
        this.subscription = subscribe(this.messageContext, COMPANY_CONTEXT_CHANNEL,
            (message) => this.handleCompanyContext(message), { scope: APPLICATION_SCOPE });
    }

    handleCompanyContext(message) {
        if (!message || message.companyCleared) {
            this.companyId = undefined;
            this.dashboard = undefined;
            this.cashFlow = undefined;
            return;
        }
        if (message.companyId && message.companyId !== this.companyId) {
            this.companyId = message.companyId;
            this.cashFlow = undefined;
            this.loadDashboard();
        }
    }

    // ------------------------------------------------------------- getters

    get hasCompany() {
        return Boolean(this.companyId);
    }

    get isDashboardTab() {
        return this.activeTab === 'dashboard';
    }

    get isCashFlowTab() {
        return this.activeTab === 'cashflow';
    }

    get isProfitLossTab() {
        return this.activeTab === 'profitloss';
    }

    get isBalanceSheetTab() {
        return this.activeTab === 'balancesheet';
    }

    get isTrialBalanceTab() {
        return this.activeTab === 'trialbalance';
    }

    get isGeneralLedgerTab() {
        return this.activeTab === 'generalledger';
    }

    get hasBudget() {
        return Boolean(this.dashboard)
            && (this.dashboard.budgetRevenueYearToDate !== null && this.dashboard.budgetRevenueYearToDate !== undefined
                || this.dashboard.budgetExpenseYearToDate !== null && this.dashboard.budgetExpenseYearToDate !== undefined);
    }

    get trendRows() {
        if (!this.dashboard) {
            return [];
        }
        const peak = Math.max(1, ...this.dashboard.trend.map((p) => Math.max(Math.abs(p.revenue), Math.abs(p.expense))));
        return this.dashboard.trend.map((p) => ({ ...p, key: `${p.year}-${p.month}`,
            revenueStyle: `width:${Math.round((Math.abs(p.revenue) / peak) * 100)}%`,
            expenseStyle: `width:${Math.round((Math.abs(p.expense) / peak) * 100)}%` }));
    }

    get cashSections() {
        return this.cashFlow ? this.cashFlow.sections.map((s) => ({ ...s, hasLines: s.lines.length > 0 })) : [];
    }

    get reconciliationLabel() {
        if (!this.cashFlow) {
            return '';
        }
        return this.cashFlow.reconciled ? 'Reconciled to the cash ledger'
            : 'Does not reconcile to the cash ledger; check cash account mapping';
    }

    get reconciliationClass() {
        return this.cashFlow && this.cashFlow.reconciled ? 'badge ok' : 'badge warn';
    }

    get cashFlowDisabled() {
        return this.isLoading || !this.fromDate || !this.toDate || this.fromDate > this.toDate;
    }

    // ------------------------------------------------------------- handlers

    handleTabActive(event) {
        this.activeTab = event.target.value;
    }

    handleAsOfChange(event) {
        this.asOfDate = event.detail.value;
    }

    handleRangeChange(event) {
        this[event.target.dataset.field] = event.detail.value;
    }

    handleRefreshDashboard() {
        this.loadDashboard();
    }

    async loadDashboard() {
        if (!this.companyId) {
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            this.dashboard = await getDashboard({ companyId: this.companyId, asOfDate: this.asOfDate });
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async handleRunCashFlow() {
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            this.cashFlow = await getCashFlow({ companyId: this.companyId, fromDate: this.fromDate, toDate: this.toDate });
        } catch (error) {
            this.cashFlow = undefined;
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    reduceError(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        if (error && error.message) {
            return error.message;
        }
        return 'An unexpected report centre error occurred.';
    }
}
