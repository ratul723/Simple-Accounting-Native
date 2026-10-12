import { createElement } from 'lwc';
import SabAgingBar from 'c/sabAgingBar';

describe('c-sab-aging-bar', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('draws non-empty segments and five buckets', () => {
        const el = createElement('c-sab-aging-bar', { is: SabAgingBar });
        el.buckets = [100, 0, 50, 0, 50];
        document.body.appendChild(el);
        const segments = el.shadowRoot.querySelectorAll('.stackbar i');
        expect(segments.length).toBe(3);
        expect(segments[0].getAttribute('style')).toContain('width:50%');
        const buckets = el.shadowRoot.querySelectorAll('.buckets > div');
        expect(buckets.length).toBe(5);
        expect(buckets[0].textContent).toBe('Not yet due100.00');
    });

    it('handles empty buckets', () => {
        const el = createElement('c-sab-aging-bar', { is: SabAgingBar });
        el.buckets = undefined;
        document.body.appendChild(el);
        expect(el.shadowRoot.querySelectorAll('.stackbar i').length).toBe(0);
    });
});
