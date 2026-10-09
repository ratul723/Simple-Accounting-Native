import { createElement } from 'lwc';
import SabDonut from 'c/sabDonut';

describe('c-sab-donut', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('draws one segment per positive part and the centre text', () => {
        const el = createElement('c-sab-donut', { is: SabDonut });
        el.parts = [{ value: 60, color: 'var(--chart-1)', label: 'A' }, { value: 40, color: 'var(--chart-2)' }, { value: 0 }];
        el.centerValue = '100,000';
        el.centerLabel = 'shares';
        document.body.appendChild(el);
        expect(el.shadowRoot.querySelectorAll('path').length).toBe(2);
        expect(el.shadowRoot.querySelector('.cv').textContent).toBe('100,000');
    });

    it('draws a full ring for a single holder and nothing for no data', () => {
        const el = createElement('c-sab-donut', { is: SabDonut });
        el.parts = [{ value: 10, color: 'red' }];
        document.body.appendChild(el);
        expect(el.shadowRoot.querySelectorAll('path').length).toBe(1);
        el.parts = [];
        return Promise.resolve().then(() => {
            expect(el.shadowRoot.querySelectorAll('path').length).toBe(0);
        });
    });
});
