import { LightningElement, api } from 'lwc';
import ICONS from './icons';

/**
 * Stroke icon from the Simple Accounting Books set. Decorative by default (aria-hidden);
 * pass a label to expose it to assistive technology.
 */
export default class SabIcon extends LightningElement {
    @api name;
    @api size = 18;
    @api strokeWidth = 1.8;
    @api label;

    get paths() {
        const list = ICONS[this.name] || [];
        return list.map((d, index) => ({ key: `${this.name}-${index}`, d }));
    }

    get isDecorative() {
        return this.label ? 'false' : 'true';
    }

    get role() {
        return this.label ? 'img' : undefined;
    }
}
