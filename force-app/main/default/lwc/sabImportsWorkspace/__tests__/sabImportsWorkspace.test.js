import { createElement } from 'lwc';
import SabImportsWorkspace from 'c/sabImportsWorkspace';
import getWorkspace from '@salesforce/apex/SABImportsWorkspaceController.getWorkspace';
import getRows from '@salesforce/apex/SABImportsWorkspaceController.getRows';
import stageImport from '@salesforce/apex/SABImportService.stage';
import validateImport from '@salesforce/apex/SABImportService.validate';
import commitImport from '@salesforce/apex/SABImportService.commitImport';

jest.mock('@salesforce/apex/SABImportsWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABImportsWorkspaceController.getRows', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABImportService.stage', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABImportService.validate', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABImportService.commitImport', () => ({ default: jest.fn() }), { virtual: true });

const COMPANY = 'a01000000000001AAA';

function workspace(overrides = {}) {
    return {
        canManage: true, canCommit: true, canViewLog: true, importTypes: ['Chart of Accounts', 'Journal Entries', 'Opening Balances', 'Customers', 'Suppliers', 'Budgets'],
        jobs: [
            { importJobId: 'J1', name: 'IMP-0002', importType: 'Opening Balances', status: 'Validated', rowCount: 14, validCount: 12, errorCount: 2,
                requestedBy: 'Priya Nair', requestedAt: '2026-09-24T02:00:00.000Z' },
            { importJobId: 'J2', name: 'IMP-0001', importType: 'Chart of Accounts', status: 'Committed', rowCount: 56, validCount: 56, errorCount: 0 }
        ],
        requests: [
            { requestId: 'R1', direction: 'Outbound', provider: 'Bank feed', operation: 'Send payment file', state: 'Retry', attempts: 2,
                nextAttemptAt: '2026-09-25T02:00:00.000Z', errorCode: 'HTTP_503' },
            { requestId: 'R2', direction: 'Outbound', provider: 'Tax portal', operation: 'Lodge BAS', state: 'Succeeded', attempts: 1, responseReference: 'ATO-123' }
        ],
        ...overrides
    };
}

const ROWS = [
    { rowId: 'W1', rowNumber: 4, status: 'Error', message: 'Account 9999 does not exist.', valuesJson: '{"account_code":"9999","debit":"100","credit":""}' },
    { rowId: 'W2', rowNumber: 1, status: 'Valid', valuesJson: '{"account_code":"1000","debit":"500"}' },
    { rowId: 'W3', rowNumber: 2, status: 'Pending', valuesJson: 'not json' }
];

async function flush() {
    for (let i = 0; i < 10; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

async function waitForFile(root) {
    for (let i = 0; i < 50 && root.querySelector('.stage-import').disabled; i++) {
        // eslint-disable-next-line no-await-in-loop, @lwc/lwc/no-async-operation
        await new Promise((resolve) => setTimeout(resolve, 5));
    }
    await flush();
}

function mount() {
    const el = createElement('c-sab-imports-workspace', { is: SabImportsWorkspace });
    el.companyName = 'Harbourline Trading';
    el.companyId = COMPANY;
    document.body.appendChild(el);
    return el;
}

describe('c-sab-imports-workspace', () => {
    beforeEach(() => {
        getWorkspace.mockResolvedValue(workspace());
        getRows.mockResolvedValue(ROWS);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows jobs, the selected job with its steps and the error rows', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(Array.from(root.querySelectorAll('.tab')).map((t) => t.textContent)).toEqual(['Imports2', 'Integration outbox2']);
        expect(root.querySelector('.jobs tbody tr').className).toBe('click sel');
        expect(root.querySelector('.jobs .down').textContent).toBe('2');
        expect(root.querySelector('.detail h2').textContent).toBe('IMP-0002');
        expect(Array.from(root.querySelectorAll('.detail .hstep')).map((s) => s.className)).toEqual(['hstep done', 'hstep done', 'hstep done', 'hstep now', 'hstep']);
        expect(root.querySelector('.detail .banner').textContent).toContain('2 rows need fixing');
        expect(root.querySelector('.commit').textContent).toBe('Commit 12 valid rows');
        expect(root.querySelector('.validate')).not.toBeNull();
        const rows = root.querySelectorAll('.rows tbody tr');
        expect(rows.length).toBe(1);
        expect(rows[0].textContent).toContain('account code 9999, debit 100');
        root.querySelectorAll('.rows .seg button')[1].click();
        await flush();
        expect(root.querySelectorAll('.rows tbody tr').length).toBe(3);
    });

    it('commits, validates and selects another job', async () => {
        commitImport.mockResolvedValue({ status: 'Committed' });
        validateImport.mockRejectedValue({ body: { message: 'Only parsed jobs can be validated.' } });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelector('.commit').click();
        await flush();
        expect(commitImport).toHaveBeenCalledWith({ importJobId: 'J1', requestKey: expect.stringMatching(/^IMP-COMMIT-J1-/) });
        expect(toast.mock.calls[0][0].detail.message).toBe('Import committed: committed');
        root.querySelector('.validate').click();
        await flush();
        expect(toast.mock.calls[1][0].detail).toEqual({ message: 'Only parsed jobs can be validated.', tone: 'bad' });
        const second = root.querySelectorAll('.jobs tbody tr')[1];
        second.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        expect(getRows).toHaveBeenLastCalledWith({ companyId: COMPANY, importJobId: 'J2' });
        expect(root.querySelector('.detail h2').textContent).toBe('IMP-0001');
        expect(root.querySelector('.commit')).toBeNull();
        second.dispatchEvent(new KeyboardEvent('keydown', { key: 'x' }));
    });

    it('downloads an error file', async () => {
        const el = mount();
        await flush();
        const link = el.shadowRoot.querySelector('.download-link');
        link.click = jest.fn();
        el.shadowRoot.querySelector('.download').click();
        expect(link.download).toBe('IMP-0002-errors.csv');
        expect(decodeURIComponent(link.href)).toContain('4,"Account 9999 does not exist."');
        expect(link.click).toHaveBeenCalled();
    });

    it('stages and validates a new file', async () => {
        stageImport.mockResolvedValue({ importJobId: 'J9', status: 'Parsed', replay: false });
        validateImport.mockResolvedValue({ importJobId: 'J9', status: 'Ready', validCount: 2, errorCount: 0 });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelector('.new-import').click();
        await flush();
        expect(root.querySelector('c-sab-modal').open).toBe(true);
        expect(root.querySelector('.stage-import').disabled).toBe(true);
        const select = root.querySelector('.import-type');
        select.value = 'Chart of Accounts';
        select.dispatchEvent(new CustomEvent('change'));
        const input = root.querySelector('.file');
        const file = new File(['account_code,name,account_type\n5000,Rent,Expense\n6000,Fees,Expense\n'], 'coa.csv', { type: 'text/csv' });
        Object.defineProperty(input, 'files', { value: [file] });
        input.dispatchEvent(new CustomEvent('change'));
        await waitForFile(root);
        expect(root.querySelector('.drop .strong').textContent).toBe('coa.csv');
        expect(root.querySelector('.drop .small').textContent).toBe('2 data rows, 0 KB');
        expect(root.querySelector('.hint-line').textContent).toContain('account_code');
        for (const [type, text] of [['Customers', 'credit_limit'], ['Suppliers', 'accounts payable'], ['Budgets', 'budget_name']]) {
            select.value = type;
            select.dispatchEvent(new CustomEvent('change'));
            // eslint-disable-next-line no-await-in-loop
            await flush();
            expect(root.querySelector('.hint-line').textContent).toContain(text);
        }
        select.value = 'Chart of Accounts';
        select.dispatchEvent(new CustomEvent('change'));
        await flush();
        root.querySelector('.stage-import').click();
        await flush();
        expect(stageImport.mock.calls[0][0]).toMatchObject({ companyId: COMPANY, importType: 'Chart of Accounts' });
        expect(validateImport).toHaveBeenCalledWith({ importJobId: 'J9' });
        expect(toast.mock.calls[0][0].detail.message).toBe('Staged and validated: 2 valid, 0 with errors');
        expect(root.querySelector('c-sab-modal').open).toBe(false);
    });

    it('replays an already staged file and reports stage errors', async () => {
        stageImport.mockRejectedValueOnce({ body: { message: 'Missing required column: account_type.' } })
            .mockResolvedValueOnce({ importJobId: 'J2', status: 'Committed', replay: true });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.new-import').click();
        await flush();
        const input = root.querySelector('.file');
        Object.defineProperty(input, 'files', { value: [new File(['a,b\n1,2\n'], 'bad.csv')] });
        input.dispatchEvent(new CustomEvent('change'));
        await waitForFile(root);
        root.querySelector('.stage-import').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('Missing required column: account_type.');
        root.querySelector('.stage-import').click();
        await flush();
        expect(validateImport).not.toHaveBeenCalled();
        root.querySelector('.new-import').click();
        await flush();
        root.querySelector('.cancel').click();
        await flush();
        expect(root.querySelector('c-sab-modal').open).toBe(false);
    });

    it('shows the integration outbox', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[1].click();
        await flush();
        const rows = root.querySelectorAll('.outbox tbody tr');
        expect(rows.length).toBe(2);
        expect(rows[0].textContent).toContain('HTTP_503');
        expect(rows[1].textContent).toContain('ATO-123');
    });

    it('handles permissions, empty states and errors', async () => {
        getWorkspace.mockResolvedValueOnce(workspace({ canManage: false, canCommit: false, canViewLog: false, jobs: [], requests: [] }));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.new-import').title).toBe('Your role cannot stage imports');
        expect(root.querySelectorAll('.tab').length).toBe(1);
        expect(root.querySelector('.empty h3').textContent).toBe('No imports yet');
    });

    it('shows commit limits, row errors and load errors', async () => {
        getWorkspace.mockResolvedValueOnce(workspace({ canCommit: false, requests: [] }));
        getRows.mockRejectedValueOnce({ body: { message: 'The import job does not belong to this company.' } });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.commit').title).toBe('Your role cannot commit imports');
        expect(root.querySelector('.rows .banner').textContent).toBe('The import job does not belong to this company.');
        root.querySelectorAll('.tab')[1].click();
        await flush();
        expect(root.querySelector('.outbox .panel-b.muted').textContent).toBe('No integration requests for this company.');

        getWorkspace.mockRejectedValueOnce({ body: { message: 'You do not have permission to view the Import and integration center.' } });
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have permission to view the Import and integration center.');
        el2.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        expect(el2.shadowRoot.querySelector('.jobs')).not.toBeNull();
    });
});
