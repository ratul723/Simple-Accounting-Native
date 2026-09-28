/**
 * G4D - AR Aging Lightning controller.
 *
 * Thin UI wrapper around SABARAgingService.
 */
public with sharing class SABARAgingController {

    public class CustomerOptionDTO {
        @AuraEnabled public Id value { get; set; }
        @AuraEnabled public String label { get; set; }
    }

    public class AgingRowDTO {
        @AuraEnabled public Id invoiceId { get; set; }
        @AuraEnabled public String legalNumber { get; set; }
        @AuraEnabled public Id partyProfileId { get; set; }
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public String customerName { get; set; }

        @AuraEnabled public Date documentDate { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public Date dueDate { get; set; }
        @AuraEnabled public Integer daysPastDue { get; set; }
        @AuraEnabled public String agingBucket { get; set; }

        @AuraEnabled public String transactionCurrency { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public Decimal exchangeRate { get; set; }

        @AuraEnabled public Decimal originalDocumentAmount { get; set; }
        @AuraEnabled public Decimal allocatedDocumentAmount { get; set; }
        @AuraEnabled public Decimal creditedDocumentAmount { get; set; }
        @AuraEnabled public Decimal outstandingDocumentAmount { get; set; }

        @AuraEnabled public Decimal originalBaseAmount { get; set; }
        @AuraEnabled public Decimal allocatedBaseAmount { get; set; }
        @AuraEnabled public Decimal creditedBaseAmount { get; set; }
        @AuraEnabled public Decimal outstandingBaseAmount { get; set; }
    }

    public class CustomerSummaryDTO {
        @AuraEnabled public Id partyProfileId { get; set; }
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public String customerName { get; set; }

        @AuraEnabled public Decimal currentAmount { get; set; }
        @AuraEnabled public Decimal days1To30Amount { get; set; }
        @AuraEnabled public Decimal days31To60Amount { get; set; }
        @AuraEnabled public Decimal days61To90Amount { get; set; }
        @AuraEnabled public Decimal days91PlusAmount { get; set; }
        @AuraEnabled public Decimal totalOutstanding { get; set; }

        @AuraEnabled public Integer openInvoiceCount { get; set; }
    }

    public class AgingDTO {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String companyName { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public Date asOfDate { get; set; }
        @AuraEnabled public Datetime generatedAt { get; set; }
        @AuraEnabled public Boolean truncated { get; set; }

        @AuraEnabled public Decimal currentAmount { get; set; }
        @AuraEnabled public Decimal days1To30Amount { get; set; }
        @AuraEnabled public Decimal days31To60Amount { get; set; }
        @AuraEnabled public Decimal days61To90Amount { get; set; }
        @AuraEnabled public Decimal days91PlusAmount { get; set; }
        @AuraEnabled public Decimal totalOutstanding { get; set; }

        @AuraEnabled public Integer openInvoiceCount { get; set; }

        @AuraEnabled public List<AgingRowDTO> rows { get; set; }
        @AuraEnabled public List<CustomerSummaryDTO> customers { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<CustomerOptionDTO> getCustomers(
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
            Party_Accounting_Profile__c.SObjectType,
            new List<Schema.SObjectField>{
                Party_Accounting_Profile__c.Company__c,
                Party_Accounting_Profile__c.Account__c,
                Party_Accounting_Profile__c.Is_Customer__c,
                Party_Accounting_Profile__c.Is_Active__c
            }
        );

        SABAccessControlService.assertReadable(
            Account.SObjectType,
            new List<Schema.SObjectField>{
                Account.Name
            }
        );

        List<CustomerOptionDTO> result =
            new List<CustomerOptionDTO>();

        for (Party_Accounting_Profile__c profile : [
            SELECT Id,
                   Account__c,
                   Account__r.Name,
                   Is_Active__c
            FROM Party_Accounting_Profile__c
            WHERE Company__c = :companyId
              AND Is_Customer__c = true
            ORDER BY Account__r.Name ASC
            LIMIT 2000
        ]) {
            CustomerOptionDTO option =
                new CustomerOptionDTO();

            option.value =
                profile.Id;
            option.label =
                profile.Account__r == null
                    ? String.valueOf(profile.Id)
                    : profile.Account__r.Name
                        + (
                            profile.Is_Active__c
                                ? ''
                                : ' · Inactive'
                        );

            result.add(
                option
            );
        }

        return result;
    }

    @AuraEnabled
    public static AgingDTO runAging(
        Id companyId,
        Date asOfDate,
        Id partyProfileId,
        Boolean includeSettled
    ) {
        try {
            SABARAgingService.ARAgingRequest request =
                new SABARAgingService.ARAgingRequest();

            request.companyId =
                companyId;
            request.asOfDate =
                asOfDate;
            request.partyProfileId =
                partyProfileId;
            request.includeSettled =
                includeSettled;

            return toDTO(
                SABARAgingService.getAging(
                    request
                )
            );
        } catch (Exception ex) {
            throw new AuraHandledException(
                ex.getMessage()
            );
        }
    }

    private static AgingDTO toDTO(
        SABARAgingService.ARAgingResult source
    ) {
        AgingDTO dto =
            new AgingDTO();

        dto.companyId =
            source.companyId;
        dto.companyName =
            source.companyName;
        dto.functionalCurrency =
            source.functionalCurrency;
        dto.asOfDate =
            source.asOfDate;
        dto.generatedAt =
            source.generatedAt;
        dto.truncated =
            source.truncated;

        dto.currentAmount =
            source.currentAmount;
        dto.days1To30Amount =
            source.days1To30Amount;
        dto.days31To60Amount =
            source.days31To60Amount;
        dto.days61To90Amount =
            source.days61To90Amount;
        dto.days91PlusAmount =
            source.days91PlusAmount;
        dto.totalOutstanding =
            source.totalOutstanding;
        dto.openInvoiceCount =
            source.openInvoiceCount;

        dto.rows =
            new List<AgingRowDTO>();

        for (
            SABARAgingService.ARAgingRow sourceRow :
            source.rows
        ) {
            AgingRowDTO row =
                new AgingRowDTO();

            row.invoiceId =
                sourceRow.invoiceId;
            row.legalNumber =
                sourceRow.legalNumber;
            row.partyProfileId =
                sourceRow.partyProfileId;
            row.accountId =
                sourceRow.accountId;
            row.customerName =
                sourceRow.customerName;
            row.documentDate =
                sourceRow.documentDate;
            row.accountingDate =
                sourceRow.accountingDate;
            row.dueDate =
                sourceRow.dueDate;
            row.daysPastDue =
                sourceRow.daysPastDue;
            row.agingBucket =
                sourceRow.agingBucket;
            row.transactionCurrency =
                sourceRow.transactionCurrency;
            row.functionalCurrency =
                sourceRow.functionalCurrency;
            row.exchangeRate =
                sourceRow.exchangeRate;

            row.originalDocumentAmount =
                sourceRow.originalDocumentAmount;
            row.allocatedDocumentAmount =
                sourceRow.allocatedDocumentAmount;
            row.creditedDocumentAmount =
                sourceRow.creditedDocumentAmount;
            row.outstandingDocumentAmount =
                sourceRow.outstandingDocumentAmount;

            row.originalBaseAmount =
                sourceRow.originalBaseAmount;
            row.allocatedBaseAmount =
                sourceRow.allocatedBaseAmount;
            row.creditedBaseAmount =
                sourceRow.creditedBaseAmount;
            row.outstandingBaseAmount =
                sourceRow.outstandingBaseAmount;

            dto.rows.add(
                row
            );
        }

        dto.customers =
            new List<CustomerSummaryDTO>();

        for (
            SABARAgingService.CustomerSummary sourceSummary :
            source.customers
        ) {
            CustomerSummaryDTO summary =
                new CustomerSummaryDTO();

            summary.partyProfileId =
                sourceSummary.partyProfileId;
            summary.accountId =
                sourceSummary.accountId;
            summary.customerName =
                sourceSummary.customerName;
            summary.currentAmount =
                sourceSummary.currentAmount;
            summary.days1To30Amount =
                sourceSummary.days1To30Amount;
            summary.days31To60Amount =
                sourceSummary.days31To60Amount;
            summary.days61To90Amount =
                sourceSummary.days61To90Amount;
            summary.days91PlusAmount =
                sourceSummary.days91PlusAmount;
            summary.totalOutstanding =
                sourceSummary.totalOutstanding;
            summary.openInvoiceCount =
                sourceSummary.openInvoiceCount;

            dto.customers.add(
                summary
            );
        }

        return dto;
    }
}
