/**
 * G8E - Expense Management workspace CRUD/FLS read policy.
 */
public with sharing class SABExpenseSecurityPolicy {

    public static void assertWorkspaceReadAccess() {
        SABAccessControlService.assertReadable(
            Accounting_Company__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Company__c.Name__c,
                Accounting_Company__c.Functional_Currency__c
            }
        );

        SABAccessControlService.assertReadable(
            Expense_Claim__c.SObjectType,
            new List<Schema.SObjectField>{
                Expense_Claim__c.Company__c,
                Expense_Claim__c.Claimant_Employment__c,
                Expense_Claim__c.Claim_Date__c,
                Expense_Claim__c.Accounting_Date__c,
                Expense_Claim__c.Currency__c,
                Expense_Claim__c.Status__c,
                Expense_Claim__c.Total__c,
                Expense_Claim__c.Approval_Request__c,
                Expense_Claim__c.Accounting_Event__c
            }
        );

        SABAccessControlService.assertReadable(
            Expense_Claim_Line__c.SObjectType,
            new List<Schema.SObjectField>{
                Expense_Claim_Line__c.Expense_Claim__c,
                Expense_Claim_Line__c.Expense_Date__c,
                Expense_Claim_Line__c.Category__c,
                Expense_Claim_Line__c.Description__c,
                Expense_Claim_Line__c.Amount__c,
                Expense_Claim_Line__c.Expense_Account__c,
                Expense_Claim_Line__c.Tax_Code__c,
                Expense_Claim_Line__c.Tax_Rate_Percent__c,
                Expense_Claim_Line__c.Taxable_Base__c,
                Expense_Claim_Line__c.Tax_Amount__c,
                Expense_Claim_Line__c.Recoverable_Tax_Amount__c,
                Expense_Claim_Line__c.Nonrecoverable_Tax_Amount__c,
                Expense_Claim_Line__c.Tax_Treatment__c,
                Expense_Claim_Line__c.Tax_Jurisdiction__c,
                Expense_Claim_Line__c.Department__c,
                Expense_Claim_Line__c.Project__c
            }
        );

        SABAccessControlService.assertReadable(
            Claim_Settlement__c.SObjectType,
            new List<Schema.SObjectField>{
                Claim_Settlement__c.Expense_Claim__c,
                Claim_Settlement__c.Payment__c,
                Claim_Settlement__c.Allocated_Amount__c,
                Claim_Settlement__c.Effective_Date__c,
                Claim_Settlement__c.Settlement_Key__c,
                Claim_Settlement__c.Status__c,
                Claim_Settlement__c.Reversal_Of__c
            }
        );

        SABAccessControlService.assertReadable(
            Accounting_Payment__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Payment__c.Company__c,
                Accounting_Payment__c.Reference__c,
                Accounting_Payment__c.Direction__c,
                Accounting_Payment__c.Processing_State__c,
                Accounting_Payment__c.Amount__c,
                Accounting_Payment__c.Transaction_Currency__c,
                Accounting_Payment__c.Effective_Date__c,
                Accounting_Payment__c.Bank_Account__c,
                Accounting_Payment__c.Party_Profile__c,
                Accounting_Payment__c.Provider_Request_Key__c,
                Accounting_Payment__c.Accounting_Event__c
            }
        );

        SABAccessControlService.assertReadable(
            Accounting_Event__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Event__c.Journal_Entry__c
            }
        );

        SABAccessControlService.assertReadable(
            Employment__c.SObjectType,
            new List<Schema.SObjectField>{
                Employment__c.Employee__c,
                Employment__c.Company__c
            }
        );

        SABAccessControlService.assertReadable(
            Employee__c.SObjectType,
            new List<Schema.SObjectField>()
        );

        SABAccessControlService.assertReadable(
            Tax_Code__c.SObjectType,
            new List<Schema.SObjectField>{
                Tax_Code__c.Code__c
            }
        );

        SABAccessControlService.assertReadable(
            GL_Account__c.SObjectType,
            new List<Schema.SObjectField>{
                GL_Account__c.Account_Code__c
            }
        );

        SABAccessControlService.assertReadable(
            Bank_Account__c.SObjectType,
            new List<Schema.SObjectField>()
        );

        SABAccessControlService.assertReadable(
            Journal_Entry__c.SObjectType,
            new List<Schema.SObjectField>()
        );
    }
}
