import { createElement } from 'lwc';
import SabJournalsWorkspace from 'c/sabJournalsWorkspace';
import getWorkspace from '@salesforce/apex/SABJournalWorkspaceController.getWorkspace';
import getJournal from '@salesforce/apex/SABJournalWorkspaceController.getJournal';
import saveDraft from '@salesforce/apex/SABJournalWorkspaceController.saveDraft';
import validateOnServer from '@salesforce/apex/SABJournalWorkspaceController.validateJournal';
import postJournal from '@salesforce/apex/SABJournalWorkspaceController.postJournal';
import getBrowseData from '@salesforce/apex/SABJournalBrowseController.getBrowseData';

jest.mock('@salesforce/apex/SABJournalWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABJournalWorkspaceController.getJournal', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABJournalWorkspaceController.saveDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABJournalWorkspaceController.validateJournal', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABJournalWorkspaceController.postJournal', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABJournalBrowseController.getBrowseData', () => ({ default: jest.fn() }), { virtual: true });

const COMPANY = 'a01000000000001AAA';
const today = (() => {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
})();
const monthStart = `${today.slice(0, 8)}01`;

const CTX = {
    companyId: COMPANY, functionalCurrency: 'AUD', canPostJournal: true, canReverseJournal: true,
    departments: [{ value: 'D1', label: 'Operations' }], costCenters: [{ value: 'C1', label: 'CC-100' }]
};

function browse(overrides = {}) {
    return {
        journals: [
            { journalId: 'J1', name: 'JE-000318', accountingDate: today, description: 'September accrual', entryType: 'Manual', status: 'Draft',
                totalDebit: 1200, periodKey: 'FY27-P04', createdBy: 'Priya Nair' },
            { journalId: 'J2', name: 'JE-000310', accountingDate: '2026-09-15', description: 'Rent', entryType: 'Manual', status: 'Posted',
                totalDebit: 4000, periodKey: 'FY27-P03', postedBy: 'Alex Morgan', postedAt: '2026-09-15T02:00:00.000Z', postingKey: 'HLT:JE:310:v1',
                accountingEventName: 'EVT-000101' },
            { journalId: 'J3', name: 'JE-000300', accountingDate: '2026-09-01', description: 'Wrong accrual', entryType: 'Manual', status: 'Reversed',
                totalDebit: 900, reversalJournalName: 'JE-000301' }
        ],
        accounts: [
            { accountId: 'A1', code: '6100', name: 'Office expenses', accountType: 'Expense', manualPostingAllowed: true, controlType: 'None', active: true },
            { accountId: 'A2', code: '2100', name: 'Accrued liabilities', accountType: 'Liability', manualPostingAllowed: true, controlType: 'None', active: true },
            { accountId: 'A3', code: '1100', name: 'Accounts receivable', accountType: 'Asset', manualPostingAllowed: false, controlType: 'AR', active: true }
        ],
        periods: [
            { periodId: 'P3', periodKey: 'FY27-P03', startDate: '2026-09-01', endDate: '2026-09-30', status: 'Closed' },
            { periodId: 'P4', periodKey: 'FY27-P04', startDate: monthStart, endDate: `${today.slice(0, 8)}31`, status: 'Open' }
        ],
        ...overrides
    };
}

const DRAFT = { journalId: 'J1', journalName: 'JE-000318', status: 'Draft', entryType: 'Manual', accountingDate: today, description: 'September accrual',
    lines: [{ glAccountId: 'A1', debit: 1200, explanation: 'Accrual', departmentId: 'D1' }, { glAccountId: 'A2', credit: 1200 }] };
const POSTED = { journalId: 'J2', journalName: 'JE-000310', status: 'Posted', entryType: 'Manual', accountingDate: '2026-09-15', description: 'Rent',
    lines: [{ glAccountId: 'A1', debit: 4000, departmentId: 'D1', costCenterId: 'C1' }, { glAccountId: 'A2', credit: 4000 }] };

async function flush() {
    for (let i = 0; i < 10; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-journals-workspace', { is: SabJournalsWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', caps: { canCreateJournal: true }, persona: { label: 'Bookkeeper' },
        visibleWorkspaces: ['journal', 'reversal'], ...props });
    el.companyId = COMPANY;
    document.body.appendChild(el);
    return el;
}

function setLine(root, index, field, value) {
    const input = root.querySelector(`[data-index="${index}"][data-field="${field}"]`);
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-journals-workspace', () => {
    beforeEach(() => {
        getWorkspace.mockResolvedValue(CTX);
        getBrowseData.mockResolvedValue(browse());
        getJournal.mockImplementation(({ journalId }) => Promise.resolve(journalId === 'J2' ? POSTED : journalId === 'J3' ? { ...POSTED, journalId: 'J3', journalName: 'JE-000300', status: 'Reversed' } : DRAFT));
        saveDraft.mockImplementation(({ request }) => Promise.resolve({ journalId: request.journalId || 'J9', journalName: request.journalId ? 'JE-000318' : 'JE-000400' }));
        validateOnServer.mockResolvedValue({ isValid: true, errors: [] });
        postJournal.mockResolvedValue({ status: 'Posted', replay: false });
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('lists journals with filters and opens the first draft in the editable grid', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        const items = root.querySelectorAll('.sab-journal-list .li');
        expect(items.length).toBe(3);
        expect(items[0].className).toBe('li click sel');
        expect(items[0].textContent).toContain('1,200.00');
        expect(root.querySelector('.je-title').textContent).toContain('JE-000318');
        expect(root.querySelector('.sab-period').textContent).toContain('FY27-P04');
        expect(root.querySelectorAll('.egrid tbody tr').length).toBe(2);
        expect(root.querySelector('.scale .state').textContent).toBe('Balanced');
        expect(root.querySelector('.issues .issue').textContent).toBe('Ready to post to FY27-P04.');
        expect(root.querySelector('.sab-post').disabled).toBe(false);
        root.querySelectorAll('.seg button')[2].click();
        await flush();
        expect(root.querySelectorAll('.sab-journal-list .li').length).toBe(1);
        root.querySelectorAll('.seg button')[1].click();
        await flush();
        root.querySelectorAll('.seg button')[3].click();
        await flush();
        expect(root.querySelector('.sab-journal-list .li').textContent).toContain('JE-000300');
    });

    it('validates live: balance, control accounts, both sides and missing department', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        setLine(root, 1, 'credit', '1000');
        await flush();
        expect(root.querySelector('.scale .state').textContent).toBe('Out by 200.00');
        expect(root.querySelector('.sab-post').title).toBe('Fix the blocking issues first');
        setLine(root, 1, 'glAccountId', 'A3');
        setLine(root, 0, 'credit', '5');
        setLine(root, 0, 'departmentId', '');
        await flush();
        const messages = Array.from(root.querySelectorAll('.issues .issue')).map((i) => i.textContent);
        expect(messages).toContain('Line 2: 1100 Accounts receivable is a AR control account. Post through the matching subledger instead.');
        expect(messages).toContain('Line 1: enter a debit or a credit, not both.');
        expect(messages).toContain('Line 1: no department. P&L by department will show it as unassigned.');
        expect(root.querySelectorAll('.egrid td.err').length).toBe(2);
        root.querySelector('.sab-add-line').click();
        await flush();
        expect(root.querySelectorAll('.egrid tbody tr').length).toBe(3);
        expect(root.querySelector('.add-row .hint').textContent).toBe('3 of 200 lines');
        root.querySelectorAll('.sab-remove-line')[2].click();
        await flush();
        expect(root.querySelectorAll('.egrid tbody tr').length).toBe(2);
    });

    it('creates, saves, previews and posts a new journal', async () => {
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelector('.sab-new-journal').click();
        await flush();
        expect(root.querySelector('.je-title').textContent).toContain('New journal');
        expect(root.querySelector('.panel-h .sub').textContent).toBe('Unsaved draft');
        const description = root.querySelector('.sab-description');
        description.value = 'Accrue audit fee';
        description.dispatchEvent(new CustomEvent('input'));
        setLine(root, 0, 'glAccountId', 'A1');
        setLine(root, 0, 'departmentId', 'D1');
        setLine(root, 0, 'debit', '750');
        setLine(root, 1, 'glAccountId', 'A2');
        setLine(root, 1, 'credit', '750');
        await flush();
        root.querySelector('.sab-preview').click();
        await flush();
        const modal = root.querySelector('c-sab-modal');
        expect(modal.open).toBe(true);
        expect(modal.heading).toBe('Posting preview for New journal');
        expect(root.querySelector('c-sab-modal .banner').textContent).toContain('Ready to post');
        expect(root.querySelector('.preview-table tfoot').textContent).toBe('Total750.00750.00');
        root.querySelector('.sab-preview-post').click();
        await flush();
        expect(saveDraft.mock.calls[0][0].request).toMatchObject({ journalId: null, companyId: COMPANY, periodId: 'P4', description: 'Accrue audit fee',
            lines: [{ glAccountId: 'A1', debit: 750, credit: null, departmentId: 'D1' }, { glAccountId: 'A2', debit: null, credit: 750 }] });
        expect(validateOnServer).toHaveBeenCalledWith({ journalId: 'J9' });
        expect(postJournal).toHaveBeenCalledWith({ journalId: 'J9' });
        expect(toast.mock.calls[0][0].detail.message).toBe('JE-000400 posted');
    });

    it('saves a draft and reports server validation failures', async () => {
        validateOnServer.mockResolvedValueOnce({ isValid: false, errors: ['Period is closed.'] });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelector('.sab-save-draft').click();
        await flush();
        expect(toast.mock.calls[0][0].detail.message).toBe('JE-000318 saved');
        root.querySelector('.sab-post').click();
        await flush();
        expect(toast.mock.calls[1][0].detail).toEqual({ message: 'Period is closed.', tone: 'bad' });
        expect(postJournal).not.toHaveBeenCalled();
        saveDraft.mockRejectedValueOnce({ body: { message: 'Only Draft Journal Entries can be edited.' } });
        root.querySelector('.sab-save-draft').click();
        await flush();
        expect(toast.mock.calls[2][0].detail.tone).toBe('bad');
    });

    it('blocks a closed period and shows a blocked preview', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        const date = root.querySelector('.sab-date');
        date.value = '2026-09-10';
        date.dispatchEvent(new CustomEvent('input'));
        await flush();
        expect(root.querySelector('.issues .issue').textContent).toBe('FY27-P03 is closed. Change the accounting date or reopen the period first.');
        expect(root.querySelector('.sab-save-draft').disabled).toBe(true);
        date.value = '2020-01-01';
        date.dispatchEvent(new CustomEvent('input'));
        await flush();
        expect(root.querySelector('.sab-period').textContent).toBe('\u2014');
        root.querySelector('.sab-preview').click();
        await flush();
        expect(root.querySelector('.sab-preview-blocked').textContent).toContain('no accounting period');
        root.querySelector('.sab-keep-editing').click();
        await flush();
        expect(root.querySelector('c-sab-modal').open).toBe(false);
    });

    it('shows a posted journal locked with its facts and reverses it', async () => {
        const el = mount();
        await flush();
        const nav = jest.fn();
        el.addEventListener('sabnavigate', nav);
        const root = el.shadowRoot;
        const posted = root.querySelectorAll('.sab-journal-list .li')[1];
        posted.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        expect(root.querySelector('.pad-top .banner').textContent).toContain('Locked');
        expect(root.querySelector('.kv').textContent).toContain('HLT:JE:310:v1');
        expect(root.querySelector('.egrid tbody tr').textContent).toContain('6100 Office expenses');
        expect(root.querySelector('.egrid tbody tr').textContent).toContain('CC-100');
        expect(root.querySelector('.validation')).toBeNull();
        root.querySelector('.sab-reverse').click();
        expect(nav.mock.calls[0][0].detail).toEqual({ workspace: 'reversal', recordId: 'J2' });
        root.querySelectorAll('.sab-journal-list .li')[2].click();
        await flush();
        expect(root.querySelector('.pad-top .banner').textContent).toContain('Reversed by JE-000301');
        posted.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab' }));
    });

    it('respects missing permissions and empty companies', async () => {
        getWorkspace.mockResolvedValue({ ...CTX, canPostJournal: false, canReverseJournal: false });
        const el = mount({ caps: { canCreateJournal: false } });
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-new-journal').title).toBe('Bookkeeper role cannot create journals');
        expect(root.querySelector('.pad-top .banner').textContent).toContain('Read only for your role');
        expect(root.querySelector('.egrid select')).toBeNull();
        root.querySelectorAll('.sab-journal-list .li')[1].click();
        await flush();
        expect(root.querySelector('.sab-reverse').title).toBe('Bookkeeper role cannot reverse journals');

        getBrowseData.mockResolvedValue(browse({ journals: [] }));
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty h3').textContent).toBe('No journals yet');
    });

    it('opens a requested record and shows load errors', async () => {
        const el = mount();
        el.recordId = 'J2';
        await flush();
        expect(el.shadowRoot.querySelector('.je-title').textContent).toContain('JE-000310');
        el.recordId = 'J1';
        await flush();
        expect(el.shadowRoot.querySelector('.je-title').textContent).toContain('JE-000318');

        getJournal.mockRejectedValueOnce({ body: { message: 'Journal not found.' } });
        el.shadowRoot.querySelectorAll('.sab-journal-list .li')[1].click();
        await flush();
        expect(el.shadowRoot.querySelector('.sab-editor .banner').textContent).toBe('Journal not found.');

        getWorkspace.mockRejectedValueOnce({ body: { message: 'Select an Accounting Company first.' } });
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty p').textContent).toBe('Select an Accounting Company first.');
        el2.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        expect(el2.shadowRoot.querySelector('.sab-journal-list')).not.toBeNull();
    });
});
