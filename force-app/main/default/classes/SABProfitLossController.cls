/**
 * G2C - Profit & Loss Lightning controller.
 */
public with sharing class SABProfitLossController {

    public class OptionDTO {
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String value { get; set; }
    }

    public class PeriodOptionDTO {
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date endDate { get; set; }
    }

    public class FilterDTO {
        @AuraEnabled public List<OptionDTO> definitions { get; set; }
        @AuraEnabled public List<PeriodOptionDTO> periods { get; set; }
        @AuraEnabled public List<OptionDTO> departments { get; set; }
        @AuraEnabled public List<OptionDTO> costCenters { get; set; }
        @AuraEnabled public List<OptionDTO> projects { get; set; }
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
    }

    public class GroupDTO {
        @AuraEnabled public String groupKey { get; set; }
        @AuraEnabled public Decimal displayOrder { get; set; }
        @AuraEnabled public Decimal currentTotal { get; set; }
        @AuraEnabled public Decimal comparisonTotal { get; set; }
        @AuraEnabled public Decimal varianceTotal { get; set; }
        @AuraEnabled public List<RowDTO> rows { get; set; }
    }

    public class ProfitLossDTO {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String companyName { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public Id reportDefinitionId { get; set; }
        @AuraEnabled public String reportDefinitionName { get; set; }
        @AuraEnabled public String definitionKey { get; set; }
        @AuraEnabled public Decimal definitionVersion { get; set; }
        @AuraEnabled public Date fromDate { get; set; }
        @AuraEnabled public Date toDate { get; set; }
        @AuraEnabled public Date comparisonFromDate { get; set; }
        @AuraEnabled public Date comparisonToDate { get; set; }
        @AuraEnabled public Boolean hasComparison { get; set; }
        @AuraEnabled public Decimal currentRevenue { get; set; }
        @AuraEnabled public Decimal currentExpense { get; set; }
        @AuraEnabled public Decimal currentNetProfitLoss { get; set; }
        @AuraEnabled public Decimal comparisonRevenue { get; set; }
        @AuraEnabled public Decimal comparisonExpense { get; set; }
        @AuraEnabled public Decimal comparisonNetProfitLoss { get; set; }
        @AuraEnabled public Decimal netProfitVariance { get; set; }
        @AuraEnabled public Integer currentLineCount { get; set; }
        @AuraEnabled public Integer comparisonLineCount { get; set; }
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
                Report_Definition__c.Version__c,
                Report_Definition__c.Effective_From__c,
                Report_Definition__c.Effective_To__c
            }
        );

        SABAccessControlService.assertReadable(
            Accounting_Period__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Period__c.Company__c,
                Accounting_Period__c.Start_Date__c,
                Accounting_Period__c.End_Date__c
            }
        );

        FilterDTO result = new FilterDTO();
        result.definitions = new List<OptionDTO>();
        result.periods = new List<PeriodOptionDTO>();

        for (Report_Definition__c definition : [
            SELECT Id, Name, Version__c,
                   Effective_From__c, Effective_To__c
            FROM Report_Definition__c
            WHERE Company__c = :companyId
              AND Report_Type__c = 'P&L'
              AND Status__c = 'Active'
            ORDER BY Version__c DESC,
                     Effective_From__c DESC,
                     Name ASC
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
            SELECT Id, Name, Start_Date__c, End_Date__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
            ORDER BY Start_Date__c DESC
            LIMIT 250
        ]) {
            PeriodOptionDTO item = new PeriodOptionDTO();
            item.value = String.valueOf(period.Id);
            item.label =
                period.Name +
                ' · ' +
                String.valueOf(period.Start_Date__c) +
                ' to ' +
                String.valueOf(period.End_Date__c);
            item.startDate = period.Start_Date__c;
            item.endDate = period.End_Date__c;
            result.periods.add(item);
        }

        result.departments =
            loadDimensionOptions(
                'Department__c',
                companyId,
                true
            );

        result.costCenters =
            loadDimensionOptions(
                'Cost_Center__c',
                companyId,
                true
            );

        result.projects =
            loadDimensionOptions(
                'Project__c',
                companyId,
                false
            );

        return result;
    }

    @AuraEnabled
    public static ProfitLossDTO runProfitLoss(
        Id companyId,
        Id reportDefinitionId,
        Date fromDate,
        Date toDate,
        Date comparisonFromDate,
        Date comparisonToDate,
        Id departmentId,
        Id costCenterId,
        Id projectId
    ) {
        try {
            SABFinancialStatementService.ProfitLossRequest request =
                buildRequest(
                    companyId,
                    reportDefinitionId,
                    fromDate,
                    toDate,
                    comparisonFromDate,
                    comparisonToDate,
                    departmentId,
                    costCenterId,
                    projectId
                );

            return toDTO(
                SABFinancialStatementService.getProfitLoss(
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
        Date fromDate,
        Date toDate,
        Date comparisonFromDate,
        Date comparisonToDate,
        Id departmentId,
        Id costCenterId,
        Id projectId,
        String rowKey,
        Boolean comparison
    ) {
        try {
            SABFinancialStatementService.ProfitLossRequest request =
                buildRequest(
                    companyId,
                    reportDefinitionId,
                    fromDate,
                    toDate,
                    comparisonFromDate,
                    comparisonToDate,
                    departmentId,
                    costCenterId,
                    projectId
                );

            List<DrilldownLineDTO> result =
                new List<DrilldownLineDTO>();

            for (
                SABFinancialStatementService.DrilldownLine source
                : SABFinancialStatementService.getProfitLossRowDrilldown(
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

    private static SABFinancialStatementService.ProfitLossRequest buildRequest(
        Id companyId,
        Id reportDefinitionId,
        Date fromDate,
        Date toDate,
        Date comparisonFromDate,
        Date comparisonToDate,
        Id departmentId,
        Id costCenterId,
        Id projectId
    ) {
        SABFinancialStatementService.ProfitLossRequest result =
            new SABFinancialStatementService.ProfitLossRequest();

        result.companyId = companyId;
        result.reportDefinitionId = reportDefinitionId;
        result.fromDate = fromDate;
        result.toDate = toDate;
        result.comparisonFromDate = comparisonFromDate;
        result.comparisonToDate = comparisonToDate;
        result.departmentId = departmentId;
        result.costCenterId = costCenterId;
        result.projectId = projectId;

        return result;
    }

    private static ProfitLossDTO toDTO(
        SABFinancialStatementService.ProfitLossResult source
    ) {
        ProfitLossDTO dto = new ProfitLossDTO();

        dto.companyId = source.companyId;
        dto.companyName = source.companyName;
        dto.functionalCurrency = source.functionalCurrency;
        dto.reportDefinitionId = source.reportDefinitionId;
        dto.reportDefinitionName = source.reportDefinitionName;
        dto.definitionKey = source.definitionKey;
        dto.definitionVersion = source.definitionVersion;
        dto.fromDate = source.fromDate;
        dto.toDate = source.toDate;
        dto.comparisonFromDate = source.comparisonFromDate;
        dto.comparisonToDate = source.comparisonToDate;
        dto.hasComparison = source.hasComparison;
        dto.currentRevenue = source.currentRevenue;
        dto.currentExpense = source.currentExpense;
        dto.currentNetProfitLoss = source.currentNetProfitLoss;
        dto.comparisonRevenue = source.comparisonRevenue;
        dto.comparisonExpense = source.comparisonExpense;
        dto.comparisonNetProfitLoss = source.comparisonNetProfitLoss;
        dto.netProfitVariance = source.netProfitVariance;
        dto.currentLineCount = source.currentLineCount;
        dto.comparisonLineCount = source.comparisonLineCount;
        dto.generatedAt = source.generatedAt;
        dto.groups = new List<GroupDTO>();

        for (
            SABFinancialStatementService.ProfitLossGroup sourceGroup
            : source.groups
        ) {
            GroupDTO groupDTO = new GroupDTO();
            groupDTO.groupKey = sourceGroup.groupKey;
            groupDTO.displayOrder = sourceGroup.displayOrder;
            groupDTO.currentTotal = sourceGroup.currentTotal;
            groupDTO.comparisonTotal = sourceGroup.comparisonTotal;
            groupDTO.varianceTotal = sourceGroup.varianceTotal;
            groupDTO.rows = new List<RowDTO>();

            for (
                SABFinancialStatementService.ProfitLossRow sourceRow
                : sourceGroup.rows
            ) {
                RowDTO rowDTO = new RowDTO();
                rowDTO.rowKey = sourceRow.rowKey;
                rowDTO.groupKey = sourceRow.groupKey;
                rowDTO.displayOrder = sourceRow.displayOrder;
                rowDTO.currentAmount = sourceRow.currentAmount;
                rowDTO.comparisonAmount = sourceRow.comparisonAmount;
                rowDTO.varianceAmount = sourceRow.varianceAmount;
                rowDTO.currentLineCount = sourceRow.currentLineCount;
                rowDTO.comparisonLineCount =
                    sourceRow.comparisonLineCount;
                groupDTO.rows.add(rowDTO);
            }

            dto.groups.add(groupDTO);
        }

        return dto;
    }

    private static List<OptionDTO> loadDimensionOptions(
        String objectApiName,
        Id companyId,
        Boolean preferActiveOnly
    ) {
        List<OptionDTO> result = new List<OptionDTO>();

        Schema.SObjectType objectType =
            Schema.getGlobalDescribe().get(objectApiName);

        if (objectType == null) {
            return result;
        }

        Schema.DescribeSObjectResult objectDescribe =
            objectType.getDescribe();

        if (!objectDescribe.isAccessible()) {
            return result;
        }

        Map<String, Schema.SObjectField> fields =
            objectDescribe.fields.getMap();

        if (
            !fields.containsKey('Name') ||
            !fields.containsKey('Company__c') ||
            !fields.get('Name').getDescribe().isAccessible() ||
            !fields.get('Company__c').getDescribe().isAccessible()
        ) {
            return result;
        }

        String soql =
            'SELECT Id, Name FROM ' +
            objectApiName +
            ' WHERE Company__c = \'' +
            String.valueOf(companyId) +
            '\'';

        if (
            preferActiveOnly &&
            fields.containsKey('Is_Active__c') &&
            fields.get('Is_Active__c').getDescribe().isAccessible()
        ) {
            soql += ' AND Is_Active__c = true';
        }

        soql += ' ORDER BY Name ASC LIMIT 1000';

        for (SObject recordValue : Database.query(soql)) {
            OptionDTO item = new OptionDTO();
            item.value = String.valueOf(recordValue.get('Id'));
            item.label = String.valueOf(recordValue.get('Name'));
            result.add(item);
        }

        return result;
    }
}
