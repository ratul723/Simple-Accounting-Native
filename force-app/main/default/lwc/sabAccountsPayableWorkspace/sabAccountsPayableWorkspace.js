import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import {
    subscribe,
    unsubscribe,
    MessageContext,
    APPLICATION_SCOPE
} from 'lightning/messageService';

import COMPANY_CONTEXT_CHANNEL
    from '@salesforce/messageChannel/SABCompanyContext__c';

import getCompanyContext
    from '@salesforce/apex/SABCompanyContextController.getCompanyContext';
import getWorkspace
    from '@salesforce/apex/SABAccountsPayableWorkspaceController.getWorkspace';

const STORAGE_KEY = 'sabSelectedAccountingCompanyId';

const BILL_COLUMNS = [
    {
        label: 'Bill',
        fieldName: 'billId',
        type: 'button',
        typeAttributes: {
            label: { fieldName: 'billNumber' },
            name: 'openBill',
            variant: 'base'
        }
    },
    { label: 'Supplier', fieldName: 'supplierName', type: 'text' },
    { label: 'Vendor Reference', fieldName: 'vendorReference', type: 'text' },
    { label: 'Status', fieldName: 'status', type: 'text' },
    { label: 'Due Date', fieldName: 'dueDate', type: 'date' },
    { label: 'Aging', fieldName: 'agingBucket', type: 'text' },
    {
        label: 'Total',
        fieldName: 'totalAmount',
        type: 'number',
        typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 }
    },
    {
        label: 'Allocated',
        fieldName: 'allocatedAmount',
        type: 'number',
        typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 }
    },
    {
        label: 'Outstanding',
        fieldName: 'outstandingAmount',
        type: 'number',
        typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 }
    }
];

const PAYMENT_COLUMNS = [
    {
        label: 'Payment',
        fieldName: 'paymentId',
        type: 'button',
        typeAttributes: {
            label: { fieldName: 'paymentNumber' },
            name: 'openPayment',
            variant: 'base'
        }
    },
    { label: 'Supplier', fieldName: 'supplierName', type: 'text' },
    { label: 'State', fieldName: 'processingState', type: 'text' },
    { label: 'Method', fieldName: 'method', type: 'text' },
    { label: 'Reference', fieldName: 'reference', type: 'text' },
    { label: 'Effective Date', fieldName: 'effectiveDate', type: 'date' },
    {
        label: 'Amount',
        fieldName: 'amount',
        type: 'number',
        typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 }
    },
    { label: 'Bank', fieldName: 'bankAccountName', type: 'text' }
];

export default class SabAccountsPayableWorkspace extends NavigationMixin(LightningElement) {
    billColumns = BILL_COLUMNS;
    paymentColumns = PAYMENT_COLUMNS;

    companyId;
    companyName;
    functionalCurrency;
    asOfDate;
    statusFilter = 'All';
    supplierProfileId = '';
    includeSettled = false;
    workspace;
    supplierOptions = [];
    subscription;
    isLoading = false;
    errorMessage;
    searchText = '';

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        this.asOfDate = new Date().toISOString().slice(0, 10);
        this.subscribeToCompanyContext();

        const storedCompanyId =
            window.sessionStorage.getItem(STORAGE_KEY);

        if (storedCompanyId) {
            this.setCompany(storedCompanyId);
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

        this.subscription = subscribe(
            this.messageContext,
            COMPANY_CONTEXT_CHANNEL,
            (message) => this.handleCompanyContext(message),
            { scope: APPLICATION_SCOPE }
        );
    }

    async handleCompanyContext(message) {
        if (!message || message.companyCleared) {
            this.companyId = undefined;
            this.companyName = undefined;
            this.functionalCurrency = undefined;
            this.workspace = undefined;
            this.supplierOptions = [];
            return;
        }

        if (!message.companyId) {
            return;
        }

        await this.setCompany(
            message.companyId,
            message.companyName,
            message.functionalCurrency
        );
    }

    async setCompany(companyId, companyName, functionalCurrency) {
        this.companyId = companyId;
        this.companyName = companyName;
        this.functionalCurrency = functionalCurrency;
        window.sessionStorage.setItem(STORAGE_KEY, companyId);
        await this.loadWorkspace();
    }

    async loadWorkspace() {
        if (!this.companyId) {
            return;
        }

        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            if (!this.companyName || !this.functionalCurrency) {
                const context = await getCompanyContext({
                    companyId: this.companyId
                });
                this.companyName = context.companyName;
                this.functionalCurrency = context.functionalCurrency;
            }

            const result = await getWorkspace({
                companyId: this.companyId,
                asOfDate: this.asOfDate,
                statusFilter: this.statusFilter,
                supplierProfileId: this.supplierProfileId || null,
                includeSettled: this.includeSettled
            });

            this.workspace = result;
            this.supplierOptions = [
                { label: 'All suppliers', value: '' },
                ...(result.suppliers || []).map((item) => ({
                    label: item.label,
                    value: item.value
                }))
            ];
        } catch (error) {
            this.workspace = undefined;
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleDateChange(event) {
        this.asOfDate = event.target.value;
        this.loadWorkspace();
    }

    handleStatusChange(event) {
        this.statusFilter = event.detail.value;
        this.loadWorkspace();
    }

    handleSupplierChange(event) {
        this.supplierProfileId = event.detail.value;
        this.loadWorkspace();
    }

    handleSettledChange(event) {
        this.includeSettled = event.target.checked;
        this.loadWorkspace();
    }

    handleSearch(event) {
        this.searchText = (event.target.value || '').trim().toLowerCase();
    }

    handleBillAction(event) {
        if (event.detail.action.name !== 'openBill') {
            return;
        }
        this.openRecord(event.detail.row.billId, 'Supplier_Bill__c');
    }

    handlePaymentAction(event) {
        if (event.detail.action.name !== 'openPayment') {
            return;
        }
        this.openRecord(event.detail.row.paymentId, 'Accounting_Payment__c');
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

    newSupplierBill() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Supplier_Bill__c',
                actionName: 'new'
            }
        });
    }

    newSupplierPayment() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Accounting_Payment__c',
                actionName: 'new'
            }
        });
    }

    refresh() {
        this.loadWorkspace();
    }

    reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((entry) => entry.message).join(', ');
        }
        return error?.body?.message || error?.message || 'Unexpected Accounts Payable error.';
    }

    get hasCompany() {
        return Boolean(this.companyId);
    }

    get hasWorkspace() {
        return Boolean(this.workspace);
    }

    get hasBills() {
        return Boolean(this.filteredBills.length);
    }

    get hasPayments() {
        return Boolean(this.workspace?.payments?.length);
    }

    get filteredBills() {
        const rows = this.workspace?.bills || [];
        if (!this.searchText) {
            return rows;
        }
        return rows.filter((row) => {
            const haystack = [
                row.billNumber,
                row.supplierName,
                row.vendorReference,
                row.status
            ].filter(Boolean).join(' ').toLowerCase();
            return haystack.includes(this.searchText);
        });
    }

    get statusOptions() {
        return [
            { label: 'All', value: 'All' },
            { label: 'Open', value: 'Open' },
            { label: 'Pending', value: 'Pending' },
            { label: 'Posted', value: 'Posted' },
            { label: 'Cancelled', value: 'Cancelled' }
        ];
    }
}
