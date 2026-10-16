import { LightningElement, api } from 'lwc';

let pickerSequence = 0;

/**
 * Customer or supplier picker: a button that opens a list of parties with a pinned footer row
 * ("Add new customer" / "Add new supplier"), like Salesforce lookups and accounting apps.
 * Fires change { value } when a party is chosen and addnew when the footer row is chosen.
 * Keyboard: Arrow keys move, Enter or Space picks, Escape or Tab closes; clicking outside closes.
 */
export default class SabPartyPicker extends LightningElement {
    @api label;
    @api options = [];
    @api value;
    @api addLabel = 'Add new';
    @api placeholder = 'Select';

    isOpen = false;
    activeIndex = -1;
    listId = `sab-party-list-${++pickerSequence}`;

    get selectedLabel() {
        const match = (this.options || []).find((o) => o.value === this.value);
        return match ? match.label : this.placeholder;
    }

    get buttonClass() {
        return `select trigger${this.value ? '' : ' empty'}`;
    }

    get panelClass() {
        return `panel-list${this.isOpen ? ' open' : ''}`;
    }

    get expanded() {
        return this.isOpen ? 'true' : 'false';
    }

    /** Parties first, then the add row as the last item, so the keyboard reaches it too. */
    get items() {
        return (this.options || []).map((o, i) => ({
            key: o.value,
            value: o.value,
            label: o.label,
            index: i,
            selected: o.value === this.value ? 'true' : 'false',
            className: `opt${i === this.activeIndex ? ' active' : ''}${o.value === this.value ? ' sel' : ''}`
        }));
    }

    get addIndex() {
        return (this.options || []).length;
    }

    get addClass() {
        return `add-row${this.activeIndex === this.addIndex ? ' active' : ''}`;
    }

    get noOptions() {
        return (this.options || []).length === 0;
    }

    handleToggle() {
        if (this.isOpen) {
            this.close();
        } else {
            this.openList();
        }
    }

    openList() {
        this.isOpen = true;
        const current = (this.options || []).findIndex((o) => o.value === this.value);
        this.activeIndex = current >= 0 ? current : 0;
    }

    close() {
        this.isOpen = false;
        this.activeIndex = -1;
    }

    handleKeydown(event) {
        const last = this.addIndex;
        if (!this.isOpen) {
            if (['ArrowDown', 'ArrowUp', 'Enter', ' '].includes(event.key)) {
                event.preventDefault();
                this.openList();
            }
            return;
        }
        if (event.key === 'ArrowDown') {
            event.preventDefault();
            this.activeIndex = Math.min(last, this.activeIndex + 1);
        } else if (event.key === 'ArrowUp') {
            event.preventDefault();
            this.activeIndex = Math.max(0, this.activeIndex - 1);
        } else if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.pickIndex(this.activeIndex);
        } else if (event.key === 'Escape') {
            event.preventDefault();
            event.stopPropagation();
            this.close();
        } else if (event.key === 'Tab') {
            this.close();
        }
    }

    pickIndex(index) {
        if (index === this.addIndex) {
            this.close();
            this.dispatchEvent(new CustomEvent('addnew'));
            return;
        }
        const option = (this.options || [])[index];
        if (option) {
            this.close();
            this.dispatchEvent(new CustomEvent('change', { detail: { value: option.value } }));
        }
    }

    handleOptionClick(event) {
        this.pickIndex(Number(event.currentTarget.dataset.index));
    }

    handleAddClick() {
        this.pickIndex(this.addIndex);
    }

    // Keep focus on the button while choosing with the mouse, so focusout only fires for real outside clicks.
    handlePanelMousedown(event) {
        event.preventDefault();
    }

    handleFocusOut() {
        this.close();
    }
}
