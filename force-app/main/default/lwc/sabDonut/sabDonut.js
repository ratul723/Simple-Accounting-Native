import { LightningElement, api } from 'lwc';

const R = 70;
const RI = 46;
const C = 90;

/**
 * Donut chart with the demo's geometry (180 x 180, outer 70, inner 46) and a serif centre value.
 * parts: [{ value: Number, color: String, label: String }]
 */
export default class SabDonut extends LightningElement {
    @api parts = [];
    @api centerValue = '';
    @api centerLabel = '';
    @api label = 'Ownership chart';

    get segments() {
        const list = (Array.isArray(this.parts) ? this.parts : []).filter((p) => Number(p.value) > 0);
        const total = list.reduce((s, p) => s + Number(p.value), 0);
        if (!total) {
            return [];
        }
        if (list.length === 1) {
            const p = list[0];
            return [{
                key: 'seg0',
                d: `M${C - R},${C}a${R},${R} 0 1 0 ${2 * R},0a${R},${R} 0 1 0 ${-2 * R},0Z` +
                    `M${C - RI},${C}a${RI},${RI} 0 1 1 ${2 * RI},0a${RI},${RI} 0 1 1 ${-2 * RI},0Z`,
                fill: p.color,
                title: p.label || ''
            }];
        }
        let a = -Math.PI / 2;
        return list.map((p, i) => {
            const a2 = a + (Number(p.value) / total) * Math.PI * 2;
            const lg = a2 - a > Math.PI ? 1 : 0;
            const d = `M${C + R * Math.cos(a)},${C + R * Math.sin(a)}A${R},${R} 0 ${lg} 1 ${C + R * Math.cos(a2)},${C + R * Math.sin(a2)}` +
                `L${C + RI * Math.cos(a2)},${C + RI * Math.sin(a2)}A${RI},${RI} 0 ${lg} 0 ${C + RI * Math.cos(a)},${C + RI * Math.sin(a)}Z`;
            a = a2;
            return { key: `seg${i}`, d, fill: p.color, title: p.label || '' };
        });
    }
}
