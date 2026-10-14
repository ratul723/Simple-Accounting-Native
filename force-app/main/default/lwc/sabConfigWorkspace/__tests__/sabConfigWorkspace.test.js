import { createElement } from 'lwc';
import SabConfigWorkspace from 'c/sabConfigWorkspace';
import getConfiguration from '@salesforce/apex/SABAdminWorkspaceController.getConfiguration';
import searchUsers from '@salesforce/apex/SABAdminWorkspaceController.searchUsers';
import saveFeature from '@salesforce/apex/SABSetupRecordService.saveFeature';
import saveGrant from '@salesforce/apex/SABAdminWorkspaceService.saveGrant';

jest.mock('@salesforce/apex/SABAdminWorkspaceController.getConfiguration', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAdminWorkspaceController.searchUsers', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSetupRecordService.saveFeature', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAdminWorkspaceService.saveGrant', () => ({ default: jest.fn() }), { virtual: true });

function config(overrides = {}) {
    return {
        canManageSetup: true, canManageAccess: true, roles: ['Bookkeeper', 'Finance Manager', 'Auditor'],
        features: [
            { featureKey: 'PROJECTS', enabled: false, configurationStatus: 'Not Configured' },
            { featureId: 'F1', featureKey: 'PAYROLL', enabled: true, configurationStatus: 'Valid' },
            { featureKey: 'CUSTOM_THING', enabled: true, configurationStatus: 'Blocked' }
        ],
        grants: [
            { grantId: 'G1', userId: 'U1', userName: 'Alex Morgan', role: 'Finance Manager', effectiveFrom: '2026-01-01', approvalLimit: null, active: true },
            { grantId: 'G2', userId: 'U2', userName: 'Sam Lee', role: 'Auditor', effectiveFrom: '2026-01-01', effectiveTo: '2026-06-30', approvalLimit: 5000, active: false }
        ],
        approvals: [{ sourceType: 'Supplier_Bill__c', pending: 2, approved: 10, rejected: 1, other: 0 }, { sourceType: 'Invoice__c', pending: 0, approved: 3, rejected: 0, other: 1 }],
        checks: [{ title: 'Core setup is ready', detail: 'All good.', status: 'Pass' }, { title: 'Cash flow categories', detail: '3 accounts', status: 'Warning' },
            { title: 'Core setup', detail: 'No open period.', status: 'Fail' }],
        runs: [{ runId: 'R1', name: 'PR-0001', runType: 'Recurring Journals', startedAt: '2026-10-01T02:00:00.000Z', completedAt: '2026-10-01T02:01:05.000Z', processed: 12,
            failures: 1, retries: 2, status: 'Complete' }, { runId: 'R2', name: 'PR-0002', runType: 'Integration Retry', startedAt: null, status: 'Queued' }],
        ...overrides
    };
}

async function flush() {
    for (let i = 0; i < 8; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-config-workspace', { is: SabConfigWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', persona: { label: 'Bookkeeper' }, ...props });
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

function set(root, field, value) {
    const input = root.querySelector(`c-sab-modal [data-field="${field}"]`);
    if (input.type === 'checkbox') {
        input.checked = value;
        input.dispatchEvent(new CustomEvent('change'));
        return;
    }
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-config-workspace', () => {
    beforeEach(() => {
        getConfiguration.mockResolvedValue(config());
        searchUsers.mockResolvedValue([{ value: 'U9', label: 'Jordan Smith (jordan@example.com)' }]);
        saveFeature.mockResolvedValue('F2');
        saveGrant.mockResolvedValue('G9');
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows feature cards and toggles a feature', async () => {
        saveFeature.mockRejectedValueOnce({ body: { message: 'You do not have permission to manage company setup.' } });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        const cards = root.querySelectorAll('.sab-feature');
        expect(Array.from(cards).map((c) => c.querySelector('h4').textContent)).toEqual(['Custom thing', 'Payroll', 'Projects']);
        expect(cards[2].querySelector('.switch').getAttribute('aria-checked')).toBe('false');
        expect(cards[2].textContent).toContain('Off');
        cards[2].querySelector('.switch').click();
        await flush();
        expect(toast.mock.calls[0][0].detail.tone).toBe('bad');
        cards[2].querySelector('.switch').click();
        await flush();
        expect(saveFeature.mock.calls[1][0].request).toMatchObject({ featureId: null, featureKey: 'PROJECTS', enabled: true });
        expect(toast.mock.calls[1][0].detail.message).toBe('Projects turned on');
        root.querySelectorAll('.sab-feature')[1].querySelector('.switch').click();
        await flush();
        expect(saveFeature.mock.calls[2][0].request).toMatchObject({ featureId: 'F1', enabled: false });
    });

    it('grants access to a found user and edits a grant', async () => {
        saveGrant.mockRejectedValueOnce({ body: { message: 'This user already has an active grant. Edit that grant instead.' } });
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[1].click();
        await flush();
        const rows = root.querySelectorAll('.sab-grants tbody tr');
        expect(rows[0].textContent).toContain('No limit');
        expect(rows[1].textContent).toContain('to 30 Jun 2026');
        expect(rows[1].textContent).toContain('Inactive');
        root.querySelector('.sab-new-grant').click();
        await flush();
        const search = root.querySelector('.sab-user-search');
        search.value = 'J';
        search.dispatchEvent(new CustomEvent('input'));
        await flush();
        expect(searchUsers).not.toHaveBeenCalled();
        search.value = 'Jor';
        search.dispatchEvent(new CustomEvent('input'));
        await flush();
        expect(root.querySelector('.sab-user').value).toBe('U9');
        set(root, 'role', 'Auditor');
        set(root, 'approvalLimit', '2500');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toContain('already has an active grant');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(saveGrant.mock.calls[1][0].request).toMatchObject({ grantId: null, userId: 'U9', role: 'Auditor', approvalLimit: 2500, active: true });
        root.querySelectorAll('.sab-grants tbody tr')[1].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        expect(root.querySelector('c-sab-modal').heading).toBe('Edit access for Sam Lee');
        expect(root.querySelector('.sab-user-search')).toBeNull();
        set(root, 'active', true);
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(saveGrant.mock.calls[2][0].request).toMatchObject({ grantId: 'G2', role: 'Auditor', approvalLimit: 5000, active: true });
        root.querySelectorAll('.sab-grants tbody tr')[1].dispatchEvent(new KeyboardEvent('keydown', { key: 'x' }));
    });

    it('shows approval activity, checks and diagnostics', async () => {
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelectorAll('.tab')[2].click();
        await flush();
        const approvals = root.querySelectorAll('.sab-approvals tbody tr');
        expect(approvals[0].textContent).toBe('Invoice0301');
        expect(approvals[1].textContent).toBe('Supplier bill21010');
        root.querySelectorAll('.tab')[3].click();
        await flush();
        expect(root.querySelector('.panel-h .sub').textContent).toBe('1 passed, 1 warnings, 1 failed');
        expect(root.querySelectorAll('.sab-checks .li')[2].querySelector('.ic').className).toBe('ic t-bad');
        root.querySelector('.sab-run-checks').click();
        await flush();
        expect(getConfiguration).toHaveBeenCalledTimes(2);
        expect(toast.mock.calls[0][0].detail.message).toBe('Configuration checks completed');
        root.querySelectorAll('.tab')[4].click();
        await flush();
        const runs = root.querySelectorAll('.sab-runs tbody tr');
        expect(runs[0].textContent).toContain('1m 5s');
        expect(runs[0].textContent).toContain('1 failed, 2 retries');
        expect(runs[1].textContent).toContain('\u2014');
    });

    it('handles permissions, empty lists and errors', async () => {
        getConfiguration.mockResolvedValueOnce(config({ canManageSetup: false, canManageAccess: false, approvals: [], runs: [] }));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-feature .switch').disabled).toBe(true);
        root.querySelectorAll('.tab')[1].click();
        await flush();
        expect(root.querySelector('.sab-new-grant').title).toBe('Bookkeeper role cannot grant access');
        root.querySelector('.sab-grants tbody tr').click();
        await flush();
        expect(root.querySelector('c-sab-modal').open).toBe(false);
        root.querySelectorAll('.tab')[2].click();
        await flush();
        expect(root.querySelector('.panel-b.muted').textContent).toBe('No approval requests yet.');
        root.querySelectorAll('.tab')[4].click();
        await flush();
        expect(root.querySelector('.panel-b.muted').textContent).toBe('No processing runs yet.');

        getConfiguration.mockRejectedValueOnce({ body: { message: 'You do not have active access to this Accounting Company.' } });
        searchUsers.mockRejectedValueOnce({ body: { message: 'Search failed.' } });
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have active access to this Accounting Company.');
        el2.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        el2.shadowRoot.querySelectorAll('.tab')[1].click();
        await flush();
        el2.shadowRoot.querySelector('.sab-new-grant').click();
        await flush();
        const search = el2.shadowRoot.querySelector('.sab-user-search');
        search.value = 'Jor';
        search.dispatchEvent(new CustomEvent('input'));
        await flush();
        expect(el2.shadowRoot.querySelector('.form-error').textContent).toBe('Search failed.');
        el2.shadowRoot.querySelector('.sab-modal-close').click();
    });

    it('asks the shell to refresh after a feature or access change', async () => {
        const el = mount();
        await flush();
        const refresh = jest.fn();
        el.addEventListener('sabrefreshshell', refresh);
        const root = el.shadowRoot;
        expect(root.querySelectorAll('.sab-feature')[2].querySelector('.note').textContent).toContain('Off: hidden from navigation.');
        root.querySelectorAll('.sab-feature')[1].querySelector('.switch').click();
        await flush();
        expect(refresh).toHaveBeenCalledTimes(1);
        root.querySelectorAll('.tab')[1].click();
        await flush();
        root.querySelector('.sab-grants tbody tr').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(refresh).toHaveBeenCalledTimes(2);
    });
});
