import { LightningElement, api } from 'lwc';
import getSetupRecords from '@salesforce/apex/SABSetupRecordService.getSetupRecords';
import canManageSetup from '@salesforce/apex/SABSetupRecordService.canManageSetup';
import createCompany from '@salesforce/apex/SABSetupRecordService.createCompany';
import saveCompany from '@salesforce/apex/SABSetupRecordService.saveCompany';
import savePeriod from '@salesforce/apex/SABSetupRecordService.savePeriod';
import saveAccount from '@salesforce/apex/SABSetupRecordService.saveAccount';
import saveSequence from '@salesforce/apex/SABSetupRecordService.saveSequence';
import saveFeature from '@salesforce/apex/SABSetupRecordService.saveFeature';
import getSetupOptions from '@salesforce/apex/SABSetupActionService.getOptions';
import generatePeriods from '@salesforce/apex/SABSetupActionService.generatePeriods';
import { formatDate } from 'c/sabFormat';

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
    .map((label, i) => ({ value: String(i + 1), label }));
const FEATURES = ['PAYROLL', 'FIXED_ASSETS', 'BUDGETS', 'PURCHASING', 'PROJECTS', 'EQUITY', 'LOANS_INVESTMENTS', 'GROUP_ACCOUNTING'];
const opts = (list) => list.map((v) => (typeof v === 'string' ? { value: v, label: v } : v));

const PROFILE_FIELDS = [
    { name: 'name', label: 'Company name', type: 'text', required: true },
    { name: 'countryCode', label: 'Country code', type: 'text', required: true, hint: 'Two letters, for example AU' },
    { name: 'functionalCurrency', label: 'Functional currency', type: 'text', required: true, hint: 'Three letters, for example AUD' },
    { name: 'fiscalYearStartMonth', label: 'Fiscal year starts', type: 'select', numeric: true, options: MONTHS, required: true },
    { name: 'fiscalCalendarType', label: 'Fiscal calendar', type: 'select', options: opts(['Calendar', 'Custom']) }
];

const PATTERNS = opts(['Monthly', '4-4-5 weeks', '4-5-4 weeks', '5-4-4 weeks', '13 periods of 4 weeks']);
const isCustom = (form) => form.fiscalCalendarType === 'Custom';

/** Extra inputs on New accounting company: periods for the first fiscal year, with the custom calendar choices. */
const FIRST_YEAR_FIELDS = [
    { name: 'createPeriods', label: 'Create the first fiscal year of periods', type: 'checkbox', extra: true },
    { name: 'firstDay', label: 'First day of the fiscal year', type: 'date', extra: true, required: true,
        showWhen: (form) => form.createPeriods === true && isCustom(form), hint: 'Custom years can start on any day' },
    { name: 'periodPattern', label: 'Period pattern', type: 'select', extra: true, options: PATTERNS,
        showWhen: (form) => form.createPeriods === true && isCustom(form), hint: 'Monthly, three 4-4-5 style quarters, or 13 four-week periods' }
];

/** The Generate fiscal year form on Accounting periods. */
const GENERATE_FIELDS = [
    { name: 'firstDay', label: 'First day of the fiscal year', type: 'date', required: true, hint: 'Defaults to the day after the last period' },
    { name: 'periodPattern', label: 'Period pattern', type: 'select', options: PATTERNS }
];

/** First day of the fiscal year that contains today, for a calendar company starting in startMonth. */
function fiscalYearStart(startMonth) {
    const today = new Date();
    let year = today.getFullYear();
    if (today.getMonth() + 1 < startMonth) {
        year -= 1;
    }
    return `${year}-${String(startMonth).padStart(2, '0')}-01`;
}

const KINDS = {
    newCompany: {
        title: 'New accounting company',
        sub: 'You become its finance manager. Set up periods, accounts and numbering next.',
        single: true,
        fields: [{ name: 'companyKey', label: 'Company key', type: 'text', required: true, hint: 'Short unique code, for example HLT-AU' },
            ...PROFILE_FIELDS, ...FIRST_YEAR_FIELDS],
        save: (request, requestKey) => createCompany({ request, requestKey }),
        saved: 'Accounting company created'
    },
    company: {
        title: 'Company profile',
        sub: 'Validated or Active needs a passing core setup check.',
        single: true,
        fields: [...PROFILE_FIELDS,
            { name: 'setupStatus', label: 'Setup status', type: 'select', options: opts(['Not Started', 'In Progress', 'Validated', 'Active', 'Suspended']) },
            { name: 'isActive', label: 'Active', type: 'checkbox' }],
        fromRecord: (r) => ({ companyId: r.Id, companyKey: r.Company_Key__c, name: r.Name__c, countryCode: r.Country_Code__c,
            functionalCurrency: r.Functional_Currency__c, fiscalYearStartMonth: r.Fiscal_Year_Start_Month__c === undefined ? '' : String(r.Fiscal_Year_Start_Month__c),
            fiscalCalendarType: r.Fiscal_Calendar_Type__c, setupStatus: r.Setup_Status__c, isActive: r.Is_Active__c === true }),
        save: (request, requestKey) => saveCompany({ request, requestKey }),
        saved: 'Company profile saved'
    },
    period: {
        title: 'Accounting periods',
        sub: 'At least one Open period is needed for core posting readiness.',
        idField: 'periodId',
        columns: [['Period_Key__c', 'Period'], ['Start_Date__c', 'Start', 'date'], ['End_Date__c', 'End', 'date'],
            ['Fiscal_Year__c', 'Fiscal year'], ['Period_Number__c', 'No.'], ['Status__c', 'Status']],
        fields: [{ name: 'periodKey', label: 'Period key', type: 'text', required: true, hint: 'For example FY27-P01' },
            { name: 'startDate', label: 'Start date', type: 'date', required: true },
            { name: 'endDate', label: 'End date', type: 'date', required: true },
            { name: 'fiscalYear', label: 'Fiscal year', type: 'number', required: true },
            { name: 'periodNumber', label: 'Period number', type: 'number', required: true },
            { name: 'fiscalQuarter', label: 'Fiscal quarter', type: 'number', hint: 'Worked out from the period number when blank' }],
        editable: (r) => r.Status__c === 'Open',
        lockedReason: 'Closed periods are changed through period reopen',
        fromRecord: (r) => ({ periodId: r.Id, periodKey: r.Period_Key__c, startDate: r.Start_Date__c, endDate: r.End_Date__c,
            fiscalYear: r.Fiscal_Year__c, periodNumber: r.Period_Number__c, fiscalQuarter: r.Fiscal_Quarter__c }),
        save: (request, requestKey) => savePeriod({ request, requestKey }),
        saved: 'Accounting period saved',
        canGenerate: true
    },
    account: {
        title: 'Chart of accounts',
        sub: 'Active GL accounts are required. Accounts with postings keep their type and code.',
        idField: 'accountId',
        columns: [['Account_Code__c', 'Code'], ['Name', 'Name'], ['Account_Type__c', 'Type'], ['Normal_Balance__c', 'Normal'],
            ['Control_Type__c', 'Control'], ['Is_Active__c', 'Active', 'bool']],
        fields: [{ name: 'code', label: 'Account code', type: 'text', required: true },
            { name: 'name', label: 'Account name', type: 'text', required: true },
            { name: 'accountType', label: 'Type', type: 'select', required: true, options: opts(['Asset', 'Liability', 'Equity', 'Revenue', 'Expense']) },
            { name: 'normalBalance', label: 'Normal balance', type: 'select', required: true, options: opts(['Debit', 'Credit']) },
            { name: 'controlType', label: 'Control type', type: 'select', options: opts(['None', 'AR', 'AP', 'Bank', 'Payroll', 'Tax', 'Equity', 'Other']) },
            { name: 'cashFlowCategory', label: 'Cash flow category', type: 'select', blank: true, options: opts(['Operating', 'Investing', 'Financing', 'Cash']) },
            { name: 'reportGroup', label: 'Report group', type: 'text' },
            { name: 'isControlAccount', label: 'Control account', type: 'checkbox' },
            { name: 'manualPostingAllowed', label: 'Manual posting allowed', type: 'checkbox' },
            { name: 'isActive', label: 'Active', type: 'checkbox' }],
        defaults: { controlType: 'None', manualPostingAllowed: true, isActive: true, normalBalance: 'Debit', accountType: 'Asset' },
        fromRecord: (r) => ({ accountId: r.Id, code: r.Account_Code__c, name: r.Name, accountType: r.Account_Type__c, normalBalance: r.Normal_Balance__c,
            controlType: r.Control_Type__c, cashFlowCategory: r.Cash_Flow_Category__c, reportGroup: r.Report_Group__c,
            isControlAccount: r.Is_Control_Account__c === true, manualPostingAllowed: r.Manual_Posting_Allowed__c === true, isActive: r.Is_Active__c === true }),
        save: (request, requestKey) => saveAccount({ request, requestKey }),
        saved: 'GL account saved'
    },
    sequence: {
        title: 'Document numbering',
        sub: 'Type, series and next number are fixed once the sequence exists; the sequence service issues numbers.',
        idField: 'sequenceId',
        columns: [['Document_Type__c', 'Document'], ['Fiscal_Series__c', 'Series'], ['Prefix__c', 'Prefix'], ['Minimum_Digits__c', 'Digits'],
            ['Next_Number__c', 'Next'], ['Is_Active__c', 'Active', 'bool']],
        fields: [{ name: 'documentType', label: 'Document type', type: 'select', required: true, createOnly: true,
            options: opts(['Invoice', 'Credit Note', 'Supplier Bill', 'Supplier Credit', 'Payment Receipt', 'Payment Disbursement', 'Purchase Order',
                'Expense Claim', 'Tax Return', 'Other']) },
            { name: 'fiscalSeries', label: 'Fiscal series', type: 'text', required: true, createOnly: true, hint: 'For example FY27' },
            { name: 'prefix', label: 'Prefix', type: 'text' },
            { name: 'minimumDigits', label: 'Minimum digits', type: 'number' },
            { name: 'nextNumber', label: 'Next number', type: 'number', required: true, createOnly: true },
            { name: 'isActive', label: 'Active', type: 'checkbox' }],
        defaults: { documentType: 'Invoice', nextNumber: '1', minimumDigits: '6', isActive: true },
        fromRecord: (r) => ({ sequenceId: r.Id, documentType: r.Document_Type__c, fiscalSeries: r.Fiscal_Series__c, prefix: r.Prefix__c,
            minimumDigits: r.Minimum_Digits__c, nextNumber: r.Next_Number__c, isActive: r.Is_Active__c === true }),
        save: (request, requestKey) => saveSequence({ request, requestKey }),
        saved: 'Document sequence saved'
    },
    feature: {
        title: 'Company features',
        sub: 'An enabled feature must reach Configuration Status Valid before core readiness passes.',
        idField: 'featureId',
        columns: [['Feature_Key__c', 'Feature'], ['Enabled__c', 'Enabled', 'bool'], ['Configuration_Status__c', 'Configuration']],
        fields: [{ name: 'featureKey', label: 'Feature', type: 'select', required: true, createOnly: true, options: opts(FEATURES) },
            { name: 'enabled', label: 'Enabled', type: 'checkbox' },
            { name: 'configurationStatus', label: 'Configuration status', type: 'select', options: opts(['Not Configured', 'In Progress', 'Valid', 'Blocked']) }],
        defaults: { featureKey: 'PAYROLL', enabled: true, configurationStatus: 'Not Configured' },
        fromRecord: (r) => ({ featureId: r.Id, featureKey: r.Feature_Key__c, enabled: r.Enabled__c === true, configurationStatus: r.Configuration_Status__c }),
        save: (request, requestKey) => saveFeature({ request, requestKey }),
        saved: 'Company feature saved'
    }
};

function reduceError(error) {
    if (!error) {
        return 'Something went wrong.';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return (error.body && error.body.message) || error.message || 'Something went wrong.';
}

function newKey(prefix) {
    const random = typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    return `SETUP-${prefix}-${random}`;
}

/**
 * In-app editor for company setup records (G22 setup): creates an Accounting Company, edits its profile, and lists,
 * creates and edits periods, GL accounts, document sequences and features through SABSetupRecordService, so the
 * setup wizard never leaves the Simple Accounting Books app. Fires "saved" (detail.recordId) and "close".
 */
export default class SabSetupRecords extends LightningElement {
    @api companyId;

    rows = [];
    view = 'list';
    form = {};
    formError;
    listError;
    saving = false;
    generating = false;
    canManage = false;
    isOpen = false;
    currentKind;
    requestKey;

    @api
    get kind() {
        return this.currentKind;
    }
    set kind(value) {
        this.currentKind = value;
    }

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
        return KINDS[this.currentKind] || KINDS.company;
    }

    async start() {
        this.formError = undefined;
        this.listError = undefined;
        this.rows = [];
        const config = this.config;
        try {
            this.canManage = this.currentKind === 'newCompany' ? true : await canManageSetup();
            if (this.currentKind === 'newCompany') {
                this.edit({ fiscalYearStartMonth: '1', fiscalCalendarType: 'Calendar', createPeriods: true, firstDay: fiscalYearStart(1), periodPattern: 'Monthly' });
                return;
            }
            const records = await getSetupRecords({ companyId: this.companyId, kind: this.currentKind });
            this.rows = records || [];
            if (config.single) {
                this.edit(this.rows.length ? config.fromRecord(this.rows[0]) : {});
            } else {
                this.view = 'list';
            }
        } catch (error) {
            this.listError = reduceError(error);
            this.view = 'list';
        }
    }

    edit(values) {
        this.generating = false;
        this.form = { ...values };
        this.requestKey = newKey(this.currentKind);
        this.formError = undefined;
        this.view = 'form';
    }

    get isList() {
        return this.view === 'list';
    }

    get heading() {
        if (this.generating) {
            return 'Generate fiscal year';
        }
        if (this.view === 'form' && !this.config.single) {
            return this.form[this.config.idField] ? `Edit ${this.config.title.toLowerCase()}` : `New ${this.config.title.toLowerCase()}`;
        }
        return this.config.title;
    }

    get subheading() {
        return this.config.sub;
    }

    get manageReason() {
        return this.canManage ? undefined : 'Your role cannot manage company setup';
    }

    get manageDisabled() {
        return !this.canManage;
    }

    get columns() {
        return (this.config.columns || []).map(([field, label]) => ({ key: field, label }));
    }

    get tableRows() {
        const config = this.config;
        return this.rows.map((r) => {
            const locked = config.editable ? !config.editable(r) : false;
            return {
                id: r.Id,
                cells: (config.columns || []).map(([field, , type]) => {
                    const v = r[field];
                    let text = v === undefined || v === null ? '' : String(v);
                    if (type === 'date') {
                        text = formatDate(v);
                    } else if (type === 'bool') {
                        text = v ? 'Yes' : 'No';
                    }
                    return { key: field, text };
                }),
                editDisabled: !this.canManage || locked,
                editTitle: !this.canManage ? this.manageReason : locked ? config.lockedReason : undefined
            };
        });
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get emptyText() {
        return `No ${this.config.title.toLowerCase()} yet.`;
    }

    get fields() {
        const editing = Boolean(this.form[this.config.idField]);
        const source = this.generating ? GENERATE_FIELDS : this.config.fields.filter((f) => !f.showWhen || f.showWhen(this.form));
        return source.map((f) => {
            const value = this.form[f.name];
            const disabled = !this.canManage || (f.createOnly && editing) || (f.name === 'companyKey' && this.currentKind !== 'newCompany');
            return {
                ...f,
                key: f.name,
                isText: f.type === 'text',
                isNumber: f.type === 'number',
                isDate: f.type === 'date',
                isSelect: f.type === 'select',
                isCheckbox: f.type === 'checkbox',
                value: value === undefined || value === null ? '' : String(value),
                checked: value === true,
                disabled,
                options: (f.options || []).map((o) => ({ ...o, selected: String(value) === o.value })),
                showBlank: Boolean(f.blank)
            };
        });
    }

    get saveDisabled() {
        return this.saving || !this.canManage;
    }

    get showBack() {
        return !this.config.single && this.view === 'form';
    }

    get showSave() {
        return this.view === 'form';
    }

    get showNew() {
        return !this.config.single && this.view === 'list';
    }

    get showGenerate() {
        return Boolean(this.config.canGenerate) && this.view === 'list';
    }

    async handleGenerate() {
        this.formError = undefined;
        this.requestKey = newKey('generate');
        this.generating = true;
        this.form = { firstDay: '', periodPattern: 'Monthly' };
        this.view = 'form';
        try {
            const o = await getSetupOptions({ companyId: this.companyId });
            this.form = { firstDay: o.nextPeriodStart || '', periodPattern: 'Monthly' };
        } catch (error) {
            this.formError = reduceError(error);
        }
    }

    handleNew() {
        this.edit({ ...(this.config.defaults || {}) });
    }

    handleEdit(event) {
        const record = this.rows.find((r) => r.Id === event.currentTarget.dataset.id);
        this.edit(this.config.fromRecord(record));
    }

    handleBack() {
        this.generating = false;
        this.view = 'list';
        this.formError = undefined;
    }

    handleInput(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        const form = { ...this.form, [field]: value };
        if (this.currentKind === 'newCompany' && field === 'fiscalYearStartMonth' && !isCustom(form)) {
            form.firstDay = fiscalYearStart(Number(value));
        }
        this.form = form;
    }

    buildRequest() {
        const request = { companyId: this.companyId };
        if (this.currentKind === 'newCompany') {
            delete request.companyId;
        }
        if (this.config.idField) {
            request[this.config.idField] = this.form[this.config.idField] || null;
        }
        for (const f of this.config.fields.filter((x) => !x.extra)) {
            const v = this.form[f.name];
            if (f.type === 'checkbox') {
                request[f.name] = v === true;
            } else if (f.type === 'number' || f.numeric) {
                request[f.name] = v === '' || v === undefined || v === null ? null : Number(v);
            } else {
                request[f.name] = v === '' || v === undefined ? null : v;
            }
        }
        if (this.currentKind === 'company') {
            request.companyId = this.companyId;
        }
        return request;
    }

    async handleSave() {
        if (this.saveDisabled) {
            return;
        }
        this.saving = true;
        this.formError = undefined;
        if (this.generating) {
            await this.saveGenerated();
            return;
        }
        try {
            const recordId = await this.config.save(this.buildRequest(), this.requestKey);
            if (this.currentKind === 'newCompany' && this.form.createPeriods === true) {
                await this.generateFirstYear(recordId);
            }
            this.dispatchEvent(new CustomEvent('sabtoast', { detail: { message: this.config.saved }, bubbles: true, composed: true }));
            this.dispatchEvent(new CustomEvent('saved', { detail: { recordId, kind: this.currentKind } }));
            if (this.config.single) {
                this.dispatchEvent(new CustomEvent('close'));
            } else {
                this.rows = (await getSetupRecords({ companyId: this.companyId, kind: this.currentKind })) || [];
                this.view = 'list';
            }
        } catch (error) {
            this.formError = reduceError(error);
        } finally {
            this.saving = false;
        }
    }

    async generateFirstYear(companyId) {
        const custom = isCustom(this.form);
        try {
            const count = await generatePeriods({ request: { companyId, firstDay: custom ? this.form.firstDay || null : fiscalYearStart(Number(this.form.fiscalYearStartMonth || 1)),
                pattern: custom ? this.form.periodPattern || 'Monthly' : 'Monthly', fiscalYear: null }, requestKey: `${this.requestKey}-P` });
            this.dispatchEvent(new CustomEvent('sabtoast', { detail: { message: `${count} accounting periods created` }, bubbles: true, composed: true }));
        } catch (error) {
            this.dispatchEvent(new CustomEvent('sabtoast', { detail: { message: `Company created, but periods were not: ${reduceError(error)}`, tone: 'bad' },
                bubbles: true, composed: true }));
        }
    }

    async saveGenerated() {
        try {
            const count = await generatePeriods({ request: { companyId: this.companyId, firstDay: this.form.firstDay || null, pattern: this.form.periodPattern || 'Monthly',
                fiscalYear: null }, requestKey: this.requestKey });
            this.dispatchEvent(new CustomEvent('sabtoast', { detail: { message: `${count} accounting periods generated` }, bubbles: true, composed: true }));
            this.dispatchEvent(new CustomEvent('saved', { detail: { kind: 'period' } }));
            this.rows = (await getSetupRecords({ companyId: this.companyId, kind: 'period' })) || [];
            this.generating = false;
            this.view = 'list';
        } catch (error) {
            this.formError = reduceError(error);
        } finally {
            this.saving = false;
        }
    }

    handleClose() {
        if (!this.saving) {
            this.dispatchEvent(new CustomEvent('close'));
        }
    }
}