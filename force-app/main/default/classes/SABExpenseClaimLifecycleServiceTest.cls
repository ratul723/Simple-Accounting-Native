@IsTest
private class SABExpenseClaimLifecycleServiceTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Submit_Expense_Claim_Action',
            'SAB_Review_Expense_Claim_Action'
        };

    @TestSetup
    static void setupFixture() {
        User testUser =
            createUser();

        assignPermissionSets(
            testUser
        );

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c =
                        'G8A Expense Company',
                    Company_Key__c =
                        'E8A',
                    Country_Code__c =
                        'BD',
                    Functional_Currency__c =
                        'BDT',
                    Fiscal_Calendar_Type__c =
                        'Calendar',
                    Fiscal_Year_Start_Month__c =
                        1,
                    Setup_Status__c =
                        'Active',
                    Is_Active__c =
                        true
                );
            insert company;

            insert new Company_User_Access__c(
                Company__c =
                    company.Id,
                User__c =
                    testUser.Id,
                Effective_From__c =
                    Date.today(),
                Grant_Key__c =
                    'G8A-ACCESS',
                Is_Active__c =
                    true,
                Role__c =
                    'Finance Manager'
            );

            Employee__c employee =
                new Employee__c(
                    Name =
                        'G8A Employee',
                    Employee_Reference__c =
                        'G8A-EMP-001',
                    Status__c =
                        'Active',
                    User__c =
                        testUser.Id
                );
            insert employee;

            Employment__c employment =
                new Employment__c(
                    Company__c =
                        company.Id,
                    Employee__c =
                        employee.Id,
                    Employment_Key__c =
                        'G8A-EMPLOYMENT-001',
                    Employment_Status__c =
                        'Active',
                    Start_Date__c =
                        Date.newInstance(
                            2026,
                            1,
                            1
                        )
                );
            insert employment;

            GL_Account__c expenseAccount =
                new GL_Account__c(
                    Name =
                        'Staff Travel Expense',
                    Company__c =
                        company.Id,
                    Company_Account_Key__c =
                        'E8A-6100',
                    Account_Code__c =
                        '6100',
                    Account_Type__c =
                        'Expense',
                    Normal_Balance__c =
                        'Debit',
                    Is_Active__c =
                        true,
                    Is_Control_Account__c =
                        false,
                    Control_Type__c =
                        'None',
                    Manual_Posting_Allowed__c =
                        true
                );
            insert expenseAccount;

            Expense_Claim__c claim =
                new Expense_Claim__c(
                    Company__c =
                        company.Id,
                    Claimant_Employment__c =
                        employment.Id,
                    Claim_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            15
                        ),
                    Currency__c =
                        'BDT',
                    Status__c =
                        'Draft'
                );
            insert claim;

            insert new List<Expense_Claim_Line__c>{
                new Expense_Claim_Line__c(
                    Expense_Claim__c =
                        claim.Id,
                    Expense_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            10
                        ),
                    Category__c =
                        'Travel',
                    Description__c =
                        'Client visit transport',
                    Amount__c =
                        100,
                    Expense_Account__c =
                        expenseAccount.Id
                ),
                new Expense_Claim_Line__c(
                    Expense_Claim__c =
                        claim.Id,
                    Expense_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            12
                        ),
                    Category__c =
                        'Meals',
                    Description__c =
                        'Client meeting meal',
                    Amount__c =
                        50,
                    Expense_Account__c =
                        expenseAccount.Id
                )
            };

            Expense_Claim__c rejectClaim =
                new Expense_Claim__c(
                    Company__c =
                        company.Id,
                    Claimant_Employment__c =
                        employment.Id,
                    Claim_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            16
                        ),
                    Currency__c =
                        'BDT',
                    Status__c =
                        'Draft'
                );
            insert rejectClaim;

            insert new Expense_Claim_Line__c(
                Expense_Claim__c =
                    rejectClaim.Id,
                Expense_Date__c =
                    Date.newInstance(
                        2026,
                        9,
                        14
                    ),
                Category__c =
                    'Travel',
                Description__c =
                    'Rejected test claim',
                Amount__c =
                    25,
                Expense_Account__c =
                    expenseAccount.Id
            );
        }
    }

    @IsTest
    static void submitCreatesApprovalAndCalculatesTotal() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Expense_Claim__c claim =
                getPrimaryClaim();

            Test.startTest();

            SABExpenseClaimLifecycleService.LifecycleResult result =
                SABExpenseClaimLifecycleService.submitClaim(
                    claim.Id,
                    'G8A-SUBMIT-001'
                );

            SABExpenseClaimLifecycleService.LifecycleResult replay =
                SABExpenseClaimLifecycleService.submitClaim(
                    claim.Id,
                    'G8A-SUBMIT-001'
                );

            Test.stopTest();

            System.assertEquals(
                'Submitted',
                result.status
            );

            System.assertEquals(
                Decimal.valueOf('150.0000'),
                result.total
            );

            System.assertNotEquals(
                null,
                result.approvalRequestId
            );

            System.assertEquals(
                'Pending',
                result.approvalStatus
            );

            System.assertEquals(
                true,
                replay.replay
            );

            System.assertEquals(
                result.approvalRequestId,
                replay.approvalRequestId
            );

            Approval_Request__c approval = [
                SELECT Company__c,
                       Policy_Version__c,
                       Request_Key__c,
                       Source_Record_Id__c,
                       Source_Type__c,
                       Source_Version__c,
                       Status__c,
                       Requested_By__c
                FROM Approval_Request__c
                WHERE Id =
                        :result.approvalRequestId
            ];

            System.assertEquals(
                'EXPENSE-CLAIM-V1',
                approval.Policy_Version__c
            );

            System.assertEquals(
                'G8A-SUBMIT-001',
                approval.Request_Key__c
            );

            System.assertEquals(
                'Expense_Claim__c',
                approval.Source_Type__c
            );

            System.assertEquals(
                String.valueOf(
                    claim.Id
                ),
                approval.Source_Record_Id__c
            );

            System.assertEquals(
                Decimal.valueOf('1'),
                approval.Source_Version__c
            );

            System.assertEquals(
                'Pending',
                approval.Status__c
            );

            System.assertEquals(
                testUser.Id,
                approval.Requested_By__c
            );
        }
    }

    @IsTest
    static void approvalCompletesRequestAndLocksLines() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Expense_Claim__c claim =
                getPrimaryClaim();

            SABExpenseClaimLifecycleService.submitClaim(
                claim.Id,
                'G8A-APPROVE-SUBMIT'
            );

            Test.startTest();

            SABExpenseClaimLifecycleService.LifecycleResult result =
                SABExpenseClaimLifecycleService.approveClaim(
                    claim.Id,
                    'G8A-APPROVE-001',
                    'Manager approved claim.'
                );

            Test.stopTest();

            System.assertEquals(
                'Approved',
                result.status
            );

            System.assertEquals(
                'Approved',
                result.approvalStatus
            );

            Approval_Request__c approval = [
                SELECT Status__c,
                       Completed_At__c
                FROM Approval_Request__c
                WHERE Id =
                        :result.approvalRequestId
            ];

            System.assertEquals(
                'Approved',
                approval.Status__c
            );

            System.assertNotEquals(
                null,
                approval.Completed_At__c
            );

            Expense_Claim_Line__c line = [
                SELECT Id,
                       Amount__c
                FROM Expense_Claim_Line__c
                WHERE Expense_Claim__c =
                        :claim.Id
                LIMIT 1
            ];

            line.Amount__c =
                999;

            Database.SaveResult lineResult =
                Database.update(
                    line,
                    false
                );

            System.assertEquals(
                false,
                lineResult.isSuccess()
            );

            System.assert(
                lineResult.getErrors()[0]
                    .getMessage()
                    .contains(
                        'locked after the claim leaves Draft'
                    ),
                lineResult.getErrors()[0]
                    .getMessage()
            );
        }
    }

    @IsTest
    static void rejectionRequiresReasonAndCompletesRequest() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Expense_Claim__c claim =
                getRejectClaim();

            SABExpenseClaimLifecycleService.submitClaim(
                claim.Id,
                'G8A-REJECT-SUBMIT'
            );

            Boolean reasonBlocked =
                false;

            try {
                SABExpenseClaimLifecycleService.rejectClaim(
                    claim.Id,
                    'G8A-REJECT-BAD',
                    null
                );
            } catch (
                SABExpenseClaimLifecycleService.ExpenseClaimLifecycleException ex
            ) {
                reasonBlocked =
                    ex.getMessage().contains(
                        'reason is required'
                    );
            }

            System.assertEquals(
                true,
                reasonBlocked
            );

            SABExpenseClaimLifecycleService.LifecycleResult result =
                SABExpenseClaimLifecycleService.rejectClaim(
                    claim.Id,
                    'G8A-REJECT-001',
                    'Receipt documentation is insufficient.'
                );

            System.assertEquals(
                'Rejected',
                result.status
            );

            System.assertEquals(
                'Rejected',
                result.approvalStatus
            );
        }
    }

    @IsTest
    static void directLifecycleStatusBypassIsBlocked() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Expense_Claim__c claim =
                getPrimaryClaim();

            claim.Status__c =
                'Approved';

            Database.SaveResult result =
                Database.update(
                    claim,
                    false
                );

            System.assertEquals(
                false,
                result.isSuccess()
            );

            System.assert(
                result.getErrors()[0]
                    .getMessage()
                    .contains(
                        'lifecycle-managed'
                    ),
                result.getErrors()[0]
                    .getMessage()
            );
        }
    }

    @IsTest
    static void approvalRequiresPostingReadyExpenseAccount() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            Accounting_Company__c company =
                getCompany();

            Employment__c employment =
                getEmployment();

            Expense_Claim__c claim =
                new Expense_Claim__c(
                    Company__c =
                        company.Id,
                    Claimant_Employment__c =
                        employment.Id,
                    Claim_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            18
                        ),
                    Currency__c =
                        'BDT',
                    Status__c =
                        'Draft'
                );
            insert claim;

            insert new Expense_Claim_Line__c(
                Expense_Claim__c =
                    claim.Id,
                Expense_Date__c =
                    Date.newInstance(
                        2026,
                        9,
                        17
                    ),
                Category__c =
                    'Office',
                Description__c =
                    'Small office expense',
                Amount__c =
                    20
            );

            SABExpenseClaimLifecycleService.submitClaim(
                claim.Id,
                'G8A-NO-ACCOUNT-SUBMIT'
            );

            Boolean blocked =
                false;

            try {
                SABExpenseClaimLifecycleService.approveClaim(
                    claim.Id,
                    'G8A-NO-ACCOUNT-APPROVE',
                    'Attempt approval.'
                );
            } catch (
                SABExpenseClaimLifecycleService.ExpenseClaimLifecycleException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'requires an Expense Account'
                    );
            }

            System.assertEquals(
                true,
                blocked
            );
        }
    }

    private static User createUser() {
        Profile profileRecord = [
            SELECT Id
            FROM Profile
            WHERE UserType =
                    'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String seed =
            String.valueOf(
                Datetime.now().getTime()
            );

        User row =
            new User(
                Alias =
                    'g8aclm',
                Email =
                    'g8aclm.'
                    + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    'G8A Expense User',
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    profileRecord.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    'g8aclm.'
                    + seed
                    + '@example.test'
            );

        insert row;
        return row;
    }

    private static void assignPermissionSets(
        User userRecord
    ) {
        Map<String, Id> permissionSetIds =
            new Map<String, Id>();

        for (PermissionSet row : [
            SELECT Id,
                   Name
            FROM PermissionSet
            WHERE Name IN :REQUIRED_PERMISSION_SETS
        ]) {
            permissionSetIds.put(
                row.Name,
                row.Id
            );
        }

        System.assertEquals(
            REQUIRED_PERMISSION_SETS.size(),
            permissionSetIds.size(),
            'All G8A action Permission Sets must exist.'
        );

        List<PermissionSetAssignment> assignments =
            new List<PermissionSetAssignment>();

        for (String permissionSetName : REQUIRED_PERMISSION_SETS) {
            assignments.add(
                new PermissionSetAssignment(
                    AssigneeId =
                        userRecord.Id,
                    PermissionSetId =
                        permissionSetIds.get(
                            permissionSetName
                        )
                )
            );
        }

        insert assignments;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                    'G8A Expense User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getCompany() {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c =
                    'E8A'
            LIMIT 1
        ];
    }

    private static Employment__c getEmployment() {
        return [
            SELECT Id
            FROM Employment__c
            WHERE Employment_Key__c =
                    'G8A-EMPLOYMENT-001'
            LIMIT 1
        ];
    }

    private static Expense_Claim__c getPrimaryClaim() {
        Id companyId =
            getCompany().Id;

        Date claimDate =
            Date.newInstance(
                2026,
                9,
                15
            );

        return [
            SELECT Id,
                   Status__c
            FROM Expense_Claim__c
            WHERE Company__c =
                    :companyId
              AND Claim_Date__c =
                    :claimDate
            LIMIT 1
        ];
    }

    private static Expense_Claim__c getRejectClaim() {
        Id companyId =
            getCompany().Id;

        Date claimDate =
            Date.newInstance(
                2026,
                9,
                16
            );

        return [
            SELECT Id,
                   Status__c
            FROM Expense_Claim__c
            WHERE Company__c =
                    :companyId
              AND Claim_Date__c =
                    :claimDate
            LIMIT 1
        ];
    }
}
