import { LightningElement, api } from 'lwc';

/**
 * Right-hand detail drawer (560px) with scrim. Content goes in the default slot and actions in
 * the "footer" slot. Fires "close" on the close button, the scrim or Escape.
 */
export default class SabDrawer extends LightningElement {
    @api heading;
    @api subheading;
    @api closeLabel = 'Close panel';
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

    get drawerClass() {
        return this.isOpen ? 'drawer open' : 'drawer';
    }

    get scrimClass() {
        return this.isOpen ? 'scrim open' : 'scrim';
    }

    get footerClass() {
        return this.hasFooter ? 'drawer-f' : 'drawer-f empty-f';
    }

    get ariaHidden() {
        return this.isOpen ? 'false' : 'true';
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
