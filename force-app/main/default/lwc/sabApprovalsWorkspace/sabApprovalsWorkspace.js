import { LightningElement, api } from 'lwc';
import getWorkspace from '@salesforce/apex/SABApprovalsCloseWorkspaceController.getWorkspace';
import getChecklist from '@salesforce/apex/SABApprovalsCloseWorkspaceController.getChecklist';
import decide from '@salesforce/apex/SABApprovalService.decide';
import cancelRequest from '@salesforce/apex/SABApprovalService.cancel';
import generateChecklist from '@salesforce/apex/SABCloseTaskService.generateChecklist';
import assignTask from '@salesforce/apex/SABCloseTaskService.assign';
import updateStatus from '@salesforce/apex/SABCloseTaskService.updateStatus';
import { formatDate, formatDateTime, formatMonth, chipClass, plural } from 'c/sabFormat';

function reduceError(error) {
    if (!error) {
        return 'Something went wrong.';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return (error.body && error.body.message) || error.message || 'Something went wrong.';
}

function newKey(prefix, id) {
    const random = typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    return `${prefix}-${id || 'new'}-${random}`;
}

/**
 * Approvals and close workspace (G22E): the user's approval inbox and submitted requests, and the month-end close
 * checklist of a period, on SABApprovalService and SABCloseTaskService.
 */
export default class SabApprovalsWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api recordId;
    @api periodKey;

    data;
    checklist;
    errorMessage;
    checklistError;
    isLoading = false;
    activeTab = 'inbox';
    selectedPeriodId;
    busyKey;
    modal;
    form = {};
    formError;
    saving = false;
    loadSequence = 0;
    checklistSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.selectedPeriodId = undefined;
            this.checklist = undefined;
            this.load();
        }
    }

    async load() {
        const companyId = this.currentCompanyId;
        const sequence = ++this.loadSequence;
        if (!companyId) {
            this.data = undefined;
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const result = await getWorkspace({ companyId });
            if (sequence !== this.loadSequence) {
                return;
            }
            this.data = result;
            if (!this.selectedPeriodId || !(result.periods || []).some((p) => p.periodId === this.selectedPeriodId)) {
                this.selectedPeriodId = result.currentPeriodId;
            }
            if (this.activeTab === 'close') {
                await this.loadChecklist();
            }
        } catch (error) {
            if (sequence === this.loadSequence) {
                this.data = undefined;
                this.errorMessage = reduceError(error);
            }
        } finally {
            if (sequence === this.loadSequence) {
                this.isLoading = false;
            }
        }
    }

    async loadChecklist() {
        const periodId = this.selectedPeriodId;
        const sequence = ++this.checklistSequence;
        if (!periodId) {
            this.checklist = undefined;
            return;
        }
        this.checklistError = undefined;
        try {
            const result = await getChecklist({ companyId: this.currentCompanyId, periodId });
            if (sequence === this.checklistSequence) {
                this.checklist = result;
            }
        } catch (error) {
            if (sequence === this.checklistSequence) {
                this.checklist = undefined;
                this.checklistError = reduceError(error);
            }
        }
    }

    // ---------- shared ----------

    get showLoading() {
        return this.isLoading && !this.data && !this.errorMessage;
    }

    get isInboxTab() {
        return this.activeTab === 'inbox';
    }

    get tabs() {
        const d = this.data || {};
        const c = this.checklist;
        return [
            { id: 'inbox', label: 'Approvals inbox', count: (d.inbox || []).length },
            { id: 'close', label: 'Close checklist', count: c ? `${c.complete}/${c.total}` : '' }
        ].map((t) => ({
            ...t,
            hasCount: t.count !== '',
            className: t.id === this.activeTab ? 'tab active' : 'tab',
            selected: t.id === this.activeTab ? 'true' : 'false'
        }));
    }

    async handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
        if (this.activeTab === 'close' && !this.checklist) {
            await this.loadChecklist();
        }
    }

    get canGoClose() {
        return Array.isArray(this.visibleWorkspaces) && this.visibleWorkspaces.includes('close');
    }

    handleOpenPeriodClose() {
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'close' }, bubbles: true, composed: true }));
    }

    toast(message, tone) {
        this.dispatchEvent(new CustomEvent('sabtoast', { detail: { message, tone }, bubbles: true, composed: true }));
    }

    async runAction(busyKey, call, message, reloadAll) {
        if (this.busyKey) {
            return;
        }
        this.busyKey = busyKey;
        try {
            await call();
            this.toast(message);
            if (reloadAll) {
                await this.load();
            } else {
                await this.loadChecklist();
            }
        } catch (error) {
            this.toast(reduceError(error), 'bad');
        } finally {
            this.busyKey = undefined;
        }
    }

    handleRetry() {
        this.load();
    }

    // ---------- inbox ----------

    get decideReason() {
        return this.data && this.data.canDecide ? undefined : 'Your role cannot decide approvals';
    }

    get inboxRows() {
        return ((this.data && this.data.inbox) || []).map((r) => ({
            ...r,
            requestedText: formatDateTime(r.requestedAt),
            stepText: `Step ${r.sequence}`,
            disabled: Boolean(this.decideReason) || this.busyKey === `step-${r.approvalStepId}`,
            title: this.decideReason
        }));
    }

    get hasInbox() {
        return this.inboxRows.length > 0;
    }

    get requestRows() {
        const reason = this.data && this.data.canRequest ? undefined : 'Your role cannot cancel approval requests';
        return ((this.data && this.data.myRequests) || []).map((r) => ({
            ...r,
            requestedText: formatDateTime(r.requestedAt),
            chip: chipClass(r.status),
            disabled: Boolean(reason),
            title: reason
        }));
    }

    get hasRequests() {
        return this.requestRows.length > 0;
    }

    handleApprove(event) {
        const stepId = event.currentTarget.dataset.id;
        this.runAction(`step-${stepId}`, () => decide({ approvalStepId: stepId, decision: 'Approved', comment: null,
            requestKey: newKey('APR-DECIDE', stepId) }), 'Approved', true);
    }

    handleReject(event) {
        const stepId = event.currentTarget.dataset.id;
        this.openModal('reject', { recordId: stepId, requestKey: newKey('APR-DECIDE', stepId) });
    }

    handleCancelRequest(event) {
        const requestId = event.currentTarget.dataset.id;
        this.openModal('cancel', { recordId: requestId, requestKey: newKey('APR-CANCEL', requestId) });
    }

    // ---------- checklist ----------

    get canManageClose() {
        return Boolean(this.data && this.data.canManageClose);
    }

    get periodOptions() {
        return ((this.data && this.data.periods) || []).map((p) => ({
            value: p.periodId,
            label: `${p.periodKey}, ${formatMonth(p.startDate)}, ${p.status.toLowerCase()}`,
            selected: p.periodId === this.selectedPeriodId
        }));
    }

    get hasPeriods() {
        return this.periodOptions.length > 0;
    }

    async handlePeriodChange(event) {
        this.selectedPeriodId = event.target.value;
        this.checklist = undefined;
        await this.loadChecklist();
    }

    get hasChecklist() {
        return Boolean(this.checklist && this.checklist.total > 0);
    }

    get summary() {
        const c = this.checklist || {};
        const pct = c.total ? Math.round((c.complete / c.total) * 100) : 0;
        return {
            meterStyle: `width:${pct}%`,
            text: `${c.complete || 0} of ${plural(c.total || 0, 'task')} complete${c.blocked ? `, ${c.blocked} blocked` : ''}`,
            bannerClass: c.readyToClose ? 'banner t-good' : 'banner t-warn',
            bannerIcon: c.readyToClose ? 'check' : 'alert',
            bannerTitle: c.readyToClose ? 'Ready to close' : 'Not ready to close',
            bannerText: c.readyToClose
                ? `Every task for ${c.periodKey} is complete. Close the period from Period close.`
                : `Period close stays blocked until every task is complete.`
        };
    }

    get generateDisabled() {
        return !this.canManageClose || (this.checklist && this.checklist.periodStatus !== 'Open');
    }

    get generateTitle() {
        if (!this.canManageClose) {
            return 'Your role cannot manage close tasks';
        }
        return this.generateDisabled ? 'Tasks can change only while the period is open' : undefined;
    }

    get generateLabel() {
        return this.hasChecklist ? 'Add missing tasks' : 'Generate checklist';
    }

    get taskRows() {
        const c = this.checklist;
        if (!c) {
            return [];
        }
        const open = c.periodStatus === 'Open';
        const manager = this.canManageClose;
        return (c.tasks || []).map((t) => {
            const mayChange = open && (manager || t.assignedToMe);
            const actions = [];
            if (mayChange && t.status === 'Not Started') {
                actions.push({ key: 'start', label: 'Start', status: 'In Progress' });
            }
            if (mayChange && (t.status === 'Not Started' || t.status === 'In Progress')) {
                actions.push({ key: 'complete', label: 'Complete', status: 'Complete', primary: true });
                actions.push({ key: 'block', label: 'Block', status: 'Blocked' });
            }
            if (mayChange && t.status === 'Blocked') {
                actions.push({ key: 'resume', label: 'Resume', status: 'In Progress' });
            }
            if (open && manager && t.status === 'Complete') {
                actions.push({ key: 'reopen', label: 'Reopen', status: 'In Progress' });
            }
            return {
                ...t,
                dueText: formatDate(t.dueDate),
                chip: chipClass(t.status, t.status === 'Not Started' ? 'neutral' : undefined),
                note: t.status === 'Blocked' ? t.blockedReason : t.evidenceReference,
                evidenceText: t.evidenceRequired ? 'Evidence required' : '',
                assigneeText: t.assigneeName || 'Unassigned',
                canAssign: open && manager,
                assigneeOptions: (c.assignees || []).map((a) => ({ ...a, selected: a.value === t.assigneeId })),
                actions: actions.map((a) => ({
                    ...a,
                    className: a.primary ? 'btn primary sm' : 'btn sm',
                    disabled: this.busyKey === `task-${t.taskId}`
                }))
            };
        });
    }

    handleGenerate() {
        const periodId = this.selectedPeriodId;
        this.runAction(`gen-${periodId}`, () => generateChecklist({ periodId }), 'Close checklist generated', false);
    }

    handleAssign(event) {
        const taskId = event.target.dataset.id;
        const assigneeId = event.target.value || null;
        const task = this.checklist.tasks.find((t) => t.taskId === taskId);
        this.runAction(`task-${taskId}`, () => assignTask({ taskId, assigneeId, dueDate: task.dueDate || null }), 'Task assigned', false);
    }

    handleTaskAction(event) {
        const taskId = event.currentTarget.dataset.id;
        const status = event.currentTarget.dataset.status;
        const task = this.checklist.tasks.find((t) => t.taskId === taskId);
        const requestKey = newKey('CLOSE-TASK', taskId);
        if (status === 'Blocked' || (status === 'Complete' && task.evidenceRequired)) {
            this.openModal(status === 'Blocked' ? 'block' : 'evidence', { recordId: taskId, taskName: task.name, status, requestKey,
                text: status === 'Complete' ? task.evidenceReference || '' : '' });
            return;
        }
        this.runAction(`task-${taskId}`, () => updateStatus({ taskId, status, evidenceReference: null, blockedReason: null, requestKey }),
            `Task moved to ${status.toLowerCase()}`, false);
    }

    // ---------- modal ----------

    get modalOpen() {
        return Boolean(this.modal);
    }

    get modalHeading() {
        return { reject: 'Reject approval', cancel: 'Cancel approval request', block: 'Block task', evidence: 'Complete task' }[this.modal];
    }

    get modalSub() {
        return {
            reject: 'A comment is required and goes back to the requester.',
            cancel: 'Remaining steps are skipped. A reason is required.',
            block: this.form.taskName,
            evidence: this.form.taskName
        }[this.modal];
    }

    get modalLabel() {
        return { reject: 'Comment', cancel: 'Reason', block: 'Why is it blocked?', evidence: 'Evidence reference' }[this.modal];
    }

    get saveLabel() {
        return { reject: 'Reject', cancel: 'Cancel request', block: 'Block task', evidence: 'Complete task' }[this.modal];
    }

    get saveClass() {
        return this.modal === 'reject' || this.modal === 'cancel' ? 'btn danger save' : 'btn primary save';
    }

    openModal(kind, form) {
        this.form = form;
        this.formError = undefined;
        this.modal = kind;
        // A textarea has no value attribute in templates; reset or prefill it after the modal renders.
        return Promise.resolve().then(() => {
            const area = this.template.querySelector('textarea');
            if (area) {
                area.value = this.form.text || '';
            }
        });
    }

    handleText(event) {
        this.form = { ...this.form, text: event.target.value };
    }

    handleCloseModal() {
        if (!this.saving) {
            this.modal = undefined;
            this.formError = undefined;
        }
    }

    async handleSave() {
        if (this.saving) {
            return;
        }
        const f = this.form;
        const kind = this.modal;
        this.saving = true;
        this.formError = undefined;
        try {
            let message;
            if (kind === 'reject') {
                await decide({ approvalStepId: f.recordId, decision: 'Rejected', comment: f.text || '', requestKey: f.requestKey });
                message = 'Rejected';
            } else if (kind === 'cancel') {
                await cancelRequest({ approvalRequestId: f.recordId, reason: f.text || '', requestKey: f.requestKey });
                message = 'Approval request cancelled';
            } else {
                await updateStatus({ taskId: f.recordId, status: f.status, evidenceReference: kind === 'evidence' ? f.text || null : null,
                    blockedReason: kind === 'block' ? f.text || null : null, requestKey: f.requestKey });
                message = kind === 'block' ? 'Task blocked' : 'Task completed';
            }
            this.modal = undefined;
            this.toast(message);
            if (kind === 'reject' || kind === 'cancel') {
                await this.load();
            } else {
                await this.loadChecklist();
            }
        } catch (error) {
            this.formError = reduceError(error);
        } finally {
            this.saving = false;
        }
    }
}
