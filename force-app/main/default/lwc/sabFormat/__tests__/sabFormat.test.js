import {
    formatNumber, moneyParts, formatCompact, formatDate, formatDateShort, formatMonth, monthName, formatDateTime,
    toneOf, chipClass, initials, plural, greeting, guardTitle
} from 'c/sabFormat';

describe('c-sab-format', () => {
    it('formats numbers like the demo', () => {
        expect(formatNumber(1234.5)).toBe('1,234.50');
        expect(formatNumber(-1234.5)).toBe('(1,234.50)');
        expect(formatNumber(1234.5, 0)).toBe('1,235');
        expect(formatNumber(null)).toBe('');
        expect(formatNumber('')).toBe('');
        expect(formatNumber('abc')).toBe('');
    });

    it('builds money parts with a currency suffix', () => {
        expect(moneyParts(-5, 'AUD')).toEqual({ text: '(5.00)', currency: 'AUD', negative: true, className: 'num neg' });
        expect(moneyParts(5).className).toBe('num');
    });

    it('formats compact axis labels', () => {
        expect(formatCompact(1250000)).toBe('1.25m');
        expect(formatCompact(12400)).toBe('12.4k');
        expect(formatCompact(950)).toBe('950');
        expect(formatCompact(-15000)).toBe('\u221215.0k');
        expect(formatCompact(undefined)).toBe('0');
    });

    it('formats dates', () => {
        expect(formatDate('2026-09-25')).toBe('25 Sep 2026');
        expect(formatDateShort('2026-09-05')).toBe('5 Sep');
        expect(formatMonth('2026-09-01')).toBe('Sep 2026');
        expect(monthName('2026-07-01')).toBe('Jul');
        expect(formatDate('')).toBe('');
        expect(formatDate('nope')).toBe('');
        expect(formatDateTime('2026-09-25T04:05:00')).toMatch(/^25 Sep 2026 \d{2}:05$/);
        expect(formatDateTime('bad')).toBe('');
        expect(formatDateTime(null)).toBe('');
    });

    it('maps statuses to tones', () => {
        expect(toneOf('Posted')).toBe('good');
        expect(toneOf('Overdue')).toBe('bad');
        expect(toneOf('Unknown')).toBe('neutral');
        expect(toneOf('Posted', 'accent')).toBe('accent');
        expect(chipClass('Open')).toBe('chip t-accent');
    });

    it('builds labels', () => {
        expect(initials('Alex Morgan')).toBe('AM');
        expect(initials('')).toBe('');
        expect(plural(1, 'bill')).toBe('1 bill');
        expect(plural(3, 'bill')).toBe('3 bills');
        expect(plural(2, 'entry', 'entries')).toBe('2 entries');
        expect(greeting(9)).toBe('Good morning');
        expect(greeting(14)).toBe('Good afternoon');
        expect(greeting(20)).toBe('Good evening');
        expect(guardTitle(true, 'Auditor', 'post')).toBeUndefined();
        expect(guardTitle(false, 'Auditor', 'post journals')).toBe('Auditor role cannot post journals');
        expect(guardTitle(false)).toBe('Your role cannot do this');
    });
});
