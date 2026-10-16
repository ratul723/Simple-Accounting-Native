import { LightningElement, api } from 'lwc';

/** Customers under Money in & out: the shared contacts list for customers. */
export default class SabCustomersWorkspace extends LightningElement {
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