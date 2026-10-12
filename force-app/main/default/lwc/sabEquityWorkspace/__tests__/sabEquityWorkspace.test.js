import { createElement } from 'lwc';
import SabEquityWorkspace from 'c/sabEquityWorkspace';
import getWorkspace from '@salesforce/apex/SABEquityWorkspaceController.getWorkspace';
import getFormOptions from '@salesforce/apex/SABEquityWorkspaceController.getFormOptions';
import saveStakeholder from '@salesforce/apex/SABEquityService.saveStakeholder';
import saveClass from '@salesforce/apex/SABEquityService.saveClass';
import saveTransaction from '@salesforce/apex/SABEquityService.saveTransaction';
import approveTransaction from '@salesforce/apex/SABEquityService.approveTransaction';
import cancelTransaction from '@salesforce/apex/SABEquityService.cancelTransaction';
import saveDistribution from '@salesforce/apex/SABDistributionService.saveDraft';
import approveDistribution from '@salesforce/apex/SABDistributionService.approve';
import settleDistribution from '@salesforce/apex/SABDistributionService.settle';
import cancelDistribution from '@salesforce/apex/SABDistributionService.cancel';

jest.mock('@salesforce/apex/SABEquityWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEquityWorkspaceController.getFormOptions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEquityService.saveStakeholder', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEquityService.saveClass', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEquityService.saveTransaction', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEquityService.approveTransaction', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEquityService.cancelTransaction', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABDistributionService.saveDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABDistributionService.approve', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABDistributionService.settle', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABDistributionService.cancel', () => ({ default: jest.fn() }), { virtual: true });

function workspace(overrides = {}) {
    return {
        currencyCode: 'AUD', canManage: true, canApprove: true, canPostJournal: true, distributionsAvailable: true,
        fiscalYearStart: '2026-07-01', shareCapital: 100000, unitsOutstanding: 100000, holderCount: 3, declaredThisYear: 30000,
        unpaid: 12000, nextPaymentDue: '2026-09-30',
        classes: [
            { classId: 'C1', name: 'Ordinary', classCode: 'ORD', parValue: 1, active: true, unitsOutstanding: 100000,
                holdings: [
                    { stakeholderId: 'S1', stakeholderName: 'Daniel Harper', units: 60000, percent: 60 },
                    { stakeholderId: 'S2', stakeholderName: 'Mei Tanaka', units: 30000, percent: 30 },
                    { stakeholderId: 'S3', stakeholderName: 'Harper Holdings', units: 10000, percent: 10 }
                ] },
            { classId: 'C2', name: 'Preference', classCode: 'PREF', parValue: null, active: true, unitsOutstanding: 0, holdings: [] }
        ],
        stakeholders: [
            { stakeholderId: 'S1', name: 'Daniel Harper', reference: 'DH', status: 'Active' },
            { stakeholderId: 'S2', name: 'Mei Tanaka', reference: 'MT', status: 'Active' },
            { stakeholderId: 'S3', name: 'Harper Holdings', reference: 'HH', status: 'Active' }
        ],
        transactions: [
            { transactionId: 'T1', name: 'EQT-0003', transactionDate: '2026-09-02', transactionType: 'Transfer', className: 'Ordinary',
                stakeholderName: 'Daniel Harper', toStakeholderName: 'Harper Holdings', units: 10000, value: 0, status: 'Draft', createdByMe: false },
            { transactionId: 'T2', name: 'EQT-0001', transactionDate: '2024-03-01', transactionType: 'Issue', className: 'Ordinary',
                stakeholderName: 'Daniel Harper', units: 70000, value: 70000, status: 'Posted', createdByMe: false }
        ],
        distributions: [
            { distributionId: 'D1', name: 'DIST-0006', distributionType: 'Dividend', className: 'Ordinary', declarationDate: '2026-08-28',
                recordDate: '2026-08-20', paymentDueDate: '2026-09-30', totalAmount: 30000, paidAmount: 18000, status: 'Part Settled',
                createdByMe: false, sourceAccount: '3300 Dividends declared', payableAccount: '2400 Dividends payable', bankAccount: 'Operating',
                lines: [
                    { lineId: 'L1', stakeholderName: 'Daniel Harper', entitledAmount: 18000, paidAmount: 18000, state: 'Paid' },
                    { lineId: 'L2', stakeholderName: 'Mei Tanaka', entitledAmount: 9000, paidAmount: 0, state: 'Unpaid' },
                    { lineId: 'L3', stakeholderName: 'Harper Holdings', entitledAmount: 3000, paidAmount: 0, state: 'Unpaid' }
                ] },
            { distributionId: 'D2', name: 'DIST-0007', distributionType: 'Dividend', declarationDate: '2026-10-10', recordDate: '2026-10-10',
                totalAmount: 5000, paidAmount: 0, status: 'Draft', createdByMe: true, lines: [] }
        ],
        ...overrides
    };
}

const OPTIONS = {
    accounts: [{ value: 'ACC1', label: 'Harper Holdings Pty Ltd' }],
    glAccounts: [
        { value: 'G1', label: '1000 Bank', kind: 'Asset' }, { value: 'G2', label: '2400 Dividends payable', kind: 'Liability' },
        { value: 'G3', label: '3000 Share capital', kind: 'Equity' }, { value: 'G4', label: '3300 Dividends declared', kind: 'Equity' }
    ],
    bankAccounts: [{ value: 'B1', label: 'Operating (AUD)' }]
};

async function flush() {
    for (let i = 0; i < 8; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount() {
    const el = createElement('c-sab-equity-workspace', { is: SabEquityWorkspace });
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

describe('c-sab-equity-workspace', () => {
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

    it('renders figures, the cap table and the selected distribution', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(Array.from(root.querySelectorAll('.fig .v')).map((v) => v.textContent)).toEqual(['100,000AUD', '3', '30,000AUD', '12,000AUD']);
        expect(Array.from(root.querySelectorAll('.fig .s')).map((s) => s.textContent)).toEqual([
            '100,000 shares in 2 classes', '3 stakeholders on record', 'DIST-0006, dividend', 'Payable by 30 Sep 2026'
        ]);
        expect(root.querySelector('c-sab-donut').centerValue).toBe('100,000');
        expect(root.querySelector('c-sab-donut').parts.length).toBe(3);
        const capRows = root.querySelectorAll('.cap-table tbody tr');
        expect(capRows[0].textContent).toBe('Daniel Harper60,00060%');
        expect(root.querySelector('.register .sub').textContent).toBe('Ordinary (ORD), par 1.00, posted transactions to today');
        expect(root.querySelector('.distribution h2').textContent).toBe('DIST-0006 Dividend, Ordinary');
        expect(root.querySelector('.distribution tfoot').textContent).toBe('Total30,000.0018,000.00');
        expect(root.querySelector('.pay').textContent).toBe('Pay remaining 12,000');
        expect(root.querySelector('.kv').textContent).toContain('Dr 3300 Dividends declared / Cr 2400 Dividends payable');
        expect(root.querySelector('.cancel-tx')).not.toBeNull();
        expect(root.querySelector('tbody .id').textContent).toBe('EQT-0003');
    });

    it('switches class and distribution', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.class-seg button')[1].click();
        await flush();
        expect(root.querySelector('.register .panel-b .muted').textContent).toContain('No shares issued yet');
        expect(root.querySelector('.register .sub').textContent).toBe('Preference (PREF), no par value, posted transactions to today');
        const select = root.querySelector('.dist-select');
        select.value = 'D2';
        select.dispatchEvent(new CustomEvent('change'));
        await flush();
        const approve = root.querySelector('.approve-dist');
        expect(approve.disabled).toBe(true);
        expect(approve.title).toBe('The creator of a distribution cannot approve it');
        expect(root.querySelector('.distribution .panel-b > .muted').textContent).toContain('Entitlements are calculated');
    });

    it('approves a transaction, pays a distribution and reports failures', async () => {
        approveTransaction.mockResolvedValue({ status: 'Posted' });
        settleDistribution.mockRejectedValueOnce({ body: { message: 'Bank account is required.' } });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        el.shadowRoot.querySelector('.approve-tx').click();
        await flush();
        expect(approveTransaction).toHaveBeenCalledWith({ transactionId: 'T1', requestKey: expect.stringMatching(/^EQ-APPROVE-T1-/) });
        expect(toast.mock.calls[0][0].detail.message).toBe('Equity transaction approved and posted');
        el.shadowRoot.querySelector('.pay').click();
        await flush();
        expect(settleDistribution.mock.calls[0][0]).toMatchObject({ distributionId: 'D1', lineIds: null,
            paymentDate: expect.stringMatching(/^\d{4}-\d{2}-\d{2}$/), requestKey: expect.stringMatching(/^DIST-SETTLE-D1-/) });
        expect(toast.mock.calls[1][0].detail).toEqual({ message: 'Bank account is required.', tone: 'bad' });
    });

    it('approves a draft distribution created by someone else', async () => {
        const data = workspace();
        data.distributions = [{ ...data.distributions[1], createdByMe: false }];
        getWorkspace.mockResolvedValue(data);
        approveDistribution.mockResolvedValue({ status: 'Posted Payable' });
        const el = mount();
        await flush();
        el.shadowRoot.querySelector('.approve-dist').click();
        await flush();
        expect(approveDistribution).toHaveBeenCalledWith({ distributionId: 'D2', requestKey: expect.stringMatching(/^DIST-APPROVE-D2-/) });
    });

    it('cancels a draft transaction and a draft distribution with a reason', async () => {
        cancelTransaction.mockResolvedValue({ status: 'Cancelled' });
        cancelDistribution.mockResolvedValue({ status: 'Cancelled' });
        const data = workspace();
        data.distributions = [data.distributions[1]];
        getWorkspace.mockResolvedValue(data);
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.cancel-tx').click();
        await flush();
        expect(root.querySelector('c-sab-modal').heading).toBe('Cancel equity transaction');
        setField(root, 'reason', 'Entered twice');
        root.querySelector('.save').click();
        await flush();
        expect(cancelTransaction.mock.calls[0][0]).toMatchObject({ transactionId: 'T1', reason: 'Entered twice', requestKey: expect.stringMatching(/^EQ-CANCEL-T1-/) });
        root.querySelector('.cancel-dist').click();
        await flush();
        setField(root, 'reason', 'Board withdrew it');
        root.querySelector('.save').click();
        await flush();
        expect(cancelDistribution.mock.calls[0][0]).toMatchObject({ distributionId: 'D2', reason: 'Board withdrew it' });
    });

    it('saves stakeholders, classes, transactions and distributions through the modal', async () => {
        saveStakeholder.mockResolvedValue('S9');
        saveClass.mockResolvedValue('C9');
        saveTransaction.mockRejectedValueOnce({ body: { message: 'Units must be greater than zero.' } }).mockResolvedValueOnce('T9');
        saveDistribution.mockResolvedValue('D9');
        const el = mount();
        await flush();
        const root = el.shadowRoot;

        root.querySelector('.add-stakeholder').click();
        await flush();
        setField(root, 'name', 'New Holder');
        setField(root, 'reference', 'NH');
        setField(root, 'accountId', 'ACC1');
        root.querySelector('.save').click();
        await flush();
        expect(saveStakeholder).toHaveBeenCalledWith({ companyId: 'a01000000000001AAA', name: 'New Holder', reference: 'NH', accountId: 'ACC1' });

        root.querySelector('.add-class').click();
        await flush();
        expect(Array.from(root.querySelectorAll('[data-field="capitalAccountId"] option')).map((o) => o.value)).toEqual(['', 'G3', 'G4']);
        setField(root, 'name', 'Class B');
        setField(root, 'classCode', 'B');
        root.querySelector('.save').click();
        await flush();
        expect(saveClass.mock.calls[0][0].request).toMatchObject({ name: 'Class B', classCode: 'B', parValue: 1 });

        root.querySelector('.new-transaction').click();
        await flush();
        setField(root, 'transactionType', 'Transfer');
        await flush();
        expect(root.querySelector('[data-field="bankAccountId"]')).toBeNull();
        setField(root, 'stakeholderId', 'S1');
        setField(root, 'toStakeholderId', 'S2');
        setField(root, 'units', '0');
        root.querySelector('.save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('Units must be greater than zero.');
        setField(root, 'units', '500');
        root.querySelector('.save').click();
        await flush();
        expect(saveTransaction.mock.calls[1][0].request).toMatchObject({ transactionType: 'Transfer', stakeholderId: 'S1',
            toStakeholderId: 'S2', units: 500, value: 0, bankAccountId: null, classId: 'C1' });

        root.querySelector('.declare').click();
        await flush();
        setField(root, 'totalAmount', '5000');
        setField(root, 'sourceAccountId', 'G4');
        setField(root, 'payableAccountId', 'G2');
        setField(root, 'bankAccountId', 'B1');
        root.querySelector('.save').click();
        await flush();
        expect(saveDistribution.mock.calls[0][0].request).toMatchObject({ distributionType: 'Dividend', totalAmount: 5000,
            sourceAccountId: 'G4', payableAccountId: 'G2', bankAccountId: 'B1' });
    });

    it('records a capital contribution without units and closes the modal', async () => {
        saveTransaction.mockResolvedValue('T9');
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.new-transaction').click();
        await flush();
        setField(root, 'transactionType', 'Capital Contribution');
        await flush();
        expect(root.querySelector('[data-field="units"]')).toBeNull();
        root.querySelector('.cancel').click();
        await flush();
        expect(root.querySelector('c-sab-modal').open).toBe(false);
    });

    it('disables actions without permissions and shows empty states', async () => {
        getWorkspace.mockResolvedValue(workspace({ canManage: false, canApprove: false, canPostJournal: false,
            classes: [], transactions: [], distributions: [], stakeholders: [], nextPaymentDue: null }));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.declare').disabled).toBe(true);
        expect(root.querySelector('.declare').title).toBe('Your role cannot manage equity');
        expect(root.querySelector('.register .sub').textContent).toBe('Add a share class to start the register.');
        expect(Array.from(root.querySelectorAll('.fig .s')).map((s) => s.textContent)[3]).toBe('Nothing unpaid');
        expect(root.querySelector('.distribution .panel-b').textContent).toContain('No distributions yet');
    });

    it('explains approval and payment limits', async () => {
        getWorkspace.mockResolvedValue(workspace({ canPostJournal: false }));
        const el = mount();
        await flush();
        expect(el.shadowRoot.querySelector('.approve-tx').title).toBe('Approving posts a journal and needs journal posting permission');
        expect(el.shadowRoot.querySelector('.pay').title).toBe('Paying posts a journal and needs journal posting permission');
        getWorkspace.mockResolvedValue(workspace({ canApprove: false, canManage: false }));
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.approve-tx').title).toBe('Your role cannot approve equity records');
        expect(el2.shadowRoot.querySelector('.pay').title).toBe('Your role cannot settle distributions');
    });

    it('shows load errors with retry and form option errors as toasts', async () => {
        getWorkspace.mockRejectedValueOnce({ body: { message: 'You do not have permission to view Capital & equity.' } });
        const el = mount();
        await flush();
        expect(el.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have permission to view Capital & equity.');
        el.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        getFormOptions.mockRejectedValueOnce({ message: 'Options failed' });
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        el.shadowRoot.querySelector('.declare').click();
        await flush();
        expect(toast.mock.calls[0][0].detail.message).toBe('Options failed');
    });
});
