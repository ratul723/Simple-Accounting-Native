import { LightningElement, api } from 'lwc';
import { formatNumber } from 'c/sabFormat';

const COLORS = ['var(--chart-1)', 'var(--chart-3)', '#D9822B', 'var(--bad)', '#7A1C16'];
const LABELS = ['Not yet due', '1-30 days', '31-60 days', '61-90 days', '90+ days'];

/** Aging stack bar and bucket legend, as the demo's agingBar. buckets: [current, 1-30, 31-60, 61-90, 90+]. */
export default class SabAgingBar extends LightningElement {
    @api buckets = [];

    get values() {
        return [0, 1, 2, 3, 4].map((i) => Number((this.buckets || [])[i]) || 0);
    }

    get segments() {
        const values = this.values;
        const total = values.reduce((s, v) => s + v, 0);
        return values
            .map((v, i) => ({ key: `s${i}`, value: v, style: `width:${total ? (v / total) * 100 : 0}%;background:${COLORS[i]}`, title: formatNumber(v) }))
            .filter((s) => s.value > 0);
    }

    get legend() {
        return this.values.map((v, i) => ({ key: `l${i}`, label: LABELS[i], text: formatNumber(v), swatch: `background:${COLORS[i]}` }));
    }
}
