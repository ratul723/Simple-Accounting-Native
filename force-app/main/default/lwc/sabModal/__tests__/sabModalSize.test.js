import { createElement } from 'lwc';
import SabModal from 'c/sabModal';

describe('c-sab-modal size', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('is a normal form width by default and wide for line tables', async () => {
        const el = createElement('c-sab-modal', { is: SabModal });
        el.open = true;
        document.body.appendChild(el);
        await Promise.resolve();
        expect(el.shadowRoot.querySelector('.modal').className).toBe('modal open');
        el.size = 'wide';
        await Promise.resolve();
        expect(el.shadowRoot.querySelector('.modal').className).toBe('modal open wide');
    });
});
