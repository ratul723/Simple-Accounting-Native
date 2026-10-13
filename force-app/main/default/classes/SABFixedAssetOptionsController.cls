/**
 * G22G-6: pick lists for the redesigned Fixed assets workspace forms (register, transfer, dispose).
 *
 * Returns the user's fixed asset action permissions and the company's active asset categories with their default life and allowed methods, active bank accounts in
 * the functional currency (for disposal proceeds), departments and cost centers. Registration, schedules, depreciation
 * posting and movements stay with the fixed asset services, unchanged. Reads run in user mode after the company grant
 * check; a list the user cannot read comes back empty.
 */
public with sharing class SABFixedAssetOptionsController {

    public class Options {
        @AuraEnabled public List<Option> categories { get; set; }
        @AuraEnabled public List<Option> bankAccounts { get; set; }
        @AuraEnabled public List<Option> departments { get; set; }
        @AuraEnabled public List<Option> costCenters { get; set; }
        @AuraEnabled public Boolean canRegister { get; set; }
        @AuraEnabled public Boolean canSchedule { get; set; }
        @AuraEnabled public Boolean canMove { get; set; }
        @AuraEnabled public Boolean canPostDepreciation { get; set; }
    }

    public class Option {
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public Integer defaultLifeMonths { get; set; }
        @AuraEnabled public String allowedMethods { get; set; }

        Option(String value, String label) {
            this.value = value;
            this.label = label;
        }
    }

    @AuraEnabled
    public static Options getOptions(Id companyId) {
        if (companyId == null || !SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw auraError('You do not have active access to this Accounting Company.');
        }
        try {
            Options options = new Options();
            options.categories = new List<Option>();
            options.bankAccounts = new List<Option>();
            options.departments = new List<Option>();
            options.costCenters = new List<Option>();
            options.canRegister = SABPermissionService.hasPermission('SAB_Manage_Fixed_Assets');
            options.canSchedule = SABPermissionService.hasPermission('SAB_Generate_Asset_Schedule');
            options.canMove = SABPermissionService.hasPermission('SAB_Manage_Asset_Movements');
            options.canPostDepreciation = SABPermissionService.hasPermission('SAB_Post_Asset_Depreciation');
            if (Schema.SObjectType.Asset_Category__c.isAccessible()) {
                for (Asset_Category__c category : [
                    SELECT Id, Name, Default_Useful_Life_Months__c, Allowed_Methods__c
                    FROM Asset_Category__c
                    WHERE Company__c = :companyId AND Is_Active__c = true
                    WITH USER_MODE
                    ORDER BY Name
                    LIMIT 200
                ]) {
                    Option option = new Option(category.Id, category.Name);
                    option.defaultLifeMonths = category.Default_Useful_Life_Months__c == null ? null : category.Default_Useful_Life_Months__c.intValue();
                    option.allowedMethods = category.Allowed_Methods__c;
                    options.categories.add(option);
                }
            }
            if (Schema.SObjectType.Bank_Account__c.isAccessible()) {
                String currencyCode = [SELECT Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH USER_MODE LIMIT 1].Functional_Currency__c;
                for (Bank_Account__c bank : [
                    SELECT Id, Name
                    FROM Bank_Account__c
                    WHERE Company__c = :companyId AND Is_Active__c = true AND Currency__c = :currencyCode
                    WITH USER_MODE
                    ORDER BY Name
                    LIMIT 200
                ]) {
                    options.bankAccounts.add(new Option(bank.Id, bank.Name));
                }
            }
            if (Schema.SObjectType.Department__c.isAccessible()) {
                for (Department__c department : [SELECT Id, Name FROM Department__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Name LIMIT 500]) {
                    options.departments.add(new Option(department.Id, department.Name));
                }
            }
            if (Schema.SObjectType.Cost_Center__c.isAccessible()) {
                for (Cost_Center__c center : [SELECT Id, Name FROM Cost_Center__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Name LIMIT 500]) {
                    options.costCenters.add(new Option(center.Id, center.Name));
                }
            }
            return options;
        } catch (QueryException ex) {
            throw auraError('Fixed asset options could not be loaded: ' + ex.getMessage());
        }
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
