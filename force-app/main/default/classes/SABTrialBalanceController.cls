/**
 * G2A Trial Balance Lightning controller.
 *
 * Thin UI wrapper over SABLedgerReportService.
 */
public with sharing class SABTrialBalanceController {

    public class PeriodOptionDTO {
        @AuraEnabled public Id value { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date endDate { get; set; }

        public PeriodOptionDTO(
            Accounting_Period__c period
        ) {
            value =
                period.Id;
            label =
                period.Name
                + ' · '
                + String.valueOf(
                    period.Start_Date__c
                )
                + ' to '
                + String.valueOf(
                    period.End_Date__c
                );
            startDate =
                period.Start_Date__c;
            endDate =
                period.End_Date__c;
        }
    }

    public class TrialBalanceRowDTO {
        @AuraEnabled public Id glAccountId { get; set; }
        @AuraEnabled public String accountCode { get; set; }
        @AuraEnabled public String accountName { get; set; }
        @AuraEnabled public String accountType { get; set; }
        @AuraEnabled public String normalBalance { get; set; }
        @AuraEnabled public Boolean active { get; set; }

        @AuraEnabled public Decimal openingDebit { get; set; }
        @AuraEnabled public Decimal openingCredit { get; set; }
        @AuraEnabled public Decimal movementDebit { get; set; }
        @AuraEnabled public Decimal movementCredit { get; set; }
        @AuraEnabled public Decimal closingDebit { get; set; }
        @AuraEnabled public Decimal closingCredit { get; set; }
    }

    public class TrialBalanceDTO {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String companyName { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public Date fromDate { get; set; }
        @AuraEnabled public Date toDate { get; set; }
        @AuraEnabled public Datetime generatedAt { get; set; }
        @AuraEnabled public Boolean balanced { get; set; }

        @AuraEnabled public List<TrialBalanceRowDTO> rows { get; set; }

        @AuraEnabled public Decimal totalOpeningDebit { get; set; }
        @AuraEnabled public Decimal totalOpeningCredit { get; set; }
        @AuraEnabled public Decimal totalMovementDebit { get; set; }
        @AuraEnabled public Decimal totalMovementCredit { get; set; }
        @AuraEnabled public Decimal totalClosingDebit { get; set; }
        @AuraEnabled public Decimal totalClosingCredit { get; set; }

        @AuraEnabled public Decimal openingDifference { get; set; }
        @AuraEnabled public Decimal movementDifference { get; set; }
        @AuraEnabled public Decimal closingDifference { get; set; }
    }

    public class LedgerLineDTO {
        @AuraEnabled public Id journalLineId { get; set; }
        @AuraEnabled public Id journalId { get; set; }
        @AuraEnabled public String journalName { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String entryType { get; set; }
        @AuraEnabled public String journalStatus { get; set; }
        @AuraEnabled public Decimal lineNumber { get; set; }
        @AuraEnabled public Decimal debit { get; set; }
        @AuraEnabled public Decimal credit { get; set; }
        @AuraEnabled public String explanation { get; set; }
        @AuraEnabled public String postingKey { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<PeriodOptionDTO> getPeriods(
        Id companyId
    ) {
        if (companyId == null) {
            throw new AuraHandledException(
                'Accounting Company is required.'
            );
        }

        SABCompanyAccessService.assertCompanyAccess(
            companyId
        );

        SABAccessControlService.assertReadable(
            Accounting_Period__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Period__c.Company__c,
                Accounting_Period__c.Start_Date__c,
                Accounting_Period__c.End_Date__c,
                Accounting_Period__c.Status__c
            }
        );

        List<PeriodOptionDTO> result =
            new List<PeriodOptionDTO>();

        for (Accounting_Period__c period : [
            SELECT Id,
                   Name,
                   Start_Date__c,
                   End_Date__c,
                   Status__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
            ORDER BY Start_Date__c DESC
            LIMIT 250
        ]) {
            result.add(
                new PeriodOptionDTO(
                    period
                )
            );
        }

        return result;
    }

    @AuraEnabled
    public static TrialBalanceDTO runTrialBalance(
        Id companyId,
        Date fromDate,
        Date toDate,
        Boolean includeZeroBalance
    ) {
        try {
            SABLedgerReportService.TrialBalanceRequest request =
                new SABLedgerReportService.TrialBalanceRequest();

            request.companyId =
                companyId;
            request.fromDate =
                fromDate;
            request.toDate =
                toDate;
            request.includeZeroBalance =
                includeZeroBalance;

            SABLedgerReportService.TrialBalanceResult serviceResult =
                SABLedgerReportService.getTrialBalance(
                    request
                );

            return toDTO(
                serviceResult
            );
        } catch (Exception ex) {
            throw new AuraHandledException(
                ex.getMessage()
            );
        }
    }

    @AuraEnabled
    public static List<LedgerLineDTO> getMovementLines(
        Id companyId,
        Id glAccountId,
        Date fromDate,
        Date toDate
    ) {
        try {
            List<LedgerLineDTO> result =
                new List<LedgerLineDTO>();

            for (
                SABLedgerReportService.LedgerLine line
                : SABLedgerReportService.getAccountMovementLines(
                    companyId,
                    glAccountId,
                    fromDate,
                    toDate
                )
            ) {
                LedgerLineDTO dto =
                    new LedgerLineDTO();

                dto.journalLineId =
                    line.journalLineId;
                dto.journalId =
                    line.journalId;
                dto.journalName =
                    line.journalName;
                dto.accountingDate =
                    line.accountingDate;
                dto.entryType =
                    line.entryType;
                dto.journalStatus =
                    line.journalStatus;
                dto.lineNumber =
                    line.lineNumber;
                dto.debit =
                    line.debit;
                dto.credit =
                    line.credit;
                dto.explanation =
                    line.explanation;
                dto.postingKey =
                    line.postingKey;

                result.add(
                    dto
                );
            }

            return result;
        } catch (Exception ex) {
            throw new AuraHandledException(
                ex.getMessage()
            );
        }
    }

    private static TrialBalanceDTO toDTO(
        SABLedgerReportService.TrialBalanceResult source
    ) {
        TrialBalanceDTO dto =
            new TrialBalanceDTO();

        dto.companyId =
            source.companyId;
        dto.companyName =
            source.companyName;
        dto.functionalCurrency =
            source.functionalCurrency;
        dto.fromDate =
            source.fromDate;
        dto.toDate =
            source.toDate;
        dto.generatedAt =
            source.generatedAt;
        dto.balanced =
            source.balanced;

        dto.totalOpeningDebit =
            source.totalOpeningDebit;
        dto.totalOpeningCredit =
            source.totalOpeningCredit;
        dto.totalMovementDebit =
            source.totalMovementDebit;
        dto.totalMovementCredit =
            source.totalMovementCredit;
        dto.totalClosingDebit =
            source.totalClosingDebit;
        dto.totalClosingCredit =
            source.totalClosingCredit;

        dto.openingDifference =
            source.openingDifference;
        dto.movementDifference =
            source.movementDifference;
        dto.closingDifference =
            source.closingDifference;

        dto.rows =
            new List<TrialBalanceRowDTO>();

        for (
            SABLedgerReportService.TrialBalanceRow row
            : source.rows
        ) {
            TrialBalanceRowDTO rowDTO =
                new TrialBalanceRowDTO();

            rowDTO.glAccountId =
                row.glAccountId;
            rowDTO.accountCode =
                row.accountCode;
            rowDTO.accountName =
                row.accountName;
            rowDTO.accountType =
                row.accountType;
            rowDTO.normalBalance =
                row.normalBalance;
            rowDTO.active =
                row.active;

            rowDTO.openingDebit =
                row.openingDebit;
            rowDTO.openingCredit =
                row.openingCredit;
            rowDTO.movementDebit =
                row.movementDebit;
            rowDTO.movementCredit =
                row.movementCredit;
            rowDTO.closingDebit =
                row.closingDebit;
            rowDTO.closingCredit =
                row.closingCredit;

            dto.rows.add(
                rowDTO
            );
        }

        return dto;
    }
}
