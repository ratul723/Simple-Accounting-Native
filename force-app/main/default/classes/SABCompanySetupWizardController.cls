/**
 * Stage 8G - Company Setup Wizard UI controller.
 *
 * Thin read-only UI wrapper around the existing SABCompanySetupService.
 *
 * The current authoritative service validates the core configuration that the
 * existing schema can actually prove:
 * - company state / currency / fiscal start / rounding account;
 * - accounting periods;
 * - chart of accounts;
 * - document sequences;
 * - enabled company features.
 *
 * It intentionally does NOT invent localization-registry or opening-balance
 * contracts that are not yet implemented in the authoritative metadata.
 */
public with sharing class SABCompanySetupWizardController {

    public class SetupStateDTO {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String companyName { get; set; }
        @AuraEnabled public String companyKey { get; set; }
        @AuraEnabled public String countryCode { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public String fiscalCalendarType { get; set; }
        @AuraEnabled public Decimal fiscalYearStartMonth { get; set; }
        @AuraEnabled public String setupStatus { get; set; }
        @AuraEnabled public Boolean companyActive { get; set; }
        @AuraEnabled public String createdSetupVersion { get; set; }
        @AuraEnabled public String countryPackVersion { get; set; }

        @AuraEnabled public Boolean readyForCoreAccounting { get; set; }
        @AuraEnabled public List<String> errors { get; set; }
        @AuraEnabled public List<String> warnings { get; set; }

        @AuraEnabled public Integer periodCount { get; set; }
        @AuraEnabled public Integer openPeriodCount { get; set; }
        @AuraEnabled public Integer activeGLAccountCount { get; set; }
        @AuraEnabled public Integer activeSequenceCount { get; set; }
        @AuraEnabled public Integer enabledFeatureCount { get; set; }
    }

    @AuraEnabled
    public static SetupStateDTO getSetupState(
        Id companyId
    ) {
        if (companyId == null) {
            throw new AuraHandledException(
                'Select an Accounting Company before using the Setup Wizard.'
            );
        }

        SABCompanyAccessService.assertCompanyAccess(
            companyId
        );

        assertCompanyReadAccess();

        Accounting_Company__c company = [
            SELECT Id,
                   Name__c,
                   Company_Key__c,
                   Country_Code__c,
                   Functional_Currency__c,
                   Fiscal_Calendar_Type__c,
                   Fiscal_Year_Start_Month__c,
                   Setup_Status__c,
                   Is_Active__c,
                   Created_Setup_Version__c,
                   Country_Pack_Version__c
            FROM Accounting_Company__c
            WHERE Id = :companyId
            LIMIT 1
        ];

        SABAccessControlService.assertRecordReadAccess(
            company.Id
        );

        SABCompanySetupService.SetupResult setupResult;

        try {
            setupResult =
                SABCompanySetupService.validateCoreSetup(
                    companyId
                );
        } catch (Exception ex) {
            throw new AuraHandledException(
                ex.getMessage()
            );
        }

        SetupStateDTO dto =
            new SetupStateDTO();

        dto.companyId =
            company.Id;
        dto.companyName =
            company.Name__c;
        dto.companyKey =
            company.Company_Key__c;
        dto.countryCode =
            company.Country_Code__c;
        dto.functionalCurrency =
            company.Functional_Currency__c;
        dto.fiscalCalendarType =
            company.Fiscal_Calendar_Type__c;
        dto.fiscalYearStartMonth =
            company.Fiscal_Year_Start_Month__c;
        dto.setupStatus =
            company.Setup_Status__c;
        dto.companyActive =
            company.Is_Active__c;
        dto.createdSetupVersion =
            company.Created_Setup_Version__c;
        dto.countryPackVersion =
            company.Country_Pack_Version__c;

        dto.readyForCoreAccounting =
            setupResult.readyForCoreAccounting;
        dto.errors =
            setupResult.errors;
        dto.warnings =
            setupResult.warnings;
        dto.periodCount =
            setupResult.periodCount;
        dto.openPeriodCount =
            setupResult.openPeriodCount;
        dto.activeGLAccountCount =
            setupResult.activeGLAccountCount;
        dto.activeSequenceCount =
            setupResult.activeSequenceCount;
        dto.enabledFeatureCount =
            setupResult.enabledFeatureCount;

        return dto;
    }

    private static void assertCompanyReadAccess() {
        SABAccessControlService.assertReadable(
            Accounting_Company__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Company__c.Name__c,
                Accounting_Company__c.Company_Key__c,
                Accounting_Company__c.Country_Code__c,
                Accounting_Company__c.Functional_Currency__c,
                Accounting_Company__c.Fiscal_Calendar_Type__c,
                Accounting_Company__c.Fiscal_Year_Start_Month__c,
                Accounting_Company__c.Setup_Status__c,
                Accounting_Company__c.Is_Active__c,
                Accounting_Company__c.Created_Setup_Version__c,
                Accounting_Company__c.Country_Pack_Version__c
            }
        );
    }
}
