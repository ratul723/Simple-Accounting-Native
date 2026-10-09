import { createElement } from 'lwc';
import SabToast from 'c/sabToast';

const flush = () => Promise.resolve();

describe('c-sab-toast', () => {
    beforeEach(() => {
        jest.useFakeTimers();
    });

    afterEach(() => {
        jest.useRealTimers();
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('keeps at most three toasts and removes them after the timeout', async () => {
        const el = createElement('c-sab-toast', { is: SabToast });
        document.body.appendChild(el);
        el.show('One');
        el.show('Two');
        el.show('Three');
        el.show('Four', 'bad');
        el.show('');
        await flush();
        const toasts = el.shadowRoot.querySelectorAll('.toast');
        expect(Array.from(toasts).map((t) => t.textContent)).toEqual(['Two', 'Three', 'Four']);
        expect(toasts[2].className).toContain('t-bad');
        jest.advanceTimersByTime(3200);
        await flush();
        expect(el.shadowRoot.querySelector('.toast').className).toContain('out');
        jest.advanceTimersByTime(400);
        await flush();
        expect(el.shadowRoot.querySelectorAll('.toast').length).toBe(0);
    });

    it('clears timers when removed', () => {
        const el = createElement('c-sab-toast', { is: SabToast });
        document.body.appendChild(el);
        el.show('Bye');
        document.body.removeChild(el);
        expect(jest.getTimerCount()).toBe(0);
    });
});
