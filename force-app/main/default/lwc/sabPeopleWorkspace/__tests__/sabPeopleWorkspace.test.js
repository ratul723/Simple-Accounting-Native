import { createElement } from 'lwc';
import SabPeopleWorkspace from 'c/sabPeopleWorkspace';
import getSummary from '@salesforce/apex/SABPayrollSummaryController.getSummary';
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

jest.mock('@salesforce/apex/SABPayrollSummaryController.getSummary', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollWorkspaceController.getRunDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollWorkspaceController.getHrQueue', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollCalculationService.createDraftForWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollCalculationService.calculate', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollReviewService.submit', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollReviewService.approve', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollReviewService.cancel', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollPostingService.post', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollSettlementService.preparePayment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollSettlementService.authorizePayment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollSettlementService.submitPayment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollSettlementService.recordPaymentSucceeded', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollSettlementService.recordPaymentFailed', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollSettlementService.recordLineReturn', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEmployeeCompensationService.approveAssignment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEmployeeCompensationService.approveBenefitAward', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEmployeeCompensationService.cancelBenefitAward', () => ({ default: jest.fn() }), { virtual: true });

const ALL = [createDraftForWorkspace, calculateRun, submitRun, approveRun, cancelRun, postRun, preparePayment, authorizePayment, submitPayment,
    recordPaymentSucceeded, recordPaymentFailed, recordLineReturn, approveAssignment, approveBenefitAward, cancelBenefitAward];

const run = (state, extra = {}) => ({ runId: 'R1', name: 'PR-0009', periodStart: '2026-09-01', periodEnd: '2026-09-30', accountingDate: '2026-09-30', state,
    grossTotal: 48250, deductionTotal: 9100, employerTotal: 5300, netTotal: 39150, settledAmount: 0, employeeCount: 8, ...extra });

function summary(state = 'Calculated', overrides = {}) {
    return {
        currencyCode: 'AUD', canViewDetail: true, selectedRunId: 'R1',
        runs: [run(state), { ...run('Settled'), runId: 'R0', name: 'PR-0008' }],
        departments: [{ name: 'Operations', gross: 30000, share: 62.2 }, { name: 'Unassigned', gross: 18250, share: 37.8 }],
        journalLines: [{ accountCode: '6000', accountName: 'Wages', debit: 48250, credit: 0 }, { accountCode: '2300', accountName: 'Payroll payable', debit: 0, credit: 48250 }],
        journalName: 'JE-000315', journalId: 'J1', postedAt: '2026-09-23T02:00:00.000Z', postedBy: 'Alex Morgan',
        ...overrides
    };
}

const CAPS = { calculate: true, submit: true, approve: true, cancel: true, postPayroll: true, postJournal: true, processPayment: true, authorizePayment: true,
    manageCompensation: true, approveCompensation: true };

function workspace(caps = CAPS) {
    return {
        functionalCurrency: 'AUD', capabilities: caps,
        employments: [{ employmentId: 'E1', status: 'Active' }, { employmentId: 'E2', status: 'Ended' }],
        openPeriods: [{ value: 'P1', label: 'FY27-P03', startDate: '2026-09-01', endDate: '2026-09-30' }],
        payableAccounts: [{ value: 'G1', label: '2300 Payroll payable' }],
        bankAccounts: [{ value: 'B1', label: 'Operating' }],
        paymentMethods: [{ value: 'EFT', label: 'EFT' }]
    };
}

function detail(payment, lineExtra = {}) {
    return {
        lines: [{ lineId: 'PL1', employeeReference: 'EMP-001', grossAmount: 6000, deductionAmount: 1200, employerContribution: 700, netAmount: 4800,
            settledAmount: 4800, outstandingAmount: 0, effectiveSettlementId: 'ST1', ...lineExtra },
        { lineId: 'PL2', employeeReference: 'EMP-002', grossAmount: 5000, deductionAmount: 900, employerContribution: 600, netAmount: 4100, settledAmount: 0, outstandingAmount: 4100 }],
        payment
    };
}

async function flush() {
    for (let i = 0; i < 10; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(persona = { key: 'HR', label: 'HR' }, props = {}) {
    const el = createElement('c-sab-people-workspace', { is: SabPeopleWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', persona, visibleWorkspaces: ['journal'], ...props });
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

function setModal(root, field, value) {
    const input = root.querySelector(`c-sab-modal [data-field="${field}"]`);
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-people-workspace', () => {
    beforeEach(() => {
        getSummary.mockResolvedValue(summary());
        getWorkspace.mockResolvedValue(workspace());
        getRunDetail.mockResolvedValue(detail(undefined));
        getHrQueue.mockResolvedValue({
            awards: [{ awardId: 'A1', awardKey: 'BA-0033', employeeReference: 'EMP-003', category: 'Incentive', amount: 300, status: 'Proposed' },
                { awardId: 'A2', awardKey: 'BA-0031', employeeReference: 'EMP-001', category: 'Incentive', amount: 1000, status: 'Consumed' }],
            pendingAssignments: [{ assignmentId: 'S1', employeeReference: 'EMP-002', componentName: 'Food allowance', category: 'Allowance', amount: 200,
                effectiveFrom: '2026-10-01', status: 'Draft' }]
        });
        ALL.forEach((m) => m.mockResolvedValue('X'));
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows the HR preparation view with stepper, lines, awards and approvals', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-views .on').textContent).toBe('HR preparation');
        expect(Array.from(root.querySelectorAll('.run-card .hstep')).map((s) => s.className).slice(0, 3)).toEqual(['hstep done', 'hstep done', 'hstep now']);
        expect(Array.from(root.querySelectorAll('.fig .v')).map((v) => v.textContent)).toEqual(['8', '48,250AUD', '9,100AUD', '39,150AUD']);
        expect(root.querySelector('.sab-lines tfoot').textContent).toBe('Total11,000.002,100.001,300.008,900.00');
        expect(root.querySelector('.sab-calculate').textContent).toBe('Recalculate');
        root.querySelector('.sab-calculate').click();
        await flush();
        expect(calculateRun).toHaveBeenCalledWith({ runId: 'R1', employmentIds: ['E1'], minorUnits: 2 });
        root.querySelector('.sab-submit').click();
        await flush();
        expect(submitRun).toHaveBeenCalledWith({ runId: 'R1' });
        root.querySelector('.sab-approve-award').click();
        await flush();
        expect(approveBenefitAward).toHaveBeenCalledWith({ awardId: 'A1' });
        root.querySelector('.sab-cancel-award').click();
        await flush();
        expect(cancelBenefitAward).toHaveBeenCalledWith({ awardId: 'A1' });
        root.querySelector('.sab-approve-assignment').click();
        await flush();
        expect(approveAssignment).toHaveBeenCalledWith({ assignmentId: 'S1' });
    });

    it('approves and cancels runs and creates a new run', async () => {
        getSummary.mockResolvedValue(summary('Submitted'));
        cancelRun.mockRejectedValueOnce({ body: { message: 'Run changed.' } });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelector('.sab-approve').click();
        await flush();
        expect(approveRun).toHaveBeenCalledWith({ runId: 'R1' });
        root.querySelector('.sab-cancel-run').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('A reason is required.');
        setModal(root, 'reason', 'Wrong period');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(toast.mock.calls[toast.mock.calls.length - 1][0].detail.tone).toBe('bad');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(cancelRun).toHaveBeenLastCalledWith({ runId: 'R1', reason: 'Wrong period' });
        root.querySelector('.sab-new-run').click();
        await flush();
        expect(root.querySelector('c-sab-modal').heading).toBe('New payroll run');
        createDraftForWorkspace.mockRejectedValueOnce({ body: { message: 'Overlapping run.' } });
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('Overlapping run.');
        createDraftForWorkspace.mockResolvedValueOnce('R2');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(createDraftForWorkspace.mock.calls[1][0]).toMatchObject({ currencyCode: 'AUD' });
        root.querySelector('.sab-modal-close').click();
    });

    it('shows finance posting with journal and departments and posts an approved run', async () => {
        getSummary.mockResolvedValue(summary('Approved'));
        const el = mount({ key: 'FINANCE_MANAGER', label: 'Finance Manager' });
        await flush();
        const nav = jest.fn();
        el.addEventListener('sabnavigate', nav);
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-views .on').textContent).toBe('Finance posting');
        expect(root.querySelector('.sab-journal h2').textContent).toBe('Payroll journal JE-000315');
        expect(root.querySelector('.sab-journal tfoot').textContent).toBe('Total48,250.0048,250.00');
        expect(root.querySelector('.sab-departments tbody tr').textContent).toContain('62.2%');
        root.querySelector('.sab-open-journal').click();
        expect(nav.mock.calls[0][0].detail).toEqual({ workspace: 'journal', recordId: 'J1' });
        root.querySelector('.sab-post').click();
        await flush();
        expect(root.querySelector('c-sab-modal [data-field="periodId"]').value).toBe('P1');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(postRun.mock.calls[0][0]).toMatchObject({ runId: 'R1', periodId: 'P1', accountingDate: '2026-09-30', payableAccountId: 'G1',
            requestKey: expect.stringMatching(/^PAYROLL-POST-R1-/) });
    });

    it('runs treasury settlement from prepare to paid, failure and bank return', async () => {
        getSummary.mockResolvedValue(summary('Posted'));
        const el = mount({ key: 'TREASURY', label: 'Treasury' });
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.banner.t-warn').textContent).toContain('Net pay is ready to release');
        root.querySelector('.sab-prepare').click();
        await flush();
        setModal(root, 'reference', 'Sept net pay');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(preparePayment.mock.calls[0][0]).toMatchObject({ runId: 'R1', bankAccountId: 'B1', method: 'EFT', reference: 'Sept net pay' });

        getRunDetail.mockResolvedValue(detail({ paymentId: 'PAY1', name: 'PAY-000230', state: 'Draft', amount: 39150, effectiveDate: '2026-09-26' }));
        await el.shadowRoot.querySelector('.sab-run').dispatchEvent(new CustomEvent('change'));
        await flush();
        root.querySelector('.sab-authorize').click();
        await flush();
        expect(authorizePayment.mock.calls[0][0]).toMatchObject({ runId: 'R1' });

        getRunDetail.mockResolvedValue(detail({ paymentId: 'PAY1', name: 'PAY-000230', state: 'Authorized', amount: 39150 }));
        root.querySelector('.sab-run').dispatchEvent(new CustomEvent('change'));
        await flush();
        root.querySelector('.sab-release').click();
        await flush();
        expect(submitPayment.mock.calls[0][0]).toMatchObject({ providerRequestKey: expect.stringMatching(/^PROVIDER-PAY1-/) });

        getRunDetail.mockResolvedValue(detail({ paymentId: 'PAY1', name: 'PAY-000230', state: 'Submitted', amount: 39150 }));
        root.querySelector('.sab-run').dispatchEvent(new CustomEvent('change'));
        await flush();
        root.querySelector('.sab-failed').click();
        await flush();
        setModal(root, 'reason', 'Account closed');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(recordPaymentFailed.mock.calls[0][0]).toMatchObject({ reason: 'Account closed' });
        root.querySelector('.sab-succeeded').click();
        await flush();
        expect(recordPaymentSucceeded).toHaveBeenCalled();
        root.querySelector('.sab-return').click();
        await flush();
        setModal(root, 'reason', 'Returned by bank');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(recordLineReturn.mock.calls[0][0]).toMatchObject({ settlementId: 'ST1', reason: 'Returned by bank' });
    });

    it('shows aggregate payroll for directors and restricted users', async () => {
        getSummary.mockResolvedValue(summary('Settled', { canViewDetail: false }));
        const el = mount({ key: 'DIRECTOR', label: 'Director' });
        await flush();
        const root = el.shadowRoot;
        expect(getWorkspace).not.toHaveBeenCalled();
        expect(root.querySelector('.banner').textContent).toContain('Directors see aggregate payroll cost');
        root.querySelectorAll('.sab-views button')[0].click();
        await flush();
        expect(root.querySelector('.sab-lines .panel-b.muted').textContent).toContain('hidden for your role');
        expect(root.querySelector('.sab-new-run').title).toBe('Payroll detail permission is required');
        root.querySelectorAll('.sab-views button')[2].click();
        await flush();
        expect(root.querySelector('.banner.t-good').textContent).toContain('Net pay released');
        expect(root.querySelector('.sab-settlement .panel-b.muted').textContent).toBe('Hidden for your role.');

        const el2 = mount({ key: 'AUDITOR', label: 'Auditor' });
        await flush();
        expect(el2.shadowRoot.querySelector('.banner').textContent).toContain('Payroll detail is restricted');
    });

    it('explains missing capabilities and handles empty and error states', async () => {
        getWorkspace.mockResolvedValue(workspace({ ...CAPS, calculate: false, submit: false, postPayroll: false }));
        getSummary.mockResolvedValue(summary('Draft'));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-calculate').title).toBe('HR role cannot calculate payroll');
        expect(root.querySelector('.sab-new-run').title).toBe('HR role cannot create payroll runs');

        getSummary.mockResolvedValueOnce({ ...summary(), runs: [], selectedRunId: null, departments: [], journalLines: [] });
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty h3').textContent).toBe('No payroll runs yet');

        getSummary.mockResolvedValueOnce(summary('Cancelled', { journalLines: [], journalName: null, departments: [] }));
        const el3 = mount({ key: 'FINANCE_MANAGER', label: 'Finance Manager' });
        await flush();
        expect(el3.shadowRoot.querySelector('.run-card .banner').textContent).toContain('cancelled');
        expect(el3.shadowRoot.querySelector('.sab-journal .panel-b.muted').textContent).toBe('This run has not been posted yet.');

        getSummary.mockRejectedValueOnce({ body: { message: 'You do not have access to payroll runs.' } });
        const el4 = mount();
        await flush();
        expect(el4.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have access to payroll runs.');
        el4.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        expect(el4.shadowRoot.querySelector('.figs')).not.toBeNull();
    });

    it('shows the employees view and reloads when employees change', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        const views = root.querySelectorAll('.sab-views button');
        views[views.length - 1].click();
        await flush();
        const staff = root.querySelector('c-sab-employees');
        expect(staff).not.toBeNull();
        const calls = getWorkspace.mock.calls.length;
        staff.dispatchEvent(new CustomEvent('changed'));
        await flush();
        expect(getWorkspace.mock.calls.length).toBeGreaterThan(calls);
    });
});
