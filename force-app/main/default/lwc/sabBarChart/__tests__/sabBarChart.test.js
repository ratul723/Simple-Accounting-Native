import { createElement } from 'lwc';
import SabBarChart from 'c/sabBarChart';

describe('c-sab-bar-chart', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('draws one bar per group and series with a legend', () => {
        const el = createElement('c-sab-bar-chart', { is: SabBarChart });
        el.groups = [{ label: 'Jul', values: [1000, 800] }, { label: 'Aug', values: [1200, 900] }];
        el.series = [{ name: 'Income', color: 'var(--chart-1)' }, { name: 'Expenses', color: 'var(--chart-2)' }];
        document.body.appendChild(el);
        const root = el.shadowRoot;
        expect(root.querySelectorAll('rect').length).toBe(4);
        expect(root.querySelectorAll('line').length).toBe(4);
        expect(root.querySelector('rect title').textContent).toBe('Income Jul: 1,000.00');
        expect(Array.from(root.querySelectorAll('.legend span')).map((s) => s.textContent)).toEqual(['Income', 'Expenses']);
    });

    it('renders an empty chart without groups', () => {
        const el = createElement('c-sab-bar-chart', { is: SabBarChart });
        el.groups = [];
        el.series = [];
        document.body.appendChild(el);
        expect(el.shadowRoot.querySelectorAll('rect').length).toBe(0);
        expect(el.shadowRoot.querySelectorAll('line').length).toBe(0);
    });
});
