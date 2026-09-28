@IsTest
private class SABARAgingServiceTest {

    @TestSetup
    static void setupFixture() {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c =
                    'G4D Company',
                Company_Key__c =
                    'A4D',
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
                'G4D-ACCESS',
            Is_Active__c =
                true,
            Role__c =
                'Finance Manager'
        );

        Account customer =
            new Account(
                Name = 'G4D Customer'
            );
        insert customer;

        Party_Accounting_Profile__c profile =
            new Party_Accounting_Profile__c(
                Company__c =
                    company.Id,
                Account__c =
                    customer.Id,
                Profile_Key__c =
                    'G4D-CUSTOMER',
                Is_Customer__c =
                    true,
                Is_Supplier__c =
                    false,
                Is_Active__c =
                    true
            );

        // Customer validation requires an AR control account.
        GL_Account__c arControl =
            new GL_Account__c(
                Name =
                    'G4D Accounts Receivable',
                Company__c =
                    company.Id,
                Company_Account_Key__c =
                    'G4D-AR',
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

        profile.AR_Control_Account__c =
            arControl.Id;
        insert profile;

        List<Invoice__c> invoices =
            new List<Invoice__c>{
                invoice(
                    company.Id,
                    profile.Id,
                    'G4D-CURRENT',
                    Date.newInstance(2026, 11, 15),
                    100
                ),
                invoice(
                    company.Id,
                    profile.Id,
                    'G4D-1-30',
                    Date.newInstance(2026, 10, 15),
                    100
                ),
                invoice(
                    company.Id,
                    profile.Id,
                    'G4D-31-60',
                    Date.newInstance(2026, 9, 15),
                    100
                ),
                invoice(
                    company.Id,
                    profile.Id,
                    'G4D-61-90',
                    Date.newInstance(2026, 8, 15),
                    100
                ),
                invoice(
                    company.Id,
                    profile.Id,
                    'G4D-91PLUS',
                    Date.newInstance(2026, 7, 15),
                    100
                )
            };

        insert invoices;

        Map<String, Invoice__c> byNumber =
            new Map<String, Invoice__c>();

        for (Invoice__c row : [
            SELECT Id,
                   Legal_Number__c
            FROM Invoice__c
            WHERE Company__c = :company.Id
        ]) {
            byNumber.put(
                row.Legal_Number__c,
                row
            );
        }

        // 1-30 invoice: 40 paid before the report date.
        insert allocation(
            company.Id,
            byNumber.get('G4D-1-30').Id,
            40,
            40,
            Date.newInstance(2026, 10, 20),
            'Allocated',
            null
        );

        // 31-60 invoice: 20 was applied, then reversed later.
        Payment_Allocation__c original =
            allocation(
                company.Id,
                byNumber.get('G4D-31-60').Id,
                20,
                20,
                Date.newInstance(2026, 9, 1),
                'Reversed',
                null
            );
        insert original;

        insert allocation(
            company.Id,
            byNumber.get('G4D-31-60').Id,
            -20,
            -20,
            Date.newInstance(2026, 9, 20),
            'Reversed',
            original.Id
        );

        // 61-90 invoice: posted credit note of 25 effective 10 Oct.
        insert new Invoice__c(
            Company__c =
                company.Id,
            Party_Profile__c =
                profile.Id,
            Document_Type__c =
                'Credit Note',
            Original_Invoice__c =
                byNumber.get('G4D-61-90').Id,
            Document_Date__c =
                Date.newInstance(2026, 10, 10),
            Accounting_Date__c =
                Date.newInstance(2026, 10, 10),
            Due_Date__c =
                Date.newInstance(2026, 10, 10),
            Status__c =
                'Posted',
            Transaction_Currency__c =
                'BDT',
            Functional_Currency__c =
                'BDT',
            Exchange_Rate__c =
                1,
            Subtotal__c =
                25,
            Tax_Total__c =
                0,
            Total__c =
                25,
            Legal_Number__c =
                'G4D-CN-001'
        );
    }

    @IsTest
    static void agingBucketsUseDatedAllocationsAndCredits() {
        Accounting_Company__c company =
            getCompany();

        SABARAgingService.ARAgingRequest request =
            new SABARAgingService.ARAgingRequest();

        request.companyId =
            company.Id;
        request.asOfDate =
            Date.newInstance(
                2026,
                10,
                31
            );
        request.includeSettled =
            false;

        Test.startTest();

        SABARAgingService.ARAgingResult result =
            SABARAgingService.getAging(
                request
            );

        Test.stopTest();

        System.assertEquals(
            5,
            result.openInvoiceCount
        );

        System.assertEquals(
            Decimal.valueOf('100'),
            result.currentAmount
        );

        System.assertEquals(
            Decimal.valueOf('60'),
            result.days1To30Amount
        );

        System.assertEquals(
            Decimal.valueOf('100'),
            result.days31To60Amount
        );

        System.assertEquals(
            Decimal.valueOf('75'),
            result.days61To90Amount
        );

        System.assertEquals(
            Decimal.valueOf('100'),
            result.days91PlusAmount
        );

        System.assertEquals(
            Decimal.valueOf('435'),
            result.totalOutstanding
        );

        Map<String, SABARAgingService.ARAgingRow> rows =
            rowsByLegalNumber(
                result.rows
            );

        System.assertEquals(
            Decimal.valueOf('40'),
            rows.get('G4D-1-30')
                .allocatedDocumentAmount
        );

        System.assertEquals(
            Decimal.valueOf('60'),
            rows.get('G4D-1-30')
                .outstandingDocumentAmount
        );

        System.assertEquals(
            Decimal.valueOf('25'),
            rows.get('G4D-61-90')
                .creditedDocumentAmount
        );

        System.assertEquals(
            Decimal.valueOf('75'),
            rows.get('G4D-61-90')
                .outstandingDocumentAmount
        );

        System.assertEquals(
            '31-60',
            rows.get('G4D-31-60')
                .agingBucket
        );
    }

    @IsTest
    static void historicalAsOfUsesAllocationAndReversalEffectiveDates() {
        Accounting_Company__c company =
            getCompany();

        SABARAgingService.ARAgingRequest request =
            new SABARAgingService.ARAgingRequest();

        request.companyId =
            company.Id;
        request.asOfDate =
            Date.newInstance(
                2026,
                9,
                10
            );
        request.includeSettled =
            true;

        Test.startTest();

        SABARAgingService.ARAgingResult result =
            SABARAgingService.getAging(
                request
            );

        Test.stopTest();

        Map<String, SABARAgingService.ARAgingRow> rows =
            rowsByLegalNumber(
                result.rows
            );

        // Original +20 allocation is effective. The -20 reversal dated 20 Sep
        // is not yet effective on 10 Sep.
        System.assertEquals(
            Decimal.valueOf('20'),
            rows.get('G4D-31-60')
                .allocatedDocumentAmount
        );

        System.assertEquals(
            Decimal.valueOf('80'),
            rows.get('G4D-31-60')
                .outstandingDocumentAmount
        );

        // Credit Note is dated 10 Oct, so it does not reduce the invoice yet.
        System.assertEquals(
            Decimal.valueOf('0'),
            rows.get('G4D-61-90')
                .creditedDocumentAmount
        );

        System.assertEquals(
            Decimal.valueOf('100'),
            rows.get('G4D-61-90')
                .outstandingDocumentAmount
        );
    }

    private static Invoice__c invoice(
        Id companyId,
        Id partyProfileId,
        String legalNumber,
        Date dueDate,
        Decimal total
    ) {
        return new Invoice__c(
            Company__c =
                companyId,
            Party_Profile__c =
                partyProfileId,
            Document_Type__c =
                'Invoice',
            Document_Date__c =
                Date.newInstance(2026, 7, 1),
            Accounting_Date__c =
                Date.newInstance(2026, 7, 1),
            Due_Date__c =
                dueDate,
            Status__c =
                'Posted',
            Transaction_Currency__c =
                'BDT',
            Functional_Currency__c =
                'BDT',
            Exchange_Rate__c =
                1,
            Subtotal__c =
                total,
            Tax_Total__c =
                0,
            Total__c =
                total,
            Legal_Number__c =
                legalNumber
        );
    }

    private static Payment_Allocation__c allocation(
        Id companyId,
        Id invoiceId,
        Decimal documentAmount,
        Decimal baseAmount,
        Date effectiveDate,
        String status,
        Id reversalOfId
    ) {
        return new Payment_Allocation__c(
            Company__c =
                companyId,
            Invoice__c =
                invoiceId,
            Allocated_Amount__c =
                documentAmount,
            Payment_Amount__c =
                documentAmount,
            Document_Amount__c =
                documentAmount,
            Base_Amount__c =
                baseAmount,
            Transaction_Currency__c =
                'BDT',
            Exchange_Rate__c =
                1,
            Allocation_Date__c =
                effectiveDate,
            Effective_Date__c =
                effectiveDate,
            Status__c =
                status,
            Reversal_Of__c =
                reversalOfId
        );
    }

    private static Accounting_Company__c getCompany() {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c =
                'A4D'
            LIMIT 1
        ];
    }

    private static Map<String, SABARAgingService.ARAgingRow>
        rowsByLegalNumber(
            List<SABARAgingService.ARAgingRow> rows
        )
    {
        Map<String, SABARAgingService.ARAgingRow> result =
            new Map<String, SABARAgingService.ARAgingRow>();

        for (
            SABARAgingService.ARAgingRow row :
            rows
        ) {
            result.put(
                row.legalNumber,
                row
            );
        }

        return result;
    }
}
