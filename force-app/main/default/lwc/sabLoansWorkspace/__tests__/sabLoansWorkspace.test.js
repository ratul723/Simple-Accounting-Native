import { createElement } from 'lwc';
import SabLoansWorkspace from 'c/sabLoansWorkspace';
import getWorkspace from '@salesforce/apex/SABLoansInvestmentsWorkspaceController.getWorkspace';
import getFormOptions from '@salesforce/apex/SABLoansInvestmentsWorkspaceController.getFormOptions';
import saveDraft from '@salesforce/apex/SABLoanService.saveDraft';
import approveLoan from '@salesforce/apex/SABLoanService.approve';
import accrueInterest from '@salesforce/apex/SABLoanService.accrueInterest';
import recordRepayment from '@salesforce/apex/SABLoanService.recordRepayment';
import saveInvestment from '@salesforce/apex/SABInvestmentService.saveInvestment';
import recordTransaction from '@salesforce/apex/SABInvestmentService.recordTransaction';

jest.mock('@salesforce/apex/SABLoansInvestmentsWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABLoansInvestmentsWorkspaceController.getFormOptions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABLoanService.saveDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABLoanService.approve', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABLoanService.accrueInterest', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABLoanService.recordRepayment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABInvestmentService.saveInvestment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABInvestmentService.recordTransaction', () => ({ default: jest.fn() }), { virtual: true });

const LINES = [
    { lineId: 'L1', sequence: 1, dueDate: '2026-07-01', payment: 4937.12, interest: 1239.17, principalDue: 3697.95, balance: 216177.7, status: 'Paid' },
    { lineId: 'L2', sequence: 2, dueDate: '2026-10-01', payment: 4937.12, interest: 1212.91, principalDue: 3724.21, balance: 212453.49, status: 'Due' },
    { lineId: 'L3', sequence: 3, dueDate: '2026-11-01', payment: 4937.12, interest: 1191.64, principalDue: 3745.48, balance: 208708.01, status: 'Planned' }
];

function workspace(overrides = {}) {
    return {
        currencyCode: 'AUD', userId: '005A', canManageLoans: true, canApproveLoans: true, canManageInvestments: true, canPostJournal: true,
        loansAvailable: true, investmentsAvailable: true, borrowings: 216177.7, borrowingCount: 1, lending: 0, interestThisQuarter: 1212.91,
        interestLoanCount: 1, investmentsTotal: 65840, incomeYearToDate: 1120, fiscalYearStart: '2026-07-01',
        loans: [
            { loanId: 'LN2', name: 'CBA business loan', loanType: 'Borrowing', counterparty: 'Commonwealth Bank', principalAccountCode: '2500',
                principal: 250000, rate: 6.85, status: 'Active', createdByMe: false, balance: 216177.7, repaid: 33822.3,
                nextDueDate: '2026-10-01', nextPayment: 4937.12, nextLineId: 'L2', nextAction: 'repay', lines: LINES },
            { loanId: 'LN3', name: 'Director loan', loanType: 'Shareholder Loan', counterparty: 'Daniel Harper', principal: 25000, rate: 0,
                status: 'Draft', createdByMe: true, balance: 25000, repaid: 0, lines: [], startDate: '2026-10-01', maturityDate: '2027-10-01',
                frequency: 'Monthly', method: 'Annuity' }
        ],
        investments: [
            { investmentId: 'IV1', name: 'ANZ term deposit', instrumentKey: 'TD-1', classification: 'Term deposit', valuationPolicy: 'COST',
                status: 'Active', accountCode: '1700', quantity: 1, carryingAmount: 50000, cost: 50000, incomeYearToDate: 1120 },
            { investmentId: 'IV2', name: 'AgriFund units', instrumentKey: 'AGF', classification: 'Managed fund', valuationPolicy: 'FVTPL',
                status: 'Active', accountCode: '1710', quantity: 1500, carryingAmount: 15840, cost: 15000, incomeYearToDate: 0 }
        ],
        transactions: [
            { transactionId: 'T1', investmentId: 'IV1', investmentName: 'ANZ term deposit', transactionType: 'Income', transactionDate: '2026-09-14',
                amount: 1120, quantity: null, gainLoss: null, posted: true }
        ],
        ...overrides
    };
}

const OPTIONS = {
    counterparties: [{ value: 'ACC1', label: 'Commonwealth Bank' }],
    glAccounts: [
        { value: 'GL1', label: '1000 Bank', kind: 'Asset' }, { value: 'GL2', label: '2500 Loan payable', kind: 'Liability' },
        { value: 'GL3', label: '6800 Interest expense', kind: 'Expense' }, { value: 'GL4', label: '4700 Interest income', kind: 'Revenue' }
    ],
    bankAccounts: [{ value: 'BA1', label: 'Operating (AUD)' }]
};

async function flush() {
    for (let i = 0; i < 8; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount() {
    const el = createElement('c-sab-loans-workspace', { is: SabLoansWorkspace });
    el.companyName = 'Harbourline Trading';
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

function setField(root, field, value) {
    const input = root.querySelector(`[data-field="${field}"]`);
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-loans-workspace', () => {
    beforeEach(() => {
        getWorkspace.mockResolvedValue(workspace());
        getFormOptions.mockResolvedValue(OPTIONS);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders figures, loan cards and the schedule of the active loan', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(Array.from(root.querySelectorAll('.fig .v')).map((v) => v.textContent)).toEqual(['216,178AUD', '1,213AUD', '65,840AUD', '1,120AUD']);
        expect(Array.from(root.querySelectorAll('.fig .s')).map((s) => s.textContent)).toEqual([
            '1 active borrowing', '1 loan with instalments due', '2 investments, carrying amount', 'Since 1 Jul 2026'
        ]);
        expect(Array.from(root.querySelectorAll('.tab')).map((t) => t.textContent)).toEqual(['Loans2', 'Investments2']);
        const cards = root.querySelectorAll('.cards .cardlet');
        expect(cards.length).toBe(2);
        expect(cards[0].className).toContain('sel');
        expect(cards[0].querySelector('.big').textContent).toBe('216,178');
        expect(cards[1].querySelectorAll('.strong')[0].textContent).toBe('Interest free');
        const approve = root.querySelector('.approve-loan');
        expect(approve.disabled).toBe(true);
        expect(approve.title).toBe('The creator of a loan cannot approve it');
        expect(root.querySelector('.schedule-panel h2').textContent).toBe('CBA business loan repayment schedule');
        const actions = root.querySelectorAll('.line-action');
        expect(actions.length).toBe(1);
        expect(actions[0].textContent).toBe('Record repayment');
        expect(actions[0].dataset.id).toBe('L2');
    });

    it('records a repayment with a request key and reloads', async () => {
        recordRepayment.mockResolvedValue({ status: 'Paid' });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        el.shadowRoot.querySelector('.line-action').click();
        await flush();
        expect(recordRepayment).toHaveBeenCalledWith({ scheduleLineId: 'L2', requestKey: expect.stringMatching(/^LOAN-REPAY-L2-/) });
        expect(toast.mock.calls[0][0].detail.message).toBe('Repayment recorded and posted');
        expect(getWorkspace).toHaveBeenCalledTimes(2);
    });

    it('accrues interest on a planned line and reports failures', async () => {
        const loans = workspace().loans;
        loans[0] = { ...loans[0], nextAction: 'accrue', nextLineId: 'L3' };
        getWorkspace.mockResolvedValue(workspace({ loans }));
        accrueInterest.mockRejectedValue({ body: { message: 'Accrue earlier instalments first.' } });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const action = el.shadowRoot.querySelector('.line-action');
        expect(action.textContent).toBe('Accrue interest');
        action.click();
        await flush();
        expect(accrueInterest).toHaveBeenCalledWith({ scheduleLineId: 'L3', requestKey: expect.stringMatching(/^LOAN-ACCRUE-L3-/) });
        expect(toast.mock.calls[0][0].detail).toEqual({ message: 'Accrue earlier instalments first.', tone: 'bad' });
    });

    it('approves a draft loan created by someone else and selects loans by keyboard', async () => {
        const loans = workspace().loans;
        loans[1] = { ...loans[1], createdByMe: false };
        getWorkspace.mockResolvedValue(workspace({ loans }));
        approveLoan.mockResolvedValue({ status: 'Active' });
        const el = mount();
        await flush();
        const cards = el.shadowRoot.querySelectorAll('.cards .cardlet');
        cards[1].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        expect(el.shadowRoot.querySelector('.schedule-panel .panel-b.muted').textContent).toBe('The schedule is generated when the loan is approved.');
        cards[0].click();
        await flush();
        expect(el.shadowRoot.querySelector('.schedule-panel h2').textContent).toBe('CBA business loan repayment schedule');
        el.shadowRoot.querySelector('.approve-loan').click();
        await flush();
        expect(approveLoan).toHaveBeenCalledWith({ loanId: 'LN3', requestKey: expect.stringMatching(/^LOAN-APPROVE-LN3-/) });
    });

    it('creates a draft loan through the modal and shows service errors', async () => {
        saveDraft.mockRejectedValueOnce({ body: { message: 'Company, name, loan type and counterparty are required.' } });
        saveDraft.mockResolvedValueOnce('LN9');
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.new-loan').click();
        await flush();
        expect(getFormOptions).toHaveBeenCalledWith({ companyId: 'a01000000000001AAA' });
        const modal = root.querySelector('c-sab-modal');
        expect(modal.open).toBe(true);
        expect(modal.heading).toBe('New loan');
        const principalOptions = Array.from(root.querySelectorAll('[data-field="principalAccountId"] option')).map((o) => o.textContent);
        expect(principalOptions).toEqual(['Select', '2500 Loan payable']);
        root.querySelector('.save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('Company, name, loan type and counterparty are required.');
        setField(root, 'name', 'Equipment loan');
        setField(root, 'counterpartyAccountId', 'ACC1');
        setField(root, 'principal', '50000');
        setField(root, 'annualRatePercent', '7.5');
        setField(root, 'maturityDate', '2028-10-01');
        setField(root, 'principalAccountId', 'GL2');
        setField(root, 'interestAccountId', 'GL3');
        setField(root, 'bankAccountId', 'BA1');
        root.querySelector('.save').click();
        await flush();
        expect(saveDraft.mock.calls[1][0].request).toMatchObject({
            companyId: 'a01000000000001AAA', name: 'Equipment loan', loanType: 'Borrowing', counterpartyAccountId: 'ACC1', principal: 50000,
            annualRatePercent: 7.5, maturityDate: '2028-10-01', principalAccountId: 'GL2', interestAccountId: 'GL3', accruedInterestAccountId: null,
            bankAccountId: 'BA1', repaymentFrequency: 'Monthly', scheduleMethod: 'Annuity'
        });
        expect(root.querySelector('c-sab-modal').open).toBe(false);
    });

    it('edits a draft loan with lending accounts', async () => {
        const loans = workspace().loans;
        loans[1] = { ...loans[1], loanType: 'Lending' };
        getWorkspace.mockResolvedValue(workspace({ loans }));
        saveDraft.mockResolvedValue('LN3');
        const el = mount();
        await flush();
        el.shadowRoot.querySelector('.edit-loan').click();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('c-sab-modal').heading).toBe('Edit draft loan');
        expect(Array.from(root.querySelectorAll('[data-field="interestAccountId"] option')).map((o) => o.textContent)).toEqual(['Select', '4700 Interest income']);
        root.querySelector('.cancel').click();
        await flush();
        expect(root.querySelector('c-sab-modal').open).toBe(false);
    });

    it('shows investments, records a valuation and saves a new investment', async () => {
        recordTransaction.mockResolvedValue({ transactionId: 'T9' });
        saveInvestment.mockResolvedValue('IV9');
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[1].click();
        await flush();
        const cards = root.querySelectorAll('.cards .cardlet');
        expect(cards.length).toBe(2);
        expect(cards[1].querySelector('.big').textContent).toBe('15,840');
        expect(cards[1].querySelectorAll('.strong')[1].textContent).toBe('1,500');
        expect(root.querySelector('.tbl tbody td .id').textContent).toBe('ANZ term deposit');
        root.querySelectorAll('.record-tx')[1].click();
        await flush();
        expect(Array.from(root.querySelectorAll('[data-field="transactionType"] option')).map((o) => o.value)).toContain('Valuation');
        setField(root, 'transactionType', 'Valuation');
        setField(root, 'amount', '-250');
        await flush();
        expect(root.querySelector('[data-field="quantity"]')).toBeNull();
        root.querySelector('.save').click();
        await flush();
        expect(recordTransaction.mock.calls[0][0]).toMatchObject({
            request: { investmentId: 'IV2', transactionType: 'Valuation', amount: -250, quantity: null },
            requestKey: expect.stringMatching(/^INV-TX-IV2-/)
        });

        root.querySelector('.new-investment').click();
        await flush();
        setField(root, 'name', 'Bond');
        setField(root, 'instrumentKey', 'BOND-1');
        setField(root, 'investmentAccountId', 'GL1');
        root.querySelector('.save').click();
        await flush();
        expect(saveInvestment.mock.calls[0][0].request).toMatchObject({ name: 'Bond', instrumentKey: 'BOND-1', valuationPolicy: 'COST',
            classification: 'Term deposit', investmentAccountId: 'GL1' });
    });

    it('disables actions the user cannot take and shows empty states', async () => {
        getWorkspace.mockResolvedValue(workspace({ canManageLoans: false, canApproveLoans: false, canManageInvestments: false,
            canPostJournal: false, loans: [], investments: [], transactions: [], interestLoanCount: 0 }));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.new-loan').disabled).toBe(true);
        expect(root.querySelector('.new-loan').title).toBe('Your role cannot manage loans');
        expect(root.querySelector('.new-investment').title).toBe('Your role cannot manage investments');
        expect(root.querySelector('.empty h3').textContent).toBe('No loans yet');
        expect(root.querySelectorAll('.fig .s')[1].textContent).toBe('No instalments due this quarter');
        root.querySelectorAll('.tab')[1].click();
        await flush();
        expect(root.querySelector('.empty h3').textContent).toBe('No investments yet');
    });

    it('explains disabled loan actions', async () => {
        getWorkspace.mockResolvedValue(workspace({ canPostJournal: false }));
        const el = mount();
        await flush();
        expect(el.shadowRoot.querySelector('.line-action').title).toBe('This action posts a journal and needs journal posting permission');
        expect(el.shadowRoot.querySelector('.approve-loan').title).toBe('Approving posts the drawdown and needs journal posting permission');
    });

    it('shows load errors with retry and form option errors as toasts', async () => {
        getWorkspace.mockRejectedValueOnce({ body: { message: 'You do not have permission to view Investments & loans.' } });
        const el = mount();
        await flush();
        expect(el.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have permission to view Investments & loans.');
        el.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        expect(el.shadowRoot.querySelector('.figs')).not.toBeNull();
        getFormOptions.mockRejectedValueOnce({ message: 'Options failed' });
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        el.shadowRoot.querySelector('.new-loan').click();
        await flush();
        expect(toast.mock.calls[0][0].detail.message).toBe('Options failed');
    });
});
