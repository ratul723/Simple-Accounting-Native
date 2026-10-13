/**
 * G22E: read policy for the Approvals and close workspace.
 *
 * Order: SAB_View_Approvals_Close, then an active company grant. Decisions, cancellations and close task changes are
 * authorised again by SABApprovalService and SABCloseTaskService.
 */
public with sharing class SABApprovalsCloseReadPolicy {

    public static final String VIEW_PERMISSION = 'SAB_View_Approvals_Close';

    public class ApprovalsCloseAccessException extends Exception {}

    public static void assertCanView(Id companyId) {
        if (!SABPermissionService.hasPermission(VIEW_PERMISSION)) {
            throw new ApprovalsCloseAccessException('You do not have permission to view Approvals and close.');
        }
        if (companyId == null) {
            throw new ApprovalsCloseAccessException('Accounting Company is required.');
        }
        if (!SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw new ApprovalsCloseAccessException('You do not have active access to this Accounting Company.');
        }
    }
}