import { LightningElement, api } from 'lwc';
import getContacts from '@salesforce/apex/SABContactService.getContacts';
import getContact from '@salesforce/apex/SABContactService.getContact';
import setActive from '@salesforce/apex/SABContactService.setActive';
import { formatNumber, formatDate, chipClass } from 'c/sabFormat';
import { reduceError, newKey, toast } from 'c/sabMoneyShared';

const FILTERS = [['active', 'Active'], ['inactive', 'Inactive'], ['all', 'All']];
const TABS = [['info', 'Contact'], ['docs', 'Documents'], ['payments', 'Payments'], ['statement', 'Statement']];

/**
 * The Customers or Suppliers list: search, Active / Inactive / All, outstanding and overdue balances, Edit and
 * Deactivate on each row, and a detail panel with contact info, documents, payments and a running statement.
 * Contacts are never deleted; deactivated ones leave the document dropdowns but stay on old documents and reports.
 */
export default class SabContacts extends LightningElement {
    @api kind = 'customer';
    @api companyName;

    data;
    errorMessage;
    isLoading = false;
    search = '';
    filter = 'active';
    selectedId;
    detail;
    detailError;
    tab = 'info';
    formOpen = false;
    formProfileId;
    busy = false;
    loadSequence = 0;
    currentCompanyId;
    openId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            if (this.currentCompanyId) {
                // A different company: close any open contact from the previous one.
                this.selectedId = undefined;
            }
            this.currentCompanyId = value;
            this.load();
        }
    }

    /** A contact opened from search or another workspace. */
    @api
    get recordId() {
        return this.openId;
    }
    set recordId(value) {
        this.openId = value;
        if (value) {
            this.openDetail(value);
        }
    }

    get noun() {
        return this.kind === 'supplier' ? 'supplier' : 'customer';
    }

    get plural() {
        return this.kind === 'supplier' ? 'suppliers' : 'customers';
    }

    async load() {
        const companyId = this.currentCompanyId;
        const sequence = ++this.loadSequence;
        if (!companyId) {
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const data = await getContacts({ companyId, kind: this.kind });
            if (sequence === this.loadSequence) {
                this.data = data;
            }
        } catch (error) {
            if (sequence === this.loadSequence) {
                this.errorMessage = reduceError(error);
            }
        } finally {
            if (sequence === this.loadSequence) {
                this.isLoading = false;
            }
        }
    }

    get loaded() {
        return Boolean(this.data) && !this.errorMessage;
    }

    get canManage() {
        return Boolean(this.data && this.data.canManage);
    }

    get newDisabled() {
        return !this.canManage;
    }

    get newTitle() {
        return this.canManage ? undefined : 'Needs the SAB Manage Contacts Action permission set';
    }

    get newLabel() {
        return `New ${this.noun}`;
    }

    get cur() {
        return (this.data && this.data.functionalCurrency) || '';
    }

    get filterButtons() {
        return FILTERS.map(([id, label]) => ({ id, label, className: id === this.filter ? 'on' : '', pressed: id === this.filter ? 'true' : 'false' }));
    }

    get rows() {
        const q = this.search.trim().toLowerCase();
        return ((this.data && this.data.rows) || [])
            .filter((r) => this.filter === 'all' || (this.filter === 'active' ? r.active : !r.active))
            .filter((r) => !q || [r.name, r.displayName, r.email, r.phone].some((v) => v && v.toLowerCase().includes(q)))
            .map((r) => ({
                ...r,
                contactText: [r.email, r.phone].filter(Boolean).join(' \u00b7 ') || '\u2014',
                outstandingText: formatNumber(r.outstanding),
                overdueText: formatNumber(r.overdue),
                overdueClass: r.overdue > 0 ? 'n num down' : 'n num',
                bothText: r.isCustomer && r.isSupplier ? 'Customer and supplier' : '',
                chip: chipClass(r.active ? 'Active' : 'Inactive', r.active ? 'good' : 'neutral'),
                statusText: r.active ? 'Active' : 'Inactive',
                toggleLabel: r.active ? 'Deactivate' : 'Reactivate',
                rowClass: r.profileId === this.selectedId ? 'click sel' : 'click'
            }));
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get emptyText() {
        if (this.search.trim()) {
            return `No ${this.plural} match "${this.search.trim()}".`;
        }
        return this.filter === 'inactive' ? `No inactive ${this.plural}.` : `No ${this.plural} yet. Use ${this.newLabel} to add one.`;
    }

    get summary() {
        const rows = (this.data && this.data.rows) || [];
        const active = rows.filter((r) => r.active).length;
        const owed = rows.reduce((s, r) => s + (Number(r.outstanding) || 0), 0);
        return `${active} active ${active === 1 ? this.noun : this.plural}, ${formatNumber(owed)} ${this.cur} outstanding`;
    }

    handleSearch(event) {
        this.search = event.target.value || '';
    }

    handleFilter(event) {
        this.filter = event.currentTarget.dataset.id;
    }

    handleRow(event) {
        if (event.type === 'keydown' && event.key !== 'Enter' && event.key !== ' ') {
            return;
        }
        this.openDetail(event.currentTarget.dataset.id);
    }

    async openDetail(profileId) {
        this.selectedId = profileId;
        this.tab = 'info';
        this.detail = undefined;
        this.detailError = undefined;
        try {
            this.detail = await getContact({ profileId });
        } catch (error) {
            this.detailError = reduceError(error);
        }
    }

    get drawerOpen() {
        return Boolean(this.selectedId);
    }

    get drawerTitle() {
        return this.detail ? this.detail.contact.name : this.noun.replace(/^./, (c) => c.toUpperCase());
    }

    get drawerSub() {
        if (!this.detail) {
            return '';
        }
        const c = this.detail.contact;
        const roles = [c.isCustomer ? 'Customer' : '', c.isSupplier ? 'Supplier' : ''].filter(Boolean).join(' and ');
        return `${roles}${this.detail.active ? '' : ', inactive'}`;
    }

    handleCloseDrawer() {
        this.selectedId = undefined;
        this.detail = undefined;
    }

    get tabs() {
        return TABS.map(([id, label]) => ({ id, label: id === 'docs' ? (this.kind === 'supplier' ? 'Bills' : 'Invoices') : label,
            className: id === this.tab ? 'tab active' : 'tab', selected: id === this.tab ? 'true' : 'false' }));
    }

    handleTab(event) {
        this.tab = event.currentTarget.dataset.id;
    }

    get isInfo() {
        return this.tab === 'info';
    }

    get isDocs() {
        return this.tab === 'docs';
    }

    get isPayments() {
        return this.tab === 'payments';
    }

    get isStatement() {
        return this.tab === 'statement';
    }

    get infoFacts() {
        const d = this.detail;
        if (!d) {
            return [];
        }
        const c = d.contact;
        const address = [c.billingStreet, c.billingCity, c.billingState, c.billingPostalCode, c.billingCountry].filter(Boolean).join(', ');
        const shipping = [c.shippingStreet, c.shippingCity, c.shippingState, c.shippingPostalCode, c.shippingCountry].filter(Boolean).join(', ');
        const facts = [['Display name', c.displayName], ['Email', c.email], ['Phone', c.phone], ['Billing address', address],
            ...(c.isCustomer ? [['Shipping address', shipping], ['Credit limit', c.creditLimit === null || c.creditLimit === undefined ? '' : formatNumber(c.creditLimit)]] : []),
            ['Tax number', c.taxNumber], ['Default tax code', d.taxCodeName], ['Payment term', d.paymentTermName], ['Currency', c.currencyCode || this.cur],
            ['Preferred payment method', c.paymentMethod],
            ...(c.isSupplier ? [['Bank account', [c.bankAccountName, c.bankRoutingCode, c.bankAccountNumber].filter(Boolean).join(' \u00b7 ')]] : [])];
        return facts.map(([label, value]) => ({ key: label, valueKey: `${label}-v`, label, value: value || '\u2014' }));
    }

    mapDocs(list) {
        return (list || []).map((x) => ({ ...x, key: x.recordId, dateText: formatDate(x.documentDate), dueText: x.dueDate ? formatDate(x.dueDate) : '',
            amountText: formatNumber(x.amount), chip: chipClass(x.status) }));
    }

    get documents() {
        return this.mapDocs(this.detail && this.detail.documents);
    }

    get payments() {
        return this.mapDocs(this.detail && this.detail.payments);
    }

    get statement() {
        return ((this.detail && this.detail.statement) || []).map((s, i) => ({ ...s, key: `s${i}`, dateText: formatDate(s.entryDate),
            chargeText: s.charge ? formatNumber(s.charge) : '', paidText: s.paid ? formatNumber(s.paid) : '', balanceText: formatNumber(s.balance) }));
    }

    get hasDocuments() {
        return this.documents.length > 0;
    }

    get hasPayments() {
        return this.payments.length > 0;
    }

    get hasStatement() {
        return this.statement.length > 0;
    }

    handleOpenDocument(event) {
        const workspace = this.tab === 'payments' ? 'payments' : this.kind === 'supplier' ? 'purchases' : 'sales';
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace, recordId: event.currentTarget.dataset.id }, bubbles: true, composed: true }));
    }

    // ---------- form and status ----------

    handleNew() {
        this.formProfileId = undefined;
        this.formOpen = true;
    }

    handleEdit(event) {
        event.stopPropagation();
        this.formProfileId = event.currentTarget.dataset.id || this.selectedId;
        this.formOpen = true;
    }

    handleFormClose() {
        this.formOpen = false;
    }

    async handleFormSaved(event) {
        this.formOpen = false;
        await this.load();
        if (this.selectedId || !this.formProfileId) {
            await this.openDetail(event.detail.profileId);
        }
    }

    async handleToggle(event) {
        event.stopPropagation();
        const profileId = event.currentTarget.dataset.id || this.selectedId;
        const row = ((this.data && this.data.rows) || []).find((r) => r.profileId === profileId);
        const activate = !(row ? row.active : this.detail && this.detail.active);
        this.busy = true;
        try {
            await setActive({ profileId, active: activate, requestKey: newKey(activate ? 'CONTACT-ON' : 'CONTACT-OFF', profileId) });
            toast(this, activate ? 'Reactivated' : 'Deactivated. It no longer appears in document dropdowns.');
            await this.load();
            if (this.selectedId === profileId) {
                await this.openDetail(profileId);
            }
        } catch (error) {
            toast(this, reduceError(error), 'bad');
        } finally {
            this.busy = false;
        }
    }

    get detailToggleLabel() {
        return this.detail && this.detail.active ? 'Deactivate' : 'Reactivate';
    }

    handleRetry() {
        this.load();
    }
}