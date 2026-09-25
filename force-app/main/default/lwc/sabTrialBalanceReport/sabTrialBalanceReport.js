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

import getPeriods
    from '@salesforce/apex/SABTrialBalanceController.getPeriods';
import runTrialBalance
    from '@salesforce/apex/SABTrialBalanceController.runTrialBalance';
import getMovementLines
    from '@salesforce/apex/SABTrialBalanceController.getMovementLines';

const STORAGE_KEY =
    'sabSelectedAccountingCompanyId';

export default class SabTrialBalanceReport
    extends NavigationMixin(LightningElement) {

    companyId;
    periodId;
    periodOptions = [];
    periodsById = new Map();

    fromDate;
    toDate;
    includeZeroBalance = false;

    report;
    selectedAccountLabel;
    drilldownLines = [];

    isLoading = false;
    errorMessage;
    subscription;
    requestSequence = 0;

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        const today =
            new Date();

        this.fromDate =
            new Date(
                today.getFullYear(),
                today.getMonth(),
                1
            )
                .toISOString()
                .slice(0, 10);

        this.toDate =
            new Date(
                today.getFullYear(),
                today.getMonth() + 1,
                0
            )
                .toISOString()
                .slice(0, 10);

        const storedCompanyId =
            window.sessionStorage.getItem(
                STORAGE_KEY
            );

        if (storedCompanyId) {
            this.companyId =
                storedCompanyId;
            this.loadPeriods();
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
            this.clearReportState();
            this.periodOptions = [];
            this.periodsById =
                new Map();
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
        this.clearReportState();
        this.periodOptions = [];
        this.periodsById =
            new Map();

        await this.loadPeriods();
    }

    async loadPeriods() {
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
            const periods =
                await getPeriods({
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

            this.periodsById =
                new Map();

            this.periodOptions =
                (periods || []).map(
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

    handlePeriodChange(event) {
        this.periodId =
            event.detail.value;

        const period =
            this.periodsById.get(
                this.periodId
            );

        if (period) {
            this.fromDate =
                period.startDate;
            this.toDate =
                period.endDate;
        }

        this.clearGeneratedReport();
    }

    handleDateChange(event) {
        this[event.target.name] =
            event.target.value;

        this.periodId =
            undefined;
        this.clearGeneratedReport();
    }

    handleZeroChange(event) {
        this.includeZeroBalance =
            event.target.checked;

        this.clearGeneratedReport();
    }

    async handleGenerate() {
        if (
            !this.companyId
            || !this.fromDate
            || !this.toDate
        ) {
            this.errorMessage =
                'Company, From Date and To Date are required.';
            return;
        }

        if (
            this.fromDate
            > this.toDate
        ) {
            this.errorMessage =
                'From Date cannot be after To Date.';
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
        this.selectedAccountLabel =
            undefined;
        this.drilldownLines = [];

        try {
            const result =
                await runTrialBalance({
                    companyId:
                        requestedCompanyId,
                    fromDate:
                        this.fromDate,
                    toDate:
                        this.toDate,
                    includeZeroBalance:
                        this.includeZeroBalance
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

    async handleViewLines(event) {
        const glAccountId =
            event.currentTarget.dataset.accountId;

        const requestedCompanyId =
            this.companyId;
        const requestId =
            ++this.requestSequence;

        this.selectedAccountLabel =
            event.currentTarget.dataset.accountCode
            + ' · '
            + event.currentTarget.dataset.accountName;

        this.drilldownLines = [];
        this.isLoading =
            true;
        this.errorMessage =
            undefined;

        try {
            const result =
                await getMovementLines({
                    companyId:
                        requestedCompanyId,
                    glAccountId,
                    fromDate:
                        this.fromDate,
                    toDate:
                        this.toDate
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
        this.selectedAccountLabel =
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

    clearGeneratedReport() {
        this.requestSequence++;
        this.report =
            undefined;
        this.selectedAccountLabel =
            undefined;
        this.drilldownLines = [];
        this.errorMessage =
            undefined;
    }

    clearReportState() {
        this.clearGeneratedReport();
        this.periodId =
            undefined;
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

        return 'Unexpected Trial Balance error.';
    }

    get hasCompany() {
        return Boolean(
            this.companyId
        );
    }

    get generateDisabled() {
        return (
            this.isLoading
            || !this.companyId
            || !this.fromDate
            || !this.toDate
        );
    }

    get hasDrilldownLines() {
        return (
            this.drilldownLines
            && this.drilldownLines.length > 0
        );
    }

    get balanceLabel() {
        return (
            this.report
            && this.report.balanced
        )
            ? 'Balanced'
            : 'Out of Balance';
    }

    get balanceClass() {
        return (
            this.report
            && this.report.balanced
        )
            ? 'balance-status balance-good'
            : 'balance-status balance-bad';
    }
}
