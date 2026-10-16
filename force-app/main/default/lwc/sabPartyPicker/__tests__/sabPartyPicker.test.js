import { createElement } from 'lwc';
import SabPartyPicker from 'c/sabPartyPicker';

const OPTIONS = [{ value: 'C1', label: 'Coastal Foods (sample)' }, { value: 'C2', label: 'Greenfield Produce (sample)' }];

async function flush() {
    for (let i = 0; i < 4; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount(props = {}) {
    const el = createElement('c-sab-party-picker', { is: SabPartyPicker });
    Object.assign(el, { label: 'Customer', options: OPTIONS, addLabel: 'Add new customer', ...props });
    document.body.appendChild(el);
    return el;
}

function key(target, k) {
    target.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true }));
}

describe('c-sab-party-picker', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('opens a list with a pinned add row and picks with the mouse', async () => {
        const el = mount();
        const change = jest.fn();
        const add = jest.fn();
        el.addEventListener('change', change);
        el.addEventListener('addnew', add);
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.trigger').textContent).toContain('Select');
        expect(root.querySelector('.panel-list').className).not.toContain('open');
        root.querySelector('.trigger').click();
        await flush();
        expect(root.querySelector('.panel-list').className).toContain('open');
        expect(root.querySelector('.trigger').getAttribute('aria-expanded')).toBe('true');
        expect(Array.from(root.querySelectorAll('.opt')).map((o) => o.textContent)).toEqual(['Coastal Foods (sample)', 'Greenfield Produce (sample)']);
        expect(root.querySelector('.add-row').textContent).toBe('Add new customer');
        root.querySelectorAll('.opt')[1].click();
        await flush();
        expect(change.mock.calls[0][0].detail.value).toBe('C2');
        expect(root.querySelector('.panel-list').className).not.toContain('open');
        root.querySelector('.trigger').click();
        await flush();
        root.querySelector('.add-row').click();
        expect(add).toHaveBeenCalledTimes(1);
        root.querySelector('.trigger').click();
        root.querySelector('.panel-list').dispatchEvent(new CustomEvent('mousedown', { cancelable: true }));
        root.querySelector('.trigger').click();
        await flush();
        expect(root.querySelector('.panel-list').className).not.toContain('open');
    });

    it('works from the keyboard and closes on Escape, Tab and outside clicks', async () => {
        const el = mount({ value: 'C1' });
        const change = jest.fn();
        const add = jest.fn();
        el.addEventListener('change', change);
        el.addEventListener('addnew', add);
        await flush();
        const root = el.shadowRoot;
        const trigger = root.querySelector('.trigger');
        expect(trigger.textContent).toContain('Coastal Foods (sample)');
        key(trigger, 'x');
        key(trigger, 'ArrowDown');
        await flush();
        expect(root.querySelector('.opt.active').textContent).toBe('Coastal Foods (sample)');
        key(trigger, 'ArrowUp');
        key(trigger, 'ArrowDown');
        await flush();
        key(trigger, 'Enter');
        await flush();
        expect(change.mock.calls[0][0].detail.value).toBe('C2');
        key(trigger, 'Enter');
        key(trigger, 'ArrowDown');
        key(trigger, 'ArrowDown');
        key(trigger, 'ArrowDown');
        await flush();
        expect(root.querySelector('.add-row').className).toContain('active');
        key(trigger, ' ');
        expect(add).toHaveBeenCalledTimes(1);
        key(trigger, 'ArrowDown');
        await flush();
        key(trigger, 'Escape');
        await flush();
        expect(root.querySelector('.panel-list').className).not.toContain('open');
        key(trigger, 'ArrowDown');
        key(trigger, 'Tab');
        await flush();
        expect(root.querySelector('.panel-list').className).not.toContain('open');
        trigger.click();
        root.querySelector('.picker').dispatchEvent(new CustomEvent('focusout'));
        await flush();
        expect(root.querySelector('.panel-list').className).not.toContain('open');
    });

    it('shows an empty state and the placeholder when there are no parties', async () => {
        const el = mount({ options: [], value: 'X' });
        await flush();
        el.shadowRoot.querySelector('.trigger').click();
        await flush();
        expect(el.shadowRoot.querySelector('.none').textContent).toBe('None yet');
        expect(el.shadowRoot.querySelector('.trigger').textContent).toContain('Select');
        el.options = undefined;
        await flush();
        expect(el.shadowRoot.querySelectorAll('.opt').length).toBe(0);
    });
});
