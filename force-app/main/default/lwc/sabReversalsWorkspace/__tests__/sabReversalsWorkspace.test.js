import { createElement } from 'lwc';
import SabReversalsWorkspace from 'c/sabReversalsWorkspace';
import getWorkspace from '@salesforce/apex/SABJournalWorkspaceController.getWorkspace';
import getJournal from '@salesforce/apex/SABJournalWorkspaceController.getJournal';
import reverseJournal from '@salesforce/apex/SABJournalWorkspaceController.reverseJournal';
import getBrowseData from '@salesforce/apex/SABJournalBrowseController.getBrowseData';

jest.mock('@salesforce/apex/SABJournalWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABJournalWorkspaceController.getJournal', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABJournalWorkspaceController.reverseJournal', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABJournalBrowseController.getBrowseData', () => ({ default: jest.fn() }), { virtual: true });

const COMPANY = 'a01000000000001AAA';
const today = (() => {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
})();
const thisMonth = `${today.slice(0, 8)}01`;

function browse(overrides = {}) {
    return {
        journals: [
            { journalId: 'J2', name: 'JE-000310', accountingDate: '2026-09-15', description: 'Rent', entryType: 'Manual', status: 'Posted', totalDebit: 4000, postedBy: 'Alex Morgan' },
            { journalId: 'J5', name: 'JE-000320', accountingDate: today, description: 'Accrual', entryType: 'Manual', status: 'Posted', totalDebit: 300 },
            { journalId: 'J6', name: 'JE-000290', accountingDate: '2026-09-01', entryType: 'Subledger', status: 'Posted', totalDebit: 50 },
            { journalId: 'J7', name: 'JE-000301', accountingDate: '2026-09-02', entryType: 'Reversal', status: 'Posted', reversalOfName: 'JE-000300', postedBy: 'Alex Morgan' }
        ],
        accounts: [{ accountId: 'A1', code: '6100', name: 'Office expenses' }, { accountId: 'A2', code: '2100', name: 'Accrued liabilities' }],
        periods: [
            { periodId: 'P3', periodKey: 'FY27-P03', startDate: '2026-09-01', endDate: '2026-09-30', status: 'Closed' },
            { periodId: 'P4', periodKey: 'FY27-P04', startDate: thisMonth, endDate: `${today.slice(0, 8)}31`, status: 'Open' },
            { periodId: 'P5', periodKey: 'FY27-P05', startDate: '2099-01-01', endDate: '2099-01-31', status: 'Open' }
        ],
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
    const el = createElement('c-sab-reversals-workspace', { is: SabReversalsWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', persona: { label: 'Bookkeeper' }, ...props });
    el.companyId = COMPANY;
    document.body.appendChild(el);
    return el;
}

function typeReason(root, text) {
    const area = root.querySelector('.sab-reason');
    area.value = text;
    area.dispatchEvent(new CustomEvent('input'));
}

describe('c-sab-reversals-workspace', () => {
    beforeEach(() => {
        getWorkspace.mockResolvedValue({ canReverseJournal: true });
        getBrowseData.mockResolvedValue(browse());
        getJournal.mockResolvedValue({ lines: [{ glAccountId: 'A1', debit: 4000 }, { glAccountId: 'A2', credit: 4000 }] });
        reverseJournal.mockResolvedValue({ reversalJournalName: 'JE-000330', replay: false });
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('lists eligible journals and history and previews the mirrored lines', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelectorAll('.sab-eligible .li').length).toBe(2);
        expect(root.querySelector('.sab-history .li').textContent).toContain('JE-000300 reversed by JE-000301');
        expect(root.querySelector('.sab-reverse-panel h2').textContent).toBe('Reverse JE-000310');
        expect(root.querySelector('.sab-original tbody tr').textContent).toBe('6100 Office expenses4,000.00');
        expect(root.querySelector('.sab-preview tbody tr').textContent).toBe('6100 Office expenses4,000.00');
        expect(root.querySelectorAll('.sab-preview tbody tr td')[2].textContent).toBe('4,000.00');
        expect(root.querySelector('.sab-blocked').textContent).toContain('FY27-P03 is closed');
        expect(root.querySelector('.sab-post-reversal').disabled).toBe(true);
        expect(root.querySelector('.post-row .hint').textContent).toBe('Enter at least 10 characters of reason.');
    });

    it('posts a reversal dated today with a reason', async () => {
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelectorAll('.sab-date-choice button')[1].click();
        await flush();
        expect(root.querySelector('.date-text').textContent).toContain('FY27-P04 (open)');
        typeReason(root, 'Posted to the wrong account');
        await flush();
        expect(root.querySelector('.sab-post-reversal').disabled).toBe(false);
        root.querySelector('.sab-post-reversal').click();
        await flush();
        expect(reverseJournal).toHaveBeenCalledWith({ originalJournalId: 'J2', reversalPeriodId: 'P4', reversalDate: today, reason: 'Posted to the wrong account' });
        expect(toast.mock.calls[0][0].detail.message).toBe('JE-000310 reversed by JE-000330');
        expect(getBrowseData).toHaveBeenCalledTimes(2);
    });

    it('uses the next period start, picks another journal and reports errors', async () => {
        reverseJournal.mockRejectedValueOnce({ body: { message: 'Reversal Accounting Period is required.' } });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        const second = root.querySelectorAll('.sab-eligible .li')[1];
        second.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        expect(root.querySelector('.sab-reverse-panel h2').textContent).toBe('Reverse JE-000320');
        root.querySelectorAll('.sab-date-choice button')[2].click();
        await flush();
        expect(root.querySelector('.date-text').textContent).toContain('FY27-P05');
        typeReason(root, 'Duplicate of JE-000318');
        await flush();
        root.querySelector('.sab-post-reversal').click();
        await flush();
        expect(toast.mock.calls[0][0].detail).toEqual({ message: 'Reversal Accounting Period is required.', tone: 'bad' });
        second.dispatchEvent(new KeyboardEvent('keydown', { key: 'a' }));
    });

    it('preselects a requested journal and handles permissions and empty lists', async () => {
        getWorkspace.mockResolvedValue({ canReverseJournal: false });
        const el = mount();
        el.recordId = 'J5';
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-reverse-panel h2').textContent).toBe('Reverse JE-000320');
        expect(root.querySelector('.sab-post-reversal').title).toBe('Bookkeeper role cannot reverse journals');
        el.recordId = 'J2';
        await flush();
        expect(root.querySelector('.sab-reverse-panel h2').textContent).toBe('Reverse JE-000310');

        getBrowseData.mockResolvedValue(browse({ journals: [], periods: [] }));
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty h3').textContent).toBe('Choose a posted journal');
        expect(el2.shadowRoot.querySelector('.sab-history .li').textContent).toBe('No reversals yet.');
    });

    it('shows detail and load errors', async () => {
        getJournal.mockRejectedValueOnce({ body: { message: 'Journal not found.' } });
        const el = mount();
        await flush();
        expect(el.shadowRoot.querySelector('.banner').textContent).toBe('Journal not found.');
        getWorkspace.mockRejectedValueOnce({ body: { message: 'Select an Accounting Company first.' } });
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty p').textContent).toBe('Select an Accounting Company first.');
        el2.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        expect(el2.shadowRoot.querySelector('.sab-eligible')).not.toBeNull();
    });
});
