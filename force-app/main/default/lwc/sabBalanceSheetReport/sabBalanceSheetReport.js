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
    from '@salesforce/apex/SABBalanceSheetController.getFilters';
import runBalanceSheet
    from '@salesforce/apex/SABBalanceSheetController.runBalanceSheet';
import getRowDrilldown
    from '@salesforce/apex/SABBalanceSheetController.getRowDrilldown';

const STORAGE_KEY =
    'sabSelectedAccountingCompanyId';

export default class SabBalanceSheetReport
    extends NavigationMixin(LightningElement) {

    companyId;
    definitionId;
    definitionOptions = [];
    periodId;
    periodOptions = [];
    periodsById = new Map();
    asOfDate;
    comparisonEnabled = false;
    comparisonAsOfDate;
    report;
    drilldownTitle;
    drilldownLines = [];
    isLoading = false;
    errorMessage;
    subscription;
    requestSequence = 0;

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        this.asOfDate =
            new Date()
                .toISOString()
                .slice(0, 10);

        const storedCompanyId =
            window.sessionStorage.getItem(
                STORAGE_KEY
            );

        if (storedCompanyId) {
            this.companyId =
                storedCompanyId;
            this.loadFilters();
        }
    }

    renderedCallback() {
        if (
            !this.subscription
            && this.messageContext
        ) {
            this.subscription =
                subscribe(
                    this.messageContext,
                    COMPANY_CONTEXT_CHANNEL,
                    (message) =>
                        this.handleCompanyContext(
                            message
                        ),
                    {
                        scope:
                            APPLICATION_SCOPE
                    }
                );
        }
    }

    disconnectedCallback() {
        unsubscribe(
            this.subscription
        );
        this.subscription =
            null;
    }

    async handleCompanyContext(message) {
        if (!message) {
            return;
        }

        if (message.companyCleared) {
            this.requestSequence++;
            this.companyId =
                undefined;
            this.clearCompanyState();
            return;
        }

        if (
            !message.companyId
            || message.companyId
                === this.companyId
        ) {
            return;
        }

        this.requestSequence++;
        this.companyId =
            message.companyId;
        this.clearCompanyState();
        await this.loadFilters();
    }

    async loadFilters() {
        if (!this.companyId) {
            return;
        }

        const requestedCompanyId =
            this.companyId;
        const requestId =
            ++this.requestSequence;

        this.isLoading =
            true;
        this.errorMessage =
            undefined;

        try {
            const result =
                await getFilters({
                    companyId:
                        requestedCompanyId
                });

            if (
                requestId
                    !== this.requestSequence
                || requestedCompanyId
                    !== this.companyId
            ) {
                return;
            }

            this.definitionOptions =
                result.definitions || [];

            if (
                this.definitionOptions.length === 1
            ) {
                this.definitionId =
                    this.definitionOptions[0].value;
            }

            this.periodsById =
                new Map();

            this.periodOptions =
                (result.periods || []).map(
                    (period) => {
                        this.periodsById.set(
                            period.value,
                            period
                        );

                        return {
                            label:
                                period.label,
                            value:
                                period.value
                        };
                    }
                );
        } catch (error) {
            this.errorMessage =
                this.reduceError(
                    error
                );
        } finally {
            if (
                requestId
                    === this.requestSequence
            ) {
                this.isLoading =
                    false;
            }
        }
    }

    handleDefinitionChange(event) {
        this.definitionId =
            event.detail.value;
        this.clearReport();
    }

    handlePeriodChange(event) {
        this.periodId =
            event.detail.value;

        const period =
            this.periodsById.get(
                this.periodId
            );

        if (period) {
            this.asOfDate =
                period.endDate;
        }

        this.clearReport();
    }

    handleDateChange(event) {
        this.asOfDate =
            event.target.value;
        this.periodId =
            undefined;
        this.clearReport();
    }

    handleComparisonToggle(event) {
        this.comparisonEnabled =
            event.target.checked;

        if (!this.comparisonEnabled) {
            this.comparisonAsOfDate =
                undefined;
        }

        this.clearReport();
    }

    handleComparisonDateChange(event) {
        this.comparisonAsOfDate =
            event.target.value;
        this.clearReport();
    }

    async handleGenerate() {
        if (
            !this.companyId
            || !this.definitionId
            || !this.asOfDate
        ) {
            this.errorMessage =
                'Company, Balance Sheet Definition and As of Date are required.';
            return;
        }

        if (
            this.comparisonEnabled
            && !this.comparisonAsOfDate
        ) {
            this.errorMessage =
                'Comparison As of Date is required.';
            return;
        }

        const requestedCompanyId =
            this.companyId;
        const requestId =
            ++this.requestSequence;

        this.isLoading =
            true;
        this.errorMessage =
            undefined;
        this.closeDrilldown();

        try {
            const result =
                await runBalanceSheet({
                    companyId:
                        requestedCompanyId,
                    reportDefinitionId:
                        this.definitionId,
                    asOfDate:
                        this.asOfDate,
                    comparisonAsOfDate:
                        this.comparisonEnabled
                            ? this.comparisonAsOfDate
                            : null
                });

            if (
                requestId
                    !== this.requestSequence
                || requestedCompanyId
                    !== this.companyId
            ) {
                return;
            }

            this.report =
                result;
        } catch (error) {
            this.report =
                undefined;
            this.errorMessage =
                this.reduceError(
                    error
                );
        } finally {
            if (
                requestId
                    === this.requestSequence
            ) {
                this.isLoading =
                    false;
            }
        }
    }

    async handleDrilldown(event) {
        const rowKey =
            event.currentTarget.dataset.rowKey;

        const requestedCompanyId =
            this.companyId;
        const requestId =
            ++this.requestSequence;

        this.isLoading =
            true;
        this.errorMessage =
            undefined;
        this.drilldownTitle =
            rowKey + ' — Source Lines';
        this.drilldownLines = [];

        try {
            const result =
                await getRowDrilldown({
                    companyId:
                        requestedCompanyId,
                    reportDefinitionId:
                        this.definitionId,
                    asOfDate:
                        this.asOfDate,
                    comparisonAsOfDate:
                        this.comparisonEnabled
                            ? this.comparisonAsOfDate
                            : null,
                    rowKey,
                    comparison:
                        false
                });

            if (
                requestId
                    !== this.requestSequence
                || requestedCompanyId
                    !== this.companyId
            ) {
                return;
            }

            this.drilldownLines =
                result || [];
        } catch (error) {
            this.errorMessage =
                this.reduceError(
                    error
                );
        } finally {
            if (
                requestId
                    === this.requestSequence
            ) {
                this.isLoading =
                    false;
            }
        }
    }

    handleCloseDrilldown() {
        this.closeDrilldown();
    }

    closeDrilldown() {
        this.drilldownTitle =
            undefined;
        this.drilldownLines = [];
    }

    handleOpenJournal(event) {
        const recordId =
            event.currentTarget.dataset.recordId;

        if (!recordId) {
            return;
        }

        this[
            NavigationMixin.Navigate
        ]({
            type:
                'standard__recordPage',
            attributes: {
                recordId,
                objectApiName:
                    'Journal_Entry__c',
                actionName:
                    'view'
            }
        });
    }

    clearReport() {
        this.requestSequence++;
        this.report =
            undefined;
        this.errorMessage =
            undefined;
        this.closeDrilldown();
    }

    clearCompanyState() {
        this.clearReport();
        this.definitionId =
            undefined;
        this.definitionOptions = [];
        this.periodId =
            undefined;
        this.periodOptions = [];
        this.periodsById =
            new Map();
    }

    reduceError(error) {
        if (
            error
            && error.body
            && error.body.message
        ) {
            return error.body.message;
        }

        if (
            error
            && error.message
        ) {
            return error.message;
        }

        return 'Unexpected Balance Sheet error.';
    }

    get hasCompany() {
        return Boolean(
            this.companyId
        );
    }

    get missingDefinition() {
        return (
            this.hasCompany
            && this.definitionOptions.length === 0
        );
    }

    get generateDisabled() {
        return (
            this.isLoading
            || !this.companyId
            || !this.definitionId
            || !this.asOfDate
        );
    }

    get currentBalanceLabel() {
        return (
            this.report
            && this.report.currentBalanced
        )
            ? 'Accounting Equation Balanced'
            : 'Accounting Equation Out of Balance';
    }

    get currentBalanceClass() {
        return (
            this.report
            && this.report.currentBalanced
        )
            ? 'balance-status balance-good'
            : 'balance-status balance-bad';
    }

    get hasDrilldownLines() {
        return (
            this.drilldownLines
            && this.drilldownLines.length > 0
        );
    }
}
