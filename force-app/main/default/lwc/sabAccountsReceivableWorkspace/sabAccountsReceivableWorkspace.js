import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';
import {
    APPLICATION_SCOPE,
    MessageContext,
    subscribe,
    unsubscribe
} from 'lightning/messageService';

import COMPANY_CONTEXT_CHANNEL from '@salesforce/messageChannel/SABCompanyContext__c';
import getCustomers from '@salesforce/apex/SABARAgingController.getCustomers';
import runAging from '@salesforce/apex/SABARAgingController.runAging';

const STORAGE_KEY = 'sabSelectedAccountingCompanyId';

const INVOICE_COLUMNS = [
    {
        label: 'Invoice',
        fieldName: 'invoiceId',
        type: 'button',
        typeAttributes: {
            label: { fieldName: 'legalNumber' },
            name: 'openInvoice',
            variant: 'base'
        }
    },
    { label: 'Customer', fieldName: 'customerName', type: 'text' },
    { label: 'Due Date', fieldName: 'dueDate', type: 'date' },
    { label: 'Aging', fieldName: 'agingBucket', type: 'text' },
    { label: 'Days Past Due', fieldName: 'daysPastDue', type: 'number' },
    {
        label: 'Original',
        fieldName: 'originalDocumentAmount',
        type: 'number',
        typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 }
    },
    {
        label: 'Allocated',
        fieldName: 'allocatedDocumentAmount',
        type: 'number',
        typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 }
    },
    {
        label: 'Credits',
        fieldName: 'creditedDocumentAmount',
        type: 'number',
        typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 }
    },
    {
        label: 'Outstanding',
        fieldName: 'outstandingDocumentAmount',
        type: 'number',
        typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 }
    },
    { label: 'Currency', fieldName: 'transactionCurrency', type: 'text' }
];

const CUSTOMER_COLUMNS = [
    { label: 'Customer', fieldName: 'customerName', type: 'text' },
    { label: 'Open Invoices', fieldName: 'openInvoiceCount', type: 'number' },
    {
        label: 'Current',
        fieldName: 'currentAmount',
        type: 'number',
        typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 }
    },
    {
        label: '1–30',
        fieldName: 'days1To30Amount',
        type: 'number',
        typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 }
    },
    {
        label: '31–60',
        fieldName: 'days31To60Amount',
        type: 'number',
        typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 }
    },
    {
        label: '61–90',
        fieldName: 'days61To90Amount',
        type: 'number',
        typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 }
    },
    {
        label: '91+',
        fieldName: 'days91PlusAmount',
        type: 'number',
        typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 }
    },
    {
        label: 'Total Outstanding',
        fieldName: 'totalOutstanding',
        type: 'number',
        typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 }
    }
];

export default class SabAccountsReceivableWorkspace extends NavigationMixin(LightningElement) {
    invoiceColumns = INVOICE_COLUMNS;
    customerColumns = CUSTOMER_COLUMNS;

    companyId;
    asOfDate;
    partyProfileId = '';
    includeSettled = false;
    customerOptions = [];
    workspace;
    searchText = '';
    isLoading = false;
    errorMessage;
    subscription;
    requestSequence = 0;

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        this.asOfDate = new Date().toISOString().slice(0, 10);

        const storedCompanyId = window.sessionStorage.getItem(STORAGE_KEY);
        if (storedCompanyId) {
            this.companyId = storedCompanyId;
            this.loadCustomers();
            this.loadWorkspace();
        }
    }

    renderedCallback() {
        if (!this.subscription && this.messageContext) {
            this.subscription = subscribe(
                this.messageContext,
                COMPANY_CONTEXT_CHANNEL,
                (message) => this.handleCompanyContext(message),
                { scope: APPLICATION_SCOPE }
            );
        }
    }

    disconnectedCallback() {
        if (this.subscription) {
            unsubscribe(this.subscription);
            this.subscription = undefined;
        }
    }

    async handleCompanyContext(message) {
        if (!message) {
            return;
        }

        if (message.companyCleared) {
            this.requestSequence += 1;
            this.companyId = undefined;
            this.customerOptions = [];
            this.workspace = undefined;
            this.partyProfileId = '';
            this.errorMessage = undefined;
            return;
        }

        if (!message.companyId || message.companyId === this.companyId) {
            return;
        }

        this.requestSequence += 1;
        this.companyId = message.companyId;
        this.partyProfileId = '';
        this.customerOptions = [];
        this.workspace = undefined;
        this.errorMessage = undefined;
        window.sessionStorage.setItem(STORAGE_KEY, this.companyId);

        await Promise.all([
            this.loadCustomers(),
            this.loadWorkspace()
        ]);
    }

    async loadCustomers() {
        if (!this.companyId) {
            return;
        }

        const requestedCompanyId = this.companyId;
        try {
            const customers = await getCustomers({ companyId: requestedCompanyId });

            if (requestedCompanyId !== this.companyId) {
                return;
            }

            this.customerOptions = [
                { label: 'All customers', value: '' },
                ...(customers || []).map((item) => ({
                    label: item.label,
                    value: item.value
                }))
            ];
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        }
    }

    async loadWorkspace() {
        if (!this.companyId || !this.asOfDate) {
            return;
        }

        const requestedCompanyId = this.companyId;
        const requestId = ++this.requestSequence;

        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            const result = await runAging({
                companyId: requestedCompanyId,
                asOfDate: this.asOfDate,
                partyProfileId: this.partyProfileId || null,
                includeSettled: this.includeSettled
            });

            if (
                requestId !== this.requestSequence
                || requestedCompanyId !== this.companyId
            ) {
                return;
            }

            this.workspace = result;
        } catch (error) {
            this.workspace = undefined;
            this.errorMessage = this.reduceError(error);
        } finally {
            if (requestId === this.requestSequence) {
                this.isLoading = false;
            }
        }
    }

    handleDateChange(event) {
        this.asOfDate = event.target.value;
        this.loadWorkspace();
    }

    handleCustomerChange(event) {
        this.partyProfileId = event.detail.value || '';
        this.loadWorkspace();
    }

    handleSettledChange(event) {
        this.includeSettled = event.target.checked;
        this.loadWorkspace();
    }

    handleSearch(event) {
        this.searchText = (event.target.value || '').trim().toLowerCase();
    }

    handleInvoiceAction(event) {
        if (event.detail.action.name !== 'openInvoice') {
            return;
        }

        this.openRecord(event.detail.row.invoiceId, 'Invoice__c');
    }

    openRecord(recordId, objectApiName) {
        if (!recordId) {
            return;
        }

        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId,
                objectApiName,
                actionName: 'view'
            }
        });
    }

    newInvoice() {
        const defaultValues = encodeDefaultFieldValues({
            Company__c: this.companyId || '',
            Document_Type__c: 'Invoice'
        });

        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Invoice__c',
                actionName: 'new'
            },
            state: {
                defaultFieldValues: defaultValues
            }
        });
    }

    newReceipt() {
        const defaultValues = encodeDefaultFieldValues({
            Company__c: this.companyId || '',
            Direction__c: 'Receipt'
        });

        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Accounting_Payment__c',
                actionName: 'new'
            },
            state: {
                defaultFieldValues: defaultValues
            }
        });
    }

    refresh() {
        Promise.all([
            this.loadCustomers(),
            this.loadWorkspace()
        ]);
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((entry) => entry.message).join(', ');
        }
        return error?.body?.message || error?.message || 'Unexpected Accounts Receivable error.';
    }

    get hasCompany() {
        return Boolean(this.companyId);
    }

    get hasWorkspace() {
        return Boolean(this.workspace);
    }

    get functionalCurrency() {
        return this.workspace?.functionalCurrency || '';
    }

    get filteredInvoices() {
        const rows = this.workspace?.rows || [];
        if (!this.searchText) {
            return rows;
        }

        return rows.filter((row) => {
            const haystack = [
                row.legalNumber,
                row.customerName,
                row.agingBucket,
                row.transactionCurrency
            ].filter(Boolean).join(' ').toLowerCase();
            return haystack.includes(this.searchText);
        });
    }

    get hasInvoices() {
        return this.filteredInvoices.length > 0;
    }

    get hasCustomers() {
        return Boolean(this.workspace?.customers?.length);
    }

    get overdueAmount() {
        return this.workspace
            ? (this.workspace.days1To30Amount || 0)
                + (this.workspace.days31To60Amount || 0)
                + (this.workspace.days61To90Amount || 0)
                + (this.workspace.days91PlusAmount || 0)
            : 0;
    }

    get reportCurrency() {
        return this.workspace?.functionalCurrency || '';
    }

    get over31Amount() {
        if (!this.workspace) {
            return 0;
        }
        return (this.workspace.days31To60Amount || 0)
            + (this.workspace.days61To90Amount || 0)
            + (this.workspace.days91PlusAmount || 0);
    }

    get invoiceDetailCountLabel() {
        const count = this.filteredInvoices.length;
        return `${count} invoice(s) shown`;
    }

    get customerDetailCountLabel() {
        const count = this.workspace?.customers?.length || 0;
        return `${count} customer(s) with outstanding balances`;
    }
}
