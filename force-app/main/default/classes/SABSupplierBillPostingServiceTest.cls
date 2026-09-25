@IsTest
private class SABSupplierBillPostingServiceTest {

    private static final String ADMIN_PERMISSION_SET =
        'SAB_Remaining_Fields_Admin';

    private static final String APPROVE_PERMISSION_SET =
        'SAB_Approve_Financial_Document_Action';

    private static final String POST_PERMISSION_SET =
        'SAB_Post_Journal_Action';

    private static final Decimal ZERO = Decimal.valueOf('0');

    @TestSetup
    static void setupFixture() {
        Profile profileRecord = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        String seed = String.valueOf(DateTime.now().getTime());

        User testUser = new User(
            Alias = 'sabg3b',
            Email = 'sabg3b.' + seed + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = 'SAB G3B User',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profileRecord.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = 'sabg3b.' + seed + '@example.test'
        );

        insert testUser;

        Map<String, Id> permissionSetIds = new Map<String, Id>();

        for (PermissionSet permissionSetRecord : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN (
                :ADMIN_PERMISSION_SET,
                :APPROVE_PERMISSION_SET,
                :POST_PERMISSION_SET
            )
        ]) {
            permissionSetIds.put(
                permissionSetRecord.Name,
                permissionSetRecord.Id
            );
        }

        System.assertEquals(
            3,
            permissionSetIds.size(),
            'G3B tests require the existing SAB admin, approval and post-action permission sets.'
        );

        insert new List<PermissionSetAssignment>{
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId = permissionSetIds.get(
                    ADMIN_PERMISSION_SET
                )
            ),
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId = permissionSetIds.get(
                    APPROVE_PERMISSION_SET
                )
            ),
            new PermissionSetAssignment(
                AssigneeId = testUser.Id,
                PermissionSetId = permissionSetIds.get(
                    POST_PERMISSION_SET
                )
            )
        };

        System.runAs(testUser) {
            Accounting_Company__c company = new Accounting_Company__c(
                Name__c = 'G3B Company',
                Company_Key__c = 'G3B',
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
                Grant_Key__c = 'G3B-ACCESS',
                Role__c = 'Finance Manager'
            );

            insert new Accounting_Period__c(
                Name = 'September 2026',
                Company__c = company.Id,
                Company_Period_Key__c = 'G3B-2026-09',
                Period_Key__c = '2026-09',
                Start_Date__c = Date.newInstance(2026, 9, 1),
                End_Date__c = Date.newInstance(2026, 9, 30),
                Fiscal_Year__c = 2026,
                Fiscal_Quarter__c = 3,
                Period_Number__c = 9,
                Status__c = 'Open'
            );

            GL_Account__c apControl = makeAccount(
                company.Id,
                '2000',
                'Accounts Payable',
                'Liability',
                'Credit',
                true,
                'AP',
                false
            );

            GL_Account__c expense = makeAccount(
                company.Id,
                '6000',
                'Office Expense',
                'Expense',
                'Debit',
                false,
                'None',
                true
            );

            GL_Account__c cash = makeAccount(
                company.Id,
                '1000',
                'Cash',
                'Asset',
                'Debit',
                false,
                'None',
                true
            );

            Account supplierAccount = new Account(
                Name = 'G3B Supplier'
            );

            insert supplierAccount;

            insert new Party_Accounting_Profile__c(
                Company__c = company.Id,
                Account__c = supplierAccount.Id,
                Profile_Key__c = 'G3B-SUPPLIER',
                Is_Supplier__c = true,
                Is_Customer__c = false,
                Is_Active__c = true,
                AP_Control_Account__c = apControl.Id
            );
        }
    }

    @IsTest
    static void approvedBillPostsOnceAndReplayReturnsOriginal() {
        User testUser = getUser();

        System.runAs(testUser) {
            Supplier_Bill__c bill = createApprovedBill(
                'Bill',
                'G3B-BILL-001',
                'BDT',
                Decimal.valueOf('1'),
                Decimal.valueOf('250'),
                Decimal.valueOf('0'),
                Decimal.valueOf('5')
            );

            SABSupplierBillPostingService.PostingRequest request =
                postingRequest(
                    bill.Id,
                    'REQ-G3B-BILL-001'
                );

            Test.startTest();

            SABSupplierBillPostingService.PostingResult first =
                SABSupplierBillPostingService.postApprovedBill(
                    request
                );

            SABSupplierBillPostingService.PostingResult replay =
                SABSupplierBillPostingService.postApprovedBill(
                    postingRequest(
                        bill.Id,
                        'REQ-G3B-BILL-REPLAY'
                    )
                );

            Test.stopTest();

            System.assertEquals(false, first.replay);
            System.assertEquals(true, replay.replay);
            System.assertEquals(
                first.journalEntryId,
                replay.journalEntryId
            );
            System.assertEquals(
                first.accountingEventId,
                replay.accountingEventId
            );

            Supplier_Bill__c postedBill = [
                SELECT Status__c, Accounting_Event__c
                FROM Supplier_Bill__c
                WHERE Id = :bill.Id
            ];

            System.assertEquals('Posted', postedBill.Status__c);
            System.assertEquals(
                first.accountingEventId,
                postedBill.Accounting_Event__c
            );

            Accounting_Event__c eventRecord = [
                SELECT Event_Type__c, Source_Type__c,
                       Source_Record_Id__c, State__c,
                       Journal_Entry__c
                FROM Accounting_Event__c
                WHERE Id = :first.accountingEventId
            ];

            System.assertEquals(
                'Supplier Bill',
                eventRecord.Event_Type__c
            );
            System.assertEquals(
                'Supplier_Bill__c',
                eventRecord.Source_Type__c
            );
            System.assertEquals(
                String.valueOf(bill.Id),
                eventRecord.Source_Record_Id__c
            );
            System.assertEquals('Posted', eventRecord.State__c);
            System.assertEquals(
                first.journalEntryId,
                eventRecord.Journal_Entry__c
            );

            Journal_Entry__c journal = [
                SELECT Status__c, Entry_Type__c,
                       Posting_Key__c, Accounting_Event__c
                FROM Journal_Entry__c
                WHERE Id = :first.journalEntryId
            ];

            System.assertEquals('Posted', journal.Status__c);
            System.assertEquals('Subledger', journal.Entry_Type__c);
            System.assertEquals(
                'SB|' + String.valueOf(bill.Id) + '|V1',
                journal.Posting_Key__c
            );

            List<Journal_Entry_Line__c> lines = [
                SELECT GL_Account__r.Account_Code__c,
                       Debit_Base__c, Credit_Base__c,
                       Transaction_Amount__c,
                       Transaction_Currency__c,
                       Functional_Currency__c,
                       Source_Line_Key__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c = :journal.Id
                ORDER BY Line_Number__c
            ];

            System.assertEquals(2, lines.size());

            System.assertEquals('6000', lines[0].GL_Account__r.Account_Code__c);
            System.assertEquals(Decimal.valueOf('255'), lines[0].Debit_Base__c);
            System.assertEquals(Decimal.valueOf('0'), lines[0].Credit_Base__c);

            System.assertEquals('2000', lines[1].GL_Account__r.Account_Code__c);
            System.assertEquals(Decimal.valueOf('0'), lines[1].Debit_Base__c);
            System.assertEquals(Decimal.valueOf('255'), lines[1].Credit_Base__c);

            String billIdText = String.valueOf(bill.Id);

            System.assertEquals(
                1,
                [
                    SELECT COUNT()
                    FROM Accounting_Event__c
                    WHERE Source_Type__c = 'Supplier_Bill__c'
                      AND Source_Record_Id__c = :billIdText
                ]
            );
        }
    }

    @IsTest
    static void supplierCreditReversesAPDirection() {
        User testUser = getUser();

        System.runAs(testUser) {
            Supplier_Bill__c credit = createApprovedBill(
                'Supplier Credit',
                'G3B-CREDIT-001',
                'BDT',
                Decimal.valueOf('1'),
                Decimal.valueOf('100'),
                ZERO,
                ZERO
            );

            Test.startTest();

            SABSupplierBillPostingService.PostingResult result =
                SABSupplierBillPostingService.postApprovedBill(
                    postingRequest(
                        credit.Id,
                        'REQ-G3B-CREDIT-001'
                    )
                );

            Test.stopTest();

            List<Journal_Entry_Line__c> lines = [
                SELECT GL_Account__r.Account_Code__c,
                       Debit_Base__c, Credit_Base__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c = :result.journalEntryId
                ORDER BY Line_Number__c
            ];

            System.assertEquals(2, lines.size());
            System.assertEquals('6000', lines[0].GL_Account__r.Account_Code__c);
            System.assertEquals(ZERO, lines[0].Debit_Base__c);
            System.assertEquals(Decimal.valueOf('100'), lines[0].Credit_Base__c);
            System.assertEquals('2000', lines[1].GL_Account__r.Account_Code__c);
            System.assertEquals(Decimal.valueOf('100'), lines[1].Debit_Base__c);
            System.assertEquals(ZERO, lines[1].Credit_Base__c);
        }
    }

    @IsTest
    static void foreignCurrencyUsesStoredBillRate() {
        User testUser = getUser();

        System.runAs(testUser) {
            Supplier_Bill__c bill = createApprovedBill(
                'Bill',
                'G3B-FX-001',
                'USD',
                Decimal.valueOf('110'),
                Decimal.valueOf('10'),
                ZERO,
                ZERO
            );

            Test.startTest();

            SABSupplierBillPostingService.PostingResult result =
                SABSupplierBillPostingService.postApprovedBill(
                    postingRequest(
                        bill.Id,
                        'REQ-G3B-FX-001'
                    )
                );

            Test.stopTest();

            List<Journal_Entry_Line__c> lines = [
                SELECT Debit_Base__c, Credit_Base__c,
                       Transaction_Amount__c,
                       Transaction_Currency__c,
                       Functional_Currency__c,
                       Applied_Exchange_Rate__c
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c = :result.journalEntryId
                ORDER BY Line_Number__c
            ];

            System.assertEquals(2, lines.size());
            System.assertEquals(Decimal.valueOf('1100'), lines[0].Debit_Base__c);
            System.assertEquals(Decimal.valueOf('1100'), lines[1].Credit_Base__c);
            System.assertEquals(Decimal.valueOf('10'), lines[0].Transaction_Amount__c);
            System.assertEquals('USD', lines[0].Transaction_Currency__c);
            System.assertEquals('BDT', lines[0].Functional_Currency__c);
            System.assertEquals(Decimal.valueOf('110'), lines[0].Applied_Exchange_Rate__c);
        }
    }

    @IsTest
    static void recoverableTaxIsBlockedUntilG4MappingExists() {
        User testUser = getUser();

        System.runAs(testUser) {
            Supplier_Bill__c bill = createApprovedBill(
                'Bill',
                'G3B-TAX-001',
                'BDT',
                Decimal.valueOf('1'),
                Decimal.valueOf('100'),
                Decimal.valueOf('15'),
                ZERO
            );

            Boolean thrown = false;

            Test.startTest();

            try {
                SABSupplierBillPostingService.postApprovedBill(
                    postingRequest(
                        bill.Id,
                        'REQ-G3B-TAX-001'
                    )
                );
            } catch (
                SABSupplierBillPostingService.SupplierBillPostingException ex
            ) {
                thrown = ex.getMessage().contains(
                    'recoverable tax'
                );
            }

            Test.stopTest();

            System.assertEquals(true, thrown);

            Supplier_Bill__c unchanged = [
                SELECT Status__c, Accounting_Event__c
                FROM Supplier_Bill__c
                WHERE Id = :bill.Id
            ];

            System.assertEquals('Approved', unchanged.Status__c);
            System.assertEquals(null, unchanged.Accounting_Event__c);

            System.assertEquals(
                0,
                [
                    SELECT COUNT()
                    FROM Journal_Entry__c
                    WHERE Description__c LIKE 'Supplier Bill%G3B-TAX-001%'
                ]
            );
        }
    }

    @IsTest
    static void manualJournalStillCannotUseAPControlAccount() {
        User testUser = getUser();

        System.runAs(testUser) {
            Accounting_Company__c company = getCompany();
            Accounting_Period__c period = getPeriod();
            GL_Account__c expense = getAccount('6000');
            GL_Account__c apControl = getAccount('2000');

            Journal_Entry__c journal = new Journal_Entry__c(
                Company__c = company.Id,
                Accounting_Period__c = period.Id,
                Accounting_Date__c = Date.newInstance(2026, 9, 15),
                Entry_Type__c = 'Manual',
                Status__c = 'Draft',
                Description__c = 'Manual AP control attempt',
                Version__c = 1
            );

            insert journal;

            insert new List<Journal_Entry_Line__c>{
                new Journal_Entry_Line__c(
                    Journal_Entry__c = journal.Id,
                    GL_Account__c = expense.Id,
                    Line_Number__c = 1,
                    Debit_Base__c = 50,
                    Credit_Base__c = 0,
                    Functional_Currency__c = 'BDT'
                ),
                new Journal_Entry_Line__c(
                    Journal_Entry__c = journal.Id,
                    GL_Account__c = apControl.Id,
                    Line_Number__c = 2,
                    Debit_Base__c = 0,
                    Credit_Base__c = 50,
                    Functional_Currency__c = 'BDT'
                )
            };

            SABAccountingEventService.ReservationRequest eventRequest =
                new SABAccountingEventService.ReservationRequest();

            eventRequest.companyId = company.Id;
            eventRequest.adapterKey = 'MANUAL_JOURNAL';
            eventRequest.requestKey = 'REQ-G3B-MANUAL';
            eventRequest.eventKey = 'EVENT-G3B-MANUAL';
            eventRequest.eventType = 'Manual Journal';
            eventRequest.sourceBusinessKey = 'MANUAL-G3B';
            eventRequest.sourceRecordId = String.valueOf(journal.Id);
            eventRequest.sourceType = 'Journal_Entry__c';
            eventRequest.sourceVersion = 1;

            SABPostingService.PostingRequest posting =
                new SABPostingService.PostingRequest();

            posting.journalEntryId = journal.Id;
            posting.postingKey = 'POST-G3B-MANUAL';
            posting.eventRequest = eventRequest;

            Boolean thrown = false;

            Test.startTest();

            try {
                SABPostingService.postDraftJournal(posting);
            } catch (Exception ex) {
                thrown = ex.getMessage().contains(
                    'does not allow manual/opening posting'
                );
            }

            Test.stopTest();

            System.assertEquals(
                true,
                thrown,
                'G3B must not weaken the manual-journal control-account restriction.'
            );
        }
    }

    private static Supplier_Bill__c createApprovedBill(
        String documentType,
        String vendorReference,
        String transactionCurrency,
        Decimal exchangeRate,
        Decimal netAmount,
        Decimal recoverableTax,
        Decimal nonrecoverableTax
    ) {
        Accounting_Company__c company = getCompany();
        Party_Accounting_Profile__c supplier = getSupplierProfile();
        GL_Account__c expense = getAccount('6000');

        Supplier_Bill__c bill = new Supplier_Bill__c(
            Company__c = company.Id,
            Supplier_Profile__c = supplier.Id,
            Document_Type__c = documentType,
            Document_Date__c = Date.newInstance(2026, 9, 10),
            Accounting_Date__c = Date.newInstance(2026, 9, 10),
            Due_Date__c = Date.newInstance(2026, 10, 10),
            Transaction_Currency__c = transactionCurrency,
            Exchange_Rate__c = exchangeRate,
            Vendor_Reference__c = vendorReference,
            Status__c = 'Draft'
        );

        insert bill;

        insert new Bill_Line__c(
            Supplier_Bill__c = bill.Id,
            Line_Number__c = 1,
            Description__c = vendorReference,
            Quantity__c = 1,
            Unit_Price__c = netAmount,
            Net_Amount__c = netAmount,
            Recoverable_Tax_Amount__c = recoverableTax,
            Nonrecoverable_Tax_Amount__c = nonrecoverableTax,
            Expense_or_Asset_Account__c = expense.Id
        );

        SABSupplierBillService.submit(
            bill.Id,
            'SUBMIT|' + vendorReference
        );

        SABSupplierBillService.approve(
            bill.Id,
            'APPROVE|' + vendorReference,
            'Approved for G3B posting test.'
        );

        return [
            SELECT Id, Status__c
            FROM Supplier_Bill__c
            WHERE Id = :bill.Id
        ];
    }

    private static SABSupplierBillPostingService.PostingRequest
        postingRequest(
            Id billId,
            String requestKey
        ) {
        SABSupplierBillPostingService.PostingRequest request =
            new SABSupplierBillPostingService.PostingRequest();

        request.supplierBillId = billId;
        request.requestKey = requestKey;

        return request;
    }

    private static User getUser() {
        return [
            SELECT Id
            FROM User
            WHERE LastName = 'SAB G3B User'
            LIMIT 1
        ];
    }

    private static Accounting_Company__c getCompany() {
        return [
            SELECT Id
            FROM Accounting_Company__c
            WHERE Company_Key__c = 'G3B'
            LIMIT 1
        ];
    }

    private static Accounting_Period__c getPeriod() {
        Id companyId = getCompany().Id;

        return [
            SELECT Id
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
              AND Period_Key__c = '2026-09'
            LIMIT 1
        ];
    }

    private static Party_Accounting_Profile__c getSupplierProfile() {
        return [
            SELECT Id
            FROM Party_Accounting_Profile__c
            WHERE Profile_Key__c = 'G3B-SUPPLIER'
            LIMIT 1
        ];
    }

    private static GL_Account__c getAccount(String code) {
        Id companyId = getCompany().Id;

        return [
            SELECT Id
            FROM GL_Account__c
            WHERE Company__c = :companyId
              AND Account_Code__c = :code
            LIMIT 1
        ];
    }

    private static GL_Account__c makeAccount(
        Id companyId,
        String code,
        String displayName,
        String accountType,
        String normalBalance,
        Boolean isControl,
        String controlType,
        Boolean manualPostingAllowed
    ) {
        GL_Account__c accountRecord = new GL_Account__c(
            Name = displayName,
            Company__c = companyId,
            Company_Account_Key__c = 'G3B-' + code,
            Account_Code__c = code,
            Account_Type__c = accountType,
            Normal_Balance__c = normalBalance,
            Is_Active__c = true,
            Is_Control_Account__c = isControl,
            Control_Type__c = controlType,
            Manual_Posting_Allowed__c = manualPostingAllowed
        );

        insert accountRecord;
        return accountRecord;
    }
}
