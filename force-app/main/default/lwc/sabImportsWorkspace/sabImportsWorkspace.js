import { LightningElement, api } from 'lwc';
import getWorkspace from '@salesforce/apex/SABImportsWorkspaceController.getWorkspace';
import getRows from '@salesforce/apex/SABImportsWorkspaceController.getRows';
import stageImport from '@salesforce/apex/SABImportService.stage';
import validateImport from '@salesforce/apex/SABImportService.validate';
import commitImport from '@salesforce/apex/SABImportService.commitImport';
import { formatDateTime, formatNumber, chipClass, plural } from 'c/sabFormat';

const STEPS = ['Stage', 'Parse', 'Validate', 'Preview', 'Commit'];
const STEP_INDEX = { Uploaded: 1, Parsed: 2, Validated: 3, 'Part Failed': 3, Failed: 3, Ready: 4, Committed: 5 };
const MAX_FILE_CHARS = 500000;

function reduceError(error) {
    if (!error) {
        return 'Something went wrong.';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return (error.body && error.body.message) || error.message || 'Something went wrong.';
}

function newKey(prefix, id) {
    const random = typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    return `${prefix}-${id || 'new'}-${random}`;
}

function steps(list, idx) {
    return list.map((label, i) => ({
        key: label,
        label,
        className: i < idx ? 'hstep done' : i === idx ? 'hstep now' : 'hstep',
        done: i < idx,
        number: i + 1
    }));
}

function summarise(json) {
    if (!json) {
        return '';
    }
    try {
        const values = JSON.parse(json);
        return Object.keys(values)
            .filter((k) => values[k] !== null && values[k] !== '')
            .map((k) => `${k.replace(/_/g, ' ')} ${values[k]}`)
            .join(', ');
    } catch {
        return '';
    }
}

function readFile(file) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result);
        reader.onerror = () => reject(new Error('The file could not be read.'));
        reader.readAsText(file);
    });
}

/**
 * Import and integration center (G22F): staged CSV imports with row validation and commit, and the integration
 * outbox, on SABImportService and SABIntegrationLogService.
 */
export default class SabImportsWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api recordId;
    @api periodKey;

    data;
    rows;
    errorMessage;
    rowsError;
    isLoading = false;
    activeTab = 'jobs';
    rowFilter = 'errors';
    selectedJobId;
    busyKey;
    modalOpen = false;
    form = {};
    formError;
    saving = false;
    loadSequence = 0;
    rowSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.selectedJobId = undefined;
            this.rows = undefined;
            this.load();
        }
    }

    async load() {
        const companyId = this.currentCompanyId;
        const sequence = ++this.loadSequence;
        if (!companyId) {
            this.data = undefined;
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const result = await getWorkspace({ companyId });
            if (sequence !== this.loadSequence) {
                return;
            }
            this.data = result;
            const jobs = result.jobs || [];
            if (!jobs.some((j) => j.importJobId === this.selectedJobId)) {
                this.selectedJobId = jobs.length ? jobs[0].importJobId : undefined;
            }
            await this.loadRows();
        } catch (error) {
            if (sequence === this.loadSequence) {
                this.data = undefined;
                this.errorMessage = reduceError(error);
            }
        } finally {
            if (sequence === this.loadSequence) {
                this.isLoading = false;
            }
        }
    }

    async loadRows() {
        const importJobId = this.selectedJobId;
        const sequence = ++this.rowSequence;
        this.rowsError = undefined;
        if (!importJobId) {
            this.rows = undefined;
            return;
        }
        try {
            const result = await getRows({ companyId: this.currentCompanyId, importJobId });
            if (sequence === this.rowSequence) {
                this.rows = result || [];
            }
        } catch (error) {
            if (sequence === this.rowSequence) {
                this.rows = undefined;
                this.rowsError = reduceError(error);
            }
        }
    }

    // ---------- header and tabs ----------

    get showLoading() {
        return this.isLoading && !this.data && !this.errorMessage;
    }

    get canManage() {
        return Boolean(this.data && this.data.canManage);
    }

    get manageReason() {
        return this.canManage ? undefined : 'Your role cannot stage imports';
    }

    get newDisabled() {
        return !this.canManage;
    }

    get isJobsTab() {
        return this.activeTab === 'jobs';
    }

    get tabs() {
        const d = this.data || {};
        const list = [{ id: 'jobs', label: 'Imports', count: (d.jobs || []).length }];
        if (d.canViewLog) {
            list.push({ id: 'out', label: 'Integration outbox', count: (d.requests || []).length });
        }
        return list.map((t) => ({ ...t, className: t.id === this.activeTab ? 'tab active' : 'tab', selected: t.id === this.activeTab ? 'true' : 'false' }));
    }

    handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    // ---------- jobs ----------

    get jobRows() {
        return ((this.data && this.data.jobs) || []).map((j) => ({
            ...j,
            rowClass: j.importJobId === this.selectedJobId ? 'click sel' : 'click',
            current: j.importJobId === this.selectedJobId ? 'true' : 'false',
            requestedText: formatDateTime(j.requestedAt),
            hasErrors: j.errorCount > 0,
            chip: chipClass(j.status)
        }));
    }

    get hasJobs() {
        return this.jobRows.length > 0;
    }

    async handleSelectJob(event) {
        if (event.type === 'keydown' && event.key !== 'Enter' && event.key !== ' ') {
            return;
        }
        if (event.type === 'keydown') {
            event.preventDefault();
        }
        this.selectedJobId = event.currentTarget.dataset.id;
        this.rows = undefined;
        await this.loadRows();
    }

    get job() {
        const j = ((this.data && this.data.jobs) || []).find((x) => x.importJobId === this.selectedJobId);
        if (!j) {
            return undefined;
        }
        const commitReason = !this.data.canCommit ? 'Your role cannot commit imports' : undefined;
        const canCommitStatus = j.status === 'Ready' || (j.status === 'Validated' && j.validCount > 0) || j.status === 'Part Failed';
        return {
            ...j,
            steps: steps(STEPS, STEP_INDEX[j.status] === undefined ? 0 : STEP_INDEX[j.status]),
            byText: [j.requestedBy, formatDateTime(j.requestedAt)].filter(Boolean).join(', '),
            validText: `${j.validCount} of ${j.rowCount}`,
            chip: chipClass(j.status),
            isCommitted: j.status === 'Committed',
            hasErrors: j.errorCount > 0,
            errorTitle: `${plural(j.errorCount, 'row')} need fixing`,
            showValidate: (j.status === 'Parsed' || j.status === 'Validated' || j.status === 'Uploaded') && this.canManage,
            showCommit: canCommitStatus,
            commitLabel: j.errorCount ? `Commit ${j.validCount} valid rows` : 'Commit import',
            commitDisabled: Boolean(commitReason) || this.busyKey === `commit-${j.importJobId}`,
            commitTitle: commitReason,
            validateDisabled: this.busyKey === `validate-${j.importJobId}`
        };
    }

    handleValidate() {
        const importJobId = this.selectedJobId;
        this.runAction(`validate-${importJobId}`, () => validateImport({ importJobId }), 'Validation finished');
    }

    handleCommit() {
        const importJobId = this.selectedJobId;
        this.runAction(`commit-${importJobId}`, () => commitImport({ importJobId, requestKey: newKey('IMP-COMMIT', importJobId) }),
            'Import committed');
    }

    async runAction(busyKey, call, message) {
        if (this.busyKey) {
            return;
        }
        this.busyKey = busyKey;
        try {
            const result = await call();
            const detail = result && result.status ? `${message}: ${result.status.toLowerCase()}` : message;
            this.toast(detail);
            await this.load();
        } catch (error) {
            this.toast(reduceError(error), 'bad');
        } finally {
            this.busyKey = undefined;
        }
    }

    // ---------- rows ----------

    get filterButtons() {
        return [
            { id: 'errors', label: 'Errors' },
            { id: 'all', label: 'All rows' }
        ].map((b) => ({ ...b, className: b.id === this.rowFilter ? 'on' : '', pressed: b.id === this.rowFilter ? 'true' : 'false' }));
    }

    handleFilter(event) {
        this.rowFilter = event.currentTarget.dataset.id;
    }

    get rowViews() {
        return (this.rows || [])
            .filter((r) => this.rowFilter === 'all' || r.status === 'Error')
            .map((r) => ({ ...r, values: summarise(r.valuesJson), chip: chipClass(r.status, r.status === 'Pending' ? 'neutral' : undefined) }));
    }

    get hasRowViews() {
        return this.rowViews.length > 0;
    }

    get showRows() {
        return Boolean(this.rows) || Boolean(this.rowsError);
    }

    get rowsTitle() {
        const j = this.job;
        return j ? `Row validation, ${j.name}` : 'Row validation';
    }

    get rowsEmptyText() {
        return this.rowFilter === 'errors' ? 'No rows with errors.' : 'No rows.';
    }

    handleDownloadErrors() {
        const errors = (this.rows || []).filter((r) => r.status === 'Error');
        const quote = (v) => `"${String(v === null || v === undefined ? '' : v).replace(/"/g, '""')}"`;
        const lines = ['row,message,values', ...errors.map((r) => [r.rowNumber, quote(r.message), quote(summarise(r.valuesJson))].join(','))];
        const link = this.template.querySelector('.download-link');
        link.href = `data:text/csv;charset=utf-8,${encodeURIComponent(lines.join('\n'))}`;
        link.download = `${this.job.name}-errors.csv`;
        link.click();
    }

    // ---------- outbox ----------

    get requestRows() {
        return ((this.data && this.data.requests) || []).map((r) => ({
            ...r,
            attemptsText: formatNumber(r.attempts || 0, 0),
            nextText: r.nextAttemptAt ? formatDateTime(r.nextAttemptAt) : '',
            chip: chipClass(r.state, r.state === 'Pending' ? 'neutral' : r.state === 'Cancelled' ? 'neutral' : undefined)
        }));
    }

    get hasRequests() {
        return this.requestRows.length > 0;
    }

    // ---------- new import ----------

    get importTypeOptions() {
        return ((this.data && this.data.importTypes) || []).map((t) => ({ value: t, label: t, selected: t === this.form.importType }));
    }

    get modalSteps() {
        return steps(['Upload', 'Validate', 'Commit'], this.form.fileName ? 1 : 0);
    }

    get hasFile() {
        return Boolean(this.form.fileName);
    }

    get fileText() {
        return `${plural(this.form.lineCount || 0, 'data row')}, ${formatNumber((this.form.size || 0) / 1024, 0)} KB`;
    }

    get columnsHint() {
        return this.form.importType === 'Chart of Accounts'
            ? 'Columns: account_code, name, account_type, optional normal_balance and is_active.'
            : 'Columns: journal_key, accounting_date (yyyy-mm-dd), account_code, debit, credit, optional description and explanation.';
    }

    get stageDisabled() {
        return this.saving || !this.form.csvText;
    }

    handleNewImport() {
        this.form = { importType: ((this.data && this.data.importTypes) || [])[0] };
        this.formError = undefined;
        this.modalOpen = true;
    }

    handleType(event) {
        this.form = { ...this.form, importType: event.target.value };
    }

    async handleFile(event) {
        const file = event.target.files && event.target.files[0];
        if (!file) {
            return;
        }
        this.formError = undefined;
        try {
            const text = await readFile(file);
            if (text.length > MAX_FILE_CHARS) {
                this.formError = 'The file is larger than 500,000 characters. Split it into smaller files.';
                return;
            }
            const lineCount = Math.max(0, text.split(/\r?\n/).filter((l) => l.trim()).length - 1);
            this.form = { ...this.form, fileName: file.name, size: file.size, csvText: text, lineCount };
        } catch (error) {
            this.formError = reduceError(error);
        }
    }

    handleCloseModal() {
        if (!this.saving) {
            this.modalOpen = false;
        }
    }

    async handleStage() {
        if (this.stageDisabled) {
            return;
        }
        this.saving = true;
        this.formError = undefined;
        try {
            const staged = await stageImport({ companyId: this.currentCompanyId, importType: this.form.importType, csvText: this.form.csvText });
            const validated = staged.replay ? staged : await validateImport({ importJobId: staged.importJobId });
            this.selectedJobId = staged.importJobId;
            this.activeTab = 'jobs';
            this.rowFilter = validated.errorCount ? 'errors' : 'all';
            this.modalOpen = false;
            this.toast(staged.replay ? 'This file was already staged; showing its import' : `Staged and validated: ${validated.validCount} valid, ${validated.errorCount} with errors`);
            await this.load();
        } catch (error) {
            this.formError = reduceError(error);
        } finally {
            this.saving = false;
        }
    }

    toast(message, tone) {
        this.dispatchEvent(new CustomEvent('sabtoast', { detail: { message, tone }, bubbles: true, composed: true }));
    }

    handleRetry() {
        this.load();
    }
}