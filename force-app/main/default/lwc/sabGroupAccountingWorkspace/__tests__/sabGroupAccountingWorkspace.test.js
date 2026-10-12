import { createElement } from 'lwc';
import SabGroupAccountingWorkspace from 'c/sabGroupAccountingWorkspace';
import getWorkspace from '@salesforce/apex/SABGroupAccountingWorkspaceController.getWorkspace';
import getCompanyOptions from '@salesforce/apex/SABGroupAccountingWorkspaceController.getCompanyOptions';
import getAccountOptions from '@salesforce/apex/SABGroupAccountingWorkspaceController.getAccountOptions';
import recordIntercompany from '@salesforce/apex/SABIntercompanyService.recordTransaction';
import saveGroup from '@salesforce/apex/SABConsolidationService.saveGroup';
import saveMember from '@salesforce/apex/SABConsolidationService.saveMember';
import calculateRun from '@salesforce/apex/SABConsolidationService.calculate';
import approveRun from '@salesforce/apex/SABConsolidationService.approve';
import publishRun from '@salesforce/apex/SABConsolidationService.publish';
import getTrialBalance from '@salesforce/apex/SABConsolidationService.getTrialBalance';

jest.mock('@salesforce/apex/SABGroupAccountingWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABGroupAccountingWorkspaceController.getCompanyOptions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABGroupAccountingWorkspaceController.getAccountOptions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABIntercompanyService.recordTransaction', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABConsolidationService.saveGroup', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABConsolidationService.saveMember', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABConsolidationService.calculate', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABConsolidationService.approve', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABConsolidationService.publish', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABConsolidationService.getTrialBalance', () => ({ default: jest.fn() }), { virtual: true });

const COMPANY = 'a01000000000001AAA';

function workspace(overrides = {}) {
    return {
        currencyCode: 'AUD', canManageIntercompany: true, canManageConsolidation: true, canApproveConsolidation: true, canPostJournal: true,
        consolidationAvailable: true, fiscalYearStart: '2026-07-01', receivableTotal: 12000, payableTotal: 3000, volumeThisYear: 15000,
        unmatchedCount: 1,
        transactions: [
            { transactionId: 'IC1', name: 'IC-0002', transactionDate: '2026-09-15', fromCompany: 'Harbourline Trading', toCompany: 'Harbourline NZ',
                direction: 'Receivable', description: 'Management fee', amount: 12000, currencyCode: 'AUD', state: 'Matched' },
            { transactionId: 'IC2', name: 'IC-0001', transactionDate: '2026-08-15', fromCompany: 'Harbourline NZ', toCompany: 'Harbourline Trading',
                direction: 'Payable', description: 'Freight', amount: 3000, currencyCode: 'AUD', state: 'Difference' }
        ],
        groups: [
            { groupId: 'G1', name: 'Harbourline Group', presentationCurrency: 'AUD', policyVersion: 'v1', active: true,
                members: [
                    { memberId: 'M1', companyId: COMPANY, companyName: 'Harbourline Trading', controlType: 'Subsidiary', ownershipPercent: 100,
                        effectiveFrom: '2026-07-01', mappingVersion: 'v1' },
                    { memberId: 'M2', companyId: 'a01B', companyName: 'Harbourline NZ', controlType: 'Subsidiary', ownershipPercent: 80,
                        effectiveFrom: '2026-07-01', effectiveTo: '2027-06-30', mappingVersion: 'v1' }
                ],
                runs: [
                    { runId: 'R2', name: 'CR-0002', asOfDate: '2026-09-30', status: 'Calculated', calculatedByMe: false, calculatedAt: '2026-10-01T01:00:00.000Z', eliminationCount: 4 },
                    { runId: 'R1', name: 'CR-0001', asOfDate: '2026-08-31', status: 'Approved', calculatedByMe: true, calculatedAt: '2026-09-01T01:00:00.000Z', eliminationCount: 4 }
                ] }
        ],
        ...overrides
    };
}

async function flush() {
    for (let i = 0; i < 8; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount() {
    const el = createElement('c-sab-group-accounting-workspace', { is: SabGroupAccountingWorkspace });
    el.companyName = 'Harbourline Trading';
    el.companyId = COMPANY;
    document.body.appendChild(el);
    return el;
}

function setField(root, field, value) {
    const input = root.querySelector(`[data-field="${field}"]`);
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-group-accounting-workspace', () => {
    beforeEach(() => {
        getWorkspace.mockResolvedValue(workspace());
        getCompanyOptions.mockResolvedValue([
            { value: COMPANY, label: 'Harbourline Trading (HLT-AU, AUD)', kind: 'AUD' },
            { value: 'a01B', label: 'Harbourline NZ (HLT-NZ, AUD)', kind: 'AUD' }
        ]);
        getAccountOptions.mockImplementation(({ accountCompanyId }) => Promise.resolve(accountCompanyId === COMPANY
            ? [{ value: 'A1', label: '1400 IC receivable', kind: 'Asset' }, { value: 'A2', label: '4100 IC revenue', kind: 'Revenue' }]
            : [{ value: 'B1', label: '2400 IC payable', kind: 'Liability' }, { value: 'B2', label: '6100 IC expense', kind: 'Expense' }]));
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders figures and the intercompany table', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(Array.from(root.querySelectorAll('.fig .v')).map((v) => v.textContent)).toEqual(['12,000AUD', '3,000AUD', '15,000AUD', '1']);
        expect(Array.from(root.querySelectorAll('.fig .s')).map((s) => s.textContent)).toEqual([
            '1 transaction', '1 transaction', '1 transaction not matched', 'Latest run calculated, as of 30 Sep 2026'
        ]);
        const rows = root.querySelectorAll('tbody tr');
        expect(rows.length).toBe(2);
        expect(rows[1].querySelector('.chip').className).toBe('chip t-bad');
        expect(rows[0].querySelector('.tag').textContent).toBe('Receivable');
    });

    it('shows groups, members and run actions with the right rules', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[1].click();
        await flush();
        expect(root.querySelector('.group-panel h2').textContent).toBe('Harbourline Group');
        const members = root.querySelectorAll('.members tbody tr');
        expect(members[1].textContent).toBe('Harbourline NZSubsidiary80.00%1 Jul 202630 Jun 2027v1');
        expect(members[0].textContent).toContain('Open');
        expect(root.querySelector('.approve-run').disabled).toBe(false);
        const publish = root.querySelector('.publish-run');
        expect(publish.disabled).toBe(true);
        expect(publish.title).toBe('The user who calculated a run cannot approve or publish it');
    });

    it('approves and publishes runs and shows the trial balance drawer', async () => {
        const runs = workspace().groups[0].runs.map((r) => ({ ...r, calculatedByMe: false }));
        const data = workspace();
        data.groups[0].runs = runs;
        getWorkspace.mockResolvedValue(data);
        approveRun.mockResolvedValue({ status: 'Approved' });
        publishRun.mockRejectedValue({ body: { message: 'Member ledgers or intercompany transactions changed since calculation; calculate a new run.' } });
        getTrialBalance.mockResolvedValue({ runId: 'R2', status: 'Calculated', asOfDate: '2026-09-30', presentationCurrency: 'AUD', stale: true,
            consolidatedCompanies: ['Harbourline Trading', 'Harbourline NZ'], excludedMembers: ['Harbourline JV (Joint Venture)'],
            rows: [{ accountCode: '1400', accountName: 'IC receivable', memberTotal: 12000, eliminations: -12000, consolidated: 0 },
                { accountCode: '1100', accountName: 'Bank', memberTotal: 5000, eliminations: 0, consolidated: 5000 }] });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[1].click();
        await flush();
        root.querySelector('.approve-run').click();
        await flush();
        expect(approveRun).toHaveBeenCalledWith({ runId: 'R2', requestKey: expect.stringMatching(/^CONS-APPROVE-R2-/) });
        root.querySelector('.publish-run').click();
        await flush();
        expect(publishRun).toHaveBeenCalledWith({ runId: 'R1', requestKey: expect.stringMatching(/^CONS-PUBLISH-R1-/) });
        expect(toast.mock.calls[1][0].detail.tone).toBe('bad');
        root.querySelector('.view-tb').click();
        await flush();
        const drawer = root.querySelector('c-sab-drawer');
        expect(drawer.open).toBe(true);
        expect(drawer.heading).toBe('Consolidated trial balance as of 30 Sep 2026');
        expect(root.querySelector('.stale')).not.toBeNull();
        expect(root.querySelector('.kv').textContent).toContain('Harbourline JV (Joint Venture)');
        expect(root.querySelector('.tb tfoot').textContent).toBe('Total17,000.00(12,000.00)5,000.00');
        drawer.dispatchEvent(new CustomEvent('close'));
        await flush();
        expect(root.querySelector('c-sab-drawer').open).toBe(false);
    });

    it('records an intercompany transaction with accounts of both companies', async () => {
        recordIntercompany.mockResolvedValue({ transactionId: 'IC9' });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.record-ic').click();
        await flush();
        expect(Array.from(root.querySelectorAll('[data-field="toCompanyId"] option')).map((o) => o.value)).toEqual(['', 'a01B']);
        setField(root, 'toCompanyId', 'a01B');
        await flush();
        expect(getAccountOptions).toHaveBeenCalledWith({ companyId: COMPANY, accountCompanyId: 'a01B' });
        setField(root, 'amount', '2500');
        setField(root, 'description', 'IT recharge');
        setField(root, 'fromReceivableAccountId', 'A1');
        setField(root, 'fromCounterAccountId', 'A2');
        setField(root, 'toPayableAccountId', 'B1');
        setField(root, 'toCounterAccountId', 'B2');
        root.querySelector('.save').click();
        await flush();
        expect(recordIntercompany.mock.calls[0][0]).toMatchObject({
            request: { fromCompanyId: COMPANY, toCompanyId: 'a01B', amount: 2500, description: 'IT recharge', fromReceivableAccountId: 'A1',
                fromCounterAccountId: 'A2', toPayableAccountId: 'B1', toCounterAccountId: 'B2' },
            requestKey: expect.stringMatching(/^IC-/)
        });
        expect(root.querySelector('c-sab-modal').open).toBe(false);
    });

    it('creates groups and members and calculates a run', async () => {
        saveGroup.mockResolvedValue('G9');
        saveMember.mockRejectedValueOnce({ body: { message: 'Member company must share the presentation currency.' } }).mockResolvedValueOnce('M9');
        calculateRun.mockResolvedValue({ runId: 'R9', status: 'Calculated', eliminationCount: 2 });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[1].click();
        await flush();
        root.querySelector('.new-group').click();
        await flush();
        setField(root, 'name', 'Pacific Group');
        root.querySelector('.save').click();
        await flush();
        expect(saveGroup).toHaveBeenCalledWith({ groupId: null, name: 'Pacific Group', presentationCurrency: 'AUD', policyVersion: 'v1' });
        root.querySelector('.add-member').click();
        await flush();
        setField(root, 'companyId', 'a01B');
        root.querySelector('.save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('Member company must share the presentation currency.');
        root.querySelector('.save').click();
        await flush();
        expect(saveMember.mock.calls[1][0].request).toMatchObject({ groupId: 'G1', companyId: 'a01B', controlType: 'Subsidiary', ownershipPercent: 100 });
        root.querySelector('.calculate').click();
        await flush();
        root.querySelector('.save').click();
        await flush();
        expect(calculateRun.mock.calls[0][0]).toMatchObject({ groupId: 'G1', requestKey: expect.stringMatching(/^CONS-CALC-/) });
        expect(toast.mock.calls[toast.mock.calls.length - 1][0].detail.message).toBe('Consolidation calculated with 2 eliminations');
    });

    it('explains disabled actions and empty states', async () => {
        getWorkspace.mockResolvedValue(workspace({ canManageIntercompany: false, canManageConsolidation: false, canApproveConsolidation: false,
            transactions: [], groups: [], unmatchedCount: 0 }));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.record-ic').title).toBe('Your role cannot record intercompany transactions');
        expect(root.querySelector('.calculate').title).toBe('Your role cannot manage consolidation');
        expect(root.querySelector('.panel-b.muted').textContent).toBe('No intercompany transactions for this company.');
        expect(root.querySelectorAll('.fig .s')[2].textContent).toBe('All transactions matched');
        root.querySelectorAll('.tab')[1].click();
        await flush();
        expect(root.querySelector('.empty h3').textContent).toBe('This company is not in a consolidation group');
    });

    it('explains journal and group prerequisites', async () => {
        getWorkspace.mockResolvedValue(workspace({ canPostJournal: false, groups: [] }));
        const el = mount();
        await flush();
        expect(el.shadowRoot.querySelector('.record-ic').title).toBe('Recording posts journals and needs journal posting permission');
        expect(el.shadowRoot.querySelector('.calculate').title).toBe('Add a consolidation group first');
        getWorkspace.mockResolvedValue(workspace({ canApproveConsolidation: false, consolidationAvailable: false, groups: [] }));
        const el2 = mount();
        await flush();
        el2.shadowRoot.querySelectorAll('.tab')[1].click();
        await flush();
        expect(el2.shadowRoot.querySelector('.panel-b.muted').textContent).toBe('Consolidation is not available for your access.');
    });

    it('shows load errors with retry and option errors as toasts', async () => {
        getWorkspace.mockRejectedValueOnce({ body: { message: 'You do not have permission to view Group accounting.' } });
        const el = mount();
        await flush();
        expect(el.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have permission to view Group accounting.');
        el.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        getCompanyOptions.mockRejectedValueOnce({ message: 'Options failed' });
        getTrialBalance.mockRejectedValueOnce({ message: 'Run not found' });
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        el.shadowRoot.querySelector('.record-ic').click();
        await flush();
        el.shadowRoot.querySelectorAll('.tab')[1].click();
        await flush();
        el.shadowRoot.querySelector('.view-tb').click();
        await flush();
        expect(toast.mock.calls.map((c) => c[0].detail.message)).toEqual(['Options failed', 'Run not found']);
    });
});
