import { createElement } from 'lwc';
import SabTaxWorkspace from 'c/sabTaxWorkspace';
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

const CAN = { prepare: true, review: true, submit: true, recordOutcome: true, amend: true };
const ret = (id, status, extra = {}) => ({ taxReturnId: id, name: `BAS ${id}`, registrationName: 'GST', jurisdiction: 'AU', periodStart: '2026-07-01', periodEnd: '2026-09-30',
    returnVersion: 1, status, netTaxDue: 12410, ...extra });

function ws(overrides = {}) {
    return {
        functionalCurrency: 'AUD', capabilities: CAN,
        registrations: [{ value: 'R1', label: 'GST ABN 53', filingFrequency: 'Quarterly', effectiveFrom: '2019-03-01' },
            { value: 'R2', label: 'Old', filingFrequency: 'Monthly', effectiveFrom: '2018-01-01', effectiveTo: '2019-01-01' }],
        returns: [ret('T1', 'Prepared'), ret('T0', 'Accepted', { returnVersion: 2, netTaxDue: -50 })],
        ...overrides
    };
}

function detail(status = 'Prepared', extra = {}) {
    return {
        taxReturn: ret('T1', status, extra),
        lines: [{ lineId: 'X1', boxKey: '1A', label: 'GST on sales', calculatedAmount: 18000, adjustmentAmount: 0, finalAmount: 18000 },
            { lineId: 'X2', boxKey: '1B', label: 'GST credits', calculatedAmount: 5590, adjustmentAmount: 10, finalAmount: 5600 }],
        history: [{ action: 'Prepared', actorName: 'Alex Morgan', actionAt: '2026-10-02T02:00:00.000Z', reason: 'Q1' }]
    };
}

async function flush() {
    for (let i = 0; i < 10; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-tax-workspace', { is: SabTaxWorkspace });
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

describe('c-sab-tax-workspace', () => {
    beforeEach(() => {
        getWorkspace.mockResolvedValue(ws());
        getReturnDetail.mockResolvedValue(detail());
        [setAdjustment, reviewReturn, submitReturn, recordAuthorityOutcome, createAmendment].forEach((m) => m.mockResolvedValue({}));
        prepareReturn.mockResolvedValue({ taxReturnId: 'T5', rebuiltExistingReturn: false });
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows the return stepper, boxes, payable and history and adjusts a box', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(Array.from(root.querySelectorAll('.sab-return .hstep')).map((s) => s.className)).toEqual(['hstep done', 'hstep now', 'hstep', 'hstep']);
        expect(root.querySelector('.payable').textContent).toContain('12,410.00');
        expect(root.querySelector('.sab-history .li').textContent).toContain('Alex Morgan');
        expect(root.querySelectorAll('.sab-returns tbody tr')[0].className).toBe('click sel');
        const adjust = root.querySelectorAll('.sab-adjust')[1];
        adjust.value = '25';
        adjust.dispatchEvent(new CustomEvent('change'));
        await flush();
        expect(setAdjustment).toHaveBeenCalledWith({ taxReturnId: 'T1', boxKey: '1B', adjustmentAmount: 25 });
        adjust.value = '10';
        adjust.dispatchEvent(new CustomEvent('change'));
        await flush();
        expect(setAdjustment).toHaveBeenCalledTimes(1);
        expect(root.querySelector('.sab-next').textContent).toBe('Mark as reviewed');
        root.querySelector('.sab-next').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(reviewReturn.mock.calls[0][0]).toMatchObject({ taxReturnId: 'T1', reason: null, requestKey: expect.stringMatching(/^TAX-REVIEW-T1-/) });
    });

    it('records submission and outcome and creates an amendment', async () => {
        getReturnDetail.mockResolvedValue(detail('Reviewed', { sourceLocked: true }));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-adjust')).toBeNull();
        root.querySelector('.sab-next').click();
        await flush();
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('A filing reference is required.');
        setModal(root, 'filingReference', 'ATO-123');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(submitReturn.mock.calls[0][0]).toMatchObject({ filingReference: 'ATO-123' });

        getReturnDetail.mockResolvedValue(detail('Submitted'));
        const el2 = mount();
        await flush();
        el2.shadowRoot.querySelector('.sab-next').click();
        await flush();
        el2.shadowRoot.querySelector('.sab-modal-save').click();
        await flush();
        expect(el2.shadowRoot.querySelector('.form-error').textContent).toBe('An acknowledgement reference is required.');
        setModal(el2.shadowRoot, 'outcome', 'Rejected');
        setModal(el2.shadowRoot, 'acknowledgementReference', 'ACK-9');
        el2.shadowRoot.querySelector('.sab-modal-save').click();
        await flush();
        expect(recordAuthorityOutcome.mock.calls[0][0]).toMatchObject({ outcome: 'Rejected', acknowledgementReference: 'ACK-9' });

        getReturnDetail.mockResolvedValue(detail('Accepted'));
        createAmendment.mockResolvedValueOnce({ amendmentTaxReturnId: 'T9' });
        const el3 = mount();
        await flush();
        el3.shadowRoot.querySelector('.sab-amend').click();
        await flush();
        el3.shadowRoot.querySelector('.sab-modal-save').click();
        await flush();
        expect(el3.shadowRoot.querySelector('.form-error').textContent).toBe('A reason is required.');
        setModal(el3.shadowRoot, 'reason', 'Missed invoice');
        el3.shadowRoot.querySelector('.sab-modal-save').click();
        await flush();
        expect(createAmendment.mock.calls[0][0]).toMatchObject({ taxReturnId: 'T1', reason: 'Missed invoice' });
    });

    it('prepares a return, switches returns and lists registrations', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.sab-prepare').click();
        await flush();
        expect(root.querySelector('c-sab-modal [data-field="registrationId"]').value).toBe('R1');
        prepareReturn.mockRejectedValueOnce({ body: { message: 'No tax lines in the period.' } });
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('No tax lines in the period.');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(prepareReturn.mock.calls[1][0]).toMatchObject({ taxRegistrationId: 'R1' });
        root.querySelectorAll('.sab-returns tbody tr')[1].dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        await flush();
        expect(getReturnDetail).toHaveBeenLastCalledWith({ taxReturnId: 'T0' });
        root.querySelectorAll('.sab-returns tbody tr')[1].dispatchEvent(new KeyboardEvent('keydown', { key: 'a' }));
        root.querySelectorAll('.tab')[1].click();
        await flush();
        const regs = root.querySelectorAll('.sab-registrations tbody tr');
        expect(regs[0].textContent).toContain('Active');
        expect(regs[1].textContent).toContain('Ended');
    });

    it('handles permissions, empty and error states', async () => {
        getWorkspace.mockResolvedValue(ws({ capabilities: { prepare: false, review: false } }));
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sab-prepare').title).toBe('Bookkeeper role cannot prepare tax returns');
        expect(root.querySelector('.sab-next').title).toBe('Bookkeeper role cannot review tax returns');

        getWorkspace.mockResolvedValue(ws({ returns: [], registrations: [] }));
        const el2 = mount();
        await flush();
        expect(el2.shadowRoot.querySelector('.empty h3').textContent).toBe('No tax returns yet');
        expect(el2.shadowRoot.querySelector('.sab-prepare').title).toBe('Add a tax registration first');
        el2.shadowRoot.querySelectorAll('.tab')[1].click();
        await flush();
        expect(el2.shadowRoot.querySelector('.panel-b.muted').textContent).toBe('No tax registrations for this company.');

        getWorkspace.mockResolvedValue(ws());
        getReturnDetail.mockRejectedValueOnce({ body: { message: 'Return not accessible.' } });
        const el3 = mount();
        await flush();
        expect(el3.shadowRoot.querySelector('.banner.t-bad').textContent).toBe('Return not accessible.');
        el3.recordId = 'T0';
        await flush();

        getWorkspace.mockRejectedValueOnce({ body: { message: 'Tax return permission is required.' } });
        const el4 = mount();
        await flush();
        expect(el4.shadowRoot.querySelector('.empty p').textContent).toBe('Tax return permission is required.');
        el4.shadowRoot.querySelector('.empty .btn').click();
        await flush();
        el4.shadowRoot.querySelector('.sab-prepare').click();
        await flush();
        el4.shadowRoot.querySelector('.sab-modal-close').click();
    });
});
