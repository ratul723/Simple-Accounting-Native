@IsTest
private class SABExpenseClaimSettlementServiceTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Remaining_Fields_Admin',
            'SAB_Expense_Reimbursement_Action'
        };

    @TestSetup
    static void setupFixture() {
        User testUser = createUser();
        assignPermissionSets(testUser);

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c = 'G8C Settlement Company',
                    Company_Key__c = 'S8C',
                    Country_Code__c = 'BD',
                    Functional_Currency__c = 'BDT',
                    Fiscal_Calendar_Type__c =
                        'Calendar',
                    Fiscal_Year_Start_Month__c = 1,
                    Setup_Status__c = 'Active',
                    Is_Active__c = true
                );
            insert company;

            insert new Company_User_Access__c(
                Company__c = company.Id,
                User__c = testUser.Id,
                Effective_From__c = Date.today(),
                Grant_Key__c =
                    'G8C-SETTLE-ACCESS',
                Is_Active__c = true,
                Role__c = 'Finance Manager'
            );

            GL_Account__c bankGL =
                new GL_Account__c(
                    Name = 'Settlement Bank GL',
                    Company__c = company.Id,
                    Company_Account_Key__c =
                        'S8C-1100',
                    Account_Code__c = '1100',
                    Account_Type__c = 'Asset',
                    Normal_Balance__c = 'Debit',
                    Is_Active__c = true,
                    Is_Control_Account__c = false,
                    Control_Type__c = 'None',
                    Manual_Posting_Allowed__c = true
                );
            insert bankGL;

            Bank_Account__c bank =
                new Bank_Account__c(
                    Name = 'Settlement Bank',
                    Company__c = company.Id,
                    Currency__c = 'BDT',
                    GL_Account__c = bankGL.Id,
                    Is_Active__c = true
                );
            insert bank;

            Employee__c employee =
                new Employee__c(
                    Name = 'Settlement Employee',
                    Employee_Reference__c =
                        'G8C-SETTLE-EMP',
                    Status__c = 'Active',
                    User__c = testUser.Id
                );
            insert employee;

            Employment__c employment =
                new Employment__c(
                    Company__c = company.Id,
                    Employee__c = employee.Id,
                    Employment_Key__c =
                        'G8C-SETTLE-EMPLOYMENT',
                    Employment_Status__c =
                        'Active',
                    Start_Date__c =
                        Date.newInstance(2026, 1, 1)
                );
            insert employment;

            Expense_Claim__c claim =
                new Expense_Claim__c(
                    Company__c = company.Id,
                    Claimant_Employment__c =
                        employment.Id,
                    Claim_Date__c =
                        Date.newInstance(2026, 9, 20),
                    Accounting_Date__c =
                        Date.newInstance(2026, 9, 20),
                    Currency__c = 'BDT',
                    Status__c = 'Draft'
                );
            insert claim;

            // Trusted fixture mutation: preserve production direct-DML guard.
            SABExpenseClaimSettlementService.settlementMutationInProgress = true;
            try {
                claim.Total__c = 150;
                claim.Status__c = 'Posted';
                update claim;
            } finally {
                SABExpenseClaimSettlementService.settlementMutationInProgress = false;
            }

            Accounting_Payment__c p1 =
                new Accounting_Payment__c(
                    Company__c = company.Id,
                    Bank_Account__c = bank.Id,
                    Direction__c = 'Disbursement',
                    Method__c = 'Bank Transfer',
                    Reference__c =
                        'G8C-SETTLE-PAY-1',
                    Amount__c = 100,
                    Transaction_Currency__c = 'BDT',
                    Effective_Date__c =
                        Date.newInstance(2026, 9, 25),
                    Processing_State__c = 'Draft'
                );
            insert p1;

            Accounting_Payment__c p2 =
                new Accounting_Payment__c(
                    Company__c = company.Id,
                    Bank_Account__c = bank.Id,
                    Direction__c = 'Disbursement',
                    Method__c = 'Bank Transfer',
                    Reference__c =
                        'G8C-SETTLE-PAY-2',
                    Amount__c = 50,
                    Transaction_Currency__c = 'BDT',
                    Effective_Date__c =
                        Date.newInstance(2026, 9, 26),
                    Processing_State__c = 'Draft'
                );
            insert p2;

            SABAccountingPaymentMutationContext.beginMutation();
            try {
                p1.Functional_Currency__c = 'BDT';
                p1.Exchange_Rate__c = 1;
                p1.Processing_State__c =
                    'Succeeded';

                p2.Functional_Currency__c = 'BDT';
                p2.Exchange_Rate__c = 1;
                p2.Processing_State__c =
                    'Succeeded';

                update new List<Accounting_Payment__c>{
                    p1, p2
                };
            } finally {
                SABAccountingPaymentMutationContext.endMutation();
            }
        }
    }

    @IsTest
    static void partialThenFullSettlementUpdatesClaimLifecycle() {
        User testUser = getUser();

        System.runAs(testUser) {
            Expense_Claim__c claim =
                getClaim();

            List<Accounting_Payment__c> payments =
                getPayments();

            SABExpenseClaimSettlementService.SettlementRequest firstRequest =
                    new SABExpenseClaimSettlementService.SettlementRequest();

            firstRequest.expenseClaimId =
                claim.Id;
            firstRequest.paymentId =
                payments[0].Id;
            firstRequest.amount = 100;
            firstRequest.settlementKey =
                'G8C-SETTLEMENT-001';

            Test.startTest();

            SABExpenseClaimSettlementService.SettlementResult first =
                    SABExpenseClaimSettlementService.settleClaim(
                            firstRequest
                        );

            Test.stopTest();

            System.assertEquals(
                'Part Paid',
                first.claimStatus
            );
            System.assertEquals(
                Decimal.valueOf('100.0000'),
                first.claimPaidAmount
            );
            System.assertEquals(
                Decimal.valueOf('50.0000'),
                first.claimRemainingAmount
            );

            SABExpenseClaimSettlementService.SettlementRequest secondRequest =
                    new SABExpenseClaimSettlementService.SettlementRequest();

            secondRequest.expenseClaimId =
                claim.Id;
            secondRequest.paymentId =
                payments[1].Id;
            secondRequest.amount = 50;
            secondRequest.settlementKey =
                'G8C-SETTLEMENT-002';

            SABExpenseClaimSettlementService.SettlementResult second =
                    SABExpenseClaimSettlementService.settleClaim(
                            secondRequest
                        );

            System.assertEquals(
                'Paid',
                second.claimStatus
            );
            System.assertEquals(
                Decimal.valueOf('150.0000'),
                second.claimPaidAmount
            );
            System.assertEquals(
                Decimal.valueOf('0.0000'),
                second.claimRemainingAmount
            );

            SABExpenseClaimSettlementService.SettlementResult replay =
                    SABExpenseClaimSettlementService.settleClaim(
                            secondRequest
                        );

            System.assertEquals(
                true,
                replay.replay
            );
            System.assertEquals(
                second.settlementId,
                replay.settlementId
            );
        }
    }

    @IsTest
    static void overpaymentIsBlocked() {
        User testUser = getUser();

        System.runAs(testUser) {
            Expense_Claim__c claim =
                getClaim();

            Accounting_Payment__c payment =
                getPayments()[0];

            SABExpenseClaimSettlementService.SettlementRequest request =
                    new SABExpenseClaimSettlementService.SettlementRequest();

            request.expenseClaimId =
                claim.Id;
            request.paymentId =
                payment.Id;
            request.amount = 151;
            request.settlementKey =
                'G8C-OVERPAY';

            Boolean blocked = false;

            Test.startTest();
            try {
                SABExpenseClaimSettlementService.settleClaim(request);
            } catch (
                SABExpenseClaimSettlementService.ExpenseClaimSettlementException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'remaining'
                    );
            }
            Test.stopTest();

            System.assertEquals(
                true,
                blocked
            );
        }
    }

    @IsTest
    static void settlementReversalRestoresPostedStatus() {
        User testUser = getUser();

        System.runAs(testUser) {
            Expense_Claim__c claim =
                getClaim();

            Accounting_Payment__c payment =
                getPayments()[0];

            SABExpenseClaimSettlementService.SettlementRequest request =
                    new SABExpenseClaimSettlementService.SettlementRequest();

            request.expenseClaimId =
                claim.Id;
            request.paymentId =
                payment.Id;
            request.amount = 100;
            request.settlementKey =
                'G8C-REV-ORIGINAL';

            SABExpenseClaimSettlementService.SettlementResult settled =
                    SABExpenseClaimSettlementService.settleClaim(request);

            Test.startTest();

            SABExpenseClaimSettlementService.SettlementResult reversed =
                    SABExpenseClaimSettlementService.reverseSettlement(
                            settled.settlementId,
                            'G8C-REVERSAL-001'
                        );

            Test.stopTest();

            System.assertEquals(
                Decimal.valueOf('-100.0000'),
                reversed.allocatedAmount
            );
            System.assertEquals(
                'Reversed',
                reversed.settlementStatus
            );
            System.assertEquals(
                Decimal.valueOf('0.0000'),
                reversed.claimPaidAmount
            );
            System.assertEquals(
                'Posted',
                reversed.claimStatus
            );

            Claim_Settlement__c original = [
                SELECT Status__c
                FROM Claim_Settlement__c
                WHERE Id = :settled.settlementId
            ];

            System.assertEquals(
                'Reversed',
                original.Status__c
            );
        }
    }


    @IsTest
    static void directClaimSettlementDmlIsBlocked() {
        User testUser = getUser();

        System.runAs(testUser) {
            Expense_Claim__c claim = getClaim();
            Accounting_Payment__c payment = getPayments()[0];

            Boolean insertBlocked = false;

            try {
                insert new Claim_Settlement__c(
                    Expense_Claim__c = claim.Id,
                    Payment__c = payment.Id,
                    Allocated_Amount__c = 10,
                    Effective_Date__c = Date.newInstance(2026, 9, 25),
                    Settlement_Key__c = 'G8C-DIRECT-INSERT',
                    Status__c = 'Effective'
                );
            } catch (DmlException ex) {
                insertBlocked =
                    ex.getMessage().contains(
                        'Claim Settlements must be created through'
                    );
            }

            System.assertEquals(
                true,
                insertBlocked,
                'Direct Claim Settlement insert must be blocked.'
            );

            SABExpenseClaimSettlementService.SettlementRequest request =
                new SABExpenseClaimSettlementService.SettlementRequest();

            request.expenseClaimId = claim.Id;
            request.paymentId = payment.Id;
            request.amount = 25;
            request.settlementKey = 'G8C-GUARD-SEED';

            SABExpenseClaimSettlementService.SettlementResult created =
                SABExpenseClaimSettlementService.settleClaim(
                    request
                );

            Claim_Settlement__c settlement = [
                SELECT Id,
                       Status__c
                FROM Claim_Settlement__c
                WHERE Id = :created.settlementId
            ];

            Boolean updateBlocked = false;

            settlement.Status__c = 'Reversed';

            try {
                update settlement;
            } catch (DmlException ex) {
                updateBlocked =
                    ex.getMessage().contains(
                        'immutable outside the controlled settlement service'
                    );
            }

            System.assertEquals(
                true,
                updateBlocked,
                'Direct Claim Settlement update must be blocked.'
            );

            Boolean deleteBlocked = false;

            try {
                delete settlement;
            } catch (DmlException ex) {
                deleteBlocked =
                    ex.getMessage().contains(
                        'Claim Settlements cannot be deleted'
                    );
            }

            System.assertEquals(
                true,
                deleteBlocked,
                'Direct Claim Settlement delete must be blocked.'
            );
        }
    }

    @IsTest
    static void expenseClaimLifecycleDirectDmlRemainsProtected() {
        User testUser = getUser();

        System.runAs(testUser) {
            Expense_Claim__c postedClaim = getClaim();

            Boolean statusUpdateBlocked = false;

            postedClaim.Status__c = 'Paid';

            try {
                update postedClaim;
            } catch (DmlException ex) {
                statusUpdateBlocked =
                    ex.getMessage().contains(
                        'Expense Claim Status is lifecycle-managed'
                    );
            }

            System.assertEquals(
                true,
                statusUpdateBlocked,
                'Direct claim status changes must remain blocked.'
            );

            Boolean deleteBlocked = false;

            try {
                delete postedClaim;
            } catch (DmlException ex) {
                deleteBlocked =
                    ex.getMessage().contains(
                        'Only Draft Expense Claims may be deleted'
                    );
            }

            System.assertEquals(
                true,
                deleteBlocked,
                'Posted claims must not be directly deleted.'
            );

            Accounting_Company__c company = [
                SELECT Id
                FROM Accounting_Company__c
                WHERE Company_Key__c = 'S8C'
                LIMIT 1
            ];

            Employment__c employment = [
                SELECT Id
                FROM Employment__c
                WHERE Company__c = :company.Id
                LIMIT 1
            ];

            Boolean badInsertBlocked = false;

            try {
                insert new Expense_Claim__c(
                    Company__c = company.Id,
                    Claimant_Employment__c = employment.Id,
                    Claim_Date__c = Date.newInstance(2026, 9, 28),
                    Accounting_Date__c = Date.newInstance(2026, 9, 28),
                    Currency__c = 'BDT',
                    Status__c = 'Posted',
                    Total__c = 1
                );
            } catch (DmlException ex) {
                badInsertBlocked =
                    ex.getMessage().contains(
                        'Expense Claims must be created in Draft status'
                    );
            }

            System.assertEquals(
                true,
                badInsertBlocked,
                'Expense Claims must enter the lifecycle as Draft.'
            );

            Expense_Claim__c draftClaim =
                new Expense_Claim__c(
                    Company__c = company.Id,
                    Claimant_Employment__c = employment.Id,
                    Claim_Date__c = Date.newInstance(2026, 9, 28),
                    Accounting_Date__c = Date.newInstance(2026, 9, 28),
                    Currency__c = 'BDT',
                    Status__c = 'Draft'
                );
            insert draftClaim;

            Boolean snapshotInsertBlocked = false;

            try {
                insert new Expense_Claim_Line__c(
                    Expense_Claim__c = draftClaim.Id,
                    Expense_Date__c = Date.newInstance(2026, 9, 27),
                    Category__c = 'Office',
                    Description__c = 'Direct tax snapshot attempt',
                    Amount__c = 20,
                    Taxable_Base__c = 20
                );
            } catch (DmlException ex) {
                snapshotInsertBlocked =
                    ex.getMessage().contains(
                        'tax snapshot fields are system-managed'
                    );
            }

            System.assertEquals(
                true,
                snapshotInsertBlocked,
                'Direct tax snapshot population must be blocked.'
            );

            Expense_Claim_Line__c editableLine =
                new Expense_Claim_Line__c(
                    Expense_Claim__c = draftClaim.Id,
                    Expense_Date__c = Date.newInstance(2026, 9, 27),
                    Category__c = 'Office',
                    Description__c = 'Draft line',
                    Amount__c = 20
                );
            insert editableLine;

            SABExpenseClaimSettlementService.settlementMutationInProgress =
                true;
            try {
                draftClaim.Status__c = 'Posted';
                update draftClaim;
            } finally {
                SABExpenseClaimSettlementService.settlementMutationInProgress =
                    false;
            }

            editableLine.Description__c =
                'Attempt after lifecycle lock';

            Boolean lineUpdateBlocked = false;

            try {
                update editableLine;
            } catch (DmlException ex) {
                lineUpdateBlocked =
                    ex.getMessage().contains(
                        'Expense Claim Lines are locked'
                    );
            }

            System.assertEquals(
                true,
                lineUpdateBlocked,
                'Lines must be locked after the claim leaves Draft.'
            );

            Boolean lineDeleteBlocked = false;

            try {
                delete editableLine;
            } catch (DmlException ex) {
                lineDeleteBlocked =
                    ex.getMessage().contains(
                        'Expense Claim Lines are locked'
                    );
            }

            System.assertEquals(
                true,
                lineDeleteBlocked,
                'Lines must not be directly deleted after the claim leaves Draft.'
            );
        }
    }

    private static User createUser() {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String seed =
            String.valueOf(
                Datetime.now().getTime()
            );

        User row = new User(
            Alias = 'g8cset',
            Email =
                'g8cset.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName =
                'G8C Settlement User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username =
                'g8cset.' + seed + '@example.test'
        );
        insert row;
        return row;
    }

    private static void assignPermissionSets(
        User userRecord
    ) {
        Map<String, Id> ids =
            new Map<String, Id>();

        for (PermissionSet row : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN :REQUIRED_PERMISSION_SETS
        ]) {
            ids.put(row.Name, row.Id);
        }

        System.assertEquals(
            REQUIRED_PERMISSION_SETS.size(),
            ids.size()
        );

        List<PermissionSetAssignment> rows =
            new List<PermissionSetAssignment>();

        for (String nameValue : REQUIRED_PERMISSION_SETS) {
            rows.add(
                new PermissionSetAssignment(
                    AssigneeId = userRecord.Id,
                    PermissionSetId =
                        ids.get(nameValue)
                )
            );
        }
        insert rows;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                'G8C Settlement User'
            LIMIT 1
        ];
    }

    private static Expense_Claim__c getClaim() {
        return [
            SELECT Id, Status__c
            FROM Expense_Claim__c
            WHERE Company__r.Company_Key__c =
                'S8C'
            LIMIT 1
        ];
    }

    private static List<Accounting_Payment__c>
        getPayments()
    {
        return [
            SELECT Id, Reference__c
            FROM Accounting_Payment__c
            WHERE Company__r.Company_Key__c =
                'S8C'
            ORDER BY Reference__c
        ];
    }
}
