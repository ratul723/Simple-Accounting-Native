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
    from '@salesforce/apex/SABGeneralLedgerController.getFilters';
import runGeneralLedger
    from '@salesforce/apex/SABGeneralLedgerController.runGeneralLedger';

const STORAGE_KEY =
    'sabSelectedAccountingCompanyId';

export default class SabGeneralLedgerReport
    extends NavigationMixin(LightningElement) {

    companyId;

    periodId;
    periodOptions = [];
    periodsById = new Map();

    glAccountId;
    accountOptions = [];

    fromDate;
    toDate;

    report;
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

            this.accountOptions = [
                {
                    label:
                        'All Accounts',
                    value:
                        ''
                },
                ...(result.accounts || []).map(
                    (account) => ({
                        label:
                            account.label,
                        value:
                            account.value
                    })
                )
            ];
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

        this.clearReport();
    }

    handleAccountChange(event) {
        this.glAccountId =
            event.detail.value || null;

        this.clearReport();
    }

    handleDateChange(event) {
        this[event.target.name] =
            event.target.value;

        this.periodId =
            undefined;

        this.clearReport();
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

        try {
            const result =
                await runGeneralLedger({
                    companyId:
                        requestedCompanyId,
                    fromDate:
                        this.fromDate,
                    toDate:
                        this.toDate,
                    glAccountId:
                        this.glAccountId
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
    }

    clearCompanyState() {
        this.clearReport();

        this.periodId =
            undefined;
        this.periodOptions = [];
        this.periodsById =
            new Map();

        this.glAccountId =
            undefined;
        this.accountOptions = [];
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

        return 'Unexpected General Ledger error.';
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

    get hasAccounts() {
        return Boolean(
            this.report
            && this.report.accounts
            && this.report.accounts.length > 0
        );
    }

    get balanceLabel() {
        return (
            this.report
            && this.report.balanced
        )
            ? 'Ledger Balanced'
            : 'Ledger Out of Balance';
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
