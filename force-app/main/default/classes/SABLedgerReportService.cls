/**
 * G2 - Ledger Reporting Foundation.
 *
 * G2A: Trial Balance.
 * G2B: General Ledger.
 *
 * Accounting contract:
 * - Financial totals come only from Journal Entry Lines whose parent Journal
 *   is part of the posted ledger.
 * - The original journal of a reversal is retained with Status = Reversed,
 *   while the opposite reversal journal is Posted. BOTH therefore remain
 *   ledger history and must be included in reporting.
 * - Draft journals never contribute to reports.
 * - Opening = all ledger activity before the selected From Date.
 * - Movement = ledger activity from From Date through To Date, inclusive.
 * - Closing = Opening + Movement.
 *
 * This service intentionally does not read an editable "current balance"
 * field from GL Account.
 */
public with sharing class SABLedgerReportService {

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    private static final Decimal EPSILON =
        Decimal.valueOf('0.00005');

    public class TrialBalanceRequest {
        public Id companyId;
        public Date fromDate;
        public Date toDate;
        public Boolean includeZeroBalance;
    }

    public class TrialBalanceRow {
        public Id glAccountId;
        public String accountCode;
        public String accountName;
        public String accountType;
        public String normalBalance;
        public Boolean active;

        public Decimal openingDebit;
        public Decimal openingCredit;
        public Decimal movementDebit;
        public Decimal movementCredit;
        public Decimal closingDebit;
        public Decimal closingCredit;

        public Decimal openingNet;
        public Decimal movementNet;
        public Decimal closingNet;
    }

    public class TrialBalanceResult {
        public Id companyId;
        public String companyName;
        public String functionalCurrency;
        public Date fromDate;
        public Date toDate;
        public Datetime generatedAt;

        public List<TrialBalanceRow> rows;

        public Decimal totalOpeningDebit;
        public Decimal totalOpeningCredit;
        public Decimal totalMovementDebit;
        public Decimal totalMovementCredit;
        public Decimal totalClosingDebit;
        public Decimal totalClosingCredit;

        public Decimal openingDifference;
        public Decimal movementDifference;
        public Decimal closingDifference;

        public Boolean balanced;
    }

    public class LedgerLine {
        public Id journalLineId;
        public Id journalId;
        public String journalName;
        public Date accountingDate;
        public String entryType;
        public String journalStatus;
        public Decimal lineNumber;
        public Decimal debit;
        public Decimal credit;
        public String explanation;
        public String postingKey;
    }


    public class GeneralLedgerRequest {
        public Id companyId;
        public Date fromDate;
        public Date toDate;
        public Id glAccountId;
    }

    public class GeneralLedgerLine {
        public Id journalLineId;
        public Id journalId;
        public String journalName;
        public Date accountingDate;
        public String entryType;
        public String journalStatus;
        public String postingKey;
        public Decimal lineNumber;
        public String explanation;

        public Decimal debit;
        public Decimal credit;

        public Decimal runningNet;
        public Decimal runningDebit;
        public Decimal runningCredit;
    }

    public class GeneralLedgerAccount {
        public Id glAccountId;
        public String accountCode;
        public String accountName;
        public String accountType;
        public String normalBalance;
        public Boolean active;

        public Decimal openingDebit;
        public Decimal openingCredit;
        public Decimal movementDebit;
        public Decimal movementCredit;
        public Decimal closingDebit;
        public Decimal closingCredit;

        public Decimal openingNet;
        public Decimal movementNet;
        public Decimal closingNet;

        public Integer movementLineCount;
        public Integer displayedLineCount;

        public List<GeneralLedgerLine> lines;
    }

    public class GeneralLedgerResult {
        public Id companyId;
        public String companyName;
        public String functionalCurrency;
        public Date fromDate;
        public Date toDate;
        public Id glAccountId;
        public Datetime generatedAt;

        public Boolean fullLedgerScope;
        public Boolean balanced;
        public Boolean truncated;

        public Integer accountCount;
        public Integer totalMovementLineCount;
        public Integer displayedLineCount;

        public Decimal totalOpeningDebit;
        public Decimal totalOpeningCredit;
        public Decimal totalMovementDebit;
        public Decimal totalMovementCredit;
        public Decimal totalClosingDebit;
        public Decimal totalClosingCredit;

        public Decimal openingDifference;
        public Decimal movementDifference;
        public Decimal closingDifference;

        public List<GeneralLedgerAccount> accounts;
    }

    public static TrialBalanceResult getTrialBalance(
        TrialBalanceRequest request
    ) {
        validateRequest(request);

        SABCompanyAccessService.assertCompanyAccess(
            request.companyId
        );

        assertLedgerReadAccess();

        Accounting_Company__c company = [
            SELECT Id,
                   Name__c,
                   Functional_Currency__c
            FROM Accounting_Company__c
            WHERE Id = :request.companyId
            LIMIT 1
        ];

        Map<Id, BalanceBucket> openingByAccount =
            aggregateBeforeDate(
                request.companyId,
                request.fromDate
            );

        Map<Id, BalanceBucket> movementByAccount =
            aggregateDateRange(
                request.companyId,
                request.fromDate,
                request.toDate
            );

        Boolean includeZero =
            request.includeZeroBalance == true;

        TrialBalanceResult result =
            new TrialBalanceResult();

        result.companyId =
            company.Id;
        result.companyName =
            company.Name__c;
        result.functionalCurrency =
            company.Functional_Currency__c;
        result.fromDate =
            request.fromDate;
        result.toDate =
            request.toDate;
        result.generatedAt =
            System.now();
        result.rows =
            new List<TrialBalanceRow>();

        result.totalOpeningDebit = ZERO;
        result.totalOpeningCredit = ZERO;
        result.totalMovementDebit = ZERO;
        result.totalMovementCredit = ZERO;
        result.totalClosingDebit = ZERO;
        result.totalClosingCredit = ZERO;

        for (GL_Account__c account : [
            SELECT Id,
                   Account_Code__c,
                   Name,
                   Account_Type__c,
                   Normal_Balance__c,
                   Is_Active__c
            FROM GL_Account__c
            WHERE Company__c = :request.companyId
            ORDER BY Account_Code__c ASC,
                     Name ASC
        ]) {
            BalanceBucket opening =
                openingByAccount.containsKey(
                    account.Id
                )
                    ? openingByAccount.get(
                        account.Id
                    )
                    : new BalanceBucket();

            BalanceBucket movement =
                movementByAccount.containsKey(
                    account.Id
                )
                    ? movementByAccount.get(
                        account.Id
                    )
                    : new BalanceBucket();

            Decimal openingNet =
                opening.debit
                - opening.credit;

            Decimal movementNet =
                movement.debit
                - movement.credit;

            Decimal closingNet =
                openingNet
                + movementNet;

            if (
                !includeZero
                && isEffectivelyZero(
                    openingNet
                )
                && isEffectivelyZero(
                    movement.debit
                )
                && isEffectivelyZero(
                    movement.credit
                )
                && isEffectivelyZero(
                    closingNet
                )
            ) {
                continue;
            }

            TrialBalanceRow row =
                new TrialBalanceRow();

            row.glAccountId =
                account.Id;
            row.accountCode =
                account.Account_Code__c;
            row.accountName =
                account.Name;
            row.accountType =
                account.Account_Type__c;
            row.normalBalance =
                account.Normal_Balance__c;
            row.active =
                account.Is_Active__c;

            row.openingNet =
                openingNet;
            row.movementNet =
                movementNet;
            row.closingNet =
                closingNet;

            row.openingDebit =
                debitSide(
                    openingNet
                );
            row.openingCredit =
                creditSide(
                    openingNet
                );

            row.movementDebit =
                nullToZero(
                    movement.debit
                );
            row.movementCredit =
                nullToZero(
                    movement.credit
                );

            row.closingDebit =
                debitSide(
                    closingNet
                );
            row.closingCredit =
                creditSide(
                    closingNet
                );

            result.rows.add(
                row
            );

            result.totalOpeningDebit +=
                row.openingDebit;
            result.totalOpeningCredit +=
                row.openingCredit;
            result.totalMovementDebit +=
                row.movementDebit;
            result.totalMovementCredit +=
                row.movementCredit;
            result.totalClosingDebit +=
                row.closingDebit;
            result.totalClosingCredit +=
                row.closingCredit;
        }

        result.openingDifference =
            result.totalOpeningDebit
            - result.totalOpeningCredit;

        result.movementDifference =
            result.totalMovementDebit
            - result.totalMovementCredit;

        result.closingDifference =
            result.totalClosingDebit
            - result.totalClosingCredit;

        result.balanced =
            isEffectivelyZero(
                result.openingDifference
            )
            && isEffectivelyZero(
                result.movementDifference
            )
            && isEffectivelyZero(
                result.closingDifference
            );

        return result;
    }

    public static List<LedgerLine> getAccountMovementLines(
        Id companyId,
        Id glAccountId,
        Date fromDate,
        Date toDate
    ) {
        if (
            companyId == null
            || glAccountId == null
            || fromDate == null
            || toDate == null
        ) {
            throw new ReportException(
                'Company, GL Account, From Date and To Date are required.'
            );
        }

        if (fromDate > toDate) {
            throw new ReportException(
                'From Date cannot be after To Date.'
            );
        }

        SABCompanyAccessService.assertCompanyAccess(
            companyId
        );

        assertLedgerReadAccess();

        GL_Account__c account = [
            SELECT Id,
                   Company__c
            FROM GL_Account__c
            WHERE Id = :glAccountId
            LIMIT 1
        ];

        if (account.Company__c != companyId) {
            throw new ReportException(
                'The selected GL Account does not belong to the selected Accounting Company.'
            );
        }

        List<LedgerLine> result =
            new List<LedgerLine>();

        for (Journal_Entry_Line__c line : [
            SELECT Id,
                   Journal_Entry__c,
                   Journal_Entry__r.Name,
                   Journal_Entry__r.Accounting_Date__c,
                   Journal_Entry__r.Entry_Type__c,
                   Journal_Entry__r.Status__c,
                   Journal_Entry__r.Posting_Key__c,
                   Line_Number__c,
                   Debit_Base__c,
                   Credit_Base__c,
                   Explanation__c
            FROM Journal_Entry_Line__c
            WHERE GL_Account__c = :glAccountId
              AND Journal_Entry__r.Company__c = :companyId
              AND Journal_Entry__r.Status__c IN (
                  'Posted',
                  'Reversed'
              )
              AND Journal_Entry__r.Accounting_Date__c >= :fromDate
              AND Journal_Entry__r.Accounting_Date__c <= :toDate
            ORDER BY Journal_Entry__r.Accounting_Date__c ASC,
                     Journal_Entry__r.Name ASC,
                     Line_Number__c ASC
            LIMIT 2000
        ]) {
            LedgerLine dto =
                new LedgerLine();

            dto.journalLineId =
                line.Id;
            dto.journalId =
                line.Journal_Entry__c;
            dto.journalName =
                line.Journal_Entry__r.Name;
            dto.accountingDate =
                line.Journal_Entry__r.Accounting_Date__c;
            dto.entryType =
                line.Journal_Entry__r.Entry_Type__c;
            dto.journalStatus =
                line.Journal_Entry__r.Status__c;
            dto.lineNumber =
                line.Line_Number__c;
            dto.debit =
                nullToZero(
                    line.Debit_Base__c
                );
            dto.credit =
                nullToZero(
                    line.Credit_Base__c
                );
            dto.explanation =
                line.Explanation__c;
            dto.postingKey =
                line.Journal_Entry__r.Posting_Key__c;

            result.add(
                dto
            );
        }

        return result;
    }


    /**
     * Returns the General Ledger for one company and date range.
     *
     * If glAccountId is null, all accounts with an opening balance or movement
     * are returned. If an account is selected, that account is returned even
     * when it has no activity.
     *
     * The first 2,000 movement lines are returned for interactive review.
     * Opening/movement/closing totals are still calculated from aggregate
     * queries across the COMPLETE requested scope, so truncating line detail
     * never changes the financial totals.
     */
    public static GeneralLedgerResult getGeneralLedger(
        GeneralLedgerRequest request
    ) {
        validateGeneralLedgerRequest(
            request
        );

        SABCompanyAccessService.assertCompanyAccess(
            request.companyId
        );

        assertLedgerReadAccess();

        Accounting_Company__c company = [
            SELECT Id,
                   Name__c,
                   Functional_Currency__c
            FROM Accounting_Company__c
            WHERE Id = :request.companyId
            LIMIT 1
        ];

        if (request.glAccountId != null) {
            Integer selectedAccountCount = [
                SELECT COUNT()
                FROM GL_Account__c
                WHERE Id = :request.glAccountId
                  AND Company__c = :request.companyId
            ];

            if (selectedAccountCount != 1) {
                throw new ReportException(
                    'The selected GL Account does not belong to the selected Accounting Company.'
                );
            }
        }

        Map<Id, BalanceBucket> openingByAccount =
            aggregateGeneralLedgerBeforeDate(
                request.companyId,
                request.glAccountId,
                request.fromDate
            );

        Map<Id, LedgerAggregateBucket> movementByAccount =
            aggregateGeneralLedgerDateRange(
                request.companyId,
                request.glAccountId,
                request.fromDate,
                request.toDate
            );

        List<Journal_Entry_Line__c> detailRows =
            queryGeneralLedgerDetail(
                request.companyId,
                request.glAccountId,
                request.fromDate,
                request.toDate
            );

        Boolean truncated =
            detailRows.size() > 2000;

        if (truncated) {
            detailRows.remove(
                detailRows.size() - 1
            );
        }

        Set<Id> accountIds =
            new Set<Id>();

        accountIds.addAll(
            openingByAccount.keySet()
        );

        accountIds.addAll(
            movementByAccount.keySet()
        );

        if (request.glAccountId != null) {
            accountIds.add(
                request.glAccountId
            );
        }

        Map<Id, List<GeneralLedgerLine>> linesByAccount =
            new Map<Id, List<GeneralLedgerLine>>();

        for (Journal_Entry_Line__c line : detailRows) {
            accountIds.add(
                line.GL_Account__c
            );

            if (
                !linesByAccount.containsKey(
                    line.GL_Account__c
                )
            ) {
                linesByAccount.put(
                    line.GL_Account__c,
                    new List<GeneralLedgerLine>()
                );
            }

            GeneralLedgerLine dto =
                new GeneralLedgerLine();

            dto.journalLineId =
                line.Id;
            dto.journalId =
                line.Journal_Entry__c;
            dto.journalName =
                line.Journal_Entry__r.Name;
            dto.accountingDate =
                line.Journal_Entry__r.Accounting_Date__c;
            dto.entryType =
                line.Journal_Entry__r.Entry_Type__c;
            dto.journalStatus =
                line.Journal_Entry__r.Status__c;
            dto.postingKey =
                line.Journal_Entry__r.Posting_Key__c;
            dto.lineNumber =
                line.Line_Number__c;
            dto.explanation =
                line.Explanation__c;
            dto.debit =
                nullToZero(
                    line.Debit_Base__c
                );
            dto.credit =
                nullToZero(
                    line.Credit_Base__c
                );

            linesByAccount
                .get(
                    line.GL_Account__c
                )
                .add(
                    dto
                );
        }

        GeneralLedgerResult result =
            new GeneralLedgerResult();

        result.companyId =
            company.Id;
        result.companyName =
            company.Name__c;
        result.functionalCurrency =
            company.Functional_Currency__c;
        result.fromDate =
            request.fromDate;
        result.toDate =
            request.toDate;
        result.glAccountId =
            request.glAccountId;
        result.generatedAt =
            System.now();

        result.fullLedgerScope =
            request.glAccountId == null;
        result.truncated =
            truncated;

        result.accounts =
            new List<GeneralLedgerAccount>();

        result.totalOpeningDebit =
            ZERO;
        result.totalOpeningCredit =
            ZERO;
        result.totalMovementDebit =
            ZERO;
        result.totalMovementCredit =
            ZERO;
        result.totalClosingDebit =
            ZERO;
        result.totalClosingCredit =
            ZERO;

        result.totalMovementLineCount =
            0;
        result.displayedLineCount =
            detailRows.size();

        if (!accountIds.isEmpty()) {
            for (GL_Account__c account : [
                SELECT Id,
                       Account_Code__c,
                       Name,
                       Account_Type__c,
                       Normal_Balance__c,
                       Is_Active__c
                FROM GL_Account__c
                WHERE Company__c = :request.companyId
                  AND Id IN :accountIds
                ORDER BY Account_Code__c ASC,
                         Name ASC
            ]) {
                BalanceBucket opening =
                    openingByAccount.containsKey(
                        account.Id
                    )
                        ? openingByAccount.get(
                            account.Id
                        )
                        : new BalanceBucket();

                LedgerAggregateBucket movement =
                    movementByAccount.containsKey(
                        account.Id
                    )
                        ? movementByAccount.get(
                            account.Id
                        )
                        : new LedgerAggregateBucket();

                Decimal openingNet =
                    opening.debit
                    - opening.credit;

                Decimal movementNet =
                    movement.debit
                    - movement.credit;

                Decimal closingNet =
                    openingNet
                    + movementNet;

                GeneralLedgerAccount accountGroup =
                    new GeneralLedgerAccount();

                accountGroup.glAccountId =
                    account.Id;
                accountGroup.accountCode =
                    account.Account_Code__c;
                accountGroup.accountName =
                    account.Name;
                accountGroup.accountType =
                    account.Account_Type__c;
                accountGroup.normalBalance =
                    account.Normal_Balance__c;
                accountGroup.active =
                    account.Is_Active__c;

                accountGroup.openingNet =
                    openingNet;
                accountGroup.movementNet =
                    movementNet;
                accountGroup.closingNet =
                    closingNet;

                accountGroup.openingDebit =
                    debitSide(
                        openingNet
                    );
                accountGroup.openingCredit =
                    creditSide(
                        openingNet
                    );

                accountGroup.movementDebit =
                    movement.debit;
                accountGroup.movementCredit =
                    movement.credit;

                accountGroup.closingDebit =
                    debitSide(
                        closingNet
                    );
                accountGroup.closingCredit =
                    creditSide(
                        closingNet
                    );

                accountGroup.movementLineCount =
                    movement.lineCount;

                accountGroup.lines =
                    linesByAccount.containsKey(
                        account.Id
                    )
                        ? linesByAccount.get(
                            account.Id
                        )
                        : new List<GeneralLedgerLine>();

                accountGroup.displayedLineCount =
                    accountGroup.lines.size();

                Decimal runningNet =
                    openingNet;

                for (
                    GeneralLedgerLine ledgerLine
                    : accountGroup.lines
                ) {
                    runningNet +=
                        ledgerLine.debit
                        - ledgerLine.credit;

                    ledgerLine.runningNet =
                        runningNet;
                    ledgerLine.runningDebit =
                        debitSide(
                            runningNet
                        );
                    ledgerLine.runningCredit =
                        creditSide(
                            runningNet
                        );
                }

                result.accounts.add(
                    accountGroup
                );

                result.totalOpeningDebit +=
                    accountGroup.openingDebit;
                result.totalOpeningCredit +=
                    accountGroup.openingCredit;
                result.totalMovementDebit +=
                    accountGroup.movementDebit;
                result.totalMovementCredit +=
                    accountGroup.movementCredit;
                result.totalClosingDebit +=
                    accountGroup.closingDebit;
                result.totalClosingCredit +=
                    accountGroup.closingCredit;

                result.totalMovementLineCount +=
                    accountGroup.movementLineCount;
            }
        }

        result.accountCount =
            result.accounts.size();

        result.openingDifference =
            result.totalOpeningDebit
            - result.totalOpeningCredit;

        result.movementDifference =
            result.totalMovementDebit
            - result.totalMovementCredit;

        result.closingDifference =
            result.totalClosingDebit
            - result.totalClosingCredit;

        result.balanced =
            result.fullLedgerScope
                ? (
                    isEffectivelyZero(
                        result.openingDifference
                    )
                    && isEffectivelyZero(
                        result.movementDifference
                    )
                    && isEffectivelyZero(
                        result.closingDifference
                    )
                )
                : null;

        return result;
    }

    private static Map<Id, BalanceBucket> aggregateGeneralLedgerBeforeDate(
        Id companyId,
        Id glAccountId,
        Date fromDate
    ) {
        Map<Id, BalanceBucket> result =
            new Map<Id, BalanceBucket>();

        List<AggregateResult> rows;

        if (glAccountId == null) {
            rows = [
                SELECT GL_Account__c accountId,
                       SUM(Debit_Base__c) debitTotal,
                       SUM(Credit_Base__c) creditTotal
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__r.Company__c = :companyId
                  AND Journal_Entry__r.Status__c IN (
                      'Posted',
                      'Reversed'
                  )
                  AND Journal_Entry__r.Accounting_Date__c < :fromDate
                GROUP BY GL_Account__c
            ];
        } else {
            rows = [
                SELECT GL_Account__c accountId,
                       SUM(Debit_Base__c) debitTotal,
                       SUM(Credit_Base__c) creditTotal
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__r.Company__c = :companyId
                  AND GL_Account__c = :glAccountId
                  AND Journal_Entry__r.Status__c IN (
                      'Posted',
                      'Reversed'
                  )
                  AND Journal_Entry__r.Accounting_Date__c < :fromDate
                GROUP BY GL_Account__c
            ];
        }

        for (AggregateResult aggregateRow : rows) {
            result.put(
                (Id) aggregateRow.get(
                    'accountId'
                ),
                new BalanceBucket(
                    (Decimal) aggregateRow.get(
                        'debitTotal'
                    ),
                    (Decimal) aggregateRow.get(
                        'creditTotal'
                    )
                )
            );
        }

        return result;
    }

    private static Map<Id, LedgerAggregateBucket> aggregateGeneralLedgerDateRange(
        Id companyId,
        Id glAccountId,
        Date fromDate,
        Date toDate
    ) {
        Map<Id, LedgerAggregateBucket> result =
            new Map<Id, LedgerAggregateBucket>();

        List<AggregateResult> rows;

        if (glAccountId == null) {
            rows = [
                SELECT GL_Account__c accountId,
                       SUM(Debit_Base__c) debitTotal,
                       SUM(Credit_Base__c) creditTotal,
                       COUNT(Id) lineCount
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__r.Company__c = :companyId
                  AND Journal_Entry__r.Status__c IN (
                      'Posted',
                      'Reversed'
                  )
                  AND Journal_Entry__r.Accounting_Date__c >= :fromDate
                  AND Journal_Entry__r.Accounting_Date__c <= :toDate
                GROUP BY GL_Account__c
            ];
        } else {
            rows = [
                SELECT GL_Account__c accountId,
                       SUM(Debit_Base__c) debitTotal,
                       SUM(Credit_Base__c) creditTotal,
                       COUNT(Id) lineCount
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__r.Company__c = :companyId
                  AND GL_Account__c = :glAccountId
                  AND Journal_Entry__r.Status__c IN (
                      'Posted',
                      'Reversed'
                  )
                  AND Journal_Entry__r.Accounting_Date__c >= :fromDate
                  AND Journal_Entry__r.Accounting_Date__c <= :toDate
                GROUP BY GL_Account__c
            ];
        }

        for (AggregateResult aggregateRow : rows) {
            result.put(
                (Id) aggregateRow.get(
                    'accountId'
                ),
                new LedgerAggregateBucket(
                    (Decimal) aggregateRow.get(
                        'debitTotal'
                    ),
                    (Decimal) aggregateRow.get(
                        'creditTotal'
                    ),
                    Integer.valueOf(
                        String.valueOf(
                            aggregateRow.get(
                                'lineCount'
                            )
                        )
                    )
                )
            );
        }

        return result;
    }

    private static List<Journal_Entry_Line__c> queryGeneralLedgerDetail(
        Id companyId,
        Id glAccountId,
        Date fromDate,
        Date toDate
    ) {
        if (glAccountId == null) {
            return [
                SELECT Id,
                       Journal_Entry__c,
                       Journal_Entry__r.Name,
                       Journal_Entry__r.Accounting_Date__c,
                       Journal_Entry__r.Entry_Type__c,
                       Journal_Entry__r.Status__c,
                       Journal_Entry__r.Posting_Key__c,
                       GL_Account__c,
                       GL_Account__r.Account_Code__c,
                       GL_Account__r.Name,
                       Line_Number__c,
                       Debit_Base__c,
                       Credit_Base__c,
                       Explanation__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__r.Company__c = :companyId
                  AND Journal_Entry__r.Status__c IN (
                      'Posted',
                      'Reversed'
                  )
                  AND Journal_Entry__r.Accounting_Date__c >= :fromDate
                  AND Journal_Entry__r.Accounting_Date__c <= :toDate
                ORDER BY GL_Account__r.Account_Code__c ASC,
                         GL_Account__r.Name ASC,
                         Journal_Entry__r.Accounting_Date__c ASC,
                         Journal_Entry__r.Name ASC,
                         Line_Number__c ASC
                LIMIT 2001
            ];
        }

        return [
            SELECT Id,
                   Journal_Entry__c,
                   Journal_Entry__r.Name,
                   Journal_Entry__r.Accounting_Date__c,
                   Journal_Entry__r.Entry_Type__c,
                   Journal_Entry__r.Status__c,
                   Journal_Entry__r.Posting_Key__c,
                   GL_Account__c,
                   GL_Account__r.Account_Code__c,
                   GL_Account__r.Name,
                   Line_Number__c,
                   Debit_Base__c,
                   Credit_Base__c,
                   Explanation__c
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__r.Company__c = :companyId
              AND GL_Account__c = :glAccountId
              AND Journal_Entry__r.Status__c IN (
                  'Posted',
                  'Reversed'
              )
              AND Journal_Entry__r.Accounting_Date__c >= :fromDate
              AND Journal_Entry__r.Accounting_Date__c <= :toDate
            ORDER BY Journal_Entry__r.Accounting_Date__c ASC,
                     Journal_Entry__r.Name ASC,
                     Line_Number__c ASC
            LIMIT 2001
        ];
    }

    private static void validateGeneralLedgerRequest(
        GeneralLedgerRequest request
    ) {
        if (request == null) {
            throw new ReportException(
                'General Ledger request is required.'
            );
        }

        if (request.companyId == null) {
            throw new ReportException(
                'Accounting Company is required.'
            );
        }

        if (
            request.fromDate == null
            || request.toDate == null
        ) {
            throw new ReportException(
                'From Date and To Date are required.'
            );
        }

        if (request.fromDate > request.toDate) {
            throw new ReportException(
                'From Date cannot be after To Date.'
            );
        }
    }

    private static Map<Id, BalanceBucket> aggregateBeforeDate(
        Id companyId,
        Date fromDate
    ) {
        Map<Id, BalanceBucket> result =
            new Map<Id, BalanceBucket>();

        for (AggregateResult aggregateRow : [
            SELECT GL_Account__c accountId,
                   SUM(Debit_Base__c) debitTotal,
                   SUM(Credit_Base__c) creditTotal
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__r.Company__c = :companyId
              AND Journal_Entry__r.Status__c IN (
                  'Posted',
                  'Reversed'
              )
              AND Journal_Entry__r.Accounting_Date__c < :fromDate
            GROUP BY GL_Account__c
        ]) {
            result.put(
                (Id) aggregateRow.get(
                    'accountId'
                ),
                new BalanceBucket(
                    (Decimal) aggregateRow.get(
                        'debitTotal'
                    ),
                    (Decimal) aggregateRow.get(
                        'creditTotal'
                    )
                )
            );
        }

        return result;
    }

    private static Map<Id, BalanceBucket> aggregateDateRange(
        Id companyId,
        Date fromDate,
        Date toDate
    ) {
        Map<Id, BalanceBucket> result =
            new Map<Id, BalanceBucket>();

        for (AggregateResult aggregateRow : [
            SELECT GL_Account__c accountId,
                   SUM(Debit_Base__c) debitTotal,
                   SUM(Credit_Base__c) creditTotal
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__r.Company__c = :companyId
              AND Journal_Entry__r.Status__c IN (
                  'Posted',
                  'Reversed'
              )
              AND Journal_Entry__r.Accounting_Date__c >= :fromDate
              AND Journal_Entry__r.Accounting_Date__c <= :toDate
            GROUP BY GL_Account__c
        ]) {
            result.put(
                (Id) aggregateRow.get(
                    'accountId'
                ),
                new BalanceBucket(
                    (Decimal) aggregateRow.get(
                        'debitTotal'
                    ),
                    (Decimal) aggregateRow.get(
                        'creditTotal'
                    )
                )
            );
        }

        return result;
    }

    private static void validateRequest(
        TrialBalanceRequest request
    ) {
        if (request == null) {
            throw new ReportException(
                'Trial Balance request is required.'
            );
        }

        if (request.companyId == null) {
            throw new ReportException(
                'Accounting Company is required.'
            );
        }

        if (
            request.fromDate == null
            || request.toDate == null
        ) {
            throw new ReportException(
                'From Date and To Date are required.'
            );
        }

        if (request.fromDate > request.toDate) {
            throw new ReportException(
                'From Date cannot be after To Date.'
            );
        }
    }

    private static void assertLedgerReadAccess() {
        SABAccessControlService.assertReadable(
            Accounting_Company__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Company__c.Name__c,
                Accounting_Company__c.Functional_Currency__c
            }
        );

        SABAccessControlService.assertReadable(
            GL_Account__c.SObjectType,
            new List<Schema.SObjectField>{
                GL_Account__c.Company__c,
                GL_Account__c.Account_Code__c,
                GL_Account__c.Account_Type__c,
                GL_Account__c.Normal_Balance__c,
                GL_Account__c.Is_Active__c
            }
        );

        SABAccessControlService.assertReadable(
            Journal_Entry__c.SObjectType,
            new List<Schema.SObjectField>{
                Journal_Entry__c.Company__c,
                Journal_Entry__c.Accounting_Date__c,
                Journal_Entry__c.Entry_Type__c,
                Journal_Entry__c.Status__c,
                Journal_Entry__c.Posting_Key__c
            }
        );

        SABAccessControlService.assertReadable(
            Journal_Entry_Line__c.SObjectType,
            new List<Schema.SObjectField>{
                Journal_Entry_Line__c.Journal_Entry__c,
                Journal_Entry_Line__c.GL_Account__c,
                Journal_Entry_Line__c.Line_Number__c,
                Journal_Entry_Line__c.Debit_Base__c,
                Journal_Entry_Line__c.Credit_Base__c,
                Journal_Entry_Line__c.Explanation__c
            }
        );
    }

    private static Decimal debitSide(
        Decimal netValue
    ) {
        Decimal value =
            nullToZero(
                netValue
            );

        return value > ZERO
            ? value
            : ZERO;
    }

    private static Decimal creditSide(
        Decimal netValue
    ) {
        Decimal value =
            nullToZero(
                netValue
            );

        return value < ZERO
            ? -value
            : ZERO;
    }

    private static Decimal nullToZero(
        Decimal value
    ) {
        return value == null
            ? ZERO
            : value;
    }

    private static Boolean isEffectivelyZero(
        Decimal value
    ) {
        Decimal safeValue =
            nullToZero(
                value
            );

        return safeValue.abs()
            < EPSILON;
    }

    private class BalanceBucket {
        Decimal debit;
        Decimal credit;

        BalanceBucket() {
            debit =
                ZERO;
            credit =
                ZERO;
        }

        BalanceBucket(
            Decimal debitValue,
            Decimal creditValue
        ) {
            debit =
                nullToZero(
                    debitValue
                );
            credit =
                nullToZero(
                    creditValue
                );
        }
    }


    private class LedgerAggregateBucket {
        Decimal debit;
        Decimal credit;
        Integer lineCount;

        LedgerAggregateBucket() {
            debit =
                ZERO;
            credit =
                ZERO;
            lineCount =
                0;
        }

        LedgerAggregateBucket(
            Decimal debitValue,
            Decimal creditValue,
            Integer lineCountValue
        ) {
            debit =
                nullToZero(
                    debitValue
                );
            credit =
                nullToZero(
                    creditValue
                );
            lineCount =
                lineCountValue == null
                    ? 0
                    : lineCountValue;
        }
    }

    public class ReportException
        extends Exception {
    }
}
