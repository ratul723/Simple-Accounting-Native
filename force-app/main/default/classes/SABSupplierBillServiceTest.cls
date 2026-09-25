@IsTest
private class SABSupplierBillServiceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String APPROVE_PERMISSION_SET =
        'SAB_Approve_Financial_Document_Action';

    @TestSetup
    static void setupFixture() {
        Profile profileRecord = [
            SELECT Id
            FROM Profile
            WHERE Id = :UserInfo.getProfileId()
            LIMIT 1
        ];

        String seed =
            String.valueOf(
                DateTime.now().getTime()
            );

        User testUser = new User(
            Alias = 'sabap',
            Email =
                'sabap.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB AP User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profileRecord.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username =
                'sabap.' + seed + '@example.test'
        );

        insert testUser;

        Map<String, Id> permissionSetIds =
            new Map<String, Id>();

        for (PermissionSet permissionSetRecord : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN (
                :ADMIN_PERMISSION_SET,
                :APPROVE_PERMISSION_SET
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
            'G3A tests require the existing broad SAB field/object permission set and financial-document approval action permission set.'
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        ADMIN_PERMISSION_SET
                    )
            ),
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId =
                    permissionSetIds.get(
                        APPROVE_PERMISSION_SET
                    )
            )
        };

        System.runAs(testUser) {
            Accounting_Company__c company =
                new Accounting_Company__c(
                    Name__c = 'G3A Company',
                    Company_Key__c = 'G3A',
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
                Is_Active__c = true,
                Effective_From__c =
                    Date.today(),
                Grant_Key__c =
                    'G3A-ACCESS',
                Role__c =
                    'Finance Manager'
            );

            insert new Accounting_Period__c(
                Name = 'September 2026',
                Company__c = company.Id,
                Company_Period_Key__c =
                    'G3A-2026-09',
                Period_Key__c =
                    '2026-09',
                Start_Date__c =
                    Date.newInstance(
                        2026,
                        9,
                        1
                    ),
                End_Date__c =
                    Date.newInstance(
                        2026,
                        9,
                        30
                    ),
                Fiscal_Year__c = 2026,
                Fiscal_Quarter__c = 3,
                Period_Number__c = 9,
                Status__c = 'Open'
            );

            GL_Account__c apControl =
                new GL_Account__c(
                    Name = 'Accounts Payable',
                    Company__c = company.Id,
                    Company_Account_Key__c =
                        'G3A-2000',
                    Account_Code__c = '2000',
                    Account_Type__c =
                        'Liability',
                    Normal_Balance__c =
                        'Credit',
                    Is_Active__c = true,
                    Is_Control_Account__c =
                        true,
                    Control_Type__c = 'AP',
                    Manual_Posting_Allowed__c =
                        false
                );

            GL_Account__c expense =
                new GL_Account__c(
                    Name = 'Office Expense',
                    Company__c = company.Id,
                    Company_Account_Key__c =
                        'G3A-6000',
                    Account_Code__c = '6000',
                    Account_Type__c =
                        'Expense',
                    Normal_Balance__c =
                        'Debit',
                    Is_Active__c = true,
                    Is_Control_Account__c =
                        false,
                    Control_Type__c = 'None',
                    Manual_Posting_Allowed__c =
                        true
                );

            insert new List<GL_Account__c>{
                apControl,
                expense
            };

            Account supplierAccount =
                new Account(
                    Name = 'G3A Supplier'
                );

            insert supplierAccount;

            Party_Accounting_Profile__c supplierProfile =
                new Party_Accounting_Profile__c(
                    Company__c = company.Id,
                    Account__c =
                        supplierAccount.Id,
                    Profile_Key__c =
                        'G3A-SUPPLIER',
                    Is_Supplier__c = true,
                    Is_Customer__c = false,
                    Is_Active__c = true,
                    AP_Control_Account__c =
                        apControl.Id
                );

            insert supplierProfile;

            Supplier_Bill__c bill =
                new Supplier_Bill__c(
                    Company__c = company.Id,
                    Supplier_Profile__c =
                        supplierProfile.Id,
                    Document_Type__c = 'Bill',
                    Document_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            10
                        ),
                    Accounting_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            10
                        ),
                    Due_Date__c =
                        Date.newInstance(
                            2026,
                            10,
                            10
                        ),
                    Transaction_Currency__c =
                        'BDT',
                    Vendor_Reference__c =
                        'SUP-INV-001',
                    Status__c = 'Draft'
                );

            insert bill;

            insert new Bill_Line__c(
                Supplier_Bill__c = bill.Id,
                Line_Number__c = 1,
                Description__c =
                    'Office supplies',
                Quantity__c = 2,
                Unit_Price__c = 125,
                Net_Amount__c = 250,
                Recoverable_Tax_Amount__c =
                    25,
                Nonrecoverable_Tax_Amount__c =
                    5,
                Expense_or_Asset_Account__c =
                    expense.Id
            );
        }
    }

    @IsTest
    static void validDraftPassesAndCalculatesTotals() {
        User testUser = getUser();
        Supplier_Bill__c bill =
            getFixtureBill();

        System.runAs(testUser) {
            Test.startTest();

            SABSupplierBillService.ValidationResult result =
                SABSupplierBillService.validateForSubmission(
                    bill.Id
                );

            Test.stopTest();

            System.assertEquals(
                true,
                result.isValid,
                String.join(
                    result.errors,
                    ' | '
                )
            );

            System.assertEquals(
                Decimal.valueOf('250'),
                result.calculatedSubtotal
            );

            System.assertEquals(
                Decimal.valueOf('30'),
                result.calculatedTaxTotal
            );

            System.assertEquals(
                Decimal.valueOf('280'),
                result.calculatedTotal
            );
        }
    }

    @IsTest
    static void submitCalculatesHeaderLocksLinesAndIsIdempotent() {
        User testUser = getUser();
        Supplier_Bill__c bill =
            getFixtureBill();

        System.runAs(testUser) {
            Test.startTest();

            SABSupplierBillService.TransitionResult firstResult =
                SABSupplierBillService.submit(
                    bill.Id,
                    'G3A-SUBMIT-001'
                );

            SABSupplierBillService.TransitionResult replayResult =
                SABSupplierBillService.submit(
                    bill.Id,
                    'G3A-SUBMIT-001'
                );

            Test.stopTest();

            Supplier_Bill__c submitted = [
                SELECT Status__c,
                       Functional_Currency__c,
                       Exchange_Rate__c,
                       Subtotal__c,
                       Tax_Total__c,
                       Total__c
                FROM Supplier_Bill__c
                WHERE Id = :bill.Id
            ];

            System.assertEquals(
                'Submitted',
                submitted.Status__c
            );

            System.assertEquals(
                'BDT',
                submitted.Functional_Currency__c
            );

            System.assertEquals(
                Decimal.valueOf('1'),
                submitted.Exchange_Rate__c
            );

            System.assertEquals(
                Decimal.valueOf('250'),
                submitted.Subtotal__c
            );

            System.assertEquals(
                Decimal.valueOf('30'),
                submitted.Tax_Total__c
            );

            System.assertEquals(
                Decimal.valueOf('280'),
                submitted.Total__c
            );

            System.assertEquals(
                false,
                firstResult.idempotentReplay
            );

            System.assertEquals(
                true,
                replayResult.idempotentReplay
            );

            Bill_Line__c line = [
                SELECT Id, Description__c
                FROM Bill_Line__c
                WHERE Supplier_Bill__c =
                    :bill.Id
                LIMIT 1
            ];

            line.Description__c =
                'Attempted change';

            Boolean blocked = false;

            try {
                update line;
            } catch (DmlException ex) {
                blocked =
                    ex.getMessage().contains(
                        'Bill Lines can only be changed while the Supplier Bill is Draft.'
                    );
            }

            System.assertEquals(
                true,
                blocked,
                'Submitted Supplier Bill lines must be locked.'
            );
        }
    }

    @IsTest
    static void approvalPassesPostingReadiness() {
        User testUser = getUser();
        Supplier_Bill__c bill =
            getFixtureBill();

        System.runAs(testUser) {
            SABSupplierBillService.submit(
                bill.Id,
                'G3A-SUBMIT-APPROVE'
            );

            Test.startTest();

            SABSupplierBillService.TransitionResult approved =
                SABSupplierBillService.approve(
                    bill.Id,
                    'G3A-APPROVE-001',
                    'Supplier invoice reviewed.'
                );

            SABSupplierBillService.assertApprovedForPosting(
                bill.Id
            );

            Test.stopTest();

            System.assertEquals(
                'Approved',
                approved.newStatus
            );

            Supplier_Bill__c refreshed = [
                SELECT Status__c
                FROM Supplier_Bill__c
                WHERE Id = :bill.Id
            ];

            System.assertEquals(
                'Approved',
                refreshed.Status__c
            );
        }
    }

    @IsTest
    static void duplicateVendorReferenceFailsWithoutException() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Company__c company =
                getCompany();

            Party_Accounting_Profile__c profile =
                getSupplierProfile();

            GL_Account__c expense =
                getExpenseAccount();

            Supplier_Bill__c duplicateBill =
                new Supplier_Bill__c(
                    Company__c = company.Id,
                    Supplier_Profile__c =
                        profile.Id,
                    Document_Type__c =
                        'Bill',
                    Document_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            11
                        ),
                    Accounting_Date__c =
                        Date.newInstance(
                            2026,
                            9,
                            11
                        ),
                    Due_Date__c =
                        Date.newInstance(
                            2026,
                            10,
                            11
                        ),
                    Transaction_Currency__c =
                        'BDT',
                    Vendor_Reference__c =
                        'SUP-INV-001',
                    Status__c = 'Draft'
                );

            insert duplicateBill;

            insert new Bill_Line__c(
                Supplier_Bill__c =
                    duplicateBill.Id,
                Line_Number__c = 1,
                Description__c =
                    'Duplicate test',
                Quantity__c = 1,
                Unit_Price__c = 50,
                Net_Amount__c = 50,
                Expense_or_Asset_Account__c =
                    expense.Id
            );

            Test.startTest();

            SABSupplierBillService.ValidationResult result =
                SABSupplierBillService.validateForSubmission(
                    duplicateBill.Id
                );

            Test.stopTest();

            System.assertEquals(
                false,
                result.isValid
            );

            System.assert(
                containsError(
                    result.errors,
                    'already exists'
                ),
                String.join(
                    result.errors,
                    ' | '
                )
            );
        }
    }

    @IsTest
    static void foreignCurrencyRequiresPositiveRate() {
        User testUser = getUser();
        Supplier_Bill__c bill =
            getFixtureBill();

        System.runAs(testUser) {
            bill.Transaction_Currency__c =
                'USD';
            bill.Exchange_Rate__c =
                null;

            update bill;

            Test.startTest();

            SABSupplierBillService.ValidationResult result =
                SABSupplierBillService.validateForSubmission(
                    bill.Id
                );

            Test.stopTest();

            System.assertEquals(
                false,
                result.isValid
            );

            System.assert(
                containsError(
                    result.errors,
                    'positive Exchange Rate'
                ),
                String.join(
                    result.errors,
                    ' | '
                )
            );
        }
    }

    @IsTest
    static void directStatusChangeIsBlocked() {
        User testUser = getUser();
        Supplier_Bill__c bill =
            getFixtureBill();

        System.runAs(testUser) {
            bill.Status__c =
                'Submitted';

            Boolean blocked = false;

            Test.startTest();

            try {
                update bill;
            } catch (DmlException ex) {
                blocked =
                    ex.getMessage().contains(
                        'controlled lifecycle service'
                    );
            }

            Test.stopTest();

            System.assertEquals(
                true,
                blocked,
                'Direct status DML must not bypass the lifecycle service.'
            );
        }
    }

    @IsTest
    static void submittedBillCanReturnToDraftForCorrection() {
        User testUser = getUser();
        Supplier_Bill__c bill =
            getFixtureBill();

        System.runAs(testUser) {
            SABSupplierBillService.submit(
                bill.Id,
                'G3A-SUBMIT-RETURN'
            );

            Test.startTest();

            SABSupplierBillService.TransitionResult result =
                SABSupplierBillService.returnToDraft(
                    bill.Id,
                    'G3A-RETURN-001',
                    'Vendor reference needs correction.'
                );

            Test.stopTest();

            System.assertEquals(
                'Draft',
                result.newStatus
            );

            Supplier_Bill__c draftBill = [
                SELECT Status__c,
                       Vendor_Reference__c
                FROM Supplier_Bill__c
                WHERE Id = :bill.Id
            ];

            draftBill.Vendor_Reference__c =
                'SUP-INV-001-CORRECTED';

            update draftBill;

            System.assertEquals(
                'SUP-INV-001-CORRECTED',
                [
                    SELECT Vendor_Reference__c
                    FROM Supplier_Bill__c
                    WHERE Id = :bill.Id
                ].Vendor_Reference__c
            );
        }
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName =
                'SAB AP User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getCompany() {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c =
                'G3A'
            LIMIT 1
        ];
    }

    private static Supplier_Bill__c getFixtureBill() {
        return [
            SELECT Id, Status__c,
                   Transaction_Currency__c,
                   Exchange_Rate__c
            FROM Supplier_Bill__c
            WHERE Vendor_Reference__c =
                'SUP-INV-001'
            LIMIT 1
        ];
    }

    private static Party_Accounting_Profile__c
        getSupplierProfile()
    {
        return [
            SELECT Id
            FROM Party_Accounting_Profile__c
            WHERE Profile_Key__c =
                'G3A-SUPPLIER'
            LIMIT 1
        ];
    }

    private static GL_Account__c getExpenseAccount() {
        return [
            SELECT Id
            FROM GL_Account__c
            WHERE Company_Account_Key__c =
                'G3A-6000'
            LIMIT 1
        ];
    }

    private static Boolean containsError(
        List<String> errors,
        String token
    ) {
        if (errors == null) {
            return false;
        }

        for (String errorMessage : errors) {
            if (
                errorMessage != null
                && errorMessage.contains(
                    token
                )
            ) {
                return true;
            }
        }

        return false;
    }
}
