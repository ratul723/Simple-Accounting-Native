import { createElement } from 'lwc';
import SabAssetsWorkspace from 'c/sabAssetsWorkspace';
import getDashboard from '@salesforce/apex/SABFixedAssetWorkspaceController.getDashboard';
import getAssetDetail from '@salesforce/apex/SABFixedAssetWorkspaceController.getAssetDetail';
import getOptions from '@salesforce/apex/SABFixedAssetOptionsController.getOptions';
import registerAsset from '@salesforce/apex/SABFixedAssetRegisterService.registerAsset';
import generateSchedule from '@salesforce/apex/SABFixedAssetScheduleService.generateSchedule';
import postDepreciation from '@salesforce/apex/SABFixedAssetDepreciationPostingService.postDepreciation';
import transferAsset from '@salesforce/apex/SABFixedAssetMovementService.transferAsset';
import recordImpairment from '@salesforce/apex/SABFixedAssetMovementService.recordImpairment';
import disposeAsset from '@salesforce/apex/SABFixedAssetMovementService.disposeAsset';

jest.mock('@salesforce/apex/SABFixedAssetWorkspaceController.getDashboard', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFixedAssetWorkspaceController.getAssetDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFixedAssetOptionsController.getOptions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFixedAssetRegisterService.registerAsset', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFixedAssetScheduleService.generateSchedule', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFixedAssetDepreciationPostingService.postDepreciation', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFixedAssetMovementService.transferAsset', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFixedAssetMovementService.recordImpairment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFixedAssetMovementService.disposeAsset', () => ({ default: jest.fn() }), { virtual: true });

const DASH = {
    functionalCurrency: 'AUD', netBookValue: 68000, futurePlannedDepreciation: 40000, reconciliationReviewCount: 1,
    assets: [
        { assetId: 'A1', name: 'Forklift', assetTag: 'FA-0001', categoryName: 'Equipment', status: 'In Service', inServiceDate: '2026-01-01', cost: 60000,
            postedDepreciation: 12000, netBookValue: 48000, futurePlannedDepreciation: 30000, reconciliationStatus: 'Review' },
        { assetId: 'A2', name: 'Van', companyAssetKey: 'FA-0002', categoryName: 'Vehicles', status: 'Impaired', cost: 30000, postedDepreciation: 5000,
            netBookValue: 20000, futurePlannedDepreciation: 10000, reconciliationStatus: 'Balanced' },
        { assetId: 'A3', name: 'Shelving', assetTag: 'FA-0003', categoryName: 'Equipment', status: 'Planned', cost: 5000, postedDepreciation: 0, netBookValue: 5000,
            futurePlannedDepreciation: 0 }
    ]
};

const OPTIONS = { canRegister: true, canSchedule: true, canMove: true, canPostDepreciation: true,
    categories: [{ value: 'C1', label: 'Equipment', defaultLifeMonths: 60 }, { value: 'C2', label: 'Vehicles', defaultLifeMonths: 48 }],
    bankAccounts: [{ value: 'B1', label: 'Operating' }], departments: [{ value: 'D1', label: 'Operations' }], costCenters: [{ value: 'K1', label: 'CC-1' }] };

const DETAIL = {
    assetId: 'A1', name: 'Forklift', assetTag: 'FA-0001', categoryName: 'Equipment', status: 'In Service', acquisitionDate: '2026-01-01', inServiceDate: '2026-01-01',
    cost: 60000, residualValue: 0, usefulLifeMonths: 60, depreciationMethod: 'Straight Line', location: 'Warehouse',
    scheduleLines: [
        { lineId: 'L2', periodName: '2026-02', scheduledDate: '2026-02-28', plannedDepreciation: 1000, status: 'Planned' },
        { lineId: 'L1', periodName: '2026-01', scheduledDate: '2026-01-31', plannedDepreciation: 1000, status: 'Posted' },
        { lineId: 'L3', periodName: '2099-01', scheduledDate: '2099-01-31', plannedDepreciation: 1000, status: 'Planned' }
    ],
    movements: [{ movementId: 'M1', movementType: 'Transfer', movementDate: '2026-03-01', amount: 0, reason: 'To warehouse' }],
    reconciliation: { postedDepreciation: 1000, netBookValue: 59000, issues: ['Overdue planned depreciation'] }
};

async function flush() {
    for (let i = 0; i < 10; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-assets-workspace', { is: SabAssetsWorkspace });
    Object.assign(el, { companyName: 'Harbourline Trading', persona: { label: 'Bookkeeper' }, ...props });
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

function setModal(root, field, value) {
    const input = root.querySelector(`c-sab-modal [data-field="${field}"]`);
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-assets-workspace', () => {
    beforeEach(() => {
        getDashboard.mockResolvedValue(DASH);
        getOptions.mockResolvedValue(OPTIONS);
        getAssetDetail.mockResolvedValue(DETAIL);
        [registerAsset, generateSchedule, postDepreciation, transferAsset, recordImpairment, disposeAsset].forEach((m) => m.mockResolvedValue({}));
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows figures, review banner, register and depreciation tabs', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(Array.from(root.querySelectorAll('.fig .v')).map((v) => v.textContent)).toEqual(['90,000AUD', '17,000AUD', '68,000AUD', '40,000AUD']);
        expect(root.querySelectorAll('.fig .s')[1].textContent).toBe('19% of cost');
        expect(root.querySelector('.banner.t-warn').textContent).toContain('1 asset need');
        const rows = root.querySelectorAll('.sab-register-table tbody tr');
        expect(rows.length).toBe(3);
        expect(rows[0].textContent).toContain('Review');
        expect(rows[1].textContent).toContain('FA-0002');
        expect(root.querySelector('.sab-register-table tfoot').textContent).toBe('In service90,000.00(17,000.00)68,000.00');
        root.querySelectorAll('.tab')[1].click();
        await flush();
        expect(root.querySelectorAll('.sab-depreciation-table tbody tr').length).toBe(2);
        expect(root.querySelector('.sab-depreciation-table tbody tr').textContent).toContain('18,000.00');
    });

    it('opens an asset with chart, schedule, movements and posts the next line', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.sab-register-table tbody tr').dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        const drawer = root.querySelector('c-sab-drawer');
        expect(drawer.heading).toBe('FA-0001');
        expect(drawer.subheading).toBe('Forklift, Equipment, In Service');
        expect(root.querySelector('c-sab-line-chart').series[0].values).toEqual([59000, 58000, 57000]);
        expect(root.querySelector('c-sab-drawer .banner').textContent).toContain('Overdue planned depreciation');
        const schedule = root.querySelectorAll('.sab-schedule tbody tr');
        expect(schedule[0].textContent).toContain('2026-01');
        expect(root.querySelectorAll('.sab-post-line').length).toBe(1);
        root.querySelector('.sab-post-line').click();
        await flush();
        expect(postDepreciation.mock.calls[0][0].request).toMatchObject({ scheduleLineId: 'L2', requestKey: expect.stringMatching(/^FA-DEPN-L2-/) });
        expect(root.querySelector('.sab-movements tbody tr').textContent).toContain('To warehouse');
        root.querySelector('.sab-register-table tbody tr').dispatchEvent(new KeyboardEvent('keydown', { key: 'a' }));
    });

    it('generates a schedule and records movements', async () => {
        getAssetDetail.mockResolvedValue({ ...DETAIL, scheduleLines: [], movements: [], reconciliation: {} });
        transferAsset.mockRejectedValueOnce({ body: { message: 'Department is inactive.' } });
        const el = mount();
        await flush();
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        const root = el.shadowRoot;
        root.querySelector('.sab-register-table tbody tr').click();
        await flush();
        root.querySelector('.sab-generate').click();
        await flush();
        expect(generateSchedule).toHaveBeenCalledWith({ request: { fixedAssetId: 'A1', bookKey: 'PRIMARY' } });
        root.querySelector('.sab-transfer').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('A reason is required.');
        setModal(root, 'toLocation', 'Yard');
        setModal(root, 'toDepartmentId', 'D1');
        setModal(root, 'reason', 'Moved to yard');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(toast.mock.calls[1][0].detail.tone).toBe('bad');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(transferAsset.mock.calls[1][0].request).toMatchObject({ fixedAssetId: 'A1', bookKey: 'PRIMARY', toLocation: 'Yard', toDepartmentId: 'D1', reason: 'Moved to yard' });
        expect(transferAsset.mock.calls[1][0].request.movementKey).toBe(transferAsset.mock.calls[0][0].request.movementKey);
        root.querySelector('.sab-impair').click();
        await flush();
        setModal(root, 'impairmentAmount', '500');
        setModal(root, 'reason', 'Damage');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(recordImpairment.mock.calls[0][0].request).toMatchObject({ impairmentAmount: 500, reason: 'Damage' });
        root.querySelector('.sab-dispose').click();
        await flush();
        setModal(root, 'proceeds', '4500');
        setModal(root, 'bankAccountId', 'B1');
        setModal(root, 'reason', 'Sold');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(disposeAsset.mock.calls[0][0].request).toMatchObject({ proceeds: 4500, bankAccountId: 'B1', reason: 'Sold' });
    });

    it('registers an asset with category defaults', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.sab-register').click();
        await flush();
        expect(root.querySelector('c-sab-modal [data-field="usefulLifeMonths"]').value).toBe('60');
        setModal(root, 'assetCategoryId', 'C2');
        await flush();
        expect(root.querySelector('c-sab-modal [data-field="usefulLifeMonths"]').value).toBe('48');
        setModal(root, 'assetName', 'Truck');
        setModal(root, 'companyAssetKey', 'FA-0014');
        setModal(root, 'functionalCurrencyCost', '80000');
        setModal(root, 'initialStatus', 'Planned');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(registerAsset.mock.calls[0][0].request).toMatchObject({ assetName: 'Truck', companyAssetKey: 'FA-0014', assetCategoryId: 'C2', functionalCurrencyCost: 80000,
            usefulLifeMonths: 48, initialStatus: 'Planned', inServiceDate: null });
        root.querySelector('.sab-register').click();
        await flush();
        root.querySelector('.sab-modal-close').click();
        await flush();
        expect(root.querySelector('c-sab-modal').open).toBe(false);
    });

    it('respects permissions and handles empty and error states', async () => {
        getOptions.mockResolvedValue({ ...OPTIONS, canRegister: false, canMove: false, canPostDepreciation: false });
        getAssetDetail.mockRejectedValueOnce({ body: { message: 'Asset not found.' } });
        const el = mount();
        el.recordId = 'A1';
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-register').title).toBe('Bookkeeper role cannot register assets');
        expect(root.querySelector('c-sab-drawer .banner').textContent).toBe('Asset not found.');
        root.querySelector('.sab-register-table tbody tr').click();
        await flush();
        expect(root.querySelector('.sab-post-line').title).toBe('Bookkeeper role cannot post depreciation');
        expect(root.querySelector('.sab-dispose').title).toBe('Bookkeeper role cannot record asset movements');
        root.querySelector('c-sab-drawer').dispatchEvent(new CustomEvent('close'));
        await flush();

        getDashboard.mockResolvedValueOnce({ ...DASH, assets: [], reconciliationReviewCount: 0 });
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty h3').textContent).toBe('No assets yet');
        el2.shadowRoot.querySelectorAll('.tab')[1].click();
        await flush();
        expect(el2.shadowRoot.querySelector('.panel-b.muted').textContent).toContain('No planned depreciation');

        getDashboard.mockRejectedValueOnce({ body: { message: 'You do not have permission to view Fixed Assets.' } });
        const el3 = mount();
        await flush();
        expect(el3.shadowRoot.querySelector('.empty p').textContent).toBe('You do not have permission to view Fixed Assets.');
        el3.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        expect(el3.shadowRoot.querySelector('.figs')).not.toBeNull();
    });
});
