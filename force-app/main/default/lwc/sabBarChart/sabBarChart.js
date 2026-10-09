import { LightningElement, api } from 'lwc';
import { formatCompact, formatNumber } from 'c/sabFormat';

const W = 640;
const PAD_LEFT = 46;
const PAD_RIGHT = 10;
const PAD_TOP = 10;
const PAD_BOTTOM = 26;

/**
 * Grouped bar chart with the demo's geometry and legend.
 * groups: [{ label: String, values: Number[] }], series: [{ name: String, color: String }]
 */
export default class SabBarChart extends LightningElement {
    @api groups = [];
    @api series = [];
    @api height = 210;
    @api label = 'Bar chart';

    get h() {
        return Number(this.height) || 210;
    }

    get viewBox() {
        return `0 0 ${W} ${this.h}`;
    }

    get groupList() {
        return Array.isArray(this.groups) ? this.groups : [];
    }

    get seriesList() {
        return Array.isArray(this.series) ? this.series : [];
    }

    get max() {
        const all = this.groupList.flatMap((g) => (g.values || []).map((v) => Number(v) || 0));
        const mx = Math.max(0, ...all) * 1.1;
        return mx > 0 ? mx : 1;
    }

    y(v) {
        return PAD_TOP + (this.h - PAD_TOP - PAD_BOTTOM) * (1 - v / this.max);
    }

    get gridlines() {
        if (!this.groupList.length) {
            return [];
        }
        const lines = [];
        for (let i = 0; i <= 3; i++) {
            const v = (this.max * i) / 3;
            lines.push({
                key: `g${i}`,
                x1: PAD_LEFT,
                x2: W - PAD_RIGHT,
                y: this.y(v),
                ty: this.y(v) + 4,
                tx: PAD_LEFT - 8,
                text: formatCompact(v)
            });
        }
        return lines;
    }

    get bars() {
        const groups = this.groupList;
        const series = this.seriesList;
        if (!groups.length || !series.length) {
            return [];
        }
        const gw = (W - PAD_LEFT - PAD_RIGHT) / groups.length;
        const bw = Math.min(34, (gw * 0.7) / series.length);
        const base = this.h - PAD_BOTTOM;
        return groups.map((group, gi) => {
            const cx = PAD_LEFT + gw * gi + gw / 2;
            const start = cx - (bw * series.length) / 2;
            const rects = series.map((s, si) => {
                const v = Number((group.values || [])[si]) || 0;
                const top = this.y(Math.max(0, v));
                return {
                    key: `b${gi}-${si}`,
                    x: start + si * bw + 1,
                    y: top,
                    width: Math.max(0, bw - 2),
                    height: Math.max(0, base - top),
                    fill: s.color,
                    title: `${s.name} ${group.label}: ${formatNumber(v)}`
                };
            });
            return { key: `grp${gi}`, rects, lx: cx, ly: this.h - 7, label: group.label };
        });
    }

    get legend() {
        return this.seriesList.map((s, i) => ({ key: `l${i}`, name: s.name, style: `background:${s.color}` }));
    }
}
