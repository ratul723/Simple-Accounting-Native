/**
 * G8B - Expense Claim Accounting & Posting.
 *
 * Approved Expense Claim -> Accounting Event -> balanced Subledger Journal
 * -> Posted Expense Claim.
 *
 * Accounting contract:
 * - Debit Expense by taxable base + nonrecoverable purchase tax.
 * - Debit Input Tax control account by recoverable purchase tax.
 * - Credit Employee Reimbursement Liability by the approved reimbursable total.
 *
 * G8A intentionally supports functional-currency claims only. G8B therefore
 * posts at exchange rate 1 and leaves foreign-currency employee expenses for a
 * later expense-FX slice.
 */
public without sharing class SABExpenseClaimPostingService {

    public class ExpenseClaimPostingException extends Exception {}

    private static final String POST_PERMISSION =
        'SAB_Post_Expense_Claim';

    private static final String STATUS_APPROVED =
        'Approved';

    private static final String STATUS_POSTED =
        'Posted';

    private static final String ENTRY_TYPE_SUBLEDGER =
        'Subledger';

    private static final String SOURCE_TYPE =
        'Expense_Claim__c';

    private static final String ADAPTER_KEY =
        'EXPENSE_CLAIM';

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    @TestVisible
    private static Boolean snapshotMutationInProgress =
        false;

    public static Boolean isSnapshotMutationInProgress() {
        return snapshotMutationInProgress;
    }

    public class PostingRequest {
        @AuraEnabled public Id expenseClaimId { get; set; }
        @AuraEnabled public String requestKey { get; set; }
    }

    public class PostingResult {
        @AuraEnabled public Id expenseClaimId { get; private set; }
        @AuraEnabled public Id journalEntryId { get; private set; }
        @AuraEnabled public Id accountingEventId { get; private set; }
        @AuraEnabled public String postingKey { get; private set; }
        @AuraEnabled public Datetime postedAt { get; private set; }
        @AuraEnabled public Decimal reimbursableTotal { get; private set; }
        @AuraEnabled public Decimal recoverableTaxTotal { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private PostingResult() {}
    }

    private class LinePlan {
        public Expense_Claim_Line__c sourceLine;
        public Decimal expenseDebit;
        public Decimal recoverableTax;
        public Id inputTaxAccountId;
    }

    @AuraEnabled
    public static PostingResult postApprovedClaim(
        PostingRequest request
    ) {
        validateRequest(
            request
        );

        SABPermissionService.assertPermission(
            POST_PERMISSION,
            'You do not have permission to post Expense Claims.'
        );

        Expense_Claim__c initialClaim = [
            SELECT Id,
                   Company__c,
                   Status__c,
                   Accounting_Event__c
            FROM Expense_Claim__c
            WHERE Id =
                    :request.expenseClaimId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(
            initialClaim.Company__c
        );

        if (initialClaim.Status__c == STATUS_POSTED) {
            return resolvePostedReplay(
                initialClaim
            );
        }

        if (initialClaim.Status__c != STATUS_APPROVED) {
            throw new ExpenseClaimPostingException(
                'Expense Claim must be Approved before posting.'
            );
        }

        Savepoint outerSavepoint =
            Database.setSavepoint();

        try {
            Expense_Claim__c claim = [
                SELECT Id,
                       Name,
                       Company__c,
                       Company__r.Functional_Currency__c,
                       Company__r.Employee_Reimbursement_Liability_Account__c,
                       Company__r.Employee_Reimbursement_Liability_Account__r.Company__c,
                       Company__r.Employee_Reimbursement_Liability_Account__r.Is_Active__c,
                       Company__r.Employee_Reimbursement_Liability_Account__r.Is_Control_Account__c,
                       Company__r.Employee_Reimbursement_Liability_Account__r.Control_Type__c,
                       Company__r.Employee_Reimbursement_Liability_Account__r.Account_Type__c,
                       Claimant_Employment__c,
                       Claimant_Employment__r.Company__c,
                       Claim_Date__c,
                       Accounting_Date__c,
                       Currency__c,
                       Status__c,
                       Total__c,
                       Approval_Request__c,
                       Accounting_Event__c
                FROM Expense_Claim__c
                WHERE Id =
                        :request.expenseClaimId
                LIMIT 1
                FOR UPDATE
            ];

            SABCompanyAccessService.assertCompanyAccess(
                claim.Company__c
            );

            if (claim.Status__c == STATUS_POSTED) {
                return resolvePostedReplay(
                    claim
                );
            }

            if (claim.Status__c != STATUS_APPROVED) {
                throw new ExpenseClaimPostingException(
                    'Expense Claim changed while posting. Retry the posting request.'
                );
            }

            if (claim.Accounting_Event__c != null) {
                throw new ExpenseClaimPostingException(
                    'Approved Expense Claim already contains an Accounting Event link.'
                );
            }

            if (claim.Accounting_Date__c == null) {
                throw new ExpenseClaimPostingException(
                    'Expense Claim Accounting Date is required before posting.'
                );
            }

            validateFunctionalCurrency(
                claim
            );

            validateReimbursementLiabilityAccount(
                claim
            );

            Accounting_Period__c period =
                resolveAndLockOpenPeriod(
                    claim.Company__c,
                    claim.Accounting_Date__c
                );

            List<Expense_Claim_Line__c> lines = [
                SELECT Id,
                       Expense_Claim__c,
                       Expense_Date__c,
                       Category__c,
                       Description__c,
                       Amount__c,
                       Expense_Account__c,
                       Expense_Account__r.Company__c,
                       Expense_Account__r.Is_Active__c,
                       Expense_Account__r.Is_Control_Account__c,
                       Expense_Account__r.Account_Type__c,
                       Tax_Code__c,
                       Tax_Code__r.Company__c,
                       Tax_Code__r.Inclusive__c,
                       Tax_Code__r.Is_Active__c,
                       Tax_Code__r.Treatment__c,
                       Tax_Code__r.Input_Tax_Account__c,
                       Tax_Code__r.Input_Tax_Account__r.Company__c,
                       Tax_Code__r.Input_Tax_Account__r.Is_Active__c,
                       Tax_Code__r.Input_Tax_Account__r.Is_Control_Account__c,
                       Tax_Code__r.Input_Tax_Account__r.Control_Type__c,
                       Department__c,
                       Project__c,
                       Tax_Rate__c,
                       Tax_Rate_Percent__c,
                       Taxable_Base__c,
                       Tax_Amount__c,
                       Recoverable_Tax_Amount__c,
                       Nonrecoverable_Tax_Amount__c,
                       Tax_Code_Key__c,
                       Tax_Jurisdiction__c,
                       Tax_Treatment__c,
                       Tax_Country_Pack_Version__c
                FROM Expense_Claim_Line__c
                WHERE Expense_Claim__c =
                        :claim.Id
            ];

            if (lines.isEmpty()) {
                throw new ExpenseClaimPostingException(
                    'Expense Claim must contain at least one Expense Claim Line.'
                );
            }

            Decimal approvedTotal =
                SABMoneyService.normalizeTransactionAmount(
                    claim.Total__c == null
                        ? ZERO
                        : claim.Total__c,
                    RoundingMode.HALF_UP
                );

            Decimal lineTotal =
                ZERO;

            for (Expense_Claim_Line__c line : lines) {
                lineTotal +=
                    SABMoneyService.normalizeTransactionAmount(
                        line.Amount__c == null
                            ? ZERO
                            : line.Amount__c,
                        RoundingMode.HALF_UP
                    );
            }

            lineTotal =
                SABMoneyService.normalizeTransactionAmount(
                    lineTotal,
                    RoundingMode.HALF_UP
                );

            if (approvedTotal != lineTotal) {
                throw new ExpenseClaimPostingException(
                    'Expense Claim Total no longer matches the approved line total.'
                );
            }

            List<LinePlan> plans =
                buildAndMaterializeLinePlans(
                    claim,
                    lines
                );

            String postingKey =
                buildPostingKey(
                    claim.Id
                );

            Journal_Entry__c journal =
                new Journal_Entry__c(
                    Company__c =
                        claim.Company__c,
                    Accounting_Period__c =
                        period.Id,
                    Accounting_Date__c =
                        claim.Accounting_Date__c,
                    Entry_Type__c =
                        ENTRY_TYPE_SUBLEDGER,
                    Status__c =
                        'Draft',
                    Description__c =
                        truncateText(
                            'Expense Claim - '
                            + claim.Name,
                            Journal_Entry__c.Description__c.getDescribe().getLength()
                        ),
                    Version__c =
                        1
                );
            insert journal;

            List<Journal_Entry_Line__c> journalLines =
                new List<Journal_Entry_Line__c>();

            Decimal nextLineNumber =
                1;

            Decimal recoverableTaxTotal =
                ZERO;

            Decimal debitTotal =
                ZERO;

            for (LinePlan plan : plans) {
                Expense_Claim_Line__c sourceLine =
                    plan.sourceLine;

                if (plan.expenseDebit != ZERO) {
                    journalLines.add(
                        new Journal_Entry_Line__c(
                            Journal_Entry__c =
                                journal.Id,
                            GL_Account__c =
                                sourceLine.Expense_Account__c,
                            Line_Number__c =
                                nextLineNumber,
                            Debit_Base__c =
                                plan.expenseDebit,
                            Credit_Base__c =
                                ZERO,
                            Explanation__c =
                                truncateText(
                                    sourceLine.Description__c,
                                    Journal_Entry_Line__c.Explanation__c.getDescribe().getLength()
                                ),
                            Transaction_Amount__c =
                                plan.expenseDebit,
                            Transaction_Currency__c =
                                claim.Currency__c,
                            Functional_Currency__c =
                                claim.Company__r.Functional_Currency__c,
                            Applied_Exchange_Rate__c =
                                Decimal.valueOf('1'),
                            Rate_Date__c =
                                claim.Accounting_Date__c,
                            Rate_Source__c =
                                'Expense Claim Functional Currency',
                            Source_Line_Key__c =
                                'EC|'
                                + String.valueOf(
                                    claim.Id
                                )
                                + '|LINE|'
                                + String.valueOf(
                                    sourceLine.Id
                                )
                                + '|EXP',
                            Department__c =
                                sourceLine.Department__c,
                            Project__c =
                                sourceLine.Project__c
                        )
                    );

                    debitTotal +=
                        plan.expenseDebit;
                    nextLineNumber++;
                }

                if (plan.recoverableTax != ZERO) {
                    journalLines.add(
                        new Journal_Entry_Line__c(
                            Journal_Entry__c =
                                journal.Id,
                            GL_Account__c =
                                plan.inputTaxAccountId,
                            Line_Number__c =
                                nextLineNumber,
                            Debit_Base__c =
                                plan.recoverableTax,
                            Credit_Base__c =
                                ZERO,
                            Explanation__c =
                                truncateText(
                                    'Recoverable input tax - '
                                    + sourceLine.Description__c,
                                    Journal_Entry_Line__c.Explanation__c.getDescribe().getLength()
                                ),
                            Transaction_Amount__c =
                                plan.recoverableTax,
                            Transaction_Currency__c =
                                claim.Currency__c,
                            Functional_Currency__c =
                                claim.Company__r.Functional_Currency__c,
                            Applied_Exchange_Rate__c =
                                Decimal.valueOf('1'),
                            Rate_Date__c =
                                claim.Accounting_Date__c,
                            Rate_Source__c =
                                'Expense Claim Tax Snapshot',
                            Source_Line_Key__c =
                                'EC|'
                                + String.valueOf(
                                    claim.Id
                                )
                                + '|LINE|'
                                + String.valueOf(
                                    sourceLine.Id
                                )
                                + '|TAX'
                        )
                    );

                    debitTotal +=
                        plan.recoverableTax;
                    recoverableTaxTotal +=
                        plan.recoverableTax;
                    nextLineNumber++;
                }
            }

            debitTotal =
                SABMoneyService.normalizeLedgerAmount(
                    debitTotal,
                    RoundingMode.HALF_UP
                );

            recoverableTaxTotal =
                SABMoneyService.normalizeLedgerAmount(
                    recoverableTaxTotal,
                    RoundingMode.HALF_UP
                );

            Decimal liabilityCredit =
                SABMoneyService.normalizeLedgerAmount(
                    approvedTotal,
                    RoundingMode.HALF_UP
                );

            if (debitTotal != liabilityCredit) {
                throw new ExpenseClaimPostingException(
                    'Expense Claim tax allocation does not reconcile to the approved reimbursable total.'
                );
            }

            journalLines.add(
                new Journal_Entry_Line__c(
                    Journal_Entry__c =
                        journal.Id,
                    GL_Account__c =
                        claim.Company__r.Employee_Reimbursement_Liability_Account__c,
                    Line_Number__c =
                        nextLineNumber,
                    Debit_Base__c =
                        ZERO,
                    Credit_Base__c =
                        liabilityCredit,
                    Explanation__c =
                        truncateText(
                            'Employee reimbursement liability - '
                            + claim.Name,
                            Journal_Entry_Line__c.Explanation__c.getDescribe().getLength()
                        ),
                    Transaction_Amount__c =
                        liabilityCredit,
                    Transaction_Currency__c =
                        claim.Currency__c,
                    Functional_Currency__c =
                        claim.Company__r.Functional_Currency__c,
                    Applied_Exchange_Rate__c =
                        Decimal.valueOf('1'),
                    Rate_Date__c =
                        claim.Accounting_Date__c,
                    Rate_Source__c =
                        'Expense Claim Functional Currency',
                    Source_Line_Key__c =
                        'EC|'
                        + String.valueOf(
                            claim.Id
                        )
                        + '|LIABILITY'
                )
            );

            insert journalLines;

            SABAccountingEventService.ReservationRequest eventRequest =
                new SABAccountingEventService.ReservationRequest();

            eventRequest.companyId =
                claim.Company__c;
            eventRequest.adapterKey =
                ADAPTER_KEY;
            eventRequest.requestKey =
                request.requestKey.trim();
            eventRequest.eventKey =
                buildEventKey(
                    claim.Id
                );
            eventRequest.eventType =
                'Expense Claim';
            eventRequest.sourceBusinessKey =
                claim.Name;
            eventRequest.sourceRecordId =
                String.valueOf(
                    claim.Id
                );
            eventRequest.sourceType =
                SOURCE_TYPE;
            eventRequest.sourceVersion =
                1;

            SABPostingService.PostingRequest postingRequest =
                new SABPostingService.PostingRequest();

            postingRequest.journalEntryId =
                journal.Id;
            postingRequest.postingKey =
                postingKey;
            postingRequest.eventRequest =
                eventRequest;

            SABPostingService.PostingResult postedJournal =
                SABPostingService.postDraftJournal(
                    postingRequest
                );

            SABExpenseClaimLifecycleService.LifecycleResult
                claimCompletion =
                    SABExpenseClaimLifecycleService.completePosting(
                        claim.Id,
                        postedJournal.accountingEventId,
                        postedJournal.journalEntryId,
                        buildAuditRequestKey(
                            claim.Id
                        )
                    );

            PostingResult result =
                new PostingResult();

            result.expenseClaimId =
                claim.Id;
            result.journalEntryId =
                postedJournal.journalEntryId;
            result.accountingEventId =
                postedJournal.accountingEventId;
            result.postingKey =
                postedJournal.postingKey;
            result.postedAt =
                postedJournal.postedAt;
            result.reimbursableTotal =
                approvedTotal;
            result.recoverableTaxTotal =
                recoverableTaxTotal;
            result.replay =
                postedJournal.replay
                || claimCompletion.replay;

            return result;
        } catch (Exception ex) {
            Database.rollback(
                outerSavepoint
            );
            throw ex;
        }
    }

    private static List<LinePlan> buildAndMaterializeLinePlans(
        Expense_Claim__c claim,
        List<Expense_Claim_Line__c> lines
    ) {
        List<LinePlan> result =
            new List<LinePlan>();

        List<Expense_Claim_Line__c> snapshotUpdates =
            new List<Expense_Claim_Line__c>();

        for (Expense_Claim_Line__c line : lines) {
            validateExpenseAccount(
                claim,
                line
            );

            Decimal lineAmount =
                SABMoneyService.normalizeTransactionAmount(
                    line.Amount__c == null
                        ? ZERO
                        : line.Amount__c,
                    RoundingMode.HALF_UP
                );

            if (lineAmount <= ZERO) {
                throw new ExpenseClaimPostingException(
                    'Every Expense Claim Line Amount must be greater than zero.'
                );
            }

            LinePlan plan =
                new LinePlan();

            plan.sourceLine =
                line;
            plan.expenseDebit =
                lineAmount;
            plan.recoverableTax =
                ZERO;
            plan.inputTaxAccountId =
                null;

            Expense_Claim_Line__c updateRow =
                new Expense_Claim_Line__c(
                    Id =
                        line.Id
                );

            if (line.Tax_Code__c == null) {
                updateRow.Tax_Rate__c =
                    null;
                updateRow.Tax_Rate_Percent__c =
                    null;
                updateRow.Taxable_Base__c =
                    lineAmount;
                updateRow.Tax_Amount__c =
                    ZERO;
                updateRow.Recoverable_Tax_Amount__c =
                    ZERO;
                updateRow.Nonrecoverable_Tax_Amount__c =
                    ZERO;
                updateRow.Tax_Code_Key__c =
                    null;
                updateRow.Tax_Jurisdiction__c =
                    null;
                updateRow.Tax_Treatment__c =
                    null;
                updateRow.Tax_Country_Pack_Version__c =
                    null;

                snapshotUpdates.add(
                    updateRow
                );
                result.add(
                    plan
                );
                continue;
            }

            if (
                line.Tax_Code__r == null
                || line.Tax_Code__r.Company__c
                    != claim.Company__c
                || line.Tax_Code__r.Is_Active__c
                    != true
            ) {
                throw new ExpenseClaimPostingException(
                    'Expense Claim Line Tax Code must be active and belong to the same Accounting Company.'
                );
            }

            if (
                line.Tax_Code__r.Treatment__c
                    == 'Standard'
                && line.Tax_Code__r.Inclusive__c
                    != true
            ) {
                throw new ExpenseClaimPostingException(
                    'G8B Expense Claim amounts represent employee-paid receipt totals. Standard tax codes on Expense Claims must therefore be configured as Inclusive.'
                );
            }

            SABTaxService.TaxRequest taxRequest =
                new SABTaxService.TaxRequest();

            taxRequest.companyId =
                claim.Company__c;
            taxRequest.taxCodeId =
                line.Tax_Code__c;
            taxRequest.taxDate =
                line.Expense_Date__c;
            taxRequest.lineAmount =
                lineAmount;
            taxRequest.documentSide =
                SABTaxService.SIDE_PURCHASE;
            taxRequest.roundingMode =
                RoundingMode.HALF_UP;

            SABTaxService.TaxSnapshot snapshot;

            try {
                snapshot =
                    SABTaxService.calculate(
                        taxRequest
                    );
            } catch (SABTaxService.TaxException ex) {
                throw new ExpenseClaimPostingException(
                    ex.getMessage()
                );
            }

            Decimal snapshotGross =
                SABMoneyService.normalizeTransactionAmount(
                    snapshot.grossAmount,
                    RoundingMode.HALF_UP
                );

            if (snapshotGross != lineAmount) {
                throw new ExpenseClaimPostingException(
                    'Expense Claim tax snapshot gross amount must equal the employee reimbursable line amount.'
                );
            }

            Decimal expenseDebit =
                SABMoneyService.normalizeTransactionAmount(
                    snapshot.taxableBase
                    + snapshot.nonrecoverableAmount,
                    RoundingMode.HALF_UP
                );

            Decimal recoverableTax =
                SABMoneyService.normalizeTransactionAmount(
                    snapshot.recoverableAmount,
                    RoundingMode.HALF_UP
                );

            if (recoverableTax != ZERO) {
                validateInputTaxAccount(
                    claim,
                    line
                );

                plan.inputTaxAccountId =
                    line.Tax_Code__r.Input_Tax_Account__c;
            }

            plan.expenseDebit =
                expenseDebit;
            plan.recoverableTax =
                recoverableTax;

            updateRow.Tax_Rate__c =
                snapshot.taxRateId;
            updateRow.Tax_Rate_Percent__c =
                snapshot.taxRatePercent;
            updateRow.Taxable_Base__c =
                snapshot.taxableBase;
            updateRow.Tax_Amount__c =
                snapshot.taxAmount;
            updateRow.Recoverable_Tax_Amount__c =
                snapshot.recoverableAmount;
            updateRow.Nonrecoverable_Tax_Amount__c =
                snapshot.nonrecoverableAmount;
            updateRow.Tax_Code_Key__c =
                snapshot.taxCodeKey;
            updateRow.Tax_Jurisdiction__c =
                snapshot.jurisdiction;
            updateRow.Tax_Treatment__c =
                snapshot.treatment;
            updateRow.Tax_Country_Pack_Version__c =
                snapshot.countryPackVersion;

            snapshotUpdates.add(
                updateRow
            );

            result.add(
                plan
            );
        }

        snapshotMutationInProgress =
            true;

        try {
            update snapshotUpdates;
        } finally {
            snapshotMutationInProgress =
                false;
        }

        return result;
    }

    private static void validateFunctionalCurrency(
        Expense_Claim__c claim
    ) {
        String claimCurrency =
            SABMoneyService.normalizeCurrencyCode(
                claim.Currency__c
            );

        String functionalCurrency =
            SABMoneyService.normalizeCurrencyCode(
                claim.Company__r.Functional_Currency__c
            );

        if (claimCurrency != functionalCurrency) {
            throw new ExpenseClaimPostingException(
                'G8B posts functional-currency Expense Claims only.'
            );
        }
    }

    private static void validateExpenseAccount(
        Expense_Claim__c claim,
        Expense_Claim_Line__c line
    ) {
        if (
            line.Expense_Account__c == null
            || line.Expense_Account__r == null
        ) {
            throw new ExpenseClaimPostingException(
                'Every Expense Claim Line requires an Expense Account before posting.'
            );
        }

        if (
            line.Expense_Account__r.Company__c
                != claim.Company__c
            || line.Expense_Account__r.Is_Active__c
                != true
            || line.Expense_Account__r.Is_Control_Account__c
                == true
            || line.Expense_Account__r.Account_Type__c
                != 'Expense'
        ) {
            throw new ExpenseClaimPostingException(
                'Expense Claim Line Expense Account must be an active, non-control Expense account in the same Accounting Company.'
            );
        }
    }

    private static void validateInputTaxAccount(
        Expense_Claim__c claim,
        Expense_Claim_Line__c line
    ) {
        if (
            line.Tax_Code__r.Input_Tax_Account__c
                == null
            || line.Tax_Code__r.Input_Tax_Account__r
                == null
        ) {
            throw new ExpenseClaimPostingException(
                'Recoverable Expense Claim tax requires an Input Tax Account on the Tax Code.'
            );
        }

        GL_Account__c taxAccount =
            line.Tax_Code__r.Input_Tax_Account__r;

        if (
            taxAccount.Company__c
                != claim.Company__c
            || taxAccount.Is_Active__c
                != true
            || taxAccount.Is_Control_Account__c
                != true
            || taxAccount.Control_Type__c
                != 'Tax'
        ) {
            throw new ExpenseClaimPostingException(
                'Expense Claim Input Tax Account must be an active Tax control account in the same Accounting Company.'
            );
        }
    }

    private static void validateReimbursementLiabilityAccount(
        Expense_Claim__c claim
    ) {
        if (
            claim.Company__r.Employee_Reimbursement_Liability_Account__c
                == null
            || claim.Company__r.Employee_Reimbursement_Liability_Account__r
                == null
        ) {
            throw new ExpenseClaimPostingException(
                'Accounting Company requires an Employee Reimbursement Liability Account before Expense Claims can be posted.'
            );
        }

        GL_Account__c liability =
            claim.Company__r.Employee_Reimbursement_Liability_Account__r;

        if (
            liability.Company__c
                != claim.Company__c
            || liability.Is_Active__c
                != true
            || liability.Is_Control_Account__c
                != true
            || liability.Control_Type__c
                != 'Other'
            || liability.Account_Type__c
                != 'Liability'
        ) {
            throw new ExpenseClaimPostingException(
                'Employee Reimbursement Liability Account must be an active Liability control account with Control Type Other in the same Accounting Company.'
            );
        }
    }

    private static Accounting_Period__c resolveAndLockOpenPeriod(
        Id companyId,
        Date accountingDate
    ) {
        List<Accounting_Period__c> periods = [
            SELECT Id,
                   Company__c,
                   Status__c,
                   Start_Date__c,
                   End_Date__c
            FROM Accounting_Period__c
            WHERE Company__c =
                    :companyId
              AND Start_Date__c <=
                    :accountingDate
              AND End_Date__c >=
                    :accountingDate
            LIMIT 2
            FOR UPDATE
        ];

        if (periods.isEmpty()) {
            throw new ExpenseClaimPostingException(
                'No Accounting Period contains the Expense Claim Accounting Date.'
            );
        }

        if (periods.size() > 1) {
            throw new ExpenseClaimPostingException(
                'More than one Accounting Period contains the Expense Claim Accounting Date.'
            );
        }

        if (periods[0].Status__c != 'Open') {
            throw new ExpenseClaimPostingException(
                'Expense Claim Accounting Period must be Open.'
            );
        }

        return periods[0];
    }

    private static PostingResult resolvePostedReplay(
        Expense_Claim__c claim
    ) {
        if (claim.Accounting_Event__c == null) {
            throw new ExpenseClaimPostingException(
                'Posted Expense Claim is missing its Accounting Event link.'
            );
        }

        Accounting_Event__c eventRecord = [
            SELECT Id,
                   Company__c,
                   Event_Key__c,
                   Source_Type__c,
                   Source_Record_Id__c,
                   State__c,
                   Journal_Entry__c,
                   Journal_Entry__r.Status__c,
                   Journal_Entry__r.Entry_Type__c,
                   Journal_Entry__r.Posting_Key__c,
                   Journal_Entry__r.Posted_At__c
            FROM Accounting_Event__c
            WHERE Id =
                    :claim.Accounting_Event__c
            LIMIT 1
        ];

        if (
            eventRecord.Company__c != claim.Company__c
            || eventRecord.Event_Key__c
                != buildEventKey(
                    claim.Id
                )
            || eventRecord.Source_Type__c
                != SOURCE_TYPE
            || eventRecord.Source_Record_Id__c
                != String.valueOf(
                    claim.Id
                )
            || eventRecord.State__c
                != 'Posted'
            || eventRecord.Journal_Entry__c
                == null
            || eventRecord.Journal_Entry__r.Status__c
                != 'Posted'
            || eventRecord.Journal_Entry__r.Entry_Type__c
                != ENTRY_TYPE_SUBLEDGER
            || eventRecord.Journal_Entry__r.Posting_Key__c
                != buildPostingKey(
                    claim.Id
                )
        ) {
            throw new ExpenseClaimPostingException(
                'Posted Expense Claim does not have a consistent subledger posting chain.'
            );
        }

        PostingResult result =
            new PostingResult();

        result.expenseClaimId =
            claim.Id;
        result.journalEntryId =
            eventRecord.Journal_Entry__c;
        result.accountingEventId =
            eventRecord.Id;
        result.postingKey =
            eventRecord.Journal_Entry__r.Posting_Key__c;
        result.postedAt =
            eventRecord.Journal_Entry__r.Posted_At__c;
        result.replay =
            true;

        Expense_Claim__c stored = [
            SELECT Total__c
            FROM Expense_Claim__c
            WHERE Id =
                    :claim.Id
        ];

        result.reimbursableTotal =
            stored.Total__c;

        AggregateResult taxTotal = [
            SELECT SUM(Recoverable_Tax_Amount__c) total
            FROM Expense_Claim_Line__c
            WHERE Expense_Claim__c =
                    :claim.Id
        ];

        Decimal recovered =
            (Decimal) taxTotal.get(
                'total'
            );

        result.recoverableTaxTotal =
            recovered == null
                ? ZERO
                : recovered;

        return result;
    }

    private static String buildPostingKey(
        Id claimId
    ) {
        return 'EC|'
            + String.valueOf(
                claimId
            )
            + '|V1';
    }

    private static String buildEventKey(
        Id claimId
    ) {
        return 'EXPENSE_CLAIM|'
            + String.valueOf(
                claimId
            )
            + '|V1';
    }

    private static String buildAuditRequestKey(
        Id claimId
    ) {
        return 'ECPOST|'
            + String.valueOf(
                claimId
            );
    }

    private static String truncateText(
        String value,
        Integer maxLength
    ) {
        if (String.isBlank(value)) {
            return value;
        }

        if (
            maxLength == null
            || maxLength <= 0
            || value.length() <= maxLength
        ) {
            return value;
        }

        return value.substring(
            0,
            maxLength
        );
    }

    private static void validateRequest(
        PostingRequest request
    ) {
        if (request == null) {
            throw new ExpenseClaimPostingException(
                'Expense Claim posting request is required.'
            );
        }

        if (request.expenseClaimId == null) {
            throw new ExpenseClaimPostingException(
                'Expense Claim Id is required.'
            );
        }

        if (String.isBlank(request.requestKey)) {
            throw new ExpenseClaimPostingException(
                'Request Key is required.'
            );
        }

        Integer maxLength =
            Accounting_Event__c.Created_Request_Key__c.getDescribe().getLength();

        if (
            maxLength > 0
            && request.requestKey.trim().length()
                > maxLength
        ) {
            throw new ExpenseClaimPostingException(
                'Request Key cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }
}
