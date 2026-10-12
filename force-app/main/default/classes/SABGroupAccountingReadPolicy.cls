/**
 * G22D: read policy for the Group accounting workspace.
 *
 * Order: SAB_View_Group_Accounting, then an active grant to the selected company. Records of other companies
 * (the counterparty of an intercompany transaction, other group members) are read in user mode, so company
 * sharing decides what the user sees; the G18 services still require a grant to every company they touch.
 */
public with sharing class SABGroupAccountingReadPolicy {

    public static final String VIEW_PERMISSION = 'SAB_View_Group_Accounting';

    public class GroupAccountingAccessException extends Exception {}

    public static void assertCanView(Id companyId) {
        if (!SABPermissionService.hasPermission(VIEW_PERMISSION)) {
            throw new GroupAccountingAccessException('You do not have permission to view Group accounting.');
        }
        if (companyId == null) {
            throw new GroupAccountingAccessException('Accounting Company is required.');
        }
        if (!SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw new GroupAccountingAccessException('You do not have active access to this Accounting Company.');
        }
    }

    public static Boolean canReadConsolidation() {
        return Schema.SObjectType.Consolidation_Group__c.isAccessible() && Schema.SObjectType.Consolidation_Member__c.isAccessible()
            && Schema.SObjectType.Consolidation_Run__c.isAccessible();
    }
}
