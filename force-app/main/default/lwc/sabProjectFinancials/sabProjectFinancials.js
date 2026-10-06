import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getReport from '@salesforce/apex/SABProjectFinancialService.getReport';
import getLedgerPage from '@salesforce/apex/SABProjectFinancialService.getLedgerPage';

const NUMBER = { minimumFractionDigits: 2, maximumFractionDigits: 4 };
const ACCOUNT_COLUMNS = [
    { label: 'Account code', fieldName: 'accountCode' },
    { label: 'Account', fieldName: 'accountName' },
    { label: 'Type', fieldName: 'accountType' },
    { label: 'Debits', fieldName: 'debit', type: 'number', typeAttributes: NUMBER },
    { label: 'Credits', fieldName: 'credit', type: 'number', typeAttributes: NUMBER },
    { label: 'Net amount', fieldName: 'amount', type: 'number', typeAttributes: NUMBER },
    { label: 'Lines', fieldName: 'lineCount', type: 'number' }
];
const LEDGER_COLUMNS = [
    { label: 'Accounting date', fieldName: 'accountingDate', type: 'date-local' },
    { label: 'Journal', type: 'button', typeAttributes: { label: { fieldName: 'journalName' }, name: 'openJournal', variant: 'base' } },
    { label: 'Line', fieldName: 'lineNumber', type: 'number' },
    { label: 'Account', fieldName: 'accountName' },
    { label: 'Type', fieldName: 'accountType' },
    { label: 'Debits', fieldName: 'debit', type: 'number', typeAttributes: NUMBER },
    { label: 'Credits', fieldName: 'credit', type: 'number', typeAttributes: NUMBER },
    { label: 'Entry type', fieldName: 'entryType' },
    { label: 'Status', fieldName: 'status' },
    { label: 'Explanation', fieldName: 'explanation', wrapText: true }
];

export default class SabProjectFinancials extends NavigationMixin(LightningElement) {
    _recordId;
    _connected = false;
    _requestId = 0;
    fromDate;
    toDate;
    report;
    lines = [];
    page;
    error;
    loading = false;
    accountColumns = ACCOUNT_COLUMNS;
    ledgerColumns = LEDGER_COLUMNS;

    @api get recordId() { return this._recordId; }
    set recordId(value) {
        if (value === this._recordId) return;
        this._recordId = value;
        this.reset();
        if (this._connected && value) this.refresh();
    }
    connectedCallback() {
        const today = new Date();
        const month = String(today.getMonth() + 1).padStart(2, '0');
        const day = String(today.getDate()).padStart(2, '0');
        this.fromDate = `${today.getFullYear()}-01-01`;
        this.toDate = `${today.getFullYear()}-${month}-${day}`;
        this._connected = true;
        if (this.recordId) this.refresh();
    }
    disconnectedCallback() { this._connected = false; this._requestId += 1; }
    reset() {
        this._requestId += 1;
        this.report = undefined; this.lines = []; this.page = undefined;
        this.error = undefined; this.loading = false;
    }
    handleDateChange(event) {
        if (event.target.name === 'fromDate') this.fromDate = event.target.value;
        else this.toDate = event.target.value;
        this.reset();
    }
    get disabled() { return this.loading || !this.recordId; }
    get hasMore() { return Boolean(this.page?.hasMore); }
    get hasLines() { return this.lines.length > 0; }
    get hasMargin() { return this.report?.marginPercent !== null && this.report?.marginPercent !== undefined; }
    get displayedCount() { return this.lines.length; }
    async refresh() {
        this.reset();
        if (!this.recordId) { this.error = 'Open a Project record to view its financials.'; return; }
        if (!this.fromDate || !this.toDate || this.fromDate > this.toDate) {
            this.error = 'Enter a valid start and end date.'; return;
        }
        const requestId = this._requestId;
        this.loading = true;
        try {
            const result = await getReport({ projectId: this.recordId, fromDate: this.fromDate, toDate: this.toDate });
            if (requestId !== this._requestId) return;
            this.report = result; this.page = result.ledger; this.lines = result.ledger.lines;
        } catch (error) {
            if (requestId === this._requestId) this.error = error.body?.message || error.message || 'Unable to load project financials.';
        } finally {
            if (requestId === this._requestId) this.loading = false;
        }
    }
    async loadMore() {
        if (this.loading || !this.hasMore) return;
        const requestId = this._requestId;
        this.loading = true;
        try {
            const page = await getLedgerPage({ projectId: this.recordId, fromDate: this.fromDate, toDate: this.toDate,
                afterDate: this.page.nextDate, afterId: this.page.nextId, pageSize: 50 });
            if (requestId !== this._requestId) return;
            const seen = new Set(this.lines.map(row => row.lineId));
            this.lines = [...this.lines, ...page.lines.filter(row => !seen.has(row.lineId))];
            this.page = page;
        } catch (error) {
            if (requestId === this._requestId) {
                this.reset();
                this.error = error.body?.message || error.message || 'Unable to load ledger details. Refresh the report.';
            }
        } finally {
            if (requestId === this._requestId) this.loading = false;
        }
    }
    handleRowAction(event) {
        if (event.detail.action.name === 'openJournal') {
            this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: {
                recordId: event.detail.row.journalId, objectApiName: 'Journal_Entry__c', actionName: 'view'
            } });
        }
    }
}
