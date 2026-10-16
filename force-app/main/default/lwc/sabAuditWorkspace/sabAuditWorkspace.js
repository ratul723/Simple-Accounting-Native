import { LightningElement, api } from 'lwc';
import getTimeline from '@salesforce/apex/SABAuditTimelineController.getTimeline';
import { formatDateShort } from 'c/sabFormat';

const KINDS = ['All', 'Posting', 'Reversal', 'Period', 'Approval', 'Settlement', 'Import', 'Event', 'Business'];
const TONE = { Posting: 'good', Reversal: 'warn', Period: 'accent', Approval: 'info', Settlement: 'good', Import: 'info', Event: 'neutral', Business: 'neutral' };
const ICON = { Posting: 'journal', Reversal: 'reverse', Period: 'close', Approval: 'check', Settlement: 'link', Import: 'import', Event: 'spark', Business: 'file' };

function reduceError(error) {
    if (!error) {
        return 'Something went wrong.';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return (error.body && error.body.message) || error.message || 'Something went wrong.';
}

/** Sentence case for action names such as LOAN_APPROVED or Manual Journal. */
function sentence(text) {
    const words = String(text || '').replace(/_/g, ' ').trim().toLowerCase();
    return words ? words.charAt(0).toUpperCase() + words.slice(1) : '';
}

/** Rewrites service separators into the demo's plain wording (no middle dots or arrows). */
function plain(text) {
    return String(text || '').replace(/\s*\u00b7\s*/g, ', ').replace(/\s*\u2192\s*/g, ' to ');
}

/** Maps a timeline item onto the demo's event kinds. */
export function kindOf(item) {
    const action = String(item.title || '').toUpperCase();
    if (item.category === 'JOURNAL') {
        return item.status === 'Reversed' && /REVERSED/.test(action) ? 'Reversal' : 'Posting';
    }
    if (item.category === 'PERIOD') {
        return 'Period';
    }
    if (item.category === 'EVENT') {
        return 'Event';
    }
    if (/REVERS/.test(action)) {
        return 'Reversal';
    }
    if (/APPROV|REJECT|DECISION|SUBMIT/.test(action)) {
        return 'Approval';
    }
    if (/SETTL|PAYMENT|REPAY|RELEASE|DISBURS|RECEIPT/.test(action)) {
        return 'Settlement';
    }
    if (/IMPORT|INTEGRATION/.test(action)) {
        return 'Import';
    }
    return 'Business';
}

function titleOf(item, kind) {
    if (item.category === 'JOURNAL') {
        const name = String(item.title || '').split('\u00b7').pop().trim();
        return kind === 'Reversal' ? `${name} reversed` : `${name} posted`;
    }
    if (item.category === 'BUSINESS') {
        return sentence(item.title);
    }
    return sentence(plain(item.title));
}

/**
 * Audit and action history in the Harbourline demo layout (G22G-2): a timeline with kind filter and search, and the
 * event counts by type, on SABAuditTimelineController (unchanged). The export downloads the filtered list as CSV.
 */
export default class SabAuditWorkspace extends LightningElement {
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
    kind = 'All';
    query = '';
    loadSequence = 0;
    currentCompanyId;

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

    async load() {
        const companyId = this.currentCompanyId;
        const sequence = ++this.loadSequence;
        if (!companyId) {
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const result = await getTimeline({ companyId });
            if (sequence === this.loadSequence) {
                this.data = result;
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

    get events() {
        return ((this.data && this.data.items) || [])
            .map((item) => {
                const kind = kindOf(item);
                const at = item.occurredAt ? new Date(item.occurredAt) : null;
                const valid = at && !Number.isNaN(at.getTime());
                const iso = valid ? `${at.getFullYear()}-${String(at.getMonth() + 1).padStart(2, '0')}-${String(at.getDate()).padStart(2, '0')}` : '';
                return {
                    key: item.itemKey,
                    kind,
                    title: titleOf(item, kind),
                    detail: plain(item.detail),
                    actor: item.actorName || 'System',
                    requestKey: item.requestKey || '',
                    status: item.status,
                    sortKey: valid ? at.getTime() : 0,
                    dateText: formatDateShort(iso),
                    timeText: valid ? `${String(at.getHours()).padStart(2, '0')}:${String(at.getMinutes()).padStart(2, '0')}` : '',
                    dotClass: `tl-dot t-${TONE[kind]}`,
                    icon: ICON[kind],
                    initials: (item.actorName || 'System').split(/\s+/).map((w) => w[0]).join('').slice(0, 2).toUpperCase()
                };
            })
            .sort((a, b) => b.sortKey - a.sortKey);
    }

    get filtered() {
        const q = this.query.trim().toLowerCase();
        return this.events.filter((e) => (this.kind === 'All' || e.kind === this.kind) &&
            (!q || `${e.title} ${e.detail} ${e.actor} ${e.requestKey}`.toLowerCase().includes(q)));
    }

    get hasEvents() {
        return this.filtered.length > 0;
    }

    get kindButtons() {
        return KINDS.map((k) => ({ id: k, label: k, className: k === this.kind ? 'on' : '', pressed: k === this.kind ? 'true' : 'false' }));
    }

    handleKind(event) {
        this.kind = event.currentTarget.dataset.id;
    }

    handleQuery(event) {
        this.query = event.target.value || '';
    }

    get counts() {
        const all = this.events;
        return KINDS.slice(1)
            .map((k) => ({ key: k, label: k, count: all.filter((e) => e.kind === k).length }))
            .filter((c) => c.count > 0);
    }

    get total() {
        return this.events.length;
    }

    get exportDisabled() {
        return !this.data;
    }

    handleExport() {
        if (!this.hasEvents) {
            this.dispatchEvent(new CustomEvent('sabtoast', { detail: { message: 'Nothing to export for this filter', tone: 'bad' }, bubbles: true, composed: true }));
            return;
        }
        const quote = (v) => `"${String(v === null || v === undefined ? '' : v).replace(/"/g, '""')}"`;
        const lines = ['date,time,kind,title,detail,actor,key',
            ...this.filtered.map((e) => [e.dateText, e.timeText, e.kind, e.title, e.detail, e.actor, e.requestKey].map(quote).join(','))];
        const link = this.template.querySelector('.sab-download');
        link.href = `data:text/csv;charset=utf-8,${encodeURIComponent(lines.join('\n'))}`;
        link.download = 'audit-history.csv';
        link.click();
        this.dispatchEvent(new CustomEvent('sabtoast', { detail: { message: `Exported ${this.filtered.length} events` }, bubbles: true, composed: true }));
    }

    handleRetry() {
        this.load();
    }
}