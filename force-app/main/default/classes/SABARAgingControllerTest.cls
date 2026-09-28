@IsTest
private class SABARAgingControllerTest {

    @IsTest
    static void customerFiltersAndReportAreAvailable() {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    'G4D Controller Company',
                Company_Key__c =
                    'D4C',
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
                UserInfo.getUserId(),
            Effective_From__c =
                Date.today(),
            Grant_Key__c =
                'G4D-CONTROLLER',
            Is_Active__c =
                true,
            Role__c =
                'Finance Manager'
        );

        GL_Account__c arControl =
            new GL_Account__c(
                Name =
                    'Controller AR',
                Company__c =
                    company.Id,
                Company_Account_Key__c =
                    'D4C-AR',
                Account_Code__c =
                    '1200',
                Account_Type__c =
                    'Asset',
                Normal_Balance__c =
                    'Debit',
                Is_Active__c =
                    true,
                Is_Control_Account__c =
                    true,
                Control_Type__c =
                    'AR',
                Manual_Posting_Allowed__c =
                    false
            );
        insert arControl;

        Account customer =
            new Account(
                Name = 'Controller Customer'
            );
        insert customer;

        Party_Accounting_Profile__c profile =
            new Party_Accounting_Profile__c(
                Company__c =
                    company.Id,
                Account__c =
                    customer.Id,
                Profile_Key__c =
                    'D4C-CUSTOMER',
                Is_Customer__c =
                    true,
                Is_Supplier__c =
                    false,
                Is_Active__c =
                    true,
                AR_Control_Account__c =
                    arControl.Id
            );
        insert profile;

        insert new Invoice__c(
            Company__c =
                company.Id,
            Party_Profile__c =
                profile.Id,
            Document_Type__c =
                'Invoice',
            Document_Date__c =
                Date.newInstance(2026, 9, 1),
            Accounting_Date__c =
                Date.newInstance(2026, 9, 1),
            Due_Date__c =
                Date.newInstance(2026, 9, 30),
            Status__c =
                'Posted',
            Transaction_Currency__c =
                'BDT',
            Functional_Currency__c =
                'BDT',
            Exchange_Rate__c =
                1,
            Subtotal__c =
                250,
            Tax_Total__c =
                0,
            Total__c =
                250,
            Legal_Number__c =
                'G4D-CTRL-001'
        );

        Test.startTest();

        List<SABARAgingController.CustomerOptionDTO> customers =
            SABARAgingController.getCustomers(
                company.Id
            );

        SABARAgingController.AgingDTO report =
            SABARAgingController.runAging(
                company.Id,
                Date.newInstance(
                    2026,
                    10,
                    31
                ),
                profile.Id,
                false
            );

        Test.stopTest();

        System.assertEquals(
            1,
            customers.size()
        );

        System.assertEquals(
            profile.Id,
            customers[0].value
        );

        System.assertEquals(
            1,
            report.openInvoiceCount
        );

        System.assertEquals(
            Decimal.valueOf('250'),
            report.totalOutstanding
        );

        System.assertEquals(
            1,
            report.rows.size()
        );

        System.assertEquals(
            '31-60',
            report.rows[0].agingBucket
        );
    }
}
