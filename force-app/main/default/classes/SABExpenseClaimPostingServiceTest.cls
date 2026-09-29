@IsTest
private class SABExpenseClaimPostingServiceTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Remaining_Fields_Admin',
            'SAB_Post_Journal_Action',
            'SAB_Submit_Expense_Claim_Action',
            'SAB_Review_Expense_Claim_Action',
            'SAB_Post_Expense_Claim_Action'
        };

    @TestSetup
    static void setupFixture() {
        User testUser = createUser();
        assignPermissionSets(testUser);

        System.runAs(testUser) {
            Accounting_Company__c company = new Accounting_Company__c(
                Name__c = 'G8B Expense Company',
                Company_Key__c = 'E8B',
                Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT',
                Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active',
                Is_Active__c = true
            );
            insert company;

            insert new Company_User_Access__c(
                Company__c = company.Id,
                User__c = testUser.Id,
                Effective_From__c = Date.today(),
                Grant_Key__c = 'G8B-ACCESS',
                Is_Active__c = true,
                Role__c = 'Finance Manager'
            );

            GL_Account__c expenseAccount = glAccount(
                company.Id, '6100', 'Staff Expense',
                'Expense', 'Debit', false, 'None', true
            );

            GL_Account__c reimbursementLiability = glAccount(
                company.Id, '2200', 'Employee Reimbursement Liability',
                'Liability', 'Credit', true, 'Other', false
            );

            GL_Account__c inputTax = glAccount(
                company.Id, '1300', 'Recoverable Input Tax',
                'Asset', 'Debit', true, 'Tax', false
            );

            company.Employee_Reimbursement_Liability_Account__c =
                reimbursementLiability.Id;
            update company;

            insert new List<Accounting_Period__c>{
                new Accounting_Period__c(
                    Name = 'September 2026',
                    Company__c = company.Id,
                    Company_Period_Key__c = 'E8B-2026-09',
                    Period_Key__c = 'E8B-2026-09',
                    Start_Date__c = Date.newInstance(2026, 9, 1),
                    End_Date__c = Date.newInstance(2026, 9, 30),
                    Fiscal_Year__c = 2026,
                    Fiscal_Quarter__c = 3,
                    Period_Number__c = 9,
                    Status__c = 'Open'
                ),
                new Accounting_Period__c(
                    Name = 'October 2026',
                    Company__c = company.Id,
                    Company_Period_Key__c = 'E8B-2026-10',
                    Period_Key__c = 'E8B-2026-10',
                    Start_Date__c = Date.newInstance(2026, 10, 1),
                    End_Date__c = Date.newInstance(2026, 10, 31),
                    Fiscal_Year__c = 2026,
                    Fiscal_Quarter__c = 4,
                    Period_Number__c = 10,
                    Status__c = 'Closed',
                    Closed_At__c = System.now(),
                    Closed_By__c = UserInfo.getUserId()
                )
            };

            Employee__c employee = new Employee__c(
                Name = 'G8B Employee',
                Employee_Reference__c = 'G8B-EMP-001',
                Status__c = 'Active',
                User__c = testUser.Id
            );
            insert employee;

            Employment__c employment = new Employment__c(
                Company__c = company.Id,
                Employee__c = employee.Id,
                Employment_Key__c = 'G8B-EMPLOYMENT-001',
                Employment_Status__c = 'Active',
                Start_Date__c = Date.newInstance(2026, 1, 1)
            );
            insert employment;

            Tax_Code__c taxCode = new Tax_Code__c(
                Name = 'G8B VAT 15 Inclusive Partial',
                Code__c = 'G8B-VAT15I',
                Company__c = company.Id,
                Inclusive__c = true,
                Is_Active__c = true,
                Jurisdiction__c = 'BD',
                Recoverability__c = 'Partial',
                Treatment__c = 'Standard',
                Input_Tax_Account__c = inputTax.Id
            );
            insert taxCode;

            insert new Tax_Rate__c(
                Tax_Code__c = taxCode.Id,
                Rate_Key__c = 'G8B-VAT15I-2026',
                Rate__c = 15,
                Recoverable_Percent__c = 60,
                Country_Pack_Version__c = 'GENERIC-1',
                Effective_From__c = Date.newInstance(2026, 1, 1)
            );

            Expense_Claim__c plainClaim = createClaim(
                company.Id,
                employment.Id,
                Date.newInstance(2026, 9, 15),
                Date.newInstance(2026, 9, 15)
            );

            insert new List<Expense_Claim_Line__c>{
                new Expense_Claim_Line__c(
                    Expense_Claim__c = plainClaim.Id,
                    Expense_Date__c = Date.newInstance(2026, 9, 10),
                    Category__c = 'Travel',
                    Description__c = 'Transport',
                    Amount__c = 100,
                    Expense_Account__c = expenseAccount.Id
                ),
                new Expense_Claim_Line__c(
                    Expense_Claim__c = plainClaim.Id,
                    Expense_Date__c = Date.newInstance(2026, 9, 12),
                    Category__c = 'Meals',
                    Description__c = 'Meal',
                    Amount__c = 50,
                    Expense_Account__c = expenseAccount.Id
                )
            };
            approveClaim(plainClaim.Id, 'G8B-PLAIN');

            Expense_Claim__c taxClaim = createClaim(
                company.Id,
                employment.Id,
                Date.newInstance(2026, 9, 20),
                Date.newInstance(2026, 9, 20)
            );

            insert new Expense_Claim_Line__c(
                Expense_Claim__c = taxClaim.Id,
                Expense_Date__c = Date.newInstance(2026, 9, 18),
                Category__c = 'Hotel',
                Description__c = 'Hotel receipt including VAT',
                Amount__c = 115,
                Expense_Account__c = expenseAccount.Id,
                Tax_Code__c = taxCode.Id
            );
            approveClaim(taxClaim.Id, 'G8B-TAX');

            Expense_Claim__c closedPeriodClaim = createClaim(
                company.Id,
                employment.Id,
                Date.newInstance(2026, 10, 15),
                Date.newInstance(2026, 10, 15)
            );

            insert new Expense_Claim_Line__c(
                Expense_Claim__c = closedPeriodClaim.Id,
                Expense_Date__c = Date.newInstance(2026, 10, 12),
                Category__c = 'Office',
                Description__c = 'Closed period test',
                Amount__c = 30,
                Expense_Account__c = expenseAccount.Id
            );
            approveClaim(closedPeriodClaim.Id, 'G8B-CLOSED');
        }
    }

    @IsTest
    static void approvedClaimPostsExpenseAndLiability() {
        User testUser = getUser();

        System.runAs(testUser) {
            Expense_Claim__c claim =
                getClaimByDate(Date.newInstance(2026, 9, 15));

            SABExpenseClaimPostingService.PostingRequest request =
                new SABExpenseClaimPostingService.PostingRequest();
            request.expenseClaimId = claim.Id;
            request.requestKey = 'G8B-POST-PLAIN';

            Test.startTest();
            SABExpenseClaimPostingService.PostingResult result =
                SABExpenseClaimPostingService.postApprovedClaim(request);
            Test.stopTest();

            System.assertEquals(
                Decimal.valueOf('150.0000'),
                result.reimbursableTotal
            );
            System.assertEquals(
                Decimal.valueOf('0.0000'),
                result.recoverableTaxTotal
            );
            System.assertNotEquals(null, result.journalEntryId);
            System.assertNotEquals(null, result.accountingEventId);

            Expense_Claim__c storedClaim = [
                SELECT Status__c, Accounting_Event__c
                FROM Expense_Claim__c
                WHERE Id = :claim.Id
            ];
            System.assertEquals('Posted', storedClaim.Status__c);
            System.assertEquals(
                result.accountingEventId,
                storedClaim.Accounting_Event__c
            );

            List<Journal_Entry_Line__c> lines = [
                SELECT GL_Account__r.Account_Code__c,
                       Debit_Base__c,
                       Credit_Base__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c = :result.journalEntryId
            ];
            System.assertEquals(3, lines.size());

            Decimal debitTotal = 0;
            Decimal creditTotal = 0;
            for (Journal_Entry_Line__c line : lines) {
                debitTotal +=
                    line.Debit_Base__c == null ? 0 : line.Debit_Base__c;
                creditTotal +=
                    line.Credit_Base__c == null ? 0 : line.Credit_Base__c;
            }

            System.assertEquals(
                Decimal.valueOf('150.0000'),
                debitTotal
            );
            System.assertEquals(
                Decimal.valueOf('150.0000'),
                creditTotal
            );
        }
    }

    @IsTest
    static void inclusivePartialTaxPostsExpenseInputTaxAndLiability() {
        User testUser = getUser();

        System.runAs(testUser) {
            Expense_Claim__c claim =
                getClaimByDate(Date.newInstance(2026, 9, 20));

            SABExpenseClaimPostingService.PostingRequest request =
                new SABExpenseClaimPostingService.PostingRequest();
            request.expenseClaimId = claim.Id;
            request.requestKey = 'G8B-POST-TAX';

            Test.startTest();
            SABExpenseClaimPostingService.PostingResult result =
                SABExpenseClaimPostingService.postApprovedClaim(request);
            Test.stopTest();

            System.assertEquals(
                Decimal.valueOf('115.0000'),
                result.reimbursableTotal
            );
            System.assertEquals(
                Decimal.valueOf('9.0000'),
                result.recoverableTaxTotal
            );

            Expense_Claim_Line__c snapshot = [
                SELECT Tax_Rate__c,
                       Tax_Rate_Percent__c,
                       Taxable_Base__c,
                       Tax_Amount__c,
                       Recoverable_Tax_Amount__c,
                       Nonrecoverable_Tax_Amount__c,
                       Tax_Code_Key__c,
                       Tax_Jurisdiction__c,
                       Tax_Treatment__c,
                       Tax_Country_Pack_Version__c
                FROM Expense_Claim_Line__c
                WHERE Expense_Claim__c = :claim.Id
                LIMIT 1
            ];

            System.assertNotEquals(null, snapshot.Tax_Rate__c);
            System.assertEquals(
                Decimal.valueOf('15'),
                snapshot.Tax_Rate_Percent__c
            );
            System.assertEquals(
                Decimal.valueOf('100.0000'),
                snapshot.Taxable_Base__c
            );
            System.assertEquals(
                Decimal.valueOf('15.0000'),
                snapshot.Tax_Amount__c
            );
            System.assertEquals(
                Decimal.valueOf('9.0000'),
                snapshot.Recoverable_Tax_Amount__c
            );
            System.assertEquals(
                Decimal.valueOf('6.0000'),
                snapshot.Nonrecoverable_Tax_Amount__c
            );
            System.assertEquals(
                'G8B-VAT15I',
                snapshot.Tax_Code_Key__c
            );

            Map<String, Journal_Entry_Line__c> byCode =
                new Map<String, Journal_Entry_Line__c>();

            for (Journal_Entry_Line__c line : [
                SELECT GL_Account__r.Account_Code__c,
                       Debit_Base__c,
                       Credit_Base__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c = :result.journalEntryId
            ]) {
                byCode.put(
                    line.GL_Account__r.Account_Code__c,
                    line
                );
            }

            System.assertEquals(
                Decimal.valueOf('106.0000'),
                byCode.get('6100').Debit_Base__c
            );
            System.assertEquals(
                Decimal.valueOf('9.0000'),
                byCode.get('1300').Debit_Base__c
            );
            System.assertEquals(
                Decimal.valueOf('115.0000'),
                byCode.get('2200').Credit_Base__c
            );
        }
    }

    @IsTest
    static void postingIsIdempotentAfterClaimIsPosted() {
        User testUser = getUser();

        System.runAs(testUser) {
            Expense_Claim__c claim =
                getClaimByDate(Date.newInstance(2026, 9, 15));

            SABExpenseClaimPostingService.PostingRequest request =
                new SABExpenseClaimPostingService.PostingRequest();
            request.expenseClaimId = claim.Id;
            request.requestKey = 'G8B-POST-REPLAY';

            /*
             * The initial posting is the expensive path. Give it a fresh
             * governor-limit context. Once Test.stopTest() is called, Apex
             * returns to the outer test context, which still has ample
             * limits for the intentionally cheap Posted-claim replay path.
             */
            Test.startTest();
            SABExpenseClaimPostingService.PostingResult first =
                SABExpenseClaimPostingService.postApprovedClaim(request);
            Test.stopTest();

            SABExpenseClaimPostingService.PostingResult replay =
                SABExpenseClaimPostingService.postApprovedClaim(request);

            System.assertEquals(true, replay.replay);
            System.assertEquals(
                first.journalEntryId,
                replay.journalEntryId
            );
            System.assertEquals(
                first.accountingEventId,
                replay.accountingEventId
            );
        }
    }

    @IsTest
    static void closedAccountingPeriodBlocksPosting() {
        User testUser = getUser();

        System.runAs(testUser) {
            Expense_Claim__c claim =
                getClaimByDate(Date.newInstance(2026, 10, 15));

            SABExpenseClaimPostingService.PostingRequest request =
                new SABExpenseClaimPostingService.PostingRequest();
            request.expenseClaimId = claim.Id;
            request.requestKey = 'G8B-POST-CLOSED';

            Boolean blocked = false;

            Test.startTest();
            try {
                SABExpenseClaimPostingService.postApprovedClaim(request);
            } catch (
                SABExpenseClaimPostingService.ExpenseClaimPostingException ex
            ) {
                blocked = ex.getMessage().contains('must be Open');
            }
            Test.stopTest();

            System.assertEquals(true, blocked);

            Expense_Claim__c stored = [
                SELECT Status__c, Accounting_Event__c
                FROM Expense_Claim__c
                WHERE Id = :claim.Id
            ];
            System.assertEquals('Approved', stored.Status__c);
            System.assertEquals(null, stored.Accounting_Event__c);
        }
    }

    private static Expense_Claim__c createClaim(
        Id companyId,
        Id employmentId,
        Date claimDate,
        Date accountingDate
    ) {
        Expense_Claim__c claim = new Expense_Claim__c(
            Company__c = companyId,
            Claimant_Employment__c = employmentId,
            Claim_Date__c = claimDate,
            Accounting_Date__c = accountingDate,
            Currency__c = 'BDT',
            Status__c = 'Draft'
        );
        insert claim;
        return claim;
    }

    private static void approveClaim(
        Id claimId,
        String seed
    ) {
        SABExpenseClaimLifecycleService.submitClaim(
            claimId,
            seed + '-SUBMIT'
        );
        SABExpenseClaimLifecycleService.approveClaim(
            claimId,
            seed + '-APPROVE',
            'G8B posting fixture approval.'
        );
    }

    private static GL_Account__c glAccount(
        Id companyId,
        String code,
        String label,
        String accountType,
        String normalBalance,
        Boolean isControl,
        String controlType,
        Boolean manualPostingAllowed
    ) {
        GL_Account__c row = new GL_Account__c(
            Name = label,
            Company__c = companyId,
            Company_Account_Key__c = 'E8B-' + code,
            Account_Code__c = code,
            Account_Type__c = accountType,
            Normal_Balance__c = normalBalance,
            Is_Active__c = true,
            Is_Control_Account__c = isControl,
            Control_Type__c = controlType,
            Manual_Posting_Allowed__c = manualPostingAllowed
        );
        insert row;
        return row;
    }

    private static User createUser() {
        Profile profileRecord = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String seed =
            String.valueOf(Datetime.now().getTime());

        User row = new User(
            Alias = 'g8bexp',
            Email = 'g8bexp.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'G8B Expense Posting User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profileRecord.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = 'g8bexp.' + seed + '@example.test'
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
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN :REQUIRED_PERMISSION_SETS
        ]) {
            permissionSetIds.put(row.Name, row.Id);
        }

        System.assertEquals(
            REQUIRED_PERMISSION_SETS.size(),
            permissionSetIds.size(),
            'All G8B prerequisite Permission Sets must exist.'
        );

        List<PermissionSetAssignment> assignments =
            new List<PermissionSetAssignment>();

        for (String permissionSetName : REQUIRED_PERMISSION_SETS) {
            assignments.add(
                new PermissionSetAssignment(
                    AssigneeId = userRecord.Id,
                    PermissionSetId =
                        permissionSetIds.get(permissionSetName)
                )
            );
        }
        insert assignments;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'G8B Expense Posting User'
            LIMIT 1
        ];
    }

    private static Expense_Claim__c getClaimByDate(
        Date claimDate
    ) {
        Accounting_Company__c company = [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c = 'E8B'
            LIMIT 1
        ];

        return [
            SELECT Id, Status__c
            FROM Expense_Claim__c
            WHERE Company__c = :company.Id
              AND Claim_Date__c = :claimDate
            LIMIT 1
        ];
    }
}
