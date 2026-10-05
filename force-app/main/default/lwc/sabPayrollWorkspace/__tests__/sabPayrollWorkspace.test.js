import { createElement } from 'lwc';
import SabPayrollWorkspace from 'c/sabPayrollWorkspace';
import getWorkspace from '@salesforce/apex/SABPayrollWorkspaceController.getWorkspace';
import getRunDetail from '@salesforce/apex/SABPayrollWorkspaceController.getRunDetail';
import getHrQueue from '@salesforce/apex/SABPayrollWorkspaceController.getHrQueue';
import calculateRun from '@salesforce/apex/SABPayrollCalculationService.calculate';
import postRun from '@salesforce/apex/SABPayrollPostingService.post';
import authorizePayment from '@salesforce/apex/SABPayrollSettlementService.authorizePayment';

jest.mock('@salesforce/apex/SABPayrollWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollWorkspaceController.getRunDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollWorkspaceController.getHrQueue', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABPayrollCalculationService.createDraft', () => ({ default: jest.fn() }), { virtual: true });
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

const COMPANY_ID = 'a00000000000001AAA';
const RUN = {
    runId: 'a01000000000001AAA', name: 'PR-0001', runKey: 'PAY-OCT', periodStart: '2026-10-01', periodEnd: '2026-10-31',
    state: 'Draft', currencyCode: 'BDT', netTotal: 0, settledAmount: 0, outstandingAmount: 0
};

function capabilities(overrides) {
    return { calculate: true, submit: true, approve: true, cancel: true, postPayroll: true, postJournal: true,
        processPayment: true, authorizePayment: true, manageCompensation: true, approveCompensation: true, ...overrides };
}

function workspace(runState, caps) {
    return {
        companyId: COMPANY_ID, companyName: 'Harbourline Trading', functionalCurrency: 'BDT', capabilities: capabilities(caps),
        runs: [{ ...RUN, state: runState }], stateCounts: [{ state: runState, count: 1 }], outstandingNetPay: 0,
        employments: [{ employmentId: 'a02000000000001AAA', employeeReference: 'EMP-1' },
            { employmentId: 'a02000000000002AAA', employeeReference: 'EMP-2' }],
        openPeriods: [{ label: '2026-10', value: 'a03000000000001AAA', startDate: '2026-10-01', endDate: '2026-10-31' }],
        payableAccounts: [{ label: '2300 Salary Payable', value: 'a04000000000001AAA' }],
        bankAccounts: [{ label: 'Operating (BDT)', value: 'a05000000000001AAA' }],
        paymentMethods: [{ label: 'Bank Transfer', value: 'Bank Transfer' }]
    };
}

function detail(runState, payment) {
    return { run: { ...RUN, state: runState }, lines: [], awards: [], payment };
}

// Test-only: let every pending Apex promise and re-render settle.
// eslint-disable-next-line @lwc/lwc/no-async-operation
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

async function mount() {
    const element = createElement('c-sab-payroll-workspace', { is: SabPayrollWorkspace });
    document.body.appendChild(element);
    await flush();
    await flush();
    return element;
}

async function selectRun(element) {
    const table = element.shadowRoot.querySelector('lightning-datatable');
    table.dispatchEvent(new CustomEvent('rowselection', { detail: { selectedRows: [{ ...RUN }] } }));
    await flush();
    await flush();
}

function button(element, cssClass) {
    return element.shadowRoot.querySelector(`lightning-button.${cssClass}`);
}

describe('c-sab-payroll-workspace', () => {
    beforeEach(() => {
        getHrQueue.mockResolvedValue({ pendingAssignments: [], awards: [] });
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        window.sessionStorage.clear();
        jest.clearAllMocks();
    });

    it('asks for a company when none is selected', async () => {
        const element = await mount();
        expect(element.shadowRoot.querySelector('.empty-state').textContent).toContain('Select an Accounting Company');
        expect(getWorkspace).not.toHaveBeenCalled();
    });

    it('loads the workspace for the stored company and lists runs', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANY_ID);
        getWorkspace.mockResolvedValue(workspace('Draft'));
        const element = await mount();
        expect(getWorkspace).toHaveBeenCalledWith({ companyId: COMPANY_ID });
        expect(element.shadowRoot.querySelector('.company-name').textContent).toBe('Harbourline Trading');
        expect(element.shadowRoot.querySelector('lightning-datatable').data).toHaveLength(1);
    });

    it('calculates a Draft run for every active employment by default', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANY_ID);
        getWorkspace.mockResolvedValue(workspace('Draft'));
        getRunDetail.mockResolvedValue(detail('Draft'));
        calculateRun.mockResolvedValue(RUN.runId);
        const element = await mount();
        await selectRun(element);
        button(element, 'calculate').click();
        await flush();
        expect(calculateRun).toHaveBeenCalledWith({ runId: RUN.runId,
            employmentIds: ['a02000000000001AAA', 'a02000000000002AAA'], minorUnits: 2 });
    });

    it('reuses the request key after a failure and issues a new one after success', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANY_ID);
        getWorkspace.mockResolvedValue(workspace('Approved'));
        getRunDetail.mockResolvedValue(detail('Approved'));
        postRun.mockRejectedValueOnce({ body: { message: 'Period locked' } }).mockResolvedValue({ replay: false });
        const element = await mount();
        await selectRun(element);
        const account = element.shadowRoot.querySelector('lightning-combobox[data-field="payableAccountId"]');
        account.dispatchEvent(new CustomEvent('change', { detail: { value: 'a04000000000001AAA' } }));
        await flush();
        button(element, 'post').click();
        await flush();
        await flush();
        expect(element.shadowRoot.querySelector('.error-banner').textContent).toBe('Period locked');
        button(element, 'post').click();
        await flush();
        await flush();
        const firstKey = postRun.mock.calls[0][0].requestKey;
        expect(postRun.mock.calls[1][0].requestKey).toBe(firstKey);
        expect(postRun.mock.calls[0][0]).toMatchObject({ runId: RUN.runId, periodId: 'a03000000000001AAA',
            accountingDate: '2026-10-31', payableAccountId: 'a04000000000001AAA' });
        // After success the key is discarded, so the next real post would get a fresh key.
        await selectRun(element);
        account.dispatchEvent(new CustomEvent('change', { detail: { value: 'a04000000000001AAA' } }));
        await flush();
        button(element, 'post').click();
        await flush();
        expect(postRun.mock.calls[2][0].requestKey).not.toBe(firstKey);
    });

    it('disables actions the user is not permitted to perform', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANY_ID);
        getWorkspace.mockResolvedValue(workspace('Submitted', { approve: false }));
        getRunDetail.mockResolvedValue(detail('Submitted'));
        const element = await mount();
        await selectRun(element);
        expect(button(element, 'approve').disabled).toBe(true);
    });

    it('offers authorization for a Draft payment and passes a request key', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANY_ID);
        getWorkspace.mockResolvedValue(workspace('Posted'));
        getRunDetail.mockResolvedValue(detail('Posted', { paymentId: 'a06000000000001AAA', name: 'PAY-1', state: 'Draft', amount: 19000 }));
        authorizePayment.mockResolvedValue({ paymentState: 'Authorized' });
        const element = await mount();
        await selectRun(element);
        expect(button(element, 'prepare')).toBeNull();
        button(element, 'authorize').click();
        await flush();
        expect(authorizePayment).toHaveBeenCalledWith({ runId: RUN.runId,
            requestKey: expect.stringMatching(/^G10G\|AUTHORIZE\|a06000000000001AAA\|/) });
    });

    it('keeps payroll tabs when the user has no compensation access', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANY_ID);
        getWorkspace.mockResolvedValue(workspace('Draft'));
        getHrQueue.mockRejectedValue({ body: { message: 'No access' } });
        const element = await mount();
        expect(element.shadowRoot.querySelector('.error-banner')).toBeNull();
        expect(element.shadowRoot.textContent).toContain('You do not have access to compensation approvals');
    });
});
