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

import getSetupState
    from '@salesforce/apex/SABCompanySetupWizardController.getSetupState';

const STORAGE_KEY =
    'sabSelectedAccountingCompanyId';

export default class SabCompanySetupWizard
    extends NavigationMixin(LightningElement) {

    companyId;
    state;
    isLoading = false;
    errorMessage;
    subscription;

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        const storedCompanyId =
            window.sessionStorage.getItem(
                STORAGE_KEY
            );

        if (storedCompanyId) {
            this.companyId =
                storedCompanyId;

            this.loadState();
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

    async handleCompanyContext(
        message
    ) {
        if (!message) {
            return;
        }

        if (message.companyCleared) {
            this.companyId =
                undefined;
            this.state =
                undefined;
            this.errorMessage =
                undefined;
            return;
        }

        if (
            !message.companyId
            || message.companyId
                === this.companyId
        ) {
            return;
        }

        this.companyId =
            message.companyId;
        this.state =
            undefined;

        await this.loadState();
    }

    async loadState() {
        if (!this.companyId) {
            return;
        }

        const requestedCompanyId =
            this.companyId;

        this.isLoading =
            true;
        this.errorMessage =
            undefined;

        try {
            const result =
                await getSetupState({
                    companyId:
                        requestedCompanyId
                });

            if (
                this.companyId
                !== requestedCompanyId
            ) {
                return;
            }

            this.state =
                result;
        } catch (error) {
            this.state =
                undefined;
            this.errorMessage =
                this.reduceError(
                    error
                );
        } finally {
            this.isLoading =
                false;
        }
    }

    async handleValidate() {
        await this.loadState();
    }

    handleOpenRecord(event) {
        const recordId =
            event.currentTarget.dataset.recordId;

        const objectApiName =
            event.currentTarget.dataset.objectApi;

        this[
            NavigationMixin.Navigate
        ]({
            type:
                'standard__recordPage',
            attributes: {
                recordId,
                objectApiName,
                actionName:
                    'view'
            }
        });
    }

    handleOpenObject(event) {
        const objectApiName =
            event.currentTarget.dataset.objectApi;

        this[
            NavigationMixin.Navigate
        ]({
            type:
                'standard__objectPage',
            attributes: {
                objectApiName,
                actionName:
                    'list'
            },
            state: {
                filterName:
                    'Recent'
            }
        });
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

        return 'Unexpected Company Setup Wizard error.';
    }

    get hasCompany() {
        return Boolean(
            this.companyId
        );
    }

    get hasErrors() {
        return Boolean(
            this.state
            && this.state.errors
            && this.state.errors.length > 0
        );
    }

    get hasWarnings() {
        return Boolean(
            this.state
            && this.state.warnings
            && this.state.warnings.length > 0
        );
    }

    get readinessLabel() {
        return (
            this.state
            && this.state.readyForCoreAccounting
        )
            ? 'Core Ready'
            : 'Needs Attention';
    }

    get readinessClass() {
        return (
            this.state
            && this.state.readyForCoreAccounting
        )
            ? 'readiness readiness-ready'
            : 'readiness readiness-warning';
    }

    get companyActiveLabel() {
        return (
            this.state
            && this.state.companyActive
        )
            ? 'Yes'
            : 'No';
    }
}
