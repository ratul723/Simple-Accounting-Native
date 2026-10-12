import { LightningElement, api } from 'lwc';
import getWorkspace from '@salesforce/apex/SABJournalWorkspaceController.getWorkspace';
import getJournal from '@salesforce/apex/SABJournalWorkspaceController.getJournal';
import reverseJournal from '@salesforce/apex/SABJournalWorkspaceController.reverseJournal';
import getBrowseData from '@salesforce/apex/SABJournalBrowseController.getBrowseData';
import { formatNumber, formatDate } from 'c/sabFormat';
import { amount, periodOf, reduceError } from 'c/sabJournalShared';

const REVERSIBLE = ['Manual', 'Opening', 'Allocation'];
const MIN_REASON = 10;

function todayIso() {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/**
 * Journal reversals workspace in the Harbourline demo layout (G22G-1): posted journals that can be reversed, reversal
 * history, and a two-pane original against reversal preview with date choice and a required reason, on
 * SABJournalWorkspaceController.reverseJournal (unchanged).
 */
export default class SabReversalsWorkspace extends LightningElement {
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
    selectedId;
    lines;
    detailError;
    dateChoice = 'orig';
    reason = '';
    busy = false;
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
            this.pick(value);
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
            const [ctx, browse] = await Promise.all([getWorkspace({ companyId }), getBrowseData({ companyId })]);
            if (sequence !== this.loadSequence) {
                return;
            }
            this.ctx = ctx;
            this.browse = browse;
            const eligible = this.eligible;
            const wanted = [this.requestedRecordId, this.selectedId].find((id) => id && eligible.some((j) => j.journalId === id));
            const target = wanted || (eligible[0] || {}).journalId;
            if (target) {
                await this.pick(target);
            } else {
                this.selectedId = undefined;
                this.lines = undefined;
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

    async pick(journalId) {
        const sequence = ++this.detailSequence;
        this.selectedId = journalId;
        this.reason = '';
        this.dateChoice = 'orig';
        this.detailError = undefined;
        try {
            const detail = await getJournal({ journalId });
            if (sequence === this.detailSequence) {
                this.lines = detail.lines || [];
            }
        } catch (error) {
            if (sequence === this.detailSequence) {
                this.lines = undefined;
                this.detailError = reduceError(error);
            }
        }
    }

    // ---------- lists ----------

    get showLoading() {
        return this.isLoading && !this.browse && !this.errorMessage;
    }

    get journals() {
        return (this.browse && this.browse.journals) || [];
    }

    get eligible() {
        return this.journals.filter((j) => j.status === 'Posted' && REVERSIBLE.includes(j.entryType));
    }

    get eligibleRows() {
        return this.eligible.map((j) => ({
            ...j,
            className: j.journalId === this.selectedId ? 'li click sel' : 'li click',
            current: j.journalId === this.selectedId ? 'true' : 'false',
            totalText: formatNumber(j.totalDebit)
        }));
    }

    get hasEligible() {
        return this.eligibleRows.length > 0;
    }

    get historyRows() {
        return this.journals
            .filter((j) => j.entryType === 'Reversal')
            .map((j) => ({ ...j, title: `${j.reversalOfName || 'A journal'} reversed by ${j.name}`, detail: [formatDate(j.accountingDate), j.postedBy].filter(Boolean).join(', ') }));
    }

    get hasHistory() {
        return this.historyRows.length > 0;
    }

    handlePick(event) {
        if (event.type === 'keydown') {
            if (event.key !== 'Enter' && event.key !== ' ') {
                return;
            }
            event.preventDefault();
        }
        this.pick(event.currentTarget.dataset.id);
    }

    // ---------- reversal ----------

    get selected() {
        return this.journals.find((j) => j.journalId === this.selectedId);
    }

    get hasSelection() {
        return Boolean(this.selected && this.lines);
    }

    get accountsById() {
        return Object.fromEntries(((this.browse && this.browse.accounts) || []).map((a) => [a.accountId, a]));
    }

    get panelTitle() {
        return `Reverse ${this.selected.name}`;
    }

    get postedText() {
        const j = this.selected;
        return [j.description, `posted ${formatDate(j.accountingDate)}${j.postedBy ? ` by ${j.postedBy}` : ''}`].filter(Boolean).join(', ');
    }

    get originalRows() {
        const accounts = this.accountsById;
        return (this.lines || []).map((l, i) => {
            const a = accounts[l.glAccountId];
            return {
                key: `l${i}`,
                code: a ? a.code : '',
                name: a ? a.name : '',
                debitText: amount(l.debit) ? formatNumber(l.debit) : '',
                creditText: amount(l.credit) ? formatNumber(l.credit) : '',
                reversalDebitText: amount(l.credit) ? formatNumber(l.credit) : '',
                reversalCreditText: amount(l.debit) ? formatNumber(l.debit) : ''
            };
        });
    }

    get nextPeriodStart() {
        const today = todayIso();
        const next = ((this.browse && this.browse.periods) || []).find((p) => p.status === 'Open' && p.startDate > today);
        return next ? next.startDate : undefined;
    }

    get dateButtons() {
        return [
            { id: 'orig', label: 'Original date' },
            { id: 'today', label: 'Today' },
            { id: 'next', label: 'Next period start', disabled: !this.nextPeriodStart }
        ].map((b) => ({ ...b, className: b.id === this.dateChoice ? 'on' : '', pressed: b.id === this.dateChoice ? 'true' : 'false' }));
    }

    handleDate(event) {
        this.dateChoice = event.currentTarget.dataset.id;
    }

    get reversalDate() {
        if (this.dateChoice === 'today') {
            return todayIso();
        }
        if (this.dateChoice === 'next') {
            return this.nextPeriodStart || todayIso();
        }
        return this.selected ? this.selected.accountingDate : todayIso();
    }

    get reversalPeriod() {
        return periodOf((this.browse && this.browse.periods) || [], this.reversalDate);
    }

    get dateText() {
        const p = this.reversalPeriod;
        return `${formatDate(this.reversalDate)} in ${p ? `${p.periodKey} (${p.status.toLowerCase()})` : 'no accounting period'}`;
    }

    get blocked() {
        const p = this.reversalPeriod;
        return !p || p.status !== 'Open';
    }

    get blockedTitle() {
        const p = this.reversalPeriod;
        return p ? `${p.periodKey} is ${p.status.toLowerCase()}` : 'No accounting period for this date';
    }

    handleReason(event) {
        this.reason = event.target.value;
    }

    get reasonHint() {
        return this.reason.trim().length < MIN_REASON ? `Enter at least ${MIN_REASON} characters of reason.` : '';
    }

    get canReverse() {
        return Boolean(this.ctx && this.ctx.canReverseJournal);
    }

    get postDisabled() {
        return this.busy || !this.canReverse || this.blocked || this.reason.trim().length < MIN_REASON;
    }

    get postTitle() {
        if (!this.canReverse) {
            return `${(this.persona && this.persona.label) || 'Your'} role cannot reverse journals`;
        }
        return undefined;
    }

    async handlePost() {
        if (this.postDisabled) {
            return;
        }
        this.busy = true;
        try {
            const result = await reverseJournal({
                originalJournalId: this.selectedId,
                reversalPeriodId: this.reversalPeriod.periodId,
                reversalDate: this.reversalDate,
                reason: this.reason.trim()
            });
            this.toast(result && result.replay ? `${this.selected.name} was already reversed` : `${this.selected.name} reversed by ${result.reversalJournalName}`);
            this.requestedRecordId = undefined;
            this.selectedId = undefined;
            await this.load();
        } catch (error) {
            this.toast(reduceError(error), 'bad');
        } finally {
            this.busy = false;
        }
    }

    toast(message, tone) {
        this.dispatchEvent(new CustomEvent('sabtoast', { detail: { message, tone }, bubbles: true, composed: true }));
    }

    handleRetry() {
        this.load();
    }
}
