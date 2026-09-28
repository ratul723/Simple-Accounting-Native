@IsTest
private class SABBankStatementImportServiceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String IMPORT_PERMISSION_SET =
        'SAB_Import_Bank_Statement_Action';

    @TestSetup
    static void setupFixture() {
        User testUser =
            createUser();

        assignPermissionSets(
            testUser
        );

        /*
         * PermissionSetAssignment is a setup object, while the accounting
         * records below are non-setup objects. Keep the non-setup fixture
         * creation inside System.runAs() so the test does not perform mixed
         * DML in one execution context.
         */
        System.runAs(testUser) {
            Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    'G5A Bank Company',
                Company_Key__c =
                    'BKI',
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
            Is_Active__c =
                true,
            Effective_From__c =
                Date.today(),
            Grant_Key__c =
                'G5A-BANK-ACCESS',
            Role__c =
                'Finance Manager'
        );

        GL_Account__c bankGL =
            new GL_Account__c(
                Name =
                    'G5A Main Bank GL',
                Company__c =
                    company.Id,
                Company_Account_Key__c =
                    'BKI-1100',
                Account_Code__c =
                    '1100',
                Account_Type__c =
                    'Asset',
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
        insert bankGL;

            Bank_Account__c bankAccount =
                new Bank_Account__c(
                    Name =
                        'G5A BDT Main Bank',
                    Company__c =
                        company.Id,
                    Bank_Name__c =
                        'G5A Bank',
                    Currency__c =
                        'BDT',
                    GL_Account__c =
                        bankGL.Id,
                    Is_Active__c =
                        true
                );
            insert bankAccount;
        }
    }

    @IsTest
    static void importAndValidateBalancedStatement() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            SABBankStatementImportService.ImportRequest request =
                buildBalancedRequest();

            Test.startTest();

            SABBankStatementImportService.ImportResult imported =
                SABBankStatementImportService.importStatement(
                    request
                );

            SABBankStatementImportService.ImportResult validated =
                SABBankStatementImportService.validateStatement(
                    imported.bankStatementId
                );

            Test.stopTest();

            System.assertEquals(
                false,
                imported.replay
            );

            System.assertEquals(
                'Imported',
                imported.status
            );

            System.assertEquals(
                3,
                imported.lineCount
            );

            System.assertEquals(
                Decimal.valueOf('1000.0000'),
                imported.openingAmount
            );

            System.assertEquals(
                Decimal.valueOf('50.0000'),
                imported.lineNetAmount
            );

            System.assertEquals(
                Decimal.valueOf('1050.0000'),
                imported.calculatedClosingAmount
            );

            System.assertEquals(
                true,
                imported.balanced
            );

            System.assertEquals(
                'Validated',
                validated.status
            );

            Bank_Statement__c stored = [
                SELECT Status__c,
                       Company__c,
                       Bank_Account__c,
                       Currency__c,
                       Import_Fingerprint__c
                FROM Bank_Statement__c
                WHERE Id =
                    :imported.bankStatementId
            ];

            System.assertEquals(
                'Validated',
                stored.Status__c
            );

            System.assertEquals(
                'BDT',
                stored.Currency__c
            );

            System.assertNotEquals(
                null,
                stored.Import_Fingerprint__c
            );

            System.assertEquals(
                3,
                [
                    SELECT COUNT()
                    FROM Bank_Statement_Line__c
                    WHERE Bank_Statement__c =
                        :stored.Id
                ]
            );
        }
    }

    @IsTest
    static void sameFingerprintReplaysExistingStatement() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            SABBankStatementImportService.ImportRequest request =
                buildBalancedRequest();

            request.importFingerprint =
                'G5A-EXPLICIT-FINGERPRINT';

            SABBankStatementImportService.ImportResult first =
                SABBankStatementImportService.importStatement(
                    request
                );

            Test.startTest();

            SABBankStatementImportService.ImportResult second =
                SABBankStatementImportService.importStatement(
                    request
                );

            Test.stopTest();

            System.assertEquals(
                true,
                second.replay
            );

            System.assertEquals(
                first.bankStatementId,
                second.bankStatementId
            );

            System.assertEquals(
                1,
                [
                    SELECT COUNT()
                    FROM Bank_Statement__c
                    WHERE Import_Fingerprint__c =
                        'G5A-EXPLICIT-FINGERPRINT'
                ]
            );
        }
    }

    @IsTest
    static void duplicateLineFingerprintIsBlocked() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            SABBankStatementImportService.ImportRequest request =
                buildBalancedRequest();

            request.lines[0].lineFingerprint =
                'DUPLICATE-LINE';
            request.lines[1].lineFingerprint =
                'DUPLICATE-LINE';

            Boolean blocked =
                false;

            Test.startTest();

            try {
                SABBankStatementImportService.importStatement(
                    request
                );
            } catch (
                SABBankStatementImportService.BankStatementImportException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'Duplicate Bank Statement line fingerprints'
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
    static void validationBlocksUnbalancedStatement() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            SABBankStatementImportService.ImportRequest request =
                buildBalancedRequest();

            request.closingAmount =
                999;

            SABBankStatementImportService.ImportResult imported =
                SABBankStatementImportService.importStatement(
                    request
                );

            Boolean blocked =
                false;

            Test.startTest();

            try {
                SABBankStatementImportService.validateStatement(
                    imported.bankStatementId
                );
            } catch (
                SABBankStatementImportService.BankStatementImportException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'does not balance'
                    );
            }

            Test.stopTest();

            System.assertEquals(
                true,
                blocked
            );

            System.assertEquals(
                'Imported',
                [
                    SELECT Status__c
                    FROM Bank_Statement__c
                    WHERE Id =
                        :imported.bankStatementId
                ].Status__c
            );
        }
    }

    @IsTest
    static void currencyMismatchIsBlocked() {
        User testUser =
            getUser();

        System.runAs(testUser) {
            SABBankStatementImportService.ImportRequest request =
                buildBalancedRequest();

            request.transactionCurrency =
                'USD';

            Boolean blocked =
                false;

            Test.startTest();

            try {
                SABBankStatementImportService.importStatement(
                    request
                );
            } catch (
                SABBankStatementImportService.BankStatementImportException ex
            ) {
                blocked =
                    ex.getMessage().contains(
                        'must match the Bank Account currency'
                    );
            }

            Test.stopTest();

            System.assertEquals(
                true,
                blocked
            );
        }
    }

    private static SABBankStatementImportService.ImportRequest
        buildBalancedRequest()
    {
        Bank_Account__c bankAccount = [
            SELECT Id
            FROM Bank_Account__c
            WHERE Name =
                'G5A BDT Main Bank'
            LIMIT 1
        ];

        SABBankStatementImportService.ImportRequest request =
            new SABBankStatementImportService.ImportRequest();

        request.bankAccountId =
            bankAccount.Id;
        request.statementStartDate =
            Date.newInstance(
                2026,
                9,
                1
            );
        request.statementEndDate =
            Date.newInstance(
                2026,
                9,
                30
            );
        request.openingAmount =
            1000;
        request.closingAmount =
            1050;
        request.transactionCurrency =
            'BDT';

        request.lines =
            new List<SABBankStatementImportService.LineRequest>{
                line(
                    1,
                    Date.newInstance(2026, 9, 5),
                    200,
                    'BANK-LINE-1',
                    'Customer deposit'
                ),
                line(
                    2,
                    Date.newInstance(2026, 9, 12),
                    -100,
                    'BANK-LINE-2',
                    'Supplier payment'
                ),
                line(
                    3,
                    Date.newInstance(2026, 9, 20),
                    -50,
                    'BANK-LINE-3',
                    'Bank charge'
                )
            };

        return request;
    }

    private static SABBankStatementImportService.LineRequest
        line(
            Decimal lineNumber,
            Date transactionDate,
            Decimal amount,
            String providerLineId,
            String reference
        )
    {
        SABBankStatementImportService.LineRequest lineRequest =
            new SABBankStatementImportService.LineRequest();

        lineRequest.lineNumber =
            lineNumber;
        lineRequest.transactionDate =
            transactionDate;
        lineRequest.valueDate =
            transactionDate;
        lineRequest.amount =
            amount;
        lineRequest.providerLineId =
            providerLineId;
        lineRequest.reference =
            reference;
        lineRequest.sourceRawText =
            providerLineId
            + '|'
            + reference
            + '|'
            + String.valueOf(amount);

        return lineRequest;
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
            String.valueOf(
                DateTime.now().getTime()
            );

        User testUser =
            new User(
                Alias =
                    'g5abank',
                Email =
                    'g5abank.'
                    + seed
                    + '@example.test',
                EmailEncodingKey =
                    'UTF-8',
                LastName =
                    'G5A Bank User',
                LanguageLocaleKey =
                    'en_US',
                LocaleSidKey =
                    'en_US',
                ProfileId =
                    profileRecord.Id,
                TimeZoneSidKey =
                    'Asia/Dhaka',
                Username =
                    'g5abank.'
                    + seed
                    + '@example.test'
            );

        insert testUser;

        return testUser;
    }

    private static void assignPermissionSets(
        User testUser
    ) {
        Set<String> names =
            new Set<String>{
                ADMIN_PERMISSION_SET,
                IMPORT_PERMISSION_SET
            };

        Map<String, Id> idsByName =
            new Map<String, Id>();

        for (PermissionSet permissionSetRecord : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN :names
        ]) {
            idsByName.put(
                permissionSetRecord.Name,
                permissionSetRecord.Id
            );
        }

        System.assertEquals(
            2,
            idsByName.size(),
            'Required G5A permission sets must exist.'
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId =
                    testUser.Id,
                PermissionSetId =
                    idsByName.get(
                        ADMIN_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId =
                    testUser.Id,
                PermissionSetId =
                    idsByName.get(
                        IMPORT_PERMISSION_SET
                    )
            )
        };
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                'G5A Bank User'
            LIMIT 1
        ];
    }
}
