import { LightningElement, wire } from 'lwc';
import LightningConfirm from 'lightning/confirm';
import {
    APPLICATION_SCOPE,
    MessageContext,
    subscribe,
    unsubscribe
} from 'lightning/messageService';

import COMPANY_CONTEXT_CHANNEL
    from '@salesforce/messageChannel/SABCompanyContext__c';

import getWorkspace
    from '@salesforce/apex/SABJournalWorkspaceController.getWorkspace';
import getJournal
    from '@salesforce/apex/SABJournalWorkspaceController.getJournal';
import saveDraft
    from '@salesforce/apex/SABJournalWorkspaceController.saveDraft';
import validateJournal
    from '@salesforce/apex/SABJournalWorkspaceController.validateJournal';
import postJournal
    from '@salesforce/apex/SABJournalWorkspaceController.postJournal';
import reverseJournal
    from '@salesforce/apex/SABJournalWorkspaceController.reverseJournal';

const STORAGE_KEY = 'sabSelectedAccountingCompanyId';

export default class SabJournalWorkspace extends LightningElement {
    companyId;
    functionalCurrency;
    canPostJournal = false;
    canReverseJournal = false;

    periodOptions = [];
    glAccountOptions = [];
    departmentOptions = [];
    costCenterOptions = [];
    projectOptions = [];
    draftOptions = [];
    postedOptions = [];

    selectedDraftId;
    selectedPostedId;
    journalId;
    journalName;
    journalStatus = 'Draft';
    periodId;
    accountingDate;
    description = '';
    lines = [];

    isLoading = false;
    isDirty = false;
    errorMessage;
    successMessage;

    validationResult;
    postingResult;
    reversalResult;

    reversalPeriodId;
    reversalDate;
    reversalReason = '';

    subscription;

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        this.accountingDate =
            new Date().toISOString().slice(0, 10);
        this.reversalDate =
            this.accountingDate;

        this.ensureTwoLines();

        const storedCompanyId =
            window.sessionStorage.getItem(
                STORAGE_KEY
            );

        if (storedCompanyId) {
            this.companyId = storedCompanyId;
            this.loadWorkspace();
        }
    }

    renderedCallback() {
        if (!this.subscription && this.messageContext) {
            this.subscription = subscribe(
                this.messageContext,
                COMPANY_CONTEXT_CHANNEL,
                (message) => this.handleCompanyContext(message),
                { scope: APPLICATION_SCOPE }
            );
        }
    }

    disconnectedCallback() {
        unsubscribe(this.subscription);
        this.subscription = null;
    }

    async handleCompanyContext(message) {
        if (!message) {
            return;
        }

        if (message.companyCleared) {
            this.companyId = undefined;
            this.functionalCurrency = undefined;
            this.clearWorkspaceState();
            return;
        }

        if (!message.companyId) {
            return;
        }

        if (this.companyId === message.companyId) {
            return;
        }

        this.companyId = message.companyId;
        this.functionalCurrency =
            message.functionalCurrency;

        this.clearWorkspaceState();
        await this.loadWorkspace();
    }

    async loadWorkspace() {
        if (!this.companyId) {
            return;
        }

        const requestedCompanyId =
            this.companyId;

        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            const result =
                await getWorkspace({
                    companyId:
                        requestedCompanyId
                });

            if (
                this.companyId
                !== requestedCompanyId
            ) {
                return;
            }

            this.functionalCurrency =
                result.functionalCurrency;
            this.canPostJournal =
                Boolean(result.canPostJournal);
            this.canReverseJournal =
                Boolean(result.canReverseJournal);

            this.periodOptions =
                this.toOptions(result.periods);
            this.glAccountOptions =
                this.toOptions(result.glAccounts);
            this.departmentOptions =
                this.withBlankOption(
                    result.departments,
                    'No Department'
                );
            this.costCenterOptions =
                this.withBlankOption(
                    result.costCenters,
                    'No Cost Center'
                );
            this.projectOptions =
                this.withBlankOption(
                    result.projects,
                    'No Project'
                );

            this.draftOptions =
                (result.drafts || []).map(
                    (draft) => ({
                        label:
                            draft.journalName
                            + ' · '
                            + draft.accountingDate
                            + (
                                draft.description
                                    ? ' · ' + draft.description
                                    : ''
                            ),
                        value:
                            draft.journalId
                    })
                );

            this.postedOptions =
                (result.postedJournals || []).map(
                    (journal) => ({
                        label:
                            journal.journalName
                            + ' · '
                            + journal.accountingDate
                            + (
                                journal.postingKey
                                    ? ' · ' + journal.postingKey
                                    : ''
                            ),
                        value:
                            journal.journalId
                    })
                );

            if (
                !this.periodId
                && this.periodOptions.length > 0
            ) {
                this.periodId =
                    this.periodOptions[0].value;
            }
        } catch (error) {
            this.errorMessage =
                this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async handleDraftChange(event) {
        const journalId =
            event.detail.value;

        if (!journalId) {
            return;
        }

        const requestedCompanyId =
            this.companyId;

        this.isLoading = true;
        this.errorMessage = undefined;
        this.successMessage = undefined;

        try {
            const result =
                await getJournal({
                    journalId
                });

            if (
                this.companyId
                    !== requestedCompanyId
                || result.companyId
                    !== requestedCompanyId
            ) {
                return;
            }

            this.applyJournal(result);
            this.selectedDraftId =
                result.journalId;
            this.selectedPostedId =
                undefined;
        } catch (error) {
            this.errorMessage =
                this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async handlePostedChange(event) {
        const journalId =
            event.detail.value;

        if (!journalId) {
            return;
        }

        const requestedCompanyId =
            this.companyId;

        this.isLoading = true;
        this.errorMessage = undefined;
        this.successMessage = undefined;

        try {
            const result =
                await getJournal({
                    journalId
                });

            if (
                this.companyId
                    !== requestedCompanyId
                || result.companyId
                    !== requestedCompanyId
            ) {
                return;
            }

            this.applyJournal(result);
            this.selectedPostedId =
                result.journalId;
            this.selectedDraftId =
                undefined;

            this.prepareReversalDefaults();
        } catch (error) {
            this.errorMessage =
                this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleNewJournal() {
        this.resetJournal();

        if (this.periodOptions.length > 0) {
            this.periodId =
                this.periodOptions[0].value;
        }
    }

    handleHeaderChange(event) {
        this[event.target.name] =
            event.detail && event.detail.value !== undefined
                ? event.detail.value
                : event.target.value;

        this.markDirty();
    }

    handleLineChange(event) {
        const index =
            Number(event.target.dataset.index);

        const field =
            event.target.dataset.field;

        let value =
            event.detail && event.detail.value !== undefined
                ? event.detail.value
                : event.target.value;

        if (field === 'debit' || field === 'credit') {
            value =
                value === '' || value === null
                    ? 0
                    : Number(value);
        }

        const updated =
            this.lines.map(
                (line, currentIndex) => (
                    currentIndex === index
                        ? {
                            ...line,
                            [field]: value
                        }
                        : line
                )
            );

        this.lines = this.decorateLines(updated);
        this.markDirty();
    }

    handleAddLine() {
        this.lines = this.decorateLines([
            ...this.lines,
            this.newLine()
        ]);

        this.markDirty();
    }

    handleRemoveLine(event) {
        const index =
            Number(event.currentTarget.dataset.index);

        const remaining =
            this.lines.filter(
                (line, currentIndex) =>
                    currentIndex !== index
            );

        this.lines =
            this.decorateLines(remaining);

        this.ensureTwoLines();
        this.markDirty();
    }

    async handleSave() {
        this.errorMessage = undefined;
        this.successMessage = undefined;

        if (!this.validateClientInput()) {
            return;
        }

        this.isLoading = true;

        try {
            const result =
                await saveDraft({
                    request: {
                        journalId:
                            this.journalId || null,
                        companyId:
                            this.companyId,
                        periodId:
                            this.periodId,
                        accountingDate:
                            this.accountingDate,
                        description:
                            this.description,
                        lines:
                            this.lines.map(
                                (line) => ({
                                    glAccountId:
                                        line.glAccountId,
                                    debit:
                                        Number(line.debit || 0),
                                    credit:
                                        Number(line.credit || 0),
                                    explanation:
                                        line.explanation || null,
                                    departmentId:
                                        line.departmentId || null,
                                    costCenterId:
                                        line.costCenterId || null,
                                    projectId:
                                        line.projectId || null
                                })
                            )
                    }
                });

            this.applyJournal(result);
            this.selectedDraftId =
                result.journalId;
            this.selectedPostedId =
                undefined;

            this.successMessage =
                'Draft Journal saved successfully.';

            await this.loadWorkspace();
        } catch (error) {
            this.errorMessage =
                this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async handleValidate() {
        this.errorMessage = undefined;
        this.successMessage = undefined;
        this.validationResult = undefined;
        this.postingResult = undefined;

        if (!this.journalId) {
            this.errorMessage =
                'Save the Draft before validating it.';
            return;
        }

        if (this.isDirty) {
            this.errorMessage =
                'Save your latest Draft changes before validating.';
            return;
        }

        this.isLoading = true;

        try {
            const result =
                await validateJournal({
                    journalId:
                        this.journalId
                });

            this.validationResult =
                result;

            if (result.isValid) {
                this.successMessage =
                    'Journal passed posting validation.';
            }
        } catch (error) {
            this.errorMessage =
                this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async handlePost() {
        this.errorMessage = undefined;
        this.successMessage = undefined;

        if (!this.validationResult || !this.validationResult.isValid) {
            this.errorMessage =
                'Run Validate and resolve all errors before posting.';
            return;
        }

        const confirmed =
            await LightningConfirm.open({
                label: 'Post Journal',
                message:
                    'Posting makes this Journal part of the financial ledger and read-only. Corrections require a reversal. Continue?',
                variant: 'header'
            });

        if (!confirmed) {
            return;
        }

        this.isLoading = true;

        try {
            const result =
                await postJournal({
                    journalId:
                        this.journalId
                });

            this.postingResult =
                result;
            this.journalStatus =
                result.status;
            this.isDirty = false;

            this.successMessage =
                result.replay
                    ? 'The original posting result was returned.'
                    : 'Journal posted successfully.';

            await this.loadWorkspace();
        } catch (error) {
            this.errorMessage =
                this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleReversalInput(event) {
        this[event.target.name] =
            event.detail && event.detail.value !== undefined
                ? event.detail.value
                : event.target.value;

        this.errorMessage = undefined;
        this.successMessage = undefined;
    }

    prepareReversalDefaults() {
        if (
            !this.reversalPeriodId
            && this.periodOptions.length > 0
        ) {
            this.reversalPeriodId =
                this.periodOptions[0].value;
        }

        if (!this.reversalDate) {
            this.reversalDate =
                new Date().toISOString().slice(0, 10);
        }

        this.reversalReason = '';
        this.reversalResult = undefined;
    }

    async handleReverse() {
        this.errorMessage = undefined;
        this.successMessage = undefined;

        if (!this.journalId || this.journalStatus !== 'Posted') {
            this.errorMessage =
                'Select a Posted Journal Entry to reverse.';
            return;
        }

        if (!this.reversalPeriodId) {
            this.errorMessage =
                'Select a Reversal Accounting Period.';
            return;
        }

        if (!this.reversalDate) {
            this.errorMessage =
                'Enter a Reversal Accounting Date.';
            return;
        }

        if (!this.reversalReason || !this.reversalReason.trim()) {
            this.errorMessage =
                'Enter a Reversal Reason.';
            return;
        }

        const confirmed =
            await LightningConfirm.open({
                label: 'Reverse Journal',
                message:
                    'This creates and posts an opposite Journal Entry. The original Posted Journal remains immutable. Continue?',
                variant: 'header'
            });

        if (!confirmed) {
            return;
        }

        this.isLoading = true;

        try {
            const result =
                await reverseJournal({
                    originalJournalId:
                        this.journalId,
                    reversalPeriodId:
                        this.reversalPeriodId,
                    reversalDate:
                        this.reversalDate,
                    reason:
                        this.reversalReason
                });

            this.reversalResult =
                result;
            this.journalStatus =
                result.originalStatus;

            this.successMessage =
                result.replay
                    ? 'The original reversal result was returned.'
                    : 'Journal reversed successfully.';

            await this.loadWorkspace();
        } catch (error) {
            this.errorMessage =
                this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    validateClientInput() {
        if (!this.periodId) {
            this.errorMessage =
                'Select an Accounting Period.';
            return false;
        }

        if (!this.accountingDate) {
            this.errorMessage =
                'Enter an Accounting Date.';
            return false;
        }

        if (this.lines.length === 0) {
            this.errorMessage =
                'Add at least one Journal line.';
            return false;
        }

        for (const line of this.lines) {
            if (!line.glAccountId) {
                this.errorMessage =
                    'Every Journal line requires a GL Account.';
                return false;
            }

            const debit =
                Number(line.debit || 0);
            const credit =
                Number(line.credit || 0);

            if (
                debit < 0
                || credit < 0
                || (debit === 0 && credit === 0)
                || (debit > 0 && credit > 0)
            ) {
                this.errorMessage =
                    'Each line must contain either a positive Debit or a positive Credit amount.';
                return false;
            }
        }

        return true;
    }

    applyJournal(result) {
        this.journalId =
            result.journalId;
        this.journalName =
            result.journalName;
        this.journalStatus =
            result.status;
        this.periodId =
            result.periodId;
        this.accountingDate =
            result.accountingDate;
        this.description =
            result.description || '';

        this.lines =
            this.decorateLines(
                (result.lines || []).map(
                    (line) => ({
                        key:
                            line.lineId
                            || this.createKey(),
                        glAccountId:
                            line.glAccountId,
                        debit:
                            Number(line.debit || 0),
                        credit:
                            Number(line.credit || 0),
                        explanation:
                            line.explanation || '',
                        departmentId:
                            line.departmentId || '',
                        costCenterId:
                            line.costCenterId || '',
                        projectId:
                            line.projectId || ''
                    })
                )
            );

        this.ensureTwoLines();
        this.isDirty = false;
        this.validationResult = undefined;
        this.reversalResult = undefined;
        this.postingResult =
            result.status === 'Posted'
                ? {
                    postingKey:
                        result.postingKey,
                    accountingEventId:
                        result.accountingEventId,
                    postedAt:
                        result.postedAt,
                    replay:
                        false
                }
                : undefined;
    }

    clearWorkspaceState() {
        this.periodOptions = [];
        this.glAccountOptions = [];
        this.departmentOptions = [];
        this.costCenterOptions = [];
        this.projectOptions = [];
        this.draftOptions = [];
        this.postedOptions = [];
        this.canPostJournal = false;
        this.canReverseJournal = false;
        this.resetJournal();
    }

    resetJournal() {
        this.selectedDraftId = undefined;
        this.selectedPostedId = undefined;
        this.journalId = undefined;
        this.journalName = undefined;
        this.journalStatus = 'Draft';
        this.description = '';
        this.accountingDate =
            new Date().toISOString().slice(0, 10);
        this.lines = [];
        this.ensureTwoLines();
        this.isDirty = false;
        this.validationResult = undefined;
        this.postingResult = undefined;
        this.reversalResult = undefined;
        this.reversalPeriodId = undefined;
        this.reversalDate =
            new Date().toISOString().slice(0, 10);
        this.reversalReason = '';
        this.errorMessage = undefined;
        this.successMessage = undefined;
    }

    markDirty() {
        this.isDirty = true;
        this.validationResult = undefined;
        this.postingResult = undefined;
        this.successMessage = undefined;
    }

    ensureTwoLines() {
        const updated = [...this.lines];

        while (updated.length < 2) {
            updated.push(this.newLine());
        }

        this.lines =
            this.decorateLines(updated);
    }

    newLine() {
        return {
            key: this.createKey(),
            displayNumber: 0,
            glAccountId: '',
            debit: 0,
            credit: 0,
            explanation: '',
            departmentId: '',
            costCenterId: '',
            projectId: ''
        };
    }

    decorateLines(lines) {
        return lines.map(
            (line, index) => ({
                ...line,
                displayNumber:
                    index + 1
            })
        );
    }

    createKey() {
        return (
            'line-'
            + Date.now()
            + '-'
            + Math.random().toString(36).slice(2)
        );
    }

    toOptions(values) {
        return (values || []).map(
            (item) => ({
                label: item.label,
                value: item.value
            })
        );
    }

    withBlankOption(values, blankLabel) {
        return [
            {
                label: blankLabel,
                value: ''
            },
            ...this.toOptions(values)
        ];
    }

    reduceError(error) {
        if (
            error
            && error.body
            && error.body.message
        ) {
            return error.body.message;
        }

        if (error && error.message) {
            return error.message;
        }

        return 'Unexpected Journal Workspace error.';
    }

    get hasCompany() {
        return Boolean(this.companyId);
    }

    get isReadOnly() {
        return this.journalStatus !== 'Draft';
    }

    get saveDisabled() {
        return (
            !this.companyId
            || this.isLoading
            || this.isReadOnly
            || this.periodOptions.length === 0
            || this.glAccountOptions.length === 0
        );
    }

    get validateDisabled() {
        return (
            !this.journalId
            || this.isLoading
            || this.isDirty
            || this.isReadOnly
        );
    }

    get postDisabled() {
        return (
            !this.journalId
            || !this.canPostJournal
            || this.isLoading
            || this.isDirty
            || this.isReadOnly
            || !this.validationResult
            || !this.validationResult.isValid
        );
    }

    get isPosted() {
        return this.journalStatus === 'Posted';
    }

    get isReversed() {
        return this.journalStatus === 'Reversed';
    }

    get showReversalPanel() {
        return (
            this.isPosted
            || this.isReversed
            || Boolean(this.reversalResult)
        );
    }

    get reverseDisabled() {
        return (
            !this.canReverseJournal
            || this.isLoading
            || !this.isPosted
            || !this.reversalPeriodId
            || !this.reversalDate
            || !this.reversalReason
            || !this.reversalReason.trim()
        );
    }

    get totalDebit() {
        return this.lines.reduce(
            (total, line) =>
                total + Number(line.debit || 0),
            0
        );
    }

    get totalCredit() {
        return this.lines.reduce(
            (total, line) =>
                total + Number(line.credit || 0),
            0
        );
    }

    get totalDebitDisplay() {
        return this.totalDebit.toFixed(4);
    }

    get totalCreditDisplay() {
        return this.totalCredit.toFixed(4);
    }

    get balanceMessage() {
        const difference =
            this.totalDebit - this.totalCredit;

        if (
            this.totalDebit === 0
            && this.totalCredit === 0
        ) {
            return 'Enter journal amounts';
        }

        if (Math.abs(difference) < 0.00005) {
            return 'Balanced';
        }

        return (
            'Difference: '
            + Math.abs(difference).toFixed(4)
        );
    }

    get balanceClass() {
        return Math.abs(
            this.totalDebit - this.totalCredit
        ) < 0.00005
            && (
                this.totalDebit !== 0
                || this.totalCredit !== 0
            )
            ? 'balance-good'
            : 'balance-warning';
    }

    get showValidationPanel() {
        return Boolean(this.validationResult);
    }

    get hasValidationErrors() {
        return (
            this.validationResult
            && this.validationResult.errors
            && this.validationResult.errors.length > 0
        );
    }

    get validationErrors() {
        return this.validationResult
            ? this.validationResult.errors || []
            : [];
    }

    get validationStatusText() {
        return this.validationResult
            && this.validationResult.isValid
            ? 'Ready to Post'
            : 'Validation Failed';
    }

    get validationBadgeClass() {
        return this.validationResult
            && this.validationResult.isValid
            ? 'validation-good'
            : 'validation-bad';
    }

    get validationLineCount() {
        return this.validationResult
            ? this.validationResult.lineCount
            : 0;
    }

    get validationDebitDisplay() {
        return this.validationResult
            ? Number(
                this.validationResult.totalDebit || 0
            ).toFixed(4)
            : '0.0000';
    }

    get validationCreditDisplay() {
        return this.validationResult
            ? Number(
                this.validationResult.totalCredit || 0
            ).toFixed(4)
            : '0.0000';
    }
}
