import { LightningElement, api } from 'lwc';

const MAX_VISIBLE = 3;
const VISIBLE_MS = 3200;
const FADE_MS = 320;

/**
 * Bottom-centre toast stack. Call show(message, tone) on the instance; at most three stay visible.
 * Confirmations fade out after 3.2 seconds. Errors (tone 'bad') stay until the user clicks anywhere on the page,
 * so a message is never missed.
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
        const sticky = tone === 'bad';
        next.push({ id, message, sticky, icon: sticky ? 'alert' : 'check', className: `toast t-${tone || 'good'}${sticky ? ' sticky' : ''}`,
            role: sticky ? 'alert' : 'status' });
        this.toasts = next;
        if (sticky) {
            this.listenForClick();
        } else {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this.timers.push(setTimeout(() => this.fade(id), VISIBLE_MS));
        }
    }

    // Registered after the current click finishes, so the click that caused the error does not dismiss it.
    listenForClick() {
        if (this.clickListener) {
            return;
        }
        this.clickListener = () => this.dismissSticky();
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timers.push(setTimeout(() => {
            if (this.clickListener) {
                document.addEventListener('click', this.clickListener, true);
            }
        }, 0));
    }

    dismissSticky() {
        this.stopListening();
        this.toasts.filter((t) => t.sticky).forEach((t) => this.fade(t.id));
    }

    stopListening() {
        if (this.clickListener) {
            document.removeEventListener('click', this.clickListener, true);
            this.clickListener = undefined;
        }
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
        this.stopListening();
        this.timers.forEach((timer) => clearTimeout(timer));
        this.timers = [];
    }
}