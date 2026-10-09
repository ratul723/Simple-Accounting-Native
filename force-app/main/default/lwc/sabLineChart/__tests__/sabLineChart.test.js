import { createElement } from 'lwc';
import SabLineChart from 'c/sabLineChart';

describe('c-sab-line-chart', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('draws gridlines, labels, area and end dot with the demo geometry', () => {
        const el = createElement('c-sab-line-chart', { is: SabLineChart });
        el.series = [{ values: [100, 200, 150], color: 'var(--chart-1)' }, { values: [90, 120, 130], color: 'var(--chart-2)', dash: true }];
        el.labels = ['3 Jul', '10', '17'];
        el.area = true;
        el.every = 2;
        document.body.appendChild(el);
        const root = el.shadowRoot;
        expect(root.querySelector('svg').getAttribute('viewBox')).toBe('0 0 640 200');
        expect(root.querySelectorAll('line').length).toBe(4);
        const xLabels = Array.from(root.querySelectorAll('text')).filter((t) => t.getAttribute('text-anchor') === 'middle');
        expect(xLabels.map((t) => t.textContent)).toEqual(['3 Jul', '17']);
        const paths = root.querySelectorAll('path');
        expect(paths.length).toBe(3);
        expect(paths[1].getAttribute('d').startsWith('M46,')).toBe(true);
        expect(paths[2].getAttribute('stroke-dasharray')).toBe('5 4');
        const dot = root.querySelector('circle');
        expect(Number(dot.getAttribute('cx'))).toBe(628);
    });

    it('renders nothing without enough data', () => {
        const el = createElement('c-sab-line-chart', { is: SabLineChart });
        el.series = [{ values: [5] }];
        el.labels = ['only'];
        el.min = 0;
        document.body.appendChild(el);
        expect(el.shadowRoot.querySelectorAll('line').length).toBe(0);
        expect(el.shadowRoot.querySelectorAll('path').length).toBe(0);
    });

    it('handles a flat series with an explicit minimum', () => {
        const el = createElement('c-sab-line-chart', { is: SabLineChart });
        el.series = [{ values: [0, 0] }];
        el.labels = ['a', 'b'];
        el.min = 0;
        el.height = 160;
        document.body.appendChild(el);
        expect(el.shadowRoot.querySelector('svg').getAttribute('viewBox')).toBe('0 0 640 160');
        expect(el.shadowRoot.querySelectorAll('line').length).toBe(4);
    });
});
