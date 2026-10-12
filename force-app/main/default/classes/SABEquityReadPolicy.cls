/**
 * G22C: read policy for the Capital & equity workspace.
 *
 * Order: SAB_View_Equity, then an active company grant. Record reads that follow run in user mode, so
 * object and field access still come from SAB_Equity_User.
 */
public with sharing class SABEquityReadPolicy {

    public static final String VIEW_PERMISSION = 'SAB_View_Equity';

    public class EquityAccessException extends Exception {}

    public static void assertCanView(Id companyId) {
        if (!SABPermissionService.hasPermission(VIEW_PERMISSION)) {
            throw new EquityAccessException('You do not have permission to view Capital & equity.');
        }
        if (companyId == null) {
            throw new EquityAccessException('Accounting Company is required.');
        }
        if (!SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw new EquityAccessException('You do not have active access to this Accounting Company.');
        }
    }

    public static Boolean canReadDistributions() {
        return Schema.SObjectType.Distribution__c.isAccessible() && Schema.SObjectType.Distribution_Line__c.isAccessible()
            && Schema.SObjectType.Distribution_Settlement__c.isAccessible();
    }
}
