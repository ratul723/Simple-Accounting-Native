/**
 * G2D - Balance Sheet Lightning controller.
 */
public with sharing class SABBalanceSheetController {

    public class OptionDTO {
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String value { get; set; }
    }

    public class PeriodOptionDTO {
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public Date endDate { get; set; }
    }

    public class FilterDTO {
        @AuraEnabled public List<OptionDTO> definitions { get; set; }
        @AuraEnabled public List<PeriodOptionDTO> periods { get; set; }
    }

    public class RowDTO {
        @AuraEnabled public String rowKey { get; set; }
        @AuraEnabled public String groupKey { get; set; }
        @AuraEnabled public Decimal displayOrder { get; set; }
        @AuraEnabled public Decimal currentAmount { get; set; }
        @AuraEnabled public Decimal comparisonAmount { get; set; }
        @AuraEnabled public Decimal varianceAmount { get; set; }
        @AuraEnabled public Integer currentLineCount { get; set; }
        @AuraEnabled public Integer comparisonLineCount { get; set; }
        @AuraEnabled public Boolean syntheticCurrentYearEarnings { get; set; }
    }

    public class GroupDTO {
        @AuraEnabled public String groupKey { get; set; }
        @AuraEnabled public Decimal displayOrder { get; set; }
        @AuraEnabled public Decimal currentTotal { get; set; }
        @AuraEnabled public Decimal comparisonTotal { get; set; }
        @AuraEnabled public Decimal varianceTotal { get; set; }
        @AuraEnabled public List<RowDTO> rows { get; set; }
    }

    public class BalanceSheetDTO {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String companyName { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public Id reportDefinitionId { get; set; }
        @AuraEnabled public String reportDefinitionName { get; set; }
        @AuraEnabled public String definitionKey { get; set; }
        @AuraEnabled public Decimal definitionVersion { get; set; }
        @AuraEnabled public Date asOfDate { get; set; }
        @AuraEnabled public Date comparisonAsOfDate { get; set; }
        @AuraEnabled public Boolean hasComparison { get; set; }
        @AuraEnabled public Decimal currentFiscalYear { get; set; }
        @AuraEnabled public Date currentFiscalYearStart { get; set; }
        @AuraEnabled public Decimal comparisonFiscalYear { get; set; }
        @AuraEnabled public Date comparisonFiscalYearStart { get; set; }
        @AuraEnabled public Decimal currentAssets { get; set; }
        @AuraEnabled public Decimal currentLiabilities { get; set; }
        @AuraEnabled public Decimal currentEquityBeforeEarnings { get; set; }
        @AuraEnabled public Decimal currentYearEarnings { get; set; }
        @AuraEnabled public Decimal currentTotalEquity { get; set; }
        @AuraEnabled public Decimal currentLiabilitiesAndEquity { get; set; }
        @AuraEnabled public Decimal currentEquationDifference { get; set; }
        @AuraEnabled public Boolean currentBalanced { get; set; }
        @AuraEnabled public Decimal comparisonAssets { get; set; }
        @AuraEnabled public Decimal comparisonLiabilities { get; set; }
        @AuraEnabled public Decimal comparisonEquityBeforeEarnings { get; set; }
        @AuraEnabled public Decimal comparisonYearEarnings { get; set; }
        @AuraEnabled public Decimal comparisonTotalEquity { get; set; }
        @AuraEnabled public Decimal comparisonLiabilitiesAndEquity { get; set; }
        @AuraEnabled public Decimal comparisonEquationDifference { get; set; }
        @AuraEnabled public Boolean comparisonBalanced { get; set; }
        @AuraEnabled public List<GroupDTO> groups { get; set; }
        @AuraEnabled public Datetime generatedAt { get; set; }
    }

    public class DrilldownLineDTO {
        @AuraEnabled public Id journalLineId { get; set; }
        @AuraEnabled public Id journalId { get; set; }
        @AuraEnabled public String journalName { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String entryType { get; set; }
        @AuraEnabled public String journalStatus { get; set; }
        @AuraEnabled public String postingKey { get; set; }
        @AuraEnabled public Id glAccountId { get; set; }
        @AuraEnabled public String accountCode { get; set; }
        @AuraEnabled public String accountName { get; set; }
        @AuraEnabled public String accountType { get; set; }
        @AuraEnabled public Decimal lineNumber { get; set; }
        @AuraEnabled public Decimal debit { get; set; }
        @AuraEnabled public Decimal credit { get; set; }
        @AuraEnabled public Decimal presentedAmount { get; set; }
        @AuraEnabled public String explanation { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static FilterDTO getFilters(Id companyId) {
        if (companyId == null) {
            throw new AuraHandledException(
                'Accounting Company is required.'
            );
        }

        SABCompanyAccessService.assertCompanyAccess(companyId);

        SABAccessControlService.assertReadable(
            Report_Definition__c.SObjectType,
            new List<Schema.SObjectField>{
                Report_Definition__c.Company__c,
                Report_Definition__c.Report_Type__c,
                Report_Definition__c.Status__c,
                Report_Definition__c.Version__c
            }
        );

        SABAccessControlService.assertReadable(
            Accounting_Period__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Period__c.Company__c,
                Accounting_Period__c.End_Date__c,
                Accounting_Period__c.Fiscal_Year__c
            }
        );

        FilterDTO result = new FilterDTO();
        result.definitions = new List<OptionDTO>();
        result.periods = new List<PeriodOptionDTO>();

        for (Report_Definition__c definition : [
            SELECT Id, Name, Version__c
            FROM Report_Definition__c
            WHERE Company__c = :companyId
              AND Report_Type__c = 'Balance Sheet'
              AND Status__c = 'Active'
            ORDER BY Version__c DESC, Name ASC
        ]) {
            OptionDTO item = new OptionDTO();
            item.value = String.valueOf(definition.Id);
            item.label =
                definition.Name +
                ' · v' +
                String.valueOf(definition.Version__c);
            result.definitions.add(item);
        }

        for (Accounting_Period__c period : [
            SELECT Id, Name, End_Date__c, Fiscal_Year__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
            ORDER BY End_Date__c DESC
            LIMIT 250
        ]) {
            PeriodOptionDTO item = new PeriodOptionDTO();
            item.value = String.valueOf(period.Id);
            item.label =
                period.Name +
                ' · FY ' +
                String.valueOf(period.Fiscal_Year__c) +
                ' · as of ' +
                String.valueOf(period.End_Date__c);
            item.endDate = period.End_Date__c;
            result.periods.add(item);
        }

        return result;
    }

    @AuraEnabled
    public static BalanceSheetDTO runBalanceSheet(
        Id companyId,
        Id reportDefinitionId,
        Date asOfDate,
        Date comparisonAsOfDate
    ) {
        try {
            SABFinancialStatementService.BalanceSheetRequest request =
                new SABFinancialStatementService.BalanceSheetRequest();

            request.companyId = companyId;
            request.reportDefinitionId = reportDefinitionId;
            request.asOfDate = asOfDate;
            request.comparisonAsOfDate = comparisonAsOfDate;

            return toDTO(
                SABFinancialStatementService.getBalanceSheet(
                    request
                )
            );
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static List<DrilldownLineDTO> getRowDrilldown(
        Id companyId,
        Id reportDefinitionId,
        Date asOfDate,
        Date comparisonAsOfDate,
        String rowKey,
        Boolean comparison
    ) {
        try {
            SABFinancialStatementService.BalanceSheetRequest request =
                new SABFinancialStatementService.BalanceSheetRequest();

            request.companyId = companyId;
            request.reportDefinitionId = reportDefinitionId;
            request.asOfDate = asOfDate;
            request.comparisonAsOfDate = comparisonAsOfDate;

            List<DrilldownLineDTO> result =
                new List<DrilldownLineDTO>();

            for (
                SABFinancialStatementService.BalanceSheetDrilldownLine source
                : SABFinancialStatementService.getBalanceSheetRowDrilldown(
                    request,
                    rowKey,
                    comparison
                )
            ) {
                DrilldownLineDTO dto = new DrilldownLineDTO();
                dto.journalLineId = source.journalLineId;
                dto.journalId = source.journalId;
                dto.journalName = source.journalName;
                dto.accountingDate = source.accountingDate;
                dto.entryType = source.entryType;
                dto.journalStatus = source.journalStatus;
                dto.postingKey = source.postingKey;
                dto.glAccountId = source.glAccountId;
                dto.accountCode = source.accountCode;
                dto.accountName = source.accountName;
                dto.accountType = source.accountType;
                dto.lineNumber = source.lineNumber;
                dto.debit = source.debit;
                dto.credit = source.credit;
                dto.presentedAmount = source.presentedAmount;
                dto.explanation = source.explanation;
                result.add(dto);
            }

            return result;
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    private static BalanceSheetDTO toDTO(
        SABFinancialStatementService.BalanceSheetResult source
    ) {
        BalanceSheetDTO dto = new BalanceSheetDTO();

        dto.companyId = source.companyId;
        dto.companyName = source.companyName;
        dto.functionalCurrency = source.functionalCurrency;
        dto.reportDefinitionId = source.reportDefinitionId;
        dto.reportDefinitionName = source.reportDefinitionName;
        dto.definitionKey = source.definitionKey;
        dto.definitionVersion = source.definitionVersion;
        dto.asOfDate = source.asOfDate;
        dto.comparisonAsOfDate = source.comparisonAsOfDate;
        dto.hasComparison = source.hasComparison;
        dto.currentFiscalYear = source.currentFiscalYear;
        dto.currentFiscalYearStart = source.currentFiscalYearStart;
        dto.comparisonFiscalYear = source.comparisonFiscalYear;
        dto.comparisonFiscalYearStart = source.comparisonFiscalYearStart;
        dto.currentAssets = source.currentAssets;
        dto.currentLiabilities = source.currentLiabilities;
        dto.currentEquityBeforeEarnings =
            source.currentEquityBeforeEarnings;
        dto.currentYearEarnings = source.currentYearEarnings;
        dto.currentTotalEquity = source.currentTotalEquity;
        dto.currentLiabilitiesAndEquity =
            source.currentLiabilitiesAndEquity;
        dto.currentEquationDifference =
            source.currentEquationDifference;
        dto.currentBalanced = source.currentBalanced;
        dto.comparisonAssets = source.comparisonAssets;
        dto.comparisonLiabilities = source.comparisonLiabilities;
        dto.comparisonEquityBeforeEarnings =
            source.comparisonEquityBeforeEarnings;
        dto.comparisonYearEarnings =
            source.comparisonYearEarnings;
        dto.comparisonTotalEquity =
            source.comparisonTotalEquity;
        dto.comparisonLiabilitiesAndEquity =
            source.comparisonLiabilitiesAndEquity;
        dto.comparisonEquationDifference =
            source.comparisonEquationDifference;
        dto.comparisonBalanced = source.comparisonBalanced;
        dto.generatedAt = source.generatedAt;

        dto.groups = new List<GroupDTO>();

        for (
            SABFinancialStatementService.BalanceSheetGroup sourceGroup
            : source.groups
        ) {
            GroupDTO groupDTO = new GroupDTO();
            groupDTO.groupKey = sourceGroup.groupKey;
            groupDTO.displayOrder = sourceGroup.displayOrder;
            groupDTO.currentTotal = sourceGroup.currentTotal;
            groupDTO.comparisonTotal =
                sourceGroup.comparisonTotal;
            groupDTO.varianceTotal =
                sourceGroup.varianceTotal;
            groupDTO.rows = new List<RowDTO>();

            for (
                SABFinancialStatementService.BalanceSheetRow sourceRow
                : sourceGroup.rows
            ) {
                RowDTO rowDTO = new RowDTO();
                rowDTO.rowKey = sourceRow.rowKey;
                rowDTO.groupKey = sourceRow.groupKey;
                rowDTO.displayOrder = sourceRow.displayOrder;
                rowDTO.currentAmount = sourceRow.currentAmount;
                rowDTO.comparisonAmount =
                    sourceRow.comparisonAmount;
                rowDTO.varianceAmount =
                    sourceRow.varianceAmount;
                rowDTO.currentLineCount =
                    sourceRow.currentLineCount;
                rowDTO.comparisonLineCount =
                    sourceRow.comparisonLineCount;
                rowDTO.syntheticCurrentYearEarnings =
                    sourceRow.syntheticCurrentYearEarnings;
                groupDTO.rows.add(rowDTO);
            }

            dto.groups.add(groupDTO);
        }

        return dto;
    }
}
