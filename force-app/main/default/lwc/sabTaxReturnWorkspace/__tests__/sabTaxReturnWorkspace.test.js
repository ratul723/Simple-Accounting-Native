import { createElement } from 'lwc';
import SabTaxReturnWorkspace from 'c/sabTaxReturnWorkspace';
import getWorkspace from '@salesforce/apex/SABTaxReturnWorkspaceController.getWorkspace';
import getReturnDetail from '@salesforce/apex/SABTaxReturnWorkspaceController.getReturnDetail';
import prepareReturn from '@salesforce/apex/SABTaxReturnWorkspaceController.prepareReturn';
import setAdjustment from '@salesforce/apex/SABTaxReturnWorkspaceController.setAdjustment';
import reviewReturn from '@salesforce/apex/SABTaxReturnLifecycleService.reviewReturn';
import submitReturn from '@salesforce/apex/SABTaxReturnLifecycleService.submitReturn';
import recordAuthorityOutcome from '@salesforce/apex/SABTaxReturnLifecycleService.recordAuthorityOutcome';
import createAmendment from '@salesforce/apex/SABTaxReturnLifecycleService.createAmendment';

jest.mock('@salesforce/apex/SABTaxReturnWorkspaceController.getWorkspace', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABTaxReturnWorkspaceController.getReturnDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABTaxReturnWorkspaceController.prepareReturn', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABTaxReturnWorkspaceController.setAdjustment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABTaxReturnLifecycleService.reviewReturn', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABTaxReturnLifecycleService.submitReturn', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABTaxReturnLifecycleService.recordAuthorityOutcome', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABTaxReturnLifecycleService.createAmendment', () => ({ default: jest.fn() }), { virtual: true });

const COMPANY_ID = 'a00000000000001AAA';
const REGISTRATION_ID = 'a07000000000001AAA';
const RETURN_ID = 'a08000000000001AAA';
const AMENDMENT_ID = 'a08000000000002AAA';

function capabilities(overrides) {
    return { prepare: true, review: true, submit: true, recordOutcome: true, amend: true, viewAudit: true, ...overrides };
}

function workspace(status, caps) {
    return {
        companyId: COMPANY_ID, companyName: 'Harbourline Trading', functionalCurrency: 'BDT', capabilities: capabilities(caps),
        registrations: [{ label: 'BD VAT (BD 123)', value: REGISTRATION_ID, filingFrequency: 'Monthly' }],
        returns: [{ taxReturnId: RETURN_ID, name: 'TR-0001', registrationName: 'BD VAT', periodStart: '2026-09-01',
            periodEnd: '2026-09-30', returnVersion: 1, status, netTaxDue: 9 }],
        stateCounts: [{ state: status, count: 1 }], openNetTaxDue: 9, filingReferenceMaxLength: 120, acknowledgementMaxLength: 120
    };
}

function detail(status) {
    return {
        taxReturn: { taxReturnId: RETURN_ID, name: 'TR-0001', status, returnVersion: 1, registrationName: 'BD VAT',
            periodStart: '2026-09-01', periodEnd: '2026-09-30', countryPackVersion: 'GENERIC-1', sourceLocked: status !== 'Prepared' },
        lines: [{ lineId: 'a09000000000001AAA', boxKey: 'OUTPUT_TAX', label: 'Output Tax', calculatedAmount: 15, adjustmentAmount: 0,
            finalAmount: 15 }],
        versions: [{ taxReturnId: RETURN_ID, name: 'TR-0001', returnVersion: 1, status }],
        history: [{ action: 'TAX_RETURN_REVIEWED', actorName: 'Reviewer', actionAt: '2026-10-01T10:00:00.000Z' },
            { action: 'TAX_RETURN_SUBMITTED', actorName: 'Reviewer', actionAt: '2026-10-01T10:00:00.000Z' }]
    };
}

// Test-only: let every pending Apex promise and re-render settle.
// eslint-disable-next-line @lwc/lwc/no-async-operation
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

async function mount() {
    const element = createElement('c-sab-tax-return-workspace', { is: SabTaxReturnWorkspace });
    document.body.appendChild(element);
    await flush();
    await flush();
    return element;
}

async function selectReturn(element) {
    const table = element.shadowRoot.querySelector('lightning-datatable');
    table.dispatchEvent(new CustomEvent('rowselection', { detail: { selectedRows: [{ taxReturnId: RETURN_ID }] } }));
    await flush();
    await flush();
}

function field(element, name) {
    return element.shadowRoot.querySelector(`[data-field="${name}"]`);
}

async function setField(element, name, value) {
    field(element, name).dispatchEvent(new CustomEvent('change', { detail: { value } }));
    await flush();
}

function button(element, cssClass) {
    return element.shadowRoot.querySelector(`lightning-button.${cssClass}`);
}

describe('c-sab-tax-return-workspace', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        window.sessionStorage.clear();
        jest.clearAllMocks();
    });

    it('asks for a company when none is selected', async () => {
        const element = await mount();
        expect(element.shadowRoot.querySelector('.empty-state').textContent).toContain('Select an Accounting Company');
        expect(getWorkspace).not.toHaveBeenCalled();
    });

    it('loads returns for the stored company and defaults the registration', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANY_ID);
        getWorkspace.mockResolvedValue(workspace('Prepared'));
        const element = await mount();
        expect(getWorkspace).toHaveBeenCalledWith({ companyId: COMPANY_ID });
        expect(element.shadowRoot.querySelector('.company-name').textContent).toBe('Harbourline Trading');
        expect(field(element, 'registrationId').value).toBe(REGISTRATION_ID);
        expect(element.shadowRoot.querySelector('lightning-datatable').data).toHaveLength(1);
    });

    it('prepares a return for the selected registration and period, then opens it', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANY_ID);
        getWorkspace.mockResolvedValue(workspace('Prepared'));
        getReturnDetail.mockResolvedValue(detail('Prepared'));
        prepareReturn.mockResolvedValue({ taxReturnId: RETURN_ID, rebuiltExistingReturn: false });
        const element = await mount();
        await setField(element, 'periodStart', '2026-09-01');
        await setField(element, 'periodEnd', '2026-09-30');
        button(element, 'prepare').click();
        await flush();
        await flush();
        expect(prepareReturn).toHaveBeenCalledWith({ taxRegistrationId: REGISTRATION_ID, periodStart: '2026-09-01',
            periodEnd: '2026-09-30' });
        expect(getReturnDetail).toHaveBeenCalledWith({ taxReturnId: RETURN_ID });
    });

    it('offers adjustment and review for a Prepared return', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANY_ID);
        getWorkspace.mockResolvedValue(workspace('Prepared'));
        getReturnDetail.mockResolvedValue(detail('Prepared'));
        setAdjustment.mockResolvedValue({});
        reviewReturn.mockResolvedValue({ status: 'Reviewed' });
        const element = await mount();
        await selectReturn(element);
        await setField(element, 'adjustmentBox', 'OUTPUT_TAX');
        await setField(element, 'adjustmentAmount', '2.5');
        button(element, 'adjust').click();
        await flush();
        expect(setAdjustment).toHaveBeenCalledWith({ taxReturnId: RETURN_ID, boxKey: 'OUTPUT_TAX', adjustmentAmount: 2.5 });
        await flush();
        await setField(element, 'reason', 'Checked against ledger');
        button(element, 'review').click();
        await flush();
        expect(reviewReturn).toHaveBeenCalledWith({ taxReturnId: RETURN_ID, reason: 'Checked against ledger',
            requestKey: expect.stringMatching(/^G11\|REVIEW\|a08000000000001AAA\|/) });
        expect(button(element, 'submit')).toBeNull();
    });

    it('reuses the request key after a failed submit and requires a filing reference', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANY_ID);
        getWorkspace.mockResolvedValue(workspace('Reviewed'));
        getReturnDetail.mockResolvedValue(detail('Reviewed'));
        submitReturn.mockRejectedValueOnce({ body: { message: 'Source hash changed' } }).mockResolvedValue({ status: 'Submitted' });
        const element = await mount();
        await selectReturn(element);
        expect(button(element, 'submit').disabled).toBe(true);
        await setField(element, 'filingReference', ' NBR-2026-09 ');
        button(element, 'submit').click();
        await flush();
        await flush();
        expect(element.shadowRoot.querySelector('.error-banner').textContent).toBe('Source hash changed');
        button(element, 'submit').click();
        await flush();
        expect(submitReturn.mock.calls[1][0].requestKey).toBe(submitReturn.mock.calls[0][0].requestKey);
        expect(submitReturn.mock.calls[0][0].filingReference).toBe('NBR-2026-09');
    });

    it('records the authority outcome and gates it by permission', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANY_ID);
        getWorkspace.mockResolvedValue(workspace('Submitted', { recordOutcome: false }));
        getReturnDetail.mockResolvedValue(detail('Submitted'));
        const element = await mount();
        await selectReturn(element);
        await setField(element, 'outcome', 'Accepted');
        await setField(element, 'acknowledgementReference', 'ACK-1');
        expect(button(element, 'outcome').disabled).toBe(true);
        expect(recordAuthorityOutcome).not.toHaveBeenCalled();
    });

    it('creates an amendment and opens the new version', async () => {
        window.sessionStorage.setItem('sabSelectedAccountingCompanyId', COMPANY_ID);
        getWorkspace.mockResolvedValue(workspace('Rejected'));
        getReturnDetail.mockResolvedValue(detail('Rejected'));
        createAmendment.mockResolvedValue({ amendmentTaxReturnId: AMENDMENT_ID });
        const element = await mount();
        await selectReturn(element);
        expect(element.shadowRoot.querySelectorAll('lightning-datatable')).toHaveLength(3);
        expect(button(element, 'amend').disabled).toBe(true);
        await setField(element, 'reason', ' Correct output tax ');
        button(element, 'amend').click();
        await flush();
        await flush();
        expect(createAmendment).toHaveBeenCalledWith({ taxReturnId: RETURN_ID, reason: 'Correct output tax',
            requestKey: expect.stringMatching(/^G11\|AMEND\|/) });
        expect(getReturnDetail).toHaveBeenLastCalledWith({ taxReturnId: AMENDMENT_ID });
    });
});
