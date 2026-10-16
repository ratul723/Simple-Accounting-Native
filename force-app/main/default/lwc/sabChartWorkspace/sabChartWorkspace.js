import { LightningElement, api } from 'lwc';
import getChart from '@salesforce/apex/SABAdminWorkspaceController.getChart';
import getMappingOptions from '@salesforce/apex/SABReportMappingService.getOptions';
import saveAccountWithMapping from '@salesforce/apex/SABReportMappingService.saveAccountWithMapping';
import moveAccount from '@salesforce/apex/SABReportMappingService.moveAccount';
import createVersion from '@salesforce/apex/SABReportMappingService.createVersion';
import activateVersion from '@salesforce/apex/SABReportMappingService.activateVersion';
import deleteDraftVersion from '@salesforce/apex/SABReportMappingService.deleteDraftVersion';
import saveDepartment from '@salesforce/apex/SABAdminWorkspaceService.saveDepartment';
import saveCostCenter from '@salesforce/apex/SABAdminWorkspaceService.saveCostCenter';
import { formatNumber, formatDate, chipClass } from 'c/sabFormat';
import { reduceError, newKey, toast } from 'c/sabMoneyShared';

const TYPES = [['All', 'All'], ['Asset', 'Assets'], ['Liability', 'Liabilities'], ['Equity', 'Equity'], ['Revenue', 'Revenue'], ['Expense', 'Expenses']];
const CONTROL_TYPES = ['None', 'AR', 'AP', 'Bank', 'Payroll', 'Tax', 'Equity', 'Other'];
const CASH_FLOW = ['Operating', 'Investing', 'Financing', 'Cash'];
const NEW_ROW = '__new__';
const statementFor = (accountType) => (accountType === 'Revenue' || accountType === 'Expense' ? 'P&L' : 'Balance Sheet');

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
    @api periodKey;
    mapping;
    viewOnly = false;
    searchAccountId;

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
    saved;
    requestKey;
    loadSequence = 0;
    currentCompanyId;

    /** A record opened from global search: the list shows only that account, with a Clear search chip. */
    @api
    get recordId() {
        return this.searchAccountId;
    }
    set recordId(value) {
        this.searchAccountId = value;
        this.activeTab = 'gl';
        this.typeFilter = 'All';
        if (value && this.data) {
            this.openAccountView(value);
        }
    }

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
                this.loadMapping();
                if (this.searchAccountId && !(data.accounts || []).some((a) => a.accountId === this.searchAccountId)) {
                    // The searched account is not in this company: show the full list, no search chip.
                    this.searchAccountId = undefined;
                }
                if (this.searchAccountId && !this.modal) {
                    this.openAccountView(this.searchAccountId);
                }
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
            .filter((a) => !this.searchAccountId || a.accountId === this.searchAccountId)
            .filter((a) => this.typeFilter === 'All' || a.accountType === this.typeFilter)
            .map((a) => ({
                ...a,
                hasControl: a.controlType && a.controlType !== 'None',
                statementRow: this.rowLabelFor(a),
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
        this.openAccountView(event.currentTarget.dataset.id);
    }

    openAccountView(accountId) {
        const a = ((this.data && this.data.accounts) || []).find((x) => x.accountId === accountId);
        if (!a) {
            return;
        }
        const current = this.mappingFor(a.accountId, a.accountType);
        this.openModal('account', { accountId: a.accountId, code: a.code, name: a.name, accountType: a.accountType, normalBalance: a.normalBalance,
            controlType: a.controlType || 'None', isControlAccount: a.isControlAccount, manualPostingAllowed: a.manualPostingAllowed, isActive: a.active,
            cashFlowCategory: a.cashFlowCategory || '', rowKey: current ? current.rowKey : '', groupKey: current ? current.groupKey : '', newRowName: '', newSection: '' }, true);
    }

    handleNewAccount() {
        this.openModal('account', { accountId: null, code: '', name: '', accountType: 'Expense', normalBalance: 'Debit', controlType: 'None', isControlAccount: false,
            manualPostingAllowed: true, isActive: true, cashFlowCategory: '', rowKey: '', groupKey: '', newRowName: '', newSection: '' });
    }

    handleClearSearch() {
        this.searchAccountId = undefined;
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'coa' }, bubbles: true, composed: true }));
    }

    get searchChip() {
        if (!this.searchAccountId || !this.data) {
            return undefined;
        }
        const a = (this.data.accounts || []).find((x) => x.accountId === this.searchAccountId);
        return a ? `${a.code} ${a.name}` : 'Search result';
    }

    // ---------- report mapping ----------

    async loadMapping() {
        try {
            this.mapping = await getMappingOptions({ companyId: this.currentCompanyId });
        } catch (error) {
            this.mapping = { definitions: [], mappings: [], unmapped: [], canManage: false, error: reduceError(error) };
        }
    }

    activeDefinitionFor(accountType) {
        const type = statementFor(accountType);
        return ((this.mapping && this.mapping.definitions) || []).find((d) => d.reportType === type && d.status === 'Active');
    }

    mappingFor(accountId, accountType) {
        const definition = this.activeDefinitionFor(accountType);
        return definition ? ((this.mapping && this.mapping.mappings) || []).find((m) => m.accountId === accountId && m.definitionId === definition.definitionId) : undefined;
    }

    rowLabelFor(a) {
        const m = this.mappingFor(a.accountId, a.accountType);
        return m ? `${labelOf(m.groupKey)} / ${labelOf(m.rowKey)}` : 'Not mapped';
    }

    get statementLabel() {
        return statementFor(this.form.accountType) === 'P&L' ? 'P&L' : 'Balance Sheet';
    }

    get sectionOptions() {
        const definition = this.activeDefinitionFor(this.form.accountType);
        const groups = [...new Set(((definition && definition.rows) || []).map((r) => r.groupKey).filter(Boolean))];
        return groups.map((g) => ({ value: g, label: labelOf(g), selected: g === this.form.groupKey }));
    }

    get rowOptions() {
        const definition = this.activeDefinitionFor(this.form.accountType);
        return ((definition && definition.rows) || []).filter((r) => !this.form.groupKey || r.groupKey === this.form.groupKey)
            .map((r) => ({ value: r.rowKey, label: labelOf(r.rowKey), selected: r.rowKey === this.form.rowKey }));
    }

    get newSectionHint() {
        const pl = this.modal === 'move' ? Boolean(this.selectedDefinition && this.selectedDefinition.reportType === 'P&L') : statementFor(this.form.accountType) === 'P&L';
        return pl ? 'For example Other expenses' : 'For example Current assets';
    }

    get isNewRow() {
        return this.form.rowKey === NEW_ROW;
    }

    get newRowValue() {
        return NEW_ROW;
    }

    get noDefinition() {
        return Boolean(this.mapping) && !this.activeDefinitionFor(this.form.accountType);
    }

    get mappingText() {
        if (!this.form.rowKey) {
            return 'Not mapped';
        }
        return `${labelOf(this.form.groupKey)} / ${labelOf(this.form.rowKey)}`;
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
            activeTo: d.activeTo || '' }, true);
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
            // Never undefined: the template reads its fields while a version is being created or the chart reloads.
            return { title: 'Report mapping', bannerTitle: 'Loading the definition', bannerText: '', bannerClass: 'banner t-info gap', rows: [], hasRows: false };
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

    openModal(kind, form, viewOnly = false) {
        this.viewOnly = viewOnly;
        this.saved = { ...form };
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
        const noun = { account: 'GL account', department: 'department', costCenter: 'cost center', move: 'report mapping' }[this.modal];
        if (this.modal === 'deleteDraft') {
            return `Delete draft ${this.form.label}`;
        }
        if (this.modal === 'move') {
            return 'Move an account to another row';
        }
        if (this.viewOnly) {
            return this.modal === 'account' ? `${this.form.code} ${this.form.name}` : `${this.form.code} ${this.form.name}`;
        }
        return `${editing ? 'Edit' : 'New'} ${noun}`;
    }

    get isViewOnly() {
        return this.viewOnly;
    }

    get isEditable() {
        return !this.viewOnly;
    }

    get showEditButton() {
        return this.viewOnly && this.canManage;
    }

    handleStartEdit() {
        this.viewOnly = false;
    }

    handleCancelEdit() {
        if (this.isEditing && this.saved) {
            this.form = { ...this.saved };
            this.formError = undefined;
            this.viewOnly = true;
            return;
        }
        this.handleClose();
    }

    get viewFacts() {
        const f = this.form;
        if (this.modal === 'account') {
            return [['Code', f.code], ['Name', f.name], ['Type', f.accountType], ['Normal balance', f.normalBalance], ['Control type', f.controlType || 'None'],
                ['Manual posting', f.manualPostingAllowed ? 'Allowed' : 'Not allowed'], ['Cash flow category', f.cashFlowCategory || 'Operating (default)'],
                [`${this.statementLabel} row`, this.mappingText], ['Status', f.isActive ? 'Active' : 'Inactive']]
                .map(([label, value]) => ({ key: label, valueKey: `${label}-v`, label, value }));
        }
        const parent = ((this.data && this.data.departments) || []).find((d) => d.recordId === f.parentId);
        return [['Code', f.code], ['Name', f.name], ...(this.modal === 'department' ? [['Parent', parent ? parent.name : '\u2014']] : []),
            ['Active from', f.activeFrom ? formatDate(f.activeFrom) : '\u2014'], ['Active to', f.activeTo ? formatDate(f.activeTo) : '\u2014'],
            ['Status', f.active ? 'Active' : 'Inactive']].map(([label, value]) => ({ key: label, valueKey: `${label}-v`, label, value }));
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
            if (statementFor(value) !== statementFor(this.form.accountType)) {
                form.groupKey = '';
                form.rowKey = '';
            }
        }
        if (field === 'groupKey' && this.form.rowKey !== NEW_ROW) {
            form.rowKey = '';
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
            if (this.modal === 'deleteDraft') {
                await deleteDraftVersion({ companyId, definitionId: f.definitionId, requestKey });
                this.definitionId = undefined;
            } else if (this.modal === 'move') {
                await moveAccount({ companyId, accountId: f.moveAccountId || null, mapping: this.mappingChoice(f, f.moveDefinitionId), requestKey });
            } else if (this.modal === 'account') {
                const changed = f.rowKey !== (this.saved && this.saved.rowKey) || f.rowKey === NEW_ROW;
                if (!f.accountId && !f.rowKey) {
                    this.formError = `Choose where this account appears on the ${this.statementLabel}.`;
                    return;
                }
                if (f.rowKey === NEW_ROW && !String(f.newRowName || '').trim()) {
                    this.formError = 'Name the new statement row.';
                    return;
                }
                await saveAccountWithMapping({ request: { accountId: f.accountId, companyId, code: f.code, name: f.name, accountType: f.accountType,
                    normalBalance: f.normalBalance, controlType: f.controlType, isControlAccount: f.isControlAccount, manualPostingAllowed: f.manualPostingAllowed,
                    isActive: f.isActive, cashFlowCategory: f.cashFlowCategory || null, reportGroup: null },
                    mapping: f.rowKey && changed ? this.mappingChoice(f, null) : null, requestKey });
            } else {
                const request = { recordId: f.recordId, companyId, code: f.code, name: f.name, parentId: f.parentId || null, active: f.active,
                    activeFrom: f.activeFrom || null, activeTo: f.activeTo || null };
                await (this.modal === 'department' ? saveDepartment({ request, requestKey }) : saveCostCenter({ request, requestKey }));
            }
            toast(this, this.modal === 'deleteDraft' ? 'Draft version deleted' : this.modal === 'move' ? 'Report mapping updated' : `${this.modalHeading.replace(/^(New|Edit) /, '').replace(/^./, (c) => c.toUpperCase())} saved`);
            this.modal = undefined;
            await this.load();
        } catch (error) {
            this.formError = reduceError(error);
        } finally {
            this.saving = false;
        }
    }

    mappingChoice(f, definitionId) {
        const newRow = f.rowKey === NEW_ROW;
        return { definitionId: definitionId || null, groupKey: (newRow ? f.newSection || f.groupKey : f.groupKey) || null, rowKey: newRow ? f.newRowName : f.rowKey };
    }

    // ---------- mapping table actions ----------

    get canManageMappings() {
        return Boolean(this.mapping && this.mapping.canManage);
    }

    get selectedDefinition() {
        return ((this.mapping && this.mapping.definitions) || []).find((d) => d.definitionId === this.definitionId);
    }

    get canActivate() {
        return this.canManageMappings && Boolean(this.selectedDefinition) && this.selectedDefinition.status === 'Draft';
    }

    get canMove() {
        return this.canManageMappings && Boolean(this.selectedDefinition) && this.selectedDefinition.status !== 'Retired';
    }

    handleMoveAccount() {
        const d = this.selectedDefinition;
        this.openModal('move', { moveDefinitionId: d.definitionId, moveAccountId: '', accountType: d.reportType === 'P&L' ? 'Expense' : 'Asset', groupKey: '', rowKey: '',
            newRowName: '', newSection: '' });
    }

    get moveAccountOptions() {
        const d = this.selectedDefinition;
        const pl = d && d.reportType === 'P&L';
        return ((this.data && this.data.accounts) || []).filter((a) => (pl ? ['Revenue', 'Expense'] : ['Asset', 'Liability', 'Equity']).includes(a.accountType))
            .map((a) => ({ value: a.accountId, label: `${a.code} ${a.name}`, selected: a.accountId === this.form.moveAccountId }));
    }

    get moveSectionOptions() {
        const d = this.selectedDefinition;
        const groups = [...new Set(((d && d.rows) || []).map((r) => r.groupKey).filter(Boolean))];
        return groups.map((g) => ({ value: g, label: labelOf(g), selected: g === this.form.groupKey }));
    }

    get moveRowOptions() {
        const d = this.selectedDefinition;
        return ((d && d.rows) || []).filter((r) => !this.form.groupKey || r.groupKey === this.form.groupKey)
            .map((r) => ({ value: r.rowKey, label: labelOf(r.rowKey), selected: r.rowKey === this.form.rowKey }));
    }

    get isMoveModal() {
        return this.modal === 'move';
    }

    async runDefinitionAction(call, message) {
        this.saving = true;
        try {
            const id = await call();
            toast(this, message);
            // Load first, then select: the new version is only in the data once the chart has reloaded.
            await this.load();
            if (id && ((this.data && this.data.definitions) || []).some((d) => d.definitionId === id)) {
                this.definitionId = id;
            }
            await this.loadMapping();
        } catch (error) {
            toast(this, reduceError(error), 'bad');
        } finally {
            this.saving = false;
        }
    }

    handleNewVersion() {
        const definitionId = this.definitionId;
        this.runDefinitionAction(() => createVersion({ companyId: this.currentCompanyId, definitionId, requestKey: newKey('MAPVER', definitionId) }),
            'New draft version created. Change its rows, then activate it.');
    }

    handleDeleteDraft() {
        const d = this.selectedDefinition;
        this.openModal('deleteDraft', { definitionId: d.definitionId, label: `${d.reportType} v${d.version}` });
    }

    get isDeleteModal() {
        return this.modal === 'deleteDraft';
    }

    handleActivate() {
        const definitionId = this.definitionId;
        this.runDefinitionAction(() => activateVersion({ companyId: this.currentCompanyId, definitionId, requestKey: newKey('MAPACT', definitionId) }),
            'Version activated. The previous version is retired.');
    }

    handleRetry() {
        this.load();
    }
}
