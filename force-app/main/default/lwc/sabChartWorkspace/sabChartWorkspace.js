import { LightningElement, api } from 'lwc';
import getChart from '@salesforce/apex/SABAdminWorkspaceController.getChart';
import saveAccount from '@salesforce/apex/SABSetupRecordService.saveAccount';
import saveDepartment from '@salesforce/apex/SABAdminWorkspaceService.saveDepartment';
import saveCostCenter from '@salesforce/apex/SABAdminWorkspaceService.saveCostCenter';
import { formatNumber, formatDate, chipClass } from 'c/sabFormat';
import { reduceError, newKey, toast } from 'c/sabMoneyShared';

const TYPES = [['All', 'All'], ['Asset', 'Assets'], ['Liability', 'Liabilities'], ['Equity', 'Equity'], ['Revenue', 'Revenue'], ['Expense', 'Expenses']];
const CONTROL_TYPES = ['None', 'AR', 'AP', 'Bank', 'Payroll', 'Tax', 'Equity', 'Other'];
const CASH_FLOW = ['Operating', 'Investing', 'Financing', 'Cash'];

/** Readable label for a mapping key such as OPERATING_EXPENSES. */
function labelOf(key) {
    const text = String(key || '').replace(/[_.]+/g, ' ').trim().toLowerCase();
    return text ? text.charAt(0).toUpperCase() + text.slice(1) : '';
}

/**
 * Chart of accounts and dimensions in the Harbourline demo layout (G22H-0): GL accounts with balances and control
 * flags, departments, cost centers, projects and report mappings, with account editing through SABSetupRecordService
 * and department and cost center editing through SABAdminWorkspaceService.
 */
export default class SabChartWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api recordId;
    @api periodKey;

    data;
    errorMessage;
    isLoading = false;
    activeTab = 'gl';
    typeFilter = 'All';
    definitionId;
    modal;
    form = {};
    formError;
    saving = false;
    requestKey;
    loadSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.definitionId = undefined;
            this.load();
        }
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
            const data = await getChart({ companyId });
            if (sequence === this.loadSequence) {
                this.data = data;
                const defs = data.definitions || [];
                if (!defs.some((d) => d.definitionId === this.definitionId)) {
                    const active = defs.find((d) => d.status === 'Active') || defs[0];
                    this.definitionId = active ? active.definitionId : undefined;
                }
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

    get showLoading() {
        return this.isLoading && !this.data && !this.errorMessage;
    }

    get personaLabel() {
        return (this.persona && this.persona.label) || 'Your';
    }

    get canManage() {
        return Boolean(this.data && this.data.canManageSetup);
    }

    get manageTitle() {
        return this.canManage ? undefined : `${this.personaLabel} role cannot manage the chart`;
    }

    get manageDisabled() {
        return !this.canManage;
    }

    get canImport() {
        return Array.isArray(this.visibleWorkspaces) && this.visibleWorkspaces.includes('import');
    }

    handleImport() {
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'import' }, bubbles: true, composed: true }));
    }

    // ---------- tabs ----------

    get tabs() {
        const d = this.data || {};
        return [
            { id: 'gl', label: 'GL accounts', count: (d.accounts || []).length },
            { id: 'dept', label: 'Departments', count: (d.departments || []).length },
            { id: 'cc', label: 'Cost centers', count: (d.costCenters || []).length },
            { id: 'proj', label: 'Projects', count: (d.projects || []).length },
            { id: 'map', label: 'Report mapping', count: '' }
        ].map((t) => ({ ...t, hasCount: t.count !== '', className: t.id === this.activeTab ? 'tab active' : 'tab', selected: t.id === this.activeTab ? 'true' : 'false' }));
    }

    handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    get isGl() {
        return this.activeTab === 'gl';
    }

    get isDept() {
        return this.activeTab === 'dept';
    }

    get isCc() {
        return this.activeTab === 'cc';
    }

    get isProj() {
        return this.activeTab === 'proj';
    }

    // ---------- GL accounts ----------

    get typeButtons() {
        return TYPES.map(([id, label]) => ({ id, label, className: id === this.typeFilter ? 'on' : '', pressed: id === this.typeFilter ? 'true' : 'false' }));
    }

    handleType(event) {
        this.typeFilter = event.currentTarget.dataset.id;
    }

    get accountRows() {
        return ((this.data && this.data.accounts) || [])
            .filter((a) => this.typeFilter === 'All' || a.accountType === this.typeFilter)
            .map((a) => ({
                ...a,
                hasControl: a.controlType && a.controlType !== 'None',
                balanceText: formatNumber(a.balance),
                rowClass: a.active ? 'click' : 'click inactive',
                inactiveText: a.active ? '' : 'Inactive'
            }));
    }

    get hasAccounts() {
        return this.accountRows.length > 0;
    }

    handleAccount(event) {
        if (event.type === 'keydown') {
            if (event.key !== 'Enter' && event.key !== ' ') {
                return;
            }
            event.preventDefault();
        }
        const a = this.data.accounts.find((x) => x.accountId === event.currentTarget.dataset.id);
        this.openModal('account', { accountId: a.accountId, code: a.code, name: a.name, accountType: a.accountType, normalBalance: a.normalBalance,
            controlType: a.controlType || 'None', isControlAccount: a.isControlAccount, manualPostingAllowed: a.manualPostingAllowed, isActive: a.active,
            cashFlowCategory: a.cashFlowCategory || '', reportGroup: a.reportGroup || '' });
    }

    handleNewAccount() {
        this.openModal('account', { accountId: null, code: '', name: '', accountType: 'Expense', normalBalance: 'Debit', controlType: 'None', isControlAccount: false,
            manualPostingAllowed: true, isActive: true, cashFlowCategory: '', reportGroup: '' });
    }

    // ---------- dimensions ----------

    dimensionRows(list) {
        return (list || []).map((d) => ({
            ...d,
            chip: chipClass(d.active ? 'Active' : 'Inactive', d.active ? 'good' : 'neutral'),
            statusText: d.active ? 'Active' : 'Inactive',
            parentText: d.parentName || '\u2014',
            personText: d.personName || '\u2014',
            rangeText: [d.activeFrom ? `from ${formatDate(d.activeFrom)}` : '', d.activeTo ? `to ${formatDate(d.activeTo)}` : ''].filter(Boolean).join(' ')
        }));
    }

    get departmentRows() {
        return this.dimensionRows(this.data && this.data.departments);
    }

    get costCenterRows() {
        return this.dimensionRows(this.data && this.data.costCenters);
    }

    get hasDepartments() {
        return this.departmentRows.length > 0;
    }

    get hasCostCenters() {
        return this.costCenterRows.length > 0;
    }

    handleNewDepartment() {
        this.openModal('department', { recordId: null, code: '', name: '', parentId: '', active: true, activeFrom: '', activeTo: '' });
    }

    handleNewCostCenter() {
        this.openModal('costCenter', { recordId: null, code: '', name: '', active: true, activeFrom: '', activeTo: '' });
    }

    handleDimension(event) {
        if (event.type === 'keydown') {
            if (event.key !== 'Enter' && event.key !== ' ') {
                return;
            }
            event.preventDefault();
        }
        const kind = event.currentTarget.dataset.kind;
        const list = kind === 'department' ? this.data.departments : this.data.costCenters;
        const d = list.find((x) => x.recordId === event.currentTarget.dataset.id);
        this.openModal(kind, { recordId: d.recordId, code: d.code, name: d.name, parentId: d.parentId || '', active: d.active, activeFrom: d.activeFrom || '',
            activeTo: d.activeTo || '' });
    }

    // ---------- projects and mapping ----------

    get projectRows() {
        return ((this.data && this.data.projects) || []).map((p) => ({ ...p, chip: chipClass(p.status, p.status === 'Planned' ? 'info' : undefined),
            managerText: p.managerName || '\u2014' }));
    }

    get hasProjects() {
        return this.projectRows.length > 0;
    }

    get canOpenProjects() {
        return Array.isArray(this.visibleWorkspaces) && this.visibleWorkspaces.includes('projects');
    }

    handleOpenProjects() {
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'projects' }, bubbles: true, composed: true }));
    }

    get definitionOptions() {
        return ((this.data && this.data.definitions) || []).map((d) => ({ value: d.definitionId,
            label: `${d.reportType} v${d.version}, ${String(d.status || 'Draft').toLowerCase()}`, selected: d.definitionId === this.definitionId }));
    }

    get hasDefinitions() {
        return this.definitionOptions.length > 0;
    }

    handleDefinition(event) {
        this.definitionId = event.target.value;
    }

    get definition() {
        const d = ((this.data && this.data.definitions) || []).find((x) => x.definitionId === this.definitionId);
        if (!d) {
            return undefined;
        }
        return {
            title: `Report mapping: ${d.reportType} v${d.version}`,
            bannerTitle: `${d.reportType} definition v${d.version} is ${String(d.status || 'Draft').toLowerCase()}`,
            bannerText: `${d.effectiveFrom ? `Effective from ${formatDate(d.effectiveFrom)}` : 'No effective date'}${d.effectiveTo ? ` to ${formatDate(d.effectiveTo)}` : ''}.`,
            bannerClass: d.status === 'Active' ? 'banner t-info gap' : 'banner t-warn gap',
            rows: (d.rows || []).map((r, i) => ({ key: `${r.rowKey}-${i}`, label: labelOf(r.rowKey), groupLabel: labelOf(r.groupKey),
                accounts: (r.accounts || []).map((a, j) => ({ key: `${i}-${j}`, label: a })), signText: r.sign === null || r.sign === undefined ? '\u2014' : String(r.sign),
                orderText: r.displayOrder === null || r.displayOrder === undefined ? '' : String(r.displayOrder) })),
            hasRows: (d.rows || []).length > 0
        };
    }

    // ---------- modal ----------

    openModal(kind, form) {
        this.form = form;
        this.formError = undefined;
        this.requestKey = newKey(`COA-${kind}`, form.accountId || form.recordId);
        this.modal = kind;
    }

    get modalOpen() {
        return Boolean(this.modal);
    }

    get modalHeading() {
        const editing = this.form.accountId || this.form.recordId;
        const noun = { account: 'GL account', department: 'department', costCenter: 'cost center' }[this.modal];
        return `${editing ? 'Edit' : 'New'} ${noun}`;
    }

    get modalSub() {
        return this.modal === 'account' ? 'Accounts with postings keep their code and type. Control accounts are posted only through their subledger.'
            : 'The code is fixed once saved. Inactive dimensions stay on past lines but cannot be used on new ones.';
    }

    get isAccountModal() {
        return this.modal === 'account';
    }

    get isDepartmentModal() {
        return this.modal === 'department';
    }

    get isEditing() {
        return Boolean(this.form.accountId || this.form.recordId);
    }

    choices(values, selected) {
        return values.map((v) => ({ value: v, label: v, selected: v === selected }));
    }

    get typeOptions() {
        return this.choices(['Asset', 'Liability', 'Equity', 'Revenue', 'Expense'], this.form.accountType);
    }

    get normalOptions() {
        return this.choices(['Debit', 'Credit'], this.form.normalBalance);
    }

    get controlOptions() {
        return this.choices(CONTROL_TYPES, this.form.controlType);
    }

    get cashFlowOptions() {
        return this.choices(CASH_FLOW, this.form.cashFlowCategory);
    }

    get parentOptions() {
        return ((this.data && this.data.departments) || []).filter((d) => d.recordId !== this.form.recordId)
            .map((d) => ({ value: d.recordId, label: `${d.code} ${d.name}`, selected: d.recordId === this.form.parentId }));
    }

    handleField(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox' ? event.target.checked : event.target.value;
        const form = { ...this.form, [field]: value };
        if (field === 'accountType') {
            form.normalBalance = ['Asset', 'Expense'].includes(value) ? 'Debit' : 'Credit';
        }
        if (field === 'controlType') {
            form.isControlAccount = value !== 'None';
            form.manualPostingAllowed = value === 'None';
        }
        this.form = form;
    }

    handleClose() {
        if (!this.saving) {
            this.modal = undefined;
        }
    }

    async handleSave() {
        const f = this.form;
        const companyId = this.currentCompanyId;
        const requestKey = this.requestKey;
        this.saving = true;
        this.formError = undefined;
        try {
            if (this.modal === 'account') {
                await saveAccount({ request: { accountId: f.accountId, companyId, code: f.code, name: f.name, accountType: f.accountType, normalBalance: f.normalBalance,
                    controlType: f.controlType, isControlAccount: f.isControlAccount, manualPostingAllowed: f.manualPostingAllowed, isActive: f.isActive,
                    cashFlowCategory: f.cashFlowCategory || null, reportGroup: f.reportGroup || null }, requestKey });
            } else {
                const request = { recordId: f.recordId, companyId, code: f.code, name: f.name, parentId: f.parentId || null, active: f.active,
                    activeFrom: f.activeFrom || null, activeTo: f.activeTo || null };
                await (this.modal === 'department' ? saveDepartment({ request, requestKey }) : saveCostCenter({ request, requestKey }));
            }
            toast(this, `${this.modalHeading.replace(/^(New|Edit) /, '').replace(/^./, (c) => c.toUpperCase())} saved`);
            this.modal = undefined;
            await this.load();
        } catch (error) {
            this.formError = reduceError(error);
        } finally {
            this.saving = false;
        }
    }

    handleRetry() {
        this.load();
    }
}
