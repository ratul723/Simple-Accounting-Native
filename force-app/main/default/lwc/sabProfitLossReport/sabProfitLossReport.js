import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import {
    APPLICATION_SCOPE,
    MessageContext,
    subscribe,
    unsubscribe
} from 'lightning/messageService';

import COMPANY_CONTEXT_CHANNEL
    from '@salesforce/messageChannel/SABCompanyContext__c';

import getFilters
    from '@salesforce/apex/SABProfitLossController.getFilters';
import runProfitLoss
    from '@salesforce/apex/SABProfitLossController.runProfitLoss';
import getRowDrilldown
    from '@salesforce/apex/SABProfitLossController.getRowDrilldown';

const STORAGE_KEY = 'sabSelectedAccountingCompanyId';

export default class SabProfitLossReport
    extends NavigationMixin(LightningElement) {

    companyId;
    definitionId;
    definitionOptions = [];
    periodId;
    periodOptions = [];
    periodsById = new Map();

    departmentId;
    departmentOptions = [];
    costCenterId;
    costCenterOptions = [];
    projectId;
    projectOptions = [];

    fromDate;
    toDate;
    comparisonEnabled = false;
    comparisonFromDate;
    comparisonToDate;

    report;
    drilldownTitle;
    drilldownLines = [];
    errorMessage;
    isLoading = false;

    subscription;
    requestSequence = 0;

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        const today = new Date();

        this.fromDate = new Date(
            today.getFullYear(),
            today.getMonth(),
            1
        ).toISOString().slice(0, 10);

        this.toDate = new Date(
            today.getFullYear(),
            today.getMonth() + 1,
            0
        ).toISOString().slice(0, 10);

        const storedCompanyId =
            window.sessionStorage.getItem(STORAGE_KEY);

        if (storedCompanyId) {
            this.companyId = storedCompanyId;
            this.loadFilters();
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
        unsubscribe(this.subscription);
        this.subscription = null;
    }

    async handleCompanyContext(message) {
        if (!message) {
            return;
        }

        if (message.companyCleared) {
            this.requestSequence++;
            this.companyId = undefined;
            this.clearCompanyState();
            return;
        }

        if (
            !message.companyId ||
            message.companyId === this.companyId
        ) {
            return;
        }

        this.requestSequence++;
        this.companyId = message.companyId;
        this.clearCompanyState();
        await this.loadFilters();
    }

    async loadFilters() {
        if (!this.companyId) {
            return;
        }

        const requestedCompanyId = this.companyId;
        const requestId = ++this.requestSequence;

        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            const result = await getFilters({
                companyId: requestedCompanyId
            });

            if (
                requestId !== this.requestSequence ||
                requestedCompanyId !== this.companyId
            ) {
                return;
            }

            this.definitionOptions =
                result.definitions || [];

            if (this.definitionOptions.length === 1) {
                this.definitionId =
                    this.definitionOptions[0].value;
            }

            this.periodsById = new Map();

            this.periodOptions = (result.periods || []).map(
                (period) => {
                    this.periodsById.set(
                        period.value,
                        period
                    );

                    return {
                        label: period.label,
                        value: period.value
                    };
                }
            );

            this.departmentOptions =
                this.withAll('All Departments', result.departments);

            this.costCenterOptions =
                this.withAll('All Cost Centers', result.costCenters);

            this.projectOptions =
                this.withAll('All Projects', result.projects);
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            if (requestId === this.requestSequence) {
                this.isLoading = false;
            }
        }
    }

    withAll(label, values) {
        return [
            { label, value: '' },
            ...(values || [])
        ];
    }

    handleDefinitionChange(event) {
        this.definitionId = event.detail.value;
        this.clearReport();
    }

    handlePeriodChange(event) {
        this.periodId = event.detail.value;

        const period =
            this.periodsById.get(this.periodId);

        if (period) {
            this.fromDate = period.startDate;
            this.toDate = period.endDate;
        }

        this.clearReport();
    }

    handleDateChange(event) {
        this[event.target.name] =
            event.target.value;

        this.periodId = undefined;
        this.clearReport();
    }

    handleDimensionChange(event) {
        this[event.target.name] =
            event.detail.value || null;

        this.clearReport();
    }

    handleComparisonToggle(event) {
        this.comparisonEnabled =
            event.target.checked;

        if (!this.comparisonEnabled) {
            this.comparisonFromDate = undefined;
            this.comparisonToDate = undefined;
        }

        this.clearReport();
    }

    handleComparisonDateChange(event) {
        this[event.target.name] =
            event.target.value;

        this.clearReport();
    }

    async handleGenerate() {
        if (
            !this.companyId ||
            !this.definitionId ||
            !this.fromDate ||
            !this.toDate
        ) {
            this.errorMessage =
                'Company, P&L Definition, From Date and To Date are required.';
            return;
        }

        if (this.fromDate > this.toDate) {
            this.errorMessage =
                'From Date cannot be after To Date.';
            return;
        }

        if (
            this.comparisonEnabled &&
            (
                !this.comparisonFromDate ||
                !this.comparisonToDate
            )
        ) {
            this.errorMessage =
                'Both comparison dates are required.';
            return;
        }

        const requestedCompanyId = this.companyId;
        const requestId = ++this.requestSequence;

        this.isLoading = true;
        this.errorMessage = undefined;
        this.closeDrilldown();

        try {
            const result = await runProfitLoss({
                companyId: requestedCompanyId,
                reportDefinitionId: this.definitionId,
                fromDate: this.fromDate,
                toDate: this.toDate,
                comparisonFromDate:
                    this.comparisonEnabled
                        ? this.comparisonFromDate
                        : null,
                comparisonToDate:
                    this.comparisonEnabled
                        ? this.comparisonToDate
                        : null,
                departmentId: this.departmentId,
                costCenterId: this.costCenterId,
                projectId: this.projectId
            });

            if (
                requestId !== this.requestSequence ||
                requestedCompanyId !== this.companyId
            ) {
                return;
            }

            this.report = result;
        } catch (error) {
            this.report = undefined;
            this.errorMessage = this.reduceError(error);
        } finally {
            if (requestId === this.requestSequence) {
                this.isLoading = false;
            }
        }
    }

    async handleDrilldown(event) {
        const rowKey =
            event.currentTarget.dataset.rowKey;

        const requestedCompanyId = this.companyId;
        const requestId = ++this.requestSequence;

        this.isLoading = true;
        this.errorMessage = undefined;
        this.drilldownTitle = rowKey + ' — Source Lines';
        this.drilldownLines = [];

        try {
            const result = await getRowDrilldown({
                companyId: requestedCompanyId,
                reportDefinitionId: this.definitionId,
                fromDate: this.fromDate,
                toDate: this.toDate,
                comparisonFromDate:
                    this.comparisonEnabled
                        ? this.comparisonFromDate
                        : null,
                comparisonToDate:
                    this.comparisonEnabled
                        ? this.comparisonToDate
                        : null,
                departmentId: this.departmentId,
                costCenterId: this.costCenterId,
                projectId: this.projectId,
                rowKey,
                comparison: false
            });

            if (
                requestId !== this.requestSequence ||
                requestedCompanyId !== this.companyId
            ) {
                return;
            }

            this.drilldownLines = result || [];
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            if (requestId === this.requestSequence) {
                this.isLoading = false;
            }
        }
    }

    handleCloseDrilldown() {
        this.closeDrilldown();
    }

    closeDrilldown() {
        this.drilldownTitle = undefined;
        this.drilldownLines = [];
    }

    handleOpenJournal(event) {
        const recordId =
            event.currentTarget.dataset.recordId;

        if (!recordId) {
            return;
        }

        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId,
                objectApiName: 'Journal_Entry__c',
                actionName: 'view'
            }
        });
    }

    clearReport() {
        this.requestSequence++;
        this.report = undefined;
        this.errorMessage = undefined;
        this.closeDrilldown();
    }

    clearCompanyState() {
        this.clearReport();
        this.definitionId = undefined;
        this.definitionOptions = [];
        this.periodId = undefined;
        this.periodOptions = [];
        this.periodsById = new Map();
        this.departmentId = undefined;
        this.departmentOptions = [];
        this.costCenterId = undefined;
        this.costCenterOptions = [];
        this.projectId = undefined;
        this.projectOptions = [];
    }

    reduceError(error) {
        if (error?.body?.message) {
            return error.body.message;
        }

        if (error?.message) {
            return error.message;
        }

        return 'Unexpected Profit & Loss error.';
    }

    get hasCompany() {
        return Boolean(this.companyId);
    }

    get missingDefinition() {
        return (
            this.hasCompany &&
            this.definitionOptions.length === 0
        );
    }

    get generateDisabled() {
        return (
            this.isLoading ||
            !this.companyId ||
            !this.definitionId ||
            !this.fromDate ||
            !this.toDate
        );
    }

    get hasDrilldownLines() {
        return this.drilldownLines.length > 0;
    }
}
