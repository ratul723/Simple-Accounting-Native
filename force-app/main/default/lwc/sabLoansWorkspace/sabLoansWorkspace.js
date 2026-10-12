import { LightningElement, api } from 'lwc';
import getWorkspace from '@salesforce/apex/SABLoansInvestmentsWorkspaceController.getWorkspace';
import getFormOptions from '@salesforce/apex/SABLoansInvestmentsWorkspaceController.getFormOptions';
import saveDraft from '@salesforce/apex/SABLoanService.saveDraft';
import approveLoan from '@salesforce/apex/SABLoanService.approve';
import accrueInterest from '@salesforce/apex/SABLoanService.accrueInterest';
import recordRepayment from '@salesforce/apex/SABLoanService.recordRepayment';
import saveInvestment from '@salesforce/apex/SABInvestmentService.saveInvestment';
import recordTransaction from '@salesforce/apex/SABInvestmentService.recordTransaction';
import { formatNumber, formatDate, formatDateShort, chipClass, plural } from 'c/sabFormat';

const LOAN_TYPES = ['Borrowing', 'Lending', 'Shareholder Loan'];
const FREQUENCIES = ['Monthly', 'Quarterly'];
const METHODS = ['Annuity', 'Equal Principal'];
const POLICIES = [
    { value: 'COST', label: 'Cost' },
    { value: 'FVTPL', label: 'Fair value through profit or loss' }
];
const CLASSIFICATIONS = ['Term deposit', 'Managed fund', 'Listed shares', 'Bond', 'Other'];
const TX_TYPES = ['Acquisition', 'Disposal', 'Income', 'Fee', 'Valuation'];

const POSTING_TEXT = {
    Borrowing: 'Accrual posts Dr interest expense / Cr accrued interest. Repayment posts Dr loan principal and Dr accrued interest / Cr bank.',
    'Shareholder Loan': 'Accrual posts Dr interest expense / Cr accrued interest. Repayment posts Dr loan principal and Dr accrued interest / Cr bank.',
    Lending: 'Accrual posts Dr accrued interest / Cr interest income. Repayment posts Dr bank / Cr loan principal and Cr accrued interest.'
};

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

function toOptions(values, selected) {
    return values.map((v) => {
        const value = typeof v === 'string' ? v : v.value;
        const label = typeof v === 'string' ? v : v.label;
        return { value, label, selected: value === selected };
    });
}

function todayIso() {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/**
 * Investments & loans workspace (G22B): loans with schedules and lifecycle actions, investment holdings
 * and transactions, on SABLoanService and SABInvestmentService.
 */
export default class SabLoansWorkspace extends LightningElement {
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
    activeTab = 'loans';
    selectedLoanId;
    busyKey;
    options;
    modal;
    form = {};
    formError;
    saving = false;
    loadSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.options = undefined;
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
            if (sequence === this.loadSequence) {
                this.data = result;
                this.ensureSelection();
            }
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

    ensureSelection() {
        const loans = this.data.loans || [];
        if (loans.some((l) => l.loanId === this.selectedLoanId)) {
            return;
        }
        const active = loans.find((l) => l.status === 'Active');
        this.selectedLoanId = (active || loans[0] || {}).loanId;
    }

    // ---------- header ----------

    get cur() {
        return (this.data && this.data.currencyCode) || this.currencyCode || '';
    }

    get canManageLoans() {
        return Boolean(this.data && this.data.canManageLoans);
    }

    get canManageInvestments() {
        return Boolean(this.data && this.data.canManageInvestments);
    }

    get newLoanDisabled() {
        return !this.canManageLoans;
    }

    get newInvestmentDisabled() {
        return !this.canManageInvestments;
    }

    get newLoanTitle() {
        return this.canManageLoans ? undefined : 'Your role cannot manage loans';
    }

    get newInvestmentTitle() {
        return this.canManageInvestments ? undefined : 'Your role cannot manage investments';
    }

    get showLoading() {
        return this.isLoading && !this.data && !this.errorMessage;
    }

    get figures() {
        const d = this.data;
        return [
            { key: 'b', label: 'Borrowings', value: formatNumber(d.borrowings, 0), sub: plural(d.borrowingCount, 'active borrowing') },
            { key: 'i', label: 'Interest this quarter', value: formatNumber(d.interestThisQuarter, 0),
                sub: d.interestLoanCount ? `${plural(d.interestLoanCount, 'loan')} with instalments due` : 'No instalments due this quarter' },
            { key: 'v', label: 'Investments', value: formatNumber(d.investmentsTotal, 0), sub: `${plural((d.investments || []).length, 'investment')}, carrying amount` },
            { key: 'n', label: 'Income received', value: formatNumber(d.incomeYearToDate, 0), sub: `Since ${formatDate(d.fiscalYearStart)}` }
        ];
    }

    // ---------- tabs ----------

    get isLoansTab() {
        return this.activeTab === 'loans';
    }

    get tabs() {
        const d = this.data || {};
        return [
            { id: 'loans', label: 'Loans', count: (d.loans || []).length },
            { id: 'inv', label: 'Investments', count: (d.investments || []).length }
        ].map((t) => ({ ...t, className: t.id === this.activeTab ? 'tab active' : 'tab', selected: t.id === this.activeTab ? 'true' : 'false' }));
    }

    handleTab(event) {
        this.activeTab = event.currentTarget.dataset.tab;
    }

    // ---------- loans ----------

    get loanCards() {
        const d = this.data;
        return (d.loans || []).map((l) => {
            const repaidPct = l.principal ? Math.max(0, Math.min(100, (l.repaid / l.principal) * 100)) : 0;
            const approveReason = this.approveReason(l);
            return {
                ...l,
                className: l.loanId === this.selectedLoanId ? 'cardlet click sel' : 'cardlet click',
                pressed: l.loanId === this.selectedLoanId ? 'true' : 'false',
                meta: [l.counterparty, l.principalAccountCode ? `GL ${l.principalAccountCode}` : null].filter(Boolean).join(', '),
                balanceText: formatNumber(l.balance, 0),
                rateText: l.rate ? `${formatNumber(l.rate, 2)}%` : 'Interest free',
                hasNext: Boolean(l.nextDueDate),
                nextText: `${formatNumber(l.nextPayment)} on ${formatDateShort(l.nextDueDate)}`,
                meterStyle: `width:${repaidPct.toFixed(1)}%`,
                repaidText: `${formatNumber(l.repaid, 0)} of ${formatNumber(l.principal, 0)} repaid`,
                chip: chipClass(l.status),
                isDraft: l.status === 'Draft',
                approveDisabled: Boolean(approveReason) || this.busyKey === `approve-${l.loanId}`,
                approveTitle: approveReason,
                editDisabled: !this.canManageLoans,
                editTitle: this.canManageLoans ? undefined : 'Your role cannot manage loans'
            };
        });
    }

    approveReason(loan) {
        if (!this.data.canApproveLoans) {
            return 'Your role cannot approve loans';
        }
        if (!this.data.canPostJournal) {
            return 'Approving posts the drawdown and needs journal posting permission';
        }
        if (loan.createdByMe) {
            return 'The creator of a loan cannot approve it';
        }
        return undefined;
    }

    get hasLoans() {
        return this.loanCards.length > 0;
    }

    get selectedLoan() {
        return ((this.data && this.data.loans) || []).find((l) => l.loanId === this.selectedLoanId);
    }

    get hasSchedule() {
        return Boolean(this.selectedLoan && (this.selectedLoan.lines || []).length);
    }

    get scheduleTitle() {
        return this.selectedLoan ? `${this.selectedLoan.name} repayment schedule` : '';
    }

    get scheduleSub() {
        return this.selectedLoan ? POSTING_TEXT[this.selectedLoan.loanType] : '';
    }

    get scheduleEmptyText() {
        return this.selectedLoan && this.selectedLoan.status === 'Draft'
            ? 'The schedule is generated when the loan is approved.'
            : 'No schedule lines.';
    }

    get scheduleRows() {
        const loan = this.selectedLoan;
        if (!loan) {
            return [];
        }
        const actionReason = !this.canManageLoans
            ? 'Your role cannot manage loans'
            : !this.data.canPostJournal
              ? 'This action posts a journal and needs journal posting permission'
              : undefined;
        return (loan.lines || []).map((line) => {
            const isNext = line.lineId === loan.nextLineId && Boolean(loan.nextAction);
            return {
                ...line,
                dueText: formatDate(line.dueDate),
                paymentText: formatNumber(line.payment),
                interestText: formatNumber(line.interest),
                principalText: formatNumber(line.principalDue),
                balanceText: formatNumber(line.balance),
                chip: chipClass(line.status),
                hasAction: isNext,
                actionLabel: loan.nextAction === 'accrue' ? 'Accrue interest' : 'Record repayment',
                action: loan.nextAction,
                actionDisabled: Boolean(actionReason) || this.busyKey === `line-${line.lineId}`,
                actionTitle: actionReason
            };
        });
    }

    handleSelectLoan(event) {
        this.selectLoan(event.currentTarget.dataset.id);
    }

    handleLoanKeydown(event) {
        if (event.target !== event.currentTarget) {
            return;
        }
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.selectLoan(event.currentTarget.dataset.id);
        }
    }

    selectLoan(id) {
        this.selectedLoanId = id;
    }

    async handleApprove(event) {
        event.stopPropagation();
        const loanId = event.currentTarget.dataset.id;
        await this.runAction(`approve-${loanId}`, () => approveLoan({ loanId, requestKey: newKey('LOAN-APPROVE', loanId) }),
            'Loan approved, schedule generated and drawdown posted');
    }

    async handleLineAction(event) {
        const lineId = event.currentTarget.dataset.id;
        const action = event.currentTarget.dataset.action;
        if (action === 'accrue') {
            await this.runAction(`line-${lineId}`, () => accrueInterest({ scheduleLineId: lineId, requestKey: newKey('LOAN-ACCRUE', lineId) }),
                'Interest accrued and posted');
        } else {
            await this.runAction(`line-${lineId}`, () => recordRepayment({ scheduleLineId: lineId, requestKey: newKey('LOAN-REPAY', lineId) }),
                'Repayment recorded and posted');
        }
    }

    async runAction(busyKey, call, message) {
        if (this.busyKey) {
            return;
        }
        this.busyKey = busyKey;
        try {
            await call();
            this.toast(message);
            await this.load();
        } catch (error) {
            this.toast(reduceError(error), 'bad');
        } finally {
            this.busyKey = undefined;
        }
    }

    // ---------- investments ----------

    get investmentCards() {
        const reason = !this.canManageInvestments
            ? 'Your role cannot manage investments'
            : !(this.data && this.data.canPostJournal)
              ? 'Recording a transaction posts a journal and needs journal posting permission'
              : undefined;
        return ((this.data && this.data.investments) || []).map((v) => ({
            ...v,
            meta: [v.instrumentKey, v.accountCode ? `GL ${v.accountCode}` : null, v.valuationPolicy].filter(Boolean).join(', '),
            carryingText: formatNumber(v.carryingAmount, 0),
            costText: formatNumber(v.cost, 0),
            quantityText: formatNumber(v.quantity, 4).replace(/\.?0+$/, '') || '0',
            incomeText: formatNumber(v.incomeYearToDate, 0),
            chip: chipClass(v.status),
            canRecord: v.status === 'Active',
            recordDisabled: Boolean(reason),
            recordTitle: reason
        }));
    }

    get hasInvestments() {
        return this.investmentCards.length > 0;
    }

    get transactionRows() {
        return ((this.data && this.data.transactions) || []).map((t) => ({
            ...t,
            dateText: formatDate(t.transactionDate),
            quantityText: t.quantity === null || t.quantity === undefined ? '' : formatNumber(t.quantity, 4).replace(/\.?0+$/, ''),
            amountText: formatNumber(t.amount),
            gainText: formatNumber(t.gainLoss),
            statusText: t.posted ? 'Posted' : 'Draft',
            chip: chipClass(t.posted ? 'Posted' : 'Draft')
        }));
    }

    get hasTransactions() {
        return this.transactionRows.length > 0;
    }

    // ---------- forms ----------

    get isLoanModal() {
        return this.modal === 'loan';
    }

    get isInvestmentModal() {
        return this.modal === 'investment';
    }

    get isTransactionModal() {
        return this.modal === 'transaction';
    }

    get modalOpen() {
        return Boolean(this.modal);
    }

    get modalHeading() {
        if (this.modal === 'loan') {
            return this.form.loanId ? 'Edit draft loan' : 'New loan';
        }
        if (this.modal === 'investment') {
            return 'New investment';
        }
        return 'Record investment transaction';
    }

    get modalSub() {
        if (this.modal === 'loan') {
            return 'Saved as a draft. Another user with approval rights approves it, which generates the schedule and posts the drawdown.';
        }
        if (this.modal === 'investment') {
            return 'Account mapping can change until the first transaction is recorded.';
        }
        return this.form.investmentName;
    }

    get saveLabel() {
        if (this.modal === 'transaction') {
            return 'Record and post';
        }
        return this.modal === 'loan' ? 'Save draft' : 'Save investment';
    }

    get loanTypeOptions() {
        return toOptions(LOAN_TYPES, this.form.loanType);
    }

    get frequencyOptions() {
        return toOptions(FREQUENCIES, this.form.repaymentFrequency);
    }

    get methodOptions() {
        return toOptions(METHODS, this.form.scheduleMethod);
    }

    get policyOptions() {
        return toOptions(POLICIES, this.form.valuationPolicy);
    }

    get classificationOptions() {
        return toOptions(CLASSIFICATIONS, this.form.classification);
    }

    get txTypeOptions() {
        const types = this.form.valuationPolicy === 'FVTPL' ? TX_TYPES : TX_TYPES.filter((t) => t !== 'Valuation');
        return toOptions(types, this.form.transactionType);
    }

    get counterpartyOptions() {
        return toOptions((this.options && this.options.counterparties) || [], this.form.counterpartyAccountId);
    }

    get bankOptions() {
        return toOptions((this.options && this.options.bankAccounts) || [], this.form.bankAccountId);
    }

    glOptions(kinds, selected) {
        const list = ((this.options && this.options.glAccounts) || []).filter((a) => !kinds || kinds.includes(a.kind));
        return toOptions(list, selected);
    }

    get isLending() {
        return this.form.loanType === 'Lending';
    }

    get principalGlOptions() {
        return this.glOptions(this.isLending ? ['Asset'] : ['Liability'], this.form.principalAccountId);
    }

    get interestGlOptions() {
        return this.glOptions(this.isLending ? ['Revenue'] : ['Expense'], this.form.interestAccountId);
    }

    get accruedGlOptions() {
        return this.glOptions(this.isLending ? ['Asset'] : ['Liability'], this.form.accruedInterestAccountId);
    }

    get investmentGlOptions() {
        return this.glOptions(['Asset'], this.form.investmentAccountId);
    }

    get incomeGlOptions() {
        return this.glOptions(['Revenue'], this.form.incomeAccountId);
    }

    get gainLossGlOptions() {
        return this.glOptions(['Revenue', 'Expense'], this.form.gainLossAccountId);
    }

    get feeGlOptions() {
        return this.glOptions(['Expense'], this.form.feeAccountId);
    }

    get needsQuantity() {
        return this.form.transactionType === 'Acquisition' || this.form.transactionType === 'Disposal';
    }

    get amountLabel() {
        if (this.form.transactionType === 'Disposal') {
            return 'Proceeds';
        }
        return this.form.transactionType === 'Valuation' ? 'Fair value change (negative for a loss)' : 'Amount';
    }

    async ensureOptions() {
        if (!this.options) {
            this.options = await getFormOptions({ companyId: this.currentCompanyId });
        }
    }

    async openForm(kind, form) {
        this.formError = undefined;
        try {
            await this.ensureOptions();
            this.form = form;
            this.modal = kind;
        } catch (error) {
            this.toast(reduceError(error), 'bad');
        }
    }

    handleNewLoan() {
        this.openForm('loan', {
            loanType: 'Borrowing', repaymentFrequency: 'Monthly', scheduleMethod: 'Annuity', startDate: todayIso()
        });
    }

    handleEditLoan(event) {
        event.stopPropagation();
        const loan = this.data.loans.find((l) => l.loanId === event.currentTarget.dataset.id);
        this.openForm('loan', {
            loanId: loan.loanId, name: loan.name, loanType: loan.loanType, principal: loan.principal, annualRatePercent: loan.rate,
            startDate: loan.startDate, maturityDate: loan.maturityDate, repaymentFrequency: loan.frequency, scheduleMethod: loan.method
        });
    }

    handleNewInvestment() {
        this.openForm('investment', { valuationPolicy: 'COST', classification: CLASSIFICATIONS[0] });
    }

    handleRecordTransaction(event) {
        const investment = this.data.investments.find((v) => v.investmentId === event.currentTarget.dataset.id);
        this.openForm('transaction', {
            investmentId: investment.investmentId, investmentName: investment.name, valuationPolicy: investment.valuationPolicy,
            transactionType: 'Acquisition', transactionDate: todayIso(), requestKey: newKey('INV-TX', investment.investmentId)
        });
    }

    handleField(event) {
        const field = event.target.dataset.field;
        this.form = { ...this.form, [field]: event.target.value };
    }

    handleCloseModal() {
        if (!this.saving) {
            this.modal = undefined;
            this.formError = undefined;
        }
    }

    numberOrNull(value) {
        return value === '' || value === null || value === undefined ? null : Number(value);
    }

    loanRequest() {
        const f = this.form;
        return {
            loanId: f.loanId || null, companyId: this.currentCompanyId, name: f.name, loanType: f.loanType,
            counterpartyAccountId: f.counterpartyAccountId || null, principal: this.numberOrNull(f.principal),
            annualRatePercent: this.numberOrNull(f.annualRatePercent), startDate: f.startDate || null, maturityDate: f.maturityDate || null,
            repaymentFrequency: f.repaymentFrequency, scheduleMethod: f.scheduleMethod, principalAccountId: f.principalAccountId || null,
            interestAccountId: f.interestAccountId || null, accruedInterestAccountId: f.accruedInterestAccountId || null,
            bankAccountId: f.bankAccountId || null
        };
    }

    investmentRequest() {
        const f = this.form;
        return {
            companyId: this.currentCompanyId, name: f.name, instrumentKey: f.instrumentKey, classification: f.classification,
            valuationPolicy: f.valuationPolicy, counterpartyAccountId: f.counterpartyAccountId || null,
            investmentAccountId: f.investmentAccountId || null, incomeAccountId: f.incomeAccountId || null,
            gainLossAccountId: f.gainLossAccountId || null, feeAccountId: f.feeAccountId || null, bankAccountId: f.bankAccountId || null
        };
    }

    async handleSave() {
        if (this.saving) {
            return;
        }
        this.saving = true;
        this.formError = undefined;
        try {
            let message;
            if (this.modal === 'loan') {
                const loanId = await saveDraft({ request: this.loanRequest() });
                this.selectedLoanId = loanId;
                this.activeTab = 'loans';
                message = this.form.loanId ? 'Draft loan updated' : 'Loan drafted';
            } else if (this.modal === 'investment') {
                await saveInvestment({ request: this.investmentRequest() });
                this.activeTab = 'inv';
                message = 'Investment saved';
            } else {
                const f = this.form;
                await recordTransaction({
                    request: {
                        investmentId: f.investmentId, transactionType: f.transactionType, transactionDate: f.transactionDate || null,
                        amount: this.numberOrNull(f.amount), quantity: this.needsQuantity ? this.numberOrNull(f.quantity) : null
                    },
                    requestKey: f.requestKey
                });
                message = `${f.transactionType} recorded and posted`;
            }
            this.modal = undefined;
            this.toast(message);
            await this.load();
        } catch (error) {
            this.formError = reduceError(error);
        } finally {
            this.saving = false;
        }
    }

    // ---------- shared ----------

    toast(message, tone) {
        this.dispatchEvent(new CustomEvent('sabtoast', { detail: { message, tone }, bubbles: true, composed: true }));
    }

    handleRetry() {
        this.load();
    }
}
