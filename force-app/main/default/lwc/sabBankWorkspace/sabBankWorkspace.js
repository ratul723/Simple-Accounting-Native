import { LightningElement, api } from 'lwc';
import getDashboard from '@salesforce/apex/SABBankReconciliationWorkspaceController.getDashboard';
import getStatementWorkspace from '@salesforce/apex/SABBankReconciliationWorkspaceController.getStatementWorkspace';
import importStatement from '@salesforce/apex/SABBankReconciliationWorkspaceController.importStatement';
import validateStatement from '@salesforce/apex/SABBankReconciliationWorkspaceController.validateStatement';
import startReconciliation from '@salesforce/apex/SABBankReconciliationWorkspaceController.startReconciliation';
import getMatchCandidates from '@salesforce/apex/SABBankReconciliationWorkspaceController.getMatchCandidates';
import createManualMatch from '@salesforce/apex/SABBankReconciliationWorkspaceController.createManualMatch';
import createSuggestedMatch from '@salesforce/apex/SABBankReconciliationWorkspaceController.createSuggestedMatch';
import confirmMatch from '@salesforce/apex/SABBankReconciliationWorkspaceController.confirmMatch';
import reverseMatch from '@salesforce/apex/SABBankReconciliationWorkspaceController.reverseMatch';
import finalizeReconciliation from '@salesforce/apex/SABBankReconciliationWorkspaceController.finalizeReconciliation';
import getLedgerLines from '@salesforce/apex/SABBankLedgerLinesController.getLedgerLines';
import { formatNumber, formatDate, formatDateShort, chipClass, plural } from 'c/sabFormat';
import { reduceError, toast } from 'c/sabMoneyShared';

const DAY_WINDOW = 7;
const AUTO_SCORE = 90;

/** Suggestion score for a candidate, shaped like the demo's percentages: exact amounts by date distance, others low. */
export function scoreOf(candidate) {
    if (!candidate.exactAmount) {
        return 60;
    }
    const days = Math.abs(candidate.dateDifferenceDays || 0);
    if (days === 0) {
        return 99;
    }
    if (days <= 3) {
        return 95;
    }
    return days <= 7 ? 90 : 80;
}

/** Parses statement CSV text: date, amount, reference, optional value_date and id columns. */
export function parseStatementCsv(text) {
    const rows = String(text || '').split(/\r?\n/).filter((l) => l.trim());
    if (rows.length < 2) {
        throw new Error('The file needs a header row and at least one line.');
    }
    const header = rows[0].split(',').map((h) => h.trim().toLowerCase().replace(/\s+/g, '_'));
    const col = (name) => header.indexOf(name);
    if (col('date') < 0 || col('amount') < 0) {
        throw new Error('The file needs date and amount columns.');
    }
    return rows.slice(1).map((row, i) => {
        const cells = row.split(',').map((c) => c.trim().replace(/^"|"$/g, ''));
        const amount = Number(cells[col('amount')]);
        const date = cells[col('date')];
        if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !Number.isFinite(amount)) {
            throw new Error(`Line ${i + 2}: use yyyy-mm-dd dates and numeric amounts.`);
        }
        return {
            lineNumber: i + 1,
            transactionDate: date,
            valueDate: col('value_date') >= 0 && cells[col('value_date')] ? cells[col('value_date')] : date,
            amount,
            reference: col('reference') >= 0 ? cells[col('reference')] : null,
            providerLineId: col('id') >= 0 ? cells[col('id')] : null,
            sourceRawText: row,
            lineFingerprint: `${i + 1}|${row}`
        };
    });
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
 * Banking and reconciliation in the Harbourline demo layout (G22G-4): bank account cards, statement against ledger
 * panes with suggestion scores, accept suggestions of 90% or more, match, confirm, reverse and finalise, and statement
 * import, on SABBankReconciliationWorkspaceController (unchanged) and SABBankLedgerLinesController.
 */
export default class SabBankWorkspace extends LightningElement {
    @api companyName;
    @api currencyCode;
    @api setupStatus;
    @api persona;
    @api caps;
    @api visibleWorkspaces;
    @api recordId;
    @api periodKey;

    dashboard;
    statement;
    ledger = [];
    candidates = [];
    errorMessage;
    isLoading = false;
    selectedBankId;
    selectedStatementId;
    selectedLineId;
    selectedLedgerId;
    busy = false;
    importOpen = false;
    importForm = {};
    importError;
    loadSequence = 0;
    statementSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.selectedBankId = undefined;
            this.selectedStatementId = undefined;
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
            const result = await getDashboard({ companyId });
            if (sequence !== this.loadSequence) {
                return;
            }
            this.dashboard = result;
            const banks = result.bankAccounts || [];
            // A bank account opened from global search is selected straight away.
            if (this.recordId && banks.some((b) => b.bankAccountId === this.recordId)) {
                this.selectedBankId = this.recordId;
            }
            if (!banks.some((b) => b.bankAccountId === this.selectedBankId)) {
                this.selectedBankId = (banks[0] || {}).bankAccountId;
            }
            await this.selectStatement(this.selectedStatementId && this.statementsForBank.some((s) => s.statementId === this.selectedStatementId)
                ? this.selectedStatementId : (this.statementsForBank[0] || {}).statementId);
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

    async selectStatement(statementId) {
        const sequence = ++this.statementSequence;
        this.selectedStatementId = statementId;
        this.selectedLineId = undefined;
        this.selectedLedgerId = undefined;
        this.candidates = [];
        if (!statementId) {
            this.statement = undefined;
            this.ledger = [];
            return;
        }
        try {
            const [ws, ledger] = await Promise.all([
                getStatementWorkspace({ bankStatementId: statementId }),
                getLedgerLines({ companyId: this.currentCompanyId, bankStatementId: statementId })
            ]);
            if (sequence === this.statementSequence) {
                this.statement = ws;
                this.ledger = ledger || [];
            }
        } catch (error) {
            if (sequence === this.statementSequence) {
                this.statement = undefined;
                this.ledger = [];
                toast(this, reduceError(error), 'bad');
            }
        }
    }

    // ---------- header and cards ----------

    get showLoading() {
        return this.isLoading && !this.dashboard && !this.errorMessage;
    }

    get personaLabel() {
        return (this.persona && this.persona.label) || 'Your';
    }

    get canSeeBankDetail() {
        return Boolean(this.persona && this.persona.canViewBankDetail);
    }

    get reconciliation() {
        const s = this.statement;
        return s && s.reconciliationId ? s : undefined;
    }

    get isFinalized() {
        return Boolean(this.statement && this.statement.reconciliationStatus === 'Finalized');
    }

    get finalizeDisabled() {
        return this.busy || !this.dashboard || !this.dashboard.canFinalize || !(this.statement && this.statement.canFinalizeNow);
    }

    get finalizeTitle() {
        if (!this.dashboard || !this.dashboard.canFinalize) {
            return `${this.personaLabel} role cannot finalise reconciliations`;
        }
        if (this.isFinalized) {
            return 'This reconciliation is finalised';
        }
        return this.statement && !this.statement.canFinalizeNow ? 'Match and confirm every statement line first' : undefined;
    }

    get importDisabled() {
        return !(this.dashboard && this.dashboard.canImport) || !this.selectedBankId;
    }

    get importTitle() {
        return this.dashboard && this.dashboard.canImport ? undefined : `${this.personaLabel} role cannot import statements`;
    }

    get cards() {
        return ((this.dashboard && this.dashboard.bankAccounts) || []).map((b) => {
            const finalized = b.latestReconciliationStatus === 'Finalized';
            const selected = b.bankAccountId === this.selectedBankId;
            let status = { text: 'No statement', tone: 'neutral' };
            if (finalized) {
                status = { text: 'Reconciled', tone: 'good' };
            } else if (selected && this.statement && this.statement.reconciliationId) {
                const open = this.statement.lineCount - this.statement.fullyMatchedLineCount;
                status = open ? { text: `${open} to match`, tone: 'warn' } : { text: 'Ready to finalise', tone: 'info' };
            } else if (b.latestStatementStatus) {
                status = { text: b.latestStatementStatus, tone: 'info' };
            }
            return {
                ...b,
                className: selected ? 'cardlet click sel' : 'cardlet click',
                pressed: selected ? 'true' : 'false',
                detail: `${b.bankName || ''} ${this.canSeeBankDetail ? b.maskedAccountNumber || '' : '\u2022\u2022\u2022\u2022'}, GL ${b.glAccountCode || ''}`.trim(),
                bookText: formatNumber(b.currentBookBalance),
                chip: chipClass(status.text, status.tone),
                statusText: status.text
            };
        });
    }

    get hasBanks() {
        return this.cards.length > 0;
    }

    async handleBank(event) {
        if (event.type === 'keydown') {
            if (event.key !== 'Enter' && event.key !== ' ') {
                return;
            }
            event.preventDefault();
        }
        this.selectedBankId = event.currentTarget.dataset.id;
        await this.selectStatement((this.statementsForBank[0] || {}).statementId);
    }

    get statementsForBank() {
        return ((this.dashboard && this.dashboard.statements) || []).filter((s) => s.bankAccountId === this.selectedBankId);
    }

    get statementOptions() {
        return this.statementsForBank.map((s) => ({ value: s.statementId, label: s.label || s.name, selected: s.statementId === this.selectedStatementId }));
    }

    get hasManyStatements() {
        return this.statementOptions.length > 1;
    }

    async handleStatement(event) {
        await this.selectStatement(event.target.value);
    }

    // ---------- figures ----------

    get figures() {
        const s = this.statement;
        const book = s.storedBookClosingAmount !== null && s.storedBookClosingAmount !== undefined ? s.storedBookClosingAmount : s.provisionalBookClosingAmount;
        const diff = s.storedDifference !== null && s.storedDifference !== undefined ? s.storedDifference : s.provisionalDifference;
        const open = this.statementRows.filter((r) => !r.done);
        const net = open.reduce((t, r) => t + (Number(r.remainingAmount) || 0), 0);
        const bank = this.cards.find((c) => c.bankAccountId === this.selectedBankId) || {};
        return [
            { key: 's', label: `Statement closing, ${formatDateShort(s.endDate)}`, value: formatNumber(s.closingAmount), sub: s.bankAccountName },
            { key: 'b', label: `Book balance, GL ${bank.glAccountCode || ''}`.trim(), value: formatNumber(book), sub: 'Posted ledger' },
            { key: 'd', label: 'Difference', value: formatNumber(diff), sub: Number(diff) ? 'Explained by unmatched items' : 'Statement agrees to the ledger' },
            { key: 'r', label: 'Statement lines to resolve', value: String(open.length), sub: open.length ? `${formatNumber(net)} net` : '', good: open.length ? '' : 'All resolved' }
        ].map((f) => ({ ...f, hasGood: Boolean(f.good) }));
    }

    get statementStatusBanner() {
        const s = this.statement;
        if (!s || s.reconciliationId) {
            return undefined;
        }
        return s.statementStatus === 'Imported'
            ? { title: 'Statement imported', text: 'Validate the statement to check its totals before reconciling.', action: 'Validate statement', kind: 'validate' }
            : { title: 'Ready to reconcile', text: 'Start a reconciliation to match statement lines to the ledger.', action: 'Start reconciliation', kind: 'start' };
    }

    get finalizedBanner() {
        return this.isFinalized
            ? `${this.statement.reconciliationName} finalised. Matches are locked; any change now needs a reversal of the match.`
            : undefined;
    }

    // ---------- statement and ledger panes ----------

    get matchesByLine() {
        const map = {};
        ((this.statement && this.statement.matches) || []).filter((m) => m.status !== 'Reversed').forEach((m) => {
            (map[m.statementLineId] = map[m.statementLineId] || []).push(m);
        });
        return map;
    }

    get statementRows() {
        const matches = this.matchesByLine;
        return ((this.statement && this.statement.lines) || []).map((l) => {
            const done = Boolean(l.fullyMatched);
            const lineMatches = matches[l.lineId] || [];
            return {
                ...l,
                done,
                className: `rline${done ? ' done' : ''}${l.lineId === this.selectedLineId ? ' sel' : ''}`,
                dateText: formatDateShort(l.transactionDate),
                ref: l.reference || l.providerLineId || `Line ${l.lineNumber}`,
                sub: lineMatches.length ? `Matched to ${lineMatches.map((m) => `${m.journalName}${m.status === 'Proposed' ? ' (proposed)' : ''}`).join(', ')}`
                    : done ? 'Matched' : 'Statement line',
                amountText: formatNumber(l.amount),
                amountClass: l.amount < 0 ? 'amt neg' : 'amt',
                tabIndex: done ? undefined : '0'
            };
        });
    }

    get scores() {
        return Object.fromEntries(this.candidates.map((c) => [c.journalEntryLineId, scoreOf(c)]));
    }

    get ledgerRows() {
        const scores = this.scores;
        return this.ledger.map((l) => {
            const done = l.remainingAmount === 0;
            const score = scores[l.journalEntryLineId];
            const suggested = !done && score !== undefined;
            return {
                ...l,
                done,
                className: `rline${done ? ' done' : ''}${l.journalEntryLineId === this.selectedLedgerId ? ' sel' : suggested ? ' sug' : ''}`,
                dateText: formatDateShort(l.accountingDate),
                ref: `${l.journalName}${l.description ? `, ${l.description}` : ''}`,
                hasScore: suggested,
                scoreText: `${score}%`,
                sub: done ? 'Matched' : `${l.entryType || 'Journal'}${l.matchedAmount ? `, ${formatNumber(l.remainingAmount)} left` : ''}`,
                amountText: formatNumber(l.amount),
                amountClass: l.amount < 0 ? 'amt neg' : 'amt',
                tabIndex: done ? undefined : '0'
            };
        });
    }

    get hasStatementRows() {
        return this.statementRows.length > 0;
    }

    get hasLedgerRows() {
        return this.ledgerRows.length > 0;
    }

    get statementPaneSub() {
        const s = this.statement;
        return s ? `${s.bankAccountName}, ${formatDate(s.startDate)} to ${formatDate(s.endDate)}` : '';
    }

    get ledgerPaneTitle() {
        const bank = this.cards.find((c) => c.bankAccountId === this.selectedBankId);
        return `Posted ledger lines${bank && bank.glAccountCode ? `, GL ${bank.glAccountCode}` : ''}`;
    }

    keyOk(event) {
        if (event.type !== 'keydown') {
            return true;
        }
        if (event.key !== 'Enter' && event.key !== ' ') {
            return false;
        }
        event.preventDefault();
        return true;
    }

    async handleStatementLine(event) {
        if (!this.keyOk(event)) {
            return;
        }
        const row = this.statementRows.find((r) => r.lineId === event.currentTarget.dataset.id);
        if (!row || row.done || !this.reconciliation) {
            return;
        }
        this.selectedLineId = row.lineId;
        this.selectedLedgerId = undefined;
        try {
            this.candidates = (await getMatchCandidates({ reconciliationId: this.statement.reconciliationId, bankStatementLineId: row.lineId, dayWindow: DAY_WINDOW })) || [];
        } catch (error) {
            this.candidates = [];
            toast(this, reduceError(error), 'bad');
        }
    }

    handleLedgerLine(event) {
        if (!this.keyOk(event)) {
            return;
        }
        const row = this.ledgerRows.find((r) => r.journalEntryLineId === event.currentTarget.dataset.id);
        if (row && !row.done) {
            this.selectedLedgerId = row.journalEntryLineId === this.selectedLedgerId ? undefined : row.journalEntryLineId;
        }
    }

    // ---------- actions ----------

    get selectedLine() {
        return this.statementRows.find((r) => r.lineId === this.selectedLineId);
    }

    get selectedLedger() {
        return this.ledgerRows.find((r) => r.journalEntryLineId === this.selectedLedgerId);
    }

    get canMatch() {
        const s = this.selectedLine;
        const l = this.selectedLedger;
        return Boolean(s && l && Math.round((s.remainingAmount - l.remainingAmount) * 100) === 0);
    }

    get locked() {
        return this.busy || !this.reconciliation || this.isFinalized || !(this.dashboard && this.dashboard.canReconcile);
    }

    get matchDisabled() {
        return this.locked || !this.canMatch;
    }

    get acceptDisabled() {
        return this.locked || !this.statementRows.some((r) => !r.done);
    }

    get adjustmentDisabled() {
        return this.locked || !this.selectedLine || this.selectedLedger !== undefined || this.candidates.length > 0;
    }

    get proposed() {
        return ((this.statement && this.statement.matches) || []).filter((m) => m.status === 'Proposed');
    }

    get confirmLabel() {
        return `Confirm ${plural(this.proposed.length, 'proposed match', 'proposed matches')}`;
    }

    get confirmDisabled() {
        return this.locked || !this.proposed.length;
    }

    get hint() {
        const s = this.selectedLine;
        const l = this.selectedLedger;
        if (!this.reconciliation) {
            return '';
        }
        if (!s) {
            return 'Select a statement line to see suggestions.';
        }
        if (l) {
            return this.canMatch ? 'Amounts agree. Match them.' : `Amounts differ by ${formatNumber(Math.abs(s.remainingAmount - l.remainingAmount))}.`;
        }
        return this.candidates.length ? 'Suggested ledger lines are highlighted on the right.' : 'No ledger line found. Record it as a bank adjustment.';
    }

    async run(call, message) {
        this.busy = true;
        try {
            await call();
            if (message) {
                toast(this, message);
            }
            await this.load();
            return true;
        } catch (error) {
            toast(this, reduceError(error), 'bad');
            return false;
        } finally {
            this.busy = false;
        }
    }

    handleMatch() {
        const s = this.selectedLine;
        const l = this.selectedLedger;
        const suggested = this.scores[l.journalEntryLineId] !== undefined;
        const args = { reconciliationId: this.statement.reconciliationId, bankStatementLineId: s.lineId, journalEntryLineId: l.journalEntryLineId,
            matchedAmount: s.remainingAmount };
        this.run(() => (suggested ? createSuggestedMatch(args) : createManualMatch(args)), 'Matched, confirm it to lock the match');
    }

    async handleAccept() {
        const reconciliationId = this.statement.reconciliationId;
        const used = new Set();
        let count = 0;
        await this.run(async () => {
            for (const line of this.statementRows.filter((r) => !r.done)) {
                // eslint-disable-next-line no-await-in-loop
                const candidates = (await getMatchCandidates({ reconciliationId, bankStatementLineId: line.lineId, dayWindow: DAY_WINDOW })) || [];
                const best = candidates
                    .filter((c) => scoreOf(c) >= AUTO_SCORE && !used.has(c.journalEntryLineId) && Number(c.suggestedMatchAmount) === Number(line.remainingAmount))
                    .sort((a, b) => scoreOf(b) - scoreOf(a))[0];
                if (best) {
                    used.add(best.journalEntryLineId);
                    // eslint-disable-next-line no-await-in-loop
                    await createSuggestedMatch({ reconciliationId, bankStatementLineId: line.lineId, journalEntryLineId: best.journalEntryLineId,
                        matchedAmount: best.suggestedMatchAmount });
                    count++;
                }
            }
        }, null);
        toast(this, count ? `${plural(count, 'suggestion')} accepted, confirm them to lock the matches` : 'No suggestions of 90% or more');
    }

    async handleConfirmAll() {
        const ids = this.proposed.map((m) => m.matchId);
        await this.run(async () => {
            for (const matchId of ids) {
                // eslint-disable-next-line no-await-in-loop
                await confirmMatch({ matchId });
            }
        }, `${plural(ids.length, 'match', 'matches')} confirmed`);
    }

    handleConfirm(event) {
        const matchId = event.currentTarget.dataset.id;
        this.run(() => confirmMatch({ matchId }), 'Match confirmed');
    }

    handleReverse(event) {
        const matchId = event.currentTarget.dataset.id;
        this.run(() => reverseMatch({ matchId }), 'Match reversed');
    }

    handleAdjustment() {
        toast(this, 'Post the bank fee or interest as a journal to the bank account, then match it here.');
        this.dispatchEvent(new CustomEvent('sabnavigate', { detail: { workspace: 'journal' }, bubbles: true, composed: true }));
    }

    handleFinalize() {
        if (this.finalizeDisabled) {
            return;
        }
        this.run(() => finalizeReconciliation({ reconciliationId: this.statement.reconciliationId }), 'Reconciliation finalised');
    }

    handleStatementAction() {
        const statementId = this.selectedStatementId;
        if (this.statementStatusBanner.kind === 'validate') {
            this.run(() => validateStatement({ bankStatementId: statementId }), 'Statement validated');
        } else {
            this.run(() => startReconciliation({ bankStatementId: statementId }), 'Reconciliation started');
        }
    }

    get matchRows() {
        return ((this.statement && this.statement.matches) || []).filter((m) => m.status !== 'Reversed').map((m) => {
            const line = ((this.statement && this.statement.lines) || []).find((l) => l.lineId === m.statementLineId) || {};
            return {
                ...m,
                lineText: line.reference || `Line ${line.lineNumber || ''}`,
                dateText: formatDate(m.accountingDate),
                amountText: formatNumber(m.matchedAmount),
                chip: chipClass(m.status, m.status === 'Proposed' ? 'info' : 'good'),
                canConfirm: m.status === 'Proposed' && !this.locked,
                canReverse: !this.busy && Boolean(this.dashboard && this.dashboard.canReconcile)
            };
        });
    }

    get hasMatches() {
        return this.matchRows.length > 0;
    }

    // ---------- import ----------

    handleOpenImport() {
        const bank = ((this.dashboard && this.dashboard.bankAccounts) || []).find((b) => b.bankAccountId === this.selectedBankId) || {};
        this.importForm = { currencyCode: bank.currencyCode || this.dashboard.functionalCurrency, openingAmount: '', closingAmount: '' };
        this.importError = undefined;
        this.importOpen = true;
    }

    handleCloseImport() {
        if (!this.busy) {
            this.importOpen = false;
        }
    }

    handleImportField(event) {
        this.importForm = { ...this.importForm, [event.target.dataset.field]: event.target.value };
    }

    async handleImportFile(event) {
        const file = event.target.files && event.target.files[0];
        if (!file) {
            return;
        }
        this.importError = undefined;
        try {
            const text = await readFile(file);
            const lines = parseStatementCsv(text);
            const dates = lines.map((l) => l.transactionDate).sort();
            this.importForm = { ...this.importForm, fileName: file.name, lines, text,
                statementStartDate: this.importForm.statementStartDate || dates[0], statementEndDate: this.importForm.statementEndDate || dates[dates.length - 1] };
        } catch (error) {
            this.importError = reduceError(error);
        }
    }

    get importLineText() {
        const f = this.importForm;
        if (!f.lines) {
            return '';
        }
        const net = f.lines.reduce((t, l) => t + l.amount, 0);
        return `${plural(f.lines.length, 'line')}, net ${formatNumber(net)}`;
    }

    get importSaveDisabled() {
        const f = this.importForm;
        return this.busy || !f.lines || f.openingAmount === '' || f.closingAmount === '' || !f.statementStartDate || !f.statementEndDate;
    }

    async handleImport() {
        if (this.importSaveDisabled) {
            return;
        }
        const f = this.importForm;
        this.busy = true;
        this.importError = undefined;
        try {
            const imported = await importStatement({ input: {
                bankAccountId: this.selectedBankId, statementStartDate: f.statementStartDate, statementEndDate: f.statementEndDate,
                openingAmount: Number(f.openingAmount), closingAmount: Number(f.closingAmount), currencyCode: f.currencyCode,
                importFingerprint: `${this.selectedBankId}|${f.statementStartDate}|${f.statementEndDate}|${f.lines.length}|${f.closingAmount}`,
                lines: f.lines.map(({ lineNumber, transactionDate, valueDate, amount, reference, providerLineId, sourceRawText, lineFingerprint }) =>
                    ({ lineNumber, transactionDate, valueDate, amount, reference, providerLineId, sourceRawText, lineFingerprint }))
            } });
            await validateStatement({ bankStatementId: imported.recordId });
            await startReconciliation({ bankStatementId: imported.recordId });
            this.importOpen = false;
            this.selectedStatementId = imported.recordId;
            toast(this, `Statement imported with ${plural(f.lines.length, 'line')}, reconciliation started`);
            this.busy = false;
            await this.load();
        } catch (error) {
            this.importError = reduceError(error);
            this.busy = false;
        }
    }

    handleRetry() {
        this.load();
    }
}