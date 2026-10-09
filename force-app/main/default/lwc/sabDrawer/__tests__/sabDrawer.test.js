import { createElement } from 'lwc';
import SabDrawer from 'c/sabDrawer';

const flush = () => Promise.resolve();

describe('c-sab-drawer', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('opens, shows the heading and closes from button, scrim and Escape', async () => {
        const el = createElement('c-sab-drawer', { is: SabDrawer });
        el.heading = 'INV-000123';
        el.subheading = 'Greenfield Produce';
        document.body.appendChild(el);
        const handler = jest.fn();
        el.addEventListener('close', handler);
        expect(el.shadowRoot.querySelector('aside').className).toBe('drawer');
        el.open = true;
        await flush();
        expect(el.open).toBe(true);
        expect(el.shadowRoot.querySelector('aside').className).toBe('drawer open');
        expect(el.shadowRoot.querySelector('.scrim').className).toBe('scrim open');
        expect(el.shadowRoot.querySelector('h2').textContent).toBe('INV-000123');
        expect(el.shadowRoot.querySelector('.sub').textContent).toBe('Greenfield Produce');
        el.shadowRoot.querySelector('.close-btn').click();
        el.shadowRoot.querySelector('.scrim').click();
        el.shadowRoot.querySelector('aside').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
        el.shadowRoot.querySelector('aside').dispatchEvent(new KeyboardEvent('keydown', { key: 'a' }));
        expect(handler).toHaveBeenCalledTimes(3);
        expect(el.shadowRoot.querySelector('.drawer-f').className).toContain('empty-f');
    });

    it('accepts string values for open', async () => {
        const el = createElement('c-sab-drawer', { is: SabDrawer });
        el.open = 'true';
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.querySelector('aside').getAttribute('aria-hidden')).toBe('false');
    });
});
