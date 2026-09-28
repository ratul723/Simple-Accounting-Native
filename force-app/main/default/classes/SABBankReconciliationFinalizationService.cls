/**
 * G5C - Bank Reconciliation Finalization.
 *
 * G5A imports/validates the statement.
 * G5B creates auditable matches between statement lines and posted Bank GL
 * journal lines.
 * G5C proves the reconciliation is complete and balanced, snapshots the book
 * and statement closing amounts, and finalizes both the reconciliation and
 * statement.
 *
 * Current G5C scope:
 * - Finalization is supported when Bank Account currency equals Company
 *   Functional Currency. This lets Book Closing use the authoritative
 *   Debit_Base__c/Credit_Base__c ledger without mixing currencies.
 * - FX-bank reconciliation can extend this later when a bank-currency ledger
 *   balance contract is added.
 */
public with sharing class SABBankReconciliationFinalizationService {

    public class BankReconciliationFinalizationException extends Exception {}

    private static final String FINALIZE_PERMISSION =
        'SAB_Finalize_Bank_Reconciliation';

    private static final String RECON_DRAFT =
        'Draft';

    private static final String RECON_IN_REVIEW =
        'In Review';

    private static final String RECON_FINALIZED =
        'Finalized';

    private static final String STATEMENT_VALIDATED =
        'Validated';

    private static final String STATEMENT_RECONCILED =
        'Reconciled';

    private static final String MATCH_PROPOSED =
        'Proposed';

    private static final String MATCH_CONFIRMED =
        'Confirmed';

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    public class FinalizationResult {
        @AuraEnabled public Id reconciliationId { get; private set; }
        @AuraEnabled public Id bankStatementId { get; private set; }
        @AuraEnabled public String reconciliationStatus { get; private set; }
        @AuraEnabled public String statementStatus { get; private set; }
        @AuraEnabled public Decimal bookClosingAmount { get; private set; }
        @AuraEnabled public Decimal statementClosingAmount { get; private set; }
        @AuraEnabled public Decimal difference { get; private set; }
        @AuraEnabled public Id approvedById { get; private set; }
        @AuraEnabled public Datetime approvedAt { get; private set; }
        @AuraEnabled public Integer statementLineCount { get; private set; }
        @AuraEnabled public Integer confirmedMatchCount { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }
    }

    @AuraEnabled
    public static FinalizationResult finalizeReconciliation(
        Id reconciliationId
    ) {
        assertPermission();

        if (reconciliationId == null) {
            throw new BankReconciliationFinalizationException(
                'Bank Reconciliation Id is required.'
            );
        }

        assertFinalizeAccess();

        Bank_Reconciliation__c reconciliation = [
            SELECT Id,
                   Company__c,
                   Company__r.Functional_Currency__c,
                   Bank_Account__c,
                   Bank_Statement__c,
                   Book_Closing_Amount__c,
                   Statement_Closing_Amount__c,
                   Difference__c,
                   Status__c,
                   Approved_At__c,
                   Approved_By__c
            FROM Bank_Reconciliation__c
            WHERE Id = :reconciliationId
            LIMIT 1
            FOR UPDATE
        ];

        SABCompanyAccessService.assertCompanyAccess(
            reconciliation.Company__c
        );

        SABAccessControlService.assertRecordEditAccess(
            reconciliation.Id
        );

        Bank_Statement__c statement = [
            SELECT Id,
                   Company__c,
                   Bank_Account__c,
                   Statement_Start_Date__c,
                   Statement_End_Date__c,
                   Opening_Amount__c,
                   Closing_Amount__c,
                   Currency__c,
                   Status__c
            FROM Bank_Statement__c
            WHERE Id = :reconciliation.Bank_Statement__c
            LIMIT 1
            FOR UPDATE
        ];

        SABAccessControlService.assertRecordEditAccess(
            statement.Id
        );

        Bank_Account__c bankAccount = [
            SELECT Id,
                   Company__c,
                   Currency__c,
                   GL_Account__c,
                   GL_Account__r.Company__c,
                   Is_Active__c
            FROM Bank_Account__c
            WHERE Id = :reconciliation.Bank_Account__c
            LIMIT 1
        ];

        validateIdentity(
            reconciliation,
            statement,
            bankAccount
        );

        if (
            reconciliation.Status__c == RECON_FINALIZED
        ) {
            if (
                statement.Status__c
                != STATEMENT_RECONCILED
            ) {
                throw new BankReconciliationFinalizationException(
                    'Finalized Bank Reconciliation is inconsistent because its Bank Statement is not Reconciled.'
                );
            }

            return buildResult(
                reconciliation,
                statement,
                countStatementLines(
                    statement.Id
                ),
                countConfirmedMatches(
                    reconciliation.Id
                ),
                true
            );
        }

        if (
            reconciliation.Status__c
            != RECON_IN_REVIEW
        ) {
            throw new BankReconciliationFinalizationException(
                'Bank Reconciliation must be In Review before finalization.'
            );
        }

        if (
            statement.Status__c
            != STATEMENT_VALIDATED
        ) {
            throw new BankReconciliationFinalizationException(
                'Bank Statement must be Validated before reconciliation finalization.'
            );
        }

        String companyFunctionalCurrency =
            SABMoneyService.normalizeCurrencyCode(
                reconciliation.Company__r
                    .Functional_Currency__c
            );

        String bankCurrency =
            SABMoneyService.normalizeCurrencyCode(
                bankAccount.Currency__c
            );

        String statementCurrency =
            SABMoneyService.normalizeCurrencyCode(
                statement.Currency__c
            );

        if (
            bankCurrency != statementCurrency
        ) {
            throw new BankReconciliationFinalizationException(
                'Bank Statement currency must match the Bank Account currency.'
            );
        }

        if (
            bankCurrency != companyFunctionalCurrency
        ) {
            throw new BankReconciliationFinalizationException(
                'G5C finalization currently requires Bank Account currency to match the Accounting Company Functional Currency.'
            );
        }

        List<Bank_Statement_Line__c> statementLines = [
            SELECT Id,
                   Line_Number__c,
                   Transaction_Date__c,
                   Amount__c
            FROM Bank_Statement_Line__c
            WHERE Bank_Statement__c = :statement.Id
            ORDER BY Line_Number__c ASC,
                     CreatedDate ASC
        ];

        if (statementLines.isEmpty()) {
            throw new BankReconciliationFinalizationException(
                'Bank Statement must contain at least one line before reconciliation finalization.'
            );
        }

        Set<Id> statementLineIds =
            new Set<Id>();

        Map<Id, Bank_Statement_Line__c> statementLineById =
            new Map<Id, Bank_Statement_Line__c>();

        for (Bank_Statement_Line__c line : statementLines) {
            statementLineIds.add(
                line.Id
            );
            statementLineById.put(
                line.Id,
                line
            );
        }

        List<Reconciliation_Match__c> activeMatches = [
            SELECT Id,
                   Bank_Statement_Line__c,
                   Journal_Entry_Line__c,
                   Matched_Amount__c,
                   Match_Type__c,
                   Status__c,
                   Journal_Entry_Line__r.GL_Account__c,
                   Journal_Entry_Line__r.Debit_Base__c,
                   Journal_Entry_Line__r.Credit_Base__c,
                   Journal_Entry_Line__r.Journal_Entry__r.Company__c,
                   Journal_Entry_Line__r.Journal_Entry__r.Status__c,
                   Journal_Entry_Line__r.Journal_Entry__r.Accounting_Date__c
            FROM Reconciliation_Match__c
            WHERE Bank_Reconciliation__c =
                    :reconciliation.Id
              AND Status__c IN (
                    'Proposed',
                    'Confirmed'
              )
            ORDER BY CreatedDate ASC
        ];

        Map<Id, Decimal> confirmedByStatementLine =
            new Map<Id, Decimal>();

        Set<Id> confirmedJournalLineIds =
            new Set<Id>();

        Integer confirmedMatchCount =
            0;

        for (Reconciliation_Match__c matchRow : activeMatches) {
            if (
                matchRow.Status__c == MATCH_PROPOSED
            ) {
                throw new BankReconciliationFinalizationException(
                    'All Proposed reconciliation matches must be confirmed or reversed before finalization.'
                );
            }

            if (
                matchRow.Status__c != MATCH_CONFIRMED
            ) {
                continue;
            }

            if (
                matchRow.Bank_Statement_Line__c == null
                || !statementLineIds.contains(
                    matchRow.Bank_Statement_Line__c
                )
            ) {
                throw new BankReconciliationFinalizationException(
                    'Confirmed reconciliation match contains a Bank Statement Line outside this reconciliation statement.'
                );
            }

            if (
                matchRow.Journal_Entry_Line__c == null
                || matchRow.Journal_Entry_Line__r == null
                || matchRow.Journal_Entry_Line__r
                    .Journal_Entry__r == null
            ) {
                throw new BankReconciliationFinalizationException(
                    'Confirmed reconciliation match requires a valid Journal Entry Line.'
                );
            }

            if (
                matchRow.Journal_Entry_Line__r
                    .Journal_Entry__r.Company__c
                != reconciliation.Company__c
            ) {
                throw new BankReconciliationFinalizationException(
                    'Cross-company reconciliation match is not allowed.'
                );
            }

            if (
                matchRow.Journal_Entry_Line__r
                    .Journal_Entry__r.Status__c
                != 'Posted'
            ) {
                throw new BankReconciliationFinalizationException(
                    'Every confirmed reconciliation match must reference a currently Posted Journal Entry.'
                );
            }

            if (
                matchRow.Journal_Entry_Line__r.GL_Account__c
                != bankAccount.GL_Account__c
            ) {
                throw new BankReconciliationFinalizationException(
                    'Every confirmed reconciliation match must reference the Bank Account GL Account.'
                );
            }

            if (
                matchRow.Journal_Entry_Line__r
                    .Journal_Entry__r.Accounting_Date__c
                > statement.Statement_End_Date__c
            ) {
                throw new BankReconciliationFinalizationException(
                    'Confirmed Bank GL match cannot be dated after the Bank Statement End Date.'
                );
            }

            Bank_Statement_Line__c statementLine =
                statementLineById.get(
                    matchRow.Bank_Statement_Line__c
                );

            if (
                !directionMatches(
                    statementLine.Amount__c,
                    matchRow.Journal_Entry_Line__r
                )
            ) {
                throw new BankReconciliationFinalizationException(
                    'Confirmed reconciliation match has an invalid Bank GL debit/credit direction.'
                );
            }

            Decimal matchedAmount =
                absoluteAmount(
                    matchRow.Matched_Amount__c
                );

            if (matchedAmount <= ZERO) {
                throw new BankReconciliationFinalizationException(
                    'Confirmed reconciliation match amount must be greater than zero.'
                );
            }

            Decimal current =
                confirmedByStatementLine.containsKey(
                    statementLine.Id
                )
                    ? confirmedByStatementLine.get(
                        statementLine.Id
                    )
                    : ZERO;

            current +=
                matchedAmount;

            if (
                current
                > absoluteAmount(
                    statementLine.Amount__c
                )
            ) {
                throw new BankReconciliationFinalizationException(
                    'Confirmed matches exceed a Bank Statement Line amount.'
                );
            }

            confirmedByStatementLine.put(
                statementLine.Id,
                current
            );

            confirmedJournalLineIds.add(
                matchRow.Journal_Entry_Line__c
            );

            confirmedMatchCount++;
        }

        for (Bank_Statement_Line__c line : statementLines) {
            Decimal expected =
                absoluteAmount(
                    line.Amount__c
                );

            Decimal confirmed =
                confirmedByStatementLine.containsKey(
                    line.Id
                )
                    ? confirmedByStatementLine.get(
                        line.Id
                    )
                    : ZERO;

            if (expected != confirmed) {
                throw new BankReconciliationFinalizationException(
                    'Every Bank Statement Line must be fully matched with Confirmed reconciliation matches before finalization.'
                );
            }
        }

        validateJournalLineCapacity(
            confirmedJournalLineIds
        );

        Decimal bookClosingAmount =
            calculateBookClosingAmount(
                reconciliation.Company__c,
                bankAccount.GL_Account__c,
                statement.Statement_End_Date__c
            );

        Decimal statementClosingAmount =
            normalizeAmount(
                statement.Closing_Amount__c
            );

        Decimal difference =
            normalizeAmount(
                statementClosingAmount
                - bookClosingAmount
            );

        if (difference != ZERO) {
            throw new BankReconciliationFinalizationException(
                'Bank Reconciliation cannot be finalized because Statement Closing Amount does not equal the Bank GL Book Closing Amount. Difference: '
                + String.valueOf(
                    difference
                )
            );
        }

        Datetime approvedAt =
            System.now();

        reconciliation.Book_Closing_Amount__c =
            bookClosingAmount;
        reconciliation.Statement_Closing_Amount__c =
            statementClosingAmount;
        reconciliation.Difference__c =
            difference;
        reconciliation.Status__c =
            RECON_FINALIZED;
        reconciliation.Approved_By__c =
            UserInfo.getUserId();
        reconciliation.Approved_At__c =
            approvedAt;

        update reconciliation;

        statement.Status__c =
            STATEMENT_RECONCILED;

        update statement;

        return buildResult(
            reconciliation,
            statement,
            statementLines.size(),
            confirmedMatchCount,
            false
        );
    }

    @AuraEnabled(cacheable=true)
    public static FinalizationResult getFinalizationSummary(
        Id reconciliationId
    ) {
        if (reconciliationId == null) {
            throw new BankReconciliationFinalizationException(
                'Bank Reconciliation Id is required.'
            );
        }

        assertSummaryReadAccess();

        Bank_Reconciliation__c reconciliation = [
            SELECT Id,
                   Company__c,
                   Bank_Statement__c,
                   Bank_Account__c,
                   Book_Closing_Amount__c,
                   Statement_Closing_Amount__c,
                   Difference__c,
                   Status__c,
                   Approved_At__c,
                   Approved_By__c
            FROM Bank_Reconciliation__c
            WHERE Id = :reconciliationId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(
            reconciliation.Company__c
        );

        SABAccessControlService.assertRecordReadAccess(
            reconciliation.Id
        );

        Bank_Statement__c statement = [
            SELECT Id,
                   Status__c,
                   Closing_Amount__c
            FROM Bank_Statement__c
            WHERE Id = :reconciliation.Bank_Statement__c
            LIMIT 1
        ];

        return buildResult(
            reconciliation,
            statement,
            countStatementLines(
                statement.Id
            ),
            countConfirmedMatches(
                reconciliation.Id
            ),
            false
        );
    }

    private static void validateIdentity(
        Bank_Reconciliation__c reconciliation,
        Bank_Statement__c statement,
        Bank_Account__c bankAccount
    ) {
        if (
            reconciliation.Company__r == null
            || String.isBlank(
                reconciliation.Company__r
                    .Functional_Currency__c
            )
        ) {
            throw new BankReconciliationFinalizationException(
                'Accounting Company Functional Currency is required.'
            );
        }

        if (
            reconciliation.Bank_Statement__c
                != statement.Id
            || reconciliation.Bank_Account__c
                != bankAccount.Id
        ) {
            throw new BankReconciliationFinalizationException(
                'Bank Reconciliation identity is inconsistent.'
            );
        }

        if (
            statement.Company__c
                != reconciliation.Company__c
            || statement.Bank_Account__c
                != reconciliation.Bank_Account__c
        ) {
            throw new BankReconciliationFinalizationException(
                'Bank Reconciliation, Bank Statement and Bank Account must use the same Accounting Company and Bank Account.'
            );
        }

        if (
            bankAccount.Company__c
                != reconciliation.Company__c
            || bankAccount.GL_Account__c == null
            || bankAccount.GL_Account__r == null
            || bankAccount.GL_Account__r.Company__c
                != reconciliation.Company__c
        ) {
            throw new BankReconciliationFinalizationException(
                'Bank Account and Bank GL Account must belong to the reconciliation Accounting Company.'
            );
        }

        if (bankAccount.Is_Active__c != true) {
            throw new BankReconciliationFinalizationException(
                'Bank Account must be active before reconciliation finalization.'
            );
        }

        if (
            statement.Statement_End_Date__c == null
        ) {
            throw new BankReconciliationFinalizationException(
                'Bank Statement End Date is required.'
            );
        }

        if (statement.Closing_Amount__c == null) {
            throw new BankReconciliationFinalizationException(
                'Bank Statement Closing Amount is required.'
            );
        }
    }

    private static Decimal calculateBookClosingAmount(
        Id companyId,
        Id bankGLAccountId,
        Date statementEndDate
    ) {
        AggregateResult aggregateRow = [
            SELECT SUM(Debit_Base__c) debitTotal,
                   SUM(Credit_Base__c) creditTotal
            FROM Journal_Entry_Line__c
            WHERE GL_Account__c =
                    :bankGLAccountId
              AND Journal_Entry__r.Company__c =
                    :companyId
              AND Journal_Entry__r.Status__c IN (
                    'Posted',
                    'Reversed'
              )
              AND Journal_Entry__r.Accounting_Date__c
                    <= :statementEndDate
        ];

        Decimal debitTotal =
            (Decimal) aggregateRow.get(
                'debitTotal'
            );

        Decimal creditTotal =
            (Decimal) aggregateRow.get(
                'creditTotal'
            );

        return normalizeAmount(
            (debitTotal == null
                ? ZERO
                : debitTotal)
            -
            (creditTotal == null
                ? ZERO
                : creditTotal)
        );
    }

    private static void validateJournalLineCapacity(
        Set<Id> journalLineIds
    ) {
        if (
            journalLineIds == null
            || journalLineIds.isEmpty()
        ) {
            return;
        }

        Map<Id, Journal_Entry_Line__c> journalLines =
            new Map<Id, Journal_Entry_Line__c>([
                SELECT Id,
                       Debit_Base__c,
                       Credit_Base__c
                FROM Journal_Entry_Line__c
                WHERE Id IN :journalLineIds
            ]);

        Map<Id, Decimal> confirmedByJournalLine =
            new Map<Id, Decimal>();

        for (Reconciliation_Match__c matchRow : [
            SELECT Journal_Entry_Line__c,
                   Matched_Amount__c
            FROM Reconciliation_Match__c
            WHERE Journal_Entry_Line__c IN :journalLineIds
              AND Status__c = 'Confirmed'
        ]) {
            Decimal current =
                confirmedByJournalLine.containsKey(
                    matchRow.Journal_Entry_Line__c
                )
                    ? confirmedByJournalLine.get(
                        matchRow.Journal_Entry_Line__c
                    )
                    : ZERO;

            current +=
                absoluteAmount(
                    matchRow.Matched_Amount__c
                );

            confirmedByJournalLine.put(
                matchRow.Journal_Entry_Line__c,
                current
            );
        }

        for (Id journalLineId : journalLineIds) {
            Journal_Entry_Line__c line =
                journalLines.get(
                    journalLineId
                );

            Decimal capacity =
                line.Debit_Base__c != null
                && line.Debit_Base__c > ZERO
                    ? line.Debit_Base__c
                    : (
                        line.Credit_Base__c == null
                            ? ZERO
                            : line.Credit_Base__c
                    );

            Decimal confirmed =
                confirmedByJournalLine.containsKey(
                    journalLineId
                )
                    ? confirmedByJournalLine.get(
                        journalLineId
                    )
                    : ZERO;

            if (confirmed > capacity) {
                throw new BankReconciliationFinalizationException(
                    'Confirmed reconciliation matches exceed a Bank GL Journal Entry Line amount.'
                );
            }
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

    private static Integer countStatementLines(
        Id bankStatementId
    ) {
        return [
            SELECT COUNT()
            FROM Bank_Statement_Line__c
            WHERE Bank_Statement__c =
                :bankStatementId
        ];
    }

    private static Integer countConfirmedMatches(
        Id reconciliationId
    ) {
        return [
            SELECT COUNT()
            FROM Reconciliation_Match__c
            WHERE Bank_Reconciliation__c =
                    :reconciliationId
              AND Status__c =
                    'Confirmed'
        ];
    }

    private static FinalizationResult buildResult(
        Bank_Reconciliation__c reconciliation,
        Bank_Statement__c statement,
        Integer statementLineCount,
        Integer confirmedMatchCount,
        Boolean replay
    ) {
        FinalizationResult result =
            new FinalizationResult();

        result.reconciliationId =
            reconciliation.Id;
        result.bankStatementId =
            statement.Id;
        result.reconciliationStatus =
            reconciliation.Status__c;
        result.statementStatus =
            statement.Status__c;
        result.bookClosingAmount =
            reconciliation.Book_Closing_Amount__c;
        result.statementClosingAmount =
            reconciliation.Statement_Closing_Amount__c == null
                ? statement.Closing_Amount__c
                : reconciliation.Statement_Closing_Amount__c;
        result.difference =
            reconciliation.Difference__c;
        result.approvedById =
            reconciliation.Approved_By__c;
        result.approvedAt =
            reconciliation.Approved_At__c;
        result.statementLineCount =
            statementLineCount;
        result.confirmedMatchCount =
            confirmedMatchCount;
        result.replay =
            replay;

        return result;
    }

    private static Decimal normalizeAmount(
        Decimal value
    ) {
        return (
            value == null
                ? ZERO
                : value
        ).setScale(
            4,
            RoundingMode.HALF_UP
        );
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

    private static void assertPermission() {
        SABPermissionService.assertPermission(
            FINALIZE_PERMISSION,
            'You do not have permission to finalize Bank Reconciliations.'
        );
    }

    private static void assertFinalizeAccess() {
        SABAccessControlService.assertReadable(
            Bank_Reconciliation__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Reconciliation__c.Book_Closing_Amount__c,
                Bank_Reconciliation__c.Statement_Closing_Amount__c,
                Bank_Reconciliation__c.Difference__c,
                Bank_Reconciliation__c.Status__c,
                Bank_Reconciliation__c.Approved_At__c,
                Bank_Reconciliation__c.Approved_By__c
            }
        );

        SABAccessControlService.assertUpdateable(
            Bank_Reconciliation__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Reconciliation__c.Book_Closing_Amount__c,
                Bank_Reconciliation__c.Statement_Closing_Amount__c,
                Bank_Reconciliation__c.Difference__c,
                Bank_Reconciliation__c.Status__c,
                Bank_Reconciliation__c.Approved_At__c,
                Bank_Reconciliation__c.Approved_By__c
            }
        );

        SABAccessControlService.assertUpdateable(
            Bank_Statement__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Statement__c.Status__c
            }
        );

        SABAccessControlService.assertReadable(
            Reconciliation_Match__c.SObjectType,
            new List<Schema.SObjectField>{
                Reconciliation_Match__c.Match_Type__c,
                Reconciliation_Match__c.Status__c
            }
        );

        SABAccessControlService.assertReadable(
            Journal_Entry_Line__c.SObjectType,
            new List<Schema.SObjectField>{
                Journal_Entry_Line__c.Debit_Base__c,
                Journal_Entry_Line__c.Credit_Base__c
            }
        );
    }

    private static void assertSummaryReadAccess() {
        SABAccessControlService.assertReadable(
            Bank_Reconciliation__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Reconciliation__c.Book_Closing_Amount__c,
                Bank_Reconciliation__c.Statement_Closing_Amount__c,
                Bank_Reconciliation__c.Difference__c,
                Bank_Reconciliation__c.Status__c,
                Bank_Reconciliation__c.Approved_At__c,
                Bank_Reconciliation__c.Approved_By__c
            }
        );

        SABAccessControlService.assertReadable(
            Bank_Statement__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Statement__c.Status__c
            }
        );
    }
}
