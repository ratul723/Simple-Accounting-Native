import { LightningElement, api } from 'lwc';
import getFormOptions from '@salesforce/apex/SABContactService.getFormOptions';
import getContact from '@salesforce/apex/SABContactService.getContact';
import saveContact from '@salesforce/apex/SABContactService.saveContact';
import { reduceError, newKey, toast } from 'c/sabMoneyShared';

const opts = (list, selected) => (list || []).map((o) => ({ value: o.value, label: o.label, selected: o.value === selected }));

/**
 * The full customer or supplier form: basic details, address, tax, terms, accounting and payment.
 * Opens empty for a new contact (optionally prefilled from quick add) or loaded for an edit. Control account and
 * payment term default from company setup, so most users only type a name. A similar existing contact is shown as a
 * warning with "Save anyway". Fires saved { profileId } and close.
 */
export default class SabContactForm extends LightningElement {
    @api companyId;
    @api kind = 'customer';
    @api profileId;
    @api prefill;

    isOpen = false;
    loading = false;
    saving = false;
    options;
    form = {};
    formError;
    duplicateWarning;
    requestKey;

    @api
    get open() {
        return this.isOpen;
    }
    set open(value) {
        const next = Boolean(value);
        if (next && !this.isOpen) {
            this.isOpen = true;
            this.start();
        } else if (!next) {
            this.isOpen = false;
        }
    }

    async start() {
        this.loading = true;
        this.formError = undefined;
        this.duplicateWarning = undefined;
        this.requestKey = newKey('CONTACT', this.profileId || this.companyId);
        try {
            const [options, detail] = await Promise.all([getFormOptions({ companyId: this.companyId }),
                this.profileId ? getContact({ profileId: this.profileId }) : Promise.resolve(undefined)]);
            this.options = options;
            const customer = this.kind !== 'supplier';
            const p = this.prefill || {};
            this.form = detail ? { ...detail.contact } : {
                name: p.name || '', email: p.email || '', isCustomer: customer, isSupplier: !customer, currencyCode: '', creditLimit: null,
                arControlId: options.defaultArControlId || '', apControlId: options.defaultApControlId || '', paymentTermId: options.defaultPaymentTermId || ''
            };
        } catch (error) {
            this.formError = reduceError(error);
        } finally {
            this.loading = false;
        }
    }

    get heading() {
        const noun = this.kind === 'supplier' ? 'supplier' : 'customer';
        return this.profileId ? `Edit ${noun}` : `New ${noun}`;
    }

    get subheading() {
        return 'Only the name is required. Control account, payment term and currency come from company setup.';
    }

    get ready() {
        return Boolean(this.options) && !this.loading;
    }

    get isCustomer() {
        return this.form.isCustomer === true;
    }

    get isSupplier() {
        return this.form.isSupplier === true;
    }

    get currencyPlaceholder() {
        return `${(this.options && this.options.functionalCurrency) || ''} (company currency)`;
    }

    get arOptions() {
        return opts(this.options && this.options.arControls, this.form.arControlId);
    }

    get apOptions() {
        return opts(this.options && this.options.apControls, this.form.apControlId);
    }

    get revenueOptions() {
        return opts(this.options && this.options.revenueAccounts, this.form.revenueAccountId);
    }

    get expenseOptions() {
        return opts(this.options && this.options.expenseAccounts, this.form.expenseAccountId);
    }

    get taxOptions() {
        return opts(this.options && this.options.taxCodes, this.form.taxCodeId);
    }

    get termOptions() {
        return opts(this.options && this.options.paymentTerms, this.form.paymentTermId);
    }

    get methodOptions() {
        return ((this.options && this.options.paymentMethods) || []).map((m) => ({ value: m, label: m, selected: m === this.form.paymentMethod }));
    }

    get saveDisabled() {
        return this.saving || !(this.options && this.options.canManage);
    }

    get saveTitle() {
        return this.options && !this.options.canManage ? 'Needs the SAB Manage Contacts Action permission set' : undefined;
    }

    handleField(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        this.form = { ...this.form, [field]: value };
        this.duplicateWarning = undefined;
    }

    handleClose() {
        if (!this.saving) {
            this.isOpen = false;
            this.dispatchEvent(new CustomEvent('close'));
        }
    }

    handleSave() {
        this.save(false);
    }

    handleSaveAnyway() {
        this.save(true);
    }

    async save(confirmDuplicate) {
        const f = this.form;
        const request = {
            profileId: this.profileId || null, companyId: this.companyId, name: f.name, displayName: f.displayName || null, email: f.email || null,
            phone: f.phone || null, billingStreet: f.billingStreet || null, billingCity: f.billingCity || null, billingState: f.billingState || null,
            billingPostalCode: f.billingPostalCode || null, billingCountry: f.billingCountry || null, shippingStreet: f.shippingStreet || null,
            shippingCity: f.shippingCity || null, shippingState: f.shippingState || null, shippingPostalCode: f.shippingPostalCode || null,
            shippingCountry: f.shippingCountry || null, taxNumber: f.taxNumber || null, taxCodeId: f.taxCodeId || null, paymentTermId: f.paymentTermId || null,
            currencyCode: f.currencyCode || null, creditLimit: f.creditLimit === '' || f.creditLimit === null || f.creditLimit === undefined ? null : Number(f.creditLimit),
            isCustomer: f.isCustomer === true, isSupplier: f.isSupplier === true, arControlId: f.arControlId || null, apControlId: f.apControlId || null,
            revenueAccountId: f.revenueAccountId || null, expenseAccountId: f.expenseAccountId || null, paymentMethod: f.paymentMethod || null,
            bankAccountName: f.bankAccountName || null, bankAccountNumber: f.bankAccountNumber || null, bankRoutingCode: f.bankRoutingCode || null
        };
        this.saving = true;
        this.formError = undefined;
        try {
            const result = await saveContact({ request, confirmDuplicate, requestKey: this.requestKey });
            if (result.duplicateWarning) {
                this.duplicateWarning = result.duplicateWarning;
                return;
            }
            toast(this, `${f.name} saved`);
            this.isOpen = false;
            this.dispatchEvent(new CustomEvent('saved', { detail: { profileId: result.profileId } }));
        } catch (error) {
            this.formError = reduceError(error);
        } finally {
            this.saving = false;
        }
    }
}