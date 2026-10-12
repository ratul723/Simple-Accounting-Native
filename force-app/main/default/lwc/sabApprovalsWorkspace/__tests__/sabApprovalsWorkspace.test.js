import { createElement } from 'lwc';
import SabApprovalsWorkspace from 'c/sabApprovalsWorkspace';
import getWorkspace from '@salesforce/apex/SABApprovalsCloseWorkspaceController.getWorkspace';
import getChecklist from '@salesforce/apex/SABApprovalsCloseWorkspaceController.getChecklist';
import decide from '@salesforce/apex/SABApprovalService.decide';
import cancelRequest from '@salesforce/apex/SABApprovalService.cancel';
import generateChecklist from '@salesforce/apex/SABCloseTaskService.generateChecklist';
import assignTask from '@salesforce/apex/SABCloseTaskService.assign';
import updateStatus from '@salesforce/apex/SABCloseTaskService.updateStatus';

jest.mock('@salesforce/apex/SABApprovalsCloseWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABApprovalsCloseWorkspaceController.getChecklist', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABApprovalService.decide', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABApprovalService.cancel', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABCloseTaskService.generateChecklist', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABCloseTaskService.assign', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABCloseTaskService.updateStatus', () => ({ default: jest.fn() }), { virtual: true });

const COMPANY = 'a01000000000001AAA';

function workspace(overrides = {}) {
    return {
        canDecide: true, canRequest: true, canManageClose: true, currentPeriodId: 'P2',
        inbox: [{ approvalStepId: 'ST1', approvalRequestId: 'AR1', name: 'APR-0042', sourceType: 'Supplier_Bill__c', sourceLabel: 'Supplier Bill',
            sourceBusinessKey: 'BILL-000397', sequence: 1, requestedByName: 'Priya Nair', requestedAt: '2026-09-24T02:00:00.000Z' }],
        myRequests: [{ approvalRequestId: 'AR2', name: 'APR-0043', sourceLabel: 'Journal Entry', sourceBusinessKey: 'JE-000318',
            requestedAt: '2026-09-25T02:00:00.000Z', status: 'Pending', nextApprover: 'Alex Morgan' }],
        periods: [
            { periodId: 'P1', periodKey: 'FY27-P02', startDate: '2026-08-01', endDate: '2026-08-31', status: 'Closed' },
            { periodId: 'P2', periodKey: 'FY27-P03', startDate: '2026-09-01', endDate: '2026-09-30', status: 'Open' }
        ],
        ...overrides
    };
}

function checklist(overrides = {}) {
    return {
        periodId: 'P2', periodKey: 'FY27-P03', periodStatus: 'Open', total: 4, complete: 1, blocked: 1, readyToClose: false,
        assignees: [{ value: 'U1', label: 'Alex Morgan' }, { value: 'U2', label: 'Priya Nair' }],
        tasks: [
            { taskId: 'T1', name: 'Reconcile every bank account', status: 'Complete', assigneeId: 'U1', assigneeName: 'Alex Morgan',
                dueDate: '2026-10-03', evidenceRequired: true, evidenceReference: 'REC-0009' },
            { taskId: 'T2', name: 'Review supplier bills', status: 'Not Started', dueDate: '2026-10-03', evidenceRequired: false },
            { taskId: 'T3', name: 'Agree intercompany balances', status: 'In Progress', assigneeId: 'U2', evidenceRequired: true },
            { taskId: 'T4', name: 'Post payroll', status: 'Blocked', blockedReason: 'Waiting for HR', evidenceRequired: false }
        ],
        ...overrides
    };
}

async function flush() {
    for (let i = 0; i < 8; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-approvals-workspace', { is: SabApprovalsWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', visibleWorkspaces: ['home', 'close', 'approvals'], ...props });
    el.companyId = COMPANY;
    document.body.appendChild(el);
    return el;
}

function typeReason(root, text) {
    const area = root.querySelector('textarea');
    area.value = text;
    area.dispatchEvent(new CustomEvent('input'));
}

describe('c-sab-approvals-workspace', () => {
    beforeEach(() => {
        getWorkspace.mockResolvedValue(workspace());
        getChecklist.mockResolvedValue(checklist());
        decide.mockResolvedValue({ status: 'Approved' });
        cancelRequest.mockResolvedValue({ status: 'Cancelled' });
        updateStatus.mockResolvedValue({});
        assignTask.mockResolvedValue();
        generateChecklist.mockResolvedValue(9);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('lists the inbox and submitted requests and approves', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.tab').textContent).toBe('Approvals inbox1');
        expect(root.querySelector('.inbox tbody tr').textContent).toContain('BILL-000397');
        expect(root.querySelector('.mine tbody tr').textContent).toContain('Alex Morgan');
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        root.querySelector('.approve').click();
        await flush();
        expect(decide).toHaveBeenCalledWith({ approvalStepId: 'ST1', decision: 'Approved', comment: null, requestKey: expect.stringMatching(/^APR-DECIDE-ST1-/) });
        expect(toast.mock.calls[0][0].detail.message).toBe('Approved');
        expect(getWorkspace).toHaveBeenCalledTimes(2);
    });

    it('rejects with a comment and cancels a request with a reason', async () => {
        decide.mockRejectedValueOnce({ body: { message: 'A rejection needs a comment.' } });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.reject').click();
        await flush();
        expect(root.querySelector('c-sab-modal').heading).toBe('Reject approval');
        root.querySelector('.save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('A rejection needs a comment.');
        typeReason(root, 'Wrong supplier');
        root.querySelector('.save').click();
        await flush();
        expect(decide.mock.calls[1][0]).toMatchObject({ approvalStepId: 'ST1', decision: 'Rejected', comment: 'Wrong supplier' });
        root.querySelector('.cancel-request').click();
        await flush();
        typeReason(root, 'Raised in error');
        root.querySelector('.save').click();
        await flush();
        expect(cancelRequest.mock.calls[0][0]).toMatchObject({ approvalRequestId: 'AR2', reason: 'Raised in error' });
    });

    it('shows the close checklist with the right actions per task', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[1].click();
        await flush();
        expect(getChecklist).toHaveBeenCalledWith({ companyId: COMPANY, periodId: 'P2' });
        expect(root.querySelectorAll('.tab')[1].textContent).toBe('Close checklist1/4');
        expect(root.querySelector('.close .banner').textContent).toContain('Not ready to close');
        expect(root.querySelector('.progress .small').textContent).toBe('1 of 4 tasks complete, 1 blocked');
        const rows = root.querySelectorAll('.tasks tbody tr');
        const labels = (row) => Array.from(row.querySelectorAll('.act button')).map((b) => b.textContent);
        expect(labels(rows[0])).toEqual(['Reopen']);
        expect(labels(rows[1])).toEqual(['Start', 'Complete', 'Block']);
        expect(labels(rows[2])).toEqual(['Complete', 'Block']);
        expect(labels(rows[3])).toEqual(['Resume']);
        expect(rows[3].textContent).toContain('Waiting for HR');
        expect(root.querySelector('.generate').textContent).toBe('Add missing tasks');
    });

    it('changes task status, completes with evidence, blocks with a reason and assigns', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[1].click();
        await flush();
        let rows = root.querySelectorAll('.tasks tbody tr');
        rows[1].querySelector('.act button').click();
        await flush();
        expect(updateStatus.mock.calls[0][0]).toMatchObject({ taskId: 'T2', status: 'In Progress', requestKey: expect.stringMatching(/^CLOSE-TASK-T2-/) });
        rows = root.querySelectorAll('.tasks tbody tr');
        rows[2].querySelectorAll('.act button')[0].click();
        await flush();
        expect(root.querySelector('c-sab-modal').heading).toBe('Complete task');
        typeReason(root, 'IC-REC-0007');
        root.querySelector('.save').click();
        await flush();
        expect(updateStatus.mock.calls[1][0]).toMatchObject({ taskId: 'T3', status: 'Complete', evidenceReference: 'IC-REC-0007', blockedReason: null });
        rows = root.querySelectorAll('.tasks tbody tr');
        rows[1].querySelectorAll('.act button')[2].click();
        await flush();
        typeReason(root, 'Supplier statement missing');
        root.querySelector('.save').click();
        await flush();
        expect(updateStatus.mock.calls[2][0]).toMatchObject({ taskId: 'T2', status: 'Blocked', blockedReason: 'Supplier statement missing' });
        const assign = root.querySelector('.assign');
        assign.value = 'U2';
        assign.dispatchEvent(new CustomEvent('change'));
        await flush();
        expect(assignTask).toHaveBeenCalledWith({ taskId: 'T1', assigneeId: 'U2', dueDate: '2026-10-03' });
    });

    it('generates a checklist for a period without one and switches periods', async () => {
        getChecklist.mockResolvedValueOnce(checklist({ total: 0, complete: 0, blocked: 0, readyToClose: true, tasks: [] }));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[1].click();
        await flush();
        expect(root.querySelector('.close .panel-b .muted').textContent).toContain('No checklist for this period');
        expect(root.querySelector('.generate').textContent).toBe('Generate checklist');
        root.querySelector('.generate').click();
        await flush();
        expect(generateChecklist).toHaveBeenCalledWith({ periodId: 'P2' });
        getChecklist.mockResolvedValueOnce(checklist({ periodId: 'P1', periodStatus: 'Closed', complete: 4, blocked: 0, readyToClose: true,
            tasks: [{ taskId: 'T9', name: 'Done', status: 'Complete', evidenceRequired: false }], total: 4 }));
        const select = root.querySelector('.period-select');
        select.value = 'P1';
        select.dispatchEvent(new CustomEvent('change'));
        await flush();
        expect(root.querySelector('.close .banner').textContent).toContain('Ready to close');
        expect(root.querySelector('.generate').disabled).toBe(true);
        expect(root.querySelector('.generate').title).toBe('Tasks can change only while the period is open');
        expect(root.querySelectorAll('.tasks .act button').length).toBe(0);
    });

    it('explains missing permissions and empty states and opens period close', async () => {
        getWorkspace.mockResolvedValue(workspace({ canDecide: false, canRequest: false, canManageClose: false, inbox: [], myRequests: [], periods: [] }));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.inbox h3').textContent).toBe('Nothing waiting for you');
        expect(root.querySelector('.mine .panel-b.muted').textContent).toBe('You have no pending requests in this company.');
        const nav = jest.fn();
        el.addEventListener('sabnavigate', nav);
        root.querySelector('.open-close').click();
        expect(nav.mock.calls[0][0].detail.workspace).toBe('close');
        root.querySelectorAll('.tab')[1].click();
        await flush();
        expect(root.querySelector('.panel-b.muted').textContent).toBe('This company has no accounting periods around today yet.');
    });

    it('disables decisions and close management without permission', async () => {
        getWorkspace.mockResolvedValue(workspace({ canDecide: false, canRequest: false, canManageClose: false }));
        getChecklist.mockResolvedValue(checklist({ tasks: [{ taskId: 'T5', name: 'Mine', status: 'Not Started', assigneeId: 'U9', assignedToMe: true,
            evidenceRequired: false }, { taskId: 'T6', name: 'Theirs', status: 'Not Started', evidenceRequired: false }] }));
        const el = mount({ visibleWorkspaces: [] });
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.approve').title).toBe('Your role cannot decide approvals');
        expect(root.querySelector('.cancel-request').title).toBe('Your role cannot cancel approval requests');
        expect(root.querySelector('.open-close')).toBeNull();
        root.querySelectorAll('.tab')[1].click();
        await flush();
        const rows = root.querySelectorAll('.tasks tbody tr');
        expect(rows[0].querySelectorAll('.act button').length).toBe(3);
        expect(rows[1].querySelectorAll('.act button').length).toBe(0);
        expect(root.querySelector('.assign')).toBeNull();
        expect(root.querySelector('.generate').title).toBe('Your role cannot manage close tasks');
    });

    it('shows load errors with retry and checklist errors inline', async () => {
        getWorkspace.mockRejectedValueOnce({ body: { message: 'You do not have permission to view Approvals and close.' } });
        getChecklist.mockRejectedValue({ body: { message: 'The accounting period does not belong to this company.' } });
        updateStatus.mockRejectedValue({ message: 'boom' });
        const el = mount();
        await flush();
        expect(el.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have permission to view Approvals and close.');
        el.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        el.shadowRoot.querySelectorAll('.tab')[1].click();
        await flush();
        expect(el.shadowRoot.querySelector('.close .banner.t-bad').textContent).toBe('The accounting period does not belong to this company.');
        el.shadowRoot.querySelectorAll('.tab')[0].click();
        await flush();
        el.shadowRoot.querySelector('.reject').click();
        await flush();
        el.shadowRoot.querySelector('.cancel').click();
        await flush();
        expect(el.shadowRoot.querySelector('c-sab-modal').open).toBe(false);
    });
});
