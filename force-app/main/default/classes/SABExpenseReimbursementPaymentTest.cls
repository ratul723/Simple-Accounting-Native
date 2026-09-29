@IsTest
private class SABExpenseReimbursementPaymentTest {

    private static final Set<String> REQUIRED_PERMISSION_SETS =
        new Set<String>{
            'SAB_Remaining_Fields_Admin',
            'SAB_Post_Journal_Action',
            'SAB_Expense_Reimbursement_Action'
        };

    @TestSetup
    static void setupFixture() {
        User testUser = createUser();
        assignPermissionSets(testUser);

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c = 'G8C Company',
                    Company_Key__c = 'E8C',
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
                Grant_Key__c = 'G8C-ACCESS',
                Is_Active__c = true,
                Role__c = 'Finance Manager'
            );

            GL_Account__c liability = glAccount(
                company.Id,
                '2200',
                'Employee Reimbursement Liability',
                'Liability',
                'Credit',
                true,
                'Other'
            );

            GL_Account__c bankGL = glAccount(
                company.Id,
                '1100',
                'Operating Bank',
                'Asset',
                'Debit',
                false,
                'None'
            );

            company.Employee_Reimbursement_Liability_Account__c =
                liability.Id;
            update company;

            Bank_Account__c bank =
                new Bank_Account__c(
                    Name = 'G8C Operating Bank',
                    Company__c = company.Id,
                    Currency__c = 'BDT',
                    GL_Account__c = bankGL.Id,
                    Is_Active__c = true
                );
            insert bank;

            insert new Accounting_Period__c(
                Name = 'September 2026',
                Company__c = company.Id,
                Company_Period_Key__c =
                    'E8C-2026-09',
                Period_Key__c =
                    'E8C-2026-09',
                Start_Date__c =
                    Date.newInstance(2026, 9, 1),
                End_Date__c =
                    Date.newInstance(2026, 9, 30),
                Fiscal_Year__c = 2026,
                Fiscal_Quarter__c = 3,
                Period_Number__c = 9,
                Status__c = 'Open'
            );

            insert new Accounting_Payment__c(
                Company__c = company.Id,
                Bank_Account__c = bank.Id,
                Direction__c = 'Disbursement',
                Method__c = 'Bank Transfer',
                Reference__c = 'G8C-REIMB-001',
                Amount__c = 150,
                Transaction_Currency__c = 'BDT',
                Effective_Date__c =
                    Date.newInstance(2026, 9, 25),
                Processing_State__c = 'Draft'
            );
        }
    }

    @IsTest
    static void reimbursementPaymentClearsLiabilityAndCreditsBank() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Payment__c payment =
                getPayment();

            SABExpenseReimbursementPaymentService.authorizePayment(
                    payment.Id,
                    'G8C-AUTH-001'
                );

            SABExpenseReimbursementPaymentService.submitPayment(
                    payment.Id,
                    'G8C-PROVIDER-001',
                    'G8C-SUBMIT-001'
                );

            Test.startTest();

            SABExpenseReimbursementPaymentService.PaymentResult
                result =
                    SABExpenseReimbursementPaymentService.recordSucceededAndPost(
                            payment.Id,
                            'G8C-POST-001'
                        );

            Test.stopTest();

            System.assertEquals(
                'Succeeded',
                result.state
            );
            System.assertNotEquals(
                null,
                result.journalEntryId
            );
            System.assertNotEquals(
                null,
                result.accountingEventId
            );

            Accounting_Payment__c stored = [
                SELECT Processing_State__c,
                       Accounting_Event__c
                FROM Accounting_Payment__c
                WHERE Id = :payment.Id
            ];

            System.assertEquals(
                'Succeeded',
                stored.Processing_State__c
            );
            System.assertEquals(
                result.accountingEventId,
                stored.Accounting_Event__c
            );

            Map<String, Journal_Entry_Line__c> byCode =
                new Map<String, Journal_Entry_Line__c>();

            for (Journal_Entry_Line__c line : [
                SELECT GL_Account__r.Account_Code__c,
                       Debit_Base__c,
                       Credit_Base__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c =
                    :result.journalEntryId
            ]) {
                byCode.put(
                    line.GL_Account__r.Account_Code__c,
                    line
                );
            }

            System.assertEquals(
                Decimal.valueOf('150.0000'),
                byCode.get('2200').Debit_Base__c
            );
            System.assertEquals(
                Decimal.valueOf('150.0000'),
                byCode.get('1100').Credit_Base__c
            );

            SABExpenseReimbursementPaymentService.PaymentResult
                replay =
                    SABExpenseReimbursementPaymentService.recordSucceededAndPost(
                            payment.Id,
                            'G8C-POST-001'
                        );

            System.assertEquals(
                true,
                replay.replay
            );
            System.assertEquals(
                result.journalEntryId,
                replay.journalEntryId
            );
        }
    }

    private static GL_Account__c glAccount(
        Id companyId,
        String code,
        String label,
        String accountType,
        String normalBalance,
        Boolean isControl,
        String controlType
    ) {
        GL_Account__c row =
            new GL_Account__c(
                Name = label,
                Company__c = companyId,
                Company_Account_Key__c =
                    'E8C-' + code,
                Account_Code__c = code,
                Account_Type__c = accountType,
                Normal_Balance__c = normalBalance,
                Is_Active__c = true,
                Is_Control_Account__c = isControl,
                Control_Type__c = controlType,
                Manual_Posting_Allowed__c =
                    !isControl
            );
        insert row;
        return row;
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
            Alias = 'g8cpay',
            Email =
                'g8cpay.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName =
                'G8C Reimbursement User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username =
                'g8cpay.' + seed + '@example.test'
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
                'G8C Reimbursement User'
            LIMIT 1
        ];
    }

    private static Accounting_Payment__c getPayment() {
        return [
            SELECT Id
            FROM Accounting_Payment__c
            WHERE Reference__c =
                'G8C-REIMB-001'
            LIMIT 1
        ];
    }
}
