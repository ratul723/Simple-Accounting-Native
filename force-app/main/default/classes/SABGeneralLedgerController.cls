/**
 * G2B - General Ledger Lightning controller.
 *
 * Thin UI wrapper around SABLedgerReportService.getGeneralLedger().
 */
public with sharing class SABGeneralLedgerController {

    public class OptionDTO {
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public Id value { get; set; }
    }

    public class PeriodOptionDTO {
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public Id value { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date endDate { get; set; }
    }

    public class FilterDTO {
        @AuraEnabled public List<PeriodOptionDTO> periods { get; set; }
        @AuraEnabled public List<OptionDTO> accounts { get; set; }
    }

    public class LineDTO {
        @AuraEnabled public Id journalLineId { get; set; }
        @AuraEnabled public Id journalId { get; set; }
        @AuraEnabled public String journalName { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String entryType { get; set; }
        @AuraEnabled public String journalStatus { get; set; }
        @AuraEnabled public String postingKey { get; set; }
        @AuraEnabled public Decimal lineNumber { get; set; }
        @AuraEnabled public String explanation { get; set; }
        @AuraEnabled public Decimal debit { get; set; }
        @AuraEnabled public Decimal credit { get; set; }
        @AuraEnabled public Decimal runningDebit { get; set; }
        @AuraEnabled public Decimal runningCredit { get; set; }
    }

    public class AccountDTO {
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

        @AuraEnabled public Integer movementLineCount { get; set; }
        @AuraEnabled public Integer displayedLineCount { get; set; }

        @AuraEnabled public List<LineDTO> lines { get; set; }
    }

    public class GeneralLedgerDTO {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String companyName { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public Date fromDate { get; set; }
        @AuraEnabled public Date toDate { get; set; }
        @AuraEnabled public Id glAccountId { get; set; }
        @AuraEnabled public Datetime generatedAt { get; set; }

        @AuraEnabled public Boolean fullLedgerScope { get; set; }
        @AuraEnabled public Boolean balanced { get; set; }
        @AuraEnabled public Boolean truncated { get; set; }

        @AuraEnabled public Integer accountCount { get; set; }
        @AuraEnabled public Integer totalMovementLineCount { get; set; }
        @AuraEnabled public Integer displayedLineCount { get; set; }

        @AuraEnabled public Decimal totalOpeningDebit { get; set; }
        @AuraEnabled public Decimal totalOpeningCredit { get; set; }
        @AuraEnabled public Decimal totalMovementDebit { get; set; }
        @AuraEnabled public Decimal totalMovementCredit { get; set; }
        @AuraEnabled public Decimal totalClosingDebit { get; set; }
        @AuraEnabled public Decimal totalClosingCredit { get; set; }

        @AuraEnabled public Decimal openingDifference { get; set; }
        @AuraEnabled public Decimal movementDifference { get; set; }
        @AuraEnabled public Decimal closingDifference { get; set; }

        @AuraEnabled public List<AccountDTO> accounts { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static FilterDTO getFilters(
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
                Accounting_Period__c.End_Date__c
            }
        );

        SABAccessControlService.assertReadable(
            GL_Account__c.SObjectType,
            new List<Schema.SObjectField>{
                GL_Account__c.Company__c,
                GL_Account__c.Account_Code__c,
                GL_Account__c.Is_Active__c
            }
        );

        FilterDTO result =
            new FilterDTO();

        result.periods =
            new List<PeriodOptionDTO>();

        for (Accounting_Period__c period : [
            SELECT Id,
                   Name,
                   Start_Date__c,
                   End_Date__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
            ORDER BY Start_Date__c DESC
            LIMIT 250
        ]) {
            PeriodOptionDTO option =
                new PeriodOptionDTO();

            option.value =
                period.Id;
            option.label =
                period.Name
                + ' · '
                + String.valueOf(
                    period.Start_Date__c
                )
                + ' to '
                + String.valueOf(
                    period.End_Date__c
                );
            option.startDate =
                period.Start_Date__c;
            option.endDate =
                period.End_Date__c;

            result.periods.add(
                option
            );
        }

        result.accounts =
            new List<OptionDTO>();

        for (GL_Account__c account : [
            SELECT Id,
                   Account_Code__c,
                   Name,
                   Is_Active__c
            FROM GL_Account__c
            WHERE Company__c = :companyId
            ORDER BY Account_Code__c ASC,
                     Name ASC
            LIMIT 2000
        ]) {
            OptionDTO option =
                new OptionDTO();

            option.value =
                account.Id;
            option.label =
                account.Account_Code__c
                + ' · '
                + account.Name
                + (
                    account.Is_Active__c
                        ? ''
                        : ' · Inactive'
                );

            result.accounts.add(
                option
            );
        }

        return result;
    }

    @AuraEnabled
    public static GeneralLedgerDTO runGeneralLedger(
        Id companyId,
        Date fromDate,
        Date toDate,
        Id glAccountId
    ) {
        try {
            SABLedgerReportService.GeneralLedgerRequest request =
                new SABLedgerReportService.GeneralLedgerRequest();

            request.companyId =
                companyId;
            request.fromDate =
                fromDate;
            request.toDate =
                toDate;
            request.glAccountId =
                glAccountId;

            return toDTO(
                SABLedgerReportService.getGeneralLedger(
                    request
                )
            );
        } catch (Exception ex) {
            throw new AuraHandledException(
                ex.getMessage()
            );
        }
    }

    private static GeneralLedgerDTO toDTO(
        SABLedgerReportService.GeneralLedgerResult source
    ) {
        GeneralLedgerDTO dto =
            new GeneralLedgerDTO();

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
        dto.glAccountId =
            source.glAccountId;
        dto.generatedAt =
            source.generatedAt;

        dto.fullLedgerScope =
            source.fullLedgerScope;
        dto.balanced =
            source.balanced;
        dto.truncated =
            source.truncated;

        dto.accountCount =
            source.accountCount;
        dto.totalMovementLineCount =
            source.totalMovementLineCount;
        dto.displayedLineCount =
            source.displayedLineCount;

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

        dto.accounts =
            new List<AccountDTO>();

        for (
            SABLedgerReportService.GeneralLedgerAccount sourceAccount
            : source.accounts
        ) {
            AccountDTO account =
                new AccountDTO();

            account.glAccountId =
                sourceAccount.glAccountId;
            account.accountCode =
                sourceAccount.accountCode;
            account.accountName =
                sourceAccount.accountName;
            account.accountType =
                sourceAccount.accountType;
            account.normalBalance =
                sourceAccount.normalBalance;
            account.active =
                sourceAccount.active;

            account.openingDebit =
                sourceAccount.openingDebit;
            account.openingCredit =
                sourceAccount.openingCredit;
            account.movementDebit =
                sourceAccount.movementDebit;
            account.movementCredit =
                sourceAccount.movementCredit;
            account.closingDebit =
                sourceAccount.closingDebit;
            account.closingCredit =
                sourceAccount.closingCredit;

            account.movementLineCount =
                sourceAccount.movementLineCount;
            account.displayedLineCount =
                sourceAccount.displayedLineCount;

            account.lines =
                new List<LineDTO>();

            for (
                SABLedgerReportService.GeneralLedgerLine sourceLine
                : sourceAccount.lines
            ) {
                LineDTO line =
                    new LineDTO();

                line.journalLineId =
                    sourceLine.journalLineId;
                line.journalId =
                    sourceLine.journalId;
                line.journalName =
                    sourceLine.journalName;
                line.accountingDate =
                    sourceLine.accountingDate;
                line.entryType =
                    sourceLine.entryType;
                line.journalStatus =
                    sourceLine.journalStatus;
                line.postingKey =
                    sourceLine.postingKey;
                line.lineNumber =
                    sourceLine.lineNumber;
                line.explanation =
                    sourceLine.explanation;
                line.debit =
                    sourceLine.debit;
                line.credit =
                    sourceLine.credit;
                line.runningDebit =
                    sourceLine.runningDebit;
                line.runningCredit =
                    sourceLine.runningCredit;

                account.lines.add(
                    line
                );
            }

            dto.accounts.add(
                account
            );
        }

        return dto;
    }
}
