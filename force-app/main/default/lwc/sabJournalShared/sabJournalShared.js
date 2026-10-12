/**
 * Shared journal helpers for the Journals and Journal reversals workspaces: period lookup, live validation in the
 * Harbourline demo wording, and the balance meter geometry.
 */
import { formatNumber } from 'c/sabFormat';

export const MAX_LINES = 200;

const round2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

export function amount(value) {
    const n = Number(value);
    return Number.isFinite(n) ? n : 0;
}

export function periodOf(periods, isoDate) {
    if (!isoDate) {
        return undefined;
    }
    return (periods || []).find((p) => p.startDate <= isoDate && p.endDate >= isoDate);
}

export function accountLabel(account) {
    if (!account) {
        return 'No account yet';
    }
    return `${account.code} ${account.name}`;
}

/**
 * Validates a journal the way the demo does. Returns { debit, credit, ok, period, issues: [{ level: 'g'|'w'|'b', message,
 * line, field }] }.
 */
export function validateJournal(journal, periods, accountsById) {
    const issues = [];
    const lines = journal.lines || [];
    const debit = round2(lines.reduce((s, l) => s + amount(l.debit), 0));
    const credit = round2(lines.reduce((s, l) => s + amount(l.credit), 0));
    const period = periodOf(periods, journal.accountingDate);
    if (!journal.accountingDate) {
        issues.push({ level: 'b', message: 'Choose an accounting date.' });
    } else if (!period) {
        issues.push({ level: 'b', message: 'The accounting date has no accounting period. Choose a date inside an open period.' });
    } else if (period.status !== 'Open') {
        issues.push({ level: 'b', message: `${period.periodKey} is ${period.status.toLowerCase()}. Change the accounting date or reopen the period first.` });
    }
    lines.forEach((l, i) => {
        const n = i + 1;
        const account = accountsById[l.glAccountId];
        if (!l.glAccountId) {
            issues.push({ level: 'b', message: `Line ${n}: choose a GL account.`, line: i, field: 'gl' });
        } else if (account && !account.manualPostingAllowed) {
            const control = account.controlType && account.controlType !== 'None' ? `${account.controlType} control` : 'non-manual';
            issues.push({ level: 'b', message: `Line ${n}: ${accountLabel(account)} is a ${control} account. Post through the matching subledger instead.`, line: i, field: 'gl' });
        } else if (account && !account.active) {
            issues.push({ level: 'b', message: `Line ${n}: ${accountLabel(account)} is inactive.`, line: i, field: 'gl' });
        }
        if (amount(l.debit) > 0 && amount(l.credit) > 0) {
            issues.push({ level: 'b', message: `Line ${n}: enter a debit or a credit, not both.`, line: i, field: 'debit' });
        }
        if (amount(l.debit) < 0 || amount(l.credit) < 0) {
            issues.push({ level: 'b', message: `Line ${n}: amounts cannot be negative.`, line: i, field: 'debit' });
        }
        if (!amount(l.debit) && !amount(l.credit)) {
            issues.push({ level: 'w', message: `Line ${n}: has no amount and will be ignored.`, line: i, field: 'debit' });
        }
        if (account && (account.accountType === 'Revenue' || account.accountType === 'Expense') && !l.departmentId) {
            issues.push({ level: 'w', message: `Line ${n}: no department. P&L by department will show it as unassigned.`, line: i, field: 'department' });
        }
    });
    if (!lines.some((l) => amount(l.debit) || amount(l.credit))) {
        issues.push({ level: 'b', message: 'Add at least one line with an amount.' });
    }
    if (round2(debit - credit) !== 0) {
        issues.push({ level: 'b', message: `Debits and credits differ by ${formatNumber(Math.abs(debit - credit))}. Journals must balance before posting.` });
    }
    if (lines.length > MAX_LINES) {
        issues.push({ level: 'b', message: `Journals are limited to ${MAX_LINES} lines.` });
    }
    const ok = !issues.some((x) => x.level === 'b');
    if (ok) {
        issues.unshift({ level: 'g', message: `Ready to post to ${period.periodKey}.` });
    }
    return { debit, credit, ok, period, issues };
}

/** Balance meter: beam tilt in degrees and the state text, as the demo's jeSummary. */
export function balance(debit, credit) {
    const diff = round2(debit - credit);
    const tilt = diff === 0 ? 0 : Math.max(-12, Math.min(12, (diff > 0 ? 1 : -1) * Math.min(12, 2 + Math.log10(Math.abs(diff) + 1) * 3)));
    const balanced = diff === 0;
    return {
        debitText: formatNumber(debit),
        creditText: formatNumber(credit),
        beamStyle: `transform:rotate(${tilt}deg);background:${balanced ? 'var(--good)' : 'var(--bad)'}`,
        stateStyle: `color:${balanced ? 'var(--good)' : 'var(--bad)'}`,
        stateText: balanced ? 'Balanced' : `Out by ${formatNumber(Math.abs(diff))}`
    };
}

export function issueIcon(level) {
    if (level === 'g') {
        return 'check';
    }
    return level === 'b' ? 'alert' : 'info';
}

export function reduceError(error) {
    if (!error) {
        return 'Something went wrong.';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return (error.body && error.body.message) || error.message || 'Something went wrong.';
}
