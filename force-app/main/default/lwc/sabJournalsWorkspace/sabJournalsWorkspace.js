import { LightningElement, api } from 'lwc';
import getWorkspace from '@salesforce/apex/SABJournalWorkspaceController.getWorkspace';
import getJournal from '@salesforce/apex/SABJournalWorkspaceController.getJournal';
import saveDraft from '@salesforce/apex/SABJournalWorkspaceController.saveDraft';
import validateOnServer from '@salesforce/apex/SABJournalWorkspaceController.validateJournal';
import postJournal from '@salesforce/apex/SABJournalWorkspaceController.postJournal';
import getBrowseData from '@salesforce/apex/SABJournalBrowseController.getBrowseData';
import { formatNumber, formatDate, formatDateTime, chipClass } from 'c/sabFormat';
import { MAX_LINES, amount, validateJournal, balance, issueIcon, reduceError } from 'c/sabJournalShared';

const FILTERS = ['All', 'Draft', 'Posted', 'Reversed'];
const REVERSIBLE = ['Manual', 'Opening', 'Allocation'];

let lineSequence = 0;
const nextKey = () => `line-${++lineSequence}`;
const blankLine = () => ({ key: nextKey(), glAccountId: '', explanation: '', departmentId: '', costCenterId: '', projectId: '', debit: '', credit: '' });

function todayIso() {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/**
 * Journals workspace in the Harbourline demo layout (G22G-1): filterable journal list, editable grid with a live
 * balance meter, validation panel and posting preview, on SABJournalWorkspaceController (unchanged) and the
 * SABJournalBrowseController read model.
 */
export default class SabJournalsWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api periodKey;

    ctx;
    browse;
    errorMessage;
    isLoading = false;
    filter = 'All';
    selectedId;
    journal;
    detailError;
    busy = false;
    previewOpen = false;
    loadSequence = 0;
    detailSequence = 0;
    currentCompanyId;
    requestedRecordId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.selectedId = undefined;
            this.journal = undefined;
            this.load();
        }
    }

    @api
    get recordId() {
        return this.requestedRecordId;
    }
    set recordId(value) {
        this.requestedRecordId = value;
        if (value && this.browse && value !== this.selectedId) {
            this.openJournal(value);
        }
    }

    async load(keepSelection) {
        const companyId = this.currentCompanyId;
        const sequence = ++this.loadSequence;
        if (!companyId) {
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const [ctx, browse] = await Promise.all([getWorkspace({ companyId }), getBrowseData({ companyId })]);
            if (sequence !== this.loadSequence) {
                return;
            }
            this.ctx = ctx;
            this.browse = browse;
            const target = keepSelection || this.requestedRecordId || this.selectedId || ((browse.journals || [])[0] || {}).journalId;
            if (target) {
                await this.openJournal(target);
            } else {
                this.journal = undefined;
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

    async openJournal(journalId) {
        const sequence = ++this.detailSequence;
        this.selectedId = journalId;
        this.detailError = undefined;
        try {
            const detail = await getJournal({ journalId });
            if (sequence !== this.detailSequence) {
                return;
            }
            this.journal = {
                journalId: detail.journalId,
                name: detail.journalName,
                status: detail.status,
                entryType: detail.entryType,
                accountingDate: detail.accountingDate,
                description: detail.description || '',
                lines: (detail.lines || []).map((l) => ({
                    key: nextKey(),
                    glAccountId: l.glAccountId || '',
                    explanation: l.explanation || '',
                    departmentId: l.departmentId || '',
                    costCenterId: l.costCenterId || '',
                    projectId: l.projectId || '',
                    debit: l.debit ? String(l.debit) : '',
                    credit: l.credit ? String(l.credit) : ''
                }))
            };
            if (this.journal.status === 'Draft' && !this.journal.lines.length) {
                this.journal.lines = [blankLine(), blankLine()];
            }
        } catch (error) {
            if (sequence === this.detailSequence) {
                this.journal = undefined;
                this.detailError = reduceError(error);
            }
        }
    }

    // ---------- lookups ----------

    get accountsById() {
        return Object.fromEntries(((this.browse && this.browse.accounts) || []).map((a) => [a.accountId, a]));
    }

    /** Projects are an optional dimension: shown when the company has projects and the Projects feature is on. */
    get showProjects() {
        const off = ((this.caps && this.caps.disabledFeatures) || []).includes('PROJECTS');
        return !off && Boolean(this.ctx && (this.ctx.projects || []).length);
    }

    get optionName() {
        const map = {};
        for (const list of [this.ctx && this.ctx.departments, this.ctx && this.ctx.costCenters, this.ctx && this.ctx.projects]) {
            (list || []).forEach((o) => {
                map[o.value] = o.label;
            });
        }
        return map;
    }

    get browseRow() {
        return ((this.browse && this.browse.journals) || []).find((j) => j.journalId === this.selectedId);
    }

    // ---------- header ----------

    get canCreate() {
        return Boolean(this.caps && this.caps.canCreateJournal);
    }

    get personaLabel() {
        return (this.persona && this.persona.label) || 'Your';
    }

    get newDisabled() {
        return !this.canCreate;
    }

    get newTitle() {
        return this.canCreate ? undefined : `${this.personaLabel} role cannot create journals`;
    }

    get showLoading() {
        return this.isLoading && !this.browse && !this.errorMessage;
    }

    get cur() {
        return (this.ctx && this.ctx.functionalCurrency) || this.currencyCode || '';
    }

    // ---------- list ----------

    get filterButtons() {
        return FILTERS.map((f) => ({ id: f, label: f, className: f === this.filter ? 'on' : '', pressed: f === this.filter ? 'true' : 'false' }));
    }

    handleFilter(event) {
        this.filter = event.currentTarget.dataset.id;
    }

    get listRows() {
        return ((this.browse && this.browse.journals) || [])
            .filter((j) => this.filter === 'All' || j.status === this.filter)
            .map((j) => ({
                ...j,
                className: j.journalId === this.selectedId ? 'li click sel' : 'li click',
                current: j.journalId === this.selectedId ? 'true' : 'false',
                meta: `${formatDate(j.accountingDate)}, ${j.entryType}`,
                chip: chipClass(j.status),
                totalText: formatNumber(j.totalDebit)
            }));
    }

    get hasListRows() {
        return this.listRows.length > 0;
    }

    handleOpen(event) {
        if (event.type === 'keydown') {
            if (event.key !== 'Enter' && event.key !== ' ') {
                return;
            }
            event.preventDefault();
        }
        this.openJournal(event.currentTarget.dataset.id);
    }

    handleNew() {
        if (!this.canCreate) {
            return;
        }
        this.selectedId = undefined;
        this.detailError = undefined;
        this.journal = { journalId: null, name: 'New journal', status: 'Draft', entryType: 'Manual', accountingDate: todayIso(), description: '',
            lines: [blankLine(), blankLine()], isNew: true };
    }

    // ---------- editor ----------

    get isDraft() {
        return Boolean(this.journal && this.journal.status === 'Draft');
    }

    get editable() {
        return this.isDraft && this.canCreate;
    }

    get readOnlyDraft() {
        return this.isDraft && !this.canCreate;
    }

    get validation() {
        return validateJournal(this.journal || { lines: [] }, (this.browse && this.browse.periods) || [], this.accountsById);
    }

    get headerChip() {
        return chipClass(this.journal.status);
    }

    get editorSub() {
        if (this.isDraft) {
            const owner = this.browseRow && this.browseRow.createdBy;
            return this.journal.isNew ? 'Unsaved draft' : `Draft owned by ${owner || 'you'}`;
        }
        return this.journal.status === 'Reversed' ? 'Reversed, lines remain visible for audit' : 'Posted journals are immutable. Corrections use a reversal.';
    }

    get lockBanner() {
        if (this.isDraft) {
            return undefined;
        }
        const row = this.browseRow || {};
        return this.journal.status === 'Reversed'
            ? { className: 'banner t-warn', icon: 'alert', title: `Reversed by ${row.reversalJournalName || 'a reversal journal'}`, text: 'The original and its reversal both stay in the ledger.' }
            : { className: 'banner t-info', icon: 'lock', title: 'Locked', text: 'Only a reversal can change the effect of this journal.' };
    }

    get periodView() {
        const p = this.validation.period;
        return p ? { key: p.periodKey, status: p.status, chip: chipClass(p.status, p.status === 'Open' ? 'accent' : 'neutral') } : undefined;
    }

    get errorCells() {
        return new Set(this.validation.issues.filter((x) => x.level === 'b' && x.line !== undefined).map((x) => `${x.line}:${x.field}`));
    }

    get accountOptions() {
        return ((this.browse && this.browse.accounts) || [])
            .filter((a) => a.active)
            .map((a) => ({ value: a.accountId, label: `${a.code} ${a.name}${a.manualPostingAllowed ? '' : ' (control)'}` }));
    }

    get lineRows() {
        const errors = this.errorCells;
        const accounts = this.accountsById;
        const names = this.optionName;
        const opts = (list, value) => (list || []).map((o) => ({ value: o.value, label: o.label, selected: o.value === value }));
        return (this.journal.lines || []).map((l, i) => {
            const account = accounts[l.glAccountId];
            return {
                ...l,
                index: i,
                number: i + 1,
                glClass: errors.has(`${i}:gl`) ? 'gl err' : 'gl',
                debitClass: errors.has(`${i}:debit`) ? 'amt err' : 'amt',
                accountOptions: this.accountOptions.map((o) => ({ ...o, selected: o.value === l.glAccountId })),
                departmentOptions: opts(this.ctx && this.ctx.departments, l.departmentId),
                costCenterOptions: opts(this.ctx && this.ctx.costCenters, l.costCenterId),
                projectOptions: opts(this.ctx && this.ctx.projects, l.projectId),
                projectName: l.projectId ? names[l.projectId] : '',
                projLabel: `Project line ${i + 1}`,
                accountCode: account ? account.code : '',
                accountName: account ? account.name : 'No account yet',
                departmentName: l.departmentId ? names[l.departmentId] : '',
                costCenterName: l.costCenterId ? names[l.costCenterId] : '',
                debitText: amount(l.debit) ? formatNumber(l.debit) : '',
                creditText: amount(l.credit) ? formatNumber(l.credit) : '',
                removeLabel: `Remove line ${i + 1}`,
                glLabel: `GL account line ${i + 1}`,
                descLabel: `Description line ${i + 1}`,
                deptLabel: `Department line ${i + 1}`,
                ccLabel: `Cost center line ${i + 1}`,
                debitLabel: `Debit line ${i + 1}`,
                creditLabel: `Credit line ${i + 1}`
            };
        });
    }

    get lineCountText() {
        return `${(this.journal.lines || []).length} of ${MAX_LINES} lines`;
    }

    get summary() {
        const v = this.validation;
        return balance(v.debit, v.credit);
    }

    get issues() {
        return this.validation.issues.map((x, i) => ({ key: `i${i}`, className: `issue ${x.level}`, icon: issueIcon(x.level), message: x.message }));
    }

    get postedFacts() {
        const row = this.browseRow || {};
        const facts = [
            ['Accounting date', `${formatDate(this.journal.accountingDate)}${row.periodKey ? ` (${row.periodKey})` : ''}`],
            ['Entry type', this.journal.entryType],
            ['Posted by', [row.postedBy, formatDateTime(row.postedAt)].filter(Boolean).join(' on ') || '\u2014'],
            ['Accounting event', row.accountingEventName || '\u2014'],
            ['Posting key', row.postingKey || '\u2014']
        ];
        if (row.reversalOfName) {
            facts.push(['Reverses', row.reversalOfName]);
        }
        if (row.reversalJournalName) {
            facts.push(['Reversed by', row.reversalJournalName]);
        }
        return facts.map(([label, value]) => ({ key: label, valueKey: `${label}-value`, label, value }));
    }

    handleHeader(event) {
        const field = event.target.dataset.field;
        this.journal = { ...this.journal, [field]: event.target.value };
    }

    handleLine(event) {
        const index = Number(event.target.dataset.index);
        const field = event.target.dataset.field;
        const lines = this.journal.lines.map((l, i) => (i === index ? { ...l, [field]: event.target.value } : l));
        this.journal = { ...this.journal, lines };
    }

    handleAddLine() {
        if (this.journal.lines.length >= MAX_LINES) {
            this.toast(`Journals are limited to ${MAX_LINES} lines.`, 'bad');
            return;
        }
        this.journal = { ...this.journal, lines: [...this.journal.lines, blankLine()] };
    }

    handleRemoveLine(event) {
        const index = Number(event.currentTarget.dataset.index);
        const lines = this.journal.lines.filter((l, i) => i !== index);
        this.journal = { ...this.journal, lines: lines.length ? lines : [blankLine()] };
    }

    // ---------- actions ----------

    get canPost() {
        return Boolean(this.ctx && this.ctx.canPostJournal);
    }

    get postDisabled() {
        return this.busy || !this.canPost || !this.validation.ok;
    }

    get postTitle() {
        if (!this.canPost) {
            return `${this.personaLabel} role cannot post journals`;
        }
        return this.validation.ok ? undefined : 'Fix the blocking issues first';
    }

    get saveDisabled() {
        return this.busy || !this.journal.accountingDate || !this.validation.period || this.validation.period.status !== 'Open';
    }

    get saveTitle() {
        return this.saveDisabled && !this.busy ? 'Choose an accounting date in an open period to save' : undefined;
    }

    get canReverse() {
        return Boolean(this.ctx && this.ctx.canReverseJournal);
    }

    get showReverse() {
        return this.journal && this.journal.status === 'Posted' && REVERSIBLE.includes(this.journal.entryType) &&
            Array.isArray(this.visibleWorkspaces) && this.visibleWorkspaces.includes('reversal');
    }

    get reverseTitle() {
        return this.canReverse ? undefined : `${this.personaLabel} role cannot reverse journals`;
    }

    get reverseDisabled() {
        return !this.canReverse;
    }

    buildRequest() {
        const v = this.validation;
        return {
            journalId: this.journal.journalId || null,
            companyId: this.currentCompanyId,
            periodId: v.period ? v.period.periodId : null,
            accountingDate: this.journal.accountingDate || null,
            description: this.journal.description || null,
            lines: this.journal.lines
                .filter((l) => l.glAccountId || amount(l.debit) || amount(l.credit))
                .map((l) => ({
                    glAccountId: l.glAccountId || null,
                    debit: amount(l.debit) || null,
                    credit: amount(l.credit) || null,
                    explanation: l.explanation || null,
                    departmentId: l.departmentId || null,
                    costCenterId: l.costCenterId || null,
                    projectId: l.projectId || null
                }))
        };
    }

    async save() {
        const saved = await saveDraft({ request: this.buildRequest() });
        this.journal = { ...this.journal, journalId: saved.journalId, name: saved.journalName, isNew: false };
        this.selectedId = saved.journalId;
        return saved.journalId;
    }

    async handleSave() {
        if (this.saveDisabled) {
            return;
        }
        this.busy = true;
        try {
            const journalId = await this.save();
            this.toast(`${this.journal.name} saved`);
            await this.load(journalId);
        } catch (error) {
            this.toast(reduceError(error), 'bad');
        } finally {
            this.busy = false;
        }
    }

    handlePreview() {
        this.previewOpen = true;
    }

    handleClosePreview() {
        this.previewOpen = false;
    }

    async handlePost() {
        if (this.postDisabled) {
            return;
        }
        this.busy = true;
        try {
            const journalId = await this.save();
            const check = await validateOnServer({ journalId });
            if (!check.isValid) {
                this.toast((check.errors || []).join(' ') || 'The journal is not valid.', 'bad');
                await this.load(journalId);
                return;
            }
            const result = await postJournal({ journalId });
            this.previewOpen = false;
            this.toast(result && result.replay ? `${this.journal.name} was already posted` : `${this.journal.name} posted`);
            await this.load(journalId);
        } catch (error) {
            this.toast(reduceError(error), 'bad');
        } finally {
            this.busy = false;
        }
    }

    handleReverse() {
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'reversal', recordId: this.journal.journalId }, bubbles: true, composed: true }));
    }

    // ---------- preview ----------

    get preview() {
        const v = this.validation;
        const accounts = this.accountsById;
        const names = this.optionName;
        const lines = this.journal.lines
            .filter((l) => amount(l.debit) || amount(l.credit))
            .map((l) => {
                const account = accounts[l.glAccountId];
                return {
                    key: l.key,
                    hasAccount: Boolean(account),
                    code: account ? account.code : '',
                    accountName: account ? account.name : '',
                    department: l.departmentId ? names[l.departmentId] : '\u2014',
                    debitText: amount(l.debit) ? formatNumber(l.debit) : '',
                    creditText: amount(l.credit) ? formatNumber(l.credit) : ''
                };
            });
        const blocking = v.issues.filter((x) => x.level === 'b').map((x, i) => ({ key: `b${i}`, message: x.message }));
        const warnings = v.issues.filter((x) => x.level === 'w').map((x, i) => ({ key: `w${i}`, className: 'issue w', message: x.message }));
        return {
            heading: `Posting preview for ${this.journal.name}`,
            sub: `${this.journal.description || 'Untitled journal'}, ${formatDate(this.journal.accountingDate)}`,
            ok: v.ok,
            blocking,
            lines,
            hasLines: lines.length > 0,
            debitText: formatNumber(v.debit),
            creditText: formatNumber(v.credit),
            periodText: v.period ? `${v.period.periodKey}, ${v.period.status.toLowerCase()}` : 'No accounting period',
            warnings,
            hasWarnings: warnings.length > 0
        };
    }

    get previewHeading() {
        return this.previewOpen && this.journal ? this.preview.heading : '';
    }

    get previewSub() {
        return this.previewOpen && this.journal ? this.preview.sub : '';
    }

    toast(message, tone) {
        this.dispatchEvent(new CustomEvent('sabtoast', { detail: { message, tone }, bubbles: true, composed: true }));
    }

    handleRetry() {
        this.load();
    }
}