/**
 * Stage 8A - Company Context Controller
 *
 * Thin UI controller for the Company Context Selector.
 *
 * Security layers:
 * 1) CRUD/FLS through SABAccessControlService.
 * 2) Company authorization through SABCompanyAccessService.
 * 3) Actual Salesforce record sharing because this class is `with sharing`.
 *
 * The selector is a convenience/context control only. Downstream financial
 * services must continue to enforce their own company/action authorization.
 */
public with sharing class SABCompanyContextController {

    public class CompanyContext {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String companyName { get; set; }
        @AuraEnabled public String companyKey { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public String setupStatus { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<CompanyContext> getAccessibleCompanies() {
        assertCompanyReadAccess();

        Set<Id> authorizedCompanyIds =
            SABCompanyAccessService.getAccessibleCompanyIds();

        if (authorizedCompanyIds.isEmpty()) {
            return new List<CompanyContext>();
        }

        List<Accounting_Company__c> companies = [
            SELECT Id,
                   Name__c,
                   Company_Key__c,
                   Functional_Currency__c,
                   Setup_Status__c,
                   Is_Active__c
            FROM Accounting_Company__c
            WHERE Id IN :authorizedCompanyIds
              AND Is_Active__c = true
            ORDER BY Name__c ASC, Company_Key__c ASC
        ];

        List<CompanyContext> results =
            new List<CompanyContext>();

        for (Accounting_Company__c company : companies) {
            results.add(toContext(company));
        }

        return results;
    }

    @AuraEnabled(cacheable=true)
    public static CompanyContext getCompanyContext(
        Id companyId
    ) {
        if (companyId == null) {
            throw new AuraHandledException(
                'Accounting Company is required.'
            );
        }

        assertCompanyReadAccess();

        try {
            SABCompanyAccessService.assertCompanyAccess(
                companyId
            );

            SABAccessControlService.assertRecordReadAccess(
                companyId
            );
        } catch (Exception ex) {
            throw new AuraHandledException(
                'You do not have active access to this Accounting Company.'
            );
        }

        List<Accounting_Company__c> companies = [
            SELECT Id,
                   Name__c,
                   Company_Key__c,
                   Functional_Currency__c,
                   Setup_Status__c,
                   Is_Active__c
            FROM Accounting_Company__c
            WHERE Id = :companyId
              AND Is_Active__c = true
            LIMIT 1
        ];

        if (companies.isEmpty()) {
            throw new AuraHandledException(
                'The selected Accounting Company is not available.'
            );
        }

        return toContext(companies[0]);
    }

    private static void assertCompanyReadAccess() {
        try {
            SABAccessControlService.assertReadable(
                Accounting_Company__c.SObjectType,
                new List<Schema.SObjectField>{
                    Accounting_Company__c.Name__c,
                    Accounting_Company__c.Company_Key__c,
                    Accounting_Company__c.Functional_Currency__c,
                    Accounting_Company__c.Setup_Status__c,
                    Accounting_Company__c.Is_Active__c
                }
            );
        } catch (
            SABAccessControlService.AccessDeniedException ex
        ) {
            throw new AuraHandledException(
                'You do not have permission to view Accounting Companies.'
            );
        }
    }

    private static CompanyContext toContext(
        Accounting_Company__c company
    ) {
        CompanyContext context =
            new CompanyContext();

        context.companyId = company.Id;
        context.companyName = company.Name__c;
        context.companyKey = company.Company_Key__c;
        context.functionalCurrency =
            company.Functional_Currency__c;
        context.setupStatus = company.Setup_Status__c;

        return context;
    }
}
