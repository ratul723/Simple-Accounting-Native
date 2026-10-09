import { LightningElement, api } from 'lwc';

/**
 * Workspace header: "Company / Group" breadcrumb, serif title, description and an "actions" slot.
 */
export default class SabWorkspaceHeader extends LightningElement {
    @api companyName;
    @api group;
    @api heading;
    @api description;
    @api optionalModule = false;

    get showCrumbs() {
        return Boolean(this.companyName || this.group);
    }

    get showSeparator() {
        return Boolean(this.companyName && this.group);
    }
}
