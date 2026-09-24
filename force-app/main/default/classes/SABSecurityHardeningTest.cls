@IsTest
private class SABSecurityHardeningTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String POST_ACTION_PERMISSION_SET =
        'SAB_Post_Journal_Action';

    private static final String POST_CUSTOM_PERMISSION =
        'SAB_Post_Journal';

    @TestSetup
    static void setupUsersAndPermissions() {
        Profile standardProfile = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String seed =
            String.valueOf(
                DateTime.now().getTime()
            );

        User dataOnlyUser = new User(
            Alias = 'sabdata',
            Email =
                'sabdata.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Data Only User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username =
                'sabdata.' + seed + '@example.test'
        );

        User actionUser = new User(
            Alias = 'sabact',
            Email =
                'sabaction.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB Action User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username =
                'sabaction.' + seed + '@example.test'
        );

        insert new List<User>{
            dataOnlyUser,
            actionUser
        };

        Map<String, Id> permissionSetIds =
            new Map<String, Id>();

        for (PermissionSet permissionSetRecord : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN (
                :ADMIN_PERMISSION_SET,
                :POST_ACTION_PERMISSION_SET
            )
        ]) {
            permissionSetIds.put(
                permissionSetRecord.Name,
                permissionSetRecord.Id
            );
        }

        System.assertEquals(
            2,
            permissionSetIds.size(),
            'Required SAB permission sets must be deployed.'
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = dataOnlyUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        ADMIN_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = actionUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        ADMIN_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = actionUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        POST_ACTION_PERMISSION_SET
                    )
            )
        };
    }

    @IsTest
    static void broadCrudDoesNotGrantPostingAction() {
        User dataOnlyUser = getUser(
            'SAB Data Only User'
        );

        System.runAs(dataOnlyUser) {
            System.assertEquals(
                false,
                SABPermissionService.hasPermission(
                    POST_CUSTOM_PERMISSION
                ),
                'Broad object/field access must not silently grant the Post Journal action.'
            );

            Boolean thrown = false;

            try {
                SABPermissionService.assertPermission(
                    POST_CUSTOM_PERMISSION,
                    'Posting permission is required.'
                );
            } catch (
                SABPermissionService.PermissionDeniedException ex
            ) {
                thrown = true;
            }

            System.assertEquals(
                true,
                thrown
            );
        }
    }

    @IsTest
    static void actionPermissionDoesNotGrantCompanyAccess() {
        User actionUser = getUser(
            'SAB Action User'
        );

        Accounting_Company__c company =
            makeCompany('S7C1');

        System.runAs(actionUser) {
            System.assertEquals(
                true,
                SABPermissionService.hasPermission(
                    POST_CUSTOM_PERMISSION
                )
            );

            System.assertEquals(
                false,
                SABCompanyAccessService.hasCompanyAccess(
                    company.Id
                ),
                'Action permission alone must not grant company authorization.'
            );
        }
    }

    @IsTest
    static void companyGrantDoesNotGrantPostingAction() {
        User dataOnlyUser = getUser(
            'SAB Data Only User'
        );

        Accounting_Company__c company =
            makeCompany('S7C2');

        insert new Company_User_Access__c(
            Company__c = company.Id,
            User__c = dataOnlyUser.Id,
            Effective_From__c = Date.today(),
            Grant_Key__c = 'SEC-7C-GRANT',
            Is_Active__c = true,
            Role__c = 'Finance Manager'
        );

        System.runAs(dataOnlyUser) {
            System.assertEquals(
                true,
                SABCompanyAccessService.hasCompanyAccess(
                    company.Id
                )
            );

            System.assertEquals(
                false,
                SABPermissionService.hasPermission(
                    POST_CUSTOM_PERMISSION
                ),
                'Company authorization must not silently grant the Post Journal action.'
            );
        }
    }

    @IsTest
    static void accessControlLayerRemainsIndependent() {
        User dataOnlyUser = getUser(
            'SAB Data Only User'
        );

        System.runAs(dataOnlyUser) {
            SABAccessControlService.assertReadable(
                Accounting_Company__c.SObjectType,
                new List<Schema.SObjectField>{
                    Accounting_Company__c.Company_Key__c,
                    Accounting_Company__c.Functional_Currency__c
                }
            );

            System.assertEquals(
                false,
                SABPermissionService.hasPermission(
                    POST_CUSTOM_PERMISSION
                ),
                'CRUD/FLS access must remain separate from high-risk business action permission.'
            );
        }
    }

    private static User getUser(
        String lastName
    ) {
        return [
            SELECT Id
            FROM User
            WHERE LastName = :lastName
            LIMIT 1
        ];
    }

    private static Accounting_Company__c makeCompany(
        String keyValue
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    'Security Company ' + keyValue,
                Company_Key__c = keyValue,
                Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT',
                Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active',
                Is_Active__c = true
            );

        insert company;
        return company;
    }
}
