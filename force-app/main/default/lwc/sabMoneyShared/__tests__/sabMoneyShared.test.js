import { reduceError, newKey, todayIso, daysBetween, documentState, hsteps, toast } from 'c/sabMoneyShared';

describe('c-sab-money-shared', () => {
    it('provides helpers', () => {
        expect(reduceError()).toBe('Something went wrong.');
        expect(reduceError({ body: [{ message: 'A' }] })).toBe('A');
        expect(reduceError({ body: { message: 'B' } })).toBe('B');
        expect(newKey('X', 'Y')).toMatch(/^X-Y-/);
        expect(newKey('X')).toMatch(/^X-new-/);
        expect(todayIso()).toMatch(/^\d{4}-\d{2}-\d{2}$/);
        expect(daysBetween('2026-10-01', '2026-10-08')).toBe(7);
        expect(daysBetween('', '2026-10-08')).toBe(0);
        expect(hsteps(['A', 'B', 'C'], 1).map((s) => s.className)).toEqual(['hstep done', 'hstep now', 'hstep']);
        const el = document.createElement('div');
        const handler = jest.fn();
        el.addEventListener('sabtoast', handler);
        toast(el, 'Hi', 'bad');
        expect(handler.mock.calls[0][0].detail).toEqual({ message: 'Hi', tone: 'bad' });
    });

    it('derives document states', () => {
        expect(documentState({ status: 'Draft' })).toBe('Draft');
        expect(documentState({ status: 'Posted', outstanding: 0, total: 10 })).toBe('Paid');
        expect(documentState({ status: 'Posted', outstanding: 5, total: 10, daysPastDue: 3 })).toBe('Overdue');
        expect(documentState({ status: 'Posted', outstanding: 5, total: 10, daysPastDue: 0 })).toBe('Part Paid');
        expect(documentState({ status: 'Posted', outstanding: 10, total: 10, daysPastDue: 0 })).toBe('Posted');
    });
});
