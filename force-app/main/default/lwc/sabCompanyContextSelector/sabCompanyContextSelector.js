import { LightningElement, wire } from 'lwc';
import { publish, MessageContext } from 'lightning/messageService';

import getAccessibleCompanies
    from '@salesforce/apex/SABCompanyContextController.getAccessibleCompanies';
import getCompanyContext
    from '@salesforce/apex/SABCompanyContextController.getCompanyContext';

import COMPANY_CONTEXT_CHANNEL
    from '@salesforce/messageChannel/SABCompanyContext__c';

const STORAGE_KEY = 'sabSelectedAccountingCompanyId';

export default class SabCompanyContextSelector extends LightningElement {
    companies = [];
    selectedCompany;
    selectedCompanyId;
    isLoading = true;
    errorMessage;
    selectionRequestId = 0;

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        this.loadCompanies();
    }

    async loadCompanies() {
        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            const result =
                await getAccessibleCompanies();

            this.companies =
                Array.isArray(result)
                    ? result
                    : [];

            if (this.companies.length === 0) {
                this.clearSelection(true, true);
                return;
            }

            const storedCompanyId =
                window.sessionStorage.getItem(
                    STORAGE_KEY
                );

            const storedStillAvailable =
                storedCompanyId
                && this.companies.some(
                    (company) =>
                        company.companyId
                            === storedCompanyId
                );

            const initialCompanyId =
                storedStillAvailable
                    ? storedCompanyId
                    : this.companies[0].companyId;

            await this.selectCompany(
                initialCompanyId,
                false
            );
        } catch (error) {
            this.clearSelection(true, true);
            this.errorMessage =
                this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async handleCompanyChange(event) {
        const nextCompanyId =
            event.detail.value;

        if (
            !nextCompanyId
            || nextCompanyId
                === this.selectedCompanyId
        ) {
            return;
        }

        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            await this.selectCompany(
                nextCompanyId,
                true
            );
        } catch (error) {
            this.errorMessage =
                this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async selectCompany(
        companyId,
        isSwitch
    ) {
        // Revalidate on the server rather than trusting the option/client cache.
        // The request id prevents a slower, stale response from overwriting a
        // newer company selection.
        const requestId =
            ++this.selectionRequestId;

        const context =
            await getCompanyContext({
                companyId
            });

        if (
            requestId
            !== this.selectionRequestId
        ) {
            return;
        }

        const previousCompanyId =
            this.selectedCompanyId;

        this.selectedCompany =
            context;
        this.selectedCompanyId =
            context.companyId;

        window.sessionStorage.setItem(
            STORAGE_KEY,
            context.companyId
        );

        const switched =
            Boolean(
                isSwitch
                && previousCompanyId
                && previousCompanyId
                    !== context.companyId
            );

        this.publishContext(
            context,
            switched
        );

        this.dispatchEvent(
            new CustomEvent(
                'companychange',
                {
                    detail: {
                        ...context,
                        companySwitched: switched,
                        companyCleared: false
                    },
                    bubbles: true,
                    composed: true
                }
            )
        );
    }

    publishContext(
        context,
        companySwitched
    ) {
        publish(
            this.messageContext,
            COMPANY_CONTEXT_CHANNEL,
            {
                companyId:
                    context.companyId,
                companyName:
                    context.companyName,
                companyKey:
                    context.companyKey,
                functionalCurrency:
                    context.functionalCurrency,
                setupStatus:
                    context.setupStatus,
                companySwitched:
                    companySwitched,
                companyCleared:
                    false
            }
        );
    }

    publishClearContext() {
        if (!this.messageContext) {
            return;
        }

        publish(
            this.messageContext,
            COMPANY_CONTEXT_CHANNEL,
            {
                companyId: null,
                companyName: null,
                companyKey: null,
                functionalCurrency: null,
                setupStatus: null,
                companySwitched: false,
                companyCleared: true
            }
        );
    }

    clearSelection(
        clearStorage = true,
        notifySubscribers = false
    ) {
        this.selectionRequestId++;
        this.selectedCompany = undefined;
        this.selectedCompanyId = undefined;

        if (clearStorage) {
            window.sessionStorage.removeItem(
                STORAGE_KEY
            );
        }

        if (notifySubscribers) {
            this.publishClearContext();
        }
    }

    get companyOptions() {
        return this.companies.map(
            (company) => ({
                label:
                    company.companyName
                    + ' · '
                    + company.functionalCurrency,
                value:
                    company.companyId
            })
        );
    }

    get hasCompanies() {
        return this.companies.length > 0;
    }

    get hasNoCompanies() {
        return (
            !this.isLoading
            && this.companies.length === 0
        );
    }

    get showPicker() {
        return this.companies.length > 1;
    }

    get currencyLabel() {
        return this.selectedCompany
            ? 'Functional Currency: '
                + this.selectedCompany.functionalCurrency
            : '';
    }

    get setupStatusLabel() {
        return this.selectedCompany
            ? 'Setup: '
                + this.selectedCompany.setupStatus
            : '';
    }

    reduceError(error) {
        if (
            error
            && error.body
            && error.body.message
        ) {
            return error.body.message;
        }

        if (error && error.message) {
            return error.message;
        }

        return 'Unable to load the Accounting Company context.';
    }
}
