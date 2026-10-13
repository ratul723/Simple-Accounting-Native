import { createElement } from 'lwc';
import SabAllocationsWorkspace from 'c/sabAllocationsWorkspace';
import getWorkspace from '@salesforce/apex/SABAllocationWorkspaceController.getWorkspace';
import getRuleDetail from '@salesforce/apex/SABAllocationWorkspaceController.getRuleDetail';
import getRunDetail from '@salesforce/apex/SABAllocationWorkspaceController.getRunDetail';
import saveRule from '@salesforce/apex/SABAllocationRuleService.saveDraft';
import approveRule from '@salesforce/apex/SABAllocationRuleService.approve';
import reviseRule from '@salesforce/apex/SABAllocationRuleService.revise';
import retireRule from '@salesforce/apex/SABAllocationRuleService.retire';
import previewRun from '@salesforce/apex/SABAllocationRunService.preview';
import approveRun from '@salesforce/apex/SABAllocationRunService.approve';
import postRun from '@salesforce/apex/SABAllocationRunService.post';
import discardRun from '@salesforce/apex/SABAllocationRunService.discard';

jest.mock('@salesforce/apex/SABAllocationWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAllocationWorkspaceController.getRuleDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAllocationWorkspaceController.getRunDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAllocationRuleService.saveDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAllocationRuleService.approve', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAllocationRuleService.revise', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAllocationRuleService.retire', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAllocationRunService.preview', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAllocationRunService.approve', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAllocationRunService.post', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAllocationRunService.discard', () => ({ default: jest.fn() }), { virtual: true });

function ws(overrides = {}) {
    return {
        functionalCurrency: 'AUD', capabilities: { manage: true, approve: true, postJournal: true }, hasRoundingAccount: false,
        rules: [{ ruleId: 'R1', name: 'Rent by department', ruleKey: 'RENT', version: 1, status: 'Approved', driverType: 'Percent', effectiveFrom: '2026-07-01', targetCount: 2 },
            { ruleId: 'R2', name: 'IT costs', ruleKey: 'IT', version: 1, status: 'Draft', driverType: 'Manual Driver', effectiveFrom: '2026-07-01', effectiveTo: '2027-06-30', targetCount: 1 }],
        runs: [{ runId: 'N1', name: 'AR-0001', ruleKey: 'RENT', ruleVersion: 1, periodName: '2026-09', status: 'Preview', sourceAmount: 4000 },
            { runId: 'N2', name: 'AR-0000', ruleKey: 'RENT', ruleVersion: 1, periodName: '2026-08', status: 'Posted', sourceAmount: 4000, journalEntryId: 'J1', journalName: 'JE-000306' },
            { runId: 'N3', name: 'AR-0002', ruleKey: 'RENT', ruleVersion: 1, periodName: '2026-10', status: 'Approved', sourceAmount: 100 }],
        accounts: [{ value: 'G1', label: '6300 Rent' }, { value: 'G2', label: '6310 Rent allocated' }],
        departments: [{ value: 'D1', label: 'Operations' }, { value: 'D2', label: 'Sales' }], costCenters: [{ value: 'K1', label: 'CC-1' }],
        openPeriods: [{ value: 'P9', label: '2026-09' }, { value: 'P10', label: '2026-10' }],
        ...overrides
    };
}

const RULE = { rule: ws().rules[0], sourceAccounts: [{ value: 'G1', label: '6300 Rent' }], sourceDepartmentName: null,
    targets: [{ targetGlAccountId: 'G2', targetAccountName: '6310 Rent allocated', targetDepartmentId: 'D1', targetDepartmentName: 'Operations', percentage: 60 },
        { targetGlAccountId: 'G2', targetAccountName: '6310 Rent allocated', targetDepartmentId: 'D2', targetDepartmentName: 'Sales', percentage: 40 }] };
const DRAFT = { ...RULE, rule: ws().rules[1], targets: [{ targetGlAccountId: 'G2', targetAccountName: '6310', driverValue: 5 }] };

async function flush() {
    for (let i = 0; i < 10; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-allocations-workspace', { is: SabAllocationsWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', persona: { label: 'Bookkeeper' }, visibleWorkspaces: ['journal'], ...props });
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

function setModal(root, field, value) {
    const input = root.querySelector(`c-sab-modal [data-field="${field}"]`);
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-allocations-workspace', () => {
    beforeEach(() => {
        getWorkspace.mockResolvedValue(ws());
        getRuleDetail.mockImplementation(({ ruleId }) => Promise.resolve(ruleId === 'R2' ? DRAFT : RULE));
        getRunDetail.mockImplementation(({ runId }) => Promise.resolve({ run: ws().runs.find((r) => r.runId === runId),
            lines: [{ rowKey: 'k1', sourceAccountName: '6300 Rent', targetAccountName: '6310', targetDepartmentName: 'Operations', amount: 2400 },
                { rowKey: 'k2', sourceAccountName: '6300 Rent', targetAccountName: '6310', targetDepartmentName: 'Sales', amount: 1600 }] }));
        [approveRule, reviseRule, retireRule, approveRun, postRun, discardRun].forEach((m) => m.mockResolvedValue({ ruleId: 'R9' }));
        previewRun.mockResolvedValue({ runId: 'N1' });
        saveRule.mockResolvedValue('R2');
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows figures, rounding warning, rules and runs', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(Array.from(root.querySelectorAll('.fig .v')).map((v) => v.textContent)).toEqual(['1', '1', '1', '4,000AUD']);
        expect(root.querySelector('.banner.t-warn').textContent).toContain('No rounding account');
        expect(root.querySelectorAll('.sab-rules tbody tr')[1].textContent).toContain('to 30 Jun 2027');
        root.querySelectorAll('.tab')[1].click();
        await flush();
        expect(root.querySelectorAll('.sab-runs tbody tr').length).toBe(3);
    });

    it('approves a draft rule, runs an approved rule and retires or revises it', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.sab-rules tbody tr')[1].click();
        await flush();
        expect(root.querySelector('c-sab-drawer').heading).toBe('IT costs');
        expect(root.querySelector('.sab-targets tbody tr').textContent).toContain('5.00');
        root.querySelector('.sab-approve-rule').click();
        await flush();
        expect(approveRule).toHaveBeenCalledWith({ ruleId: 'R2', requestKey: expect.stringMatching(/^ALLOC-RULE-APPROVE-R2-/) });
        root.querySelectorAll('.sab-rules tbody tr')[0].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        expect(root.querySelector('.sab-targets tbody tr').textContent).toContain('60.00%');
        expect(root.querySelector('.tags').textContent).toBe('6300 Rent');
        root.querySelector('.sab-preview').click();
        await flush();
        expect(root.querySelector('c-sab-modal [data-field="periodId"]').value).toBe('P10');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(previewRun.mock.calls[0][0]).toMatchObject({ ruleId: 'R1', periodId: 'P10' });
        expect(root.querySelector('c-sab-drawer').heading).toBe('AR-0001');
        root.querySelectorAll('.tab')[0].click();
        await flush();
        root.querySelectorAll('.sab-rules tbody tr')[0].click();
        await flush();
        root.querySelector('.sab-retire').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('A reason is required.');
        setModal(root, 'reason', 'Office closed');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(retireRule.mock.calls[0][0]).toMatchObject({ ruleId: 'R1', reason: 'Office closed' });
        root.querySelector('.sab-revise').click();
        await flush();
        setModal(root, 'reason', 'New split');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(reviseRule.mock.calls[0][0]).toMatchObject({ ruleId: 'R1', reason: 'New split' });
        expect(getRuleDetail).toHaveBeenLastCalledWith({ ruleId: 'R9' });
    });

    it('approves, posts and discards runs and opens the journal', async () => {
        const el = mount();
        await flush();
        const nav = jest.fn();
        el.addEventListener('sabnavigate', nav);
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[1].click();
        await flush();
        const runs = () => root.querySelectorAll('.sab-runs tbody tr');
        runs()[0].click();
        await flush();
        expect(root.querySelector('.sab-run-lines tfoot').textContent).toContain('4,000.00');
        root.querySelector('.sab-approve-run').click();
        await flush();
        expect(approveRun.mock.calls[0][0]).toMatchObject({ runId: 'N1' });
        root.querySelector('.sab-discard').click();
        await flush();
        setModal(root, 'reason', 'Wrong period');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(discardRun.mock.calls[0][0]).toMatchObject({ runId: 'N1', reason: 'Wrong period' });
        runs()[2].click();
        await flush();
        root.querySelector('.sab-post-run').click();
        await flush();
        expect(postRun.mock.calls[0][0]).toMatchObject({ runId: 'N3' });
        runs()[1].click();
        await flush();
        root.querySelector('.sab-open-journal').click();
        expect(nav.mock.calls[0][0].detail).toEqual({ workspace: 'journal', recordId: 'J1' });
        root.querySelector('c-sab-drawer').dispatchEvent(new CustomEvent('close'));
        await flush();
        expect(root.querySelector('c-sab-drawer').open).toBe(false);
    });

    it('creates and edits rules with targets', async () => {
        saveRule.mockRejectedValueOnce({ body: { message: 'Percent targets must total 100.' } });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.sab-new-rule').click();
        await flush();
        setModal(root, 'name', 'Rent');
        setModal(root, 'ruleKey', 'RENT2');
        const multi = root.querySelector('c-sab-modal [data-field="sourceAccountIds"]');
        multi.options[0].selected = true;
        multi.dispatchEvent(new CustomEvent('change'));
        const rows = () => root.querySelectorAll('.sab-target-grid tbody tr');
        const setTarget = (row, field, value) => {
            const input = rows()[row].querySelector(`[data-field="${field}"]`);
            input.value = value;
            input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
        };
        setTarget(0, 'targetGlAccountId', 'G2');
        setTarget(0, 'targetDepartmentId', 'D1');
        setTarget(0, 'percentage', '70');
        await flush();
        expect(root.querySelector('.sab-target-grid tfoot .down').textContent).toBe('70.00%');
        root.querySelector('.sab-add-target').click();
        await flush();
        root.querySelectorAll('.sab-remove-target')[2].click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('Percent targets must total 100.');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(saveRule.mock.calls[1][0].request).toMatchObject({ name: 'Rent', ruleKey: 'RENT2', driverType: 'Percent', sourceAccountIds: ['G1'],
            targets: [{ targetGlAccountId: 'G2', targetDepartmentId: 'D1', targetCostCenterId: null, percentage: 70, driverValue: null }] });
        root.querySelector('.sab-edit-rule').click();
        await flush();
        expect(root.querySelector('c-sab-modal').heading).toBe('Edit allocation rule');
        setModal(root, 'driverType', 'Manual Driver');
        await flush();
        expect(root.querySelector('.sab-target-grid thead').textContent).toContain('Driver');
        root.querySelector('.sab-modal-close').click();
    });

    it('respects permissions and handles errors', async () => {
        getWorkspace.mockResolvedValue(ws({ capabilities: { manage: false, approve: false, postJournal: false }, hasRoundingAccount: true, rules: [], runs: [] }));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-new-rule').title).toBe('Bookkeeper role cannot manage allocation rules');
        expect(root.querySelector('.empty h3').textContent).toBe('No allocation rules yet');
        root.querySelectorAll('.tab')[1].click();
        await flush();
        expect(root.querySelector('.panel-b.muted').textContent).toContain('No allocation runs yet');

        getWorkspace.mockResolvedValue(ws({ capabilities: { manage: false, approve: false, postJournal: false } }));
        getRuleDetail.mockRejectedValueOnce({ body: { message: 'Rule not found.' } });
        const el2 = mount();
        await flush();
        el2.shadowRoot.querySelectorAll('.sab-rules tbody tr')[0].click();
        await flush();
        expect(el2.shadowRoot.querySelector('c-sab-drawer .banner').textContent).toBe('Rule not found.');
        el2.shadowRoot.querySelectorAll('.sab-rules tbody tr')[1].click();
        await flush();
        expect(el2.shadowRoot.querySelector('.sab-approve-rule').title).toBe('Bookkeeper role cannot approve allocation rules');
        el2.shadowRoot.querySelectorAll('.sab-rules tbody tr')[1].dispatchEvent(new KeyboardEvent('keydown', { key: 'a' }));

        getWorkspace.mockRejectedValueOnce({ body: { message: 'Allocation workspace permission is required.' } });
        const el3 = mount();
        await flush();
        expect(el3.shadowRoot.querySelector('.empty p').textContent).toBe('Allocation workspace permission is required.');
        el3.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        expect(el3.shadowRoot.querySelector('.figs')).not.toBeNull();
    });
});
