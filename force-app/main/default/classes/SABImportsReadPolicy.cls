/**
 * G22F: read policy for the Import and integration center.
 *
 * Order: SAB_View_Imports, then an active company grant. Staging, validating and committing are authorised again by
 * SABImportService; the integration log needs SAB_View_Integration_Log as SABIntegrationLogService requires.
 */
public with sharing class SABImportsReadPolicy {

    public static final String VIEW_PERMISSION = 'SAB_View_Imports';

    public class ImportsAccessException extends Exception {}

    public static void assertCanView(Id companyId) {
        if (!SABPermissionService.hasPermission(VIEW_PERMISSION)) {
            throw new ImportsAccessException('You do not have permission to view the Import and integration center.');
        }
        if (companyId == null) {
            throw new ImportsAccessException('Accounting Company is required.');
        }
        if (!SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw new ImportsAccessException('You do not have active access to this Accounting Company.');
        }
    }
}