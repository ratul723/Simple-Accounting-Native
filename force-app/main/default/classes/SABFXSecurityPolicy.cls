/**
 * G7F - FX read-access policy for the finance-user workspace.
 *
 * Why this exists:
 * - SABPermissionService controls business actions.
 * - SABCompanyAccessService controls company authorization.
 * - Salesforce sharing controls record visibility.
 * - This policy explicitly enforces object CRUD/FLS for data exposed through
 *   the G7E user-facing workspace.
 *
 * It does not grant access; it verifies the access already granted by the
 * subscriber org's profiles/permission sets.
 */
public with sharing class SABFXSecurityPolicy {

    public static void assertWorkspaceReadAccess() {
        SABAccessControlService.assertReadable(
            Accounting_Company__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Company__c.Name__c,
                Accounting_Company__c.Functional_Currency__c,
                Accounting_Company__c.Unrealized_FX_Gain_Account__c,
                Accounting_Company__c.Unrealized_FX_Loss_Account__c,
                Accounting_Company__c.Realized_FX_Gain_Account__c,
                Accounting_Company__c.Realized_FX_Loss_Account__c
            }
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

        SABAccessControlService.assertReadable(
            FX_Revaluation_Run__c.SObjectType,
            new List<Schema.SObjectField>{
                FX_Revaluation_Run__c.Company__c,
                FX_Revaluation_Run__c.Accounting_Period__c,
                FX_Revaluation_Run__c.Run_Key__c,
                FX_Revaluation_Run__c.Rate_Set_Key__c,
                FX_Revaluation_Run__c.Reversal_Policy__c,
                FX_Revaluation_Run__c.Status__c,
                FX_Revaluation_Run__c.Journal_Entry__c,
                FX_Revaluation_Run__c.Approved_By__c,
                FX_Revaluation_Run__c.Approved_At__c,
                FX_Revaluation_Run__c.Posted_At__c,
                FX_Revaluation_Run__c.Reversal_Journal_Entry__c,
                FX_Revaluation_Run__c.Reversal_Accounting_Event__c,
                FX_Revaluation_Run__c.Reversed_At__c
            }
        );

        SABAccessControlService.assertReadable(
            FX_Revaluation_Line__c.SObjectType,
            new List<Schema.SObjectField>{
                FX_Revaluation_Line__c.FX_Revaluation_Run__c,
                FX_Revaluation_Line__c.Source_Type__c,
                FX_Revaluation_Line__c.Source_Record_Id__c,
                FX_Revaluation_Line__c.Source_GL_Account__c,
                FX_Revaluation_Line__c.Transaction_Currency__c,
                FX_Revaluation_Line__c.Outstanding_Amount__c,
                FX_Revaluation_Line__c.Carrying_Amount__c,
                FX_Revaluation_Line__c.Applied_Rate__c,
                FX_Revaluation_Line__c.Exchange_Rate__c,
                FX_Revaluation_Line__c.Revalued_Amount__c,
                FX_Revaluation_Line__c.Adjustment_Amount__c
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
                Accounting_Payment__c.Functional_Currency__c,
                Accounting_Payment__c.Exchange_Rate__c,
                Accounting_Payment__c.Exchange_Rate_Record__c,
                Accounting_Payment__c.Effective_Date__c,
                Accounting_Payment__c.Bank_Account__c,
                Accounting_Payment__c.Party_Profile__c,
                Accounting_Payment__c.Provider_Request_Key__c,
                Accounting_Payment__c.Accounting_Event__c
            }
        );

        SABAccessControlService.assertReadable(
            Payment_Allocation__c.SObjectType,
            new List<Schema.SObjectField>{
                Payment_Allocation__c.Company__c,
                Payment_Allocation__c.Payment__c,
                Payment_Allocation__c.Invoice__c,
                Payment_Allocation__c.Supplier_Bill__c,
                Payment_Allocation__c.Status__c,
                Payment_Allocation__c.Allocated_Amount__c,
                Payment_Allocation__c.Payment_Amount__c,
                Payment_Allocation__c.Document_Amount__c,
                Payment_Allocation__c.Base_Amount__c,
                Payment_Allocation__c.Transaction_Currency__c,
                Payment_Allocation__c.Exchange_Rate__c,
                Payment_Allocation__c.Allocation_Date__c,
                Payment_Allocation__c.Effective_Date__c,
                Payment_Allocation__c.Historical_Carrying_Base__c,
                Payment_Allocation__c.Settlement_Base_Amount__c,
                Payment_Allocation__c.Realized_FX_Amount__c,
                Payment_Allocation__c.Realized_FX_State__c,
                Payment_Allocation__c.Realized_FX_Journal__c,
                Payment_Allocation__c.Realized_FX_Accounting_Event__c,
                Payment_Allocation__c.Realized_FX_Reversal_Journal__c,
                Payment_Allocation__c.Realized_FX_Reversal_Event__c,
                Payment_Allocation__c.Realized_FX_Reversed_At__c,
                Payment_Allocation__c.Reversal_Of__c
            }
        );

        SABAccessControlService.assertReadable(
            Invoice__c.SObjectType,
            new List<Schema.SObjectField>{
                Invoice__c.Company__c,
                Invoice__c.Party_Profile__c,
                Invoice__c.Document_Type__c,
                Invoice__c.Status__c,
                Invoice__c.Legal_Number__c,
                Invoice__c.Document_Date__c,
                Invoice__c.Due_Date__c,
                Invoice__c.Total__c,
                Invoice__c.Transaction_Currency__c,
                Invoice__c.Functional_Currency__c,
                Invoice__c.Exchange_Rate__c
            }
        );

        SABAccessControlService.assertReadable(
            Supplier_Bill__c.SObjectType,
            new List<Schema.SObjectField>{
                Supplier_Bill__c.Company__c,
                Supplier_Bill__c.Supplier_Profile__c,
                Supplier_Bill__c.Document_Type__c,
                Supplier_Bill__c.Status__c,
                Supplier_Bill__c.Vendor_Reference__c,
                Supplier_Bill__c.Document_Date__c,
                Supplier_Bill__c.Due_Date__c,
                Supplier_Bill__c.Total__c,
                Supplier_Bill__c.Transaction_Currency__c,
                Supplier_Bill__c.Functional_Currency__c,
                Supplier_Bill__c.Exchange_Rate__c
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
            new List<Schema.SObjectField>{
                Bank_Account__c.Company__c,
                Bank_Account__c.Currency__c,
                Bank_Account__c.GL_Account__c,
                Bank_Account__c.Is_Active__c
            }
        );

        SABAccessControlService.assertReadable(
            Party_Accounting_Profile__c.SObjectType,
            new List<Schema.SObjectField>{
                Party_Accounting_Profile__c.Company__c,
                Party_Accounting_Profile__c.Is_Active__c,
                Party_Accounting_Profile__c.Is_Customer__c,
                Party_Accounting_Profile__c.Is_Supplier__c
            }
        );

        SABAccessControlService.assertReadable(
            Accounting_Event__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Event__c.Journal_Entry__c
            }
        );
    }
}
