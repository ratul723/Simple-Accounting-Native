import { createElement } from 'lwc';
import SabAllocationWorkspace from 'c/sabAllocationWorkspace';
import getWorkspace from '@salesforce/apex/SABAllocationWorkspaceController.getWorkspace';
import getRuleDetail from '@salesforce/apex/SABAllocationWorkspaceController.getRuleDetail';
import getRunDetail from '@salesforce/apex/SABAllocationWorkspaceController.getRunDetail';
import saveDraft from '@salesforce/apex/SABAllocationRuleService.saveDraft';
import approveRule from '@salesforce/apex/SABAllocationRuleService.approve';
import previewRun from '@salesforce/apex/SABAllocationRunService.preview';
import postRun from '@salesforce/apex/SABAllocationRunService.post';
import discardRun from '@salesforce/apex/SABAllocationRunService.discard';

const APEX = ['SABAllocationWorkspaceController.getWorkspace', 'SABAllocationWorkspaceController.getRuleDetail',
    'SABAllocationWorkspaceController.getRunDetail', 'SABAllocationRuleService.saveDraft', 'SABAllocationRuleService.approve',
    'SABAllocationRuleService.revise', 'SABAllocationRuleService.retire', 'SABAllocationRunService.preview',
    'SABAllocationRunService.approve', 'SABAllocationRunService.post', 'SABAllocationRunService.discard'];
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

const COMPANY_ID = 'a00000000000001AAA';
const RULE_ID = 'a0R000000000001AAA';
const RUN_ID = 'a0S000000000001AAA';
const RENT = 'a0G000000000001AAA';
const SALES = 'a0D000000000001AAA';
const OPS = 'a0D000000000002AAA';
const OCT = 'a0P000000000001AAA';

function workspace(caps, rules, runs) {
    return {
        companyId: COMPANY_ID, companyName: 'Harbourline Trading', functionalCurrency: 'BDT', hasRoundingAccount: true,
        capabilities: { manage: true, approve: true, postJournal: true, ...caps },
        rules: rules || [{ ruleId: RULE_ID, ruleKey: 'RENT-SPLIT', name: 'Rent split', version: 1, status: 'Approved', driverType: 'Percent',
            roundingPolicy: 'Largest Remainder', targetCount: 2 }],
        runs: runs || [{ runId: RUN_ID, name: 'AR-0001', ruleKey: 'RENT-SPLIT', ruleVersion: 1, periodName: 'Oct 2026', status: 'Approved',
            sourceAmount: 1100.01 }],
        ruleCounts: [{ state: 'Approved', count: 1 }], runCounts: [{ state: 'Approved', count: 1 }],
        accounts: [{ label: '6100 Rent', value: RENT }], departments: [{ label: 'Sales', value: SALES }, { label: 'Ops', value: OPS }],
        costCenters: [], openPeriods: [{ label: 'Oct 2026', value: OCT }]
    };
}

function ruleDetail(status) {
    return {
        rule: { ruleId: RULE_ID, ruleKey: 'RENT-SPLIT', name: 'Rent split', version: 1, status, driverType: 'Percent',
            roundingPolicy: 'Largest Remainder', effectiveFrom: '2026-01-01' },
        sourceAccounts: [{ label: '6100 Rent', value: RENT }],
        targets: [{ sequence: 1, targetAccountName: 'Same as source', targetDepartmentId: SALES, targetDepartmentName: 'Sales', percentage: 60 },
            { sequence: 2, targetAccountName: 'Same as source', targetDepartmentId: OPS, targetDepartmentName: 'Ops', percentage: 40 }]
    };
}

function runDetail(status) {
    return {
        run: { runId: RUN_ID, name: 'AR-0001', ruleKey: 'RENT-SPLIT', ruleVersion: 1, periodName: 'Oct 2026', status, sourceAmount: 1000 },
        lines: [{ rowKey: 'L0', sourceAccountName: '6100 Rent', targetAccountName: '6100 Rent', targetDepartmentName: 'Sales', amount: 600 },
            { rowKey: 'L1', sourceAccountName: '6100 Rent', targetAccountName: '6100 Rent', targetDepartmentName: 'Ops', amount: 400 }]
    };
}

// Test-only: let pending Apex promises and re-renders settle.
// eslint-disable-next-line @lwc/lwc/no-async-operation
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

async function mount() {
    const element = createElement('c-sab-allocation-workspace', { is: SabAllocationWorkspace });
    document.body.appendChild(element);
    await flush();
    await flush();
    return element;
}

const q = (element, selector) => element.shadowRoot.querySelector(selector);
const qa = (element, selector) => Array.from(element.shadowRoot.querySelectorAll(selector));

async function change(target, value) {
    target.dispatchEvent(new CustomEvent('change', { detail: { value } }));
    await flush();
}

async function select(element, tableIndex, row) {
    qa(element, 'lightning-datatable')[tableIndex].dispatchEvent(new CustomEvent('rowselection', { detail: { selectedRows: [row] } }));
    await flush();
    await flush();
}

describe('c-sab-allocation-workspace', () => {
    beforeEach(() => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANY_ID);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        window.sessionStorage.clear();
        jest.clearAllMocks();
    });

    it('asks for a company when none is selected', async () => {
        window.sessionStorage.clear();
        const element = await mount();
        expect(q(element, '.empty-state').textContent).toContain('Select an Accounting Company');
        expect(getWorkspace).not.toHaveBeenCalled();
        expect(APEX).toHaveLength(11);
    });

    it('loads rules, runs and counts for the stored company', async () => {
        getWorkspace.mockResolvedValue(workspace());
        const element = await mount();
        expect(getWorkspace).toHaveBeenCalledWith({ companyId: COMPANY_ID });
        expect(q(element, '.company-name').textContent).toBe('Harbourline Trading');
        expect(qa(element, '.metric-card')).toHaveLength(2);
    });

    it('saves a Percent draft only when the targets total 100 and sends the service request shape', async () => {
        getWorkspace.mockResolvedValue(workspace());
        getRuleDetail.mockResolvedValue(ruleDetail('Draft'));
        saveDraft.mockResolvedValue(RULE_ID);
        const element = await mount();
        q(element, 'lightning-button.new-rule').click();
        await flush();
        await change(q(element, '[data-field="name"]'), 'Rent split');
        await change(q(element, '[data-field="ruleKey"]'), 'rent-split');
        await change(q(element, '[data-field="effectiveFrom"]'), '2026-01-01');
        await change(q(element, '[data-field="sourceAccountIds"]'), [RENT]);
        await change(q(element, '[data-field="targetDepartmentId"]'), SALES);
        await change(q(element, '.target-row [data-field="weight"]'), '60');
        expect(q(element, 'lightning-button.save-rule').disabled).toBe(true);
        q(element, 'lightning-button.add-target').click();
        await flush();
        const rows = qa(element, '.target-row');
        await change(rows[1].querySelector('[data-field="targetDepartmentId"]'), OPS);
        await change(rows[1].querySelector('[data-field="weight"]'), '40');
        expect(q(element, 'lightning-button.save-rule').disabled).toBe(false);
        q(element, 'lightning-button.save-rule').click();
        await flush();
        await flush();
        const request = saveDraft.mock.calls[0][0].request;
        expect(request).toMatchObject({ companyId: COMPANY_ID, name: 'Rent split', ruleKey: 'rent-split', driverType: 'Percent',
            sourceAccountIds: [RENT], sourceDepartmentId: null, effectiveTo: null });
        expect(request.targets).toEqual([
            { targetGlAccountId: null, targetDepartmentId: SALES, targetCostCenterId: null, percentage: 60, driverValue: null },
            { targetGlAccountId: null, targetDepartmentId: OPS, targetCostCenterId: null, percentage: 40, driverValue: null }]);
    });

    it('approves a Draft rule with a request key', async () => {
        getWorkspace.mockResolvedValue(workspace(null, [{ ruleId: RULE_ID, ruleKey: 'RENT-SPLIT', version: 1, status: 'Draft' }]));
        getRuleDetail.mockResolvedValue(ruleDetail('Draft'));
        approveRule.mockResolvedValue({ status: 'Approved' });
        const element = await mount();
        await select(element, 0, { ruleId: RULE_ID });
        q(element, 'lightning-button.approve-rule').click();
        await flush();
        expect(approveRule).toHaveBeenCalledWith({ ruleId: RULE_ID, requestKey: expect.stringMatching(/^G14B\|APPROVE_RULE\|/) });
    });

    it('previews an approved rule for an open period', async () => {
        getWorkspace.mockResolvedValue(workspace(null, null, []));
        getRunDetail.mockResolvedValue(runDetail('Preview'));
        previewRun.mockResolvedValue({ runId: RUN_ID, status: 'Preview' });
        const element = await mount();
        expect(q(element, 'lightning-button.preview').disabled).toBe(true);
        await change(q(element, '[data-field="previewRuleId"]'), RULE_ID);
        await change(q(element, '[data-field="previewPeriodId"]'), OCT);
        q(element, 'lightning-button.preview').click();
        await flush();
        await flush();
        expect(previewRun).toHaveBeenCalledWith({ ruleId: RULE_ID, periodId: OCT, requestKey: expect.stringMatching(/^G14B\|PREVIEW\|/) });
        expect(getRunDetail).toHaveBeenCalledWith({ runId: RUN_ID });
    });

    it('reuses the request key after a failed post and discards with a reason', async () => {
        getWorkspace.mockResolvedValue(workspace());
        getRunDetail.mockResolvedValue(runDetail('Approved'));
        postRun.mockRejectedValueOnce({ body: { message: 'Source balances changed since the preview' } });
        discardRun.mockResolvedValue({ status: 'Failed' });
        const element = await mount();
        await select(element, 1, { runId: RUN_ID });
        q(element, 'lightning-button.post-run').click();
        await flush();
        await flush();
        expect(q(element, '.error-banner').textContent).toContain('Source balances changed');
        q(element, 'lightning-button.post-run').click();
        await flush();
        expect(postRun.mock.calls[1][0].requestKey).toBe(postRun.mock.calls[0][0].requestKey);
        expect(q(element, 'lightning-button.discard-run').disabled).toBe(true);
        await change(q(element, '.action-panel [data-field="reason"]'), ' Late invoice ');
        q(element, 'lightning-button.discard-run').click();
        await flush();
        expect(discardRun).toHaveBeenCalledWith({ runId: RUN_ID, reason: 'Late invoice',
            requestKey: expect.stringMatching(/^G14B\|DISCARD_RUN\|/) });
    });

    it('disables actions the user has no permission for', async () => {
        getWorkspace.mockResolvedValue(workspace({ manage: false, approve: false, postJournal: false }));
        getRunDetail.mockResolvedValue(runDetail('Approved'));
        const element = await mount();
        expect(q(element, 'lightning-button.new-rule').disabled).toBe(true);
        await select(element, 1, { runId: RUN_ID });
        expect(q(element, 'lightning-button.post-run').disabled).toBe(true);
        expect(postRun).not.toHaveBeenCalled();
    });
});
