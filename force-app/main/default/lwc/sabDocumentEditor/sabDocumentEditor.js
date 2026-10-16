import { LightningElement, api } from 'lwc';
import getEntryOptions from '@salesforce/apex/SABDocumentEntryService.getEntryOptions';
import getDraft from '@salesforce/apex/SABDocumentEntryService.getDraft';
import saveInvoice from '@salesforce/apex/SABDocumentEntryService.saveInvoice';
import saveBill from '@salesforce/apex/SABDocumentEntryService.saveBill';
import savePayment from '@salesforce/apex/SABDocumentEntryService.savePayment';
import saveExpenseClaim from '@salesforce/apex/SABDocumentEntryService.saveExpenseClaim';
import quickAddParty from '@salesforce/apex/SABContactService.quickAdd';
import { formatNumber } from 'c/sabFormat';
import { reduceError, newKey, todayIso, toast } from 'c/sabMoneyShared';

const KINDS = {
    invoice: { title: 'Invoice', party: 'Customer', partyList: 'customers', accounts: 'revenueAccounts', accountLabel: 'Revenue account', documentType: 'Invoice' },
    credit: { title: 'Credit note', party: 'Customer', partyList: 'customers', accounts: 'revenueAccounts', accountLabel: 'Revenue account', documentType: 'Credit Note' },
    bill: { title: 'Supplier bill', party: 'Supplier', partyList: 'suppliers', accounts: 'expenseAccounts', accountLabel: 'Expense or asset account', documentType: 'Bill' },
    supplierCredit: { title: 'Supplier credit', party: 'Supplier', partyList: 'suppliers', accounts: 'expenseAccounts', accountLabel: 'Expense or asset account', documentType: 'Supplier Credit' },
    receipt: { title: 'Receipt', party: 'Customer', partyList: 'customers', direction: 'Receipt', payment: true },
    payment: { title: 'Supplier payment', party: 'Supplier', partyList: 'suppliers', direction: 'Disbursement', payment: true },
    claim: { title: 'Expense claim', accounts: 'expenseAccounts', accountLabel: 'Expense account', claim: true }
};

let lineSequence = 0;
const blankLine = () => ({ key: `d${++lineSequence}`, description: '', quantity: '1', unitPrice: '', discount: '', amount: '', accountId: '', taxCodeId: '', departmentId: '',
    costCenterId: '', projectId: '', category: '', expenseDate: '' });

function addDays(iso, days) {
    const d = new Date(`${iso}T00:00:00`);
    d.setDate(d.getDate() + days);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/**
 * Draft document entry (G22G-3b): one modal for invoices, credit notes, supplier bills and credits, receipts, supplier
 * payments and expense claims, header and lines, saved through SABDocumentEntryService. Fires "saved" with the record id.
 */
export default class SabDocumentEditor extends LightningElement {
    @api companyId;
    @api kind = 'invoice';
    @api recordId;
    /** Optional currency for a new payment or receipt, such as a foreign currency from Foreign exchange. */
    @api defaultCurrency;

    options;
    form = {};
    lines = [];
    formError;
    loading = false;
    saving = false;
    requestKey;
    loadedType;
    partyFormOpen = false;
    newPartyEmail = '';
    partyDuplicate;
    detailsOpen = false;
    detailsPrefill;
    newPartyName = '';
    partyError;
    partySaving = false;
    isOpen = false;

    @api
    get open() {
        return this.isOpen;
    }
    set open(value) {
        const next = value === true || value === 'true';
        const opening = next && !this.isOpen;
        this.isOpen = next;
        if (opening) {
            this.start();
        }
    }

    get config() {
        return KINDS[this.kind] || KINDS.invoice;
    }

    async start() {
        this.formError = undefined;
        this.partyFormOpen = false;
        this.loadedType = undefined;
        this.loading = true;
        this.requestKey = newKey(`DOC-${this.kind}`, this.recordId);
        try {
            this.options = await getEntryOptions({ companyId: this.companyId });
            if (this.recordId) {
                this.fromDraft(await getDraft({ companyId: this.companyId, recordId: this.recordId }));
            } else {
                this.blank();
            }
        } catch (error) {
            this.formError = reduceError(error);
        } finally {
            this.loading = false;
        }
    }

    blank() {
        const today = todayIso();
        const party = ((this.options[this.config.partyList] || [])[0] || {}).value || '';
        this.form = { partyProfileId: party, documentDate: today, dueDate: addDays(today, 30), reference: '', originalInvoiceId: '', currencyCode: this.defaultCurrency || this.options.currencyCode,
            exchangeRate: '', bankAccountId: ((this.options.bankAccounts || [])[0] || {}).value || '', amount: '', effectiveDate: today,
            method: ((this.options.methods || [])[0] || {}).value || '', employmentId: this.options.myEmploymentId || ((this.options.employments || [])[0] || {}).value || '' };
        this.lines = [blankLine()];
    }

    fromDraft(view) {
        const str = (v) => (v === null || v === undefined ? '' : String(v));
        if (view.payment) {
            const p = view.payment;
            this.form = { partyProfileId: str(p.partyProfileId), bankAccountId: str(p.bankAccountId), amount: str(p.amount), effectiveDate: p.effectiveDate, method: str(p.method),
                reference: str(p.reference), currencyCode: p.currencyCode, exchangeRate: str(p.exchangeRate) };
            this.lines = [];
            return;
        }
        if (view.claim) {
            const c = view.claim;
            this.form = { employmentId: str(c.employmentId), documentDate: c.claimDate, currencyCode: c.currencyCode };
            this.lines = (c.lines || []).map((l) => ({ ...blankLine(), description: str(l.description), amount: str(l.amount), accountId: str(l.accountId),
                taxCodeId: str(l.taxCodeId), departmentId: str(l.departmentId), projectId: str(l.projectId), category: str(l.category), expenseDate: str(l.expenseDate) }));
            return;
        }
        const d = view.document;
        this.loadedType = d.documentType;
        this.form = { partyProfileId: str(d.partyProfileId), documentDate: d.documentDate, dueDate: d.dueDate, reference: str(d.reference),
            originalInvoiceId: str(d.originalInvoiceId), currencyCode: d.currencyCode, exchangeRate: str(d.exchangeRate) };
        this.lines = (d.lines || []).map((l) => ({ ...blankLine(), description: str(l.description), quantity: str(l.quantity), unitPrice: str(l.unitPrice), discount: str(l.discount),
            accountId: str(l.accountId), taxCodeId: str(l.taxCodeId), departmentId: str(l.departmentId), costCenterId: str(l.costCenterId), projectId: str(l.projectId) }));
    }

    // ---------- view ----------

    get heading() {
        return `${this.recordId ? 'Edit' : 'New'} ${this.config.title.toLowerCase()}`;
    }

    get subheading() {
        if (this.config.payment) {
            return 'Saved as Draft. Authorise and release it from Payments.';
        }
        if (this.config.claim) {
            return 'Saved as Draft. Submit it for review from Expense claims.';
        }
        return 'Saved as Draft with tax calculated from the tax codes. Submit it for approval next.';
    }

    get isPayment() {
        return Boolean(this.config.payment);
    }

    get isClaim() {
        return Boolean(this.config.claim);
    }

    get isDocument() {
        return !this.isPayment && !this.isClaim;
    }

    get isCredit() {
        return this.kind === 'credit';
    }

    get isBillKind() {
        return this.kind === 'bill' || this.kind === 'supplierCredit';
    }

    get showDiscount() {
        return this.kind === 'invoice' || this.kind === 'credit';
    }

    get showProjects() {
        return Boolean(this.options && (this.options.projects || []).length);
    }

    get showCostCenter() {
        return !this.isClaim;
    }

    get noEmployees() {
        return this.isClaim && Boolean(this.options) && !(this.options.employments || []).length;
    }

    handleOpenPeople() {
        this.dispatchEvent(new CustomEvent('close'));
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'payroll', recordId: 'staff' }, bubbles: true, composed: true }));
    }

    /** Invoices, credit notes, bills and claims have a line table; payments and receipts are a short form. */
    get modalSize() {
        return this.isPayment ? 'default' : 'wide';
    }

    get partyLabel() {
        return this.config.party;
    }
    get partyLabelLower() {
    return (this.partyLabel || '').toLowerCase();
}

    get accountLabel() {
        return this.config.accountLabel;
    }

    get foreign() {
        return Boolean(this.options && this.form.currencyCode && this.form.currencyCode.toUpperCase() !== this.options.currencyCode);
    }

    choices(list, selected) {
        return (list || []).map((o) => ({ value: o.value, label: o.label, selected: o.value === selected }));
    }

    get partyOptions() {
        return this.choices(this.options && this.options[this.config.partyList], this.form.partyProfileId);
    }

    get creditOptions() {
        return ((this.options && this.options.creditableInvoices) || [])
            .map((o) => {
                const [label, party] = o.label.split('|');
                return { value: o.value, label, party, selected: o.value === this.form.originalInvoiceId };
            })
            .filter((o) => !this.form.partyProfileId || o.party === this.form.partyProfileId);
    }

    get bankOptions() {
        return this.choices(this.options && this.options.bankAccounts, this.form.bankAccountId);
    }

    get methodOptions() {
        return this.choices(this.options && this.options.methods, this.form.method);
    }

    get employmentOptions() {
        return this.choices(this.options && this.options.employments, this.form.employmentId);
    }

    get lineRows() {
        const o = this.options || {};
        return this.lines.map((l, i) => {
            const qty = Number(l.quantity) || 0;
            const net = this.isClaim ? Number(l.amount) || 0 : qty * (Number(l.unitPrice) || 0) - (Number(l.discount) || 0);
            return {
                ...l,
                index: i,
                netText: formatNumber(net),
                accountOptions: this.choices(o[this.config.accounts], l.accountId),
                taxOptions: this.choices(o.taxCodes, l.taxCodeId),
                departmentOptions: this.choices(o.departments, l.departmentId),
                costCenterOptions: this.choices(o.costCenters, l.costCenterId),
                projectOptions: this.choices(o.projects, l.projectId)
            };
        });
    }

    get netTotal() {
        return formatNumber(this.lines.reduce((s, l) => s + (this.isClaim ? Number(l.amount) || 0
            : (Number(l.quantity) || 0) * (Number(l.unitPrice) || 0) - (Number(l.discount) || 0)), 0));
    }

    get totalLabel() {
        return this.isClaim ? 'Total' : 'Net before tax';
    }

    get saveDisabled() {
        return this.saving || this.loading || !this.options;
    }

    // ---------- new customer or supplier ----------

    get newPartyLabel() {
        return `New ${this.config.party ? this.config.party.toLowerCase() : 'party'}`;
    }

    get addPartyLabel() {
        return `Add new ${this.partyLabelLower || 'party'}`;
    }

    /** A party chosen in the payment and receipt picker. */
    handlePartyPick(event) {
        this.form = { ...this.form, partyProfileId: event.detail.value };
    }

    /** The picker's pinned "Add new customer/supplier" row: open the Name + Add row. */
    handleAddNewParty() {
        if (!this.partyFormOpen) {
            this.handleTogglePartyForm();
        }
    }

    handleTogglePartyForm() {
        this.partyFormOpen = !this.partyFormOpen;
        this.partyError = undefined;
        this.partyDuplicate = undefined;
        this.newPartyName = '';
        this.newPartyEmail = '';
    }

    handlePartyName(event) {
        this.newPartyName = event.target.value;
    }

    handlePartyEmail(event) {
        this.newPartyEmail = event.target.value;
    }

    get partyKind() {
        return this.config.partyList === 'suppliers' ? 'supplier' : 'customer';
    }

    handleSaveParty() {
        this.quickAdd(false);
    }

    handleSavePartyAnyway() {
        this.quickAdd(true);
    }

    /** Quick add: a name and optional email; control account, payment term and currency come from company setup. */
    async quickAdd(confirmDuplicate) {
        if (this.partySaving) {
            return;
        }
        const supplier = this.partyKind === 'supplier';
        this.partySaving = true;
        this.partyError = undefined;
        try {
            const result = await quickAddParty({ companyId: this.companyId, name: this.newPartyName, email: this.newPartyEmail || null,
                isCustomer: !supplier, isSupplier: supplier, confirmDuplicate, requestKey: newKey('PARTY', this.companyId) });
            if (result.duplicateWarning) {
                this.partyDuplicate = result.duplicateWarning;
                return;
            }
            await this.selectNewParty(result.profileId);
            toast(this, `${this.newPartyName} added`);
        } catch (error) {
            this.partyError = reduceError(error);
        } finally {
            this.partySaving = false;
        }
    }

    async selectNewParty(profileId) {
        this.options = await getEntryOptions({ companyId: this.companyId });
        this.form = { ...this.form, partyProfileId: profileId };
        this.partyFormOpen = false;
        this.partyDuplicate = undefined;
    }

    /** "Add more details": the full customer or supplier form, prefilled with what was typed. */
    handleMoreDetails() {
        this.detailsPrefill = { name: this.newPartyName, email: this.newPartyEmail };
        this.detailsOpen = true;
    }

    handleDetailsClose() {
        this.detailsOpen = false;
    }

    async handleDetailsSaved(event) {
        this.detailsOpen = false;
        await this.selectNewParty(event.detail.profileId);
    }

    // ---------- input ----------

    handleField(event) {
        const field = event.target.dataset.field;

        // "+ Add new customer/supplier" picked from the dropdown
        if (field === 'partyProfileId' && event.target.value === '__new__') {
            event.target.value = this.form.partyProfileId || ''; // keep the previous selection, never save "__new__"
            if (!this.partyFormOpen) {
                this.handleTogglePartyForm(); // opens the Name + Add row
            }
            return;
        }

        const form = { ...this.form, [field]: event.target.value };
        if (field === 'documentDate' && this.isDocument && this.form.dueDate === addDays(this.form.documentDate, 30)) {
            form.dueDate = addDays(event.target.value, 30);
        }
        this.form = form;
    }

    handleLine(event) {
        const index = Number(event.target.dataset.index);
        const field = event.target.dataset.field;
        this.lines = this.lines.map((l, i) => (i === index ? { ...l, [field]: event.target.value } : l));
    }

    handleAddLine() {
        this.lines = [...this.lines, blankLine()];
    }

    handleRemoveLine(event) {
        const index = Number(event.currentTarget.dataset.index);
        this.lines = this.lines.filter((l, i) => i !== index);
    }

    handleClose() {
        if (!this.saving) {
            this.dispatchEvent(new CustomEvent('close'));
        }
    }

    num(v) {
        return v === '' || v === undefined || v === null ? null : Number(v);
    }

    lineRequests() {
        return this.lines.filter((l) => l.description || l.unitPrice || l.amount || l.accountId).map((l) => ({
            description: l.description || null, quantity: this.num(l.quantity), unitPrice: this.num(l.unitPrice), discount: this.num(l.discount), amount: this.num(l.amount),
            accountId: l.accountId || null, taxCodeId: l.taxCodeId || null, departmentId: l.departmentId || null, costCenterId: l.costCenterId || null,
            projectId: l.projectId || null,
            category: l.category || null, expenseDate: l.expenseDate || null
        }));
    }

    async handleSave() {
        if (this.saveDisabled) {
            return;
        }
        const f = this.form;
        const requestKey = this.requestKey;
        const companyId = this.companyId;
        const recordId = this.recordId || null;
        this.saving = true;
        this.formError = undefined;
        try {
            let id;
            if (this.isPayment) {
                id = await savePayment({ request: { recordId, companyId, direction: this.config.direction, partyProfileId: f.partyProfileId || null,
                    bankAccountId: f.bankAccountId || null, amount: this.num(f.amount), effectiveDate: f.effectiveDate || null, method: f.method || null,
                    reference: f.reference || null, currencyCode: f.currencyCode || null, exchangeRate: this.num(f.exchangeRate) }, requestKey });
            } else if (this.isClaim) {
                id = await saveExpenseClaim({ request: { recordId, companyId, employmentId: f.employmentId || null, claimDate: f.documentDate || null,
                    currencyCode: f.currencyCode || null, lines: this.lineRequests() }, requestKey });
            } else {
                const request = { recordId, companyId, documentType: this.loadedType || this.config.documentType, partyProfileId: f.partyProfileId || null, documentDate: f.documentDate || null,
                    dueDate: f.dueDate || null, reference: f.reference || null, originalInvoiceId: f.originalInvoiceId || null, currencyCode: f.currencyCode || null,
                    exchangeRate: this.num(f.exchangeRate), lines: this.lineRequests() };
                id = this.isBillKind ? await saveBill({ request, requestKey }) : await saveInvoice({ request, requestKey });
            }
            toast(this, `${this.config.title} saved as draft`);
            this.dispatchEvent(new CustomEvent('saved', { detail: { recordId: id, kind: this.kind } }));
            this.dispatchEvent(new CustomEvent('close'));
        } catch (error) {
            this.formError = reduceError(error);
        } finally {
            this.saving = false;
        }
    }
}
