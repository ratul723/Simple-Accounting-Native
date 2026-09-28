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

import getCustomers
    from '@salesforce/apex/SABARAgingController.getCustomers';
import runAging
    from '@salesforce/apex/SABARAgingController.runAging';

const STORAGE_KEY =
    'sabSelectedAccountingCompanyId';

export default class SabARAgingReport
    extends NavigationMixin(LightningElement) {

    companyId;
    asOfDate;
    partyProfileId;
    includeSettled = false;

    customerOptions = [];
    report;
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
            this.loadCustomers();
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
        if (this.subscription) {
            unsubscribe(
                this.subscription
            );
        }

        this.subscription =
            null;
    }

    async handleCompanyContext(message) {
        if (!message) {
            return;
        }

        if (message.companyCleared) {
            this.requestSequence++;
            this.companyId = undefined;
            this.partyProfileId = undefined;
            this.customerOptions = [];
            this.report = undefined;
            return;
        }

        if (
            !message.companyId
            || message.companyId === this.companyId
        ) {
            return;
        }

        this.requestSequence++;
        this.companyId =
            message.companyId;
        this.partyProfileId =
            undefined;
        this.report =
            undefined;
        this.customerOptions =
            [];

        await this.loadCustomers();
    }

    async loadCustomers() {
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
            const customers =
                await getCustomers({
                    companyId:
                        requestedCompanyId
                });

            if (
                requestId !== this.requestSequence
                || requestedCompanyId !== this.companyId
            ) {
                return;
            }

            this.customerOptions = [
                {
                    label:
                        'All customers',
                    value:
                        ''
                },
                ...(customers || [])
                    .map((item) => ({
                        label:
                            item.label,
                        value:
                            item.value
                    }))
            ];
        } catch (error) {
            this.errorMessage =
                this.reduceError(
                    error
                );
        } finally {
            if (
                requestId === this.requestSequence
            ) {
                this.isLoading =
                    false;
            }
        }
    }

    handleDateChange(event) {
        this.asOfDate =
            event.target.value;
        this.report =
            undefined;
    }

    handleCustomerChange(event) {
        this.partyProfileId =
            event.detail.value || undefined;
        this.report =
            undefined;
    }

    handleSettledChange(event) {
        this.includeSettled =
            event.target.checked;
        this.report =
            undefined;
    }

    async handleGenerate() {
        if (
            !this.companyId
            || !this.asOfDate
        ) {
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
            const report =
                await runAging({
                    companyId:
                        requestedCompanyId,
                    asOfDate:
                        this.asOfDate,
                    partyProfileId:
                        this.partyProfileId || null,
                    includeSettled:
                        this.includeSettled
                });

            if (
                requestId !== this.requestSequence
                || requestedCompanyId !== this.companyId
            ) {
                return;
            }

            this.report =
                report;
        } catch (error) {
            this.errorMessage =
                this.reduceError(
                    error
                );
            this.report =
                undefined;
        } finally {
            if (
                requestId === this.requestSequence
            ) {
                this.isLoading =
                    false;
            }
        }
    }

    handleOpenInvoice(event) {
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
                actionName:
                    'view'
            }
        });
    }

    get hasCompany() {
        return Boolean(
            this.companyId
        );
    }

    get generateDisabled() {
        return (
            !this.companyId
            || !this.asOfDate
            || this.isLoading
        );
    }

    get hasRows() {
        return Boolean(
            this.report
            && this.report.rows
            && this.report.rows.length
        );
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

        return 'Unexpected AR Aging error.';
    }
}
