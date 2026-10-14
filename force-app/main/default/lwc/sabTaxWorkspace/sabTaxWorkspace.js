import { LightningElement, api } from 'lwc';
import getWorkspace from '@salesforce/apex/SABTaxReturnWorkspaceController.getWorkspace';
import getReturnDetail from '@salesforce/apex/SABTaxReturnWorkspaceController.getReturnDetail';
import prepareReturn from '@salesforce/apex/SABTaxReturnWorkspaceController.prepareReturn';
import setAdjustment from '@salesforce/apex/SABTaxReturnWorkspaceController.setAdjustment';
import reviewReturn from '@salesforce/apex/SABTaxReturnLifecycleService.reviewReturn';
import submitReturn from '@salesforce/apex/SABTaxReturnLifecycleService.submitReturn';
import recordAuthorityOutcome from '@salesforce/apex/SABTaxReturnLifecycleService.recordAuthorityOutcome';
import createAmendment from '@salesforce/apex/SABTaxReturnLifecycleService.createAmendment';
import getSetupOptions from '@salesforce/apex/SABSetupActionService.getOptions';
import saveTaxRegistration from '@salesforce/apex/SABSetupActionService.saveTaxRegistration';
import { formatNumber, formatDate, formatDateTime, chipClass } from 'c/sabFormat';
import { reduceError, newKey, toast } from 'c/sabMoneyShared';

const STEPS = ['Prepare', 'Review', 'Submit', 'Outcome'];
const STEP_INDEX = { Draft: 0, Prepared: 1, Reviewed: 2, Submitted: 3, Accepted: 4, Rejected: 4, Amended: 4 };

function iso(d) {
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/**
 * Tax in the Harbourline demo layout (G22G-6): tax returns with the Prepare, Review, Submit, Outcome stepper, box lines
 * with adjustments, amount payable, previous returns and registrations, on SABTaxReturnWorkspaceController and
 * SABTaxReturnLifecycleService, unchanged. The app prepares returns; it does not lodge them.
 */
export default class SabTaxWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api periodKey;

    data;
    detail;
    errorMessage;
    detailError;
    isLoading = false;
    activeTab = 'ret';
    selectedId;
    busy = false;
    modal;
    form = {};
    formError;
    requestKeys = {};
    frequencies = [];
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
        if (value && this.data) {
            this.select(value);
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
            const data = await getWorkspace({ companyId });
            if (sequence !== this.loadSequence) {
                return;
            }
            this.data = data;
            const returns = data.returns || [];
            const wanted = [this.requestedRecordId, this.selectedId].find((id) => id && returns.some((r) => r.taxReturnId === id));
            await this.select(wanted || (returns[0] || {}).taxReturnId);
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

    async select(taxReturnId) {
        const sequence = ++this.detailSequence;
        this.selectedId = taxReturnId;
        this.detailError = undefined;
        if (!taxReturnId) {
            this.detail = undefined;
            return;
        }
        try {
            const detail = await getReturnDetail({ taxReturnId });
            if (sequence === this.detailSequence) {
                this.detail = detail;
            }
        } catch (error) {
            if (sequence === this.detailSequence) {
                this.detail = undefined;
                this.detailError = reduceError(error);
            }
        }
    }

    get showLoading() {
        return this.isLoading && !this.data && !this.errorMessage;
    }

    get cur() {
        return (this.data && this.data.functionalCurrency) || this.currencyCode || '';
    }

    get can() {
        return (this.data && this.data.capabilities) || {};
    }

    get personaLabel() {
        return (this.persona && this.persona.label) || 'Your';
    }

    reason(allowed, action) {
        return allowed ? undefined : `${this.personaLabel} role cannot ${action}`;
    }

    // ---------- tabs ----------

    get tabs() {
        const d = this.data || {};
        return [
            { id: 'ret', label: 'Returns', count: (d.returns || []).length },
            { id: 'reg', label: 'Registrations', count: (d.registrations || []).length }
        ].map((t) => ({ ...t, className: t.id === this.activeTab ? 'tab active' : 'tab', selected: t.id === this.activeTab ? 'true' : 'false' }));
    }

    handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    get isReturns() {
        return this.activeTab === 'ret';
    }

    get registrationRows() {
        return ((this.data && this.data.registrations) || []).map((r) => ({
            ...r,
            fromText: formatDate(r.effectiveFrom),
            toText: r.effectiveTo ? formatDate(r.effectiveTo) : '\u2014',
            chip: chipClass(r.effectiveTo ? 'Ended' : 'Active', r.effectiveTo ? 'neutral' : 'good'),
            statusText: r.effectiveTo ? 'Ended' : 'Active'
        }));
    }

    get hasRegistrations() {
        return this.registrationRows.length > 0;
    }

    // ---------- returns ----------

    get returnRows() {
        return ((this.data && this.data.returns) || []).map((r) => ({
            ...r,
            className: r.taxReturnId === this.selectedId ? 'click sel' : 'click',
            periodText: `${formatDate(r.periodStart)} to ${formatDate(r.periodEnd)}`,
            dueText: formatNumber(r.netTaxDue, 0),
            chip: chipClass(r.status, r.status === 'Draft' || r.status === 'Prepared' ? 'neutral' : undefined),
            versionText: r.returnVersion > 1 ? `v${r.returnVersion}` : ''
        }));
    }

    get hasReturns() {
        return this.returnRows.length > 0;
    }

    handleRow(event) {
        if (event.type === 'keydown') {
            if (event.key !== 'Enter' && event.key !== ' ') {
                return;
            }
            event.preventDefault();
        }
        this.select(event.currentTarget.dataset.id);
    }

    get current() {
        return this.detail && this.detail.taxReturn;
    }

    get view() {
        const r = this.current;
        const idx = STEP_INDEX[r.status] === undefined ? 0 : STEP_INDEX[r.status];
        const editable = r.status === 'Prepared' && !r.sourceLocked && this.can.prepare;
        const next = {
            Prepared: { label: 'Mark as reviewed', kind: 'review', allowed: this.can.review, action: 'review tax returns' },
            Reviewed: { label: 'Record submission', kind: 'submit', allowed: this.can.submit, action: 'submit tax returns' },
            Submitted: { label: 'Record outcome', kind: 'outcome', allowed: this.can.recordOutcome, action: 'record authority outcomes' }
        }[r.status];
        return {
            title: `${r.name}${r.returnVersion > 1 ? ` v${r.returnVersion}` : ''}, ${formatDate(r.periodStart)} to ${formatDate(r.periodEnd)}`,
            sub: [r.registrationName, r.jurisdiction, r.countryPackVersion ? `pack ${r.countryPackVersion}` : null].filter(Boolean).join(', '),
            steps: STEPS.map((label, i) => ({ key: label, label, number: i + 1, done: i < idx, className: i < idx ? 'hstep done' : i === idx ? 'hstep now' : 'hstep' })),
            chip: chipClass(r.status, r.status === 'Prepared' ? 'neutral' : undefined),
            lines: ((this.detail && this.detail.lines) || []).map((l) => ({
                ...l,
                calcText: formatNumber(l.calculatedAmount),
                adjText: l.adjustmentAmount ? formatNumber(l.adjustmentAmount) : '\u2014',
                finalText: formatNumber(l.finalAmount),
                editable
            })),
            hasLines: ((this.detail && this.detail.lines) || []).length > 0,
            showNext: Boolean(next),
            nextLabel: next ? next.label : '',
            nextKind: next ? next.kind : '',
            nextDisabled: this.busy || !next || !next.allowed,
            nextTitle: next ? this.reason(next.allowed, next.action) : undefined,
            showAmend: ['Accepted', 'Rejected'].includes(r.status),
            amendDisabled: this.busy || !this.can.amend,
            amendTitle: this.reason(this.can.amend, 'amend tax returns'),
            payableText: formatNumber(r.netTaxDue),
            payableLabel: Number(r.netTaxDue) < 0 ? 'Refund due' : 'Amount payable',
            facts: [['Filing reference', r.filingReference || '\u2014'], ['Acknowledgement', r.acknowledgementReference || '\u2014'],
                ['Source', r.sourceLocked ? 'Locked at review' : 'Live, rebuilt on prepare'], ['Amends', r.amendsTaxReturnName || '\u2014']]
                .map(([label, value]) => ({ key: label, valueKey: `${label}-v`, label, value })),
            history: ((this.detail && this.detail.history) || []).map((h, i) => ({ ...h, key: `h${i}`, atText: formatDateTime(h.actionAt) })),
            hasHistory: ((this.detail && this.detail.history) || []).length > 0
        };
    }

    get prepareDisabled() {
        return this.busy || !this.can.prepare || !((this.data && this.data.registrations) || []).length;
    }

    get prepareTitle() {
        if (!this.can.prepare) {
            return `${this.personaLabel} role cannot prepare tax returns`;
        }
        return ((this.data && this.data.registrations) || []).length ? undefined : 'Add a tax registration first';
    }

    // ---------- actions ----------

    keyFor(action, recordId) {
        const name = `${action}|${recordId}`;
        if (!this.requestKeys[name]) {
            this.requestKeys = { ...this.requestKeys, [name]: newKey(`TAX-${action}`, recordId) };
        }
        return this.requestKeys[name];
    }

    async execute(action, recordId, call, message) {
        const name = `${action}|${recordId}`;
        this.busy = true;
        try {
            const result = await call(this.keyFor(action, recordId));
            const keys = { ...this.requestKeys };
            delete keys[name];
            this.requestKeys = keys;
            if (result && (result.amendmentTaxReturnId || result.taxReturnId)) {
                this.selectedId = result.amendmentTaxReturnId || result.taxReturnId;
            }
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

    async handleAdjustment(event) {
        const boxKey = event.target.dataset.box;
        const line = this.view.lines.find((l) => l.boxKey === boxKey);
        const value = event.target.value === '' ? 0 : Number(event.target.value);
        if (!line || Number(line.adjustmentAmount || 0) === value) {
            return;
        }
        this.busy = true;
        try {
            await setAdjustment({ taxReturnId: this.selectedId, boxKey, adjustmentAmount: value });
            toast(this, `Box ${boxKey} adjusted`);
            await this.select(this.selectedId);
        } catch (error) {
            toast(this, reduceError(error), 'bad');
        } finally {
            this.busy = false;
        }
    }

    openModal(kind, form) {
        this.form = form;
        this.formError = undefined;
        this.modal = kind;
    }

    handlePrepare() {
        const d = new Date();
        const quarterStart = new Date(d.getFullYear(), Math.floor(d.getMonth() / 3) * 3 - 3, 1);
        const quarterEnd = new Date(quarterStart.getFullYear(), quarterStart.getMonth() + 3, 0);
        this.openModal('prepare', { registrationId: ((this.data.registrations || [])[0] || {}).value || '', periodStart: iso(quarterStart), periodEnd: iso(quarterEnd) });
    }

    async handleAddRegistration() {
        this.openModal('registration', { name: 'GST', jurisdiction: '', identifier: '', filingFrequency: 'Quarterly', effectiveFrom: iso(new Date()), effectiveTo: '',
            countryPackVersion: '' });
        try {
            const o = await getSetupOptions({ companyId: this.currentCompanyId });
            this.frequencies = o.filingFrequencies || [];
            this.form = { ...this.form, jurisdiction: this.form.jurisdiction || o.countryCode || '', countryPackVersion: this.form.countryPackVersion || o.countryPackVersion || '' };
        } catch (error) {
            this.formError = reduceError(error);
        }
    }

    get isRegistrationModal() {
        return this.modal === 'registration';
    }

    get frequencyOptions() {
        return (this.frequencies && this.frequencies.length ? this.frequencies : ['Monthly', 'Quarterly', 'Annual'])
            .map((v) => ({ value: v, label: v, selected: v === this.form.filingFrequency }));
    }

    handleNext(event) {
        const kind = event.currentTarget.dataset.kind;
        this.openModal(kind, { reason: '', filingReference: '', outcome: 'Accepted', acknowledgementReference: '' });
    }

    handleAmend() {
        this.openModal('amend', { reason: '' });
    }

    get modalOpen() {
        return Boolean(this.modal);
    }

    get modalHeading() {
        return { registration: 'Add tax registration', prepare: 'Prepare tax return', review: 'Mark as reviewed', submit: 'Record submission', outcome: 'Record authority outcome', amend: 'Create amendment' }[this.modal];
    }

    get modalSub() {
        return {
            registration: 'Returns are prepared per registration and period.',
            prepare: 'Builds the return from posted tax lines for the registration and period.',
            review: 'Locks the source tax lines behind this return.',
            submit: 'Record the filing reference after lodging through the authority portal or your tax agent.',
            outcome: 'Record what the tax authority decided.',
            amend: 'Creates a new draft version that supersedes this return. A reason is required.'
        }[this.modal];
    }

    get saveLabel() {
        return { registration: 'Save registration', prepare: 'Prepare return', review: 'Mark as reviewed', submit: 'Record submission', outcome: 'Record outcome', amend: 'Create amendment' }[this.modal];
    }

    get isPrepareModal() {
        return this.modal === 'prepare';
    }

    get isSubmitModal() {
        return this.modal === 'submit';
    }

    get isOutcomeModal() {
        return this.modal === 'outcome';
    }

    get needsReason() {
        return this.modal !== 'prepare' && this.modal !== 'registration';
    }

    get registrationOptions() {
        return ((this.data && this.data.registrations) || []).map((r) => ({ value: r.value, label: r.label, selected: r.value === this.form.registrationId }));
    }

    get outcomeOptions() {
        return ['Accepted', 'Rejected'].map((v) => ({ value: v, label: v, selected: v === this.form.outcome }));
    }

    handleField(event) {
        this.form = { ...this.form, [event.target.dataset.field]: event.target.value };
    }

    handleCloseModal() {
        if (!this.busy) {
            this.modal = undefined;
        }
    }

    async handleSave() {
        const f = this.form;
        const id = this.selectedId;
        const reasonText = String(f.reason || '').trim() || null;
        if (this.modal === 'amend' && !reasonText) {
            this.formError = 'A reason is required.';
            return;
        }
        if (this.modal === 'submit' && !String(f.filingReference || '').trim()) {
            this.formError = 'A filing reference is required.';
            return;
        }
        if (this.modal === 'outcome' && !String(f.acknowledgementReference || '').trim()) {
            this.formError = 'An acknowledgement reference is required.';
            return;
        }
        let ok;
        if (this.modal === 'registration') {
            this.busy = true;
            try {
                await saveTaxRegistration({ request: { companyId: this.currentCompanyId, name: f.name, jurisdiction: f.jurisdiction, identifier: f.identifier,
                    filingFrequency: f.filingFrequency, effectiveFrom: f.effectiveFrom || null, effectiveTo: f.effectiveTo || null,
                    countryPackVersion: f.countryPackVersion || null, active: true }, requestKey: this.keyFor('REGISTRATION', this.currentCompanyId) });
                toast(this, 'Tax registration added');
                ok = true;
            } catch (error) {
                this.formError = reduceError(error);
            } finally {
                this.busy = false;
            }
            if (ok) {
                const keys = { ...this.requestKeys };
                delete keys[`REGISTRATION|${this.currentCompanyId}`];
                this.requestKeys = keys;
                this.modal = undefined;
                this.activeTab = 'reg';
                await this.load();
            }
            return;
        }
        if (this.modal === 'prepare') {
            this.busy = true;
            try {
                const result = await prepareReturn({ taxRegistrationId: f.registrationId || null, periodStart: f.periodStart || null, periodEnd: f.periodEnd || null });
                this.selectedId = result.taxReturnId;
                toast(this, result.rebuiltExistingReturn ? 'Tax return rebuilt from current tax lines' : 'Tax return prepared');
                ok = true;
            } catch (error) {
                this.formError = reduceError(error);
            } finally {
                this.busy = false;
            }
            if (ok) {
                this.modal = undefined;
                await this.load();
            }
            return;
        }
        if (this.modal === 'review') {
            ok = await this.execute('REVIEW', id, (key) => reviewReturn({ taxReturnId: id, requestKey: key, reason: reasonText }), 'Tax return reviewed');
        } else if (this.modal === 'submit') {
            ok = await this.execute('SUBMIT', id, (key) => submitReturn({ taxReturnId: id, filingReference: f.filingReference.trim(), requestKey: key, reason: reasonText }),
                'Submission recorded');
        } else if (this.modal === 'outcome') {
            ok = await this.execute('OUTCOME', id, (key) => recordAuthorityOutcome({ taxReturnId: id, outcome: f.outcome, acknowledgementReference: f.acknowledgementReference.trim(),
                requestKey: key, reason: reasonText }), `Return ${f.outcome.toLowerCase()}`);
        } else {
            ok = await this.execute('AMEND', id, (key) => createAmendment({ taxReturnId: id, requestKey: key, reason: reasonText }), 'Amendment created');
        }
        if (ok) {
            this.modal = undefined;
        }
    }

    handleRetry() {
        this.load();
    }
}
