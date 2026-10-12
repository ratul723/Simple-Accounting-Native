import { createElement } from 'lwc';
import SabPeriodCloseWorkspace from 'c/sabPeriodCloseWorkspace';
import getWorkspace from '@salesforce/apex/SABAccountingPeriodWorkspaceController.getWorkspace';
import getPeriodDetail from '@salesforce/apex/SABAccountingPeriodWorkspaceController.getPeriodDetail';
import closePeriod from '@salesforce/apex/SABAccountingPeriodWorkspaceController.closePeriod';
import reopenPeriod from '@salesforce/apex/SABAccountingPeriodWorkspaceController.reopenPeriod';
import getChecklist from '@salesforce/apex/SABApprovalsCloseWorkspaceController.getChecklist';
import updateTaskStatus from '@salesforce/apex/SABCloseTaskService.updateStatus';

jest.mock('@salesforce/apex/SABAccountingPeriodWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAccountingPeriodWorkspaceController.getPeriodDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAccountingPeriodWorkspaceController.closePeriod', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAccountingPeriodWorkspaceController.reopenPeriod', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABApprovalsCloseWorkspaceController.getChecklist', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABCloseTaskService.updateStatus', () => ({ default: jest.fn() }), { virtual: true });

const COMPANY = 'a01000000000001AAA';
const d = new Date();
const y = d.getFullYear();
const iso = (yy, m, day) => `${yy}-${String(m).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
const m = d.getMonth() + 1;
const prev = m === 1 ? [y - 1, 12] : [y, m - 1];
const next = m === 12 ? [y + 1, 1] : [y, m + 1];
const lastDay = new Date(y, m, 0).getDate();
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

function periods(overrides = {}) {
    return [
        { periodId: 'PP', periodName: 'P-PREV', startDate: iso(prev[0], prev[1], 1), endDate: iso(prev[0], prev[1], 28), fiscalYear: 2027, status: 'Closed',
            closedByName: 'Alex Morgan', closedAt: '2026-09-05T02:00:00.000Z', ...(overrides.PP || {}) },
        { periodId: 'PC', periodName: 'P-CUR', startDate: iso(y, m, 1), endDate: iso(y, m, lastDay), fiscalYear: 2027, status: 'Open', ...(overrides.PC || {}) },
        { periodId: 'PN', periodName: 'P-NEXT', startDate: iso(next[0], next[1], 1), endDate: iso(next[0], next[1], 28), fiscalYear: 2027, status: 'Open' },
        { periodId: 'PO', periodName: 'P-OLD', startDate: '2020-01-01', endDate: '2020-01-31', fiscalYear: 2020, status: 'Closed' }
    ];
}

const CHECKLIST = {
    total: 3, complete: 1, readyToClose: false,
    tasks: [
        { taskId: 'T1', name: 'Reconcile bank', status: 'Complete', assigneeName: 'Alex Morgan' },
        { taskId: 'T2', name: 'Review accruals', status: 'In Progress', assignedToMe: true, dueDate: iso(y, m, 5) },
        { taskId: 'T3', name: 'Agree intercompany', status: 'Blocked', blockedReason: 'Waiting for NZ', evidenceRequired: true }
    ]
};

async function flush() {
    for (let i = 0; i < 10; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-period-close-workspace', { is: SabPeriodCloseWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', persona: { label: 'Finance Manager' }, visibleWorkspaces: ['close', 'approvals'], ...props });
    el.companyId = COMPANY;
    document.body.appendChild(el);
    return el;
}

describe('c-sab-period-close-workspace', () => {
    beforeEach(() => {
        getWorkspace.mockResolvedValue({ canClosePeriod: true, canReopenPeriod: true, periods: periods() });
        getPeriodDetail.mockResolvedValue({ actions: [{ actionId: 'A1', previousStatus: 'Open', newStatus: 'Closed', performedByName: 'Alex Morgan',
            performedAt: '2026-09-05T02:00:00.000Z', reason: 'August close' }] });
        getChecklist.mockResolvedValue(CHECKLIST);
        closePeriod.mockResolvedValue({ newStatus: 'Closed', replay: false });
        reopenPeriod.mockResolvedValue({ newStatus: 'Open', replay: false });
        updateTaskStatus.mockResolvedValue({});
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows the fiscal year grid and the current period checklist', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-period-grid h2').textContent).toBe('Fiscal year 2027');
        const cells = root.querySelectorAll('.pcell');
        expect(cells.length).toBe(3);
        expect(cells[0].className).toBe('pcell closed');
        expect(cells[1].className).toBe('pcell sel');
        expect(cells[2].textContent).toContain('Open, future');
        expect(root.querySelector('.sab-period-main h2').textContent).toContain('Close checklist for');
        expect(root.querySelector('.count-row').textContent).toBe('1 of 3 complete2 open');
        const tasks = root.querySelectorAll('.tasks .li');
        expect(tasks[1].querySelector('.sab-mark-done')).not.toBeNull();
        expect(tasks[2].querySelector('.sab-resolve')).not.toBeNull();
        expect(tasks[2].textContent).toContain('Waiting for NZ');
        expect(root.querySelector('.sab-close-reason').value).toBe(`${MONTHS[m - 1]} month-end close`);
        expect(root.querySelector('.sab-close').disabled).toBe(true);
        expect(root.querySelector('.row.end .hint').textContent).toBe('Complete every task to close. Open tasks: 2.');
        expect(root.querySelector('.sab-history tbody tr').textContent).toContain('Open to Closed');
    });

    it('marks a task done, resolves another and closes when ready', async () => {
        const el = mount();
        await flush();
        const toast = jest.fn();
        const nav = jest.fn();
        el.addEventListener('sabtoast', toast);
        el.addEventListener('sabnavigate', nav);
        const root = el.shadowRoot;
        getChecklist.mockResolvedValueOnce({ ...CHECKLIST, complete: 3, readyToClose: true, tasks: CHECKLIST.tasks.map((t) => ({ ...t, status: 'Complete' })) });
        root.querySelector('.sab-mark-done').click();
        await flush();
        expect(updateTaskStatus.mock.calls[0][0]).toMatchObject({ taskId: 'T2', status: 'Complete', requestKey: expect.stringMatching(/^CLOSE-TASK-T2-/) });
        expect(toast.mock.calls[0][0].detail.message).toBe('Task marked done');
        expect(root.querySelector('.sab-close').disabled).toBe(false);
        root.querySelector('.sab-close').click();
        await flush();
        expect(closePeriod.mock.calls[0][0]).toMatchObject({ periodId: 'PC', reason: `${MONTHS[m - 1]} month-end close`, requestKey: expect.stringMatching(/^PERIOD-CLOSE-PC-/) });
        expect(getWorkspace).toHaveBeenCalledTimes(2);
    });

    it('reopens a closed period with a reason and reports failures', async () => {
        reopenPeriod.mockRejectedValueOnce({ body: { message: 'You do not have permission to reopen periods.' } });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelectorAll('.pcell')[0].click();
        await flush();
        expect(root.querySelector('.sab-period-main h2').textContent).toContain('is closed');
        expect(root.querySelector('.kv').textContent).toContain('Alex Morgan');
        expect(root.querySelector('.sab-reopen').disabled).toBe(true);
        const area = root.querySelector('.sab-reopen-reason');
        area.value = 'Late freight invoice';
        area.dispatchEvent(new CustomEvent('input'));
        await flush();
        root.querySelector('.sab-reopen').click();
        await flush();
        expect(toast.mock.calls[0][0].detail).toEqual({ message: 'You do not have permission to reopen periods.', tone: 'bad' });
        root.querySelector('.sab-reopen').click();
        await flush();
        expect(reopenPeriod).toHaveBeenCalledTimes(2);
    });

    it('shows future periods, other years, reopened periods and missing checklists', async () => {
        getWorkspace.mockResolvedValue({ canClosePeriod: false, canReopenPeriod: false, periods: periods({ PP: { status: 'Open' } }) });
        getChecklist.mockRejectedValue({ body: { message: 'No access' } });
        getPeriodDetail.mockResolvedValue({ actions: [] });
        const el = mount({ visibleWorkspaces: ['close'] });
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-period-main .muted').textContent).toContain('not available for your access');
        expect(root.querySelector('.sab-close').title).toBe('Finance Manager role cannot close periods');
        root.querySelectorAll('.pcell')[2].click();
        await flush();
        expect(root.querySelector('.empty h3').textContent).toBe('This period has not started');
        root.querySelectorAll('.pcell')[0].click();
        await flush();
        expect(root.querySelector('.sab-period-main h2').textContent).toContain('is open again');
        expect(root.querySelector('.sab-close-reason').value).toBe('Late entries posted, closing again');
        expect(root.querySelector('.sab-history .panel-b.muted').textContent).toBe('No closes or reopens recorded for this period.');
        root.querySelector('.sab-prev-year').click();
        await flush();
        expect(root.querySelector('.sab-period-grid h2').textContent).toBe('Fiscal year 2020');
        expect(root.querySelector('.sab-prev-year').disabled).toBe(true);
        root.querySelector('.sab-next-year').click();
        await flush();
        expect(root.querySelector('.sab-period-grid h2').textContent).toBe('Fiscal year 2027');
    });

    it('handles no periods, empty checklists and load errors', async () => {
        getChecklist.mockResolvedValue({ total: 0, complete: 0, tasks: [] });
        const el = mount();
        await flush();
        expect(el.shadowRoot.querySelector('.sab-period-main .muted').textContent).toContain('No close checklist');

        getWorkspace.mockResolvedValueOnce({ periods: [] });
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty h3').textContent).toBe('No accounting periods');

        getWorkspace.mockRejectedValueOnce({ body: { message: 'Select an Accounting Company first.' } });
        const el3 = mount();
        await flush();
        expect(el3.shadowRoot.querySelector('.empty p').textContent).toBe('Select an Accounting Company first.');
        el3.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        expect(el3.shadowRoot.querySelector('.sab-period-grid')).not.toBeNull();

        getPeriodDetail.mockRejectedValueOnce({ body: { message: 'Accounting Period is required.' } });
        const toast = jest.fn();
        el3.addEventListener('sabtoast', toast);
        el3.shadowRoot.querySelectorAll('.pcell')[0].click();
        await flush();
        expect(toast.mock.calls[0][0].detail.tone).toBe('bad');
    });
});
