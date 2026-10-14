/**
 * Remaining-tasks batch 2: pick lists and permissions for the Employees and pay view in People and payroll.
 *
 * Returns the company's pay components, departments, cost centers and the expense and liability accounts pay
 * components post to, with the user's compensation permissions. Employees, employments, pay components and pay
 * assignments are saved through SABEmployeeCompensationService, unchanged. Read only, user mode after the grant check.
 */
public with sharing class SABPeopleSetupController {

    public class Option {
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String detail { get; set; }
        @AuraEnabled public Boolean active { get; set; }

        Option(String value, String label) {
            this.value = value;
            this.label = label;
        }
    }

    public class Options {
        @AuraEnabled public Boolean canManage { get; set; }
        @AuraEnabled public Boolean canApprove { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public List<Option> payComponents { get; set; }
        @AuraEnabled public List<Option> departments { get; set; }
        @AuraEnabled public List<Option> costCenters { get; set; }
        @AuraEnabled public List<Option> expenseAccounts { get; set; }
        @AuraEnabled public List<Option> liabilityAccounts { get; set; }
        @AuraEnabled public List<String> categories { get; set; }
        @AuraEnabled public List<DraftPay> draftPay { get; set; }
    }

    /** Draft pay lines; approved pay comes from SABEmployeeCompensationService.getCurrentCompensation. */
    public class DraftPay {
        @AuraEnabled public Id assignmentId { get; set; }
        @AuraEnabled public Id employmentId { get; set; }
        @AuraEnabled public String payComponentName { get; set; }
        @AuraEnabled public String category { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public Date effectiveFrom { get; set; }
        @AuraEnabled public String status { get; set; }
    }

    @AuraEnabled
    public static Options getOptions(Id companyId) {
        if (companyId == null || !SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw auraError('You do not have active access to this Accounting Company.');
        }
        try {
            Options o = new Options();
            o.canManage = SABPermissionService.hasPermission('SAB_Manage_Employee_Compensation');
            o.canApprove = SABPermissionService.hasPermission('SAB_Approve_Employee_Compensation');
            o.currencyCode = [SELECT Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH USER_MODE LIMIT 1].Functional_Currency__c;
            o.payComponents = new List<Option>();
            if (Schema.SObjectType.Pay_Component__c.isAccessible()) {
                for (Pay_Component__c c : [SELECT Id, Name, Category__c, Is_Active__c FROM Pay_Component__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Name LIMIT 500]) {
                    Option option = new Option(c.Id, c.Name);
                    option.detail = c.Category__c;
                    option.active = c.Is_Active__c == true;
                    o.payComponents.add(option);
                }
            }
            o.departments = new List<Option>();
            if (Schema.SObjectType.Department__c.isAccessible()) {
                for (Department__c d : [SELECT Id, Name FROM Department__c WHERE Company__c = :companyId AND Is_Active__c = true WITH USER_MODE ORDER BY Name LIMIT 500]) {
                    o.departments.add(new Option(d.Id, d.Name));
                }
            }
            o.costCenters = new List<Option>();
            if (Schema.SObjectType.Cost_Center__c.isAccessible()) {
                for (Cost_Center__c c : [SELECT Id, Name FROM Cost_Center__c WHERE Company__c = :companyId AND Is_Active__c = true WITH USER_MODE ORDER BY Name LIMIT 500]) {
                    o.costCenters.add(new Option(c.Id, c.Name));
                }
            }
            o.expenseAccounts = new List<Option>();
            o.liabilityAccounts = new List<Option>();
            for (GL_Account__c a : [SELECT Id, Account_Code__c, Name, Account_Type__c FROM GL_Account__c WHERE Company__c = :companyId AND Is_Active__c = true
                    AND Account_Type__c IN ('Expense', 'Liability') WITH USER_MODE ORDER BY Account_Code__c LIMIT 1000]) {
                Option option = new Option(a.Id, a.Account_Code__c + ' ' + a.Name);
                (a.Account_Type__c == 'Expense' ? o.expenseAccounts : o.liabilityAccounts).add(option);
            }
            o.draftPay = new List<DraftPay>();
            if (Schema.SObjectType.Employee_Pay_Component__c.isAccessible()) {
                for (Employee_Pay_Component__c a : [SELECT Id, Employment__c, Pay_Component__r.Name, Pay_Component__r.Category__c, Amount__c, Effective_From__c, Status__c
                        FROM Employee_Pay_Component__c WHERE Employment__r.Company__c = :companyId AND Status__c = 'Draft' WITH USER_MODE ORDER BY Effective_From__c LIMIT 500]) {
                    DraftPay d = new DraftPay();
                    d.assignmentId = a.Id;
                    d.employmentId = a.Employment__c;
                    d.payComponentName = a.Pay_Component__r == null ? null : a.Pay_Component__r.Name;
                    d.category = a.Pay_Component__r == null ? null : a.Pay_Component__r.Category__c;
                    d.amount = a.Amount__c;
                    d.effectiveFrom = a.Effective_From__c;
                    d.status = a.Status__c;
                    o.draftPay.add(d);
                }
            }
            o.categories = new List<String>();
            for (Schema.PicklistEntry e : Pay_Component__c.Category__c.getDescribe().getPicklistValues()) {
                if (e.isActive()) {
                    o.categories.add(e.getValue());
                }
            }
            return o;
        } catch (QueryException ex) {
            throw auraError('People options could not be loaded: ' + ex.getMessage());
        }
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
