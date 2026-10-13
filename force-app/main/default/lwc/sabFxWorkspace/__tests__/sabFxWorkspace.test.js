import { createElement } from 'lwc';
import SabFxWorkspace from 'c/sabFxWorkspace';
import getDashboard from '@salesforce/apex/SABFXOperationsWorkspaceController.getDashboard';
import getTargets from '@salesforce/apex/SABFXOperationsWorkspaceController.getEligibleSettlementTargets';
import previewRevaluation from '@salesforce/apex/SABFXRevaluationPreviewService.preview';
import approveRun from '@salesforce/apex/SABFXRevaluationPostingService.approveRun';
import postApprovedRun from '@salesforce/apex/SABFXRevaluationPostingService.postApprovedRun';
import reversePostedRun from '@salesforce/apex/SABFXRevaluationReversalService.reversePostedRun';
import authorizeForeignPayment from '@salesforce/apex/SABForeignCurrencySettlementService.authorizeForeignPayment';
import submitForeignPayment from '@salesforce/apex/SABForeignCurrencySettlementService.submitForeignPayment';
import postForeignPayment from '@salesforce/apex/SABForeignCurrencySettlementService.postForeignPayment';
import allocateForeignPayment from '@salesforce/apex/SABForeignCurrencySettlementService.allocateForeignPayment';
import reverseForeignAllocation from '@salesforce/apex/SABForeignCurrencySettlementService.reverseForeignAllocation';

jest.mock('@salesforce/apex/SABFXOperationsWorkspaceController.getDashboard', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFXOperationsWorkspaceController.getEligibleSettlementTargets', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFXRevaluationPreviewService.preview', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFXRevaluationPostingService.approveRun', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFXRevaluationPostingService.postApprovedRun', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFXRevaluationReversalService.reversePostedRun', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABForeignCurrencySettlementService.authorizeForeignPayment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABForeignCurrencySettlementService.submitForeignPayment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABForeignCurrencySettlementService.postForeignPayment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABForeignCurrencySettlementService.allocateForeignPayment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABForeignCurrencySettlementService.reverseForeignAllocation', () => ({ default: jest.fn() }), { virtual: true });

const run = (id, status, extra = {}) => ({ runId: id, name: `FXR-${id}`, runKey: `KEY-${id}`, accountingPeriodName: '2026-09', rateSetKey: 'RBA', reversalPolicy: 'First Day of Next Period',
    status, lineCount: 2, arLineCount: 1, apLineCount: 1, signedAdjustmentTotal: -120, approvedByName: 'Daniel', postedAt: '2026-09-30T02:00:00.000Z',
    lines: [{ lineId: 'L1', sourceType: 'Invoice', sourceGLAccountCode: '1200', sourceGLAccountName: 'AR', transactionCurrency: 'USD', outstandingAmount: 1000,
        carryingAmount: 1500, appliedRate: 1.38, revaluedAmount: 1380, adjustmentAmount: -120 }], ...extra });
const pay = (id, state, extra = {}) => ({ paymentId: id, name: `PAY-${id}`, direction: 'Receipt', partyProfileName: 'Acme US', processingState: state, amount: 1000,
    transactionCurrency: 'USD', functionalCurrency: 'AUD', exchangeRate: 1.4, effectiveDate: '2026-09-25', activeAllocatedAmount: 0, unallocatedAmount: 1000, ...extra });

function dash(overrides = {}) {
    return {
        functionalCurrency: 'AUD', canRunRevaluation: true, canApproveRevaluation: true, canPostRevaluation: true, canReverseRevaluation: true,
        canProcessForeignSettlement: true, canPostRealizedFX: true, canReverseRealizedFX: true, unrealizedAccountsConfigured: true, realizedAccountsConfigured: false,
        previewRunCount: 1, approvedRunCount: 1, postedRunCount: 1, reversedRunCount: 0, postedRealizedGainTotal: 50, postedRealizedLossTotal: 20,
        periods: [{ periodId: 'P8', name: '2026-08', label: 'Aug 2026', status: 'Closed' }, { periodId: 'P9', name: '2026-09', label: 'Sep 2026', status: 'Open' }],
        revaluationRuns: [run('R1', 'Preview'), run('R2', 'Approved'), run('R3', 'Posted'), run('R4', 'Reversed', { lines: [] })],
        foreignPayments: [pay('F1', 'Draft'), pay('F2', 'Authorized'), pay('F3', 'Submitted'), pay('F4', 'Succeeded'), pay('F5', 'Failed')],
        allocations: [{ allocationId: 'A1', paymentReference: 'PAY-F4', targetName: 'INV-1', targetType: 'Invoice', status: 'Allocated', documentAmount: 500, transactionCurrency: 'USD',
            effectiveDate: '2026-09-26', realizedFXAmount: -15 }, { allocationId: 'A2', status: 'Reversed', realizedFXAmount: 0 }],
        ...overrides
    };
}

async function flush() {
    for (let i = 0; i < 10; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-fx-workspace', { is: SabFxWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', persona: { label: 'Bookkeeper' }, ...props });
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

function row(root, selector, index) {
    root.querySelectorAll(`${selector} tbody tr`)[index].click();
}

function setModal(root, field, value) {
    const input = root.querySelector(`c-sab-modal [data-field="${field}"]`);
    if (input.type === 'checkbox') {
        input.checked = value;
        input.dispatchEvent(new CustomEvent('change'));
        return;
    }
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-fx-workspace', () => {
    beforeEach(() => {
        getDashboard.mockResolvedValue(dash());
        getTargets.mockResolvedValue([{ targetId: 'I1', targetType: 'Invoice', documentNumber: 'INV-1', outstandingAmount: 600, transactionCurrency: 'USD' },
            { targetId: 'B1', targetType: 'Supplier Bill', name: 'BILL-1', outstandingAmount: 300, transactionCurrency: 'USD' }]);
        previewRevaluation.mockResolvedValue({ runId: 'R1' });
        [approveRun, postApprovedRun, reversePostedRun, authorizeForeignPayment, submitForeignPayment, postForeignPayment, allocateForeignPayment, reverseForeignAllocation]
            .forEach((m) => m.mockResolvedValue({}));
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows figures, setup warning and runs, and takes a run from preview to reversal', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(Array.from(root.querySelectorAll('.fig .v')).map((v) => v.textContent)).toEqual(['1', '1', '50AUD', '20AUD']);
        expect(root.querySelector('.banner.t-warn').textContent).toContain('realized gain and loss accounts');
        expect(root.querySelectorAll('.sab-runs tbody tr')[0].textContent).toContain('1 AR, 1 AP');
        root.querySelector('.sab-new-run').click();
        await flush();
        expect(root.querySelector('c-sab-modal [data-field="periodId"]').value).toBe('P9');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(previewRevaluation.mock.calls[0][0].request).toMatchObject({ accountingPeriodId: 'P9', reversalPolicy: 'First Day of Next Period' });
        expect(root.querySelector('c-sab-drawer').heading).toBe('FXR-R1');
        expect(root.querySelector('.sab-run-lines tbody tr').textContent).toContain('1,000.00 USD');
        root.querySelector('.sab-approve-run').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(approveRun.mock.calls[0][0]).toMatchObject({ runId: 'R1', reason: null });
        row(root, '.sab-runs', 1);
        await flush();
        root.querySelector('.sab-post-run').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(postApprovedRun.mock.calls[0][0]).toMatchObject({ runId: 'R2' });
        row(root, '.sab-runs', 2);
        await flush();
        root.querySelector('.sab-reverse-run').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('A reason is required.');
        setModal(root, 'manual', true);
        await flush();
        setModal(root, 'periodId', 'P9');
        setModal(root, 'reversalDate', '2026-10-01');
        setModal(root, 'reason', 'Wrong rates');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(reversePostedRun.mock.calls[0][0]).toMatchObject({ runId: 'R3', requestedReversalPeriodId: 'P9', requestedReversalDate: '2026-10-01', reason: 'Wrong rates' });
        row(root, '.sab-runs', 3);
        await flush();
        expect(root.querySelector('c-sab-drawer .banner').textContent).toContain('Reversed');
        expect(root.querySelector('c-sab-drawer').textContent).toContain('No open foreign-currency balances');
    });

    it('processes foreign payments and allocates them', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[1].click();
        await flush();
        row(root, '.sab-fx-payments', 0);
        await flush();
        root.querySelector('.sab-authorize').click();
        await flush();
        expect(authorizeForeignPayment.mock.calls[0][0]).toMatchObject({ paymentId: 'F1' });
        row(root, '.sab-fx-payments', 1);
        await flush();
        root.querySelector('.sab-release').click();
        await flush();
        expect(submitForeignPayment.mock.calls[0][0]).toMatchObject({ paymentId: 'F2', providerRequestKey: expect.stringMatching(/^FX-PROVIDER-F2-/) });
        row(root, '.sab-fx-payments', 2);
        await flush();
        root.querySelector('.sab-clear').click();
        await flush();
        expect(postForeignPayment.mock.calls[0][0]).toMatchObject({ paymentId: 'F3' });
        root.querySelectorAll('.sab-fx-payments tbody tr')[3].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        expect(root.querySelector('c-sab-drawer').textContent).toContain('1.4 AUD per USD');
        root.querySelector('.sab-allocate').click();
        await flush();
        expect(root.querySelector('c-sab-modal [data-field="amount"]').value).toBe('600');
        setModal(root, 'targetId', 'B1');
        setModal(root, 'amount', '300');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(allocateForeignPayment.mock.calls[0][0]).toMatchObject({ paymentId: 'F4', requests: [{ invoiceId: null, supplierBillId: 'B1', amount: 300 }] });
        row(root, '.sab-fx-payments', 4);
        await flush();
        expect(root.querySelector('c-sab-drawer .banner').textContent).toContain('Bank rejected');
        root.querySelectorAll('.sab-fx-payments tbody tr')[3].dispatchEvent(new KeyboardEvent('keydown', { key: 'q' }));
    });

    it('reverses a settlement and validates allocation input', async () => {
        getTargets.mockResolvedValueOnce([]);
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[2].click();
        await flush();
        expect(root.querySelectorAll('.sab-reverse-allocation').length).toBe(1);
        root.querySelector('.sab-reverse-allocation').click();
        await flush();
        setModal(root, 'reason', 'Wrong invoice');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(reverseForeignAllocation.mock.calls[0][0]).toMatchObject({ allocationId: 'A1', reason: 'Wrong invoice' });
        root.querySelectorAll('.tab')[1].click();
        await flush();
        row(root, '.sab-fx-payments', 3);
        await flush();
        root.querySelector('.sab-allocate').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('Choose an open document and an amount above zero.');
        root.querySelector('.sab-modal-close').click();
        await flush();
        root.querySelector('c-sab-drawer').dispatchEvent(new CustomEvent('close'));
    });

    it('explains permissions and handles empty and error states', async () => {
        getDashboard.mockResolvedValue(dash({ canRunRevaluation: false, canApproveRevaluation: false, canProcessForeignSettlement: false, unrealizedAccountsConfigured: false }));
        getTargets.mockRejectedValueOnce({ body: { message: 'Payment not eligible.' } });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-new-run').title).toBe('Bookkeeper role cannot run revaluations');
        expect(root.querySelector('.banner.t-warn').textContent).toContain('unrealized gain and loss accounts');
        row(root, '.sab-runs', 0);
        await flush();
        expect(root.querySelector('.sab-approve-run').title).toBe('Bookkeeper role cannot approve revaluations');
        root.querySelectorAll('.tab')[1].click();
        await flush();
        row(root, '.sab-fx-payments', 2);
        await flush();
        expect(root.querySelector('.sab-clear').title).toBe('Bookkeeper role cannot process foreign payments');

        getDashboard.mockResolvedValueOnce(dash({ revaluationRuns: [], foreignPayments: [], allocations: [], realizedAccountsConfigured: true }));
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty h3').textContent).toBe('No revaluation runs yet');
        expect(el2.shadowRoot.querySelector('.banner.t-warn')).toBeNull();
        el2.shadowRoot.querySelectorAll('.tab')[1].click();
        await flush();
        expect(el2.shadowRoot.querySelector('.panel-b.muted').textContent).toBe('No foreign-currency payments.');
        el2.shadowRoot.querySelectorAll('.tab')[2].click();
        await flush();
        expect(el2.shadowRoot.querySelector('.panel-b.muted').textContent).toBe('No foreign-currency settlements yet.');

        getDashboard.mockRejectedValueOnce({ body: { message: 'You do not have permission to view the FX Operations Workspace.' } });
        const el3 = mount();
        await flush();
        expect(el3.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have permission to view the FX Operations Workspace.');
        getDashboard.mockResolvedValue(dash());
        el3.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        el3.shadowRoot.querySelectorAll('.tab')[1].click();
        await flush();
        row(el3.shadowRoot, '.sab-fx-payments', 3);
        await flush();
        el3.shadowRoot.querySelector('.sab-allocate').click();
        await flush();
        expect(el3.shadowRoot.querySelector('.form-error').textContent).toBe('Payment not eligible.');
    });
});
