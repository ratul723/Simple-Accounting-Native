import { createElement } from 'lwc';
import SabSampleLoader from 'c/sabSampleLoader';
import startSampleCompany from '@salesforce/apex/SABSampleCompanyService.startSampleCompany';
import getStatus from '@salesforce/apex/SABSampleCompanyService.getStatus';

jest.mock('@salesforce/apex/SABSampleCompanyService.startSampleCompany', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABSampleCompanyService.getStatus', () => ({ default: jest.fn() }), { virtual: true });

const STEPS = ['Opening balances', 'Trading two months ago', 'Trading last month', 'Trading this month', 'Overdue invoice', 'Current invoice', 'Work to do'];
const status = (done, state, failures = 0, lastMessage = '') => ({ runId: 'R1', companyId: 'CO1', status: state, stepsDone: done, stepsTotal: 7, failures, lastMessage, steps: STEPS });

async function flush() {
    for (let i = 0; i < 8; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount() {
    const el = createElement('c-sab-sample-loader', { is: SabSampleLoader });
    document.body.appendChild(el);
    el.open = true;
    return el;
}

describe('c-sab-sample-loader', () => {
    beforeEach(() => {
        jest.useFakeTimers();
        startSampleCompany.mockResolvedValue({ companyId: 'CO1', runId: 'R1', companyName: 'Harbourline Trading (sample 123456)' });
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        jest.useRealTimers();
    });

    it('explains the sample, starts it and follows the steps until done', async () => {
        getStatus.mockResolvedValueOnce(status(0, 'Queued')).mockResolvedValueOnce(status(3, 'Running')).mockResolvedValueOnce(status(7, 'Complete'));
        const el = mount();
        const loaded = jest.fn();
        el.addEventListener('loaded', loaded);
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelectorAll('.what li').length).toBe(4);
        root.querySelector('.sab-sample-start').click();
        await flush();
        expect(startSampleCompany.mock.calls[0][0].requestKey).toMatch(/^SAMPLE-company-/);
        expect(root.querySelector('c-sab-modal').subheading).toBe('Harbourline Trading (sample 123456)');
        expect(root.querySelector('.summary').textContent).toBe('0 of 7 steps done');
        expect(root.querySelectorAll('.step')[0].className).toBe('step now');
        expect(root.querySelector('.sab-sample-open').textContent).toBe('Open now');
        jest.advanceTimersByTime(2000);
        await flush();
        expect(Array.from(root.querySelectorAll('.step')).map((s) => s.className).slice(2, 4)).toEqual(['step done', 'step now']);
        jest.advanceTimersByTime(2000);
        await flush();
        expect(root.querySelector('c-sab-modal').heading).toBe('Sample company ready');
        expect(root.querySelector('.summary').textContent).toBe('Every step finished');
        expect(getStatus).toHaveBeenCalledTimes(3);
        jest.advanceTimersByTime(4000);
        expect(getStatus).toHaveBeenCalledTimes(3);
        root.querySelector('.sab-sample-open').click();
        expect(loaded.mock.calls[0][0].detail).toEqual({ recordId: 'CO1' });
    });

    it('lists skipped steps, shows errors and closes', async () => {
        getStatus.mockResolvedValueOnce(status(7, 'Complete', 2, 'Work to do: You do not have permission to submit supplier bills.'));
        const el = mount();
        const closed = jest.fn();
        el.addEventListener('close', closed);
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.sab-sample-start').click();
        await flush();
        expect(root.querySelector('.summary').textContent).toBe('5 of 7 steps done, 2 could not run with your permissions');
        expect(root.querySelector('.banner.t-warn').textContent).toContain('You do not have permission to submit supplier bills.');
        root.querySelector('.sab-sample-close').click();
        expect(closed).toHaveBeenCalled();
        el.open = false;

        startSampleCompany.mockRejectedValueOnce({ body: { message: 'You do not have permission to create Accounting Companies.' } });
        const el2 = mount();
        await flush();
        el2.shadowRoot.querySelector('.sab-sample-start').click();
        await flush();
        expect(el2.shadowRoot.querySelector('.form-error').textContent).toBe('You do not have permission to create Accounting Companies.');
        expect(el2.shadowRoot.querySelector('.sab-sample-start')).not.toBeNull();

        getStatus.mockRejectedValueOnce({ body: { message: 'The sample load was not found.' } });
        const el3 = mount();
        await flush();
        el3.shadowRoot.querySelector('.sab-sample-start').click();
        await flush();
        expect(el3.shadowRoot.querySelector('.form-error').textContent).toBe('The sample load was not found.');
        document.body.removeChild(el3);
    });
});
