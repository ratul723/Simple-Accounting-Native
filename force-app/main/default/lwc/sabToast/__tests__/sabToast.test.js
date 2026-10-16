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
        // The error stays until the user clicks; the confirmations are gone.
        expect(Array.from(el.shadowRoot.querySelectorAll('.toast')).map((t) => t.textContent)).toEqual(['Four']);
    });

    it('clears timers when removed', () => {
        const el = createElement('c-sab-toast', { is: SabToast });
        document.body.appendChild(el);
        el.show('Bye');
        document.body.removeChild(el);
        expect(jest.getTimerCount()).toBe(0);
    });

    it('keeps an error until the user clicks anywhere', async () => {
        jest.useFakeTimers();
        const el = createElement('c-sab-toast', { is: SabToast });
        document.body.appendChild(el);
        el.show('Saved', 'good');
        el.show('Something failed', 'bad');
        await Promise.resolve();
        const errorToast = () => Array.from(el.shadowRoot.querySelectorAll('.toast')).find((t) => t.textContent === 'Something failed');
        expect(errorToast().getAttribute('role')).toBe('alert');
        jest.advanceTimersByTime(10000);
        await Promise.resolve();
        expect(el.shadowRoot.querySelectorAll('.toast').length).toBe(1);
        expect(errorToast().className).not.toContain('out');
        document.body.click();
        await Promise.resolve();
        expect(errorToast().className).toContain('out');
        jest.advanceTimersByTime(400);
        await Promise.resolve();
        expect(el.shadowRoot.querySelectorAll('.toast').length).toBe(0);
        el.show('Again', 'bad');
        jest.advanceTimersByTime(1);
        document.body.removeChild(el);
        document.body.click();
        jest.useRealTimers();
    });
});
