/**
 * G10G: Payroll & HR Workspace CRUD/FLS read policy.
 *
 * Fails with one clear message before any workspace query instead of a partial user-mode error.
 * Grant these through SAB_Payroll_Workspace_User.
 */
public with sharing class SABPayrollWorkspaceSecurityPolicy {

    public static void assertWorkspaceReadAccess() {
        SABAccessControlService.assertReadable(Accounting_Company__c.SObjectType, new List<Schema.SObjectField>{
            Accounting_Company__c.Name__c, Accounting_Company__c.Functional_Currency__c});
        SABAccessControlService.assertReadable(Payroll_Run__c.SObjectType, new List<Schema.SObjectField>{
            Payroll_Run__c.Company__c, Payroll_Run__c.Run_Key__c, Payroll_Run__c.Pay_Period_Start__c,
            Payroll_Run__c.Pay_Period_End__c, Payroll_Run__c.Workflow_State__c, Payroll_Run__c.Currency__c,
            Payroll_Run__c.Gross_Total__c, Payroll_Run__c.Deduction_Total__c, Payroll_Run__c.Employer_Total__c,
            Payroll_Run__c.Net_Total__c, Payroll_Run__c.Settled_Amount__c, Payroll_Run__c.Accounting_Date__c,
            Payroll_Run__c.Settlement_Payment__c});
        SABAccessControlService.assertReadable(Payroll_Line__c.SObjectType, new List<Schema.SObjectField>{
            Payroll_Line__c.Employment__c, Payroll_Line__c.Gross_Amount__c, Payroll_Line__c.Deduction_Amount__c,
            Payroll_Line__c.Employer_Contribution__c, Payroll_Line__c.Net_Amount__c});
        SABAccessControlService.assertReadable(Payroll_Component_Line__c.SObjectType, new List<Schema.SObjectField>{
            Payroll_Component_Line__c.Benefit_Award__c, Payroll_Component_Line__c.Component_Category__c,
            Payroll_Component_Line__c.Amount__c});
        SABAccessControlService.assertReadable(Employment__c.SObjectType, new List<Schema.SObjectField>{
            Employment__c.Company__c, Employment__c.Employee__c, Employment__c.Department__c, Employment__c.Employment_Status__c});
        SABAccessControlService.assertReadable(Employee__c.SObjectType, new List<Schema.SObjectField>{
            Employee__c.Employee_Reference__c});
        SABAccessControlService.assertReadable(Accounting_Period__c.SObjectType, new List<Schema.SObjectField>{
            Accounting_Period__c.Company__c, Accounting_Period__c.Period_Key__c, Accounting_Period__c.Start_Date__c,
            Accounting_Period__c.End_Date__c, Accounting_Period__c.Status__c});
        SABAccessControlService.assertReadable(GL_Account__c.SObjectType, new List<Schema.SObjectField>{
            GL_Account__c.Company__c, GL_Account__c.Account_Code__c, GL_Account__c.Account_Type__c, GL_Account__c.Is_Active__c});
        SABAccessControlService.assertReadable(Bank_Account__c.SObjectType, new List<Schema.SObjectField>{
            Bank_Account__c.Company__c, Bank_Account__c.Currency__c, Bank_Account__c.Is_Active__c});
        SABAccessControlService.assertReadable(Accounting_Payment__c.SObjectType, new List<Schema.SObjectField>{
            Accounting_Payment__c.Processing_State__c, Accounting_Payment__c.Amount__c, Accounting_Payment__c.Effective_Date__c,
            Accounting_Payment__c.Method__c, Accounting_Payment__c.Reference__c, Accounting_Payment__c.Provider_Request_Key__c,
            Accounting_Payment__c.Bank_Account__c});
        SABAccessControlService.assertReadable(Benefit_Award__c.SObjectType, new List<Schema.SObjectField>{
            Benefit_Award__c.Award_Key__c});
    }

    public static void assertHrReadAccess() {
        SABAccessControlService.assertReadable(Employee_Pay_Component__c.SObjectType, new List<Schema.SObjectField>{
            Employee_Pay_Component__c.Employment__c, Employee_Pay_Component__c.Pay_Component__c, Employee_Pay_Component__c.Amount__c,
            Employee_Pay_Component__c.Currency__c, Employee_Pay_Component__c.Effective_From__c,
            Employee_Pay_Component__c.Effective_To__c, Employee_Pay_Component__c.Status__c});
        SABAccessControlService.assertReadable(Benefit_Award__c.SObjectType, new List<Schema.SObjectField>{
            Benefit_Award__c.Employment__c, Benefit_Award__c.Pay_Component__c, Benefit_Award__c.Award_Key__c,
            Benefit_Award__c.Amount__c, Benefit_Award__c.Currency__c, Benefit_Award__c.Service_Period_Start__c,
            Benefit_Award__c.Service_Period_End__c, Benefit_Award__c.Status__c, Benefit_Award__c.Consumed_By_Payroll_Run__c});
        SABAccessControlService.assertReadable(Pay_Component__c.SObjectType, new List<Schema.SObjectField>{
            Pay_Component__c.Category__c});
        SABAccessControlService.assertReadable(Employment__c.SObjectType, new List<Schema.SObjectField>{
            Employment__c.Company__c, Employment__c.Employee__c});
        SABAccessControlService.assertReadable(Employee__c.SObjectType, new List<Schema.SObjectField>{
            Employee__c.Employee_Reference__c});
    }
}
