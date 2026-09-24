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

import getTimeline
    from '@salesforce/apex/SABAuditTimelineController.getTimeline';

const STORAGE_KEY =
    'sabSelectedAccountingCompanyId';

export default class SabAuditTimeline
    extends NavigationMixin(LightningElement) {

    companyId;
    items = [];
    categoryFilter = 'ALL';
    searchText = '';

    businessActionCount = 0;
    periodActionCount = 0;
    journalActionCount = 0;
    accountingEventCount = 0;

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

            this.loadTimeline();
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
            this.clearTimeline();
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

        this.clearTimeline();

        await this.loadTimeline();
    }

    clearTimeline() {
        this.items = [];
        this.categoryFilter = 'ALL';
        this.searchText = '';
        this.businessActionCount = 0;
        this.periodActionCount = 0;
        this.journalActionCount = 0;
        this.accountingEventCount = 0;
        this.errorMessage = undefined;
    }

    async loadTimeline() {
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
                await getTimeline({
                    companyId:
                        requestedCompanyId
                });

            if (
                this.companyId
                !== requestedCompanyId
            ) {
                return;
            }

            this.businessActionCount =
                result.businessActionCount || 0;
            this.periodActionCount =
                result.periodActionCount || 0;
            this.journalActionCount =
                result.journalActionCount || 0;
            this.accountingEventCount =
                result.accountingEventCount || 0;

            this.items =
                (result.items || []).map(
                    (item) =>
                        this.decorateItem(
                            item
                        )
                );
        } catch (error) {
            this.items = [];
            this.errorMessage =
                this.reduceError(
                    error
                );
        } finally {
            this.isLoading =
                false;
        }
    }

    decorateItem(item) {
        const config =
            this.categoryConfig(
                item.category
            );

        const sourceDisplay =
            item.sourceType
                ? (
                    item.sourceType
                    + (
                        item.sourceRecordId
                            ? ' · '
                                + item.sourceRecordId
                            : ''
                    )
                    + (
                        item.sourceVersion !== null
                        && item.sourceVersion !== undefined
                            ? ' · v'
                                + item.sourceVersion
                            : ''
                    )
                )
                : '';

        return {
            ...item,
            categoryLabel:
                config.label,
            iconName:
                config.icon,
            badgeClass:
                'type-badge '
                + config.cssClass,
            actorDisplay:
                item.actorName || '',
            sourceDisplay
        };
    }

    categoryConfig(category) {
        switch (category) {
            case 'BUSINESS':
                return {
                    label:
                        'Business',
                    icon:
                        'standard:task2',
                    cssClass:
                        'business'
                };

            case 'PERIOD':
                return {
                    label:
                        'Period',
                    icon:
                        'standard:date_time',
                    cssClass:
                        'period'
                };

            case 'JOURNAL':
                return {
                    label:
                        'Journal',
                    icon:
                        'standard:journal',
                    cssClass:
                        'journal'
                };

            case 'EVENT':
                return {
                    label:
                        'Event',
                    icon:
                        'standard:record',
                    cssClass:
                        'event'
                };

            default:
                return {
                    label:
                        'History',
                    icon:
                        'standard:record',
                    cssClass:
                        ''
                };
        }
    }

    handleCategoryChange(event) {
        this.categoryFilter =
            event.detail.value;
    }

    handleSearchChange(event) {
        this.searchText =
            event.target.value || '';
    }

    async handleRefresh() {
        await this.loadTimeline();
    }

    handleOpenRecord(event) {
        const recordId =
            event.currentTarget.dataset.recordId;

        const objectApiName =
            event.currentTarget.dataset.objectApi;

        if (
            !recordId
            || !objectApiName
        ) {
            return;
        }

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

        return 'Unexpected Audit History error.';
    }

    get categoryOptions() {
        return [
            {
                label:
                    'All History',
                value:
                    'ALL'
            },
            {
                label:
                    'Journal',
                value:
                    'JOURNAL'
            },
            {
                label:
                    'Accounting Period',
                value:
                    'PERIOD'
            },
            {
                label:
                    'Business Action',
                value:
                    'BUSINESS'
            },
            {
                label:
                    'Accounting Event',
                value:
                    'EVENT'
            }
        ];
    }

    get visibleItems() {
        const search =
            (this.searchText || '')
                .trim()
                .toLowerCase();

        return this.items.filter(
            (item) => {
                const categoryMatches =
                    this.categoryFilter
                        === 'ALL'
                    || item.category
                        === this.categoryFilter;

                if (!categoryMatches) {
                    return false;
                }

                if (!search) {
                    return true;
                }

                const haystack = [
                    item.title,
                    item.detail,
                    item.actorName,
                    item.status,
                    item.requestKey,
                    item.sourceType,
                    item.sourceRecordId,
                    item.sourceDisplay
                ]
                    .filter(Boolean)
                    .join(' ')
                    .toLowerCase();

                return haystack.includes(
                    search
                );
            }
        );
    }

    get hasVisibleItems() {
        return (
            this.visibleItems.length > 0
        );
    }

    get hasCompany() {
        return Boolean(
            this.companyId
        );
    }
}
