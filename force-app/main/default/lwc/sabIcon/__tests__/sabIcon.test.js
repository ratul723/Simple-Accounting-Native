import { createElement } from 'lwc';
import SabIcon from 'c/sabIcon';

describe('c-sab-icon', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('renders the icon paths, decorative by default', () => {
        const el = createElement('c-sab-icon', { is: SabIcon });
        el.name = 'setup';
        document.body.appendChild(el);
        const svg = el.shadowRoot.querySelector('svg');
        expect(svg.getAttribute('aria-hidden')).toBe('true');
        expect(el.shadowRoot.querySelectorAll('path').length).toBe(3);
    });

    it('exposes a label and renders nothing for unknown names', () => {
        const el = createElement('c-sab-icon', { is: SabIcon });
        el.name = 'not-an-icon';
        el.label = 'Missing';
        document.body.appendChild(el);
        const svg = el.shadowRoot.querySelector('svg');
        expect(svg.getAttribute('role')).toBe('img');
        expect(svg.getAttribute('aria-label')).toBe('Missing');
        expect(el.shadowRoot.querySelectorAll('path').length).toBe(0);
    });
});
