@IsTest
private class SABAccountsPayableWorkspaceControllerTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String WORKSPACE_PERMISSION_SET =
        'SAB_Accounts_Payable_Workspace_User';

    @TestSetup
    static void setupFixture() {
        Profile profileRecord = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String seed = String.valueOf(Datetime.now().getTime());

        User testUser = new User(
            Alias = 'sabapw',
            Email = 'sabapw.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB AP Workspace User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profileRecord.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = 'sabapw.' + seed + '@example.test'
        );
        insert testUser;

        Map<String, Id> permissionIds = new Map<String, Id>();
        for (PermissionSet row : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN (
                :ADMIN_PERMISSION_SET,
                :WORKSPACE_PERMISSION_SET
            )
        ]) {
            permissionIds.put(row.Name, row.Id);
        }

        System.assertEquals(2, permissionIds.size());

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId = permissionIds.get(ADMIN_PERMISSION_SET)
            ),
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId = permissionIds.get(WORKSPACE_PERMISSION_SET)
            )
        };

        System.runAs(testUser) {
            Accounting_Company__c company = new Accounting_Company__c(
                Name__c = 'G3E AP Workspace Company',
                Company_Key__c = 'A9P',
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
                Effective_From__c = Date.today(),
                Grant_Key__c = 'A9P-ACCESS',
                Role__c = 'Finance Manager'
            );

            insert new Accounting_Period__c(
                Name = 'October 2026',
                Company__c = company.Id,
                Company_Period_Key__c = 'A9P-2026-10',
                Period_Key__c = '2026-10',
                Start_Date__c = Date.newInstance(2026, 10, 1),
                End_Date__c = Date.newInstance(2026, 10, 31),
                Fiscal_Year__c = 2026,
                Fiscal_Quarter__c = 4,
                Period_Number__c = 10,
                Status__c = 'Open'
            );

            GL_Account__c apControl = new GL_Account__c(
                Name = 'Accounts Payable',
                Company__c = company.Id,
                Company_Account_Key__c = 'A9P-2000',
                Account_Code__c = '2000',
                Account_Type__c = 'Liability',
                Normal_Balance__c = 'Credit',
                Is_Active__c = true,
                Is_Control_Account__c = true,
                Control_Type__c = 'AP',
                Manual_Posting_Allowed__c = false
            );

            GL_Account__c expense = new GL_Account__c(
                Name = 'Office Expense',
                Company__c = company.Id,
                Company_Account_Key__c = 'A9P-6000',
                Account_Code__c = '6000',
                Account_Type__c = 'Expense',
                Normal_Balance__c = 'Debit',
                Is_Active__c = true,
                Is_Control_Account__c = false,
                Control_Type__c = 'None',
                Manual_Posting_Allowed__c = true
            );

            insert new List<GL_Account__c>{ apControl, expense };

            Account supplierAccount = new Account(
                Name = 'AP Workspace Supplier'
            );
            insert supplierAccount;

            Party_Accounting_Profile__c profile = new Party_Accounting_Profile__c(
                Company__c = company.Id,
                Account__c = supplierAccount.Id,
                Profile_Key__c = 'A9P-SUPPLIER',
                Is_Supplier__c = true,
                Is_Customer__c = false,
                Is_Active__c = true,
                AP_Control_Account__c = apControl.Id
            );
            insert profile;

            Supplier_Bill__c bill = new Supplier_Bill__c(
                Company__c = company.Id,
                Supplier_Profile__c = profile.Id,
                Document_Type__c = 'Bill',
                Document_Date__c = Date.newInstance(2026, 10, 1),
                Accounting_Date__c = Date.newInstance(2026, 10, 1),
                Due_Date__c = Date.newInstance(2026, 10, 31),
                Transaction_Currency__c = 'BDT',
                Vendor_Reference__c = 'AP-WORKSPACE-001',
                Status__c = 'Draft'
            );
            insert bill;

            insert new Bill_Line__c(
                Supplier_Bill__c = bill.Id,
                Line_Number__c = 1,
                Description__c = 'AP workspace test line',
                Quantity__c = 1,
                Unit_Price__c = 100,
                Net_Amount__c = 100,
                Expense_or_Asset_Account__c = expense.Id
            );

            GL_Account__c bankGL = new GL_Account__c(
                Name = 'Main Bank',
                Company__c = company.Id,
                Company_Account_Key__c = 'A9P-1100',
                Account_Code__c = '1100',
                Account_Type__c = 'Asset',
                Normal_Balance__c = 'Debit',
                Is_Active__c = true,
                Is_Control_Account__c = false,
                Control_Type__c = 'None',
                Manual_Posting_Allowed__c = true
            );
            insert bankGL;

            Bank_Account__c bank = new Bank_Account__c(
                Name = 'AP Workspace Bank',
                Company__c = company.Id,
                Bank_Name__c = 'Example Bank',
                Currency__c = 'BDT',
                GL_Account__c = bankGL.Id,
                Is_Active__c = true
            );
            insert bank;

            insert new Accounting_Payment__c(
                Company__c = company.Id,
                Party_Profile__c = profile.Id,
                Bank_Account__c = bank.Id,
                Direction__c = 'Disbursement',
                Method__c = 'Bank Transfer',
                Reference__c = 'AP-WORKSPACE-PAY-001',
                Amount__c = 50,
                Transaction_Currency__c = 'BDT',
                Effective_Date__c = Date.newInstance(2026, 10, 15),
                Processing_State__c = 'Draft'
            );
        }
    }

    @IsTest
    static void workspaceReturnsCompanyBillsPaymentsAndSuppliers() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Company__c company = [
                SELECT Id
                FROM Accounting_Company__c
                WHERE Company_Key__c = 'A9P'
                LIMIT 1
            ];

            Test.startTest();
            SABAccountsPayableWorkspaceController.WorkspaceDTO result =
                SABAccountsPayableWorkspaceController.getWorkspace(
                    company.Id,
                    Date.newInstance(2026, 10, 31),
                    'All',
                    null,
                    false
                );
            Test.stopTest();

            System.assertEquals(
                'G3E AP Workspace Company',
                result.companyName
            );
            System.assertEquals(1, result.suppliers.size());
            System.assertEquals(1, result.bills.size());
            System.assertEquals(1, result.pendingBills);
            System.assertEquals(1, result.payments.size());
            System.assertEquals(1, result.pendingPayments);
            System.assertEquals(
                Decimal.valueOf('50'),
                result.pendingPaymentAmount
            );
        }
    }

    @IsTest
    static void unauthorizedCompanyIsBlocked() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Company__c company = new Accounting_Company__c(
                Name__c = 'Unauthorized AP Company',
                Company_Key__c = 'A9Q',
                Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT',
                Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active',
                Is_Active__c = true
            );
            insert company;

            System.assertEquals(
                false,
                SABCompanyAccessService.hasCompanyAccess(company.Id)
            );

            Boolean blocked = false;
            try {
                SABAccountsPayableWorkspaceController.getWorkspace(
                    company.Id,
                    Date.today(),
                    'All',
                    null,
                    false
                );
            } catch (Exception ex) {
                blocked = true;
            }

            System.assertEquals(true, blocked);
        }
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB AP Workspace User'
            LIMIT 1
        ];
    }
}
