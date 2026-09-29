/**
 * G9A - Direct-DML protection for the Fixed Asset register.
 */
public without sharing class SABFixedAssetRegisterGuard {

    public static void beforeInsert(
        List<Fixed_Asset__c> rows
    ) {
        if (
            SABFixedAssetRegisterService.isMutationInProgress()
            || SABFixedAssetMovementService.isMutationInProgress()
        ) {
            return;
        }

        for (Fixed_Asset__c row : rows) {
            row.addError(
                'Fixed Assets must be registered through the controlled Fixed Asset service.'
            );
        }
    }

    public static void beforeUpdate(
        List<Fixed_Asset__c> newRows,
        Map<Id, Fixed_Asset__c> oldMap
    ) {
        if (
            SABFixedAssetRegisterService.isMutationInProgress()
            || SABFixedAssetMovementService.isMutationInProgress()
        ) {
            return;
        }

        for (Fixed_Asset__c current : newRows) {
            Fixed_Asset__c prior =
                oldMap.get(current.Id);

            if (prior == null) {
                continue;
            }

            if (current.Status__c != prior.Status__c) {
                current.Status__c.addError(
                    'Fixed Asset lifecycle status is system-managed.'
                );
            }

            if (
                current.Company__c != prior.Company__c
                || current.Company_Asset_Key__c
                    != prior.Company_Asset_Key__c
                || current.Asset_Category__c
                    != prior.Asset_Category__c
                || current.Source_Bill_Line__c
                    != prior.Source_Bill_Line__c
                || current.Acquisition_Date__c
                    != prior.Acquisition_Date__c
                || current.In_Service_Date__c
                    != prior.In_Service_Date__c
                || current.Functional_Currency_Cost__c
                    != prior.Functional_Currency_Cost__c
                || current.Residual_Value__c
                    != prior.Residual_Value__c
                || current.Useful_Life_Months__c
                    != prior.Useful_Life_Months__c
                || current.Depreciation_Method__c
                    != prior.Depreciation_Method__c
                || current.Department__c
                    != prior.Department__c
                || current.Cost_Center__c
                    != prior.Cost_Center__c
                || current.Custodian__c
                    != prior.Custodian__c
                || current.Location__c
                    != prior.Location__c
            ) {
                current.addError(
                    'Fixed Asset accounting basis, custody and reporting dimensions are immutable outside controlled asset lifecycle services.'
                );
            }
        }
    }

    public static void beforeDelete(
        List<Fixed_Asset__c> rows
    ) {
        if (
            SABFixedAssetRegisterService.isMutationInProgress()
            || SABFixedAssetMovementService.isMutationInProgress()
        ) {
            return;
        }

        for (Fixed_Asset__c row : rows) {
            if (row.Status__c != 'Planned') {
                row.addError(
                    'Only Planned Fixed Assets can be deleted.'
                );
            }
        }
    }
}
