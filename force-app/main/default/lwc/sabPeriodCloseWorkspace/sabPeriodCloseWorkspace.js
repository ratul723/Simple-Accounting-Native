import { LightningElement, api } from 'lwc';
import getWorkspace from '@salesforce/apex/SABAccountingPeriodWorkspaceController.getWorkspace';
import getPeriodDetail from '@salesforce/apex/SABAccountingPeriodWorkspaceController.getPeriodDetail';
import closePeriod from '@salesforce/apex/SABAccountingPeriodWorkspaceController.closePeriod';
import reopenPeriod from '@salesforce/apex/SABAccountingPeriodWorkspaceController.reopenPeriod';
import getChecklist from '@salesforce/apex/SABApprovalsCloseWorkspaceController.getChecklist';
import updateTaskStatus from '@salesforce/apex/SABCloseTaskService.updateStatus';
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

function todayIso() {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

const TASK_ICON = { Complete: 'check', Blocked: 'alert' };
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

/**
 * Period close and reopen in the Harbourline demo layout (G22G-2): fiscal-year period grid, close checklist with
 * meter, close and reopen with a reason, and the period action history, on SABAccountingPeriodWorkspaceController
 * (unchanged) and the G19 close checklist.
 */
export default class SabPeriodCloseWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api recordId;
    @api periodKey;

    data;
    errorMessage;
    isLoading = false;
    fiscalYear;
    selectedId;
    detail;
    checklist;
    checklistUnavailable = false;
    reason = '';
    busy = false;
    loadSequence = 0;
    detailSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.selectedId = undefined;
            this.fiscalYear = undefined;
            this.load();
        }
    }

    async load() {
        const companyId = this.currentCompanyId;
        const sequence = ++this.loadSequence;
        if (!companyId) {
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
            const periods = this.periods;
            const today = todayIso();
            const current = periods.find((p) => p.startDate <= today && p.endDate >= today);
            const keep = periods.find((p) => p.periodId === this.selectedId);
            const target = keep || current || periods[periods.length - 1];
            if (target) {
                this.fiscalYear = this.fiscalYear && this.years.includes(this.fiscalYear) && keep ? this.fiscalYear : target.fiscalYear;
                await this.select(target.periodId);
            }
        } catch (error) {
            if (sequence === this.loadSequence) {
                this.errorMessage = reduceError(error);
            }
        } finally {
            if (sequence === this.loadSequence) {
                this.isLoading = false;
            }
        }
    }

    async select(periodId) {
        const sequence = ++this.detailSequence;
        this.selectedId = periodId;
        this.reason = this.defaultReason(periodId);
        this.checklist = undefined;
        this.checklistUnavailable = false;
        try {
            const detail = await getPeriodDetail({ periodId });
            if (sequence !== this.detailSequence) {
                return;
            }
            this.detail = detail;
            if (this.mode === 'close') {
                try {
                    this.checklist = await getChecklist({ companyId: this.currentCompanyId, periodId });
                } catch {
                    this.checklistUnavailable = true;
                }
            }
        } catch (error) {
            if (sequence === this.detailSequence) {
                this.detail = undefined;
                this.toast(reduceError(error), 'bad');
            }
        }
    }

    defaultReason(periodId) {
        const p = this.periods.find((x) => x.periodId === periodId);
        if (!p || p.status === 'Closed') {
            return '';
        }
        return p.endDate < todayIso() ? 'Late entries posted, closing again' : `${MONTHS[Number(p.startDate.slice(5, 7)) - 1]} month-end close`;
    }

    // ---------- periods ----------

    get showLoading() {
        return this.isLoading && !this.data && !this.errorMessage;
    }

    get periods() {
        return [...((this.data && this.data.periods) || [])].sort((a, b) => (a.startDate < b.startDate ? -1 : 1));
    }

    get years() {
        return [...new Set(this.periods.map((p) => p.fiscalYear))];
    }

    get yearPeriods() {
        return this.periods.filter((p) => p.fiscalYear === this.fiscalYear);
    }

    get gridTitle() {
        return this.fiscalYear ? `Fiscal year ${this.fiscalYear}` : 'Accounting periods';
    }

    get gridSub() {
        const list = this.yearPeriods;
        return `${list.filter((p) => p.status === 'Closed').length} closed, ${list.filter((p) => p.status !== 'Closed').length} open`;
    }

    get hasPrevYear() {
        return this.years.indexOf(this.fiscalYear) > 0;
    }

    get hasNextYear() {
        const i = this.years.indexOf(this.fiscalYear);
        return i >= 0 && i < this.years.length - 1;
    }

    get prevDisabled() {
        return !this.hasPrevYear;
    }

    get nextDisabled() {
        return !this.hasNextYear;
    }

    handlePrevYear() {
        this.fiscalYear = this.years[this.years.indexOf(this.fiscalYear) - 1];
    }

    handleNextYear() {
        this.fiscalYear = this.years[this.years.indexOf(this.fiscalYear) + 1];
    }

    get cells() {
        const today = todayIso();
        return this.yearPeriods.map((p) => {
            const closed = p.status === 'Closed';
            const current = p.startDate <= today && p.endDate >= today;
            const future = p.startDate > today;
            let state = { chip: chipClass('Open', 'accent'), text: 'Open', isChip: true };
            if (closed) {
                state = { chip: chipClass('Closed', 'neutral'), text: 'Closed', isChip: true };
            } else if (future) {
                state = { text: 'Open, future', isChip: false };
            } else if (!current) {
                state = { chip: chipClass('Open', 'warn'), text: 'Open, past', isChip: true };
            }
            return {
                ...p,
                ...state,
                label: formatMonth(p.startDate),
                className: `pcell${p.periodId === this.selectedId ? ' sel' : ''}${closed ? ' closed' : ''}`,
                pressed: p.periodId === this.selectedId ? 'true' : 'false'
            };
        });
    }

    handlePick(event) {
        this.select(event.currentTarget.dataset.id);
    }

    // ---------- selected period ----------

    get selected() {
        return this.periods.find((p) => p.periodId === this.selectedId);
    }

    get monthName() {
        return this.selected ? MONTHS[Number(this.selected.startDate.slice(5, 7)) - 1] : '';
    }

    get mode() {
        const p = this.selected;
        if (!p) {
            return 'none';
        }
        if (p.status === 'Closed') {
            return 'closed';
        }
        return p.startDate > todayIso() ? 'future' : 'close';
    }

    get isClosed() {
        return this.mode === 'closed';
    }

    get isClose() {
        return this.mode === 'close';
    }

    get isLateReopened() {
        return this.isClose && this.selected.endDate < todayIso();
    }

    get mainTitle() {
        const label = formatMonth(this.selected.startDate);
        if (this.isClosed) {
            return `${label} is closed`;
        }
        if (this.mode === 'future') {
            return label;
        }
        return this.isLateReopened ? `${label} is open again` : `Close checklist for ${label}`;
    }

    get mainSub() {
        if (this.isClosed) {
            return 'Reopening is a controlled action with a mandatory reason';
        }
        return this.isLateReopened ? 'Reopened periods should be closed again promptly' : 'Closing locks the period against new postings';
    }

    get closedFacts() {
        const p = this.selected;
        return [
            { key: 'by', label: 'Closed by', value: p.closedByName || '\u2014' },
            { key: 'at', label: 'Closed at', value: formatDateTime(p.closedAt) || '\u2014' },
            { key: 'post', label: 'Postings', value: 'Rejected until reopened' }
        ];
    }

    get hasChecklist() {
        return Boolean(this.checklist && this.checklist.total > 0);
    }

    get checklistSummary() {
        const c = this.checklist || { complete: 0, total: 0 };
        const open = c.total - c.complete;
        return {
            doneText: `${c.complete} of ${c.total} complete`,
            openText: `${open} open`,
            meterStyle: `width:${c.total ? Math.round((c.complete / c.total) * 100) : 0}%`
        };
    }

    get canManageClose() {
        return Array.isArray(this.visibleWorkspaces) && this.visibleWorkspaces.includes('approvals');
    }

    get taskRows() {
        return ((this.checklist && this.checklist.tasks) || []).map((t) => {
            const open = t.status !== 'Complete';
            const markable = open && t.status !== 'Blocked' && !t.evidenceRequired && (t.assignedToMe || this.canCloseByRole);
            return {
                ...t,
                iconClass: `ic t-${t.status === 'Complete' ? 'good' : t.status === 'Blocked' ? 'bad' : t.status === 'In Progress' ? 'info' : 'neutral'}`,
                icon: TASK_ICON[t.status] || 'audit',
                detail: [t.assigneeName || 'Unassigned', t.status === 'Blocked' ? t.blockedReason : null, t.dueDate ? `due ${formatDate(t.dueDate)}` : null]
                    .filter(Boolean).join(', '),
                chip: chipClass(t.status, t.status === 'Not Started' ? 'neutral' : undefined),
                markable,
                resolve: open && !markable && this.canManageClose
            };
        });
    }

    get canCloseByRole() {
        return Boolean(this.data && this.data.canClosePeriod);
    }

    get openTasks() {
        const c = this.checklist;
        return c ? c.total - c.complete : 0;
    }

    get closeLabel() {
        return this.isLateReopened ? `Close ${formatMonth(this.selected.startDate)}` : `Close ${this.monthName}`;
    }

    get closeDisabled() {
        return this.busy || !this.canCloseByRole || this.openTasks > 0 || !this.reason.trim();
    }

    get closeTitle() {
        if (!this.canCloseByRole) {
            return `${(this.persona && this.persona.label) || 'Your'} role cannot close periods`;
        }
        return undefined;
    }

    get closeHint() {
        return this.openTasks > 0 ? `Complete every task to close. Open tasks: ${this.openTasks}.` : '';
    }

    get reopenDisabled() {
        return this.busy || !(this.data && this.data.canReopenPeriod) || !this.reason.trim();
    }

    get reopenTitle() {
        return this.data && this.data.canReopenPeriod ? undefined : `${(this.persona && this.persona.label) || 'Your'} role cannot reopen periods`;
    }

    get futureText() {
        return `${formatMonth(this.selected.startDate)} is open for forward-dated documents. Its close checklist can be generated from the template once it starts on ${formatDate(this.selected.startDate)}.`;
    }

    handleReason(event) {
        this.reason = event.target.value;
    }

    async handleClose() {
        if (this.closeDisabled) {
            return;
        }
        await this.runPeriodAction(() => closePeriod({ periodId: this.selectedId, requestKey: newKey('PERIOD-CLOSE', this.selectedId), reason: this.reason.trim() }),
            `${formatMonth(this.selected.startDate)} closed`);
    }

    async handleReopen() {
        if (this.reopenDisabled) {
            return;
        }
        await this.runPeriodAction(() => reopenPeriod({ periodId: this.selectedId, requestKey: newKey('PERIOD-REOPEN', this.selectedId), reason: this.reason.trim() }),
            `${formatMonth(this.selected.startDate)} reopened`);
    }

    async runPeriodAction(call, message) {
        this.busy = true;
        try {
            const result = await call();
            this.toast(result && result.replay ? `${message} (already done)` : message);
            await this.load();
        } catch (error) {
            this.toast(reduceError(error), 'bad');
        } finally {
            this.busy = false;
        }
    }

    async handleMarkDone(event) {
        const taskId = event.currentTarget.dataset.id;
        this.busy = true;
        try {
            await updateTaskStatus({ taskId, status: 'Complete', evidenceReference: null, blockedReason: null, requestKey: newKey('CLOSE-TASK', taskId) });
            this.toast('Task marked done');
            this.checklist = await getChecklist({ companyId: this.currentCompanyId, periodId: this.selectedId });
        } catch (error) {
            this.toast(reduceError(error), 'bad');
        } finally {
            this.busy = false;
        }
    }

    handleResolve() {
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'approvals' }, bubbles: true, composed: true }));
    }

    // ---------- history ----------

    get historyRows() {
        return ((this.detail && this.detail.actions) || []).map((a) => ({
            ...a,
            period: this.selected ? this.selected.periodName : '',
            change: `${a.previousStatus} to ${a.newStatus}`,
            atText: formatDateTime(a.performedAt)
        }));
    }

    get hasHistory() {
        return this.historyRows.length > 0;
    }

    get historySub() {
        return `${plural(this.historyRows.length, 'action')} for this period, newest first`;
    }

    toast(message, tone) {
        this.dispatchEvent(new CustomEvent('sabtoast', { detail: { message, tone }, bubbles: true, composed: true }));
    }

    handleRetry() {
        this.load();
    }
}