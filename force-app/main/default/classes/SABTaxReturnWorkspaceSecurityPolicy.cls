/**
 * G11: Tax Return Workspace CRUD/FLS read policy.
 * Fails with one clear message before any workspace query. Grant through SAB_Tax_Return_Workspace_User.
 */
public with sharing class SABTaxReturnWorkspaceSecurityPolicy {

    public static void assertReadAccess() {
        SABAccessControlService.assertReadable(Accounting_Company__c.SObjectType, new List<Schema.SObjectField>{
            Accounting_Company__c.Name__c, Accounting_Company__c.Functional_Currency__c});
        SABAccessControlService.assertReadable(Tax_Registration__c.SObjectType, new List<Schema.SObjectField>{
            Tax_Registration__c.Company__c, Tax_Registration__c.Jurisdiction__c, Tax_Registration__c.Registration_Identifier__c,
            Tax_Registration__c.Filing_Frequency__c, Tax_Registration__c.Effective_From__c, Tax_Registration__c.Effective_To__c,
            Tax_Registration__c.Is_Active__c});
        SABAccessControlService.assertReadable(Tax_Return__c.SObjectType, new List<Schema.SObjectField>{
            Tax_Return__c.Company__c, Tax_Return__c.Tax_Registration__c, Tax_Return__c.Period_Start__c, Tax_Return__c.Period_End__c,
            Tax_Return__c.Return_Version__c, Tax_Return__c.Status__c, Tax_Return__c.Country_Pack_Version__c,
            Tax_Return__c.Filing_Reference__c, Tax_Return__c.Acknowledgement_Reference__c, Tax_Return__c.Locked_Source_Hash__c,
            Tax_Return__c.Amends_Tax_Return__c});
        SABAccessControlService.assertReadable(Tax_Return_Line__c.SObjectType, new List<Schema.SObjectField>{
            Tax_Return_Line__c.Box_Key__c, Tax_Return_Line__c.Label__c, Tax_Return_Line__c.Calculated_Amount__c,
            Tax_Return_Line__c.Adjustment_Amount__c, Tax_Return_Line__c.Final_Amount__c});
    }
}
