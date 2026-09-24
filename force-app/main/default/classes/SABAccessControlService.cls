/**
 * Simple Accounting Books - central CRUD/FLS + record-access helper.
 *
 * Step 7A.
 *
 * This service complements, but does NOT replace:
 * - SABPermissionService       -> action authorization
 * - SABCompanyAccessService    -> company authorization
 * - Salesforce record sharing -> record visibility
 *
 * High-risk application services should apply all relevant layers.
 */
public with sharing class SABAccessControlService {

    public class AccessDeniedException extends Exception {}

    public enum AccessOperation {
        READ_ACCESS,
        CREATE_ACCESS,
        UPDATE_ACCESS,
        DELETE_ACCESS
    }

    public static void assertObjectAccess(
        Schema.SObjectType objectType,
        AccessOperation operation
    ) {
        if (objectType == null) {
            throw new AccessDeniedException(
                'Object type is required.'
            );
        }

        if (operation == null) {
            throw new AccessDeniedException(
                'Access operation is required.'
            );
        }

        Schema.DescribeSObjectResult describeResult =
            objectType.getDescribe();

        Boolean allowed = false;

        if (operation == AccessOperation.READ_ACCESS) {
            allowed = describeResult.isAccessible();
        } else if (operation == AccessOperation.CREATE_ACCESS) {
            allowed = describeResult.isCreateable();
        } else if (operation == AccessOperation.UPDATE_ACCESS) {
            allowed = describeResult.isUpdateable();
        } else if (operation == AccessOperation.DELETE_ACCESS) {
            allowed = describeResult.isDeletable();
        }

        if (!allowed) {
            throw new AccessDeniedException(
                'You do not have '
                + operationLabel(operation)
                + ' access to '
                + describeResult.getLabel()
                + '.'
            );
        }
    }

    public static void assertFieldAccess(
        List<Schema.SObjectField> fieldTokens,
        AccessOperation operation
    ) {
        if (
            fieldTokens == null
            || fieldTokens.isEmpty()
        ) {
            return;
        }

        if (operation == null) {
            throw new AccessDeniedException(
                'Access operation is required.'
            );
        }

        for (Schema.SObjectField fieldToken : fieldTokens) {
            if (fieldToken == null) {
                throw new AccessDeniedException(
                    'Field token is required.'
                );
            }

            Schema.DescribeFieldResult describeResult =
                fieldToken.getDescribe();

            Boolean allowed = false;

            if (operation == AccessOperation.READ_ACCESS) {
                allowed = describeResult.isAccessible();
            } else if (operation == AccessOperation.CREATE_ACCESS) {
                allowed = describeResult.isCreateable();
            } else if (operation == AccessOperation.UPDATE_ACCESS) {
                allowed = describeResult.isUpdateable();
            } else {
                throw new AccessDeniedException(
                    'Field-level DELETE access is not a supported operation.'
                );
            }

            if (!allowed) {
                throw new AccessDeniedException(
                    'You do not have '
                    + String.valueOf(operation).toLowerCase()
                    + ' access to field '
                    + describeResult.getLabel()
                    + '.'
                );
            }
        }
    }

    public static void assertReadable(
        Schema.SObjectType objectType,
        List<Schema.SObjectField> fieldTokens
    ) {
        assertObjectAccess(
            objectType,
            AccessOperation.READ_ACCESS
        );

        assertFieldAccess(
            fieldTokens,
            AccessOperation.READ_ACCESS
        );
    }

    public static void assertCreateable(
        Schema.SObjectType objectType,
        List<Schema.SObjectField> fieldTokens
    ) {
        assertObjectAccess(
            objectType,
            AccessOperation.CREATE_ACCESS
        );

        assertFieldAccess(
            fieldTokens,
            AccessOperation.CREATE_ACCESS
        );
    }

    public static void assertUpdateable(
        Schema.SObjectType objectType,
        List<Schema.SObjectField> fieldTokens
    ) {
        assertObjectAccess(
            objectType,
            AccessOperation.UPDATE_ACCESS
        );

        assertFieldAccess(
            fieldTokens,
            AccessOperation.UPDATE_ACCESS
        );
    }

    public static void assertDeletable(
        Schema.SObjectType objectType
    ) {
        assertObjectAccess(
            objectType,
            AccessOperation.DELETE_ACCESS
        );
    }

    /**
     * Checks Salesforce record sharing for the CURRENT USER.
     *
     * This intentionally uses UserRecordAccess rather than inferring access
     * from Company_User_Access__c. The company grant is authorization input,
     * while actual record sharing must also exist.
     */
    public static void assertRecordReadAccess(
        Id recordId
    ) {
        UserRecordAccess accessRow =
            getRecordAccess(recordId);

        if (
            accessRow == null
            || accessRow.HasReadAccess != true
        ) {
            throw new AccessDeniedException(
                'You do not have read access to this record.'
            );
        }
    }

    public static void assertRecordEditAccess(
        Id recordId
    ) {
        UserRecordAccess accessRow =
            getRecordAccess(recordId);

        if (
            accessRow == null
            || accessRow.HasEditAccess != true
        ) {
            throw new AccessDeniedException(
                'You do not have edit access to this record.'
            );
        }
    }

    public static void assertRecordDeleteAccess(
        Id recordId
    ) {
        UserRecordAccess accessRow =
            getRecordAccess(recordId);

        if (
            accessRow == null
            || accessRow.HasDeleteAccess != true
        ) {
            throw new AccessDeniedException(
                'You do not have delete access to this record.'
            );
        }
    }

    /**
     * Convenience method for a service that needs both company authorization
     * and real Salesforce record visibility.
     */
    public static void assertCompanyAndRecordReadAccess(
        Id companyId,
        Id recordId
    ) {
        SABCompanyAccessService.assertCompanyAccess(
            companyId
        );

        assertRecordReadAccess(
            recordId
        );
    }

    public static void assertCompanyAndRecordEditAccess(
        Id companyId,
        Id recordId
    ) {
        SABCompanyAccessService.assertCompanyAccess(
            companyId
        );

        assertRecordEditAccess(
            recordId
        );
    }

    private static String operationLabel(
        AccessOperation operation
    ) {
        if (operation == AccessOperation.READ_ACCESS) {
            return 'read';
        }

        if (operation == AccessOperation.CREATE_ACCESS) {
            return 'create';
        }

        if (operation == AccessOperation.UPDATE_ACCESS) {
            return 'update';
        }

        if (operation == AccessOperation.DELETE_ACCESS) {
            return 'delete';
        }

        return 'required';
    }

    private static UserRecordAccess getRecordAccess(
        Id recordId
    ) {
        if (recordId == null) {
            throw new AccessDeniedException(
                'Record Id is required.'
            );
        }

        List<UserRecordAccess> rows = [
            SELECT RecordId,
                   HasReadAccess,
                   HasEditAccess,
                   HasDeleteAccess
            FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId()
              AND RecordId = :recordId
            LIMIT 1
        ];

        return rows.isEmpty()
            ? null
            : rows[0];
    }
}
