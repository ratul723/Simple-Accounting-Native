import { createElement } from 'lwc';
import SabBankWorkspace, { scoreOf, parseStatementCsv } from 'c/sabBankWorkspace';
import getDashboard from '@salesforce/apex/SABBankReconciliationWorkspaceController.getDashboard';
import getStatementWorkspace from '@salesforce/apex/SABBankReconciliationWorkspaceController.getStatementWorkspace';
import importStatement from '@salesforce/apex/SABBankReconciliationWorkspaceController.importStatement';
import validateStatement from '@salesforce/apex/SABBankReconciliationWorkspaceController.validateStatement';
import startReconciliation from '@salesforce/apex/SABBankReconciliationWorkspaceController.startReconciliation';
import getMatchCandidates from '@salesforce/apex/SABBankReconciliationWorkspaceController.getMatchCandidates';
import createManualMatch from '@salesforce/apex/SABBankReconciliationWorkspaceController.createManualMatch';
import createSuggestedMatch from '@salesforce/apex/SABBankReconciliationWorkspaceController.createSuggestedMatch';
import confirmMatch from '@salesforce/apex/SABBankReconciliationWorkspaceController.confirmMatch';
import reverseMatch from '@salesforce/apex/SABBankReconciliationWorkspaceController.reverseMatch';
import finalizeReconciliation from '@salesforce/apex/SABBankReconciliationWorkspaceController.finalizeReconciliation';
import getLedgerLines from '@salesforce/apex/SABBankLedgerLinesController.getLedgerLines';

jest.mock('@salesforce/apex/SABBankReconciliationWorkspaceController.getDashboard', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBankReconciliationWorkspaceController.getStatementWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBankReconciliationWorkspaceController.importStatement', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBankReconciliationWorkspaceController.validateStatement', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBankReconciliationWorkspaceController.startReconciliation', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBankReconciliationWorkspaceController.getMatchCandidates', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBankReconciliationWorkspaceController.createManualMatch', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBankReconciliationWorkspaceController.createSuggestedMatch', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBankReconciliationWorkspaceController.confirmMatch', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBankReconciliationWorkspaceController.reverseMatch', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBankReconciliationWorkspaceController.finalizeReconciliation', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABBankLedgerLinesController.getLedgerLines', () => ({ default: jest.fn() }), { virtual: true });

const DASH = {
    functionalCurrency: 'AUD', canImport: true, canReconcile: true, canFinalize: true,
    bankAccounts: [
        { bankAccountId: 'B1', name: 'Operating', bankName: 'CBA', maskedAccountNumber: '\u2022\u2022\u2022\u2022 4821', currencyCode: 'AUD', glAccountCode: '1000',
            currentBookBalance: 217430.5, latestReconciliationStatus: 'Draft' },
        { bankAccountId: 'B2', name: 'USD receipts', bankName: 'HSBC', currencyCode: 'USD', glAccountCode: '1010', currentBookBalance: 25214.3,
            latestReconciliationStatus: 'Finalized' }
    ],
    statements: [
        { statementId: 'S1', bankAccountId: 'B1', label: 'Sep 2026', status: 'Validated' },
        { statementId: 'S0', bankAccountId: 'B1', label: 'Aug 2026', status: 'Reconciled' }
    ]
};

function statement(overrides = {}) {
    return {
        statementId: 'S1', statementName: 'STM-1', bankAccountName: 'Operating', startDate: '2026-09-01', endDate: '2026-09-25', openingAmount: 200000,
        closingAmount: 218200.5, statementStatus: 'Validated', reconciliationId: 'REC1', reconciliationName: 'REC-0042', reconciliationStatus: 'In Review',
        provisionalBookClosingAmount: 217430.5, provisionalDifference: 770, lineCount: 3, fullyMatchedLineCount: 1, canFinalizeNow: false,
        lines: [
            { lineId: 'L1', lineNumber: 1, transactionDate: '2026-09-22', amount: 4180, reference: 'GREENFIELD INV141', remainingAmount: 4180, fullyMatched: false },
            { lineId: 'L2', lineNumber: 2, transactionDate: '2026-09-23', amount: -12.5, reference: 'BANK FEE', remainingAmount: -12.5, fullyMatched: false },
            { lineId: 'L3', lineNumber: 3, transactionDate: '2026-09-10', amount: 500, reference: 'DEPOSIT', remainingAmount: 0, fullyMatched: true }
        ],
        matches: [
            { matchId: 'M1', statementLineId: 'L3', journalName: 'JE-000201', accountingDate: '2026-09-10', matchType: 'Manual', matchedAmount: 500, status: 'Confirmed' },
            { matchId: 'M2', statementLineId: 'L1', journalName: 'JE-000210', accountingDate: '2026-09-20', matchType: 'Suggested', matchedAmount: 100, status: 'Proposed' },
            { matchId: 'M0', statementLineId: 'L1', status: 'Reversed' }
        ],
        ...overrides
    };
}

const LEDGER = [
    { journalEntryLineId: 'J1', journalName: 'JE-000220', entryType: 'Subledger', accountingDate: '2026-09-21', description: 'Receipt Greenfield', amount: 4180,
        matchedAmount: 0, remainingAmount: 4180 },
    { journalEntryLineId: 'J2', journalName: 'JE-000221', accountingDate: '2026-09-24', amount: -300, matchedAmount: 100, remainingAmount: -200 },
    { journalEntryLineId: 'J3', journalName: 'JE-000201', accountingDate: '2026-09-10', amount: 500, matchedAmount: 500, remainingAmount: 0, matchedHere: true }
];

async function flush() {
    for (let i = 0; i < 10; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-bank-workspace', { is: SabBankWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', persona: { label: 'Bookkeeper', canViewBankDetail: true }, ...props });
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

describe('c-sab-bank-workspace', () => {
    beforeEach(() => {
        getDashboard.mockResolvedValue(DASH);
        getStatementWorkspace.mockResolvedValue(statement());
        getLedgerLines.mockResolvedValue(LEDGER);
        getMatchCandidates.mockResolvedValue([{ journalEntryLineId: 'J1', exactAmount: true, dateDifferenceDays: 1, suggestedMatchAmount: 4180 }]);
        [createManualMatch, createSuggestedMatch, confirmMatch, reverseMatch, finalizeReconciliation, validateStatement, startReconciliation].forEach((m) => m.mockResolvedValue({}));
        importStatement.mockResolvedValue({ recordId: 'S9' });
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('scores candidates and parses statement files', () => {
        expect([0, 2, 5, 9].map((d) => scoreOf({ exactAmount: true, dateDifferenceDays: d }))).toEqual([99, 95, 90, 80]);
        expect(scoreOf({ exactAmount: false })).toBe(60);
        const lines = parseStatementCsv('Date,Amount,Reference,Value date,Id\n2026-09-22,4180,"GREENFIELD",2026-09-23,X1\n2026-09-23,-12.5,FEE,,\n');
        expect(lines.map((l) => [l.transactionDate, l.amount, l.reference, l.valueDate, l.providerLineId])).toEqual([
            ['2026-09-22', 4180, 'GREENFIELD', '2026-09-23', 'X1'], ['2026-09-23', -12.5, 'FEE', '2026-09-23', '']]);
        expect(() => parseStatementCsv('date,amount')).toThrow('The file needs a header row and at least one line.');
        expect(() => parseStatementCsv('ref,value\nA,1')).toThrow('The file needs date and amount columns.');
        expect(() => parseStatementCsv('date,amount\n22/09/2026,1')).toThrow('Line 2: use yyyy-mm-dd dates and numeric amounts.');
    });

    it('renders cards, figures and both panes', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        const cards = root.querySelectorAll('.cards .cardlet');
        expect(cards[0].className).toBe('cardlet click sel');
        expect(cards[0].textContent).toContain('CBA \u2022\u2022\u2022\u2022 4821, GL 1000');
        expect(cards[0].querySelector('.chip').textContent).toBe('2 to match');
        expect(cards[1].querySelector('.chip').textContent).toBe('Reconciled');
        expect(Array.from(root.querySelectorAll('.fig .v')).map((v) => v.textContent)).toEqual(['218,200.50', '217,430.50', '770.00', '2']);
        expect(root.querySelectorAll('.sab-statement-lines .rline').length).toBe(3);
        expect(root.querySelectorAll('.sab-statement-lines .rline')[0].textContent).toContain('Matched to JE-000210 (proposed)');
        expect(root.querySelectorAll('.sab-ledger-lines .rline')[1].textContent).toContain('(200.00) left');
        expect(root.querySelector('.sab-ledger-lines h2').textContent).toBe('Posted ledger lines, GL 1000');
        expect(root.querySelector('.sab-finalize').title).toBe('Match and confirm every statement line first');
        expect(root.querySelector('.hint').textContent).toBe('Select a statement line to see suggestions.');
        expect(root.querySelectorAll('.sab-matches tbody tr').length).toBe(2);
    });

    it('selects a line, shows suggestion scores and matches', async () => {
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelectorAll('.sab-statement-lines .rline')[0].click();
        await flush();
        expect(getMatchCandidates).toHaveBeenCalledWith({ reconciliationId: 'REC1', bankStatementLineId: 'L1', dayWindow: 7 });
        const ledger = root.querySelectorAll('.sab-ledger-lines .rline');
        expect(ledger[0].className).toBe('rline sug');
        expect(ledger[0].querySelector('.score').textContent).toBe('95%');
        expect(root.querySelector('.hint').textContent).toBe('Suggested ledger lines are highlighted on the right.');
        ledger[1].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        expect(root.querySelector('.hint').textContent).toBe('Amounts differ by 4,380.00.');
        expect(root.querySelector('.sab-match').disabled).toBe(true);
        ledger[0].click();
        await flush();
        expect(root.querySelector('.hint').textContent).toBe('Amounts agree. Match them.');
        root.querySelector('.sab-match').click();
        await flush();
        expect(createSuggestedMatch).toHaveBeenCalledWith({ reconciliationId: 'REC1', bankStatementLineId: 'L1', journalEntryLineId: 'J1', matchedAmount: 4180 });
        expect(toast.mock.calls[0][0].detail.message).toBe('Matched, confirm it to lock the match');
    });

    it('accepts suggestions, confirms, reverses and records adjustments', async () => {
        getMatchCandidates.mockImplementation(({ bankStatementLineId }) => Promise.resolve(bankStatementLineId === 'L1'
            ? [{ journalEntryLineId: 'J1', exactAmount: true, dateDifferenceDays: 0, suggestedMatchAmount: 4180 }] : []));
        const el = mount();
        await flush();
        const toast = jest.fn();
        const nav = jest.fn();
        el.addEventListener('sabtoast', toast);
        el.addEventListener('sabnavigate', nav);
        const root = el.shadowRoot;
        root.querySelector('.sab-accept').click();
        await flush();
        await flush();
        expect(createSuggestedMatch).toHaveBeenCalledTimes(1);
        expect(toast.mock.calls[toast.mock.calls.length - 1][0].detail.message).toBe('1 suggestion accepted, confirm them to lock the matches');
        root.querySelector('.sab-confirm-all').click();
        await flush();
        expect(confirmMatch).toHaveBeenCalledWith({ matchId: 'M2' });
        root.querySelector('.sab-confirm').click();
        await flush();
        root.querySelectorAll('.sab-reverse')[0].click();
        await flush();
        expect(reverseMatch).toHaveBeenCalledWith({ matchId: 'M1' });
        root.querySelectorAll('.sab-statement-lines .rline')[1].click();
        await flush();
        expect(root.querySelector('.hint').textContent).toBe('No ledger line found. Record it as a bank adjustment.');
        root.querySelector('.sab-adjustment').click();
        expect(nav.mock.calls[0][0].detail.workspace).toBe('journal');
    });

    it('finalises when ready and shows the finalised banner', async () => {
        getStatementWorkspace.mockResolvedValueOnce(statement({ canFinalizeNow: true, fullyMatchedLineCount: 3,
            lines: statement().lines.map((l) => ({ ...l, fullyMatched: true, remainingAmount: 0 })) }));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.cards .chip').textContent).toBe('Ready to finalise');
        expect(root.querySelector('.figs').textContent).toContain('All resolved');
        root.querySelector('.sab-finalize').click();
        await flush();
        expect(finalizeReconciliation).toHaveBeenCalledWith({ reconciliationId: 'REC1' });
        getStatementWorkspace.mockResolvedValue(statement({ reconciliationStatus: 'Finalized' }));
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.banner.t-good').textContent).toContain('REC-0042 finalised');
        expect(el2.shadowRoot.querySelector('.sab-accept').disabled).toBe(true);
        expect(el2.shadowRoot.querySelector('.sab-finalize').title).toBe('This reconciliation is finalised');
    });

    it('validates and starts statements, switches bank and statement', async () => {
        getStatementWorkspace.mockResolvedValueOnce(statement({ reconciliationId: null, statementStatus: 'Imported' }));
        const el = mount({ persona: { label: 'Auditor' } });
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.cards .cardlet').textContent).toContain('\u2022\u2022\u2022\u2022, GL 1000');
        expect(root.querySelector('.sab-statement-action').textContent).toBe('Validate statement');
        root.querySelector('.sab-statement-action').click();
        await flush();
        expect(validateStatement).toHaveBeenCalledWith({ bankStatementId: 'S1' });
        getStatementWorkspace.mockResolvedValueOnce(statement({ reconciliationId: null, statementStatus: 'Validated' }));
        const select = root.querySelector('.sab-statement');
        select.value = 'S0';
        select.dispatchEvent(new CustomEvent('change'));
        await flush();
        expect(root.querySelector('.sab-statement-action').textContent).toBe('Start reconciliation');
        root.querySelector('.sab-statement-action').click();
        await flush();
        expect(startReconciliation).toHaveBeenCalled();
        root.querySelectorAll('.cards .cardlet')[1].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        expect(root.querySelector('.empty h3').textContent).toBe('No statement for this account');
        root.querySelectorAll('.cards .cardlet')[1].dispatchEvent(new KeyboardEvent('keydown', { key: 'x' }));
    });

    it('imports a statement file and starts reconciling', async () => {
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelector('.sab-import').click();
        await flush();
        const input = root.querySelector('.sab-file');
        Object.defineProperty(input, 'files', { value: [new File(['date,amount,reference\n2026-10-01,100,A\n2026-10-05,-20,B\n'], 'oct.csv')] });
        input.dispatchEvent(new CustomEvent('change'));
        for (let i = 0; i < 50 && !root.querySelector('.drop .small').textContent.includes('lines'); i++) {
            // eslint-disable-next-line no-await-in-loop, @lwc/lwc/no-async-operation
            await new Promise((resolve) => setTimeout(resolve, 5));
        }
        expect(root.querySelector('.drop .small').textContent).toBe('2 lines, net 80.00');
        expect(root.querySelector('.sab-import-save').disabled).toBe(true);
        ['openingAmount', 'closingAmount'].forEach((field, i) => {
            const f = root.querySelector(`[data-field="${field}"]`);
            f.value = i ? '180' : '100';
            f.dispatchEvent(new CustomEvent('input'));
        });
        await flush();
        root.querySelector('.sab-import-save').click();
        await flush();
        expect(importStatement.mock.calls[0][0].input).toMatchObject({ bankAccountId: 'B1', statementStartDate: '2026-10-01', statementEndDate: '2026-10-05',
            openingAmount: 100, closingAmount: 180, currencyCode: 'AUD' });
        expect(importStatement.mock.calls[0][0].input.lines.length).toBe(2);
        expect(validateStatement).toHaveBeenCalledWith({ bankStatementId: 'S9' });
        expect(startReconciliation).toHaveBeenCalledWith({ bankStatementId: 'S9' });
        expect(toast.mock.calls[0][0].detail.message).toBe('Statement imported with 2 lines, reconciliation started');
    });

    it('reports import and load errors and missing permissions', async () => {
        getDashboard.mockResolvedValueOnce({ ...DASH, canImport: false, canFinalize: false });
        importStatement.mockRejectedValueOnce({ body: { message: 'Statement already imported.' } });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-import').title).toBe('Bookkeeper role cannot import statements');
        expect(root.querySelector('.sab-finalize').title).toBe('Bookkeeper role cannot finalise reconciliations');

        getLedgerLines.mockRejectedValueOnce({ body: { message: 'Ledger unavailable.' } });
        const el2 = mount();
        const toast = jest.fn();
        el2.addEventListener('sabtoast', toast);
        await flush();
        expect(toast.mock.calls[0][0].detail.message).toBe('Ledger unavailable.');

        getDashboard.mockResolvedValueOnce({ ...DASH, bankAccounts: [], statements: [] });
        const el3 = mount();
        await flush();
        expect(el3.shadowRoot.querySelector('.empty h3').textContent).toBe('No bank accounts');

        getDashboard.mockRejectedValueOnce({ body: { message: 'You do not have permission to view Bank Reconciliation details.' } });
        const el4 = mount();
        await flush();
        expect(el4.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have permission to view Bank Reconciliation details.');
        el4.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        el4.shadowRoot.querySelector('.sab-import').click();
        await flush();
        const input = el4.shadowRoot.querySelector('.sab-file');
        Object.defineProperty(input, 'files', { value: [new File(['nope'], 'bad.csv')] });
        input.dispatchEvent(new CustomEvent('change'));
        for (let i = 0; i < 50 && !el4.shadowRoot.querySelector('.form-error'); i++) {
            // eslint-disable-next-line no-await-in-loop, @lwc/lwc/no-async-operation
            await new Promise((resolve) => setTimeout(resolve, 5));
        }
        expect(el4.shadowRoot.querySelector('.form-error').textContent).toBe('The file needs a header row and at least one line.');
        el4.shadowRoot.querySelector('.sab-import-cancel').click();
        await flush();
        expect(el4.shadowRoot.querySelector('c-sab-modal').open).toBe(false);
    });

    it('selects the bank account opened from search', async () => {
        const el = mount({ recordId: 'B2' });
        await flush();
        const selected = Array.from(el.shadowRoot.querySelectorAll('[aria-pressed="true"], .sel, .selected')).map((x) => x.textContent).join(' ');
        expect(selected).toContain('USD receipts');
    });
});
