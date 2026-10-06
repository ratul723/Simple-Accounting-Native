import { LightningElement, wire } from 'lwc';
import { subscribe, unsubscribe, MessageContext, APPLICATION_SCOPE } from 'lightning/messageService';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import COMPANY_CONTEXT_CHANNEL from '@salesforce/messageChannel/SABCompanyContext__c';

import getWorkspace from '@salesforce/apex/SABTaxReturnWorkspaceController.getWorkspace';
import getReturnDetail from '@salesforce/apex/SABTaxReturnWorkspaceController.getReturnDetail';
import prepareReturn from '@salesforce/apex/SABTaxReturnWorkspaceController.prepareReturn';
import setAdjustment from '@salesforce/apex/SABTaxReturnWorkspaceController.setAdjustment';
import reviewReturn from '@salesforce/apex/SABTaxReturnLifecycleService.reviewReturn';
import submitReturn from '@salesforce/apex/SABTaxReturnLifecycleService.submitReturn';
import recordAuthorityOutcome from '@salesforce/apex/SABTaxReturnLifecycleService.recordAuthorityOutcome';
import createAmendment from '@salesforce/apex/SABTaxReturnLifecycleService.createAmendment';

const STORAGE_KEY = 'sabSelectedAccountingCompanyId';
const ADJUSTABLE = ['Draft', 'Prepared'];
const AMENDABLE = ['Accepted', 'Rejected'];
const MONEY = { type: 'number', typeAttributes: { minimumFractionDigits: 2, maximumFractionDigits: 4 } };

const RETURN_COLUMNS = [
    { label: 'Return', fieldName: 'name' },
    { label: 'Registration', fieldName: 'registrationName' },
    { label: 'Period Start', fieldName: 'periodStart', type: 'date-local' },
    { label: 'Period End', fieldName: 'periodEnd', type: 'date-local' },
    { label: 'Version', fieldName: 'returnVersion', type: 'number' },
    { label: 'Status', fieldName: 'status' },
    { label: 'Net Tax Due', fieldName: 'netTaxDue', ...MONEY },
    { label: 'Filing Ref', fieldName: 'filingReference' }
];

const LINE_COLUMNS = [
    { label: 'Box', fieldName: 'boxKey' },
    { label: 'Label', fieldName: 'label' },
    { label: 'Calculated', fieldName: 'calculatedAmount', ...MONEY },
    { label: 'Adjustment', fieldName: 'adjustmentAmount', ...MONEY },
    { label: 'Final', fieldName: 'finalAmount', ...MONEY }
];

const VERSION_COLUMNS = [
    { label: 'Return', fieldName: 'name' },
    { label: 'Version', fieldName: 'returnVersion', type: 'number' },
    { label: 'Status', fieldName: 'status' },
    { label: 'Filing Ref', fieldName: 'filingReference' },
    { label: 'Acknowledgement', fieldName: 'acknowledgementReference' }
];

const HISTORY_COLUMNS = [
    { label: 'When', fieldName: 'actionAt', type: 'date', typeAttributes: { year: 'numeric', month: 'short', day: '2-digit',
        hour: '2-digit', minute: '2-digit' } },
    { label: 'Action', fieldName: 'action' },
    { label: 'By', fieldName: 'actorName' },
    { label: 'Reason', fieldName: 'reason' }
];

const OUTCOME_OPTIONS = [
    { label: 'Accepted', value: 'Accepted' },
    { label: 'Rejected', value: 'Rejected' }
];

function isoDate(date) {
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${date.getFullYear()}-${month}-${day}`;
}

export default class SabTaxReturnWorkspace extends LightningElement {
    returnColumns = RETURN_COLUMNS;
    lineColumns = LINE_COLUMNS;
    versionColumns = VERSION_COLUMNS;
    historyColumns = HISTORY_COLUMNS;
    outcomeOptions = OUTCOME_OPTIONS;

    companyId;
    workspace;
    detail;
    subscription;
    isLoading = false;
    errorMessage;
    selectedReturnId;

    // Form state
    registrationId;
    periodStart;
    periodEnd;
    adjustmentBox;
    adjustmentAmount;
    reason = '';
    filingReference = '';
    outcome;
    acknowledgementReference = '';

    // Request keys survive a failed attempt (a retry replays) and are discarded after success.
    requestKeys = {};

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        this.defaultPeriod();
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
            this.clearSelection();
            return;
        }
        if (message.companyId && message.companyId !== this.companyId) {
            this.companyId = message.companyId;
            this.registrationId = undefined;
            this.requestKeys = {};
            this.clearSelection();
            this.refresh();
        }
    }

    // Default to the previous calendar month, the most common filing period.
    defaultPeriod() {
        const today = new Date();
        const firstOfThisMonth = new Date(today.getFullYear(), today.getMonth(), 1);
        const lastOfPrevious = new Date(firstOfThisMonth.getTime() - 86400000);
        this.periodStart = isoDate(new Date(lastOfPrevious.getFullYear(), lastOfPrevious.getMonth(), 1));
        this.periodEnd = isoDate(lastOfPrevious);
    }

    clearSelection() {
        this.selectedReturnId = undefined;
        this.detail = undefined;
        this.clearActionForm();
    }

    clearActionForm() {
        this.adjustmentBox = undefined;
        this.adjustmentAmount = undefined;
        this.reason = '';
        this.filingReference = '';
        this.outcome = undefined;
        this.acknowledgementReference = '';
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
            if (!this.registrationId && this.registrations.length) {
                this.registrationId = this.registrations[0].value;
            }
            if (this.selectedReturnId) {
                await this.loadDetail();
            }
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async loadDetail() {
        this.detail = this.selectedReturnId ? await getReturnDetail({ taxReturnId: this.selectedReturnId }) : undefined;
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

    get openNetTaxDue() {
        return this.workspace ? this.workspace.openNetTaxDue : 0;
    }

    get can() {
        return (this.workspace && this.workspace.capabilities) || {};
    }

    get registrations() {
        return (this.workspace && this.workspace.registrations) || [];
    }

    get hasRegistrations() {
        return this.registrations.length > 0;
    }

    get returns() {
        return (this.workspace && this.workspace.returns) || [];
    }

    get hasReturns() {
        return this.returns.length > 0;
    }

    get stateCounts() {
        return (this.workspace && this.workspace.stateCounts) || [];
    }

    get selectedRows() {
        return this.selectedReturnId ? [this.selectedReturnId] : [];
    }

    get taxReturn() {
        return this.detail ? this.detail.taxReturn : undefined;
    }

    get hasSelectedReturn() {
        return Boolean(this.taxReturn);
    }

    get status() {
        return this.taxReturn ? this.taxReturn.status : undefined;
    }

    get lines() {
        return (this.detail && this.detail.lines) || [];
    }

    get versions() {
        return (this.detail && this.detail.versions) || [];
    }

    get hasOtherVersions() {
        return this.versions.length > 1;
    }

    get history() {
        // Audit rows can share a timestamp, so each row gets its own key.
        return ((this.detail && this.detail.history) || []).map((row, index) => ({ ...row, rowKey: `h${index}` }));
    }

    get hasHistory() {
        return this.history.length > 0;
    }

    get boxOptions() {
        return this.lines.map((line) => ({ label: `${line.boxKey} (${line.label || ''})`, value: line.boxKey }));
    }

    get isAdjustable() {
        return ADJUSTABLE.includes(this.status);
    }

    get isPrepared() {
        return this.status === 'Prepared';
    }

    get isReviewed() {
        return this.status === 'Reviewed';
    }

    get isSubmitted() {
        return this.status === 'Submitted';
    }

    get isAmendable() {
        return AMENDABLE.includes(this.status);
    }

    get lockedLabel() {
        return this.taxReturn && this.taxReturn.sourceLocked ? 'Source data locked at review' : 'Source data not locked';
    }

    get filingMaxLength() {
        return this.workspace ? this.workspace.filingReferenceMaxLength : 255;
    }

    get acknowledgementMaxLength() {
        return this.workspace ? this.workspace.acknowledgementMaxLength : 255;
    }

    // Disabled flags: permission AND inputs AND not busy. The services re-check everything.
    get prepareDisabled() {
        return this.isLoading || !this.can.prepare || !this.registrationId || !this.periodStart || !this.periodEnd
            || this.periodStart > this.periodEnd;
    }

    get adjustDisabled() {
        return this.isLoading || !this.can.prepare || !this.adjustmentBox
            || this.adjustmentAmount === undefined || this.adjustmentAmount === null || this.adjustmentAmount === '';
    }

    get reviewDisabled() {
        return this.isLoading || !this.can.review;
    }

    get submitDisabled() {
        return this.isLoading || !this.can.submit || !this.filingReference.trim();
    }

    get outcomeDisabled() {
        return this.isLoading || !this.can.recordOutcome || !this.outcome || !this.acknowledgementReference.trim();
    }

    // The amendment service requires a reason; it is recorded on the original return's audit trail.
    get amendDisabled() {
        return this.isLoading || !this.can.amend || !this.reason.trim();
    }

    // ------------------------------------------------------------- handlers

    handleRefresh() {
        this.refresh();
    }

    handleFieldChange(event) {
        this[event.target.dataset.field] = event.detail.value;
    }

    async handleReturnSelection(event) {
        const rows = event.detail.selectedRows || [];
        const taxReturnId = rows.length ? rows[0].taxReturnId : undefined;
        if (taxReturnId === this.selectedReturnId) {
            return;
        }
        await this.selectReturn(taxReturnId);
    }

    handleVersionSelection(event) {
        const rows = event.detail.selectedRows || [];
        if (rows.length && rows[0].taxReturnId !== this.selectedReturnId) {
            this.selectReturn(rows[0].taxReturnId);
        }
    }

    async selectReturn(taxReturnId) {
        this.selectedReturnId = taxReturnId;
        this.clearActionForm();
        this.isLoading = true;
        try {
            await this.loadDetail();
        } catch (error) {
            this.notifyError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handlePrepare() {
        return this.runAction('PREPARE', `${this.registrationId}|${this.periodStart}|${this.periodEnd}`, async () => {
            const result = await prepareReturn({ taxRegistrationId: this.registrationId, periodStart: this.periodStart,
                periodEnd: this.periodEnd });
            this.selectedReturnId = result.taxReturnId;
            return result.rebuiltExistingReturn ? 'Tax return rebuilt from posted tax lines.' : 'Tax return prepared.';
        });
    }

    handleAdjust() {
        return this.runAction('ADJUST', this.selectedReturnId, async () => {
            await setAdjustment({ taxReturnId: this.selectedReturnId, boxKey: this.adjustmentBox,
                adjustmentAmount: Number(this.adjustmentAmount) });
            return 'Adjustment saved.';
        });
    }

    handleReview() {
        return this.runAction('REVIEW', this.selectedReturnId, async (key) => {
            await reviewReturn({ taxReturnId: this.selectedReturnId, requestKey: key, reason: this.reason });
            return 'Tax return reviewed; source data is locked.';
        });
    }

    handleSubmit() {
        return this.runAction('SUBMIT', this.selectedReturnId, async (key) => {
            await submitReturn({ taxReturnId: this.selectedReturnId, filingReference: this.filingReference.trim(),
                requestKey: key, reason: this.reason });
            return 'Tax return submitted.';
        });
    }

    handleOutcome() {
        return this.runAction('OUTCOME', this.selectedReturnId, async (key) => {
            await recordAuthorityOutcome({ taxReturnId: this.selectedReturnId, outcome: this.outcome,
                acknowledgementReference: this.acknowledgementReference.trim(), requestKey: key, reason: this.reason });
            return `Authority outcome recorded: ${this.outcome}.`;
        });
    }

    handleAmend() {
        return this.runAction('AMEND', this.selectedReturnId, async (key) => {
            const result = await createAmendment({ taxReturnId: this.selectedReturnId, requestKey: key, reason: this.reason.trim() });
            if (result && result.amendmentTaxReturnId) {
                this.selectedReturnId = result.amendmentTaxReturnId;
            }
            return 'Amendment version created; prepare it to rebuild from posted tax lines.';
        });
    }

    // ------------------------------------------------------------- actions

    requestKey(action, recordId) {
        const name = `${action}|${recordId}`;
        if (!this.requestKeys[name]) {
            this.requestKeys[name] = `G11|${name}|${Date.now()}`;
        }
        return this.requestKeys[name];
    }

    async runAction(action, recordId, call) {
        const name = `${action}|${recordId}`;
        const key = this.requestKey(action, recordId);
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const message = await call(key);
            delete this.requestKeys[name];
            this.dispatchEvent(new ShowToastEvent({ title: 'Tax Returns', message, variant: 'success' }));
            this.clearActionForm();
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
        this.dispatchEvent(new ShowToastEvent({ title: 'Tax Returns', message, variant: 'error' }));
    }

    reduceError(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        if (error && error.message) {
            return error.message;
        }
        return 'An unexpected Tax Return Workspace error occurred.';
    }
}
