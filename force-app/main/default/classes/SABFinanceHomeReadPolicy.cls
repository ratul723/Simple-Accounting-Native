/**
 * G22A: Finance home read policy.
 *
 * Order: custom permission SAB_View_Finance_Home, then an active company grant. Each home section
 * additionally checks object and field access before it queries, so a user without access to an
 * area sees that section as unavailable rather than an error for the whole page.
 */
public with sharing class SABFinanceHomeReadPolicy {

    public static final String VIEW_PERMISSION = 'SAB_View_Finance_Home';

    public class FinanceHomeAccessException extends Exception {}

    public static void assertCanView(Id companyId) {
        if (!SABPermissionService.hasPermission(VIEW_PERMISSION)) {
            throw new FinanceHomeAccessException('You do not have permission to view Finance home.');
        }
        if (companyId == null) {
            throw new FinanceHomeAccessException('Accounting Company is required.');
        }
        if (!SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw new FinanceHomeAccessException('You do not have active access to this Accounting Company.');
        }
    }

    /** True when the object and every listed field are readable by the running user. */
    public static Boolean canRead(Schema.SObjectType objectType, List<Schema.SObjectField> fields) {
        if (!objectType.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()) {
            return false;
        }
        for (Schema.SObjectField field : fields) {
            if (!field.getDescribe().isAccessible()) {
                return false;
            }
        }
        return true;
    }
}
