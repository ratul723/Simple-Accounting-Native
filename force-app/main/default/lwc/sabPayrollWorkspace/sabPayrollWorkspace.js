import { LightningElement, wire } from 'lwc';
import { subscribe, unsubscribe, MessageContext, APPLICATION_SCOPE } from 'lightning/messageService';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import COMPANY_CONTEXT_CHANNEL from '@salesforce/messageChannel/SABCompanyContext__c';

import getWorkspace from '@salesforce/apex/SABPayrollWorkspaceController.getWorkspace';
import getRunDetail from '@salesforce/apex/SABPayrollWorkspaceController.getRunDetail';
import getHrQueue from '@salesforce/apex/SABPayrollWorkspaceController.getHrQueue';

import createDraftForWorkspace from '@salesforce/apex/SABPayrollCalculationService.createDraftForWorkspace';
import calculateRun from '@salesforce/apex/SABPayrollCalculationService.calculate';
import submitRun from '@salesforce/apex/SABPayrollReviewService.submit';
import approveRun from '@salesforce/apex/SABPayrollReviewService.approve';
import cancelRun from '@salesforce/apex/SABPayrollReviewService.cancel';
import postRun from '@salesforce/apex/SABPayrollPostingService.post';

import preparePayment from '@salesforce/apex/SABPayrollSettlementService.preparePayment';
import authorizePayment from '@salesforce/apex/SABPayrollSettlementService.authorizePayment';
import submitPayment from '@salesforce/apex/SABPayrollSettlementService.submitPayment';
import recordPaymentSucceeded from '@salesforce/apex/SABPayrollSettlementService.recordPaymentSucceeded';
import recordPaymentFailed from '@salesforce/apex/SABPayrollSettlementService.recordPaymentFailed';
import recordLineReturn from '@salesforce/apex/SABPayrollSettlementService.recordLineReturn';

import approveAssignment from '@salesforce/apex/SABEmployeeCompensationService.approveAssignment';
import approveBenefitAward from '@salesforce/apex/SABEmployeeCompensationService.approveBenefitAward';
import cancelBenefitAward from '@salesforce/apex/SABEmployeeCompensationService.cancelBenefitAward';

const STORAGE_KEY = 'sabSelectedAccountingCompanyId';
const CANCELLABLE = ['Draft', 'Calculated', 'Submitted', 'Approved'];
const IN_FLIGHT = ['Draft', 'Authorized', 'Submitted'];
const MONEY = { type: 'number', typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 } };

const RUN_COLUMNS = [
    { label: 'Run', fieldName: 'name' },
    { label: 'Run Key', fieldName: 'runKey' },
    { label: 'Period Start', fieldName: 'periodStart', type: 'date-local' },
    { label: 'Period End', fieldName: 'periodEnd', type: 'date-local' },
    { label: 'State', fieldName: 'state' },
    { label: 'Net Pay', fieldName: 'netTotal', ...MONEY },
    { label: 'Settled', fieldName: 'settledAmount', ...MONEY },
    { label: 'Outstanding', fieldName: 'outstandingAmount', ...MONEY },
    { label: 'Payment', fieldName: 'paymentState' }
];

const LINE_COLUMNS = [
    { label: 'Employee', fieldName: 'employeeReference' },
    { label: 'Gross', fieldName: 'grossAmount', ...MONEY },
    { label: 'Deductions', fieldName: 'deductionAmount', ...MONEY },
    { label: 'Employer', fieldName: 'employerContribution', ...MONEY },
    { label: 'Net', fieldName: 'netAmount', ...MONEY },
    { label: 'Settled', fieldName: 'settledAmount', ...MONEY },
    { label: 'Outstanding', fieldName: 'outstandingAmount', ...MONEY }
];

const AWARD_LINE_COLUMNS = [
    { label: 'Award', fieldName: 'awardKey' },
    { label: 'Employee', fieldName: 'employeeReference' },
    { label: 'Category', fieldName: 'category' },
    { label: 'Amount', fieldName: 'amount', ...MONEY }
];

const ASSIGNMENT_COLUMNS = [
    { label: 'Employee', fieldName: 'employeeReference' },
    { label: 'Component', fieldName: 'componentName' },
    { label: 'Category', fieldName: 'category' },
    { label: 'Amount', fieldName: 'amount', ...MONEY },
    { label: 'Currency', fieldName: 'currencyCode' },
    { label: 'From', fieldName: 'effectiveFrom', type: 'date-local' },
    { label: 'To', fieldName: 'effectiveTo', type: 'date-local' }
];

const AWARD_COLUMNS = [
    { label: 'Award', fieldName: 'awardKey' },
    { label: 'Employee', fieldName: 'employeeReference' },
    { label: 'Component', fieldName: 'componentName' },
    { label: 'Amount', fieldName: 'amount', ...MONEY },
    { label: 'Service Start', fieldName: 'serviceStart', type: 'date-local' },
    { label: 'Status', fieldName: 'status' }
];

export default class SabPayrollWorkspace extends LightningElement {
    runColumns = RUN_COLUMNS;
    lineColumns = LINE_COLUMNS;
    awardLineColumns = AWARD_LINE_COLUMNS;
    assignmentColumns = ASSIGNMENT_COLUMNS;
    awardColumns = AWARD_COLUMNS;

    companyId;
    workspace;
    runDetail;
    hrQueue;
    subscription;
    isLoading = false;
    errorMessage;

    selectedRunId;
    selectedAssignmentId;
    selectedAwardId;

    // Form state
    showNewRunModal = false;
    newRunStart;
    newRunEnd;
    selectedEmploymentIds = [];
    minorUnits = 2;
    cancelReason = '';
    postPeriodId;
    postDate;
    payableAccountId;
    paymentBankId;
    paymentDate;
    paymentMethod;
    paymentReference = '';
    providerKey = '';
    failReason = '';
    returnSettlementId;
    returnDate;
    returnReason = '';

    // Request keys survive a failed attempt (so a retry replays) and are discarded after success.
    requestKeys = {};

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        this.subscribeToCompanyContext();
        const stored = window.sessionStorage.getItem(STORAGE_KEY);
        if (stored) {
            this.companyId = stored;
            this.refresh();
        }
    }

    disconnectedCallback() {
        if (this.subscription) {
            unsubscribe(this.subscription);
            this.subscription = undefined;
        }
    }

    subscribeToCompanyContext() {
        if (this.subscription || !this.messageContext) {
            return;
        }
        this.subscription = subscribe(this.messageContext, COMPANY_CONTEXT_CHANNEL,
            (message) => this.handleCompanyContext(message), { scope: APPLICATION_SCOPE });
    }

    handleCompanyContext(message) {
        if (!message || message.companyCleared) {
            this.companyId = undefined;
            this.workspace = undefined;
            this.hrQueue = undefined;
            this.showNewRunModal = false;
            this.resetNewRunForm();
            this.resetSelection();
            return;
        }
        if (message.companyId && message.companyId !== this.companyId) {
            this.companyId = message.companyId;
            this.showNewRunModal = false;
            this.resetNewRunForm();
            this.resetSelection();
            this.requestKeys = {};
            this.refresh();
        }
    }

    resetSelection() {
        this.selectedRunId = undefined;
        this.runDetail = undefined;
        this.selectedAssignmentId = undefined;
        this.selectedAwardId = undefined;
    }

    // ------------------------------------------------------------- loading

    async refresh() {
        if (!this.companyId) {
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            this.workspace = await getWorkspace({ companyId: this.companyId });
            if (this.selectedEmploymentIds.length === 0) {
                this.selectedEmploymentIds = this.employments.map((row) => row.employmentId);
            }
            if (this.selectedRunId && !this.runs.some((row) => row.runId === this.selectedRunId)) {
                this.resetSelection();
            }
            if (this.selectedRunId) {
                await this.loadRunDetail();
            }
            await this.loadHrQueue();
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async loadRunDetail() {
        if (!this.selectedRunId) {
            this.runDetail = undefined;
            return;
        }
        this.runDetail = await getRunDetail({ runId: this.selectedRunId });
        this.applyDefaults();
    }

    async loadHrQueue() {
        try {
            this.hrQueue = await getHrQueue({ companyId: this.companyId });
        } catch {
            // Payroll users without compensation access still get the payroll tabs.
            this.hrQueue = undefined;
        }
    }

    applyDefaults() {
        const run = this.selectedRun;
        if (!run) {
            return;
        }
        if (!this.postDate) {
            this.postDate = run.periodEnd;
        }
        if (!this.postPeriodId) {
            const period = this.openPeriods.find((p) => p.startDate <= run.periodEnd && p.endDate >= run.periodEnd);
            this.postPeriodId = period ? period.value : undefined;
        }
        if (!this.paymentDate) {
            this.paymentDate = run.accountingDate || run.periodEnd;
        }
        if (!this.returnDate) {
            this.returnDate = this.paymentDate;
        }
    }

    // ------------------------------------------------------------- getters

    get hasCompany() {
        return Boolean(this.companyId);
    }

    get hasWorkspace() {
        return Boolean(this.workspace);
    }

    get companyName() {
        return this.workspace ? this.workspace.companyName : '';
    }

    get functionalCurrency() {
        return this.workspace ? this.workspace.functionalCurrency : '';
    }

    get outstandingNetPay() {
        return this.workspace ? this.workspace.outstandingNetPay : 0;
    }

    get can() {
        return (this.workspace && this.workspace.capabilities) || {};
    }

    get runs() {
        return (this.workspace && this.workspace.runs) || [];
    }

    get hasRuns() {
        return this.runs.length > 0;
    }

    get stateCounts() {
        return (this.workspace && this.workspace.stateCounts) || [];
    }

    get employments() {
        return (this.workspace && this.workspace.employments) || [];
    }

    get eligibleEmploymentCount() {
        return this.employments.length;
    }

    get employmentOptions() {
        return this.employments.map((row) => ({
            label: row.departmentName ? `${row.employeeReference} (${row.departmentName})` : row.employeeReference,
            value: row.employmentId
        }));
    }

    get openPeriods() {
        return (this.workspace && this.workspace.openPeriods) || [];
    }

    get payableAccounts() {
        return (this.workspace && this.workspace.payableAccounts) || [];
    }

    get bankAccounts() {
        return (this.workspace && this.workspace.bankAccounts) || [];
    }

    get paymentMethods() {
        return (this.workspace && this.workspace.paymentMethods) || [];
    }

    get selectedRunRows() {
        return this.selectedRunId ? [this.selectedRunId] : [];
    }

    get selectedRun() {
        return this.runDetail ? this.runDetail.run : undefined;
    }

    get hasSelectedRun() {
        return Boolean(this.selectedRun);
    }

    get runState() {
        return this.selectedRun ? this.selectedRun.state : undefined;
    }

    get runLines() {
        return (this.runDetail && this.runDetail.lines) || [];
    }

    get runAwards() {
        return (this.runDetail && this.runDetail.awards) || [];
    }

    get hasRunAwards() {
        return this.runAwards.length > 0;
    }

    get payment() {
        return this.runDetail ? this.runDetail.payment : undefined;
    }

    get hasPayment() {
        return Boolean(this.payment);
    }

    get paymentState() {
        return this.payment ? this.payment.state : undefined;
    }

    get isDraft() {
        return this.runState === 'Draft';
    }

    get isCalculated() {
        return this.runState === 'Calculated';
    }

    get isSubmitted() {
        return this.runState === 'Submitted';
    }

    get isApproved() {
        return this.runState === 'Approved';
    }

    get isPosted() {
        return this.runState === 'Posted';
    }

    get isCancellable() {
        return CANCELLABLE.includes(this.runState);
    }

    get canPrepareFlow() {
        return this.isPosted && (!this.hasPayment || !IN_FLIGHT.includes(this.paymentState));
    }

    get paymentIsDraft() {
        return this.isPosted && this.paymentState === 'Draft';
    }

    get paymentIsAuthorized() {
        return this.isPosted && this.paymentState === 'Authorized';
    }

    get paymentIsSubmitted() {
        return this.isPosted && this.paymentState === 'Submitted';
    }

    get paymentInFlight() {
        return this.isPosted && IN_FLIGHT.includes(this.paymentState);
    }

    get returnOptions() {
        return this.runLines
            .filter((line) => line.effectiveSettlementId)
            .map((line) => ({ label: `${line.employeeReference} (${line.settledAmount})`, value: line.effectiveSettlementId }));
    }

    get hasReturnOptions() {
        return this.returnOptions.length > 0 && this.paymentState === 'Succeeded';
    }

    get pendingAssignments() {
        return (this.hrQueue && this.hrQueue.pendingAssignments) || [];
    }

    get awards() {
        return (this.hrQueue && this.hrQueue.awards) || [];
    }

    get hasHrQueue() {
        return Boolean(this.hrQueue);
    }

    get selectedAward() {
        return this.awards.find((row) => row.awardId === this.selectedAwardId);
    }

    get newRunDateInvalid() {
        return Boolean(this.newRunStart && this.newRunEnd && this.newRunEnd < this.newRunStart);
    }

    get newRunButtonDisabled() {
        return this.isLoading || !this.can.calculate;
    }

    // Disabled flags: capability AND state AND not busy. The services re-check everything.
    get createDisabled() {
        return this.isLoading || !this.can.calculate || !this.newRunStart || !this.newRunEnd
            || this.newRunDateInvalid;
    }

    get calculateDisabled() {
        return this.isLoading || !this.can.calculate || this.selectedEmploymentIds.length === 0;
    }

    get submitDisabled() {
        return this.isLoading || !this.can.submit;
    }

    get approveDisabled() {
        return this.isLoading || !this.can.approve;
    }

    get cancelDisabled() {
        return this.isLoading || !this.can.cancel || !this.cancelReason;
    }

    get postDisabled() {
        return this.isLoading || !this.can.postPayroll || !this.can.postJournal
            || !this.postPeriodId || !this.postDate || !this.payableAccountId;
    }

    get prepareDisabled() {
        return this.isLoading || !this.can.processPayment || !this.paymentBankId || !this.paymentDate || !this.paymentMethod;
    }

    get authorizeDisabled() {
        return this.isLoading || !this.can.authorizePayment;
    }

    get submitPaymentDisabled() {
        return this.isLoading || !this.can.processPayment || !this.providerKey;
    }

    get succeededDisabled() {
        return this.isLoading || !this.can.processPayment || !this.can.postJournal;
    }

    get failDisabled() {
        return this.isLoading || !this.can.processPayment || !this.failReason;
    }

    get returnDisabled() {
        return this.isLoading || !this.can.processPayment || !this.can.postJournal
            || !this.returnSettlementId || !this.returnDate || !this.returnReason;
    }

    get approveAssignmentDisabled() {
        return this.isLoading || !this.can.approveCompensation || !this.selectedAssignmentId;
    }

    get approveAwardDisabled() {
        return this.isLoading || !this.can.approveCompensation || !this.selectedAward || this.selectedAward.status !== 'Proposed';
    }

    get cancelAwardDisabled() {
        return this.isLoading || !this.can.manageCompensation || !this.selectedAward || this.selectedAward.status === 'Consumed';
    }

    // ------------------------------------------------------------- handlers

    handleRefresh() {
        this.refresh();
    }

    handleFieldChange(event) {
        const field = event.target.dataset.field;
        this[field] = event.detail.value;
    }

    handleOpenNewRun() {
        this.resetNewRunForm();
        this.showNewRunModal = true;
    }

    handleCloseNewRun() {
        if (this.isLoading) {
            return;
        }
        this.showNewRunModal = false;
        this.resetNewRunForm();
    }

    resetNewRunForm() {
        this.newRunStart = undefined;
        this.newRunEnd = undefined;
    }

    handleNewRunStart(event) {
        this.newRunStart = event.detail.value;
    }

    async handleRunSelection(event) {
        const rows = event.detail.selectedRows || [];
        const runId = rows.length ? rows[0].runId : undefined;
        if (runId === this.selectedRunId) {
            return;
        }
        this.selectedRunId = runId;
        this.clearRunForm();
        this.isLoading = true;
        try {
            await this.loadRunDetail();
        } catch (error) {
            this.notifyError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleAssignmentSelection(event) {
        const rows = event.detail.selectedRows || [];
        this.selectedAssignmentId = rows.length ? rows[0].assignmentId : undefined;
    }

    handleAwardSelection(event) {
        const rows = event.detail.selectedRows || [];
        this.selectedAwardId = rows.length ? rows[0].awardId : undefined;
    }

    clearRunForm() {
        this.cancelReason = '';
        this.postPeriodId = undefined;
        this.postDate = undefined;
        this.paymentDate = undefined;
        this.paymentReference = '';
        this.providerKey = '';
        this.failReason = '';
        this.returnSettlementId = undefined;
        this.returnDate = undefined;
        this.returnReason = '';
    }

    handleCreateDraft() {
        return this.runAction('DRAFT', this.companyId, async () => {
            const runId = await createDraftForWorkspace({ companyId: this.companyId, periodStart: this.newRunStart,
                periodEnd: this.newRunEnd, currencyCode: this.workspace.functionalCurrency });
            this.selectedRunId = runId;
            this.showNewRunModal = false;
            this.resetNewRunForm();
        }, 'Draft payroll run created.');
    }

    handleCalculate() {
        return this.runAction('CALCULATE', this.selectedRunId, () => calculateRun({ runId: this.selectedRunId,
            employmentIds: this.selectedEmploymentIds, minorUnits: Number(this.minorUnits) }), 'Payroll calculated.');
    }

    handleSubmit() {
        return this.runAction('SUBMIT', this.selectedRunId, () => submitRun({ runId: this.selectedRunId }),
            'Payroll submitted for approval.');
    }

    handleApprove() {
        return this.runAction('APPROVE', this.selectedRunId, () => approveRun({ runId: this.selectedRunId }), 'Payroll approved.');
    }

    handleCancel() {
        return this.runAction('CANCEL', this.selectedRunId, () => cancelRun({ runId: this.selectedRunId, reason: this.cancelReason }),
            'Payroll cancelled; consumed awards were released.');
    }

    handlePost() {
        return this.runAction('POST', this.selectedRunId, (key) => postRun({ runId: this.selectedRunId,
            periodId: this.postPeriodId, accountingDate: this.postDate, payableAccountId: this.payableAccountId, requestKey: key }),
        'Payroll accrual posted.');
    }

    handlePrepare() {
        return this.runAction('PREPARE', this.selectedRunId, (key) => preparePayment({ runId: this.selectedRunId,
            bankAccountId: this.paymentBankId, paymentDate: this.paymentDate, method: this.paymentMethod,
            reference: this.paymentReference, requestKey: key }), 'Net-pay payment prepared.');
    }

    handleAuthorize() {
        return this.runAction('AUTHORIZE', this.payment.paymentId, (key) => authorizePayment({ runId: this.selectedRunId,
            requestKey: key }), 'Payment authorized.');
    }

    handleSubmitPayment() {
        return this.runAction('PAYSUBMIT', this.payment.paymentId, (key) => submitPayment({ runId: this.selectedRunId,
            providerRequestKey: this.providerKey, requestKey: key }), 'Payment submitted to the bank.');
    }

    handleSucceeded() {
        return this.runAction('SUCCEEDED', this.payment.paymentId, (key) => recordPaymentSucceeded({ runId: this.selectedRunId,
            requestKey: key }), 'Payment succeeded; payroll settled.');
    }

    handleFailed() {
        return this.runAction('FAILED', this.payment.paymentId, (key) => recordPaymentFailed({ runId: this.selectedRunId,
            reason: this.failReason, requestKey: key }), 'Payment recorded as failed.');
    }

    handleReturn() {
        return this.runAction('RETURN', this.returnSettlementId, (key) => recordLineReturn({ settlementId: this.returnSettlementId,
            returnDate: this.returnDate, reason: this.returnReason, requestKey: key }), 'Bank return recorded; line reopened.');
    }

    handleApproveAssignment() {
        return this.runAction('APPROVEASSIGN', this.selectedAssignmentId, () => approveAssignment({
            assignmentId: this.selectedAssignmentId }), 'Compensation approved.');
    }

    handleApproveAward() {
        return this.runAction('APPROVEAWARD', this.selectedAwardId, () => approveBenefitAward({ awardId: this.selectedAwardId }),
            'Benefit award approved.');
    }

    handleCancelAward() {
        return this.runAction('CANCELAWARD', this.selectedAwardId, () => cancelBenefitAward({ awardId: this.selectedAwardId }),
            'Benefit award cancelled.');
    }

    // ------------------------------------------------------------- actions

    requestKey(action, recordId) {
        const name = `${action}|${recordId}`;
        if (!this.requestKeys[name]) {
            this.requestKeys[name] = `G10G|${name}|${Date.now()}`;
        }
        return this.requestKeys[name];
    }

    async runAction(action, recordId, call, successMessage) {
        const name = `${action}|${recordId}`;
        const key = this.requestKey(action, recordId);
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            await call(key);
            delete this.requestKeys[name];
            this.dispatchEvent(new ShowToastEvent({ title: 'Payroll', message: successMessage, variant: 'success' }));
            this.clearRunForm();
            this.isLoading = false;
            await this.refresh();
        } catch (error) {
            this.notifyError(error);
        } finally {
            this.isLoading = false;
        }
    }

    notifyError(error) {
        const message = this.reduceError(error);
        this.errorMessage = message;
        this.dispatchEvent(new ShowToastEvent({ title: 'Payroll', message, variant: 'error' }));
    }

    reduceError(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        if (error && error.message) {
            return error.message;
        }
        return 'An unexpected Payroll Workspace error occurred.';
    }
}
