import { LightningElement, api } from 'lwc';

const MAX_VISIBLE = 3;
const VISIBLE_MS = 3200;
const FADE_MS = 320;

/**
 * Bottom-centre toast stack. Call show(message) on the instance; at most three stay visible and
 * each fades out after 3.2 seconds, as in the demo.
 */
export default class SabToast extends LightningElement {
    toasts = [];
    sequence = 0;
    timers = [];

    @api
    show(message, tone) {
        if (!message) {
            return;
        }
        const id = ++this.sequence;
        const next = this.toasts.slice(-(MAX_VISIBLE - 1));
        next.push({ id, message, icon: tone === 'bad' ? 'alert' : 'check', className: `toast t-${tone || 'good'}` });
        this.toasts = next;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timers.push(setTimeout(() => this.fade(id), VISIBLE_MS));
    }

    fade(id) {
        this.toasts = this.toasts.map((t) => (t.id === id ? { ...t, className: `${t.className} out` } : t));
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timers.push(setTimeout(() => this.remove(id), FADE_MS));
    }

    remove(id) {
        this.toasts = this.toasts.filter((t) => t.id !== id);
    }

    disconnectedCallback() {
        this.timers.forEach((timer) => clearTimeout(timer));
        this.timers = [];
    }
}
