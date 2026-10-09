import { LightningElement, api } from 'lwc';
import { formatCompact } from 'c/sabFormat';

const W = 640;
const PAD_LEFT = 46;
const PAD_RIGHT = 12;
const PAD_TOP = 12;
const PAD_BOTTOM = 26;

const fix = (n) => Number(n.toFixed(1));

/**
 * Line chart with the demo's geometry: 640 wide viewBox, four gridlines with compact labels,
 * optional area fill under the first series and an end dot on the first series.
 * series: [{ values: Number[], color: String, width: Number, dash: Boolean }]
 */
export default class SabLineChart extends LightningElement {
    @api series = [];
    @api labels = [];
    @api height = 200;
    @api area = false;
    @api every = 1;
    @api min;
    @api label = 'Chart';

    get viewBox() {
        return `0 0 ${W} ${this.h}`;
    }

    get h() {
        return Number(this.height) || 200;
    }

    get hasData() {
        return this.cleanSeries.length > 0 && this.labelList.length > 1;
    }

    get labelList() {
        return Array.isArray(this.labels) ? this.labels : [];
    }

    get cleanSeries() {
        return (Array.isArray(this.series) ? this.series : [])
            .map((s) => ({ ...s, values: (s.values || []).map((v) => Number(v) || 0) }))
            .filter((s) => s.values.length > 0);
    }

    get scale() {
        const all = this.cleanSeries.flatMap((s) => s.values);
        let mn = this.min !== undefined && this.min !== null ? Number(this.min) : Math.min(...all);
        let mx = Math.max(...all);
        if (this.min === undefined || this.min === null) {
            const pad = (mx - mn) * 0.15 || 1;
            mn -= pad;
        }
        mx += (mx - mn) * 0.08;
        if (mx === mn) {
            mx = mn + 1;
        }
        const n = this.labelList.length;
        const x = (i) => PAD_LEFT + (i * (W - PAD_LEFT - PAD_RIGHT)) / (n - 1);
        const y = (v) => PAD_TOP + (this.h - PAD_TOP - PAD_BOTTOM) * (1 - (v - mn) / (mx - mn));
        return { mn, mx, x, y };
    }

    get gridlines() {
        if (!this.hasData) {
            return [];
        }
        const { mn, mx, y } = this.scale;
        const lines = [];
        for (let i = 0; i <= 3; i++) {
            const v = mn + ((mx - mn) * i) / 3;
            lines.push({
                key: `g${i}`,
                x1: PAD_LEFT,
                x2: W - PAD_RIGHT,
                y: y(v),
                ty: y(v) + 4,
                tx: PAD_LEFT - 8,
                text: formatCompact(v)
            });
        }
        return lines;
    }

    get xLabels() {
        if (!this.hasData) {
            return [];
        }
        const { x } = this.scale;
        const every = Number(this.every) || 1;
        const list = this.labelList;
        return list
            .map((text, i) => ({ key: `x${i}`, x: x(i), y: this.h - 6, text, show: i % every === 0 || i === list.length - 1 }))
            .filter((item) => item.show);
    }

    get paths() {
        if (!this.hasData) {
            return [];
        }
        const { x, y } = this.scale;
        const base = this.h - PAD_BOTTOM;
        return this.cleanSeries.map((s, si) => {
            const d = s.values.map((v, i) => `${i ? 'L' : 'M'}${fix(x(i))},${fix(y(v))}`).join('');
            const last = s.values.length - 1;
            return {
                key: `s${si}`,
                d,
                stroke: s.color || 'var(--chart-1)',
                strokeWidth: s.width || 2.2,
                dash: s.dash ? '5 4' : undefined,
                hasArea: si === 0 && this.area,
                areaD: `${d}L${x(last)},${base}L${x(0)},${base}Z`,
                hasDot: si === 0,
                cx: x(last),
                cy: y(s.values[last])
            };
        });
    }
}
