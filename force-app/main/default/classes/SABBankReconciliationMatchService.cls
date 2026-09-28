/**
 * G5B - Bank Statement Line <-> Posted Bank GL Line matching.
 *
 * G5A imports and validates raw bank statements. G5B starts a reconciliation
 * container and records auditable matches against posted Journal Entry Lines.
 *
 * Matching does not create or edit accounting journals.
 * G5C owns reconciliation finalization.
 */
public with sharing class SABBankReconciliationMatchService {

    public class BankReconciliationMatchException extends Exception {}

    private static final String RECONCILE_PERMISSION =
        'SAB_Reconcile_Bank';

    private static final String STATEMENT_VALIDATED =
        'Validated';

    private static final String STATEMENT_RECONCILED =
        'Reconciled';

    private static final String RECON_DRAFT =
        'Draft';

    private static final String RECON_IN_REVIEW =
        'In Review';

    private static final String RECON_FINALIZED =
        'Finalized';

    private static final String MATCH_MANUAL =
        'Manual';

    private static final String MATCH_SUGGESTED =
        'Suggested';

    private static final String MATCH_PROPOSED =
        'Proposed';

    private static final String MATCH_CONFIRMED =
        'Confirmed';

    private static final String MATCH_REVERSED =
        'Reversed';

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    private static final Integer DEFAULT_DAY_WINDOW =
        7;

    private static final Integer MAX_DAY_WINDOW =
        90;

    private static final Integer DEFAULT_CANDIDATE_LIMIT =
        50;

    private static final Integer MAX_CANDIDATE_LIMIT =
        200;

    public class ReconciliationResult {
        @AuraEnabled public Id reconciliationId { get; private set; }
        @AuraEnabled public String status { get; private set; }
        @AuraEnabled public Id bankStatementId { get; private set; }
        @AuraEnabled public Id bankAccountId { get; private set; }
        @AuraEnabled public Decimal statementClosingAmount { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }
    }

    public class MatchCandidate {
        @AuraEnabled public Id journalEntryLineId { get; private set; }
        @AuraEnabled public Id journalEntryId { get; private set; }
        @AuraEnabled public Date accountingDate { get; private set; }
        @AuraEnabled public String journalDescription { get; private set; }
        @AuraEnabled public Decimal journalAmount { get; private set; }
        @AuraEnabled public Decimal journalRemainingAmount { get; private set; }
        @AuraEnabled public Decimal statementRemainingAmount { get; private set; }
        @AuraEnabled public Decimal suggestedMatchAmount { get; private set; }
        @AuraEnabled public Integer dateDifferenceDays { get; private set; }
        @AuraEnabled public Boolean exactAmount { get; private set; }
        @AuraEnabled public String transactionCurrency { get; private set; }
        @AuraEnabled public String sourceLineKey { get; private set; }
    }

    public class MatchResult {
        @AuraEnabled public Id matchId { get; private set; }
        @AuraEnabled public Id reconciliationId { get; private set; }
        @AuraEnabled public Id bankStatementLineId { get; private set; }
        @AuraEnabled public Id journalEntryLineId { get; private set; }
        @AuraEnabled public Decimal matchedAmount { get; private set; }
        @AuraEnabled public String matchType { get; private set; }
        @AuraEnabled public String status { get; private set; }
        @AuraEnabled public Decimal statementRemainingAmount { get; private set; }
        @AuraEnabled public Decimal journalRemainingAmount { get; private set; }
    }

    @AuraEnabled
    public static ReconciliationResult startReconciliation(
        Id bankStatementId
    ) {
        assertPermission();

        if (bankStatementId == null) {
            throw new BankReconciliationMatchException(
                'Bank Statement Id is required.'
            );
        }

        assertStartAccess();

        Bank_Statement__c statement = [
            SELECT Id,
                   Company__c,
                   Bank_Account__c,
                   Bank_Account__r.Company__c,
                   Bank_Account__r.GL_Account__c,
                   Bank_Account__r.GL_Account__r.Company__c,
                   Bank_Account__r.Currency__c,
                   Bank_Account__r.Is_Active__c,
                   Currency__c,
                   Status__c,
                   Closing_Amount__c
            FROM Bank_Statement__c
            WHERE Id = :bankStatementId
            LIMIT 1
            FOR UPDATE
        ];

        SABCompanyAccessService.assertCompanyAccess(
            statement.Company__c
        );

        SABAccessControlService.assertRecordReadAccess(
            statement.Id
        );

        validateStatementForMatching(
            statement
        );

        List<Bank_Reconciliation__c> existing = [
            SELECT Id,
                   Bank_Statement__c,
                   Bank_Account__c,
                   Statement_Closing_Amount__c,
                   Status__c
            FROM Bank_Reconciliation__c
            WHERE Bank_Statement__c = :statement.Id
            ORDER BY CreatedDate DESC
        ];

        for (Bank_Reconciliation__c row : existing) {
            if (
                row.Status__c == RECON_DRAFT
                || row.Status__c == RECON_IN_REVIEW
            ) {
                return buildReconciliationResult(
                    row,
                    true
                );
            }

            if (row.Status__c == RECON_FINALIZED) {
                throw new BankReconciliationMatchException(
                    'The Bank Statement already has a Finalized reconciliation.'
                );
            }
        }

        Bank_Reconciliation__c reconciliation =
            new Bank_Reconciliation__c(
                Company__c =
                    statement.Company__c,
                Bank_Account__c =
                    statement.Bank_Account__c,
                Bank_Statement__c =
                    statement.Id,
                Statement_Closing_Amount__c =
                    statement.Closing_Amount__c,
                Status__c =
                    RECON_DRAFT
            );

        insert reconciliation;

        return buildReconciliationResult(
            reconciliation,
            false
        );
    }

    @AuraEnabled(cacheable=true)
    public static List<MatchCandidate> getMatchCandidates(
        Id reconciliationId,
        Id bankStatementLineId,
        Integer dayWindow,
        Integer maxResults
    ) {
        assertPermission();

        ReconciliationContext context =
            loadContext(
                reconciliationId,
                bankStatementLineId,
                false
            );

        Integer resolvedDayWindow =
            dayWindow == null
                ? DEFAULT_DAY_WINDOW
                : dayWindow;

        if (
            resolvedDayWindow < 0
            || resolvedDayWindow > MAX_DAY_WINDOW
        ) {
            throw new BankReconciliationMatchException(
                'Candidate day window must be between 0 and '
                + MAX_DAY_WINDOW
                + ' days.'
            );
        }

        Integer resolvedLimit =
            maxResults == null
                ? DEFAULT_CANDIDATE_LIMIT
                : maxResults;

        if (
            resolvedLimit <= 0
            || resolvedLimit > MAX_CANDIDATE_LIMIT
        ) {
            throw new BankReconciliationMatchException(
                'Candidate result limit must be between 1 and '
                + MAX_CANDIDATE_LIMIT
                + '.'
            );
        }

        Decimal statementRemaining =
            remainingStatementAmount(
                context.statementLine
            );

        if (statementRemaining <= ZERO) {
            return new List<MatchCandidate>();
        }

        Date minDate =
            context.statementLine.Transaction_Date__c.addDays(
                -resolvedDayWindow
            );

        Date maxDate =
            context.statementLine.Transaction_Date__c.addDays(
                resolvedDayWindow
            );

        if (
            maxDate
            > context.statement.Statement_End_Date__c
        ) {
            maxDate =
                context.statement.Statement_End_Date__c;
        }

        List<Journal_Entry_Line__c> journalLines = [
            SELECT Id,
                   Journal_Entry__c,
                   Journal_Entry__r.Company__c,
                   Journal_Entry__r.Status__c,
                   Journal_Entry__r.Accounting_Date__c,
                   Journal_Entry__r.Description__c,
                   GL_Account__c,
                   Debit_Base__c,
                   Credit_Base__c,
                   Transaction_Amount__c,
                   Transaction_Currency__c,
                   Functional_Currency__c,
                   Source_Line_Key__c
            FROM Journal_Entry_Line__c
            WHERE GL_Account__c =
                    :context.bankAccount.GL_Account__c
              AND Journal_Entry__r.Company__c =
                    :context.reconciliation.Company__c
              AND Journal_Entry__r.Status__c = 'Posted'
              AND Journal_Entry__r.Accounting_Date__c >= :minDate
              AND Journal_Entry__r.Accounting_Date__c <= :maxDate
            ORDER BY Journal_Entry__r.Accounting_Date__c ASC,
                     Journal_Entry__c ASC,
                     Line_Number__c ASC
            LIMIT :resolvedLimit
        ];

        Set<Id> journalLineIds =
            new Set<Id>();

        for (Journal_Entry_Line__c line : journalLines) {
            journalLineIds.add(
                line.Id
            );
        }

        Map<Id, Decimal> matchedByJournalLine =
            activeMatchedAmountsByJournalLine(
                journalLineIds
            );

        List<MatchCandidate> result =
            new List<MatchCandidate>();

        for (Journal_Entry_Line__c line : journalLines) {
            if (
                !directionMatches(
                    context.statementLine.Amount__c,
                    line
                )
            ) {
                continue;
            }

            Decimal journalAmount =
                journalMatchableAmount(
                    line,
                    context.statement.Currency__c
                );

            if (journalAmount <= ZERO) {
                continue;
            }

            Decimal alreadyMatched =
                matchedByJournalLine.containsKey(
                    line.Id
                )
                    ? matchedByJournalLine.get(
                        line.Id
                    )
                    : ZERO;

            Decimal journalRemaining =
                journalAmount
                - alreadyMatched;

            if (journalRemaining <= ZERO) {
                continue;
            }

            Decimal suggested =
                smallerOf(
                    statementRemaining,
                    journalRemaining
                );

            MatchCandidate candidate =
                new MatchCandidate();

            candidate.journalEntryLineId =
                line.Id;
            candidate.journalEntryId =
                line.Journal_Entry__c;
            candidate.accountingDate =
                line.Journal_Entry__r.Accounting_Date__c;
            candidate.journalDescription =
                line.Journal_Entry__r.Description__c;
            candidate.journalAmount =
                journalAmount;
            candidate.journalRemainingAmount =
                journalRemaining;
            candidate.statementRemainingAmount =
                statementRemaining;
            candidate.suggestedMatchAmount =
                suggested;
            candidate.dateDifferenceDays =
                absoluteInteger(
                    context.statementLine.Transaction_Date__c.daysBetween(
                        line.Journal_Entry__r.Accounting_Date__c
                    )
                );
            candidate.exactAmount =
                statementRemaining
                    == journalRemaining;
            candidate.transactionCurrency =
                resolvedJournalCurrency(
                    line,
                    context.statement.Currency__c
                );
            candidate.sourceLineKey =
                line.Source_Line_Key__c;

            result.add(
                candidate
            );
        }

        return result;
    }

    @AuraEnabled
    public static MatchResult createManualMatch(
        Id reconciliationId,
        Id bankStatementLineId,
        Id journalEntryLineId,
        Decimal matchedAmount
    ) {
        return createMatch(
            reconciliationId,
            bankStatementLineId,
            journalEntryLineId,
            matchedAmount,
            MATCH_MANUAL,
            MATCH_CONFIRMED
        );
    }

    @AuraEnabled
    public static MatchResult createSuggestedMatch(
        Id reconciliationId,
        Id bankStatementLineId,
        Id journalEntryLineId,
        Decimal matchedAmount
    ) {
        return createMatch(
            reconciliationId,
            bankStatementLineId,
            journalEntryLineId,
            matchedAmount,
            MATCH_SUGGESTED,
            MATCH_PROPOSED
        );
    }

    @AuraEnabled
    public static MatchResult confirmSuggestedMatch(
        Id matchId
    ) {
        assertPermission();

        if (matchId == null) {
            throw new BankReconciliationMatchException(
                'Reconciliation Match Id is required.'
            );
        }

        assertMatchUpdateAccess();

        Reconciliation_Match__c matchRow = [
            SELECT Id,
                   Bank_Reconciliation__c,
                   Bank_Reconciliation__r.Status__c,
                   Bank_Statement_Line__c,
                   Journal_Entry_Line__c,
                   Matched_Amount__c,
                   Match_Type__c,
                   Status__c
            FROM Reconciliation_Match__c
            WHERE Id = :matchId
            LIMIT 1
            FOR UPDATE
        ];

        if (matchRow.Status__c != MATCH_PROPOSED) {
            throw new BankReconciliationMatchException(
                'Only a Proposed reconciliation match can be confirmed.'
            );
        }

        if (
            matchRow.Bank_Reconciliation__r.Status__c
                == RECON_FINALIZED
        ) {
            throw new BankReconciliationMatchException(
                'A Finalized Bank Reconciliation cannot be changed.'
            );
        }

        // Re-run all financial-capacity and company/currency rules while
        // excluding the proposal itself from the active-match totals.
        MatchValidation validation =
            validateMatch(
                matchRow.Bank_Reconciliation__c,
                matchRow.Bank_Statement_Line__c,
                matchRow.Journal_Entry_Line__c,
                matchRow.Matched_Amount__c,
                matchRow.Id
            );

        matchRow.Status__c =
            MATCH_CONFIRMED;

        update matchRow;

        moveReconciliationToReview(
            validation.reconciliation
        );

        return buildMatchResult(
            matchRow,
            validation.statementRemainingAfter,
            validation.journalRemainingAfter
        );
    }

    @AuraEnabled
    public static MatchResult reverseMatch(
        Id matchId
    ) {
        assertPermission();

        if (matchId == null) {
            throw new BankReconciliationMatchException(
                'Reconciliation Match Id is required.'
            );
        }

        assertMatchCreateAccess();
        assertMatchUpdateAccess();

        Reconciliation_Match__c original = [
            SELECT Id,
                   Bank_Reconciliation__c,
                   Bank_Reconciliation__r.Company__c,
                   Bank_Reconciliation__r.Status__c,
                   Bank_Statement_Line__c,
                   Journal_Entry_Line__c,
                   Match_Type__c,
                   Matched_Amount__c,
                   Status__c
            FROM Reconciliation_Match__c
            WHERE Id = :matchId
            LIMIT 1
            FOR UPDATE
        ];

        SABCompanyAccessService.assertCompanyAccess(
            original.Bank_Reconciliation__r.Company__c
        );

        SABAccessControlService.assertRecordEditAccess(
            original.Id
        );

        if (
            original.Bank_Reconciliation__r.Status__c
                == RECON_FINALIZED
        ) {
            throw new BankReconciliationMatchException(
                'A Finalized Bank Reconciliation cannot be changed.'
            );
        }

        if (
            original.Status__c != MATCH_CONFIRMED
            && original.Status__c != MATCH_PROPOSED
        ) {
            throw new BankReconciliationMatchException(
                'Only an active Proposed or Confirmed reconciliation match can be reversed.'
            );
        }

        original.Status__c =
            MATCH_REVERSED;

        update original;

        Reconciliation_Match__c reversal =
            new Reconciliation_Match__c(
                Bank_Reconciliation__c =
                    original.Bank_Reconciliation__c,
                Bank_Statement_Line__c =
                    original.Bank_Statement_Line__c,
                Journal_Entry_Line__c =
                    original.Journal_Entry_Line__c,
                Match_Type__c =
                    original.Match_Type__c,
                Matched_Amount__c =
                    -absoluteAmount(
                        original.Matched_Amount__c
                    ),
                Status__c =
                    MATCH_REVERSED,
                Reversal_Of__c =
                    original.Id
            );

        insert reversal;

        ReconciliationContext context =
            loadContext(
                original.Bank_Reconciliation__c,
                original.Bank_Statement_Line__c,
                false
            );

        Journal_Entry_Line__c journalLine =
            loadJournalLine(
                original.Journal_Entry_Line__c,
                false
            );

        Decimal statementRemaining =
            remainingStatementAmount(
                context.statementLine
            );

        Decimal journalRemaining =
            journalMatchableAmount(
                journalLine,
                context.statement.Currency__c
            )
            - activeMatchedAmountForJournalLine(
                journalLine.Id,
                null
            );

        return buildMatchResult(
            reversal,
            statementRemaining,
            journalRemaining
        );
    }

    private static MatchResult createMatch(
        Id reconciliationId,
        Id bankStatementLineId,
        Id journalEntryLineId,
        Decimal matchedAmount,
        String matchType,
        String statusValue
    ) {
        assertPermission();

        assertMatchCreateAccess();

        MatchValidation validation =
            validateMatch(
                reconciliationId,
                bankStatementLineId,
                journalEntryLineId,
                matchedAmount,
                null
            );

        Reconciliation_Match__c matchRow =
            new Reconciliation_Match__c(
                Bank_Reconciliation__c =
                    reconciliationId,
                Bank_Statement_Line__c =
                    bankStatementLineId,
                Journal_Entry_Line__c =
                    journalEntryLineId,
                Match_Type__c =
                    matchType,
                Matched_Amount__c =
                    absoluteAmount(
                        matchedAmount
                    ),
                Status__c =
                    statusValue
            );

        insert matchRow;

        if (statusValue == MATCH_CONFIRMED) {
            moveReconciliationToReview(
                validation.reconciliation
            );
        }

        return buildMatchResult(
            matchRow,
            validation.statementRemainingAfter,
            validation.journalRemainingAfter
        );
    }

    private static MatchValidation validateMatch(
        Id reconciliationId,
        Id bankStatementLineId,
        Id journalEntryLineId,
        Decimal matchedAmount,
        Id excludedMatchId
    ) {
        if (
            reconciliationId == null
            || bankStatementLineId == null
            || journalEntryLineId == null
        ) {
            throw new BankReconciliationMatchException(
                'Reconciliation, Bank Statement Line and Journal Entry Line are required.'
            );
        }

        Decimal normalizedMatchAmount =
            absoluteAmount(
                matchedAmount
            );

        if (normalizedMatchAmount <= ZERO) {
            throw new BankReconciliationMatchException(
                'Matched Amount must be greater than zero.'
            );
        }

        ReconciliationContext context =
            loadContext(
                reconciliationId,
                bankStatementLineId,
                true
            );

        Journal_Entry_Line__c journalLine =
            loadJournalLine(
                journalEntryLineId,
                true
            );

        validateJournalLine(
            context,
            journalLine
        );

        List<Reconciliation_Match__c> duplicateRows = [
            SELECT Id
            FROM Reconciliation_Match__c
            WHERE Bank_Reconciliation__c =
                    :reconciliationId
              AND Bank_Statement_Line__c =
                    :bankStatementLineId
              AND Journal_Entry_Line__c =
                    :journalEntryLineId
              AND Status__c IN (
                    'Proposed',
                    'Confirmed'
              )
        ];

        for (Reconciliation_Match__c row : duplicateRows) {
            if (
                excludedMatchId == null
                || row.Id != excludedMatchId
            ) {
                throw new BankReconciliationMatchException(
                    'An active reconciliation match already exists for this Bank Statement Line and Journal Entry Line.'
                );
            }
        }

        Decimal activeOnStatement =
            activeMatchedAmountForStatementLine(
                bankStatementLineId,
                excludedMatchId
            );

        Decimal statementTotal =
            absoluteAmount(
                context.statementLine.Amount__c
            );

        Decimal statementRemainingBefore =
            statementTotal
            - activeOnStatement;

        if (
            normalizedMatchAmount
            > statementRemainingBefore
        ) {
            throw new BankReconciliationMatchException(
                'Matched Amount exceeds the remaining Bank Statement Line amount.'
            );
        }

        Decimal journalTotal =
            journalMatchableAmount(
                journalLine,
                context.statement.Currency__c
            );

        Decimal activeOnJournal =
            activeMatchedAmountForJournalLine(
                journalEntryLineId,
                excludedMatchId
            );

        Decimal journalRemainingBefore =
            journalTotal
            - activeOnJournal;

        if (
            normalizedMatchAmount
            > journalRemainingBefore
        ) {
            throw new BankReconciliationMatchException(
                'Matched Amount exceeds the remaining Journal Entry Line amount.'
            );
        }

        MatchValidation validation =
            new MatchValidation();

        validation.reconciliation =
            context.reconciliation;
        validation.statementRemainingAfter =
            statementRemainingBefore
            - normalizedMatchAmount;
        validation.journalRemainingAfter =
            journalRemainingBefore
            - normalizedMatchAmount;

        return validation;
    }

    private static ReconciliationContext loadContext(
        Id reconciliationId,
        Id bankStatementLineId,
        Boolean lockRows
    ) {
        if (
            reconciliationId == null
            || bankStatementLineId == null
        ) {
            throw new BankReconciliationMatchException(
                'Reconciliation and Bank Statement Line are required.'
            );
        }

        List<Bank_Reconciliation__c> reconciliations;

        if (lockRows) {
            reconciliations = [
                SELECT Id,
                       Company__c,
                       Bank_Account__c,
                       Bank_Account__r.Company__c,
                       Bank_Account__r.GL_Account__c,
                       Bank_Account__r.GL_Account__r.Company__c,
                       Bank_Account__r.Currency__c,
                       Bank_Account__r.Is_Active__c,
                       Bank_Statement__c,
                       Bank_Statement__r.Company__c,
                       Bank_Statement__r.Bank_Account__c,
                       Bank_Statement__r.Bank_Account__r.Company__c,
                       Bank_Statement__r.Bank_Account__r.Currency__c,
                       Bank_Statement__r.Bank_Account__r.GL_Account__c,
                       Bank_Statement__r.Bank_Account__r.GL_Account__r.Company__c,
                       Bank_Statement__r.Bank_Account__r.Is_Active__c,
                       Bank_Statement__r.Currency__c,
                       Bank_Statement__r.Statement_Start_Date__c,
                       Bank_Statement__r.Statement_End_Date__c,
                       Bank_Statement__r.Status__c,
                       Status__c
                FROM Bank_Reconciliation__c
                WHERE Id = :reconciliationId
                LIMIT 1
                FOR UPDATE
            ];
        } else {
            reconciliations = [
                SELECT Id,
                       Company__c,
                       Bank_Account__c,
                       Bank_Account__r.Company__c,
                       Bank_Account__r.GL_Account__c,
                       Bank_Account__r.GL_Account__r.Company__c,
                       Bank_Account__r.Currency__c,
                       Bank_Account__r.Is_Active__c,
                       Bank_Statement__c,
                       Bank_Statement__r.Company__c,
                       Bank_Statement__r.Bank_Account__c,
                       Bank_Statement__r.Bank_Account__r.Company__c,
                       Bank_Statement__r.Bank_Account__r.Currency__c,
                       Bank_Statement__r.Bank_Account__r.GL_Account__c,
                       Bank_Statement__r.Bank_Account__r.GL_Account__r.Company__c,
                       Bank_Statement__r.Bank_Account__r.Is_Active__c,
                       Bank_Statement__r.Currency__c,
                       Bank_Statement__r.Statement_Start_Date__c,
                       Bank_Statement__r.Statement_End_Date__c,
                       Bank_Statement__r.Status__c,
                       Status__c
                FROM Bank_Reconciliation__c
                WHERE Id = :reconciliationId
                LIMIT 1
            ];
        }

        if (reconciliations.isEmpty()) {
            throw new BankReconciliationMatchException(
                'Bank Reconciliation was not found.'
            );
        }

        Bank_Reconciliation__c reconciliation =
            reconciliations[0];

        SABCompanyAccessService.assertCompanyAccess(
            reconciliation.Company__c
        );

        SABAccessControlService.assertRecordReadAccess(
            reconciliation.Id
        );

        if (reconciliation.Status__c == RECON_FINALIZED) {
            throw new BankReconciliationMatchException(
                'A Finalized Bank Reconciliation cannot be changed.'
            );
        }

        if (
            reconciliation.Bank_Statement__r == null
            || reconciliation.Bank_Statement__r.Company__c
                != reconciliation.Company__c
            || reconciliation.Bank_Statement__r.Bank_Account__c
                != reconciliation.Bank_Account__c
        ) {
            throw new BankReconciliationMatchException(
                'Bank Reconciliation, Bank Statement and Bank Account must be company-consistent.'
            );
        }

        validateStatementForMatching(
            reconciliation.Bank_Statement__r
        );

        List<Bank_Statement_Line__c> statementLines;

        if (lockRows) {
            statementLines = [
                SELECT Id,
                       Bank_Statement__c,
                       Line_Number__c,
                       Transaction_Date__c,
                       Value_Date__c,
                       Amount__c,
                       Reference__c,
                       Provider_Line_Id__c
                FROM Bank_Statement_Line__c
                WHERE Id = :bankStatementLineId
                LIMIT 1
                FOR UPDATE
            ];
        } else {
            statementLines = [
                SELECT Id,
                       Bank_Statement__c,
                       Line_Number__c,
                       Transaction_Date__c,
                       Value_Date__c,
                       Amount__c,
                       Reference__c,
                       Provider_Line_Id__c
                FROM Bank_Statement_Line__c
                WHERE Id = :bankStatementLineId
                LIMIT 1
            ];
        }

        if (statementLines.isEmpty()) {
            throw new BankReconciliationMatchException(
                'Bank Statement Line was not found.'
            );
        }

        Bank_Statement_Line__c statementLine =
            statementLines[0];

        if (
            statementLine.Bank_Statement__c
            != reconciliation.Bank_Statement__c
        ) {
            throw new BankReconciliationMatchException(
                'Bank Statement Line does not belong to the Reconciliation Bank Statement.'
            );
        }

        if (
            statementLine.Amount__c == null
            || statementLine.Amount__c == ZERO
        ) {
            throw new BankReconciliationMatchException(
                'A zero Bank Statement Line cannot be reconciled.'
            );
        }

        ReconciliationContext context =
            new ReconciliationContext();

        context.reconciliation =
            reconciliation;
        context.statement =
            reconciliation.Bank_Statement__r;
        context.statementLine =
            statementLine;
        context.bankAccount =
            reconciliation.Bank_Account__r;

        return context;
    }

    private static Journal_Entry_Line__c loadJournalLine(
        Id journalEntryLineId,
        Boolean lockRow
    ) {
        List<Journal_Entry_Line__c> rows;

        if (lockRow) {
            rows = [
                SELECT Id,
                       Journal_Entry__c,
                       Journal_Entry__r.Company__c,
                       Journal_Entry__r.Status__c,
                       Journal_Entry__r.Accounting_Date__c,
                       Journal_Entry__r.Description__c,
                       GL_Account__c,
                       Debit_Base__c,
                       Credit_Base__c,
                       Transaction_Amount__c,
                       Transaction_Currency__c,
                       Functional_Currency__c,
                       Source_Line_Key__c
                FROM Journal_Entry_Line__c
                WHERE Id = :journalEntryLineId
                LIMIT 1
                FOR UPDATE
            ];
        } else {
            rows = [
                SELECT Id,
                       Journal_Entry__c,
                       Journal_Entry__r.Company__c,
                       Journal_Entry__r.Status__c,
                       Journal_Entry__r.Accounting_Date__c,
                       Journal_Entry__r.Description__c,
                       GL_Account__c,
                       Debit_Base__c,
                       Credit_Base__c,
                       Transaction_Amount__c,
                       Transaction_Currency__c,
                       Functional_Currency__c,
                       Source_Line_Key__c
                FROM Journal_Entry_Line__c
                WHERE Id = :journalEntryLineId
                LIMIT 1
            ];
        }

        if (rows.isEmpty()) {
            throw new BankReconciliationMatchException(
                'Journal Entry Line was not found.'
            );
        }

        return rows[0];
    }

    private static void validateJournalLine(
        ReconciliationContext context,
        Journal_Entry_Line__c journalLine
    ) {
        if (
            journalLine.Journal_Entry__r == null
            || journalLine.Journal_Entry__r.Status__c
                != 'Posted'
        ) {
            throw new BankReconciliationMatchException(
                'Only a Posted Journal Entry Line can be reconciled.'
            );
        }

        if (
            journalLine.Journal_Entry__r.Company__c
                != context.reconciliation.Company__c
        ) {
            throw new BankReconciliationMatchException(
                'Cross-company Bank Reconciliation matching is not allowed.'
            );
        }

        if (
            journalLine.GL_Account__c
                != context.bankAccount.GL_Account__c
        ) {
            throw new BankReconciliationMatchException(
                'Journal Entry Line must use the Bank Account GL Account.'
            );
        }

        if (
            journalLine.Journal_Entry__r.Accounting_Date__c
                > context.statement.Statement_End_Date__c
        ) {
            throw new BankReconciliationMatchException(
                'Journal Entry Line Accounting Date cannot be after the Bank Statement End Date.'
            );
        }

        if (
            !directionMatches(
                context.statementLine.Amount__c,
                journalLine
            )
        ) {
            throw new BankReconciliationMatchException(
                'Bank Statement Line direction does not match the Bank GL debit/credit direction.'
            );
        }

        Decimal matchable =
            journalMatchableAmount(
                journalLine,
                context.statement.Currency__c
            );

        if (matchable <= ZERO) {
            throw new BankReconciliationMatchException(
                'Journal Entry Line currency/amount is not compatible with the Bank Statement currency.'
            );
        }
    }

    private static void validateStatementForMatching(
        Bank_Statement__c statement
    ) {
        if (statement == null) {
            throw new BankReconciliationMatchException(
                'Bank Statement was not found.'
            );
        }

        if (
            statement.Status__c != STATEMENT_VALIDATED
            && statement.Status__c != STATEMENT_RECONCILED
        ) {
            throw new BankReconciliationMatchException(
                'Bank Statement must be Validated before reconciliation matching.'
            );
        }

        if (
            statement.Bank_Account__r == null
            || statement.Bank_Account__r.Is_Active__c
                != true
        ) {
            throw new BankReconciliationMatchException(
                'Bank Account must be active for reconciliation matching.'
            );
        }

        if (
            statement.Bank_Account__r.Company__c
                != statement.Company__c
            || statement.Bank_Account__r.GL_Account__c
                == null
            || statement.Bank_Account__r.GL_Account__r == null
            || statement.Bank_Account__r.GL_Account__r.Company__c
                != statement.Company__c
        ) {
            throw new BankReconciliationMatchException(
                'Bank Statement Bank Account and Bank GL Account must belong to the same Accounting Company.'
            );
        }

        if (
            SABMoneyService.normalizeCurrencyCode(
                statement.Bank_Account__r.Currency__c
            )
            != SABMoneyService.normalizeCurrencyCode(
                statement.Currency__c
            )
        ) {
            throw new BankReconciliationMatchException(
                'Bank Statement currency must match the Bank Account currency.'
            );
        }
    }

    private static Boolean directionMatches(
        Decimal statementAmount,
        Journal_Entry_Line__c journalLine
    ) {
        Decimal debit =
            journalLine.Debit_Base__c == null
                ? ZERO
                : journalLine.Debit_Base__c;

        Decimal credit =
            journalLine.Credit_Base__c == null
                ? ZERO
                : journalLine.Credit_Base__c;

        if (statementAmount > ZERO) {
            return debit > ZERO
                && credit == ZERO;
        }

        if (statementAmount < ZERO) {
            return credit > ZERO
                && debit == ZERO;
        }

        return false;
    }

    private static Decimal journalMatchableAmount(
        Journal_Entry_Line__c journalLine,
        String statementCurrency
    ) {
        String normalizedStatementCurrency =
            SABMoneyService.normalizeCurrencyCode(
                statementCurrency
            );

        if (
            !String.isBlank(
                journalLine.Transaction_Currency__c
            )
            && journalLine.Transaction_Amount__c != null
            && SABMoneyService.normalizeCurrencyCode(
                journalLine.Transaction_Currency__c
            )
                == normalizedStatementCurrency
        ) {
            return absoluteAmount(
                journalLine.Transaction_Amount__c
            );
        }

        if (
            !String.isBlank(
                journalLine.Functional_Currency__c
            )
            && SABMoneyService.normalizeCurrencyCode(
                journalLine.Functional_Currency__c
            )
                == normalizedStatementCurrency
        ) {
            Decimal debit =
                journalLine.Debit_Base__c == null
                    ? ZERO
                    : journalLine.Debit_Base__c;

            Decimal credit =
                journalLine.Credit_Base__c == null
                    ? ZERO
                    : journalLine.Credit_Base__c;

            return debit > ZERO
                ? debit
                : credit;
        }

        return ZERO;
    }

    private static String resolvedJournalCurrency(
        Journal_Entry_Line__c journalLine,
        String statementCurrency
    ) {
        if (
            !String.isBlank(
                journalLine.Transaction_Currency__c
            )
        ) {
            return SABMoneyService.normalizeCurrencyCode(
                journalLine.Transaction_Currency__c
            );
        }

        if (
            !String.isBlank(
                journalLine.Functional_Currency__c
            )
        ) {
            return SABMoneyService.normalizeCurrencyCode(
                journalLine.Functional_Currency__c
            );
        }

        return SABMoneyService.normalizeCurrencyCode(
            statementCurrency
        );
    }

    private static Decimal remainingStatementAmount(
        Bank_Statement_Line__c statementLine
    ) {
        Decimal total =
            absoluteAmount(
                statementLine.Amount__c
            );

        Decimal active =
            activeMatchedAmountForStatementLine(
                statementLine.Id,
                null
            );

        Decimal remaining =
            total
            - active;

        return remaining < ZERO
            ? ZERO
            : remaining;
    }

    private static Decimal activeMatchedAmountForStatementLine(
        Id statementLineId,
        Id excludedMatchId
    ) {
        Decimal total =
            ZERO;

        for (Reconciliation_Match__c matchRow : [
            SELECT Id,
                   Matched_Amount__c
            FROM Reconciliation_Match__c
            WHERE Bank_Statement_Line__c =
                    :statementLineId
              AND Status__c IN (
                    'Proposed',
                    'Confirmed'
              )
        ]) {
            if (
                excludedMatchId != null
                && matchRow.Id == excludedMatchId
            ) {
                continue;
            }

            total +=
                absoluteAmount(
                    matchRow.Matched_Amount__c
                );
        }

        return total;
    }

    private static Decimal activeMatchedAmountForJournalLine(
        Id journalLineId,
        Id excludedMatchId
    ) {
        Decimal total =
            ZERO;

        for (Reconciliation_Match__c matchRow : [
            SELECT Id,
                   Matched_Amount__c
            FROM Reconciliation_Match__c
            WHERE Journal_Entry_Line__c =
                    :journalLineId
              AND Status__c IN (
                    'Proposed',
                    'Confirmed'
              )
        ]) {
            if (
                excludedMatchId != null
                && matchRow.Id == excludedMatchId
            ) {
                continue;
            }

            total +=
                absoluteAmount(
                    matchRow.Matched_Amount__c
                );
        }

        return total;
    }

    private static Map<Id, Decimal>
        activeMatchedAmountsByJournalLine(
            Set<Id> journalLineIds
        )
    {
        Map<Id, Decimal> result =
            new Map<Id, Decimal>();

        if (
            journalLineIds == null
            || journalLineIds.isEmpty()
        ) {
            return result;
        }

        for (Reconciliation_Match__c row : [
            SELECT Journal_Entry_Line__c,
                   Matched_Amount__c
            FROM Reconciliation_Match__c
            WHERE Journal_Entry_Line__c IN :journalLineIds
              AND Status__c IN (
                    'Proposed',
                    'Confirmed'
              )
        ]) {
            Decimal current =
                result.containsKey(
                    row.Journal_Entry_Line__c
                )
                    ? result.get(
                        row.Journal_Entry_Line__c
                    )
                    : ZERO;

            current +=
                absoluteAmount(
                    row.Matched_Amount__c
                );

            result.put(
                row.Journal_Entry_Line__c,
                current
            );
        }

        return result;
    }

    private static void moveReconciliationToReview(
        Bank_Reconciliation__c reconciliation
    ) {
        if (
            reconciliation == null
            || reconciliation.Status__c
                != RECON_DRAFT
        ) {
            return;
        }

        assertReconciliationUpdateAccess();

        reconciliation.Status__c =
            RECON_IN_REVIEW;

        update reconciliation;
    }

    private static ReconciliationResult
        buildReconciliationResult(
            Bank_Reconciliation__c row,
            Boolean replay
        )
    {
        ReconciliationResult result =
            new ReconciliationResult();

        result.reconciliationId =
            row.Id;
        result.status =
            row.Status__c;
        result.bankStatementId =
            row.Bank_Statement__c;
        result.bankAccountId =
            row.Bank_Account__c;
        result.statementClosingAmount =
            row.Statement_Closing_Amount__c;
        result.replay =
            replay;

        return result;
    }

    private static MatchResult buildMatchResult(
        Reconciliation_Match__c row,
        Decimal statementRemaining,
        Decimal journalRemaining
    ) {
        MatchResult result =
            new MatchResult();

        result.matchId =
            row.Id;
        result.reconciliationId =
            row.Bank_Reconciliation__c;
        result.bankStatementLineId =
            row.Bank_Statement_Line__c;
        result.journalEntryLineId =
            row.Journal_Entry_Line__c;
        result.matchedAmount =
            row.Matched_Amount__c;
        result.matchType =
            row.Match_Type__c;
        result.status =
            row.Status__c;
        result.statementRemainingAmount =
            statementRemaining < ZERO
                ? ZERO
                : statementRemaining;
        result.journalRemainingAmount =
            journalRemaining < ZERO
                ? ZERO
                : journalRemaining;

        return result;
    }

    private static Decimal absoluteAmount(
        Decimal value
    ) {
        if (value == null) {
            return ZERO;
        }

        return value < ZERO
            ? -value
            : value;
    }

    private static Decimal smallerOf(
        Decimal leftValue,
        Decimal rightValue
    ) {
        return leftValue <= rightValue
            ? leftValue
            : rightValue;
    }

    private static Integer absoluteInteger(
        Integer value
    ) {
        return value < 0
            ? -value
            : value;
    }

    private static void assertPermission() {
        SABPermissionService.assertPermission(
            RECONCILE_PERMISSION,
            'You do not have permission to reconcile Bank Statements.'
        );
    }

    private static void assertStartAccess() {
        SABAccessControlService.assertReadable(
            Bank_Statement__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Statement__c.Status__c
            }
        );

        SABAccessControlService.assertReadable(
            Bank_Account__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Account__c.GL_Account__c,
                Bank_Account__c.Currency__c,
                Bank_Account__c.Is_Active__c
            }
        );

        SABAccessControlService.assertCreateable(
            Bank_Reconciliation__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Reconciliation__c.Statement_Closing_Amount__c,
                Bank_Reconciliation__c.Status__c
            }
        );
    }

    private static void assertMatchCreateAccess() {
        SABAccessControlService.assertReadable(
            Bank_Reconciliation__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Reconciliation__c.Status__c
            }
        );

        SABAccessControlService.assertReadable(
            Bank_Statement__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Statement__c.Status__c
            }
        );

        SABAccessControlService.assertReadable(
            Bank_Statement_Line__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Statement_Line__c.Reference__c,
                Bank_Statement_Line__c.Provider_Line_Id__c,
                Bank_Statement_Line__c.Value_Date__c
            }
        );

        SABAccessControlService.assertReadable(
            Journal_Entry__c.SObjectType,
            new List<Schema.SObjectField>{
                Journal_Entry__c.Description__c
            }
        );

        SABAccessControlService.assertReadable(
            Journal_Entry_Line__c.SObjectType,
            new List<Schema.SObjectField>{
                Journal_Entry_Line__c.Debit_Base__c,
                Journal_Entry_Line__c.Credit_Base__c,
                Journal_Entry_Line__c.Transaction_Amount__c,
                Journal_Entry_Line__c.Transaction_Currency__c,
                Journal_Entry_Line__c.Source_Line_Key__c
            }
        );

        SABAccessControlService.assertCreateable(
            Reconciliation_Match__c.SObjectType,
            new List<Schema.SObjectField>{
                Reconciliation_Match__c.Match_Type__c,
                Reconciliation_Match__c.Status__c,
                Reconciliation_Match__c.Reversal_Of__c
            }
        );
    }

    private static void assertMatchUpdateAccess() {
        SABAccessControlService.assertUpdateable(
            Reconciliation_Match__c.SObjectType,
            new List<Schema.SObjectField>{
                Reconciliation_Match__c.Status__c
            }
        );
    }

    private static void assertReconciliationUpdateAccess() {
        SABAccessControlService.assertUpdateable(
            Bank_Reconciliation__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Reconciliation__c.Status__c
            }
        );
    }

    private class ReconciliationContext {
        Bank_Reconciliation__c reconciliation;
        Bank_Statement__c statement;
        Bank_Statement_Line__c statementLine;
        Bank_Account__c bankAccount;
    }

    private class MatchValidation {
        Bank_Reconciliation__c reconciliation;
        Decimal statementRemainingAfter;
        Decimal journalRemainingAfter;
    }
}
