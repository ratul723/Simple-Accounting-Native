import { createElement } from 'lwc';
import SabExpensesWorkspace from 'c/sabExpensesWorkspace';
import getDashboard from '@salesforce/apex/SABExpenseOperationsWorkspaceController.getDashboard';
import getClaimDetail from '@salesforce/apex/SABExpenseOperationsWorkspaceController.getClaimDetail';
import submitClaim from '@salesforce/apex/SABExpenseClaimLifecycleService.submitClaim';
import approveClaim from '@salesforce/apex/SABExpenseClaimLifecycleService.approveClaim';
import rejectClaim from '@salesforce/apex/SABExpenseClaimLifecycleService.rejectClaim';
import postApprovedClaim from '@salesforce/apex/SABExpenseClaimPostingService.postApprovedClaim';
import authorizePayment from '@salesforce/apex/SABExpenseReimbursementPaymentService.authorizePayment';
import submitPayment from '@salesforce/apex/SABExpenseReimbursementPaymentService.submitPayment';
import postPayment from '@salesforce/apex/SABExpenseReimbursementPaymentService.recordSucceededAndPost';
import settleClaim from '@salesforce/apex/SABExpenseClaimSettlementService.settleClaim';
import reverseSettlement from '@salesforce/apex/SABExpenseClaimSettlementService.reverseSettlement';

jest.mock('@salesforce/apex/SABExpenseOperationsWorkspaceController.getDashboard', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABExpenseOperationsWorkspaceController.getClaimDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABExpenseClaimLifecycleService.submitClaim', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABExpenseClaimLifecycleService.approveClaim', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABExpenseClaimLifecycleService.rejectClaim', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABExpenseClaimPostingService.postApprovedClaim', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABExpenseReimbursementPaymentService.authorizePayment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABExpenseReimbursementPaymentService.submitPayment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABExpenseReimbursementPaymentService.recordSucceededAndPost', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABExpenseClaimSettlementService.settleClaim', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABExpenseClaimSettlementService.reverseSettlement', () => ({ default: jest.fn() }), { virtual: true });

const claim = (id, status, extra = {}) => ({ claimId: id, name: `EC-${id}`, claimantName: 'Maya Chen', claimDate: '2026-09-20', currencyCode: 'AUD', status,
    totalAmount: 300, paidAmount: 0, remainingAmount: 300, lineCount: 2, ...extra });
const pay = (id, state, extra = {}) => ({ paymentId: id, name: `PAY-${id}`, reference: 'Reimb', processingState: state, amount: 500, currencyCode: 'AUD',
    effectiveDate: '2026-09-25', bankAccountName: 'Operating', allocatedAmount: 0, remainingAmount: 500, ...extra });

function dash(overrides = {}) {
    return {
        functionalCurrency: 'AUD', canSubmitClaim: true, canReviewClaim: true, canPostClaim: true, canProcessReimbursement: true,
        submittedCount: 1, approvedCount: 1, postedCount: 1, partPaidCount: 0, paidCount: 2, rejectedCount: 1, reimbursementOutstanding: 300,
        claims: [claim('C1', 'Draft'), claim('C2', 'Submitted'), claim('C3', 'Approved'), claim('C4', 'Posted'), claim('C5', 'Rejected')],
        reimbursementPayments: [pay('P1', 'Draft'), pay('P2', 'Authorized'), pay('P3', 'Submitted'), pay('P4', 'Succeeded', { remainingAmount: 200 }), pay('P5', 'Failed')],
        ...overrides
    };
}

function detail(claimId) {
    return { claimId, lines: [{ lineId: 'L1', expenseDate: '2026-09-18', category: 'Travel', description: 'Taxi', amount: 100, expenseAccountCode: '6200', expenseAccountName: 'Travel',
        taxCode: 'GST', taxAmount: 9.09 }],
    settlements: [{ settlementId: 'S1', paymentName: 'PAY-P0', allocatedAmount: 50, effectiveDate: '2026-09-26', status: 'Effective' },
        { settlementId: 'S2', paymentName: 'PAY-P0', allocatedAmount: 10, effectiveDate: '2026-09-27', status: 'Reversed' }] };
}

async function flush() {
    for (let i = 0; i < 10; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-expenses-workspace', { is: SabExpensesWorkspace });
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
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-expenses-workspace', () => {
    beforeEach(() => {
        getDashboard.mockResolvedValue(dash());
        getClaimDetail.mockImplementation(({ claimId }) => Promise.resolve(detail(claimId)));
        [submitClaim, approveClaim, rejectClaim, postApprovedClaim, authorizePayment, submitPayment, postPayment, settleClaim, reverseSettlement].forEach((m) => m.mockResolvedValue({}));
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows figures and claims and runs the claim lifecycle', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(Array.from(root.querySelectorAll('.fig .v')).map((v) => v.textContent)).toEqual(['1', '1', '300AUD', '2']);
        expect(root.querySelectorAll('.sab-claims tbody tr').length).toBe(5);
        row(root, '.sab-claims', 0);
        await flush();
        expect(root.querySelector('.sab-claim-lines tbody tr').textContent).toContain('6200 Travel');
        root.querySelector('.sab-submit-claim').click();
        await flush();
        expect(submitClaim.mock.calls[0][0]).toMatchObject({ claimId: 'C1', requestKey: expect.stringMatching(/^EXP-SUBMIT-C1-/) });
        row(root, '.sab-claims', 1);
        await flush();
        root.querySelector('.sab-reject-claim').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('A reason is required.');
        setModal(root, 'reason', 'Missing receipt');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(rejectClaim.mock.calls[0][0]).toMatchObject({ claimId: 'C2', reason: 'Missing receipt' });
        root.querySelector('.sab-approve-claim').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(approveClaim.mock.calls[0][0]).toMatchObject({ claimId: 'C2', reason: null });
        row(root, '.sab-claims', 2);
        await flush();
        root.querySelector('.sab-post-claim').click();
        await flush();
        expect(postApprovedClaim.mock.calls[0][0].request).toMatchObject({ expenseClaimId: 'C3' });
        row(root, '.sab-claims', 4);
        await flush();
        expect(root.querySelector('c-sab-drawer .banner').textContent).toContain('Rejected');
    });

    it('applies and reverses reimbursements on a posted claim', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.sab-claims tbody tr')[3].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        expect(root.querySelectorAll('.sab-settlements tbody tr').length).toBe(2);
        expect(root.querySelectorAll('.sab-reverse-settlement').length).toBe(1);
        root.querySelector('.sab-reverse-settlement').click();
        await flush();
        expect(reverseSettlement.mock.calls[0][0]).toMatchObject({ settlementId: 'S1', reversalSettlementKey: expect.stringMatching(/^EXP-SETTLE-REV-S1-/) });
        root.querySelector('.sab-settle').click();
        await flush();
        expect(root.querySelector('c-sab-modal [data-field="amount"]').value).toBe('200');
        setModal(root, 'amount', '0');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('Choose a payment and an amount above zero.');
        setModal(root, 'paymentId', 'P4');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(settleClaim.mock.calls[0][0].request).toMatchObject({ expenseClaimId: 'C4', paymentId: 'P4', amount: 200 });
        root.querySelectorAll('.sab-claims tbody tr')[3].dispatchEvent(new KeyboardEvent('keydown', { key: 'x' }));
    });

    it('processes reimbursement payments', async () => {
        authorizePayment.mockRejectedValueOnce({ body: { message: 'Bank inactive.' } });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[1].click();
        await flush();
        row(root, '.sab-reimbursements', 0);
        await flush();
        root.querySelector('.sab-authorize').click();
        await flush();
        expect(toast.mock.calls[0][0].detail.tone).toBe('bad');
        root.querySelector('.sab-authorize').click();
        await flush();
        expect(authorizePayment.mock.calls[1][0].requestKey).toBe(authorizePayment.mock.calls[0][0].requestKey);
        row(root, '.sab-reimbursements', 1);
        await flush();
        root.querySelector('.sab-release').click();
        await flush();
        expect(submitPayment.mock.calls[0][0]).toMatchObject({ paymentId: 'P2', providerRequestKey: expect.stringMatching(/^EXP-PROVIDER-P2-/) });
        row(root, '.sab-reimbursements', 2);
        await flush();
        root.querySelector('.sab-clear').click();
        await flush();
        expect(postPayment.mock.calls[0][0]).toMatchObject({ paymentId: 'P3' });
        row(root, '.sab-reimbursements', 4);
        await flush();
        expect(root.querySelector('c-sab-drawer .banner').textContent).toContain('Bank rejected');
        root.querySelector('c-sab-drawer').dispatchEvent(new CustomEvent('close'));
        await flush();
        expect(root.querySelector('c-sab-drawer').open).toBe(false);
    });

    it('explains permissions and handles empty and error states', async () => {
        getDashboard.mockResolvedValue(dash({ canSubmitClaim: false, canReviewClaim: false, canPostClaim: false, canProcessReimbursement: false,
            reimbursementPayments: [pay('P1', 'Draft')] }));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        row(root, '.sab-claims', 0);
        await flush();
        expect(root.querySelector('.sab-submit-claim').title).toBe('Bookkeeper role cannot submit expense claims');
        row(root, '.sab-claims', 3);
        await flush();
        expect(root.querySelector('.sab-settle').title).toBe('Bookkeeper role cannot settle reimbursements');
        expect(root.querySelector('.sab-reverse-settlement')).toBeNull();

        getDashboard.mockResolvedValueOnce(dash({ claims: [], reimbursementPayments: [] }));
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty h3').textContent).toBe('No expense claims yet');
        el2.shadowRoot.querySelectorAll('.tab')[1].click();
        await flush();
        expect(el2.shadowRoot.querySelector('.panel-b.muted').textContent).toBe('No reimbursement payments yet.');

        getClaimDetail.mockRejectedValueOnce({ body: { message: 'Claim not accessible.' } });
        const el3 = mount();
        await flush();
        row(el3.shadowRoot, '.sab-claims', 0);
        await flush();
        expect(el3.shadowRoot.querySelector('c-sab-drawer .banner').textContent).toBe('Claim not accessible.');

        getDashboard.mockRejectedValueOnce({ body: { message: 'You do not have permission to view Expense Operations.' } });
        const el4 = mount();
        await flush();
        expect(el4.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have permission to view Expense Operations.');
        el4.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        row(el4.shadowRoot, '.sab-claims', 3);
        await flush();
        el4.shadowRoot.querySelector('.sab-settle').click();
        await flush();
        el4.shadowRoot.querySelector('.sab-modal-close').click();
    });

    it('creates and edits expense claims in the document editor', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        const editor = root.querySelector('c-sab-document-editor');
        root.querySelector('.sab-new-claim').click();
        await flush();
        expect(editor.kind).toBe('claim');
        expect(editor.open).toBe(true);
        editor.dispatchEvent(new CustomEvent('saved', { detail: { recordId: 'C1' } }));
        await flush();
        expect(root.querySelector('c-sab-drawer').heading).toBe('EC-C1');
        root.querySelector('.sab-edit-claim').click();
        await flush();
        expect(editor.recordId).toBe('C1');
        editor.dispatchEvent(new CustomEvent('close'));
    });
});
