@IsTest
private class SABTaxPostingIntegrationTest {

    @IsTest
    static void invoiceAndSupplierInstructionsUseSnapshots() {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c = 'G6B Posting Co',
                Company_Key__c = 'GTP',
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
            User__c = UserInfo.getUserId(),
            Is_Active__c = true,
            Effective_From__c = Date.today(),
            Grant_Key__c = 'G6B-POST-GRANT',
            Role__c = 'Finance Manager'
        );

        GL_Account__c taxAccount =
            new GL_Account__c(
                Name = 'Tax Control',
                Company__c = company.Id,
                Company_Account_Key__c = 'GTP-TAX',
                Account_Code__c = '2200',
                Account_Type__c = 'Liability',
                Normal_Balance__c = 'Credit',
                Is_Active__c = true,
                Is_Control_Account__c = true,
                Control_Type__c = 'Tax',
                Manual_Posting_Allowed__c = false
            );
        insert taxAccount;

        GL_Account__c arControl =
            new GL_Account__c(
                Name = 'Accounts Receivable',
                Company__c = company.Id,
                Company_Account_Key__c = 'GTP-AR',
                Account_Code__c = '1200',
                Account_Type__c = 'Asset',
                Normal_Balance__c = 'Debit',
                Is_Active__c = true,
                Is_Control_Account__c = true,
                Control_Type__c = 'AR',
                Manual_Posting_Allowed__c = false
            );
        insert arControl;

        Account customerAccount =
            new Account(
                Name = 'G6B Posting Customer'
            );
        insert customerAccount;

        Party_Accounting_Profile__c customer =
            new Party_Accounting_Profile__c(
                Account__c = customerAccount.Id,
                Company__c = company.Id,
                Profile_Key__c = 'GTP-C',
                Is_Active__c = true,
                Is_Customer__c = true,
                AR_Control_Account__c = arControl.Id
            );
        insert customer;

        Invoice__c invoice =
            new Invoice__c(
                Company__c = company.Id,
                Party_Profile__c = customer.Id,
                Document_Date__c = Date.today(),
                Accounting_Date__c = Date.today(),
                Due_Date__c = Date.today(),
                Document_Type__c = 'Invoice',
                Status__c = 'Draft',
                Transaction_Currency__c = 'BDT',
                Functional_Currency__c = 'BDT',
                Subtotal__c = 100,
                Tax_Total__c = 15,
                Total__c = 115
            );
        insert invoice;

        GL_Account__c revenue =
            new GL_Account__c(
                Name = 'Revenue',
                Company__c = company.Id,
                Company_Account_Key__c = 'GTP-REV',
                Account_Code__c = '4100',
                Account_Type__c = 'Revenue',
                Normal_Balance__c = 'Credit',
                Is_Active__c = true,
                Is_Control_Account__c = false,
                Control_Type__c = 'None',
                Manual_Posting_Allowed__c = true
            );
        insert revenue;

        Invoice_Line__c invoiceLine =
            new Invoice_Line__c(
                Invoice__c = invoice.Id,
                Line_Number__c = 1,
                Description__c = 'Posting tax test',
                Quantity__c = 1,
                Unit_Price__c = 100,
                Discount_Amount__c = 0,
                Net_Amount__c = 100,
                Revenue_Account__c = revenue.Id
            );
        insert invoiceLine;

        Document_Tax_Line__c taxLine =
            new Document_Tax_Line__c(
                Invoice_Line__c = invoiceLine.Id,
                Company__c = company.Id,
                Taxable_Base__c = 100,
                Tax_Amount__c = 15,
                Recoverable_Amount__c = 0,
                Tax_Account__c = taxAccount.Id,
                Tax_Rate__c = 15,
                Tax_Code_Key__c = 'POST15',
                Jurisdiction__c = 'BD',
                Calculation_Version__c = 'G6B-DOC-TAX-1'
            );
        insert taxLine;

        Test.startTest();

        List<SABTaxPostingIntegrationService.PostingInstruction> instructions =
            SABTaxPostingIntegrationService.getInvoiceInstructions(
                invoice.Id
            );

        Test.stopTest();

        System.assertEquals(
            1,
            instructions.size()
        );
        System.assertEquals(
            false,
            instructions[0].debit
        );
        System.assertEquals(
            Decimal.valueOf('15.0000'),
            instructions[0].transactionAmount
        );
        System.assertEquals(
            taxAccount.Id,
            instructions[0].taxAccountId
        );
    }
}
