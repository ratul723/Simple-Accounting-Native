import { LightningElement, api } from 'lwc';
import getSetupState from '@salesforce/apex/SABCompanySetupWizardController.getSetupState';
import getSetupRecords from '@salesforce/apex/SABSetupRecordService.getSetupRecords';
import getAccessibleCompanies from '@salesforce/apex/SABCompanyContextController.getAccessibleCompanies';
import { formatDate, chipClass, plural } from 'c/sabFormat';

const FULL_MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const TABS = [
    { id: 'company', label: 'Company' },
    { id: 'periods', label: 'Fiscal calendar & periods', kind: 'period' },
    { id: 'accounts', label: 'Chart of accounts', kind: 'account' },
    { id: 'numbering', label: 'Defaults & numbering', kind: 'sequence' },
    { id: 'features', label: 'Features', kind: 'feature' },
    { id: 'companies', label: 'Companies' }
];

function reduceError(error) {
    if (!error) {
        return 'Something went wrong.';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return (error.body && error.body.message) || error.message || 'Something went wrong.';
}

/**
 * Company setup workspace in the Harbourline demo layout: setup progress steps, readiness banner, company profile,
 * periods, chart of accounts, numbering, features and the company list. Editing opens c/sabSetupRecords in place.
 */
export default class SabSetupWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api recordId;
    @api periodKey;

    state;
    errorMessage;
    isLoading = false;
    activeTab = 'company';
    records = {};
    recordsError;
    companies;
    editorOpen = false;
    editorKind = 'company';
    loadSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.records = {};
            this.load();
        }
    }

    async load() {
        const companyId = this.currentCompanyId;
        const sequence = ++this.loadSequence;
        if (!companyId) {
            this.state = undefined;
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const result = await getSetupState({ companyId });
            if (sequence === this.loadSequence) {
                this.state = result;
                await this.loadTab();
            }
        } catch (error) {
            if (sequence === this.loadSequence) {
                this.state = undefined;
                this.errorMessage = reduceError(error);
            }
        } finally {
            if (sequence === this.loadSequence) {
                this.isLoading = false;
            }
        }
    }

    async loadTab() {
        const tab = TABS.find((t) => t.id === this.activeTab);
        this.recordsError = undefined;
        try {
            if (tab.kind) {
                const rows = await getSetupRecords({ companyId: this.currentCompanyId, kind: tab.kind });
                this.records = { ...this.records, [tab.kind]: rows || [] };
            } else if (tab.id === 'companies') {
                this.companies = await getAccessibleCompanies();
            }
        } catch (error) {
            this.recordsError = reduceError(error);
        }
    }

    // ---------- header ----------

    get showLoading() {
        return this.isLoading && !this.state && !this.errorMessage;
    }

    get steps() {
        const s = this.state || {};
        const list = [
            { key: 'company', title: 'Company profile', text: 'Legal name, country, currency and fiscal calendar', done: Boolean(s.companyActive && s.fiscalYearStartMonth),
                detail: s.companyActive ? `Fiscal year starts ${FULL_MONTHS[(s.fiscalYearStartMonth || 1) - 1]}` : 'Company is not active' },
            { key: 'period', title: 'Accounting periods', text: 'At least one Open period for posting', done: s.openPeriodCount > 0,
                detail: `${plural(s.periodCount || 0, 'period')}, ${s.openPeriodCount || 0} open` },
            { key: 'account', title: 'Chart of accounts', text: 'Active GL accounts with valid control rules', done: s.activeGLAccountCount > 0,
                detail: `${plural(s.activeGLAccountCount || 0, 'active account')}` },
            { key: 'sequence', title: 'Document numbering', text: 'Gap-free sequences, reserved at posting', done: s.activeSequenceCount > 0,
                detail: `${plural(s.activeSequenceCount || 0, 'active sequence')}` },
            { key: 'feature', title: 'Company features', text: 'Every enabled feature configured as Valid', done: !(s.errors || []).some((e) => /feature/i.test(e)),
                detail: `${plural(s.enabledFeatureCount || 0, 'enabled feature')}` },
            { key: 'validate', title: 'Core readiness', text: 'The authoritative setup check passes', done: Boolean(s.readyForCoreAccounting),
                detail: s.readyForCoreAccounting ? 'Ready for core accounting' : 'Not ready yet' }
        ];
        const next = list.findIndex((step) => !step.done);
        return list.map((step, i) => ({
            ...step,
            className: step.done ? 'step done' : i === next ? 'step now' : 'step',
            number: i + 1,
            isNow: i === next
        }));
    }

    get doneCount() {
        return this.steps.filter((s) => s.done).length;
    }

    get progressSub() {
        return this.doneCount === this.steps.length ? 'All steps complete' : `${this.doneCount} of ${this.steps.length} steps complete`;
    }

    get nextStep() {
        return this.steps.find((s) => !s.done && s.key !== 'validate');
    }

    get showContinue() {
        return Boolean(this.nextStep);
    }

    handleContinue() {
        this.openEditor(this.nextStep.key);
    }

    // ---------- company tab ----------

    get readiness() {
        const s = this.state || {};
        const errors = s.errors || [];
        const warnings = s.warnings || [];
        if (s.readyForCoreAccounting) {
            return { className: 'banner t-good', icon: 'check', title: 'Core accounting readiness passed',
                text: warnings.length ? warnings.join(' ') : 'The core setup checks passed for this company.' };
        }
        return { className: 'banner t-warn', icon: 'alert', title: `${plural(errors.length, 'item')} to finish before posting`,
            text: errors.join(' ') || warnings.join(' ') };
    }

    get profile() {
        const s = this.state || {};
        return [
            ['Legal name', s.companyName],
            ['Company key', s.companyKey],
            ['Country', s.countryCode],
            ['Functional currency', s.functionalCurrency],
            ['Fiscal calendar', s.fiscalCalendarType],
            ['Fiscal year starts', s.fiscalYearStartMonth ? FULL_MONTHS[s.fiscalYearStartMonth - 1] : ''],
            ['Country pack', s.countryPackVersion || 'Not set'],
            ['Created with version', s.createdSetupVersion || 'Not recorded']
        ].map(([label, value]) => ({ key: label, label, value: value || '\u2014' }));
    }

    get statusChip() {
        return chipClass((this.state && this.state.setupStatus) || '', this.state && this.state.setupStatus === 'In Progress' ? 'warn' : undefined);
    }

    get isCompanyTab() {
        return this.activeTab === 'company';
    }

    get isCompaniesTab() {
        return this.activeTab === 'companies';
    }

    get isRecordsTab() {
        return !this.isCompanyTab && !this.isCompaniesTab;
    }

    // ---------- tabs ----------

    get tabs() {
        return TABS.map((t) => ({ ...t, className: t.id === this.activeTab ? 'tab active' : 'tab', selected: t.id === this.activeTab ? 'true' : 'false' }));
    }

    async handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
        await this.loadTab();
    }

    get recordPanel() {
        const tab = TABS.find((t) => t.id === this.activeTab);
        const rows = this.records[tab.kind] || [];
        const configs = {
            period: {
                title: 'Fiscal calendar & periods', sub: `${plural(rows.length, 'period')}, ${rows.filter((r) => r.Status__c === 'Open').length} open`,
                action: 'Manage periods',
                columns: ['Period', 'Start', 'End', 'Fiscal year', 'Quarter', 'Status'],
                cells: (r) => [{ id: true, text: r.Period_Key__c }, { text: formatDate(r.Start_Date__c) }, { text: formatDate(r.End_Date__c) },
                    { text: String(r.Fiscal_Year__c || '') }, { text: r.Fiscal_Quarter__c ? `Q${r.Fiscal_Quarter__c}` : '' },
                    { chip: chipClass(r.Status__c, r.Status__c === 'Open' ? 'accent' : 'neutral'), text: r.Status__c }]
            },
            account: {
                title: 'Chart of accounts', sub: `${plural(rows.filter((r) => r.Is_Active__c).length, 'active account')}`, action: 'Manage accounts',
                columns: ['Code', 'Name', 'Type', 'Normal balance', 'Control', 'Status'],
                cells: (r) => [{ id: true, text: r.Account_Code__c }, { text: r.Name }, { text: r.Account_Type__c }, { text: r.Normal_Balance__c },
                    { text: r.Control_Type__c === 'None' ? '' : r.Control_Type__c },
                    { chip: chipClass(r.Is_Active__c ? 'Active' : 'Inactive'), text: r.Is_Active__c ? 'Active' : 'Inactive' }]
            },
            sequence: {
                title: 'Document numbering', sub: 'Gap-free sequences, reserved at posting', action: 'Manage numbering',
                columns: ['Document', 'Prefix', 'Next number', 'Series', 'Status'],
                cells: (r) => [{ text: r.Document_Type__c }, { tag: true, text: r.Prefix__c || 'None' },
                    { text: `${r.Prefix__c || ''}${String(r.Next_Number__c || '').padStart(r.Minimum_Digits__c || 0, '0')}` },
                    { text: r.Fiscal_Series__c }, { chip: chipClass(r.Is_Active__c ? 'Active' : 'Inactive'), text: r.Is_Active__c ? 'Active' : 'Inactive' }]
            },
            feature: {
                title: 'Company features', sub: 'An enabled feature must reach Valid before core readiness passes', action: 'Manage features',
                columns: ['Feature', 'Enabled', 'Configuration'],
                cells: (r) => [{ id: true, text: (r.Feature_Key__c || '').replace(/_/g, ' ').toLowerCase().replace(/^./, (c) => c.toUpperCase()) },
                    { text: r.Enabled__c ? 'On' : 'Off' },
                    { chip: chipClass(r.Configuration_Status__c, r.Configuration_Status__c === 'Not Configured' ? 'neutral' : undefined), text: r.Configuration_Status__c }]
            }
        };
        const config = configs[tab.kind];
        return {
            title: config.title,
            sub: config.sub,
            action: config.action,
            kind: tab.kind,
            columns: config.columns.map((c) => ({ key: c, label: c })),
            rows: rows.map((r) => ({
                key: r.Id,
                cells: config.cells(r).map((c, i) => ({ ...c, key: `${r.Id}-${i}`, isId: Boolean(c.id), isChip: Boolean(c.chip), isTag: Boolean(c.tag) }))
            })),
            hasRows: rows.length > 0,
            emptyText: `No ${config.title.toLowerCase()} yet.`
        };
    }

    handleManage(event) {
        this.openEditor(event.currentTarget.dataset.kind);
    }

    // ---------- companies tab ----------

    get companyRows() {
        return (this.companies || []).map((c) => ({
            ...c,
            isCurrent: c.companyId === this.currentCompanyId,
            chip: chipClass(c.setupStatus, c.setupStatus === 'In Progress' ? 'warn' : undefined)
        }));
    }

    get canCreateCompany() {
        return Boolean(this.caps && this.caps.canCreateCompany);
    }

    get addCompanyTitle() {
        return this.canCreateCompany ? undefined : 'Your role cannot add companies';
    }

    get addCompanyDisabled() {
        return !this.canCreateCompany;
    }

    handleSwitch(event) {
        this.dispatchEvent(new CustomEvent('sabswitchcompany', { detail: { companyId: event.currentTarget.dataset.id }, bubbles: true, composed: true }));
    }

    handleAddCompany() {
        this.dispatchEvent(new CustomEvent('sabnewcompany', { bubbles: true, composed: true }));
    }

    // ---------- editor ----------

    handleEditProfile() {
        this.openEditor('company');
    }

    openEditor(kind) {
        this.editorKind = kind === 'validate' ? 'company' : kind;
        this.editorOpen = true;
    }

    handleEditorClose() {
        this.editorOpen = false;
    }

    async handleEditorSaved() {
        this.records = {};
        this.dispatchEvent(new CustomEvent('sabrefreshshell', { bubbles: true, composed: true }));
        await this.load();
    }

    toast(message, tone) {
        this.dispatchEvent(new CustomEvent('sabtoast', { detail: { message, tone }, bubbles: true, composed: true }));
    }

    handleRetry() {
        this.load();
    }
}