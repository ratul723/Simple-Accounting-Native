import { amount, periodOf, accountLabel, validateJournal, balance, issueIcon, reduceError } from 'c/sabJournalShared';

const PERIODS = [{ periodId: 'P1', periodKey: 'FY27-P04', startDate: '2026-10-01', endDate: '2026-10-31', status: 'Open' }];
const ACCOUNTS = {
    A1: { code: '6100', name: 'Office', accountType: 'Expense', manualPostingAllowed: true, active: true },
    A2: { code: '2100', name: 'Accrued', accountType: 'Liability', manualPostingAllowed: true, active: false },
    A3: { code: '1100', name: 'AR', accountType: 'Asset', manualPostingAllowed: false, controlType: 'None', active: true }
};

describe('c-sab-journal-shared', () => {
    it('handles amounts, periods and labels', () => {
        expect(amount('12.5')).toBe(12.5);
        expect(amount('abc')).toBe(0);
        expect(periodOf(PERIODS, '2026-10-12').periodKey).toBe('FY27-P04');
        expect(periodOf(PERIODS, '')).toBeUndefined();
        expect(accountLabel(undefined)).toBe('No account yet');
        expect(accountLabel(ACCOUNTS.A1)).toBe('6100 Office');
    });

    it('validates journals', () => {
        const ok = validateJournal({ accountingDate: '2026-10-12', lines: [{ glAccountId: 'A1', debit: '10', departmentId: 'D' }, { glAccountId: 'A1', credit: '10', departmentId: 'D' }] }, PERIODS, ACCOUNTS);
        expect(ok.ok).toBe(true);
        expect(ok.issues[0].message).toBe('Ready to post to FY27-P04.');
        const bad = validateJournal({ accountingDate: '', lines: [{ glAccountId: 'A2', debit: '-5' }, { glAccountId: 'A3' }] }, PERIODS, ACCOUNTS);
        const messages = bad.issues.map((i) => i.message);
        expect(messages).toContain('Choose an accounting date.');
        expect(messages).toContain('Line 1: 2100 Accrued is inactive.');
        expect(messages).toContain('Line 1: amounts cannot be negative.');
        expect(messages).toContain('Line 2: 1100 AR is a non-manual account. Post through the matching subledger instead.');
        expect(validateJournal({ accountingDate: '2026-10-12', lines: [{ glAccountId: 'A1' }] }, PERIODS, ACCOUNTS).issues.map((i) => i.message))
            .toContain('Add at least one line with an amount.');
        const many = validateJournal({ accountingDate: '2026-10-12', lines: Array.from({ length: 201 }, () => ({ glAccountId: 'A1', debit: '0' })) }, PERIODS, ACCOUNTS);
        expect(many.issues.map((i) => i.message)).toContain('Journals are limited to 200 lines.');
    });

    it('builds the balance meter and helpers', () => {
        expect(balance(10, 10).stateText).toBe('Balanced');
        expect(balance(10, 5).beamStyle).toContain('var(--bad)');
        expect(balance(5, 10).stateText).toBe('Out by 5.00');
        expect(issueIcon('g')).toBe('check');
        expect(issueIcon('b')).toBe('alert');
        expect(issueIcon('w')).toBe('info');
        expect(reduceError(undefined)).toBe('Something went wrong.');
        expect(reduceError({ body: [{ message: 'A' }, { message: 'B' }] })).toBe('A, B');
        expect(reduceError({ message: 'C' })).toBe('C');
    });
});
