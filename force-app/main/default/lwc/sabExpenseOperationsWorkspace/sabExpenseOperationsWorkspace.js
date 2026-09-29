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
    from '@salesforce/apex/SABExpenseOperationsWorkspaceController.getDashboard';
import getClaimDetail
    from '@salesforce/apex/SABExpenseOperationsWorkspaceController.getClaimDetail';

import submitClaim
    from '@salesforce/apex/SABExpenseClaimLifecycleService.submitClaim';
import approveClaim
    from '@salesforce/apex/SABExpenseClaimLifecycleService.approveClaim';
import rejectClaim
    from '@salesforce/apex/SABExpenseClaimLifecycleService.rejectClaim';
import postApprovedClaim
    from '@salesforce/apex/SABExpenseClaimPostingService.postApprovedClaim';

import authorizePayment
    from '@salesforce/apex/SABExpenseReimbursementPaymentService.authorizePayment';
import submitPayment
    from '@salesforce/apex/SABExpenseReimbursementPaymentService.submitPayment';
import postPayment
    from '@salesforce/apex/SABExpenseReimbursementPaymentService.recordSucceededAndPost';

import settleClaim
    from '@salesforce/apex/SABExpenseClaimSettlementService.settleClaim';
import reverseSettlement
    from '@salesforce/apex/SABExpenseClaimSettlementService.reverseSettlement';

const STORAGE_KEY = 'sabSelectedAccountingCompanyId';

const CLAIM_COLUMNS = [
    { label: 'Claim', fieldName: 'name' },
    { label: 'Employee', fieldName: 'claimantName' },
    { label: 'Claim Date', fieldName: 'claimDate', type: 'date' },
    { label: 'Status', fieldName: 'status' },
    {
        label: 'Total',
        fieldName: 'totalAmount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'Paid',
        fieldName: 'paidAmount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'Remaining',
        fieldName: 'remainingAmount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    }
];

const LINE_COLUMNS = [
    { label: 'Date', fieldName: 'expenseDate', type: 'date' },
    { label: 'Category', fieldName: 'category' },
    { label: 'Description', fieldName: 'description' },
    {
        label: 'Amount',
        fieldName: 'amount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    { label: 'Expense Account', fieldName: 'expenseAccountCode' },
    { label: 'Tax Code', fieldName: 'taxCode' },
    {
        label: 'Tax %',
        fieldName: 'taxRatePercent',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 0,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'Tax',
        fieldName: 'taxAmount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'Recoverable',
        fieldName: 'recoverableTax',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    }
];

const PAYMENT_COLUMNS = [
    { label: 'Reference', fieldName: 'reference' },
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
    {
        label: 'Allocated',
        fieldName: 'allocatedAmount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    {
        label: 'Remaining',
        fieldName: 'remainingAmount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    { label: 'Effective Date', fieldName: 'effectiveDate', type: 'date' }
];

const SETTLEMENT_COLUMNS = [
    { label: 'Settlement', fieldName: 'name' },
    { label: 'Payment', fieldName: 'paymentReference' },
    {
        label: 'Amount',
        fieldName: 'allocatedAmount',
        type: 'number',
        typeAttributes: {
            minimumFractionDigits: 2,
            maximumFractionDigits: 4
        }
    },
    { label: 'Effective Date', fieldName: 'effectiveDate', type: 'date' },
    { label: 'Status', fieldName: 'status' },
    { label: 'Settlement Key', fieldName: 'settlementKey' }
];

export default class SabExpenseOperationsWorkspace extends NavigationMixin(LightningElement) {
    claimColumns = CLAIM_COLUMNS;
    lineColumns = LINE_COLUMNS;
    paymentColumns = PAYMENT_COLUMNS;
    settlementColumns = SETTLEMENT_COLUMNS;

    companyId;
    companyName;
    functionalCurrency;
    dashboard;
    claimDetail;
    subscription;

    selectedClaimId;
    selectedPaymentId;
    selectedSettlementId;

    reviewReason = '';
    providerRequestKey = '';
    settlementAmount;
    settlementKey = '';
    reversalSettlementKey = '';

    isLoading = false;
    errorMessage;
    actionKeys = {};

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        this.subscribeToCompanyContext();

        const storedCompanyId =
            window.sessionStorage.getItem(STORAGE_KEY);

        if (storedCompanyId) {
            this.companyId = storedCompanyId;
            this.loadDashboard();
        }
    }

    disconnectedCallback() {
        if (this.subscription) {
            unsubscribe(this.subscription);
            this.subscription = undefined;
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
                    this.handleCompanyContext(message),
                { scope: APPLICATION_SCOPE }
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
            this.companyId !== message.companyId;

        this.companyId = message.companyId;
        this.companyName = message.companyName;
        this.functionalCurrency =
            message.functionalCurrency;

        if (changed) {
            this.resetSelections();
            await this.loadDashboard();
        }
    }

    clearWorkspace() {
        this.companyId = undefined;
        this.companyName = undefined;
        this.functionalCurrency = undefined;
        this.dashboard = undefined;
        this.claimDetail = undefined;
        this.resetSelections();
    }

    resetSelections() {
        this.selectedClaimId = undefined;
        this.selectedPaymentId = undefined;
        this.selectedSettlementId = undefined;
        this.claimDetail = undefined;
        this.reviewReason = '';
        this.providerRequestKey = '';
        this.settlementAmount = undefined;
        this.settlementKey = '';
        this.reversalSettlementKey = '';
        this.actionKeys = {};
    }

    async loadDashboard() {
        if (!this.companyId) {
            return;
        }

        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            const result =
                await getDashboard({
                    companyId: this.companyId
                });

            this.dashboard = result;
            this.companyName = result.companyName;
            this.functionalCurrency =
                result.functionalCurrency;

            this.restoreSelections();

            if (this.selectedClaimId) {
                await this.loadClaimDetail();
            }
        } catch (error) {
            this.errorMessage =
                this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async loadClaimDetail() {
        if (!this.selectedClaimId) {
            this.claimDetail = undefined;
            return;
        }

        try {
            this.claimDetail =
                await getClaimDetail({
                    claimId: this.selectedClaimId
                });

            this.restoreSettlementSelection();
        } catch (error) {
            this.errorMessage =
                this.reduceError(error);
        }
    }

    restoreSelections() {
        if (
            this.selectedClaimId
            && !this.claims.some(
                (row) =>
                    row.claimId === this.selectedClaimId
            )
        ) {
            this.selectedClaimId = undefined;
            this.claimDetail = undefined;
        }

        if (
            this.selectedPaymentId
            && !this.payments.some(
                (row) =>
                    row.paymentId === this.selectedPaymentId
            )
        ) {
            this.selectedPaymentId = undefined;
        }
    }

    restoreSettlementSelection() {
        if (
            this.selectedSettlementId
            && !this.settlements.some(
                (row) =>
                    row.settlementId ===
                        this.selectedSettlementId
            )
        ) {
            this.selectedSettlementId = undefined;
        }
    }

    get hasCompany() {
        return Boolean(this.companyId);
    }

    get hasDashboard() {
        return Boolean(this.dashboard);
    }

    get claims() {
        return this.dashboard
            && Array.isArray(this.dashboard.claims)
            ? this.dashboard.claims
            : [];
    }

    get payments() {
        return this.dashboard
            && Array.isArray(
                this.dashboard.reimbursementPayments
            )
            ? this.dashboard.reimbursementPayments
            : [];
    }

    get claimLines() {
        return this.claimDetail
            && Array.isArray(this.claimDetail.lines)
            ? this.claimDetail.lines
            : [];
    }

    get settlements() {
        return this.claimDetail
            && Array.isArray(
                this.claimDetail.settlements
            )
            ? this.claimDetail.settlements
            : [];
    }

    get selectedClaim() {
        return this.claims.find(
            (row) =>
                row.claimId === this.selectedClaimId
        );
    }

    get selectedPayment() {
        return this.payments.find(
            (row) =>
                row.paymentId === this.selectedPaymentId
        );
    }

    get selectedSettlement() {
        return this.settlements.find(
            (row) =>
                row.settlementId ===
                    this.selectedSettlementId
        );
    }

    get selectedClaimRows() {
        return this.selectedClaimId
            ? [this.selectedClaimId]
            : [];
    }

    get selectedPaymentRows() {
        return this.selectedPaymentId
            ? [this.selectedPaymentId]
            : [];
    }

    get selectedSettlementRows() {
        return this.selectedSettlementId
            ? [this.selectedSettlementId]
            : [];
    }

    get hasSelectedClaim() {
        return Boolean(this.selectedClaim);
    }

    get hasSelectedPayment() {
        return Boolean(this.selectedPayment);
    }

    get hasSelectedSettlement() {
        return Boolean(this.selectedSettlement);
    }

    get canAddLine() {
        return Boolean(
            this.selectedClaim
            && this.selectedClaim.status === 'Draft'
        );
    }

    get canSubmit() {
        return Boolean(
            this.selectedClaim
            && this.selectedClaim.status === 'Draft'
            && this.dashboard
            && this.dashboard.canSubmitClaim
        );
    }

    get canApprove() {
        return Boolean(
            this.selectedClaim
            && this.selectedClaim.status === 'Submitted'
            && this.dashboard
            && this.dashboard.canReviewClaim
        );
    }

    get canReject() {
        return Boolean(
            this.canApprove
            && this.reviewReason
        );
    }

    get canPost() {
        return Boolean(
            this.selectedClaim
            && this.selectedClaim.status === 'Approved'
            && this.dashboard
            && this.dashboard.canPostClaim
        );
    }

    get canAuthorizePayment() {
        return Boolean(
            this.selectedPayment
            && this.selectedPayment.processingState === 'Draft'
            && this.dashboard
            && this.dashboard.canProcessReimbursement
        );
    }

    get canSubmitPayment() {
        return Boolean(
            this.selectedPayment
            && this.selectedPayment.processingState === 'Authorized'
            && this.providerRequestKey
            && this.dashboard
            && this.dashboard.canProcessReimbursement
        );
    }

    get canPostPayment() {
        return Boolean(
            this.selectedPayment
            && this.selectedPayment.processingState === 'Submitted'
            && this.dashboard
            && this.dashboard.canProcessReimbursement
        );
    }

    get canSettle() {
        return Boolean(
            this.selectedClaim
            && (
                this.selectedClaim.status === 'Posted'
                || this.selectedClaim.status === 'Part Paid'
            )
            && this.selectedPayment
            && this.selectedPayment.processingState === 'Succeeded'
            && Number(this.settlementAmount) > 0
            && this.settlementKey
            && this.dashboard
            && this.dashboard.canProcessReimbursement
        );
    }

    get canReverseSettlement() {
        return Boolean(
            this.selectedSettlement
            && !this.selectedSettlement.reversalOfId
            && Number(
                this.selectedSettlement.allocatedAmount
            ) > 0
            && this.selectedSettlement.status === 'Effective'
            && this.reversalSettlementKey
            && this.dashboard
            && this.dashboard.canProcessReimbursement
        );
    }

    get addLineDisabled() { return !this.canAddLine; }
    get submitDisabled() { return !this.canSubmit; }
    get approveDisabled() { return !this.canApprove; }
    get rejectDisabled() { return !this.canReject; }
    get postDisabled() { return !this.canPost; }
    get authorizePaymentDisabled() { return !this.canAuthorizePayment; }
    get submitPaymentDisabled() { return !this.canSubmitPayment; }
    get postPaymentDisabled() { return !this.canPostPayment; }
    get settleDisabled() { return !this.canSettle; }
    get reverseSettlementDisabled() { return !this.canReverseSettlement; }

    get claimValidationFeedback() {
        if (!this.selectedClaim) {
            return '';
        }

        if (
            this.selectedClaim.status === 'Draft'
            && this.selectedClaim.lineCount === 0
        ) {
            return 'Add at least one claim line before submission.';
        }

        if (this.selectedClaim.status === 'Draft') {
            return 'Draft claim is ready for lifecycle validation on Submit.';
        }

        if (this.selectedClaim.status === 'Submitted') {
            return 'Submitted claim is awaiting finance review.';
        }

        if (this.selectedClaim.status === 'Approved') {
            return 'Approved claim is ready for accounting posting.';
        }

        if (
            this.selectedClaim.status === 'Posted'
            || this.selectedClaim.status === 'Part Paid'
        ) {
            return 'Claim is posted and awaiting reimbursement settlement.';
        }

        if (this.selectedClaim.status === 'Paid') {
            return 'Claim is fully reimbursed.';
        }

        return `Claim status: ${this.selectedClaim.status}`;
    }

    handleClaimSelection(event) {
        const rows = event.detail.selectedRows;
        this.selectedClaimId =
            rows.length ? rows[0].claimId : undefined;
        this.selectedSettlementId = undefined;
        this.loadClaimDetail();
    }

    handlePaymentSelection(event) {
        const rows = event.detail.selectedRows;
        this.selectedPaymentId =
            rows.length ? rows[0].paymentId : undefined;
    }

    handleSettlementSelection(event) {
        const rows = event.detail.selectedRows;
        this.selectedSettlementId =
            rows.length
                ? rows[0].settlementId
                : undefined;
    }

    handleReviewReasonChange(event) {
        this.reviewReason = event.target.value;
    }

    handleProviderKeyChange(event) {
        this.providerRequestKey =
            event.target.value;
    }

    handleSettlementAmountChange(event) {
        this.settlementAmount =
            event.target.value;
    }

    handleSettlementKeyChange(event) {
        this.settlementKey =
            event.target.value;
    }

    handleReversalSettlementKeyChange(event) {
        this.reversalSettlementKey =
            event.target.value;
    }

    async handleRefresh() {
        await this.loadDashboard();
    }

    handleNewClaim() {
        const defaultValues =
            encodeDefaultFieldValues({
                Company__c: this.companyId,
                Currency__c: this.functionalCurrency
            });

        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Expense_Claim__c',
                actionName: 'new'
            },
            state: {
                defaultFieldValues: defaultValues
            }
        });
    }

    handleAddClaimLine() {
        if (!this.selectedClaimId) {
            return;
        }

        const defaultValues =
            encodeDefaultFieldValues({
                Expense_Claim__c: this.selectedClaimId
            });

        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Expense_Claim_Line__c',
                actionName: 'new'
            },
            state: {
                defaultFieldValues: defaultValues
            }
        });
    }

    handleNewPayment() {
        const defaultValues =
            encodeDefaultFieldValues({
                Company__c: this.companyId,
                Direction__c: 'Disbursement',
                Transaction_Currency__c:
                    this.functionalCurrency,
                Functional_Currency__c:
                    this.functionalCurrency
            });

        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Accounting_Payment__c',
                actionName: 'new'
            },
            state: {
                defaultFieldValues: defaultValues
            }
        });
    }

    handleOpenClaim() {
        this.openRecord(
            'Expense_Claim__c',
            this.selectedClaimId
        );
    }

    handleOpenClaimJournal() {
        if (this.selectedClaim) {
            this.openRecord(
                'Journal_Entry__c',
                this.selectedClaim.journalEntryId
            );
        }
    }

    handleOpenPayment() {
        this.openRecord(
            'Accounting_Payment__c',
            this.selectedPaymentId
        );
    }

    handleOpenPaymentJournal() {
        if (this.selectedPayment) {
            this.openRecord(
                'Journal_Entry__c',
                this.selectedPayment.journalEntryId
            );
        }
    }

    async handleSubmitClaim() {
        await this.runAction(
            () =>
                submitClaim({
                    claimId: this.selectedClaimId,
                    requestKey:
                        this.actionKey('SUBMIT')
                }),
            'Expense Claim submitted.'
        );
    }

    async handleApproveClaim() {
        await this.runAction(
            () =>
                approveClaim({
                    claimId: this.selectedClaimId,
                    requestKey:
                        this.actionKey('APPROVE'),
                    reason:
                        this.reviewReason || null
                }),
            'Expense Claim approved.'
        );
    }

    async handleRejectClaim() {
        await this.runAction(
            () =>
                rejectClaim({
                    claimId: this.selectedClaimId,
                    requestKey:
                        this.actionKey('REJECT'),
                    reason: this.reviewReason
                }),
            'Expense Claim rejected.'
        );
    }

    async handlePostClaim() {
        await this.runAction(
            () =>
                postApprovedClaim({
                    request: {
                        expenseClaimId:
                            this.selectedClaimId,
                        requestKey:
                            this.actionKey('POST')
                    }
                }),
            'Expense Claim posted.'
        );
    }

    async handleAuthorizePayment() {
        await this.runAction(
            () =>
                authorizePayment({
                    paymentId:
                        this.selectedPaymentId,
                    requestKey:
                        this.actionKey('PAYAUTH')
                }),
            'Reimbursement Payment authorized.'
        );
    }

    async handleSubmitPayment() {
        await this.runAction(
            () =>
                submitPayment({
                    paymentId:
                        this.selectedPaymentId,
                    providerRequestKey:
                        this.providerRequestKey,
                    requestKey:
                        this.actionKey('PAYSUBMIT')
                }),
            'Reimbursement Payment submitted.'
        );
    }

    async handlePostPayment() {
        await this.runAction(
            () =>
                postPayment({
                    paymentId:
                        this.selectedPaymentId,
                    requestKey:
                        this.actionKey('PAYPOST')
                }),
            'Reimbursement Payment posted.'
        );
    }

    async handleSettleClaim() {
        await this.runAction(
            () =>
                settleClaim({
                    request: {
                        expenseClaimId:
                            this.selectedClaimId,
                        paymentId:
                            this.selectedPaymentId,
                        amount:
                            Number(this.settlementAmount),
                        settlementKey:
                            this.settlementKey
                    }
                }),
            'Expense Claim settlement recorded.'
        );

        this.settlementAmount = undefined;
        this.settlementKey = '';
    }

    async handleReverseSettlement() {
        await this.runAction(
            () =>
                reverseSettlement({
                    settlementId:
                        this.selectedSettlementId,
                    reversalSettlementKey:
                        this.reversalSettlementKey
                }),
            'Expense Claim settlement reversed.'
        );

        this.reversalSettlementKey = '';
    }

    async runAction(action, successMessage) {
        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            await action();
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Success',
                    message: successMessage,
                    variant: 'success'
                })
            );
            await this.loadDashboard();
        } catch (error) {
            const message =
                this.reduceError(error);
            this.errorMessage = message;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Expense Operations',
                    message,
                    variant: 'error'
                })
            );
        } finally {
            this.isLoading = false;
        }
    }

    actionKey(prefix) {
        const sourceId =
            this.selectedClaimId
            || this.selectedPaymentId
            || 'WORKSPACE';

        const keyName =
            `${prefix}|${sourceId}`;

        if (!this.actionKeys[keyName]) {
            this.actionKeys[keyName] =
                `${keyName}|${Date.now()}`;
        }

        return this.actionKeys[keyName];
    }

    openRecord(objectApiName, recordId) {
        if (!recordId) {
            return;
        }

        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId,
                objectApiName,
                actionName: 'view'
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

        if (error && error.message) {
            return error.message;
        }

        return 'An unexpected Expense Operations error occurred.';
    }
}
