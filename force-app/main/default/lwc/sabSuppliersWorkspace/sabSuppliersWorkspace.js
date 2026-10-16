import { LightningElement, api } from 'lwc';

/** Suppliers under Money in & out: the shared contacts list for suppliers. */
export default class SabSuppliersWorkspace extends LightningElement {
    @api companyId;
    @api companyName;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api recordId;
    @api currencyCode;
    @api setupStatus;
    @api periodKey;
}