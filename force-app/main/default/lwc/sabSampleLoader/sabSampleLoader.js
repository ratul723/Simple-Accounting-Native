import { LightningElement, api } from 'lwc';
import startSampleCompany from '@salesforce/apex/SABSampleCompanyService.startSampleCompany';
import getStatus from '@salesforce/apex/SABSampleCompanyService.getStatus';
import { reduceError, newKey } from 'c/sabMoneyShared';

const POLL_MS = 2000;

/**
 * "Load sample company" (G22H): starts SABSampleCompanyService, follows its steps with a short poll and offers to open
 * the company when the load finishes. Fires "loaded" (detail.recordId) and "close".
 */
export default class SabSampleLoader extends LightningElement {
    result;
    status;
    errorMessage;
    starting = false;
    isOpen = false;
    timer;
    requestKey;

    @api
    get open() {
        return this.isOpen;
    }
    set open(value) {
        const next = value === true || value === 'true';
        const opening = next && !this.isOpen;
        this.isOpen = next;
        if (opening) {
            this.result = undefined;
            this.status = undefined;
            this.errorMessage = undefined;
            this.requestKey = newKey('SAMPLE', 'company');
        }
        if (!next) {
            this.stopPolling();
        }
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    get notStarted() {
        return !this.result && !this.starting;
    }

    async handleStart() {
        this.starting = true;
        this.errorMessage = undefined;
        try {
            this.result = await startSampleCompany({ requestKey: this.requestKey });
            await this.poll();
        } catch (error) {
            this.errorMessage = reduceError(error);
        } finally {
            this.starting = false;
        }
    }

    async poll() {
        try {
            this.status = await getStatus({ runId: this.result.runId });
        } catch (error) {
            this.errorMessage = reduceError(error);
            return;
        }
        if (!this.finished && this.isOpen) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.timer = setTimeout(() => this.poll(), POLL_MS);
        }
    }

    stopPolling() {
        if (this.timer) {
            clearTimeout(this.timer);
            this.timer = undefined;
        }
    }

    get finished() {
        return Boolean(this.status && (this.status.status === 'Complete' || this.status.status === 'Failed'));
    }

    get heading() {
        return this.finished ? 'Sample company ready' : 'Load sample company';
    }

    get subheading() {
        return this.result ? this.result.companyName : 'Creates Harbourline Trading with a chart of accounts, customers, suppliers and three months of activity.';
    }

    get steps() {
        const s = this.status;
        if (!s) {
            return [];
        }
        return (s.steps || []).map((label, i) => {
            const done = i < s.stepsDone;
            const now = !this.finished && i === s.stepsDone;
            return {
                key: label,
                label,
                className: done ? 'step done' : now ? 'step now' : 'step',
                done,
                number: i + 1,
                hint: now ? 'Working' : ''
            };
        });
    }

    get summary() {
        const s = this.status;
        if (!this.finished) {
            return s ? `${s.stepsDone} of ${s.stepsTotal} steps done` : 'Setting up the company';
        }
        return s.failures ? `${s.stepsTotal - s.failures} of ${s.stepsTotal} steps done, ${s.failures} could not run with your permissions` : 'Every step finished';
    }

    get showFailureNote() {
        return Boolean(this.finished && this.status.failures);
    }

    get lastMessage() {
        return this.status ? this.status.lastMessage : '';
    }

    get openDisabled() {
        return !this.result;
    }

    get openLabel() {
        return this.finished ? 'Open sample company' : 'Open now';
    }

    handleOpenCompany() {
        this.stopPolling();
        this.dispatchEvent(new CustomEvent('loaded', { detail: { recordId: this.result.companyId } }));
    }

    handleClose() {
        this.stopPolling();
        this.dispatchEvent(new CustomEvent('close'));
    }
}
