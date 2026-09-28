import { LightningElement, wire } from 'lwc';
import LightningConfirm from 'lightning/confirm';
import { NavigationMixin } from 'lightning/navigation';
import {
    APPLICATION_SCOPE,
    MessageContext,
    subscribe,
    unsubscribe
} from 'lightning/messageService';

import COMPANY_CONTEXT_CHANNEL
    from '@salesforce/messageChannel/SABCompanyContext__c';

import getDashboard
    from '@salesforce/apex/SABBankReconciliationWorkspaceController.getDashboard';
import getStatementWorkspace
    from '@salesforce/apex/SABBankReconciliationWorkspaceController.getStatementWorkspace';
import importStatement
    from '@salesforce/apex/SABBankReconciliationWorkspaceController.importStatement';
import validateStatement
    from '@salesforce/apex/SABBankReconciliationWorkspaceController.validateStatement';
import startReconciliation
    from '@salesforce/apex/SABBankReconciliationWorkspaceController.startReconciliation';
import getMatchCandidates
    from '@salesforce/apex/SABBankReconciliationWorkspaceController.getMatchCandidates';
import createManualMatch
    from '@salesforce/apex/SABBankReconciliationWorkspaceController.createManualMatch';
import createSuggestedMatch
    from '@salesforce/apex/SABBankReconciliationWorkspaceController.createSuggestedMatch';
import confirmMatch
    from '@salesforce/apex/SABBankReconciliationWorkspaceController.confirmMatch';
import reverseMatch
    from '@salesforce/apex/SABBankReconciliationWorkspaceController.reverseMatch';
import finalizeReconciliation
    from '@salesforce/apex/SABBankReconciliationWorkspaceController.finalizeReconciliation';

const STORAGE_KEY = 'sabSelectedAccountingCompanyId';

export default class SabBankReconciliationWorkspace
    extends NavigationMixin(LightningElement) {

    companyId;
    dashboard;
    statementWorkspace;
    selectedBankAccountId;
    selectedStatementId;
    selectedLineId;
    candidates = [];
    candidateDayWindow = 7;

    isLoading = false;
    errorMessage;
    successMessage;
    subscription;

    importStartDate;
    importEndDate;
    importOpeningAmount;
    importClosingAmount;
    importCurrencyCode;
    importFingerprint = '';
    importLines = [];
    lineKeySequence = 0;

    @wire(MessageContext)
    messageContext;

    connectedCallback() {
        const today = new Date().toISOString().slice(0, 10);
        this.importStartDate = today;
        this.importEndDate = today;
        this.addImportLine();

        const storedCompanyId =
            window.sessionStorage.getItem(STORAGE_KEY);

        if (storedCompanyId) {
            this.companyId = storedCompanyId;
            this.loadDashboard();
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
        if (this.subscription) {
            unsubscribe(this.subscription);
        }
        this.subscription = null;
    }

    async handleCompanyContext(message) {
        if (!message) {
            return;
        }

        if (message.companyCleared) {
            this.companyId = undefined;
            this.dashboard = undefined;
            this.statementWorkspace = undefined;
            this.selectedBankAccountId = undefined;
            this.selectedStatementId = undefined;
            this.selectedLineId = undefined;
            this.candidates = [];
            return;
        }

        if (!message.companyId || message.companyId === this.companyId) {
            return;
        }

        this.companyId = message.companyId;
        this.dashboard = undefined;
        this.statementWorkspace = undefined;
        this.selectedBankAccountId = undefined;
        this.selectedStatementId = undefined;
        this.selectedLineId = undefined;
        this.candidates = [];

        await this.loadDashboard();
    }

    async loadDashboard() {
        if (!this.companyId) {
            return;
        }

        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            this.dashboard = await getDashboard({
                companyId: this.companyId
            });

            const banks = this.dashboard.bankAccounts || [];

            if (
                !this.selectedBankAccountId
                || !banks.some(
                    (row) =>
                        row.bankAccountId === this.selectedBankAccountId
                )
            ) {
                this.selectedBankAccountId =
                    banks.length ? banks[0].bankAccountId : undefined;
            }

            this.syncImportCurrency();

            const statements = this.filteredStatements;

            if (
                !this.selectedStatementId
                || !statements.some(
                    (row) =>
                        row.statementId === this.selectedStatementId
                )
            ) {
                this.selectedStatementId =
                    statements.length
                        ? statements[0].statementId
                        : undefined;
            }

            if (this.selectedStatementId) {
                await this.loadStatementWorkspace();
            } else {
                this.statementWorkspace = undefined;
            }
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async loadStatementWorkspace() {
        if (!this.selectedStatementId) {
            this.statementWorkspace = undefined;
            return;
        }

        try {
            this.statementWorkspace =
                await getStatementWorkspace({
                    bankStatementId: this.selectedStatementId
                });
            this.selectedLineId = undefined;
            this.candidates = [];
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        }
    }

    handleBankAccountChange(event) {
        this.selectedBankAccountId = event.detail.value;
        this.syncImportCurrency();

        const statements = this.filteredStatements;
        this.selectedStatementId =
            statements.length ? statements[0].statementId : undefined;

        if (this.selectedStatementId) {
            this.loadStatementWorkspace();
        } else {
            this.statementWorkspace = undefined;
        }
    }

    handleStatementChange(event) {
        this.selectedStatementId = event.detail.value;
        this.loadStatementWorkspace();
    }

    handleRefresh() {
        this.successMessage = undefined;
        this.loadDashboard();
    }

    handleImportHeaderChange(event) {
        const field = event.target.dataset.field;
        let value = event.target.value;

        if (field === 'openingAmount' || field === 'closingAmount') {
            value = value === '' ? null : Number(value);
        }

        const map = {
            startDate: 'importStartDate',
            endDate: 'importEndDate',
            openingAmount: 'importOpeningAmount',
            closingAmount: 'importClosingAmount',
            currencyCode: 'importCurrencyCode',
            importFingerprint: 'importFingerprint'
        };

        this[map[field]] = value;
    }

    handleImportLineChange(event) {
        const key = event.target.dataset.key;
        const field = event.target.dataset.field;
        let value = event.target.value;

        if (field === 'lineNumber' || field === 'amount') {
            value = value === '' ? null : Number(value);
        }

        this.importLines = this.importLines.map(
            (line) =>
                line.key === key
                    ? { ...line, [field]: value }
                    : line
        );
    }

    addImportLine() {
        const key = `line-${++this.lineKeySequence}`;

        this.importLines = [
            ...this.importLines,
            {
                key,
                lineNumber: this.importLines.length + 1,
                transactionDate: this.importEndDate,
                valueDate: this.importEndDate,
                amount: null,
                providerLineId: '',
                reference: ''
            }
        ];
    }

    handleAddLine() {
        this.addImportLine();
    }

    handleRemoveLine(event) {
        const key = event.currentTarget.dataset.key;

        if (this.importLines.length <= 1) {
            return;
        }

        this.importLines = this.importLines
            .filter((line) => line.key !== key)
            .map((line, index) => ({
                ...line,
                lineNumber: index + 1
            }));
    }

    async handleImportStatement() {
        this.isLoading = true;
        this.errorMessage = undefined;
        this.successMessage = undefined;

        try {
            const result = await importStatement({
                input: {
                    bankAccountId: this.selectedBankAccountId,
                    statementStartDate: this.importStartDate,
                    statementEndDate: this.importEndDate,
                    openingAmount: this.importOpeningAmount,
                    closingAmount: this.importClosingAmount,
                    currencyCode: this.importCurrencyCode,
                    importFingerprint: this.importFingerprint,
                    lines: this.importLines.map((line) => ({
                        lineNumber: line.lineNumber,
                        transactionDate: line.transactionDate,
                        valueDate: line.valueDate,
                        amount: line.amount,
                        providerLineId: line.providerLineId,
                        reference: line.reference,
                        sourceRawText: null,
                        lineFingerprint: null
                    }))
                }
            });

            this.successMessage = result.message;
            this.selectedStatementId = result.recordId;
            await this.loadDashboard();
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async handleValidateStatement() {
        await this.runAction(
            () => validateStatement({
                bankStatementId: this.selectedStatementId
            })
        );
    }

    async handleStartReconciliation() {
        await this.runAction(
            () => startReconciliation({
                bankStatementId: this.selectedStatementId
            })
        );
    }

    async handleFindMatches(event) {
        this.selectedLineId =
            event.currentTarget.dataset.lineId;

        this.isLoading = true;
        this.errorMessage = undefined;

        try {
            this.candidates = await getMatchCandidates({
                reconciliationId:
                    this.statementWorkspace.reconciliationId,
                bankStatementLineId: this.selectedLineId,
                dayWindow: Number(this.candidateDayWindow)
            });
        } catch (error) {
            this.errorMessage = this.reduceError(error);
            this.candidates = [];
        } finally {
            this.isLoading = false;
        }
    }

    handleDayWindowChange(event) {
        this.candidateDayWindow = Number(event.target.value);
    }

    async handleManualMatch(event) {
        await this.runAction(
            () => createManualMatch({
                reconciliationId:
                    this.statementWorkspace.reconciliationId,
                bankStatementLineId: this.selectedLineId,
                journalEntryLineId:
                    event.currentTarget.dataset.journalLineId,
                matchedAmount:
                    Number(event.currentTarget.dataset.amount)
            })
        );
    }

    async handleProposeMatch(event) {
        await this.runAction(
            () => createSuggestedMatch({
                reconciliationId:
                    this.statementWorkspace.reconciliationId,
                bankStatementLineId: this.selectedLineId,
                journalEntryLineId:
                    event.currentTarget.dataset.journalLineId,
                matchedAmount:
                    Number(event.currentTarget.dataset.amount)
            })
        );
    }

    async handleConfirmMatch(event) {
        await this.runAction(
            () => confirmMatch({
                matchId: event.currentTarget.dataset.matchId
            })
        );
    }

    async handleReverseMatch(event) {
        const confirmed = await LightningConfirm.open({
            message:
                'Reverse this reconciliation match? The audit history will be preserved.',
            label: 'Reverse Match',
            variant: 'headerless'
        });

        if (!confirmed) {
            return;
        }

        await this.runAction(
            () => reverseMatch({
                matchId: event.currentTarget.dataset.matchId
            })
        );
    }

    async handleFinalize() {
        const confirmed = await LightningConfirm.open({
            message:
                'Finalize this bank reconciliation? Closing balances will be snapshotted and the statement will be marked Reconciled.',
            label: 'Finalize Bank Reconciliation',
            variant: 'headerless'
        });

        if (!confirmed) {
            return;
        }

        await this.runAction(
            () => finalizeReconciliation({
                reconciliationId:
                    this.statementWorkspace.reconciliationId
            })
        );
    }

    async runAction(action) {
        this.isLoading = true;
        this.errorMessage = undefined;
        this.successMessage = undefined;

        try {
            const result = await action();
            this.successMessage = result.message;
            await this.loadDashboard();
        } catch (error) {
            this.errorMessage = this.reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    handleOpenRecord(event) {
        const recordId =
            event.currentTarget.dataset.recordId;

        if (!recordId) {
            return;
        }

        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId,
                actionName: 'view'
            }
        });
    }

    syncImportCurrency() {
        if (this.selectedBankAccount) {
            this.importCurrencyCode =
                this.selectedBankAccount.currencyCode;
        }
    }

    get hasCompany() {
        return Boolean(this.companyId);
    }

    get hasDashboard() {
        return Boolean(this.dashboard);
    }

    get hasBankAccounts() {
        return Boolean(
            this.dashboard
            && this.dashboard.bankAccounts
            && this.dashboard.bankAccounts.length
        );
    }

    get bankAccountOptions() {
        return (this.dashboard?.bankAccounts || []).map(
            (bank) => ({
                label: `${bank.name} · ${bank.currencyCode}`,
                value: bank.bankAccountId
            })
        );
    }

    get filteredStatements() {
        return (this.dashboard?.statements || []).filter(
            (row) =>
                row.bankAccountId === this.selectedBankAccountId
        );
    }

    get statementOptions() {
        return this.filteredStatements.map(
            (row) => ({
                label: row.label,
                value: row.statementId
            })
        );
    }

    get selectedBankAccount() {
        return (this.dashboard?.bankAccounts || []).find(
            (row) =>
                row.bankAccountId === this.selectedBankAccountId
        );
    }

    get canImport() {
        return Boolean(this.dashboard?.canImport);
    }

    get canReconcile() {
        return Boolean(this.dashboard?.canReconcile);
    }

    get canFinalize() {
        return Boolean(this.dashboard?.canFinalize);
    }

    get hasCandidates() {
        return Boolean(this.candidates?.length);
    }

    get hasMatches() {
        return Boolean(
            this.statementWorkspace?.matches?.length
        );
    }

    get validateDisabled() {
        return (
            !this.canImport
            || this.statementWorkspace?.statementStatus !== 'Imported'
            || this.isLoading
        );
    }

    get startReconciliationDisabled() {
        return (
            !this.canReconcile
            || !this.statementWorkspace
            || !['Validated', 'Reconciled'].includes(
                this.statementWorkspace.statementStatus
            )
            || this.statementWorkspace.reconciliationStatus === 'Finalized'
            || this.isLoading
        );
    }

    get finalizeDisabled() {
        return (
            !this.canFinalize
            || !this.statementWorkspace?.canFinalizeNow
            || this.isLoading
        );
    }

    get importDisabled() {
        return (
            !this.canImport
            || !this.selectedBankAccountId
            || !this.importStartDate
            || !this.importEndDate
            || this.importOpeningAmount === null
            || this.importOpeningAmount === undefined
            || this.importClosingAmount === null
            || this.importClosingAmount === undefined
            || !this.importCurrencyCode
            || this.importLines.some(
                (line) =>
                    !line.transactionDate
                    || line.amount === null
                    || line.amount === undefined
            )
            || this.isLoading
        );
    }

    get functionalCashLabel() {
        return this.dashboard
            ? `${this.dashboard.functionalCurrencyBookCash} ${this.dashboard.functionalCurrency}`
            : '';
    }

    get differenceClass() {
        return this.statementWorkspace?.provisionalDifference === 0
            ? 'summary-value good'
            : 'summary-value bad';
    }

    get finalized() {
        return (
            this.statementWorkspace?.reconciliationStatus
            === 'Finalized'
        );
    }

    reduceError(error) {
        if (error?.body?.message) {
            return error.body.message;
        }
        if (error?.message) {
            return error.message;
        }
        return 'Unexpected Bank Reconciliation Workspace error.';
    }
}
