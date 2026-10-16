import { LightningElement, api } from 'lwc';
import getDashboard from '@salesforce/apex/SABFixedAssetWorkspaceController.getDashboard';
import getAssetDetail from '@salesforce/apex/SABFixedAssetWorkspaceController.getAssetDetail';
import getOptions from '@salesforce/apex/SABFixedAssetOptionsController.getOptions';
import registerAsset from '@salesforce/apex/SABFixedAssetRegisterService.registerAsset';
import generateSchedule from '@salesforce/apex/SABFixedAssetScheduleService.generateSchedule';
import postDepreciation from '@salesforce/apex/SABFixedAssetDepreciationPostingService.postDepreciation';
import transferAsset from '@salesforce/apex/SABFixedAssetMovementService.transferAsset';
import recordImpairment from '@salesforce/apex/SABFixedAssetMovementService.recordImpairment';
import disposeAsset from '@salesforce/apex/SABFixedAssetMovementService.disposeAsset';
import { formatNumber, formatDate, chipClass, plural } from 'c/sabFormat';
import { reduceError, newKey, todayIso, toast } from 'c/sabMoneyShared';

const BOOK = 'PRIMARY';
const LIVE = ['In Service', 'Impaired'];

/**
 * Fixed assets in the Harbourline demo layout (G22G-6): figures, register, depreciation and an asset drawer with the
 * book value chart, schedule, movements, and register, schedule, post, transfer, impair and dispose actions on the
 * fixed asset services, unchanged.
 */
export default class SabAssetsWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api periodKey;

    data;
    options;
    errorMessage;
    isLoading = false;
    activeTab = 'reg';
    drawerOpen = false;
    detail;
    detailError;
    selectedId;
    busy = false;
    modal;
    form = {};
    formError;
    requestKeys = {};
    loadSequence = 0;
    currentCompanyId;
    requestedRecordId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.load();
        }
    }

    @api
    get recordId() {
        return this.requestedRecordId;
    }
    set recordId(value) {
        this.requestedRecordId = value;
        if (value && this.data) {
            this.openAsset(value);
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
            const [data, options] = await Promise.all([getDashboard({ companyId }), getOptions({ companyId })]);
            if (sequence !== this.loadSequence) {
                return;
            }
            this.data = data;
            this.options = options;
            const target = this.requestedRecordId || (this.drawerOpen ? this.selectedId : undefined);
            if (target) {
                await this.openAsset(target);
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

    get cur() {
        return (this.data && this.data.functionalCurrency) || this.currencyCode || '';
    }

    get personaLabel() {
        return (this.persona && this.persona.label) || 'Your';
    }

    get opt() {
        return this.options || {};
    }

    get assets() {
        return (this.data && this.data.assets) || [];
    }

    // ---------- figures and tabs ----------

    get figures() {
        const live = this.assets.filter((a) => LIVE.includes(a.status));
        const sum = (list, f) => list.reduce((s, a) => s + (Number(a[f]) || 0), 0);
        const cost = sum(live, 'cost');
        const dep = sum(live, 'postedDepreciation');
        return [
            { key: 'c', label: 'Cost in service', value: formatNumber(cost, 0), sub: plural(live.length, 'asset') },
            { key: 'a', label: 'Accumulated depreciation', value: formatNumber(dep, 0), sub: cost ? `${((dep / cost) * 100).toFixed(0)}% of cost` : 'Nothing posted yet' },
            { key: 'n', label: 'Net book value', value: formatNumber(this.data.netBookValue, 0), sub: 'After depreciation, impairment and disposals' },
            { key: 'p', label: 'Planned depreciation', value: formatNumber(this.data.futurePlannedDepreciation, 0), sub: 'Scheduled, not yet posted' }
        ];
    }

    get reviewBanner() {
        const n = this.data && this.data.reconciliationReviewCount;
        return n ? `${plural(n, 'asset')} need a reconciliation review. Open the asset to see the issues.` : undefined;
    }

    get tabs() {
        return [
            { id: 'reg', label: 'Register', count: this.assets.length },
            { id: 'dep', label: 'Depreciation', count: this.depreciationRows.length }
        ].map((t) => ({ ...t, className: t.id === this.activeTab ? 'tab active' : 'tab', selected: t.id === this.activeTab ? 'true' : 'false' }));
    }

    handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    get isRegister() {
        return this.activeTab === 'reg';
    }

    get registerRows() {
        return this.assets.map((a) => ({
            ...a,
            label: a.assetTag || a.companyAssetKey,
            inServiceText: a.inServiceDate ? formatDate(a.inServiceDate) : '\u2014',
            costText: formatNumber(a.cost),
            accText: formatNumber(-(Number(a.postedDepreciation) || 0)),
            bookText: formatNumber(a.netBookValue),
            chip: chipClass(a.status, a.status === 'Planned' ? 'info' : a.status === 'Disposed' ? 'neutral' : a.status === 'Impaired' ? 'warn' : undefined),
            review: a.reconciliationStatus && a.reconciliationStatus !== 'Balanced' && a.reconciliationStatus !== 'OK'
        }));
    }

    get registerFoot() {
        const live = this.assets.filter((a) => LIVE.includes(a.status));
        const sum = (f) => live.reduce((s, a) => s + (Number(a[f]) || 0), 0);
        return { cost: formatNumber(sum('cost')), acc: formatNumber(-sum('postedDepreciation')), book: formatNumber(sum('netBookValue')) };
    }

    get depreciationRows() {
        return this.assets.filter((a) => LIVE.includes(a.status) && Number(a.futurePlannedDepreciation) > 0).map((a) => ({
            ...a,
            label: a.assetTag || a.companyAssetKey,
            bookText: formatNumber(a.netBookValue),
            postedText: formatNumber(a.postedDepreciation),
            plannedText: formatNumber(a.futurePlannedDepreciation),
            closingText: formatNumber((Number(a.netBookValue) || 0) - (Number(a.futurePlannedDepreciation) || 0))
        }));
    }

    get hasAssets() {
        return this.assets.length > 0;
    }

    get hasDepreciation() {
        return this.depreciationRows.length > 0;
    }

    get registerDisabled() {
        return !this.opt.canRegister;
    }

    get registerTitle() {
        return this.opt.canRegister ? undefined : `${this.personaLabel} role cannot register assets`;
    }

    // ---------- drawer ----------

    handleRow(event) {
        if (event.type === 'keydown') {
            if (event.key !== 'Enter' && event.key !== ' ') {
                return;
            }
            event.preventDefault();
        }
        this.openAsset(event.currentTarget.dataset.id);
    }

    async openAsset(assetId) {
        this.selectedId = assetId;
        this.detailError = undefined;
        this.drawerOpen = true;
        try {
            this.detail = await getAssetDetail({ assetId });
        } catch (error) {
            this.detail = undefined;
            this.detailError = reduceError(error);
        }
    }

    handleCloseDrawer() {
        this.drawerOpen = false;
    }

    get drawerHeading() {
        const a = this.detail || this.assets.find((x) => x.assetId === this.selectedId) || {};
        return a.assetTag || a.companyAssetKey || a.name || '';
    }

    get drawerSub() {
        const a = this.detail;
        return a ? [a.name, a.categoryName, a.status].filter(Boolean).join(', ') : '';
    }

    get view() {
        const a = this.detail;
        const lines = [...(a.scheduleLines || [])].sort((x, y) => (x.scheduledDate < y.scheduledDate ? -1 : 1));
        const today = todayIso();
        const next = lines.find((l) => l.status === 'Planned');
        const canPostNext = Boolean(next) && next.scheduledDate <= today && LIVE.includes(a.status);
        const r = a.reconciliation || {};
        let book = Number(a.cost) || 0;
        const points = lines.map((l) => {
            book -= Number(l.plannedDepreciation) || 0;
            return { x: formatDate(l.scheduledDate), y: Math.round(book * 100) / 100 };
        });
        const reason = (allowed, action) => (allowed ? undefined : `${this.personaLabel} role cannot ${action}`);
        const open = a.status !== 'Disposed';
        return {
            facts: [['Category', a.categoryName], ['Acquired', formatDate(a.acquisitionDate)], ['In service', a.inServiceDate ? formatDate(a.inServiceDate) : '\u2014'],
                ['Cost', `${formatNumber(a.cost)} ${this.cur}`], ['Residual value', formatNumber(a.residualValue)], ['Useful life', `${a.usefulLifeMonths || 0} months`],
                ['Method', a.depreciationMethod], ['Location', a.location || '\u2014'], ['Department', a.departmentName || '\u2014'], ['Custodian', a.custodianName || '\u2014'],
                ['Posted depreciation', formatNumber(r.postedDepreciation)], ['Net book value', formatNumber(r.netBookValue)]]
                .map(([label, value]) => ({ key: label, valueKey: `${label}-v`, label, value: value || '\u2014' })),
            issues: (r.issues || []).map((m, i) => ({ key: `i${i}`, message: m })),
            hasIssues: (r.issues || []).length > 0,
            chartSeries: [{ name: 'Book value', values: points.map((p) => p.y), color: 'var(--chart-1)', width: 2 }],
            chartEvery: Math.max(1, Math.ceil(points.length / 6)),
            chartLabels: points.map((p) => p.x),
            hasChart: points.length > 1,
            schedule: lines.map((l) => ({
                ...l,
                dateText: formatDate(l.scheduledDate),
                amountText: formatNumber(l.plannedDepreciation),
                chip: chipClass(l.status, l.status === 'Planned' ? 'info' : undefined),
                isNext: canPostNext && next && l.lineId === next.lineId
            })),
            hasSchedule: lines.length > 0,
            showGenerate: !lines.length && open,
            generateDisabled: this.busy || !this.opt.canSchedule,
            generateTitle: reason(this.opt.canSchedule, 'generate depreciation schedules'),
            postDisabled: this.busy || !this.opt.canPostDepreciation,
            postTitle: reason(this.opt.canPostDepreciation, 'post depreciation'),
            movements: (a.movements || []).map((m) => ({ ...m, dateText: formatDate(m.movementDate), amountText: m.amount ? formatNumber(m.amount) : '\u2014',
                detail: [m.reason, m.proceeds ? `proceeds ${formatNumber(m.proceeds)}` : null].filter(Boolean).join(', ') })),
            hasMovements: (a.movements || []).length > 0,
            canMoveAsset: open,
            moveDisabled: this.busy || !this.opt.canMove,
            moveTitle: reason(this.opt.canMove, 'record asset movements')
        };
    }

    keyFor(action, recordId) {
        const name = `${action}|${recordId}`;
        if (!this.requestKeys[name]) {
            this.requestKeys = { ...this.requestKeys, [name]: newKey(`FA-${action}`, recordId) };
        }
        return this.requestKeys[name];
    }

    async execute(action, recordId, call, message) {
        const name = `${action}|${recordId}`;
        this.busy = true;
        try {
            await call(this.keyFor(action, recordId));
            const keys = { ...this.requestKeys };
            delete keys[name];
            this.requestKeys = keys;
            toast(this, message);
            await this.load();
            return true;
        } catch (error) {
            toast(this, reduceError(error), 'bad');
            return false;
        } finally {
            this.busy = false;
        }
    }

    handleGenerate() {
        const fixedAssetId = this.selectedId;
        this.execute('SCHEDULE', fixedAssetId, () => generateSchedule({ request: { fixedAssetId, bookKey: BOOK } }), 'Depreciation schedule generated');
    }

    handlePostLine(event) {
        const scheduleLineId = event.currentTarget.dataset.id;
        this.execute('DEPN', scheduleLineId, (requestKey) => postDepreciation({ request: { scheduleLineId, requestKey } }), 'Depreciation posted');
    }

    // ---------- modals ----------

    openModal(kind, form) {
        this.form = form;
        this.formError = undefined;
        this.modal = kind;
    }

    handleRegister() {
        const category = (this.opt.categories || [])[0] || {};
        this.openModal('register', { assetName: '', companyAssetKey: '', assetCategoryId: category.value || '', acquisitionDate: todayIso(), inServiceDate: todayIso(),
            functionalCurrencyCost: '', residualValue: '0', usefulLifeMonths: category.defaultLifeMonths ? String(category.defaultLifeMonths) : '', depreciationMethod: 'Straight Line',
            assetTag: '', location: '', departmentId: '', initialStatus: 'In Service' });
    }

    handleTransfer() {
        this.openModal('transfer', { movementDate: todayIso(), toLocation: '', toDepartmentId: '', toCostCenterId: '', reason: '' });
    }

    handleImpair() {
        this.openModal('impair', { movementDate: todayIso(), impairmentAmount: '', reason: '' });
    }

    handleDispose() {
        this.openModal('dispose', { movementDate: todayIso(), proceeds: '0', bankAccountId: '', reason: '' });
    }

    get modalOpen() {
        return Boolean(this.modal);
    }

    get modalHeading() {
        return { register: 'Register asset', transfer: 'Transfer asset', impair: 'Record impairment', dispose: 'Dispose of asset' }[this.modal];
    }

    get modalSub() {
        return {
            register: 'Creates the asset. Generate its depreciation schedule next.',
            transfer: 'Moves the asset to another location, department or cost center. No journal is posted.',
            impair: 'Posts Dr impairment / Cr accumulated impairment and reduces the book value.',
            dispose: 'Removes the asset at book value and posts any gain or loss on disposal.'
        }[this.modal];
    }

    get isRegisterModal() {
        return this.modal === 'register';
    }

    get isTransferModal() {
        return this.modal === 'transfer';
    }

    get isImpairModal() {
        return this.modal === 'impair';
    }

    get isDisposeModal() {
        return this.modal === 'dispose';
    }

    get needsReason() {
        return this.modal !== 'register';
    }

    get saveLabel() {
        return { register: 'Register asset', transfer: 'Transfer', impair: 'Record impairment', dispose: 'Dispose' }[this.modal];
    }

    get saveClass() {
        return this.modal === 'dispose' || this.modal === 'impair' ? 'btn danger sab-modal-save' : 'btn primary sab-modal-save';
    }

    choices(list, selected) {
        return (list || []).map((o) => ({ value: o.value, label: o.label, selected: o.value === selected }));
    }

    get categoryOptions() {
        return this.choices(this.opt.categories, this.form.assetCategoryId);
    }

    get departmentOptions() {
        return this.choices(this.opt.departments, this.form.departmentId || this.form.toDepartmentId);
    }

    get costCenterOptions() {
        return this.choices(this.opt.costCenters, this.form.toCostCenterId);
    }

    get bankOptions() {
        return this.choices(this.opt.bankAccounts, this.form.bankAccountId);
    }

    get statusOptions() {
        return ['In Service', 'Planned'].map((v) => ({ value: v, label: v, selected: v === this.form.initialStatus }));
    }

    handleField(event) {
        const field = event.target.dataset.field;
        const form = { ...this.form, [field]: event.target.value };
        if (field === 'assetCategoryId') {
            const category = (this.opt.categories || []).find((c) => c.value === event.target.value);
            if (category && category.defaultLifeMonths) {
                form.usefulLifeMonths = String(category.defaultLifeMonths);
            }
        }
        this.form = form;
    }

    handleCloseModal() {
        if (!this.busy) {
            this.modal = undefined;
        }
    }

    num(value) {
        return value === '' || value === undefined || value === null ? null : Number(value);
    }

    async handleSave() {
        const f = this.form;
        if (this.needsReason && !String(f.reason || '').trim()) {
            this.formError = 'A reason is required.';
            return;
        }
        const fixedAssetId = this.selectedId;
        let ok;
        if (this.modal === 'register') {
            const key = (f.companyAssetKey || f.assetTag || f.assetName || '').trim();
            ok = await this.execute('REGISTER', key, () => registerAsset({ request: {
                companyId: this.currentCompanyId, assetName: f.assetName, companyAssetKey: key, assetCategoryId: f.assetCategoryId || null,
                acquisitionDate: f.acquisitionDate || null, inServiceDate: f.initialStatus === 'In Service' ? f.inServiceDate || null : null,
                functionalCurrencyCost: this.num(f.functionalCurrencyCost), residualValue: this.num(f.residualValue), usefulLifeMonths: this.num(f.usefulLifeMonths),
                depreciationMethod: f.depreciationMethod, assetTag: f.assetTag || null, location: f.location || null, departmentId: f.departmentId || null,
                initialStatus: f.initialStatus } }), `${f.assetName || 'Asset'} registered`);
        } else if (this.modal === 'transfer') {
            ok = await this.execute('TRANSFER', fixedAssetId, (key) => transferAsset({ request: { fixedAssetId, movementKey: key, bookKey: BOOK, movementDate: f.movementDate,
                accountingDate: f.movementDate, toDepartmentId: f.toDepartmentId || null, toCostCenterId: f.toCostCenterId || null, toLocation: f.toLocation || null,
                reason: f.reason.trim() } }), 'Asset transferred');
        } else if (this.modal === 'impair') {
            ok = await this.execute('IMPAIR', fixedAssetId, (key) => recordImpairment({ request: { fixedAssetId, movementKey: key, requestKey: key, bookKey: BOOK,
                movementDate: f.movementDate, accountingDate: f.movementDate, impairmentAmount: this.num(f.impairmentAmount), reason: f.reason.trim() } }), 'Impairment posted');
        } else {
            ok = await this.execute('DISPOSE', fixedAssetId, (key) => disposeAsset({ request: { fixedAssetId, movementKey: key, requestKey: key, bookKey: BOOK,
                movementDate: f.movementDate, accountingDate: f.movementDate, proceeds: this.num(f.proceeds), bankAccountId: f.bankAccountId || null,
                reason: f.reason.trim() } }), 'Asset disposed');
        }
        if (ok) {
            this.modal = undefined;
        }
    }

    handleRetry() {
        this.load();
    }
}