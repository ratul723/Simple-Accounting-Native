import { createElement } from 'lwc';
import SabAuditWorkspace, { kindOf } from 'c/sabAuditWorkspace';
import getTimeline from '@salesforce/apex/SABAuditTimelineController.getTimeline';

jest.mock('@salesforce/apex/SABAuditTimelineController.getTimeline', () => ({ default: jest.fn() }), { virtual: true });

const ITEMS = [
    { itemKey: 'J1', category: 'JOURNAL', occurredAt: '2026-09-25T04:05:00.000Z', title: 'Journal Posted \u00b7 JE-000318', detail: 'Accrual \u00b7 FY27-P03',
        actorName: 'Alex Morgan', status: 'Posted', requestKey: 'HLT:JE:318:v1' },
    { itemKey: 'J2', category: 'JOURNAL', occurredAt: '2026-09-26T04:05:00.000Z', title: 'Journal Reversed \u00b7 JE-000300', detail: 'Reversal Journal: JE-000301',
        actorName: 'Alex Morgan', status: 'Reversed' },
    { itemKey: 'P1', category: 'PERIOD', occurredAt: '2026-09-05T02:00:00.000Z', title: 'Period Open \u2192 Closed', detail: 'August close', actorName: 'Priya Nair' },
    { itemKey: 'B1', category: 'BUSINESS', occurredAt: '2026-09-20T02:00:00.000Z', title: 'LOAN_APPROVED', detail: 'Loan approved', actorName: 'Priya Nair' },
    { itemKey: 'B2', category: 'BUSINESS', occurredAt: '2026-09-21T02:00:00.000Z', title: 'DISTRIBUTION_SETTLED', detail: 'Paid' },
    { itemKey: 'B3', category: 'BUSINESS', occurredAt: '2026-09-22T02:00:00.000Z', title: 'IMPORT_COMMITTED', detail: 'Chart of accounts' },
    { itemKey: 'B4', category: 'BUSINESS', occurredAt: '2026-09-23T02:00:00.000Z', title: 'SETUP_ACCOUNT_SAVED', detail: 'GL account 1000 saved' },
    { itemKey: 'B5', category: 'BUSINESS', occurredAt: '2026-09-24T02:00:00.000Z', title: 'JOURNAL_REVERSED', detail: 'Reason' },
    { itemKey: 'E1', category: 'EVENT', occurredAt: null, title: 'Accounting Event \u00b7 Manual Journal', detail: 'EVT \u00b7 MANUAL_JOURNAL' }
];

async function flush() {
    for (let i = 0; i < 8; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount() {
    const el = createElement('c-sab-audit-workspace', { is: SabAuditWorkspace });
    el.companyName = 'Harbourline Trading';
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

describe('c-sab-audit-workspace', () => {
    beforeEach(() => {
        getTimeline.mockResolvedValue({ items: ITEMS });
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('maps service items to demo kinds', () => {
        expect(ITEMS.map(kindOf)).toEqual(['Posting', 'Reversal', 'Period', 'Approval', 'Settlement', 'Import', 'Business', 'Reversal', 'Event']);
    });

    it('renders the timeline newest first in plain wording with counts', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        const items = root.querySelectorAll('.tl-item');
        expect(items.length).toBe(9);
        expect(items[0].querySelector('.t').textContent).toBe('JE-000300 reversed');
        const titles = Array.from(items).map((i) => i.querySelector('.t').textContent);
        expect(titles).toContain('JE-000318 posted');
        expect(titles).toContain('Period open to closed');
        expect(titles).toContain('Loan approved');
        expect(titles).toContain('Accounting event, manual journal');
        expect(root.textContent).not.toContain('\u00b7');
        expect(root.textContent).not.toContain('\u2192');
        expect(items[0].querySelector('.avatar').textContent).toBe('AM');
        expect(root.querySelector('.sab-counts tfoot').textContent).toBe('Total9');
    });

    it('filters by kind and search and exports', async () => {
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        const kinds = root.querySelectorAll('.seg button');
        kinds[2].click();
        await flush();
        expect(root.querySelectorAll('.tl-item').length).toBe(2);
        kinds[0].click();
        const search = root.querySelector('.sab-query');
        search.value = 'hlt:je';
        search.dispatchEvent(new CustomEvent('input'));
        await flush();
        expect(root.querySelectorAll('.tl-item').length).toBe(1);
        const link = root.querySelector('.sab-download');
        link.click = jest.fn();
        root.querySelector('.sab-export').click();
        expect(decodeURIComponent(link.href)).toContain('"JE-000318 posted"');
        expect(link.download).toBe('audit-history.csv');
        expect(toast.mock.calls[0][0].detail.message).toBe('Exported 1 events');
        search.value = 'nothing matches';
        search.dispatchEvent(new CustomEvent('input'));
        await flush();
        expect(root.querySelector('.empty h3').textContent).toBe('No matching events');
        expect(root.querySelector('.sab-export').disabled).toBe(false);
        root.querySelector('.sab-export').click();
        expect(toast.mock.calls[1][0].detail).toEqual({ message: 'Nothing to export for this filter', tone: 'bad' });
    });

    it('shows load errors with retry', async () => {
        getTimeline.mockRejectedValueOnce({ body: { message: 'Select an Accounting Company before viewing audit history.' } });
        const el = mount();
        await flush();
        expect(el.shadowRoot.querySelector('.empty p').textContent).toBe('Select an Accounting Company before viewing audit history.');
        el.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        expect(el.shadowRoot.querySelectorAll('.tl-item').length).toBe(9);
    });
});
