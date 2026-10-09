import { createElement } from 'lwc';
import SabModal from 'c/sabModal';

const flush = () => Promise.resolve();

describe('c-sab-modal', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('opens and fires close from the button, scrim and Escape', async () => {
        const el = createElement('c-sab-modal', { is: SabModal });
        el.heading = 'Posting preview';
        el.subheading = 'JE-000318';
        document.body.appendChild(el);
        const handler = jest.fn();
        el.addEventListener('close', handler);
        el.open = true;
        await flush();
        const modal = el.shadowRoot.querySelector('.modal');
        expect(modal.className).toBe('modal open');
        expect(el.shadowRoot.querySelector('h2').textContent).toBe('Posting preview');
        el.shadowRoot.querySelector('.close-btn').click();
        el.shadowRoot.querySelector('.scrim').click();
        modal.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
        modal.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab' }));
        expect(handler).toHaveBeenCalledTimes(3);
        el.open = false;
        await flush();
        expect(el.open).toBe(false);
        expect(el.shadowRoot.querySelector('.modal').className).toBe('modal');
    });
});
