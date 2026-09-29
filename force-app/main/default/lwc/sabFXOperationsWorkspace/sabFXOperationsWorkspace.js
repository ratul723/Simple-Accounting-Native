import { LightningElement, wire } from 'lwc';
import {
    subscribe,
    unsubscribe,
    MessageContext,
    APPLICATION_SCOPE
} from 'lightning/messageService';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { encodeDefaultFieldValues } from 'lightning/pageReferenceUtils';

import COMPANY_CONTEXT_CHANNEL
    from '@salesforce/messageChannel/SABCompanyContext__c';

import getDashboard
    from '@salesforce/apex/SABFXOperationsWorkspaceController.getDashboard';
import getEligibleSettlementTargets
    from '@salesforce/apex/SABFXOperationsWorkspaceController.getEligibleSettlementTargets';

import previewRevaluation
    from '@salesforce/apex/SABFXRevaluationPreviewService.preview';
import approveRun
    from '@salesforce/apex/SABFXRevaluationPostingService.approveRun';
import postApprovedRun
    from '@salesforce/apex/SABFXRevaluationPostingService.postApprovedRun';
import reversePostedRun
    from '@salesforce/apex/SABFXRevaluationReversalService.reversePostedRun';

import authorizeForeignPayment
    from '@salesforce/apex/SABForeignCurrencySettlementService.authorizeForeignPayment';
import submitForeignPayment
    from '@salesforce/apex/SABForeignCurrencySettlementService.submitForeignPayment';
import postForeignPayment
    from '@salesforce/apex/SABForeignCurrencySettlementService.postForeignPayment';
import allocateForeignPayment
    from '@salesforce/apex/SABForeignCurrencySettlementService.allocateForeignPayment';
import reverseForeignAllocation
    from '@salesforce/apex/SABForeignCurrencySettlementService.reverseForeignAllocation';

const STORAGE_KEY = 'sabSelectedAccountingCompanyId';

const RUN_COLUMNS = [
    { label: 'Run Key', fieldName: 'runKey' },
    { label: 'Period', fieldName: 'accountingPeriodName' },
    { label: 'Status', fieldName: 'status' },
    { label: 'Reversal Policy', fieldName: 'reversalPolicy' },
    { label: 'Lines', fieldName: 'lineCount', type: 'number' },
    {
        label: 'Signed Adjustment',
        fieldName: 'signedAdjustmentTotal',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    }
];

const RUN_LINE_COLUMNS = [
    { label: 'Source', fieldName: 'sourceType' },
    { label: 'Currency', fieldName: 'transactionCurrency' },
    {
        label: 'Outstanding',
        fieldName: 'outstandingAmount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'Carrying',
        fieldName: 'carryingAmount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'Rate',
        fieldName: 'appliedRate',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 10
        }
    },
    {
        label: 'Revalued',
        fieldName: 'revaluedAmount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'Adjustment',
        fieldName: 'adjustmentAmount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    }
];

const PAYMENT_COLUMNS = [
    { label: 'Reference', fieldName: 'reference' },
    { label: 'Direction', fieldName: 'direction' },
    { label: 'State', fieldName: 'processingState' },
    {
        label: 'Amount',
        fieldName: 'amount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    { label: 'Currency', fieldName: 'transactionCurrency' },
    {
        label: 'Rate',
        fieldName: 'exchangeRate',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 10
        }
    },
    {
        label: 'Unallocated',
        fieldName: 'unallocatedAmount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    }
];

const TARGET_COLUMNS = [
    { label: 'Type', fieldName: 'targetType' },
    { label: 'Document', fieldName: 'documentNumber' },
    { label: 'Due Date', fieldName: 'dueDate', type: 'date' },
    {
        label: 'Outstanding',
        fieldName: 'outstandingAmount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'Historical Rate',
        fieldName: 'historicalRate',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 10
        }
    }
];

const ALLOCATION_COLUMNS = [
    { label: 'Payment', fieldName: 'paymentReference' },
    { label: 'Target Type', fieldName: 'targetType' },
    { label: 'Target', fieldName: 'targetName' },
    { label: 'Status', fieldName: 'status' },
    {
        label: 'Payment Amount',
        fieldName: 'paymentAmount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'Realized FX',
        fieldName: 'realizedFXAmount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    { label: 'FX State', fieldName: 'realizedFXState' }
];

export default class SabFXOperationsWorkspace extends NavigationMixin(LightningElement) {
    runColumns = RUN_COLUMNS;
    runLineColumns = RUN_LINE_COLUMNS;
    paymentColumns = PAYMENT_COLUMNS;
    targetColumns = TARGET_COLUMNS;
    allocationColumns = ALLOCATION_COLUMNS;

    companyId;
    companyName;
    functionalCurrency;
    dashboard;
    subscription;

    isLoading = false;
    errorMessage;

    selectedPeriodId;
    runKey = '';
    reversalPolicy = 'First Day of Next Period';
    runReason = '';

    selectedRunId;
    selectedPaymentId;
    selectedTargetId;
    selectedAllocationId;

    providerRequestKey = '';
    allocationAmount;
    allocationEffectiveDate;
    allocationNotes = '';
    allocationReason = '';

    runReversalPeriodId;
    runReversalDate;
    runReversalReason = '';

    allocationReversalDate;
    allocationReversalReason = '';

    eligibleTargets = [];
    actionKeys = {};

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        this.subscribeToCompanyContext();

        const storedCompanyId =
            window.sessionStorage.getItem(
                STORAGE_KEY
            );

        if (storedCompanyId) {
            this.companyId =
                storedCompanyId;
            this.loadDashboard();
        }
    }

    disconnectedCallback() {
        if (this.subscription) {
            unsubscribe(
                this.subscription
            );
            this.subscription =
                undefined;
        }
    }

    subscribeToCompanyContext() {
        if (
            this.subscription
            || !this.messageContext
        ) {
            return;
        }

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

    async handleCompanyContext(message) {
        if (
            !message
            || message.companyCleared
        ) {
            this.clearWorkspace();
            return;
        }

        if (!message.companyId) {
            return;
        }

        const changed =
            this.companyId
                !== message.companyId;

        this.companyId =
            message.companyId;
        this.companyName =
            message.companyName;
        this.functionalCurrency =
            message.functionalCurrency;

        if (changed) {
            this.resetSelections();
            await this.loadDashboard();
        }
    }

    clearWorkspace() {
        this.companyId =
            undefined;
        this.companyName =
            undefined;
        this.functionalCurrency =
            undefined;
        this.dashboard =
            undefined;
        this.eligibleTargets =
            [];
        this.resetSelections();
    }

    resetSelections() {
        this.selectedRunId =
            undefined;
        this.selectedPaymentId =
            undefined;
        this.selectedTargetId =
            undefined;
        this.selectedAllocationId =
            undefined;
        this.selectedPeriodId =
            undefined;
        this.runReversalPeriodId =
            undefined;
        this.runReversalDate =
            undefined;
        this.allocationReversalDate =
            undefined;
        this.allocationEffectiveDate =
            undefined;
        this.runKey =
            '';
        this.providerRequestKey =
            '';
        this.allocationAmount =
            undefined;
        this.allocationNotes =
            '';
        this.allocationReason =
            '';
        this.runReversalReason =
            '';
        this.allocationReversalReason =
            '';
        this.eligibleTargets =
            [];
        this.actionKeys =
            {};
    }

    async loadDashboard() {
        if (!this.companyId) {
            return;
        }

        this.isLoading = true;
        this.errorMessage =
            undefined;

        try {
            const result =
                await getDashboard({
                    companyId:
                        this.companyId
                });

            this.dashboard =
                result;
            this.companyName =
                result.companyName;
            this.functionalCurrency =
                result.functionalCurrency;

            this.initializePeriodSelection();
            this.restoreSelectedRows();
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

    initializePeriodSelection() {
        if (
            !this.dashboard
            || !Array.isArray(
                this.dashboard.periods
            )
            || this.dashboard.periods.length
                === 0
        ) {
            return;
        }

        const existingValid =
            this.selectedPeriodId
            && this.dashboard.periods.some(
                (period) =>
                    period.periodId
                        === this.selectedPeriodId
            );

        if (!existingValid) {
            const openPeriod =
                this.dashboard.periods.find(
                    (period) =>
                        period.status
                            === 'Open'
                );

            this.selectedPeriodId =
                openPeriod
                    ? openPeriod.periodId
                    : this.dashboard.periods[0]
                        .periodId;
        }

        if (!this.runReversalPeriodId) {
            this.runReversalPeriodId =
                this.selectedPeriodId;
        }

        if (!this.runKey) {
            this.runKey =
                this.generateRunKey();
        }
    }

    restoreSelectedRows() {
        if (this.selectedRunId) {
            const runStillExists =
                this.revaluationRuns.some(
                    (run) =>
                        run.runId
                            === this.selectedRunId
                );

            if (!runStillExists) {
                this.selectedRunId =
                    undefined;
            }
        }

        if (this.selectedPaymentId) {
            const paymentStillExists =
                this.foreignPayments.some(
                    (payment) =>
                        payment.paymentId
                            === this.selectedPaymentId
                );

            if (!paymentStillExists) {
                this.selectedPaymentId =
                    undefined;
                this.eligibleTargets =
                    [];
            }
        }

        if (this.selectedAllocationId) {
            const allocationStillExists =
                this.allocations.some(
                    (allocation) =>
                        allocation.allocationId
                            === this.selectedAllocationId
                );

            if (!allocationStillExists) {
                this.selectedAllocationId =
                    undefined;
            }
        }
    }

    get hasCompany() {
        return Boolean(
            this.companyId
        );
    }

    get hasDashboard() {
        return Boolean(
            this.dashboard
        );
    }

    get periodOptions() {
        return this.dashboard
            && Array.isArray(
                this.dashboard.periods
            )
            ? this.dashboard.periods.map(
                (period) => ({
                    label:
                        period.label,
                    value:
                        period.periodId
                })
            )
            : [];
    }

    get reversalPolicyOptions() {
        return [
            {
                label:
                    'First Day of Next Period',
                value:
                    'First Day of Next Period'
            },
            {
                label:
                    'Next Open Period',
                value:
                    'Next Open Period'
            },
            {
                label:
                    'No Automatic Reversal',
                value:
                    'No Automatic Reversal'
            }
        ];
    }

    get revaluationRuns() {
        return this.dashboard
            && Array.isArray(
                this.dashboard.revaluationRuns
            )
            ? this.dashboard.revaluationRuns
            : [];
    }

    get foreignPayments() {
        return this.dashboard
            && Array.isArray(
                this.dashboard.foreignPayments
            )
            ? this.dashboard.foreignPayments
            : [];
    }

    get allocations() {
        return this.dashboard
            && Array.isArray(
                this.dashboard.allocations
            )
            ? this.dashboard.allocations
            : [];
    }

    get selectedRun() {
        return this.revaluationRuns.find(
            (run) =>
                run.runId
                    === this.selectedRunId
        );
    }

    get selectedRunLines() {
        return this.selectedRun
            && Array.isArray(
                this.selectedRun.lines
            )
            ? this.selectedRun.lines
            : [];
    }

    get selectedPayment() {
        return this.foreignPayments.find(
            (payment) =>
                payment.paymentId
                    === this.selectedPaymentId
        );
    }

    get selectedTarget() {
        return this.eligibleTargets.find(
            (target) =>
                target.targetId
                    === this.selectedTargetId
        );
    }

    get selectedAllocation() {
        return this.allocations.find(
            (allocation) =>
                allocation.allocationId
                    === this.selectedAllocationId
        );
    }

    get selectedRunRows() {
        return this.selectedRunId
            ? [this.selectedRunId]
            : [];
    }

    get selectedPaymentRows() {
        return this.selectedPaymentId
            ? [this.selectedPaymentId]
            : [];
    }

    get selectedTargetRows() {
        return this.selectedTargetId
            ? [this.selectedTargetId]
            : [];
    }

    get selectedAllocationRows() {
        return this.selectedAllocationId
            ? [this.selectedAllocationId]
            : [];
    }

    get previewDisabled() {
        return !this.canPreviewRun;
    }

    get approveRunDisabled() {
        return !this.canApproveSelectedRun;
    }

    get postRunDisabled() {
        return !this.canPostSelectedRun;
    }

    get reverseRunDisabled() {
        return !this.canReverseSelectedRun;
    }

    get authorizePaymentDisabled() {
        return !this.canAuthorizePayment;
    }

    get submitPaymentDisabled() {
        return !this.canSubmitPayment;
    }

    get postPaymentDisabled() {
        return !this.canPostPayment;
    }

    get loadTargetsDisabled() {
        return !this.canLoadTargets;
    }

    get allocateDisabled() {
        return !this.canAllocate;
    }

    get reverseAllocationDisabled() {
        return !this.canReverseAllocation;
    }

    get canPreviewRun() {
        return Boolean(
            this.dashboard
            && this.dashboard.canRunRevaluation
            && this.selectedPeriodId
            && this.runKey
        );
    }

    get canApproveSelectedRun() {
        return Boolean(
            this.selectedRun
            && this.selectedRun.status
                === 'Preview'
            && this.dashboard
            && this.dashboard.canApproveRevaluation
        );
    }

    get canPostSelectedRun() {
        return Boolean(
            this.selectedRun
            && this.selectedRun.status
                === 'Approved'
            && this.dashboard
            && this.dashboard.canPostRevaluation
        );
    }

    get canReverseSelectedRun() {
        return Boolean(
            this.selectedRun
            && this.selectedRun.status
                === 'Posted'
            && this.dashboard
            && this.dashboard.canReverseRevaluation
        );
    }

    get manualRunReversal() {
        return Boolean(
            this.selectedRun
            && this.selectedRun.reversalPolicy
                === 'No Automatic Reversal'
        );
    }

    get canAuthorizePayment() {
        return Boolean(
            this.selectedPayment
            && this.selectedPayment.processingState
                === 'Draft'
            && this.dashboard
            && this.dashboard.canProcessForeignSettlement
        );
    }

    get canSubmitPayment() {
        return Boolean(
            this.selectedPayment
            && this.selectedPayment.processingState
                === 'Authorized'
            && this.providerRequestKey
            && this.dashboard
            && this.dashboard.canProcessForeignSettlement
        );
    }

    get canPostPayment() {
        return Boolean(
            this.selectedPayment
            && this.selectedPayment.processingState
                === 'Submitted'
            && this.dashboard
            && this.dashboard.canProcessForeignSettlement
        );
    }

    get canLoadTargets() {
        return Boolean(
            this.selectedPayment
            && this.selectedPayment.processingState
                === 'Succeeded'
            && this.selectedPayment.unallocatedAmount
                > 0
        );
    }

    get canAllocate() {
        return Boolean(
            this.selectedPayment
            && this.selectedTarget
            && this.allocationAmount
            && Number(
                this.allocationAmount
            ) > 0
            && Number(
                this.allocationAmount
            ) <= Number(
                this.selectedPayment.unallocatedAmount
            )
            && Number(
                this.allocationAmount
            ) <= Number(
                this.selectedTarget.outstandingAmount
            )
            && this.dashboard
            && this.dashboard.canProcessForeignSettlement
            && this.dashboard.canPostRealizedFX
        );
    }

    get canReverseAllocation() {
        return Boolean(
            this.selectedAllocation
            && this.selectedAllocation.status
                === 'Allocated'
            && this.allocationReversalDate
            && this.allocationReversalReason
            && this.dashboard
            && this.dashboard.canProcessForeignSettlement
            && this.dashboard.canReverseRealizedFX
        );
    }

    get hasEligibleTargets() {
        return this.eligibleTargets.length
            > 0;
    }

    get hasSelectedRun() {
        return Boolean(
            this.selectedRun
        );
    }

    get hasSelectedPayment() {
        return Boolean(
            this.selectedPayment
        );
    }

    get hasSelectedAllocation() {
        return Boolean(
            this.selectedAllocation
        );
    }

    get selectedPaymentSummary() {
        if (!this.selectedPayment) {
            return '';
        }

        return (
            this.selectedPayment.direction
            + ' · '
            + this.selectedPayment.amount
            + ' '
            + this.selectedPayment.transactionCurrency
            + ' · '
            + this.selectedPayment.processingState
        );
    }

    get selectedAllocationSummary() {
        if (!this.selectedAllocation) {
            return '';
        }

        return (
            this.selectedAllocation.targetType
            + ' · '
            + this.selectedAllocation.paymentAmount
            + ' '
            + this.selectedAllocation.transactionCurrency
            + ' · FX '
            + (
                this.selectedAllocation.realizedFXAmount
                    || 0
            )
        );
    }

    get realizedNetTotal() {
        if (!this.dashboard) {
            return 0;
        }

        return Number(
            this.dashboard.postedRealizedGainTotal
                || 0
        )
        - Number(
            this.dashboard.postedRealizedLossTotal
                || 0
        );
    }

    handlePeriodChange(event) {
        this.selectedPeriodId =
            event.detail.value;
    }

    handleRunKeyChange(event) {
        this.runKey =
            event.detail.value;
    }

    handleReversalPolicyChange(event) {
        this.reversalPolicy =
            event.detail.value;
    }

    handleRunReasonChange(event) {
        this.runReason =
            event.detail.value;
    }

    handleRunReversalPeriodChange(event) {
        this.runReversalPeriodId =
            event.detail.value;
    }

    handleRunReversalDateChange(event) {
        this.runReversalDate =
            event.detail.value;
    }

    handleRunReversalReasonChange(event) {
        this.runReversalReason =
            event.detail.value;
    }

    handleAllocationReversalDateChange(event) {
        this.allocationReversalDate =
            event.detail.value;
    }

    handleAllocationReversalReasonChange(event) {
        this.allocationReversalReason =
            event.detail.value;
    }

    handleProviderKeyChange(event) {
        this.providerRequestKey =
            event.detail.value;
    }

    handleAllocationAmountChange(event) {
        this.allocationAmount =
            event.detail.value;
    }

    handleAllocationDateChange(event) {
        this.allocationEffectiveDate =
            event.detail.value;
    }

    handleAllocationNotesChange(event) {
        this.allocationNotes =
            event.detail.value;
    }

    handleAllocationReasonChange(event) {
        this.allocationReason =
            event.detail.value;
    }

    handleRunSelection(event) {
        const rows =
            event.detail.selectedRows;

        this.selectedRunId =
            rows && rows.length
                ? rows[0].runId
                : undefined;

        if (
            this.selectedRun
            && this.selectedRun.reversalPolicy
                === 'No Automatic Reversal'
        ) {
            const laterOpenPeriods =
                this.dashboard.periods
                    .filter(
                        (period) =>
                            period.status
                                === 'Open'
                            && period.startDate
                                > this.selectedRun.periodEndDate
                    )
                    .sort(
                        (left, right) =>
                            left.startDate.localeCompare(
                                right.startDate
                            )
                    );

            const nextOpen =
                laterOpenPeriods.length
                    ? laterOpenPeriods[0]
                    : undefined;

            if (nextOpen) {
                this.runReversalPeriodId =
                    nextOpen.periodId;
                this.runReversalDate =
                    nextOpen.startDate;
            }
        }
    }

    async handlePaymentSelection(event) {
        const rows =
            event.detail.selectedRows;

        this.selectedPaymentId =
            rows && rows.length
                ? rows[0].paymentId
                : undefined;

        this.selectedTargetId =
            undefined;
        this.eligibleTargets =
            [];
        this.allocationAmount =
            undefined;

        if (this.selectedPayment) {
            this.allocationEffectiveDate =
                this.selectedPayment.effectiveDate;
            this.providerRequestKey =
                this.selectedPayment.providerRequestKey
                    || '';
        } else {
            this.providerRequestKey =
                '';
        }

        if (this.canLoadTargets) {
            await this.loadEligibleTargets();
        }
    }

    handleTargetSelection(event) {
        const rows =
            event.detail.selectedRows;

        this.selectedTargetId =
            rows && rows.length
                ? rows[0].targetId
                : undefined;

        if (this.selectedTarget) {
            const paymentRemaining =
                Number(
                    this.selectedPayment
                        .unallocatedAmount
                    || 0
                );

            const targetRemaining =
                Number(
                    this.selectedTarget
                        .outstandingAmount
                    || 0
                );

            this.allocationAmount =
                Math.min(
                    paymentRemaining,
                    targetRemaining
                );
        }
    }

    handleAllocationSelection(event) {
        const rows =
            event.detail.selectedRows;

        this.selectedAllocationId =
            rows && rows.length
                ? rows[0].allocationId
                : undefined;

        if (this.selectedAllocation) {
            this.allocationReversalDate =
                this.selectedAllocation
                    .effectiveDate;
        }
    }

    async loadEligibleTargets() {
        if (!this.selectedPaymentId) {
            return;
        }

        this.isLoading =
            true;
        this.errorMessage =
            undefined;

        try {
            const result =
                await getEligibleSettlementTargets({
                    paymentId:
                        this.selectedPaymentId
                });

            this.eligibleTargets =
                Array.isArray(result)
                    ? result
                    : [];
        } catch (error) {
            this.eligibleTargets =
                [];
            this.showError(
                error
            );
        } finally {
            this.isLoading =
                false;
        }
    }

    async handlePreview() {
        if (!this.canPreviewRun) {
            return;
        }

        await this.runAction(
            async () => {
                const request = {
                    companyId:
                        this.companyId,
                    accountingPeriodId:
                        this.selectedPeriodId,
                    runKey:
                        this.runKey.trim(),
                    reversalPolicy:
                        this.reversalPolicy
                };

                const result =
                    await previewRevaluation({
                        request
                    });

                this.selectedRunId =
                    result.runId;

                this.runKey =
                    this.generateRunKey();

                this.toast(
                    'FX Preview Created',
                    'FX revaluation preview is ready for review.',
                    'success'
                );
            }
        );
    }

    async handleApproveRun() {
        if (!this.canApproveSelectedRun) {
            return;
        }

        const key =
            this.getActionKey(
                'FX-APPROVE',
                this.selectedRunId
            );

        await this.runAction(
            async () => {
                await approveRun({
                    runId:
                        this.selectedRunId,
                    requestKey:
                        key,
                    reason:
                        this.runReason
                });

                this.clearActionKey(
                    'FX-APPROVE',
                    this.selectedRunId
                );

                this.toast(
                    'FX Run Approved',
                    'The preview snapshot is now locked and approved.',
                    'success'
                );
            }
        );
    }

    async handlePostRun() {
        if (!this.canPostSelectedRun) {
            return;
        }

        const key =
            this.getActionKey(
                'FX-POST',
                this.selectedRunId
            );

        await this.runAction(
            async () => {
                await postApprovedRun({
                    runId:
                        this.selectedRunId,
                    requestKey:
                        key,
                    reason:
                        this.runReason
                });

                this.clearActionKey(
                    'FX-POST',
                    this.selectedRunId
                );

                this.toast(
                    'FX Run Posted',
                    'The unrealized FX journal has been posted.',
                    'success'
                );
            }
        );
    }

    async handleReverseRun() {
        if (!this.canReverseSelectedRun) {
            return;
        }

        if (
            !this.runReversalReason
            || (
                this.manualRunReversal
                && (
                    !this.runReversalPeriodId
                    || !this.runReversalDate
                )
            )
        ) {
            this.toast(
                'Reversal Information Required',
                'Provide the required reversal reason, period and date.',
                'warning'
            );
            return;
        }

        const key =
            this.getActionKey(
                'FX-REVERSE',
                this.selectedRunId
            );

        await this.runAction(
            async () => {
                await reversePostedRun({
                    runId:
                        this.selectedRunId,
                    requestedReversalPeriodId:
                        this.manualRunReversal
                            ? this.runReversalPeriodId
                            : null,
                    requestedReversalDate:
                        this.manualRunReversal
                            ? this.runReversalDate
                            : null,
                    requestKey:
                        key,
                    reason:
                        this.runReversalReason
                });

                this.clearActionKey(
                    'FX-REVERSE',
                    this.selectedRunId
                );

                this.toast(
                    'FX Run Reversed',
                    'The posted revaluation journal has been reversed.',
                    'success'
                );
            }
        );
    }

    async handleAuthorizePayment() {
        if (!this.canAuthorizePayment) {
            return;
        }

        const key =
            this.getActionKey(
                'FCY-AUTH',
                this.selectedPaymentId
            );

        await this.runAction(
            async () => {
                await authorizeForeignPayment({
                    paymentId:
                        this.selectedPaymentId,
                    requestKey:
                        key
                });

                this.clearActionKey(
                    'FCY-AUTH',
                    this.selectedPaymentId
                );

                this.toast(
                    'Payment Authorized',
                    'Approved Spot rate was selected and snapshotted.',
                    'success'
                );
            }
        );
    }

    async handleSubmitPayment() {
        if (!this.canSubmitPayment) {
            return;
        }

        const key =
            this.getActionKey(
                'FCY-SUBMIT',
                this.selectedPaymentId
            );

        await this.runAction(
            async () => {
                await submitForeignPayment({
                    paymentId:
                        this.selectedPaymentId,
                    providerRequestKey:
                        this.providerRequestKey.trim(),
                    requestKey:
                        key
                });

                this.clearActionKey(
                    'FCY-SUBMIT',
                    this.selectedPaymentId
                );

                this.toast(
                    'Payment Submitted',
                    'The payment is ready for settlement posting.',
                    'success'
                );
            }
        );
    }

    async handlePostPayment() {
        if (!this.canPostPayment) {
            return;
        }

        const key =
            this.getActionKey(
                'FCY-POST',
                this.selectedPaymentId
            );

        await this.runAction(
            async () => {
                await postForeignPayment({
                    paymentId:
                        this.selectedPaymentId,
                    requestKey:
                        key
                });

                this.clearActionKey(
                    'FCY-POST',
                    this.selectedPaymentId
                );

                this.toast(
                    'Payment Posted',
                    'Foreign-currency cash settlement was posted at the snapshotted settlement rate.',
                    'success'
                );
            }
        );
    }

    async handleAllocate() {
        if (!this.canAllocate) {
            return;
        }

        const target =
            this.selectedTarget;

        const request = {
            invoiceId:
                target.targetType
                    === 'Invoice'
                    ? target.targetId
                    : null,
            supplierBillId:
                target.targetType
                    === 'Supplier Bill'
                    ? target.targetId
                    : null,
            amount:
                Number(
                    this.allocationAmount
                ),
            effectiveDate:
                this.allocationEffectiveDate
                    || this.selectedPayment
                        .effectiveDate,
            notes:
                this.allocationNotes
        };

        const key =
            this.getActionKey(
                'FCY-ALLOC',
                this.selectedPaymentId
                + '-'
                + target.targetId
            );

        await this.runAction(
            async () => {
                await allocateForeignPayment({
                    paymentId:
                        this.selectedPaymentId,
                    requests:
                        [request],
                    requestKey:
                        key,
                    reason:
                        this.allocationReason
                });

                this.clearActionKey(
                    'FCY-ALLOC',
                    this.selectedPaymentId
                    + '-'
                    + target.targetId
                );

                this.selectedTargetId =
                    undefined;
                this.allocationAmount =
                    undefined;
                this.allocationNotes =
                    '';

                this.toast(
                    'Payment Allocated',
                    'Allocation was created and realized FX was processed automatically.',
                    'success'
                );
            }
        );
    }

    async handleReverseAllocation() {
        if (!this.canReverseAllocation) {
            return;
        }

        const key =
            this.getActionKey(
                'FCY-ALLOC-REV',
                this.selectedAllocationId
            );

        await this.runAction(
            async () => {
                await reverseForeignAllocation({
                    allocationId:
                        this.selectedAllocationId,
                    reversalDate:
                        this.allocationReversalDate,
                    requestKey:
                        key,
                    reason:
                        this.allocationReversalReason
                });

                this.clearActionKey(
                    'FCY-ALLOC-REV',
                    this.selectedAllocationId
                );

                this.toast(
                    'Allocation Reversed',
                    'Realized FX was reversed first, then the allocation reversal was recorded.',
                    'success'
                );
            }
        );
    }

    async runAction(action) {
        this.isLoading =
            true;
        this.errorMessage =
            undefined;

        try {
            await action();
            await this.loadDashboard();

            if (
                this.selectedPaymentId
                && this.canLoadTargets
            ) {
                await this.loadEligibleTargets();
            }
        } catch (error) {
            this.showError(
                error
            );
        } finally {
            this.isLoading =
                false;
        }
    }

    handleRefresh() {
        this.loadDashboard();
    }

    handleNewPayment() {
        this[NavigationMixin.Navigate]({
            type:
                'standard__objectPage',
            attributes: {
                objectApiName:
                    'Accounting_Payment__c',
                actionName:
                    'new'
            },
            state: {
                defaultFieldValues:
                    encodeDefaultFieldValues({
                        Company__c:
                            this.companyId,
                        Functional_Currency__c:
                            this.functionalCurrency,
                        Processing_State__c:
                            'Draft'
                    })
            }
        });
    }

    handleOpenRunJournal() {
        if (
            this.selectedRun
            && this.selectedRun.journalEntryId
        ) {
            this.navigateToRecord(
                this.selectedRun.journalEntryId
            );
        }
    }

    handleOpenRunReversalJournal() {
        if (
            this.selectedRun
            && this.selectedRun
                .reversalJournalEntryId
        ) {
            this.navigateToRecord(
                this.selectedRun
                    .reversalJournalEntryId
            );
        }
    }

    handleOpenPayment() {
        if (this.selectedPaymentId) {
            this.navigateToRecord(
                this.selectedPaymentId
            );
        }
    }

    handleOpenPaymentJournal() {
        if (
            this.selectedPayment
            && this.selectedPayment.journalEntryId
        ) {
            this.navigateToRecord(
                this.selectedPayment
                    .journalEntryId
            );
        }
    }

    handleOpenAllocation() {
        if (this.selectedAllocationId) {
            this.navigateToRecord(
                this.selectedAllocationId
            );
        }
    }

    handleOpenRealizedFXJournal() {
        if (
            this.selectedAllocation
            && this.selectedAllocation
                .realizedFXJournalId
        ) {
            this.navigateToRecord(
                this.selectedAllocation
                    .realizedFXJournalId
            );
        }
    }

    handleOpenRealizedFXReversalJournal() {
        if (
            this.selectedAllocation
            && this.selectedAllocation
                .realizedFXReversalJournalId
        ) {
            this.navigateToRecord(
                this.selectedAllocation
                    .realizedFXReversalJournalId
            );
        }
    }

    navigateToRecord(recordId) {
        this[NavigationMixin.Navigate]({
            type:
                'standard__recordPage',
            attributes: {
                recordId,
                actionName:
                    'view'
            }
        });
    }

    getActionKey(action, recordId) {
        const mapKey =
            action
            + ':'
            + recordId;

        if (!this.actionKeys[mapKey]) {
            this.actionKeys = {
                ...this.actionKeys,
                [mapKey]:
                    action
                    + '-'
                    + Date.now()
                    + '-'
                    + String(
                        recordId
                    ).slice(
                        -18
                    )
            };
        }

        return this.actionKeys[mapKey];
    }

    clearActionKey(action, recordId) {
        const mapKey =
            action
            + ':'
            + recordId;

        const next = {
            ...this.actionKeys
        };

        delete next[mapKey];

        this.actionKeys =
            next;
    }

    generateRunKey() {
        const companyFragment =
            this.companyId
                ? String(
                    this.companyId
                ).slice(
                    -6
                )
                : 'COMP';

        return (
            'FX-'
            + companyFragment
            + '-'
            + Date.now()
        );
    }

    toast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title,
                message,
                variant
            })
        );
    }

    showError(error) {
        const message =
            this.reduceError(
                error
            );

        this.errorMessage =
            message;

        this.toast(
            'FX Operation Failed',
            message,
            'error'
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
            && Array.isArray(
                error.body
            )
        ) {
            return error.body
                .map(
                    (item) =>
                        item.message
                )
                .join(
                    ' | '
                );
        }

        if (error && error.message) {
            return error.message;
        }

        return 'The FX operation could not be completed.';
    }
}
