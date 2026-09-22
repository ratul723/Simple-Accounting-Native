/**
 * Central Custom Permission helper.
 *
 * Business services should call this helper before high-risk actions instead
 * of checking profile names or hard-coding job titles.
 */
public with sharing class SABPermissionService {
    public class PermissionDeniedException extends Exception {}

    public static Boolean hasPermission(String permissionDeveloperName) {
        if (String.isBlank(permissionDeveloperName)) {
            return false;
        }
        return FeatureManagement.checkPermission(permissionDeveloperName);
    }

    public static void assertPermission(
        String permissionDeveloperName,
        String errorMessage
    ) {
        if (!hasPermission(permissionDeveloperName)) {
            throw new PermissionDeniedException(
                String.isBlank(errorMessage)
                    ? 'You do not have permission to perform this action.'
                    : errorMessage
            );
        }
    }
}