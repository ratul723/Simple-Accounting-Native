import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import {
    subscribe,
    unsubscribe,
    MessageContext,
    APPLICATION_SCOPE
} from 'lightning/messageService';

import COMPANY_CONTEXT_CHANNEL
    from '@salesforce/messageChannel/SABCompanyContext__c';

import getAccessibleCompanies
    from '@salesforce/apex/SABFixedAssetWorkspaceController.getAccessibleCompanies';
import getDashboard
    from '@salesforce/apex/SABFixedAssetWorkspaceController.getDashboard';
import getAssetDetail
    from '@salesforce/apex/SABFixedAssetWorkspaceController.getAssetDetail';

const STORAGE_KEY = 'sabSelectedAccountingCompanyId';

const ASSET_COLUMNS = [
    {
        label: 'Asset',
        fieldName: 'name',
        type: 'text'
    },
    {
        label: 'Asset Tag',
        fieldName: 'assetTag',
        type: 'text'
    },
    {
        label: 'Category',
        fieldName: 'categoryName',
        type: 'text'
    },
    {
        label: 'Status',
        fieldName: 'status',
        type: 'text'
    },
    {
        label: 'Cost',
        fieldName: 'cost',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'Posted Depreciation',
        fieldName: 'postedDepreciation',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'NBV',
        fieldName: 'netBookValue',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'Reconciliation',
        fieldName: 'reconciliationStatus',
        type: 'text'
    }
];

const SCHEDULE_COLUMNS = [
    {
        label: 'Scheduled Date',
        fieldName: 'scheduledDate',
        type: 'date'
    },
    {
        label: 'Period',
        fieldName: 'periodName',
        type: 'text'
    },
    {
        label: 'Book',
        fieldName: 'bookKey',
        type: 'text'
    },
    {
        label: 'Planned Depreciation',
        fieldName: 'plannedDepreciation',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'Version',
        fieldName: 'calculationVersion',
        type: 'number'
    },
    {
        label: 'Status',
        fieldName: 'status',
        type: 'text'
    }
];

const MOVEMENT_COLUMNS = [
    {
        label: 'Accounting Date',
        fieldName: 'accountingDate',
        type: 'date'
    },
    {
        label: 'Movement',
        fieldName: 'movementType',
        type: 'text'
    },
    {
        label: 'Amount',
        fieldName: 'amount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'Proceeds',
        fieldName: 'proceeds',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'Book',
        fieldName: 'bookKey',
        type: 'text'
    },
    {
        label: 'Reason',
        fieldName: 'reason',
        type: 'text'
    },
    {
        label: 'Movement Key',
        fieldName: 'movementKey',
        type: 'text'
    }
];

export default class SabFixedAssetWorkspace extends NavigationMixin(LightningElement) {
    assetColumns = ASSET_COLUMNS;
    scheduleColumns = SCHEDULE_COLUMNS;
    movementColumns = MOVEMENT_COLUMNS;

    companyId;
    companyName;
    functionalCurrency;

    dashboard;
    selectedAsset;
    subscription;

    companyOptions = [];
    searchText = '';
    statusFilter = 'All';
    isLoading = false;
    errorMessage;

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        this.subscribeToCompanyContext();

        const storedCompanyId =
            window.sessionStorage.getItem(STORAGE_KEY);

        if (storedCompanyId) {
            this.companyId = storedCompanyId;
            this.loadDashboard();
        } else {
            this.loadCompanies();
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
            this.dashboard = undefined;
            this.selectedAsset = undefined;
            await this.loadCompanies();
            return;
        }

        if (!message.companyId) {
            return;
        }

        this.companyId = message.companyId;
        this.companyName = message.companyName;
        this.functionalCurrency = message.functionalCurrency;

        window.sessionStorage.setItem(
            STORAGE_KEY,
            this.companyId
        );

        await this.loadDashboard();
    }

    async loadCompanies() {
        try {
            const result = await getAccessibleCompanies();

            this.companyOptions = (result || []).map(
                (company) => ({
                    label: company.name,
                    value: company.companyId
                })
            );
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        }
    }

    async handleCompanyChange(event) {
        this.companyId = event.detail.value;

        const selected =
            (this.companyOptions || []).find(
                (option) =>
                    option.value === this.companyId
            );

        if (selected) {
            this.companyName = selected.label;
        }

        window.sessionStorage.setItem(
            STORAGE_KEY,
            this.companyId
        );

        await this.loadDashboard();
    }

    async loadDashboard() {
        if (!this.companyId) {
            return;
        }

        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            const result = await getDashboard({
                companyId: this.companyId
            });

            this.dashboard = result;
            this.companyName = result.companyName;
            this.functionalCurrency = result.functionalCurrency;

            if (
                this.selectedAsset
                && !result.assets.some(
                    (row) =>
                        row.assetId === this.selectedAsset.assetId
                )
            ) {
                this.selectedAsset = undefined;
            }
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async handleAssetSelection(event) {
        const rows = event.detail.selectedRows || [];

        if (!rows.length) {
            this.selectedAsset = undefined;
            return;
        }

        await this.loadAssetDetail(rows[0].assetId);
    }

    async loadAssetDetail(assetId) {
        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            this.selectedAsset =
                await getAssetDetail({
                    assetId
                });
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async handleRefresh() {
        this.selectedAsset = undefined;
        await this.loadDashboard();

        if (!this.companyId) {
            await this.loadCompanies();
        }
    }

    handleSearch(event) {
        this.searchText =
            (event.target.value || '').trim().toLowerCase();
    }

    handleStatusFilter(event) {
        this.statusFilter = event.detail.value;
    }

    openAssetRecord() {
        if (!this.selectedAsset) {
            return;
        }

        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this.selectedAsset.assetId,
                objectApiName: 'Fixed_Asset__c',
                actionName: 'view'
            }
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }

    reduceError(error) {
        if (!error) {
            return 'Unknown error.';
        }

        if (Array.isArray(error.body)) {
            return error.body
                .map((entry) => entry.message)
                .join(', ');
        }

        return (
            error.body?.message
            || error.message
            || 'Unexpected error.'
        );
    }

    get hasCompany() {
        return Boolean(this.companyId);
    }

    get hasDashboard() {
        return Boolean(this.dashboard);
    }

    get hasSelectedAsset() {
        return Boolean(this.selectedAsset);
    }

    get statusOptions() {
        return [
            { label: 'All Statuses', value: 'All' },
            { label: 'Planned', value: 'Planned' },
            { label: 'In Service', value: 'In Service' },
            { label: 'Impaired', value: 'Impaired' },
            { label: 'Disposed', value: 'Disposed' }
        ];
    }

    get filteredAssets() {
        if (!this.dashboard?.assets) {
            return [];
        }

        return this.dashboard.assets.filter((asset) => {
            const matchesStatus =
                this.statusFilter === 'All'
                || asset.status === this.statusFilter;

            if (!matchesStatus) {
                return false;
            }

            if (!this.searchText) {
                return true;
            }

            const haystack = [
                asset.name,
                asset.assetTag,
                asset.companyAssetKey,
                asset.categoryName,
                asset.status
            ]
                .filter(Boolean)
                .join(' ')
                .toLowerCase();

            return haystack.includes(this.searchText);
        });
    }

    get selectedScheduleLines() {
        return this.selectedAsset?.scheduleLines || [];
    }

    get selectedMovements() {
        return this.selectedAsset?.movements || [];
    }

    get reconciliationIssues() {
        return this.selectedAsset?.reconciliation?.issues || [];
    }

    get hasReconciliationIssues() {
        return this.reconciliationIssues.length > 0;
    }

    get reconciliationStatusClass() {
        return this.selectedAsset?.reconciliation?.status === 'OK'
            ? 'status-ok'
            : 'status-review';
    }

    get selectedRows() {
        return this.selectedAsset
            ? [this.selectedAsset.assetId]
            : [];
    }

    get disableOpenAsset() {
        return !this.selectedAsset;
    }
}
