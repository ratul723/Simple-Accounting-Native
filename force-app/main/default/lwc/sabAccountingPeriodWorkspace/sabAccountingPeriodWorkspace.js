import { LightningElement, wire } from 'lwc';
import LightningConfirm from 'lightning/confirm';
import {
    APPLICATION_SCOPE,
    MessageContext,
    subscribe,
    unsubscribe
} from 'lightning/messageService';

import COMPANY_CONTEXT_CHANNEL
    from '@salesforce/messageChannel/SABCompanyContext__c';

import getWorkspace
    from '@salesforce/apex/SABAccountingPeriodWorkspaceController.getWorkspace';
import getPeriodDetail
    from '@salesforce/apex/SABAccountingPeriodWorkspaceController.getPeriodDetail';
import closePeriod
    from '@salesforce/apex/SABAccountingPeriodWorkspaceController.closePeriod';
import reopenPeriod
    from '@salesforce/apex/SABAccountingPeriodWorkspaceController.reopenPeriod';

const STORAGE_KEY =
    'sabSelectedAccountingCompanyId';

export default class SabAccountingPeriodWorkspace
    extends LightningElement {

    companyId;
    canClosePeriod = false;
    canReopenPeriod = false;

    periodOptions = [];
    selectedPeriodId;
    period;
    actions = [];
    latestActionId;

    reason = '';
    closeRequestKey;
    reopenRequestKey;

    isLoading = false;
    successMessage;
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

            this.loadWorkspace();
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
            this.canClosePeriod =
                false;
            this.canReopenPeriod =
                false;
            this.resetSelection();
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

        this.canClosePeriod =
            false;
        this.canReopenPeriod =
            false;
        this.resetSelection();

        await this.loadWorkspace();
    }

    async loadWorkspace() {
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
                await getWorkspace({
                    companyId:
                        requestedCompanyId
                });

            if (
                this.companyId
                !== requestedCompanyId
            ) {
                return;
            }

            this.canClosePeriod =
                Boolean(
                    result.canClosePeriod
                );

            this.canReopenPeriod =
                Boolean(
                    result.canReopenPeriod
                );

            this.periodOptions =
                (result.periods || []).map(
                    (period) => ({
                        label:
                            period.periodName
                            + ' · '
                            + period.startDate
                            + ' to '
                            + period.endDate
                            + ' · '
                            + period.status,
                        value:
                            period.periodId
                    })
                );

            if (
                this.selectedPeriodId
                && !this.periodOptions.some(
                    (option) =>
                        option.value
                            === this.selectedPeriodId
                )
            ) {
                this.resetSelection();
            }
        } catch (error) {
            this.errorMessage =
                this.reduceError(
                    error
                );
        } finally {
            this.isLoading =
                false;
        }
    }

    async handlePeriodChange(
        event
    ) {
        this.selectedPeriodId =
            event.detail.value;

        await this.loadPeriod();
    }

    async loadPeriod() {
        if (!this.selectedPeriodId) {
            return;
        }

        const requestedPeriodId =
            this.selectedPeriodId;
        const requestedCompanyId =
            this.companyId;

        this.isLoading =
            true;
        this.errorMessage =
            undefined;

        try {
            const result =
                await getPeriodDetail({
                    periodId:
                        requestedPeriodId
                });

            if (
                this.companyId
                    !== requestedCompanyId
                || this.selectedPeriodId
                    !== requestedPeriodId
            ) {
                return;
            }

            this.period =
                result.period;
            this.actions =
                result.actions || [];
            this.latestActionId =
                result.latestActionId;

            this.reason = '';

            this.prepareRequestKeys();
        } catch (error) {
            this.errorMessage =
                this.reduceError(
                    error
                );
        } finally {
            this.isLoading =
                false;
        }
    }

    handleReasonChange(
        event
    ) {
        this.reason =
            event.target.value;

        this.successMessage =
            undefined;
        this.errorMessage =
            undefined;
    }

    prepareRequestKeys() {
        if (!this.period) {
            return;
        }

        const basis =
            this.latestActionId
            || 'ROOT';

        this.closeRequestKey =
            'UI-CLOSE-'
            + this.period.periodId
            + '-'
            + basis;

        this.reopenRequestKey =
            'UI-REOPEN-'
            + this.period.periodId
            + '-'
            + basis;
    }

    async handleClose() {
        this.errorMessage =
            undefined;
        this.successMessage =
            undefined;

        if (
            !this.reason
            || !this.reason.trim()
        ) {
            this.errorMessage =
                'Enter a reason before closing the Accounting Period.';
            return;
        }

        const confirmed =
            await LightningConfirm.open({
                label:
                    'Close Accounting Period',
                message:
                    'Closing this Period prevents new posting into it until an authorized user reopens it. Continue?',
                variant:
                    'header'
            });

        if (!confirmed) {
            return;
        }

        await this.executeAction(
            'close'
        );
    }

    async handleReopen() {
        this.errorMessage =
            undefined;
        this.successMessage =
            undefined;

        if (
            !this.reason
            || !this.reason.trim()
        ) {
            this.errorMessage =
                'Enter a reason before reopening the Accounting Period.';
            return;
        }

        const confirmed =
            await LightningConfirm.open({
                label:
                    'Reopen Accounting Period',
                message:
                    'Reopening allows authorized posting into this historical Period again and may change regenerated historical reports. Continue?',
                variant:
                    'header'
            });

        if (!confirmed) {
            return;
        }

        await this.executeAction(
            'reopen'
        );
    }

    async executeAction(
        actionName
    ) {
        this.isLoading =
            true;

        try {
            let result;

            if (
                actionName
                === 'close'
            ) {
                result =
                    await closePeriod({
                        periodId:
                            this.period.periodId,
                        requestKey:
                            this.closeRequestKey,
                        reason:
                            this.reason.trim()
                    });
            } else {
                result =
                    await reopenPeriod({
                        periodId:
                            this.period.periodId,
                        requestKey:
                            this.reopenRequestKey,
                        reason:
                            this.reason.trim()
                    });
            }

            this.successMessage =
                result.replay
                    ? 'The original Period action result was returned.'
                    : (
                        actionName
                            === 'close'
                            ? 'Accounting Period closed successfully.'
                            : 'Accounting Period reopened successfully.'
                    );

            await this.loadPeriod();
            await this.loadWorkspace();
        } catch (error) {
            this.errorMessage =
                this.reduceError(
                    error
                );
        } finally {
            this.isLoading =
                false;
        }
    }

    resetSelection() {
        this.periodOptions = [];
        this.selectedPeriodId =
            undefined;
        this.period =
            undefined;
        this.actions = [];
        this.latestActionId =
            undefined;
        this.reason = '';
        this.closeRequestKey =
            undefined;
        this.reopenRequestKey =
            undefined;
        this.successMessage =
            undefined;
        this.errorMessage =
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

        return 'Unexpected Accounting Period Workspace error.';
    }

    get hasCompany() {
        return Boolean(
            this.companyId
        );
    }

    get isOpen() {
        return (
            this.period
            && this.period.status
                === 'Open'
        );
    }

    get isClosed() {
        return (
            this.period
            && this.period.status
                === 'Closed'
        );
    }

    get hasHistory() {
        return (
            this.actions
            && this.actions.length > 0
        );
    }

    get hasRelevantPermission() {
        return (
            (this.isOpen
                && this.canClosePeriod)
            || (this.isClosed
                && this.canReopenPeriod)
        );
    }

    get closeDisabled() {
        return (
            this.isLoading
            || !this.canClosePeriod
            || !this.isOpen
            || !this.reason
            || !this.reason.trim()
        );
    }

    get reopenDisabled() {
        return (
            this.isLoading
            || !this.canReopenPeriod
            || !this.isClosed
            || !this.reason
            || !this.reason.trim()
        );
    }

    get reasonLabel() {
        return this.isClosed
            ? 'Reason for Reopening'
            : 'Reason for Closing';
    }

    get periodDateRange() {
        if (!this.period) {
            return '';
        }

        return (
            this.period.startDate
            + ' to '
            + this.period.endDate
        );
    }

    get fiscalLabel() {
        if (!this.period) {
            return '';
        }

        return (
            'FY '
            + this.period.fiscalYear
            + ' · Q'
            + this.period.fiscalQuarter
            + ' · Period '
            + this.period.periodNumber
        );
    }

    get closedByDisplay() {
        return (
            this.period
            && this.period.closedByName
        )
            ? this.period.closedByName
            : '—';
    }
}
