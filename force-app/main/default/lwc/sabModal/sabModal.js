import { LightningElement, api } from 'lwc';

/**
 * Centred modal dialog (up to 680px) with scrim. Body in the default slot, actions in "footer".
 * Fires "close" on the close button, the scrim or Escape.
 */
export default class SabModal extends LightningElement {
    @api heading;
    @api subheading;
    @api closeLabel = 'Close dialog';
    /** 'default' (forms), or 'wide' for dialogs with a table of lines (budget lines, invoices, bills). */
    @api size = 'default';
    hasFooter = false;
    wasOpen = false;
    isOpen = false;

    @api
    get open() {
        return this.isOpen;
    }
    set open(value) {
        this.isOpen = value === true || value === 'true';
    }

    get modalClass() {
        return `modal${this.isOpen ? ' open' : ''}${this.size === 'wide' ? ' wide' : ''}`;
    }

    get footerClass() {
        return this.hasFooter ? 'drawer-f' : 'drawer-f empty-f';
    }

    renderedCallback() {
        if (this.isOpen && !this.wasOpen) {
            const button = this.template.querySelector('.close-btn');
            if (button) {
                button.focus();
            }
        }
        this.wasOpen = this.isOpen;
    }

    handleFooterSlot(event) {
        this.hasFooter = event.target.assignedNodes().length > 0;
    }

    handleKeydown(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            this.requestClose();
        }
    }

    requestClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }
}