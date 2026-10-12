import { createElement } from 'lwc';
import SabFixedAssetWorkspace from 'c/sabFixedAssetWorkspace';
import getAccessibleCompanies from '@salesforce/apex/SABFixedAssetWorkspaceController.getAccessibleCompanies';
import getDashboard from '@salesforce/apex/SABFixedAssetWorkspaceController.getDashboard';
import getAssetDetail from '@salesforce/apex/SABFixedAssetWorkspaceController.getAssetDetail';

jest.mock('@salesforce/apex/SABFixedAssetWorkspaceController.getAccessibleCompanies', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFixedAssetWorkspaceController.getDashboard', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABFixedAssetWorkspaceController.getAssetDetail', () => ({ default: jest.fn() }), { virtual: true });

const DASHBOARD = {
    companyName: 'Harbourline Trading', functionalCurrency: 'AUD', bookKey: 'PRIMARY', totalAssets: 1, inServiceAssets: 1,
    grossCost: 1000, postedDepreciation: 100, postedImpairment: 0, netBookValue: 900, futurePlannedDepreciation: 900,
    reconciliationReviewCount: 0, assets: [{ assetId: 'FA1', name: 'Forklift', status: 'In Service' }]
};

async function flush() {
    for (let i = 0; i < 6; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

describe('c-sab-fixed-asset-workspace', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        window.sessionStorage.clear();
        jest.clearAllMocks();
    });

    it('renders the header while the dashboard is still loading for a stored company', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', 'a01000000000001AAA');
        let resolveDashboard;
        getDashboard.mockReturnValue(new Promise((resolve) => {
            resolveDashboard = resolve;
        }));
        const el = createElement('c-sab-fixed-asset-workspace', { is: SabFixedAssetWorkspace });
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.querySelector('.header-row')).not.toBeNull();
        expect(el.shadowRoot.querySelector('.header-row p').textContent).toContain('Book:');
        resolveDashboard(DASHBOARD);
        await flush();
        expect(el.shadowRoot.querySelector('.header-row p').textContent).toContain('PRIMARY');
        expect(getDashboard).toHaveBeenCalledWith({ companyId: 'a01000000000001AAA' });
    });

    it('renders the selected asset when its detail has no reconciliation', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', 'a01000000000001AAA');
        getDashboard.mockResolvedValue(DASHBOARD);
        getAssetDetail.mockResolvedValue({ assetId: 'FA1', name: 'Forklift', status: 'In Service', scheduleLines: [], movements: [] });
        const el = createElement('c-sab-fixed-asset-workspace', { is: SabFixedAssetWorkspace });
        document.body.appendChild(el);
        await flush();
        const table = el.shadowRoot.querySelector('lightning-datatable');
        table.dispatchEvent(new CustomEvent('rowselection', { detail: { selectedRows: [{ assetId: 'FA1' }] } }));
        await flush();
        expect(getAssetDetail).toHaveBeenCalled();
        expect(Array.from(el.shadowRoot.querySelectorAll('h3')).map((h) => h.textContent)).toContain('Forklift');
    });

    it('lists companies when none is stored', async () => {
        getAccessibleCompanies.mockResolvedValue([{ companyId: 'a01000000000001AAA', name: 'Harbourline Trading' }]);
        const el = createElement('c-sab-fixed-asset-workspace', { is: SabFixedAssetWorkspace });
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.querySelector('lightning-combobox').options).toEqual([{ label: 'Harbourline Trading', value: 'a01000000000001AAA' }]);
    });
});
