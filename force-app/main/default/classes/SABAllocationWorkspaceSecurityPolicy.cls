/**
 * G14B: Allocation Workspace CRUD/FLS read policy. Fails with one clear message before any workspace query.
 * Grant through SAB_Allocation_Workspace_User together with SAB_Allocation_User.
 */
public with sharing class SABAllocationWorkspaceSecurityPolicy {

    public static void assertReadAccess() {
        SABAccessControlService.assertReadable(Allocation_Rule__c.SObjectType, new List<Schema.SObjectField>{
            Allocation_Rule__c.Company__c, Allocation_Rule__c.Rule_Key__c, Allocation_Rule__c.Version__c, Allocation_Rule__c.Status__c,
            Allocation_Rule__c.Driver_Type__c, Allocation_Rule__c.Rounding_Policy__c, Allocation_Rule__c.Effective_From__c,
            Allocation_Rule__c.Effective_To__c, Allocation_Rule__c.Source_Filter_JSON__c});
        SABAccessControlService.assertReadable(Allocation_Rule_Line__c.SObjectType, new List<Schema.SObjectField>{
            Allocation_Rule_Line__c.Sequence__c, Allocation_Rule_Line__c.Target_GL_Account__c, Allocation_Rule_Line__c.Target_Department__c,
            Allocation_Rule_Line__c.Target_Cost_Center__c, Allocation_Rule_Line__c.Percentage__c, Allocation_Rule_Line__c.Driver_Value__c});
        SABAccessControlService.assertReadable(Allocation_Run__c.SObjectType, new List<Schema.SObjectField>{
            Allocation_Run__c.Allocation_Rule__c, Allocation_Run__c.Accounting_Period__c, Allocation_Run__c.Rule_Version__c,
            Allocation_Run__c.Status__c, Allocation_Run__c.Source_Amount_Snapshot__c, Allocation_Run__c.Calculated_Output_JSON__c,
            Allocation_Run__c.Journal_Entry__c});
        SABAccessControlService.assertReadable(GL_Account__c.SObjectType, new List<Schema.SObjectField>{
            GL_Account__c.Account_Code__c, GL_Account__c.Is_Active__c, GL_Account__c.Is_Control_Account__c});
    }
}
