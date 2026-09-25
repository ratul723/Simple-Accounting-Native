/**
 * G2 financial statement service.
 *
 * G2C - Profit & Loss.
 * G2D - Balance Sheet.
 *
 * Only Posted/Reversed Journal Entry Lines contribute.
 * Report_Definition__c + effective-dated Report_Mapping__c drive presentation.
 *
 * Balance Sheet earnings rule:
 * permanent Asset/Liability/Equity balances come from the posted ledger through
 * the as-of date; current-year earnings come from Revenue/Expense activity from
 * the configured fiscal-year start through the same date. If a closing journal
 * transfers profit/loss into Equity and zeros Revenue/Expense, current-year
 * earnings becomes zero so retained earnings is not double counted.
 */
public with sharing class SABFinancialStatementService {

    private static final Decimal ZERO = Decimal.valueOf('0');
    private static final Integer MAX_P_AND_L_LINES = 50000;

    public class ProfitLossRequest {
        public Id companyId;
        public Id reportDefinitionId;
        public Date fromDate;
        public Date toDate;
        public Date comparisonFromDate;
        public Date comparisonToDate;
        public Id departmentId;
        public Id costCenterId;
        public Id projectId;
    }

    public class ProfitLossRow {
        public String rowKey;
        public String groupKey;
        public Decimal displayOrder;
        public Decimal currentAmount;
        public Decimal comparisonAmount;
        public Decimal varianceAmount;
        public Integer currentLineCount;
        public Integer comparisonLineCount;
    }

    public class ProfitLossGroup {
        public String groupKey;
        public Decimal displayOrder;
        public Decimal currentTotal;
        public Decimal comparisonTotal;
        public Decimal varianceTotal;
        public List<ProfitLossRow> rows;
    }

    public class ProfitLossResult {
        public Id companyId;
        public String companyName;
        public String functionalCurrency;
        public Id reportDefinitionId;
        public String reportDefinitionName;
        public String definitionKey;
        public Decimal definitionVersion;
        public Date fromDate;
        public Date toDate;
        public Date comparisonFromDate;
        public Date comparisonToDate;
        public Boolean hasComparison;
        public Decimal currentRevenue;
        public Decimal currentExpense;
        public Decimal currentNetProfitLoss;
        public Decimal comparisonRevenue;
        public Decimal comparisonExpense;
        public Decimal comparisonNetProfitLoss;
        public Decimal netProfitVariance;
        public Integer currentLineCount;
        public Integer comparisonLineCount;
        public List<ProfitLossGroup> groups;
        public Datetime generatedAt;
    }

    public class DrilldownLine {
        public Id journalLineId;
        public Id journalId;
        public String journalName;
        public Date accountingDate;
        public String entryType;
        public String journalStatus;
        public String postingKey;
        public Id glAccountId;
        public String accountCode;
        public String accountName;
        public String accountType;
        public Decimal lineNumber;
        public Decimal debit;
        public Decimal credit;
        public Decimal presentedAmount;
        public String explanation;
    }


    public class BalanceSheetRequest {
        public Id companyId;
        public Id reportDefinitionId;
        public Date asOfDate;
        public Date comparisonAsOfDate;
    }

    public class BalanceSheetRow {
        public String rowKey;
        public String groupKey;
        public Decimal displayOrder;
        public Decimal currentAmount;
        public Decimal comparisonAmount;
        public Decimal varianceAmount;
        public Integer currentLineCount;
        public Integer comparisonLineCount;
        public Boolean syntheticCurrentYearEarnings;
    }

    public class BalanceSheetGroup {
        public String groupKey;
        public Decimal displayOrder;
        public Decimal currentTotal;
        public Decimal comparisonTotal;
        public Decimal varianceTotal;
        public List<BalanceSheetRow> rows;
    }

    public class BalanceSheetResult {
        public Id companyId;
        public String companyName;
        public String functionalCurrency;
        public Id reportDefinitionId;
        public String reportDefinitionName;
        public String definitionKey;
        public Decimal definitionVersion;
        public Date asOfDate;
        public Date comparisonAsOfDate;
        public Boolean hasComparison;
        public Decimal currentFiscalYear;
        public Date currentFiscalYearStart;
        public Decimal comparisonFiscalYear;
        public Date comparisonFiscalYearStart;
        public Decimal currentAssets;
        public Decimal currentLiabilities;
        public Decimal currentEquityBeforeEarnings;
        public Decimal currentYearEarnings;
        public Decimal currentTotalEquity;
        public Decimal currentLiabilitiesAndEquity;
        public Decimal currentEquationDifference;
        public Boolean currentBalanced;
        public Decimal comparisonAssets;
        public Decimal comparisonLiabilities;
        public Decimal comparisonEquityBeforeEarnings;
        public Decimal comparisonYearEarnings;
        public Decimal comparisonTotalEquity;
        public Decimal comparisonLiabilitiesAndEquity;
        public Decimal comparisonEquationDifference;
        public Boolean comparisonBalanced;
        public List<BalanceSheetGroup> groups;
        public Datetime generatedAt;
    }

    public class BalanceSheetDrilldownLine {
        public Id journalLineId;
        public Id journalId;
        public String journalName;
        public Date accountingDate;
        public String entryType;
        public String journalStatus;
        public String postingKey;
        public Id glAccountId;
        public String accountCode;
        public String accountName;
        public String accountType;
        public Decimal lineNumber;
        public Decimal debit;
        public Decimal credit;
        public Decimal presentedAmount;
        public String explanation;
    }

    private class BalanceMappingInfo {
        Id glAccountId;
        String accountType;
        String rowKey;
        String groupKey;
        Decimal displayOrder;
        Decimal signMultiplier;
        Date effectiveFrom;
        Date effectiveTo;
    }

    private class BalanceRowBucket {
        String rowKey;
        String groupKey;
        Decimal displayOrder;
        Decimal currentAmount = ZERO;
        Decimal comparisonAmount = ZERO;
        Integer currentLineCount = 0;
        Integer comparisonLineCount = 0;
        Boolean syntheticCurrentYearEarnings = false;
    }

    private class PermanentBalanceBucket {
        Id glAccountId;
        String accountType;
        Decimal debit = ZERO;
        Decimal credit = ZERO;
        Integer lineCount = 0;
    }

    private class EarningsBucket {
        Decimal revenue = ZERO;
        Decimal expense = ZERO;
        Integer lineCount = 0;

        Decimal netEarnings() {
            return revenue - expense;
        }
    }

    private class FiscalContext {
        Decimal fiscalYear;
        Date fiscalYearStart;
    }

    private class MappingInfo {
        Id glAccountId;
        String accountType;
        String rowKey;
        String groupKey;
        Decimal displayOrder;
        Decimal signMultiplier;
        Date effectiveFrom;
        Date effectiveTo;
    }

    private class RowBucket {
        String rowKey;
        String groupKey;
        Decimal displayOrder;
        Decimal currentAmount = ZERO;
        Decimal comparisonAmount = ZERO;
        Integer currentLineCount = 0;
        Integer comparisonLineCount = 0;
    }

    public class StatementException extends Exception {}

    public static ProfitLossResult getProfitLoss(ProfitLossRequest request) {
        validateRequest(request);
        SABCompanyAccessService.assertCompanyAccess(request.companyId);
        assertReadAccess(request);

        Accounting_Company__c company = [
            SELECT Id, Name__c, Functional_Currency__c
            FROM Accounting_Company__c
            WHERE Id = :request.companyId
            LIMIT 1
        ];

        Report_Definition__c definition = loadDefinition(request);
        List<Report_Mapping__c> mappings = loadMappings(definition.Id);

        Map<Id, List<MappingInfo>> mappingsByAccount =
            buildMappingIndex(mappings, request.companyId);

        Map<String, RowBucket> rows = seedRows(mappings);

        List<Journal_Entry_Line__c> currentLines = queryLines(
            request.companyId,
            request.fromDate,
            request.toDate,
            request.departmentId,
            request.costCenterId,
            request.projectId,
            null,
            MAX_P_AND_L_LINES
        );

        List<Journal_Entry_Line__c> comparisonLines =
            new List<Journal_Entry_Line__c>();

        Boolean hasComparison =
            request.comparisonFromDate != null &&
            request.comparisonToDate != null;

        if (hasComparison) {
            comparisonLines = queryLines(
                request.companyId,
                request.comparisonFromDate,
                request.comparisonToDate,
                request.departmentId,
                request.costCenterId,
                request.projectId,
                null,
                MAX_P_AND_L_LINES
            );
        }

        Decimal currentRevenue = ZERO;
        Decimal currentExpense = ZERO;
        Integer currentLineCount = 0;

        for (Journal_Entry_Line__c line : currentLines) {
            MappingInfo mapping = resolveMapping(
                mappingsByAccount,
                line.GL_Account__c,
                line.Journal_Entry__r.Accounting_Date__c
            );

            applyLine(rows, mapping, line, true);
            currentLineCount++;

            if (line.GL_Account__r.Account_Type__c == 'Revenue') {
                currentRevenue +=
                    nullToZero(line.Credit_Base__c) -
                    nullToZero(line.Debit_Base__c);
            } else {
                currentExpense +=
                    nullToZero(line.Debit_Base__c) -
                    nullToZero(line.Credit_Base__c);
            }
        }

        Decimal comparisonRevenue = ZERO;
        Decimal comparisonExpense = ZERO;
        Integer comparisonLineCount = 0;

        for (Journal_Entry_Line__c line : comparisonLines) {
            MappingInfo mapping = resolveMapping(
                mappingsByAccount,
                line.GL_Account__c,
                line.Journal_Entry__r.Accounting_Date__c
            );

            applyLine(rows, mapping, line, false);
            comparisonLineCount++;

            if (line.GL_Account__r.Account_Type__c == 'Revenue') {
                comparisonRevenue +=
                    nullToZero(line.Credit_Base__c) -
                    nullToZero(line.Debit_Base__c);
            } else {
                comparisonExpense +=
                    nullToZero(line.Debit_Base__c) -
                    nullToZero(line.Credit_Base__c);
            }
        }

        ProfitLossResult result = new ProfitLossResult();
        result.companyId = company.Id;
        result.companyName = company.Name__c;
        result.functionalCurrency = company.Functional_Currency__c;
        result.reportDefinitionId = definition.Id;
        result.reportDefinitionName = definition.Name;
        result.definitionKey = definition.Definition_Key__c;
        result.definitionVersion = definition.Version__c;
        result.fromDate = request.fromDate;
        result.toDate = request.toDate;
        result.comparisonFromDate = request.comparisonFromDate;
        result.comparisonToDate = request.comparisonToDate;
        result.hasComparison = hasComparison;
        result.currentRevenue = currentRevenue;
        result.currentExpense = currentExpense;
        result.currentNetProfitLoss = currentRevenue - currentExpense;
        result.comparisonRevenue = comparisonRevenue;
        result.comparisonExpense = comparisonExpense;
        result.comparisonNetProfitLoss =
            comparisonRevenue - comparisonExpense;
        result.netProfitVariance =
            result.currentNetProfitLoss -
            result.comparisonNetProfitLoss;
        result.currentLineCount = currentLineCount;
        result.comparisonLineCount = comparisonLineCount;
        result.groups = buildGroups(rows);
        result.generatedAt = System.now();
        return result;
    }

    public static List<DrilldownLine> getProfitLossRowDrilldown(
        ProfitLossRequest request,
        String rowKey,
        Boolean comparison
    ) {
        validateRequest(request);

        if (String.isBlank(rowKey)) {
            throw new StatementException(
                'Profit & Loss row key is required for drilldown.'
            );
        }

        SABCompanyAccessService.assertCompanyAccess(request.companyId);
        assertReadAccess(request);

        Report_Definition__c definition = loadDefinition(request);
        List<Report_Mapping__c> mappings = loadMappings(definition.Id);

        Map<Id, List<MappingInfo>> mappingsByAccount =
            buildMappingIndex(mappings, request.companyId);

        Set<Id> rowAccountIds = new Set<Id>();
        for (Report_Mapping__c mapping : mappings) {
            if (mapping.Row_Key__c == rowKey) {
                rowAccountIds.add(mapping.GL_Account__c);
            }
        }

        if (rowAccountIds.isEmpty()) {
            throw new StatementException(
                'No Report Mapping exists for the selected Profit & Loss row.'
            );
        }

        Date rangeFrom =
            comparison == true
                ? request.comparisonFromDate
                : request.fromDate;
        Date rangeTo =
            comparison == true
                ? request.comparisonToDate
                : request.toDate;

        if (rangeFrom == null || rangeTo == null) {
            throw new StatementException(
                'The selected comparison range is not configured.'
            );
        }

        List<Journal_Entry_Line__c> sourceLines = queryLines(
            request.companyId,
            rangeFrom,
            rangeTo,
            request.departmentId,
            request.costCenterId,
            request.projectId,
            rowAccountIds,
            2000
        );

        List<DrilldownLine> result = new List<DrilldownLine>();

        for (Journal_Entry_Line__c line : sourceLines) {
            MappingInfo mapping = resolveMapping(
                mappingsByAccount,
                line.GL_Account__c,
                line.Journal_Entry__r.Accounting_Date__c
            );

            if (mapping.rowKey != rowKey) {
                continue;
            }

            DrilldownLine dto = new DrilldownLine();
            dto.journalLineId = line.Id;
            dto.journalId = line.Journal_Entry__c;
            dto.journalName = line.Journal_Entry__r.Name;
            dto.accountingDate =
                line.Journal_Entry__r.Accounting_Date__c;
            dto.entryType = line.Journal_Entry__r.Entry_Type__c;
            dto.journalStatus = line.Journal_Entry__r.Status__c;
            dto.postingKey = line.Journal_Entry__r.Posting_Key__c;
            dto.glAccountId = line.GL_Account__c;
            dto.accountCode = line.GL_Account__r.Account_Code__c;
            dto.accountName = line.GL_Account__r.Name;
            dto.accountType = line.GL_Account__r.Account_Type__c;
            dto.lineNumber = line.Line_Number__c;
            dto.debit = nullToZero(line.Debit_Base__c);
            dto.credit = nullToZero(line.Credit_Base__c);
            dto.presentedAmount =
                (dto.debit - dto.credit) *
                mapping.signMultiplier;
            dto.explanation = line.Explanation__c;
            result.add(dto);
        }

        return result;
    }


    public static BalanceSheetResult getBalanceSheet(
        BalanceSheetRequest request
    ) {
        validateBalanceSheetRequest(request);

        SABCompanyAccessService.assertCompanyAccess(
            request.companyId
        );

        assertBalanceSheetReadAccess();

        Accounting_Company__c company = [
            SELECT Id, Name__c, Functional_Currency__c
            FROM Accounting_Company__c
            WHERE Id = :request.companyId
            LIMIT 1
        ];

        Report_Definition__c definition =
            loadBalanceSheetDefinition(request);

        List<Report_Mapping__c> mappings =
            loadBalanceSheetMappings(definition.Id);

        Map<Id, List<BalanceMappingInfo>> mappingsByAccount =
            buildBalanceMappingIndex(
                mappings,
                request.companyId
            );

        FiscalContext currentFiscal =
            resolveFiscalContext(
                request.companyId,
                request.asOfDate
            );

        Boolean hasComparison =
            request.comparisonAsOfDate != null;

        FiscalContext comparisonFiscal;

        if (hasComparison) {
            comparisonFiscal =
                resolveFiscalContext(
                    request.companyId,
                    request.comparisonAsOfDate
                );
        }

        Map<String, BalanceRowBucket> rowBuckets =
            seedBalanceRows(
                mappings,
                request.asOfDate,
                request.comparisonAsOfDate
            );

        List<PermanentBalanceBucket> currentPermanent =
            queryPermanentBalances(
                request.companyId,
                request.asOfDate
            );

        EarningsBucket currentEarnings =
            queryCurrentYearEarnings(
                request.companyId,
                currentFiscal.fiscalYearStart,
                request.asOfDate
            );

        Decimal currentAssets = ZERO;
        Decimal currentLiabilities = ZERO;
        Decimal currentEquity = ZERO;

        for (PermanentBalanceBucket balance : currentPermanent) {
            BalanceMappingInfo mapping =
                resolveBalanceMapping(
                    mappingsByAccount,
                    balance.glAccountId,
                    request.asOfDate
                );

            Decimal debitMinusCredit =
                balance.debit - balance.credit;

            applyPermanentBalanceToRow(
                rowBuckets,
                mapping,
                debitMinusCredit,
                balance.lineCount,
                true
            );

            if (balance.accountType == 'Asset') {
                currentAssets += debitMinusCredit;
            } else if (balance.accountType == 'Liability') {
                currentLiabilities += -debitMinusCredit;
            } else {
                currentEquity += -debitMinusCredit;
            }
        }

        addSyntheticEarningsRow(
            rowBuckets,
            mappings,
            currentEarnings.netEarnings(),
            currentEarnings.lineCount,
            true
        );

        Decimal comparisonAssets = ZERO;
        Decimal comparisonLiabilities = ZERO;
        Decimal comparisonEquity = ZERO;
        EarningsBucket comparisonEarnings =
            new EarningsBucket();

        if (hasComparison) {
            List<PermanentBalanceBucket> comparisonPermanent =
                queryPermanentBalances(
                    request.companyId,
                    request.comparisonAsOfDate
                );

            comparisonEarnings =
                queryCurrentYearEarnings(
                    request.companyId,
                    comparisonFiscal.fiscalYearStart,
                    request.comparisonAsOfDate
                );

            for (
                PermanentBalanceBucket balance
                : comparisonPermanent
            ) {
                BalanceMappingInfo mapping =
                    resolveBalanceMapping(
                        mappingsByAccount,
                        balance.glAccountId,
                        request.comparisonAsOfDate
                    );

                Decimal debitMinusCredit =
                    balance.debit - balance.credit;

                applyPermanentBalanceToRow(
                    rowBuckets,
                    mapping,
                    debitMinusCredit,
                    balance.lineCount,
                    false
                );

                if (balance.accountType == 'Asset') {
                    comparisonAssets += debitMinusCredit;
                } else if (balance.accountType == 'Liability') {
                    comparisonLiabilities += -debitMinusCredit;
                } else {
                    comparisonEquity += -debitMinusCredit;
                }
            }

            addSyntheticEarningsRow(
                rowBuckets,
                mappings,
                comparisonEarnings.netEarnings(),
                comparisonEarnings.lineCount,
                false
            );
        }

        BalanceSheetResult result =
            new BalanceSheetResult();

        result.companyId = company.Id;
        result.companyName = company.Name__c;
        result.functionalCurrency =
            company.Functional_Currency__c;
        result.reportDefinitionId = definition.Id;
        result.reportDefinitionName = definition.Name;
        result.definitionKey =
            definition.Definition_Key__c;
        result.definitionVersion =
            definition.Version__c;
        result.asOfDate = request.asOfDate;
        result.comparisonAsOfDate =
            request.comparisonAsOfDate;
        result.hasComparison = hasComparison;
        result.currentFiscalYear =
            currentFiscal.fiscalYear;
        result.currentFiscalYearStart =
            currentFiscal.fiscalYearStart;

        if (hasComparison) {
            result.comparisonFiscalYear =
                comparisonFiscal.fiscalYear;
            result.comparisonFiscalYearStart =
                comparisonFiscal.fiscalYearStart;
        }

        result.currentAssets = currentAssets;
        result.currentLiabilities =
            currentLiabilities;
        result.currentEquityBeforeEarnings =
            currentEquity;
        result.currentYearEarnings =
            currentEarnings.netEarnings();
        result.currentTotalEquity =
            currentEquity +
            result.currentYearEarnings;
        result.currentLiabilitiesAndEquity =
            currentLiabilities +
            result.currentTotalEquity;
        result.currentEquationDifference =
            currentAssets -
            result.currentLiabilitiesAndEquity;
        result.currentBalanced =
            isEffectivelyZero(
                result.currentEquationDifference
            );

        result.comparisonAssets =
            comparisonAssets;
        result.comparisonLiabilities =
            comparisonLiabilities;
        result.comparisonEquityBeforeEarnings =
            comparisonEquity;
        result.comparisonYearEarnings =
            comparisonEarnings.netEarnings();
        result.comparisonTotalEquity =
            comparisonEquity +
            result.comparisonYearEarnings;
        result.comparisonLiabilitiesAndEquity =
            comparisonLiabilities +
            result.comparisonTotalEquity;
        result.comparisonEquationDifference =
            comparisonAssets -
            result.comparisonLiabilitiesAndEquity;
        result.comparisonBalanced =
            !hasComparison ||
            isEffectivelyZero(
                result.comparisonEquationDifference
            );

        result.groups =
            buildBalanceSheetGroups(
                rowBuckets
            );
        result.generatedAt = System.now();

        return result;
    }

    public static List<BalanceSheetDrilldownLine>
        getBalanceSheetRowDrilldown(
            BalanceSheetRequest request,
            String rowKey,
            Boolean comparison
        ) {
        validateBalanceSheetRequest(request);

        if (String.isBlank(rowKey)) {
            throw new StatementException(
                'Balance Sheet row key is required for drilldown.'
            );
        }

        SABCompanyAccessService.assertCompanyAccess(
            request.companyId
        );

        assertBalanceSheetReadAccess();

        Report_Definition__c definition =
            loadBalanceSheetDefinition(request);

        Date asOfDate =
            comparison == true
                ? request.comparisonAsOfDate
                : request.asOfDate;

        if (asOfDate == null) {
            throw new StatementException(
                'The selected comparison as-of date is not configured.'
            );
        }

        List<BalanceSheetDrilldownLine> result =
            new List<BalanceSheetDrilldownLine>();

        if (rowKey == 'CURRENT_YEAR_EARNINGS') {
            FiscalContext fiscalContext =
                resolveFiscalContext(
                    request.companyId,
                    asOfDate
                );

            List<Journal_Entry_Line__c> earningsLines =
                queryBalanceSheetDrilldownLines(
                    request.companyId,
                    fiscalContext.fiscalYearStart,
                    asOfDate,
                    null,
                    true
                );

            for (
                Journal_Entry_Line__c line
                : earningsLines
            ) {
                BalanceSheetDrilldownLine dto =
                    toBalanceSheetDrilldown(line);

                dto.presentedAmount =
                    nullToZero(
                        line.Credit_Base__c
                    ) -
                    nullToZero(
                        line.Debit_Base__c
                    );

                result.add(dto);
            }

            return result;
        }

        List<Report_Mapping__c> mappings =
            loadBalanceSheetMappings(
                definition.Id
            );

        Map<Id, List<BalanceMappingInfo>> mappingsByAccount =
            buildBalanceMappingIndex(
                mappings,
                request.companyId
            );

        Set<Id> accountIds =
            new Set<Id>();

        for (Id accountId : mappingsByAccount.keySet()) {
            BalanceMappingInfo mapping =
                resolveBalanceMapping(
                    mappingsByAccount,
                    accountId,
                    asOfDate
                );

            if (mapping.rowKey == rowKey) {
                accountIds.add(accountId);
            }
        }

        if (accountIds.isEmpty()) {
            throw new StatementException(
                'No effective Balance Sheet mapping exists for the selected row.'
            );
        }

        List<Journal_Entry_Line__c> sourceLines =
            queryBalanceSheetDrilldownLines(
                request.companyId,
                null,
                asOfDate,
                accountIds,
                false
            );

        for (Journal_Entry_Line__c line : sourceLines) {
            BalanceMappingInfo mapping =
                resolveBalanceMapping(
                    mappingsByAccount,
                    line.GL_Account__c,
                    asOfDate
                );

            if (mapping.rowKey != rowKey) {
                continue;
            }

            BalanceSheetDrilldownLine dto =
                toBalanceSheetDrilldown(line);

            dto.presentedAmount =
                (
                    nullToZero(
                        line.Debit_Base__c
                    ) -
                    nullToZero(
                        line.Credit_Base__c
                    )
                ) *
                mapping.signMultiplier;

            result.add(dto);
        }

        return result;
    }

    private static BalanceSheetDrilldownLine
        toBalanceSheetDrilldown(
            Journal_Entry_Line__c line
        ) {
        BalanceSheetDrilldownLine dto =
            new BalanceSheetDrilldownLine();

        dto.journalLineId = line.Id;
        dto.journalId = line.Journal_Entry__c;
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
        dto.glAccountId = line.GL_Account__c;
        dto.accountCode =
            line.GL_Account__r.Account_Code__c;
        dto.accountName =
            line.GL_Account__r.Name;
        dto.accountType =
            line.GL_Account__r.Account_Type__c;
        dto.lineNumber = line.Line_Number__c;
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

        return dto;
    }

    private static Report_Definition__c loadDefinition(
        ProfitLossRequest request
    ) {
        List<Report_Definition__c> definitions = [
            SELECT Id, Name, Company__c, Definition_Key__c,
                   Effective_From__c, Effective_To__c,
                   Report_Type__c, Status__c, Version__c
            FROM Report_Definition__c
            WHERE Id = :request.reportDefinitionId
            LIMIT 1
        ];

        if (definitions.isEmpty()) {
            throw new StatementException(
                'The selected Report Definition was not found or is not accessible.'
            );
        }

        Report_Definition__c definition = definitions[0];

        if (definition.Company__c != request.companyId) {
            throw new StatementException(
                'The selected Report Definition does not belong to the selected Accounting Company.'
            );
        }

        if (definition.Report_Type__c != 'P&L') {
            throw new StatementException(
                'The selected Report Definition is not a Profit & Loss definition.'
            );
        }

        if (definition.Status__c != 'Active') {
            throw new StatementException(
                'The selected Profit & Loss definition must be Active.'
            );
        }

        validateDefinitionDates(
            definition,
            request.fromDate,
            request.toDate,
            'current'
        );

        if (
            request.comparisonFromDate != null &&
            request.comparisonToDate != null
        ) {
            validateDefinitionDates(
                definition,
                request.comparisonFromDate,
                request.comparisonToDate,
                'comparison'
            );
        }

        return definition;
    }

    private static void validateDefinitionDates(
        Report_Definition__c definition,
        Date fromDate,
        Date toDate,
        String rangeName
    ) {
        if (
            definition.Effective_From__c != null &&
            fromDate < definition.Effective_From__c
        ) {
            throw new StatementException(
                'The ' + rangeName +
                ' range starts before the selected Profit & Loss definition becomes effective.'
            );
        }

        if (
            definition.Effective_To__c != null &&
            toDate > definition.Effective_To__c
        ) {
            throw new StatementException(
                'The ' + rangeName +
                ' range ends after the selected Profit & Loss definition expires.'
            );
        }
    }

    private static List<Report_Mapping__c> loadMappings(Id definitionId) {
        List<Report_Mapping__c> mappings = [
            SELECT Id, Report_Definition__c, GL_Account__c,
                   GL_Account__r.Account_Code__c,
                   GL_Account__r.Name,
                   GL_Account__r.Account_Type__c,
                   GL_Account__r.Company__c,
                   Row_Key__c, Group_Key__c,
                   Sign_Multiplier__c, Display_Order__c,
                   Effective_From__c, Effective_To__c
            FROM Report_Mapping__c
            WHERE Report_Definition__c = :definitionId
            ORDER BY Display_Order__c ASC,
                     Row_Key__c ASC,
                     GL_Account__r.Account_Code__c ASC
        ];

        if (mappings.isEmpty()) {
            throw new StatementException(
                'The selected Profit & Loss definition has no Report Mappings.'
            );
        }

        return mappings;
    }

    private static Map<Id, List<MappingInfo>> buildMappingIndex(
        List<Report_Mapping__c> mappings,
        Id companyId
    ) {
        Map<Id, List<MappingInfo>> result =
            new Map<Id, List<MappingInfo>>();

        for (Report_Mapping__c mapping : mappings) {
            if (mapping.GL_Account__r.Company__c != companyId) {
                throw new StatementException(
                    'A Profit & Loss mapping references a GL Account from another Accounting Company.'
                );
            }

            if (
                mapping.GL_Account__r.Account_Type__c != 'Revenue' &&
                mapping.GL_Account__r.Account_Type__c != 'Expense'
            ) {
                throw new StatementException(
                    'Profit & Loss mappings may reference only Revenue or Expense GL Accounts.'
                );
            }

            if (
                mapping.Sign_Multiplier__c == null ||
                (
                    mapping.Sign_Multiplier__c != Decimal.valueOf('1') &&
                    mapping.Sign_Multiplier__c != Decimal.valueOf('-1')
                )
            ) {
                throw new StatementException(
                    'Every Profit & Loss mapping must have Sign Multiplier 1 or -1.'
                );
            }

            if (String.isBlank(mapping.Row_Key__c)) {
                throw new StatementException(
                    'Every Profit & Loss mapping must have a Row Key.'
                );
            }

            if (
                mapping.Effective_From__c != null &&
                mapping.Effective_To__c != null &&
                mapping.Effective_From__c > mapping.Effective_To__c
            ) {
                throw new StatementException(
                    'A Profit & Loss mapping has Effective From after Effective To.'
                );
            }

            MappingInfo info = new MappingInfo();
            info.glAccountId = mapping.GL_Account__c;
            info.accountType =
                mapping.GL_Account__r.Account_Type__c;
            info.rowKey = mapping.Row_Key__c;
            info.groupKey =
                String.isBlank(mapping.Group_Key__c)
                    ? 'UNGROUPED'
                    : mapping.Group_Key__c;
            info.displayOrder =
                mapping.Display_Order__c == null
                    ? Decimal.valueOf('999999')
                    : mapping.Display_Order__c;
            info.signMultiplier = mapping.Sign_Multiplier__c;
            info.effectiveFrom = mapping.Effective_From__c;
            info.effectiveTo = mapping.Effective_To__c;

            if (!result.containsKey(info.glAccountId)) {
                result.put(
                    info.glAccountId,
                    new List<MappingInfo>()
                );
            }

            result.get(info.glAccountId).add(info);
        }

        return result;
    }

    private static MappingInfo resolveMapping(
        Map<Id, List<MappingInfo>> mappingsByAccount,
        Id glAccountId,
        Date accountingDate
    ) {
        if (!mappingsByAccount.containsKey(glAccountId)) {
            throw new StatementException(
                'Profit & Loss is incomplete: a Revenue or Expense GL Account has posted activity but no Report Mapping.'
            );
        }

        List<MappingInfo> matches = new List<MappingInfo>();

        for (MappingInfo mapping : mappingsByAccount.get(glAccountId)) {
            Boolean starts =
                mapping.effectiveFrom == null ||
                mapping.effectiveFrom <= accountingDate;
            Boolean ends =
                mapping.effectiveTo == null ||
                mapping.effectiveTo >= accountingDate;

            if (starts && ends) {
                matches.add(mapping);
            }
        }

        if (matches.isEmpty()) {
            throw new StatementException(
                'Profit & Loss is incomplete: posted activity has no effective Report Mapping on ' +
                String.valueOf(accountingDate) + '.'
            );
        }

        if (matches.size() > 1) {
            throw new StatementException(
                'Profit & Loss mapping is ambiguous: more than one Report Mapping is effective for the same GL Account on ' +
                String.valueOf(accountingDate) + '.'
            );
        }

        return matches[0];
    }

    private static Map<String, RowBucket> seedRows(
        List<Report_Mapping__c> mappings
    ) {
        Map<String, RowBucket> result = new Map<String, RowBucket>();

        for (Report_Mapping__c mapping : mappings) {
            String groupKey =
                String.isBlank(mapping.Group_Key__c)
                    ? 'UNGROUPED'
                    : mapping.Group_Key__c;

            String keyValue = groupKey + '||' + mapping.Row_Key__c;
            Decimal orderValue =
                mapping.Display_Order__c == null
                    ? Decimal.valueOf('999999')
                    : mapping.Display_Order__c;

            if (!result.containsKey(keyValue)) {
                RowBucket row = new RowBucket();
                row.rowKey = mapping.Row_Key__c;
                row.groupKey = groupKey;
                row.displayOrder = orderValue;
                result.put(keyValue, row);
            } else if (
                orderValue < result.get(keyValue).displayOrder
            ) {
                result.get(keyValue).displayOrder = orderValue;
            }
        }

        return result;
    }

    private static void applyLine(
        Map<String, RowBucket> rows,
        MappingInfo mapping,
        Journal_Entry_Line__c line,
        Boolean currentPeriod
    ) {
        String keyValue =
            mapping.groupKey + '||' + mapping.rowKey;

        if (!rows.containsKey(keyValue)) {
            RowBucket row = new RowBucket();
            row.rowKey = mapping.rowKey;
            row.groupKey = mapping.groupKey;
            row.displayOrder = mapping.displayOrder;
            rows.put(keyValue, row);
        }

        RowBucket target = rows.get(keyValue);
        Decimal presentedAmount =
            (
                nullToZero(line.Debit_Base__c) -
                nullToZero(line.Credit_Base__c)
            ) * mapping.signMultiplier;

        if (currentPeriod) {
            target.currentAmount += presentedAmount;
            target.currentLineCount++;
        } else {
            target.comparisonAmount += presentedAmount;
            target.comparisonLineCount++;
        }
    }

    private static List<ProfitLossGroup> buildGroups(
        Map<String, RowBucket> rows
    ) {
        List<RowBucket> orderedRows = new List<RowBucket>();
        orderedRows.addAll(rows.values());

        for (Integer i = 1; i < orderedRows.size(); i++) {
            RowBucket current = orderedRows[i];
            Integer j = i - 1;

            while (
                j >= 0 &&
                compareRows(current, orderedRows[j]) < 0
            ) {
                orderedRows[j + 1] = orderedRows[j];
                j--;
            }

            orderedRows[j + 1] = current;
        }

        List<ProfitLossGroup> result =
            new List<ProfitLossGroup>();

        Map<String, ProfitLossGroup> byGroup =
            new Map<String, ProfitLossGroup>();

        for (RowBucket bucket : orderedRows) {
            if (!byGroup.containsKey(bucket.groupKey)) {
                ProfitLossGroup statementGroup =
                    new ProfitLossGroup();

                statementGroup.groupKey = bucket.groupKey;
                statementGroup.displayOrder = bucket.displayOrder;
                statementGroup.currentTotal = ZERO;
                statementGroup.comparisonTotal = ZERO;
                statementGroup.varianceTotal = ZERO;
                statementGroup.rows =
                    new List<ProfitLossRow>();

                byGroup.put(
                    bucket.groupKey,
                    statementGroup
                );
                result.add(statementGroup);
            }

            ProfitLossGroup targetGroup =
                byGroup.get(bucket.groupKey);

            ProfitLossRow row = new ProfitLossRow();
            row.rowKey = bucket.rowKey;
            row.groupKey = bucket.groupKey;
            row.displayOrder = bucket.displayOrder;
            row.currentAmount = bucket.currentAmount;
            row.comparisonAmount = bucket.comparisonAmount;
            row.varianceAmount =
                bucket.currentAmount -
                bucket.comparisonAmount;
            row.currentLineCount = bucket.currentLineCount;
            row.comparisonLineCount =
                bucket.comparisonLineCount;

            targetGroup.rows.add(row);
            targetGroup.currentTotal += row.currentAmount;
            targetGroup.comparisonTotal += row.comparisonAmount;
            targetGroup.varianceTotal += row.varianceAmount;
        }

        return result;
    }

    private static Integer compareRows(
        RowBucket leftRow,
        RowBucket rightRow
    ) {
        if (leftRow.displayOrder < rightRow.displayOrder) {
            return -1;
        }

        if (leftRow.displayOrder > rightRow.displayOrder) {
            return 1;
        }

        Integer groupCompare =
            leftRow.groupKey.compareTo(rightRow.groupKey);

        if (groupCompare != 0) {
            return groupCompare;
        }

        return leftRow.rowKey.compareTo(rightRow.rowKey);
    }

    private static List<Journal_Entry_Line__c> queryLines(
        Id companyId,
        Date fromDate,
        Date toDate,
        Id departmentId,
        Id costCenterId,
        Id projectId,
        Set<Id> accountIds,
        Integer maxRows
    ) {
        String whereClause =
            buildWhereClause(
                companyId,
                fromDate,
                toDate,
                departmentId,
                costCenterId,
                projectId,
                accountIds
            );

        Integer rowCount =
            Database.countQuery(
                'SELECT COUNT() FROM Journal_Entry_Line__c WHERE ' +
                whereClause
            );

        if (rowCount > maxRows) {
            throw new StatementException(
                'The selected Profit & Loss scope contains ' +
                String.valueOf(rowCount) +
                ' ledger lines, which exceeds the interactive limit of ' +
                String.valueOf(maxRows) +
                '. Narrow the date range or dimensions.'
            );
        }

        String soql =
            'SELECT Id, Journal_Entry__c, Journal_Entry__r.Name, ' +
            'Journal_Entry__r.Accounting_Date__c, ' +
            'Journal_Entry__r.Entry_Type__c, ' +
            'Journal_Entry__r.Status__c, ' +
            'Journal_Entry__r.Posting_Key__c, ' +
            'GL_Account__c, GL_Account__r.Account_Code__c, ' +
            'GL_Account__r.Name, GL_Account__r.Account_Type__c, ' +
            'Line_Number__c, Debit_Base__c, Credit_Base__c, Explanation__c ' +
            'FROM Journal_Entry_Line__c WHERE ' +
            whereClause +
            ' ORDER BY Journal_Entry__r.Accounting_Date__c ASC, ' +
            'Journal_Entry__r.Name ASC, Line_Number__c ASC ' +
            'LIMIT ' + String.valueOf(maxRows);

        return Database.query(soql);
    }

    private static String buildWhereClause(
        Id companyId,
        Date fromDate,
        Date toDate,
        Id departmentId,
        Id costCenterId,
        Id projectId,
        Set<Id> accountIds
    ) {
        List<String> clauses = new List<String>{
            'Journal_Entry__r.Company__c = \'' +
                String.valueOf(companyId) + '\'',
            'Journal_Entry__r.Status__c IN (\'Posted\', \'Reversed\')',
            'Journal_Entry__r.Accounting_Date__c >= ' +
                String.valueOf(fromDate),
            'Journal_Entry__r.Accounting_Date__c <= ' +
                String.valueOf(toDate),
            'GL_Account__r.Account_Type__c IN (\'Revenue\', \'Expense\')'
        };

        if (departmentId != null) {
            clauses.add(
                'Department__c = \'' +
                String.valueOf(departmentId) + '\''
            );
        }

        if (costCenterId != null) {
            clauses.add(
                'Cost_Center__c = \'' +
                String.valueOf(costCenterId) + '\''
            );
        }

        if (projectId != null) {
            clauses.add(
                'Project__c = \'' +
                String.valueOf(projectId) + '\''
            );
        }

        if (accountIds != null && !accountIds.isEmpty()) {
            List<String> values = new List<String>();

            for (Id accountId : accountIds) {
                values.add(
                    '\'' + String.valueOf(accountId) + '\''
                );
            }

            clauses.add(
                'GL_Account__c IN (' +
                String.join(values, ',') +
                ')'
            );
        }

        return String.join(clauses, ' AND ');
    }


    private static Report_Definition__c loadBalanceSheetDefinition(
        BalanceSheetRequest request
    ) {
        List<Report_Definition__c> definitions = [
            SELECT Id, Name, Company__c, Definition_Key__c,
                   Effective_From__c, Effective_To__c,
                   Report_Type__c, Status__c, Version__c
            FROM Report_Definition__c
            WHERE Id = :request.reportDefinitionId
            LIMIT 1
        ];

        if (definitions.isEmpty()) {
            throw new StatementException(
                'The selected Balance Sheet Report Definition was not found or is not accessible.'
            );
        }

        Report_Definition__c definition =
            definitions[0];

        if (
            definition.Company__c
            != request.companyId
        ) {
            throw new StatementException(
                'The selected Balance Sheet definition does not belong to the selected Accounting Company.'
            );
        }

        if (
            definition.Report_Type__c
            != 'Balance Sheet'
        ) {
            throw new StatementException(
                'The selected Report Definition is not a Balance Sheet definition.'
            );
        }

        if (definition.Status__c != 'Active') {
            throw new StatementException(
                'The selected Balance Sheet definition must be Active.'
            );
        }

        validateBalanceDefinitionDate(
            definition,
            request.asOfDate,
            'current'
        );

        if (request.comparisonAsOfDate != null) {
            validateBalanceDefinitionDate(
                definition,
                request.comparisonAsOfDate,
                'comparison'
            );
        }

        return definition;
    }

    private static void validateBalanceDefinitionDate(
        Report_Definition__c definition,
        Date asOfDate,
        String rangeName
    ) {
        if (
            definition.Effective_From__c != null
            && asOfDate <
                definition.Effective_From__c
        ) {
            throw new StatementException(
                'The ' +
                rangeName +
                ' as-of date is before the selected Balance Sheet definition becomes effective.'
            );
        }

        if (
            definition.Effective_To__c != null
            && asOfDate >
                definition.Effective_To__c
        ) {
            throw new StatementException(
                'The ' +
                rangeName +
                ' as-of date is after the selected Balance Sheet definition expires.'
            );
        }
    }

    private static List<Report_Mapping__c>
        loadBalanceSheetMappings(
            Id definitionId
        ) {
        List<Report_Mapping__c> mappings = [
            SELECT Id, Report_Definition__c, GL_Account__c,
                   GL_Account__r.Account_Code__c,
                   GL_Account__r.Name,
                   GL_Account__r.Account_Type__c,
                   GL_Account__r.Company__c,
                   Row_Key__c, Group_Key__c,
                   Sign_Multiplier__c, Display_Order__c,
                   Effective_From__c, Effective_To__c
            FROM Report_Mapping__c
            WHERE Report_Definition__c =
                :definitionId
            ORDER BY Display_Order__c ASC,
                     Row_Key__c ASC,
                     GL_Account__r.Account_Code__c ASC
        ];

        if (mappings.isEmpty()) {
            throw new StatementException(
                'The selected Balance Sheet definition has no Report Mappings.'
            );
        }

        return mappings;
    }

    private static Map<Id, List<BalanceMappingInfo>>
        buildBalanceMappingIndex(
            List<Report_Mapping__c> mappings,
            Id companyId
        ) {
        Map<Id, List<BalanceMappingInfo>> result =
            new Map<Id, List<BalanceMappingInfo>>();

        for (Report_Mapping__c mapping : mappings) {
            if (
                mapping.GL_Account__r.Company__c
                != companyId
            ) {
                throw new StatementException(
                    'A Balance Sheet mapping references a GL Account from another Accounting Company.'
                );
            }

            String accountType =
                mapping.GL_Account__r.Account_Type__c;

            if (
                accountType != 'Asset'
                && accountType != 'Liability'
                && accountType != 'Equity'
            ) {
                throw new StatementException(
                    'Balance Sheet mappings may reference only Asset, Liability or Equity GL Accounts.'
                );
            }

            if (
                mapping.Sign_Multiplier__c == null
                || (
                    mapping.Sign_Multiplier__c
                        != Decimal.valueOf('1')
                    && mapping.Sign_Multiplier__c
                        != Decimal.valueOf('-1')
                )
            ) {
                throw new StatementException(
                    'Every Balance Sheet mapping must have Sign Multiplier 1 or -1.'
                );
            }

            if (String.isBlank(mapping.Row_Key__c)) {
                throw new StatementException(
                    'Every Balance Sheet mapping must have a Row Key.'
                );
            }

            if (
                mapping.Row_Key__c
                == 'CURRENT_YEAR_EARNINGS'
            ) {
                throw new StatementException(
                    'CURRENT_YEAR_EARNINGS is reserved for the system-calculated Balance Sheet earnings row.'
                );
            }

            if (
                mapping.Effective_From__c != null
                && mapping.Effective_To__c != null
                && mapping.Effective_From__c >
                    mapping.Effective_To__c
            ) {
                throw new StatementException(
                    'A Balance Sheet mapping has Effective From after Effective To.'
                );
            }

            BalanceMappingInfo info =
                new BalanceMappingInfo();

            info.glAccountId =
                mapping.GL_Account__c;
            info.accountType =
                accountType;
            info.rowKey =
                mapping.Row_Key__c;
            info.groupKey =
                String.isBlank(
                    mapping.Group_Key__c
                )
                    ? accountType.toUpperCase()
                    : mapping.Group_Key__c;
            info.displayOrder =
                mapping.Display_Order__c == null
                    ? Decimal.valueOf('999999')
                    : mapping.Display_Order__c;
            info.signMultiplier =
                mapping.Sign_Multiplier__c;
            info.effectiveFrom =
                mapping.Effective_From__c;
            info.effectiveTo =
                mapping.Effective_To__c;

            if (
                !result.containsKey(
                    info.glAccountId
                )
            ) {
                result.put(
                    info.glAccountId,
                    new List<BalanceMappingInfo>()
                );
            }

            result.get(
                info.glAccountId
            ).add(
                info
            );
        }

        return result;
    }

    private static BalanceMappingInfo resolveBalanceMapping(
        Map<Id, List<BalanceMappingInfo>> mappingsByAccount,
        Id glAccountId,
        Date asOfDate
    ) {
        if (
            !mappingsByAccount.containsKey(
                glAccountId
            )
        ) {
            throw new StatementException(
                'Balance Sheet is incomplete: an Asset, Liability or Equity GL Account has a non-zero balance but no Report Mapping.'
            );
        }

        List<BalanceMappingInfo> matches =
            new List<BalanceMappingInfo>();

        for (
            BalanceMappingInfo mapping
            : mappingsByAccount.get(
                glAccountId
            )
        ) {
            Boolean starts =
                mapping.effectiveFrom == null
                || mapping.effectiveFrom
                    <= asOfDate;

            Boolean ends =
                mapping.effectiveTo == null
                || mapping.effectiveTo
                    >= asOfDate;

            if (starts && ends) {
                matches.add(mapping);
            }
        }

        if (matches.isEmpty()) {
            throw new StatementException(
                'Balance Sheet is incomplete: a permanent-account balance has no effective Report Mapping on '
                + String.valueOf(asOfDate)
                + '.'
            );
        }

        if (matches.size() > 1) {
            throw new StatementException(
                'Balance Sheet mapping is ambiguous: more than one Report Mapping is effective for the same GL Account on '
                + String.valueOf(asOfDate)
                + '.'
            );
        }

        return matches[0];
    }

    private static Map<String, BalanceRowBucket>
        seedBalanceRows(
            List<Report_Mapping__c> mappings,
            Date currentAsOf,
            Date comparisonAsOf
        ) {
        Map<String, BalanceRowBucket> result =
            new Map<String, BalanceRowBucket>();

        for (Report_Mapping__c mapping : mappings) {
            Boolean effectiveCurrent =
                isBalanceMappingEffective(
                    mapping.Effective_From__c,
                    mapping.Effective_To__c,
                    currentAsOf
                );

            Boolean effectiveComparison =
                comparisonAsOf != null
                && isBalanceMappingEffective(
                    mapping.Effective_From__c,
                    mapping.Effective_To__c,
                    comparisonAsOf
                );

            if (
                !effectiveCurrent
                && !effectiveComparison
            ) {
                continue;
            }

            String groupKey =
                String.isBlank(
                    mapping.Group_Key__c
                )
                    ? mapping.GL_Account__r.Account_Type__c.toUpperCase()
                    : mapping.Group_Key__c;

            String keyValue =
                groupKey +
                '||' +
                mapping.Row_Key__c;

            Decimal orderValue =
                mapping.Display_Order__c == null
                    ? Decimal.valueOf('999999')
                    : mapping.Display_Order__c;

            if (!result.containsKey(keyValue)) {
                BalanceRowBucket row =
                    new BalanceRowBucket();

                row.rowKey =
                    mapping.Row_Key__c;
                row.groupKey =
                    groupKey;
                row.displayOrder =
                    orderValue;

                result.put(
                    keyValue,
                    row
                );
            } else if (
                orderValue <
                result.get(
                    keyValue
                ).displayOrder
            ) {
                result.get(
                    keyValue
                ).displayOrder =
                    orderValue;
            }
        }

        return result;
    }

    private static Boolean isBalanceMappingEffective(
        Date effectiveFrom,
        Date effectiveTo,
        Date asOfDate
    ) {
        return (
            asOfDate != null
            && (
                effectiveFrom == null
                || effectiveFrom <= asOfDate
            )
            && (
                effectiveTo == null
                || effectiveTo >= asOfDate
            )
        );
    }

    private static void applyPermanentBalanceToRow(
        Map<String, BalanceRowBucket> rows,
        BalanceMappingInfo mapping,
        Decimal debitMinusCredit,
        Integer lineCount,
        Boolean currentPeriod
    ) {
        String keyValue =
            mapping.groupKey +
            '||' +
            mapping.rowKey;

        if (!rows.containsKey(keyValue)) {
            BalanceRowBucket row =
                new BalanceRowBucket();

            row.rowKey =
                mapping.rowKey;
            row.groupKey =
                mapping.groupKey;
            row.displayOrder =
                mapping.displayOrder;

            rows.put(
                keyValue,
                row
            );
        }

        BalanceRowBucket target =
            rows.get(
                keyValue
            );

        Decimal presentedAmount =
            debitMinusCredit *
            mapping.signMultiplier;

        if (currentPeriod) {
            target.currentAmount +=
                presentedAmount;
            target.currentLineCount +=
                lineCount;
        } else {
            target.comparisonAmount +=
                presentedAmount;
            target.comparisonLineCount +=
                lineCount;
        }
    }

    private static void addSyntheticEarningsRow(
        Map<String, BalanceRowBucket> rows,
        List<Report_Mapping__c> mappings,
        Decimal earnings,
        Integer lineCount,
        Boolean currentPeriod
    ) {
        String equityGroup =
            'EQUITY';

        Decimal maxEquityOrder =
            Decimal.valueOf('900000');

        Boolean foundEquity =
            false;

        for (Report_Mapping__c mapping : mappings) {
            if (
                mapping.GL_Account__r.Account_Type__c
                != 'Equity'
            ) {
                continue;
            }

            String mappingGroup =
                String.isBlank(
                    mapping.Group_Key__c
                )
                    ? 'EQUITY'
                    : mapping.Group_Key__c;

            Decimal mappingOrder =
                mapping.Display_Order__c == null
                    ? Decimal.valueOf('900000')
                    : mapping.Display_Order__c;

            if (!foundEquity) {
                equityGroup =
                    mappingGroup;
                maxEquityOrder =
                    mappingOrder;
                foundEquity =
                    true;
            } else if (
                mappingGroup == equityGroup
                && mappingOrder >
                    maxEquityOrder
            ) {
                maxEquityOrder =
                    mappingOrder;
            }
        }

        String keyValue =
            equityGroup +
            '||CURRENT_YEAR_EARNINGS';

        if (!rows.containsKey(keyValue)) {
            BalanceRowBucket row =
                new BalanceRowBucket();

            row.rowKey =
                'CURRENT_YEAR_EARNINGS';
            row.groupKey =
                equityGroup;
            row.displayOrder =
                maxEquityOrder +
                Decimal.valueOf('1');
            row.syntheticCurrentYearEarnings =
                true;

            rows.put(
                keyValue,
                row
            );
        }

        BalanceRowBucket target =
            rows.get(
                keyValue
            );

        if (currentPeriod) {
            target.currentAmount =
                earnings;
            target.currentLineCount =
                lineCount;
        } else {
            target.comparisonAmount =
                earnings;
            target.comparisonLineCount =
                lineCount;
        }
    }

    private static List<PermanentBalanceBucket>
        queryPermanentBalances(
            Id companyId,
            Date asOfDate
        ) {
        List<AggregateResult> aggregates = [
            SELECT GL_Account__c accountId,
                   GL_Account__r.Account_Type__c accountType,
                   SUM(Debit_Base__c) debitTotal,
                   SUM(Credit_Base__c) creditTotal,
                   COUNT(Id) lineCount
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__r.Company__c =
                :companyId
              AND Journal_Entry__r.Status__c IN (
                  'Posted',
                  'Reversed'
              )
              AND Journal_Entry__r.Accounting_Date__c
                  <= :asOfDate
              AND GL_Account__r.Account_Type__c IN (
                  'Asset',
                  'Liability',
                  'Equity'
              )
            GROUP BY GL_Account__c,
                     GL_Account__r.Account_Type__c
        ];

        List<PermanentBalanceBucket> result =
            new List<PermanentBalanceBucket>();

        for (AggregateResult aggregateRow : aggregates) {
            Decimal debit =
                nullToZero(
                    (Decimal) aggregateRow.get(
                        'debitTotal'
                    )
                );

            Decimal credit =
                nullToZero(
                    (Decimal) aggregateRow.get(
                        'creditTotal'
                    )
                );

            if (
                isEffectivelyZero(
                    debit - credit
                )
            ) {
                continue;
            }

            PermanentBalanceBucket bucket =
                new PermanentBalanceBucket();

            bucket.glAccountId =
                (Id) aggregateRow.get(
                    'accountId'
                );
            bucket.accountType =
                (String) aggregateRow.get(
                    'accountType'
                );
            bucket.debit =
                debit;
            bucket.credit =
                credit;
            bucket.lineCount =
                Integer.valueOf(
                    String.valueOf(
                        aggregateRow.get(
                            'lineCount'
                        )
                    )
                );

            result.add(bucket);
        }

        return result;
    }

    private static EarningsBucket queryCurrentYearEarnings(
        Id companyId,
        Date fiscalYearStart,
        Date asOfDate
    ) {
        EarningsBucket result =
            new EarningsBucket();

        for (AggregateResult aggregateRow : [
            SELECT GL_Account__r.Account_Type__c accountType,
                   SUM(Debit_Base__c) debitTotal,
                   SUM(Credit_Base__c) creditTotal,
                   COUNT(Id) lineCount
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__r.Company__c =
                :companyId
              AND Journal_Entry__r.Status__c IN (
                  'Posted',
                  'Reversed'
              )
              AND Journal_Entry__r.Accounting_Date__c
                  >= :fiscalYearStart
              AND Journal_Entry__r.Accounting_Date__c
                  <= :asOfDate
              AND GL_Account__r.Account_Type__c IN (
                  'Revenue',
                  'Expense'
              )
            GROUP BY GL_Account__r.Account_Type__c
        ]) {
            String accountType =
                (String) aggregateRow.get(
                    'accountType'
                );

            Decimal debit =
                nullToZero(
                    (Decimal) aggregateRow.get(
                        'debitTotal'
                    )
                );

            Decimal credit =
                nullToZero(
                    (Decimal) aggregateRow.get(
                        'creditTotal'
                    )
                );

            Integer lineCount =
                Integer.valueOf(
                    String.valueOf(
                        aggregateRow.get(
                            'lineCount'
                        )
                    )
                );

            if (accountType == 'Revenue') {
                result.revenue +=
                    credit - debit;
            } else {
                result.expense +=
                    debit - credit;
            }

            result.lineCount +=
                lineCount;
        }

        return result;
    }

    private static FiscalContext resolveFiscalContext(
        Id companyId,
        Date asOfDate
    ) {
        List<Accounting_Period__c> periods = [
            SELECT Id, Fiscal_Year__c,
                   Start_Date__c, End_Date__c
            FROM Accounting_Period__c
            WHERE Company__c =
                :companyId
              AND Start_Date__c
                  <= :asOfDate
              AND End_Date__c
                  >= :asOfDate
            ORDER BY Start_Date__c ASC
            LIMIT 2
        ];

        if (periods.isEmpty()) {
            throw new StatementException(
                'No Accounting Period contains the Balance Sheet as-of date.'
            );
        }

        if (periods.size() > 1) {
            throw new StatementException(
                'More than one Accounting Period contains the Balance Sheet as-of date.'
            );
        }

        Decimal fiscalYear =
            periods[0].Fiscal_Year__c;

        AggregateResult fiscalStartResult = [
            SELECT MIN(Start_Date__c) fiscalStart
            FROM Accounting_Period__c
            WHERE Company__c =
                :companyId
              AND Fiscal_Year__c =
                :fiscalYear
        ];

        Date fiscalYearStart =
            (Date) fiscalStartResult.get(
                'fiscalStart'
            );

        if (fiscalYearStart == null) {
            throw new StatementException(
                'The fiscal year start could not be resolved from Accounting Periods.'
            );
        }

        FiscalContext result =
            new FiscalContext();

        result.fiscalYear =
            fiscalYear;
        result.fiscalYearStart =
            fiscalYearStart;

        return result;
    }

    private static List<BalanceSheetGroup>
        buildBalanceSheetGroups(
            Map<String, BalanceRowBucket> rows
        ) {
        List<BalanceRowBucket> orderedRows =
            new List<BalanceRowBucket>();

        orderedRows.addAll(
            rows.values()
        );

        for (
            Integer i = 1;
            i < orderedRows.size();
            i++
        ) {
            BalanceRowBucket current =
                orderedRows[i];

            Integer j = i - 1;

            while (
                j >= 0
                && compareBalanceRows(
                    current,
                    orderedRows[j]
                ) < 0
            ) {
                orderedRows[j + 1] =
                    orderedRows[j];
                j--;
            }

            orderedRows[j + 1] =
                current;
        }

        List<BalanceSheetGroup> result =
            new List<BalanceSheetGroup>();

        Map<String, BalanceSheetGroup> byGroup =
            new Map<String, BalanceSheetGroup>();

        for (BalanceRowBucket bucket : orderedRows) {
            if (
                !byGroup.containsKey(
                    bucket.groupKey
                )
            ) {
                BalanceSheetGroup statementGroup =
                    new BalanceSheetGroup();

                statementGroup.groupKey =
                    bucket.groupKey;
                statementGroup.displayOrder =
                    bucket.displayOrder;
                statementGroup.currentTotal =
                    ZERO;
                statementGroup.comparisonTotal =
                    ZERO;
                statementGroup.varianceTotal =
                    ZERO;
                statementGroup.rows =
                    new List<BalanceSheetRow>();

                byGroup.put(
                    bucket.groupKey,
                    statementGroup
                );

                result.add(
                    statementGroup
                );
            }

            BalanceSheetGroup targetGroup =
                byGroup.get(
                    bucket.groupKey
                );

            BalanceSheetRow row =
                new BalanceSheetRow();

            row.rowKey =
                bucket.rowKey;
            row.groupKey =
                bucket.groupKey;
            row.displayOrder =
                bucket.displayOrder;
            row.currentAmount =
                bucket.currentAmount;
            row.comparisonAmount =
                bucket.comparisonAmount;
            row.varianceAmount =
                bucket.currentAmount -
                bucket.comparisonAmount;
            row.currentLineCount =
                bucket.currentLineCount;
            row.comparisonLineCount =
                bucket.comparisonLineCount;
            row.syntheticCurrentYearEarnings =
                bucket.syntheticCurrentYearEarnings;

            targetGroup.rows.add(row);
            targetGroup.currentTotal +=
                row.currentAmount;
            targetGroup.comparisonTotal +=
                row.comparisonAmount;
            targetGroup.varianceTotal +=
                row.varianceAmount;
        }

        return result;
    }

    private static Integer compareBalanceRows(
        BalanceRowBucket leftRow,
        BalanceRowBucket rightRow
    ) {
        if (
            leftRow.displayOrder <
            rightRow.displayOrder
        ) {
            return -1;
        }

        if (
            leftRow.displayOrder >
            rightRow.displayOrder
        ) {
            return 1;
        }

        Integer groupCompare =
            leftRow.groupKey.compareTo(
                rightRow.groupKey
            );

        if (groupCompare != 0) {
            return groupCompare;
        }

        return leftRow.rowKey.compareTo(
            rightRow.rowKey
        );
    }

    private static List<Journal_Entry_Line__c>
        queryBalanceSheetDrilldownLines(
            Id companyId,
            Date fromDate,
            Date toDate,
            Set<Id> accountIds,
            Boolean earningsOnly
        ) {
        List<String> clauses =
            new List<String>{
                'Journal_Entry__r.Company__c = \'' +
                    String.valueOf(companyId) + '\'',
                'Journal_Entry__r.Status__c IN (\'Posted\', \'Reversed\')',
                'Journal_Entry__r.Accounting_Date__c <= ' +
                    String.valueOf(toDate)
            };

        if (fromDate != null) {
            clauses.add(
                'Journal_Entry__r.Accounting_Date__c >= ' +
                String.valueOf(fromDate)
            );
        }

        if (earningsOnly) {
            clauses.add(
                'GL_Account__r.Account_Type__c IN (\'Revenue\', \'Expense\')'
            );
        } else {
            clauses.add(
                'GL_Account__r.Account_Type__c IN (\'Asset\', \'Liability\', \'Equity\')'
            );
        }

        if (
            accountIds != null
            && !accountIds.isEmpty()
        ) {
            List<String> values =
                new List<String>();

            for (Id accountId : accountIds) {
                values.add(
                    '\'' +
                    String.valueOf(accountId) +
                    '\''
                );
            }

            clauses.add(
                'GL_Account__c IN (' +
                String.join(values, ',') +
                ')'
            );
        }

        String whereClause =
            String.join(
                clauses,
                ' AND '
            );

        Integer rowCount =
            Database.countQuery(
                'SELECT COUNT() ' +
                'FROM Journal_Entry_Line__c ' +
                'WHERE ' +
                whereClause
            );

        if (rowCount > 2000) {
            throw new StatementException(
                'The selected Balance Sheet drilldown contains ' +
                String.valueOf(rowCount) +
                ' ledger lines, which exceeds the interactive limit of 2000. Narrow the drilldown scope.'
            );
        }

        return Database.query(
            'SELECT Id, Journal_Entry__c, Journal_Entry__r.Name, ' +
            'Journal_Entry__r.Accounting_Date__c, ' +
            'Journal_Entry__r.Entry_Type__c, ' +
            'Journal_Entry__r.Status__c, ' +
            'Journal_Entry__r.Posting_Key__c, ' +
            'GL_Account__c, GL_Account__r.Account_Code__c, ' +
            'GL_Account__r.Name, GL_Account__r.Account_Type__c, ' +
            'Line_Number__c, Debit_Base__c, Credit_Base__c, ' +
            'Explanation__c ' +
            'FROM Journal_Entry_Line__c ' +
            'WHERE ' +
            whereClause +
            ' ORDER BY Journal_Entry__r.Accounting_Date__c ASC, ' +
            'Journal_Entry__r.Name ASC, Line_Number__c ASC ' +
            'LIMIT 2000'
        );
    }

    private static void validateBalanceSheetRequest(
        BalanceSheetRequest request
    ) {
        if (request == null) {
            throw new StatementException(
                'Balance Sheet request is required.'
            );
        }

        if (request.companyId == null) {
            throw new StatementException(
                'Accounting Company is required.'
            );
        }

        if (request.reportDefinitionId == null) {
            throw new StatementException(
                'Balance Sheet Report Definition is required.'
            );
        }

        if (request.asOfDate == null) {
            throw new StatementException(
                'Balance Sheet as-of date is required.'
            );
        }
    }

    private static void assertBalanceSheetReadAccess() {
        SABAccessControlService.assertReadable(
            Accounting_Company__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Company__c.Name__c,
                Accounting_Company__c.Functional_Currency__c
            }
        );

        SABAccessControlService.assertReadable(
            Accounting_Period__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Period__c.Company__c,
                Accounting_Period__c.Start_Date__c,
                Accounting_Period__c.End_Date__c,
                Accounting_Period__c.Fiscal_Year__c
            }
        );

        SABAccessControlService.assertReadable(
            Report_Definition__c.SObjectType,
            new List<Schema.SObjectField>{
                Report_Definition__c.Company__c,
                Report_Definition__c.Definition_Key__c,
                Report_Definition__c.Effective_From__c,
                Report_Definition__c.Effective_To__c,
                Report_Definition__c.Report_Type__c,
                Report_Definition__c.Status__c,
                Report_Definition__c.Version__c
            }
        );

        SABAccessControlService.assertReadable(
            Report_Mapping__c.SObjectType,
            new List<Schema.SObjectField>{
                Report_Mapping__c.Report_Definition__c,
                Report_Mapping__c.GL_Account__c,
                Report_Mapping__c.Row_Key__c,
                Report_Mapping__c.Group_Key__c,
                Report_Mapping__c.Sign_Multiplier__c,
                Report_Mapping__c.Display_Order__c,
                Report_Mapping__c.Effective_From__c,
                Report_Mapping__c.Effective_To__c
            }
        );

        SABAccessControlService.assertReadable(
            GL_Account__c.SObjectType,
            new List<Schema.SObjectField>{
                GL_Account__c.Company__c,
                GL_Account__c.Account_Code__c,
                GL_Account__c.Account_Type__c
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
    }

    private static Boolean isEffectivelyZero(
        Decimal value
    ) {
        return nullToZero(value).abs()
            < Decimal.valueOf('0.00005');
    }

    private static void validateRequest(ProfitLossRequest request) {
        if (request == null) {
            throw new StatementException(
                'Profit & Loss request is required.'
            );
        }

        if (request.companyId == null) {
            throw new StatementException(
                'Accounting Company is required.'
            );
        }

        if (request.reportDefinitionId == null) {
            throw new StatementException(
                'Profit & Loss Report Definition is required.'
            );
        }

        if (request.fromDate == null || request.toDate == null) {
            throw new StatementException(
                'From Date and To Date are required.'
            );
        }

        if (request.fromDate > request.toDate) {
            throw new StatementException(
                'From Date cannot be after To Date.'
            );
        }

        Boolean hasComparisonFrom =
            request.comparisonFromDate != null;
        Boolean hasComparisonTo =
            request.comparisonToDate != null;

        if (hasComparisonFrom != hasComparisonTo) {
            throw new StatementException(
                'Both comparison From Date and comparison To Date are required.'
            );
        }

        if (
            hasComparisonFrom &&
            request.comparisonFromDate >
                request.comparisonToDate
        ) {
            throw new StatementException(
                'Comparison From Date cannot be after Comparison To Date.'
            );
        }
    }

    private static void assertReadAccess(
        ProfitLossRequest request
    ) {
        SABAccessControlService.assertReadable(
            Accounting_Company__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Company__c.Name__c,
                Accounting_Company__c.Functional_Currency__c
            }
        );

        SABAccessControlService.assertReadable(
            Report_Definition__c.SObjectType,
            new List<Schema.SObjectField>{
                Report_Definition__c.Company__c,
                Report_Definition__c.Definition_Key__c,
                Report_Definition__c.Effective_From__c,
                Report_Definition__c.Effective_To__c,
                Report_Definition__c.Report_Type__c,
                Report_Definition__c.Status__c,
                Report_Definition__c.Version__c
            }
        );

        SABAccessControlService.assertReadable(
            Report_Mapping__c.SObjectType,
            new List<Schema.SObjectField>{
                Report_Mapping__c.Report_Definition__c,
                Report_Mapping__c.GL_Account__c,
                Report_Mapping__c.Row_Key__c,
                Report_Mapping__c.Group_Key__c,
                Report_Mapping__c.Sign_Multiplier__c,
                Report_Mapping__c.Display_Order__c,
                Report_Mapping__c.Effective_From__c,
                Report_Mapping__c.Effective_To__c
            }
        );

        SABAccessControlService.assertReadable(
            GL_Account__c.SObjectType,
            new List<Schema.SObjectField>{
                GL_Account__c.Company__c,
                GL_Account__c.Account_Code__c,
                GL_Account__c.Account_Type__c
            }
        );

        List<Schema.SObjectField> lineFields =
            new List<Schema.SObjectField>{
                Journal_Entry_Line__c.Journal_Entry__c,
                Journal_Entry_Line__c.GL_Account__c,
                Journal_Entry_Line__c.Line_Number__c,
                Journal_Entry_Line__c.Debit_Base__c,
                Journal_Entry_Line__c.Credit_Base__c,
                Journal_Entry_Line__c.Explanation__c
            };

        if (request.departmentId != null) {
            lineFields.add(
                Journal_Entry_Line__c.Department__c
            );
        }

        if (request.costCenterId != null) {
            lineFields.add(
                Journal_Entry_Line__c.Cost_Center__c
            );
        }

        if (request.projectId != null) {
            lineFields.add(
                Journal_Entry_Line__c.Project__c
            );
        }

        SABAccessControlService.assertReadable(
            Journal_Entry_Line__c.SObjectType,
            lineFields
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
    }

    private static Decimal nullToZero(Decimal value) {
        return value == null ? ZERO : value;
    }
}
