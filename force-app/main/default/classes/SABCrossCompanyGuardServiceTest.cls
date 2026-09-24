@IsTest
private class SABCrossCompanyGuardServiceTest {

    private class Fixture {
        Accounting_Company__c companyA;
        Accounting_Company__c companyB;
        Accounting_Period__c periodA;
        Accounting_Period__c periodB;
        GL_Account__c assetA;
        GL_Account__c assetB;
        GL_Account__c arA;
        GL_Account__c arB;
        GL_Account__c apA;
        GL_Account__c apB;
        Party_Accounting_Profile__c customerA;
        Party_Accounting_Profile__c customerB;
        Party_Accounting_Profile__c supplierA;
        Party_Accounting_Profile__c supplierB;
        Bank_Account__c bankA;
        Bank_Account__c bankB;
    }

    @IsTest
    static void validSameCompanyJournalAndLinePass() {
        Fixture f = makeFixture();

        Journal_Entry__c journal =
            makeJournal(
                f.companyA.Id,
                f.periodA.Id
            );

        insert journal;

        insert new Journal_Entry_Line__c(
            Journal_Entry__c = journal.Id,
            GL_Account__c = f.assetA.Id,
            Line_Number__c = 1,
            Debit_Base__c = 100,
            Credit_Base__c = 0,
            Functional_Currency__c = 'BDT'
        );

        System.assertNotEquals(null, journal.Id);
    }

    @IsTest
    static void journalCannotUseOtherCompanyPeriod() {
        Fixture f = makeFixture();

        Journal_Entry__c journal =
            makeJournal(
                f.companyA.Id,
                f.periodB.Id
            );

        Database.SaveResult result =
            Database.insert(
                journal,
                false
            );

        assertCrossCompanyFailure(result);
    }

    @IsTest
    static void journalCannotUseOtherCompanyEvent() {
        Fixture f = makeFixture();

        Accounting_Event__c eventB =
            makeEvent(
                f.companyB.Id,
                'EVENT-B'
            );
        insert eventB;

        Journal_Entry__c journal =
            makeJournal(
                f.companyA.Id,
                f.periodA.Id
            );
        journal.Accounting_Event__c =
            eventB.Id;

        Database.SaveResult result =
            Database.insert(
                journal,
                false
            );

        assertCrossCompanyFailure(result);
    }

    @IsTest
    static void journalLineCannotUseOtherCompanyAccount() {
        Fixture f = makeFixture();

        Journal_Entry__c journal =
            makeJournal(
                f.companyA.Id,
                f.periodA.Id
            );
        insert journal;

        Journal_Entry_Line__c line =
            new Journal_Entry_Line__c(
                Journal_Entry__c = journal.Id,
                GL_Account__c = f.assetB.Id,
                Line_Number__c = 1,
                Debit_Base__c = 100,
                Credit_Base__c = 0,
                Functional_Currency__c = 'BDT'
            );

        Database.SaveResult result =
            Database.insert(
                line,
                false
            );

        assertCrossCompanyFailure(result);
    }

    @IsTest
    static void journalLineCannotUseOtherCompanyDimension() {
        Fixture f = makeFixture();

        Department__c departmentB =
            new Department__c(
                Company__c = f.companyB.Id,
                Company_Department_Key__c = 'B1-DEPT',
                Code__c = 'D01',
                Is_Active__c = true
            );
        insert departmentB;

        Journal_Entry__c journal =
            makeJournal(
                f.companyA.Id,
                f.periodA.Id
            );
        insert journal;

        Journal_Entry_Line__c line =
            new Journal_Entry_Line__c(
                Journal_Entry__c = journal.Id,
                GL_Account__c = f.assetA.Id,
                Department__c = departmentB.Id,
                Line_Number__c = 1,
                Debit_Base__c = 100,
                Credit_Base__c = 0,
                Functional_Currency__c = 'BDT'
            );

        Database.SaveResult result =
            Database.insert(
                line,
                false
            );

        assertCrossCompanyFailure(result);
    }

    @IsTest
    static void bankAccountCannotUseOtherCompanyGL() {
        Fixture f = makeFixture();

        Bank_Account__c bank =
            new Bank_Account__c(
                Company__c = f.companyA.Id,
                GL_Account__c = f.assetB.Id,
                Currency__c = 'BDT',
                Is_Active__c = true
            );

        Database.SaveResult result =
            Database.insert(
                bank,
                false
            );

        assertCrossCompanyFailure(result);
    }

    @IsTest
    static void invoiceCannotUseOtherCompanyPartyProfile() {
        Fixture f = makeFixture();

        Invoice__c invoice =
            new Invoice__c(
                Company__c = f.companyA.Id,
                Party_Profile__c = f.customerB.Id,
                Document_Type__c = 'Invoice',
                Document_Date__c = Date.today(),
                Transaction_Currency__c = 'BDT',
                Status__c = 'Draft'
            );

        Database.SaveResult result =
            Database.insert(
                invoice,
                false
            );

        assertCrossCompanyFailure(result);
    }

    @IsTest
    static void supplierBillCannotUseOtherCompanyProfile() {
        Fixture f = makeFixture();

        Supplier_Bill__c bill =
            new Supplier_Bill__c(
                Company__c = f.companyA.Id,
                Supplier_Profile__c = f.supplierB.Id,
                Document_Type__c = 'Bill',
                Document_Date__c = Date.today(),
                Transaction_Currency__c = 'BDT',
                Status__c = 'Draft'
            );

        Database.SaveResult result =
            Database.insert(
                bill,
                false
            );

        assertCrossCompanyFailure(result);
    }

    @IsTest
    static void paymentCannotUseOtherCompanyBank() {
        Fixture f = makeFixture();

        Accounting_Payment__c payment =
            new Accounting_Payment__c(
                Company__c = f.companyA.Id,
                Bank_Account__c = f.bankB.Id,
                Direction__c = 'Disbursement',
                Effective_Date__c = Date.today(),
                Amount__c = 100,
                Transaction_Currency__c = 'BDT',
                Processing_State__c = 'Draft'
            );

        Database.SaveResult result =
            Database.insert(
                payment,
                false
            );

        assertCrossCompanyFailure(result);
    }

    @IsTest
    static void eventCannotLinkOtherCompanyJournal() {
        Fixture f = makeFixture();

        Journal_Entry__c journalA =
            makeJournal(
                f.companyA.Id,
                f.periodA.Id
            );
        insert journalA;

        Accounting_Event__c eventB =
            makeEvent(
                f.companyB.Id,
                'EVENT-CROSS'
            );
        eventB.Journal_Entry__c =
            journalA.Id;

        Database.SaveResult result =
            Database.insert(
                eventB,
                false
            );

        assertCrossCompanyFailure(result);
    }

    private static void assertCrossCompanyFailure(
        Database.SaveResult result
    ) {
        System.assertEquals(
            false,
            result.isSuccess()
        );

        String message =
            result.getErrors()[0].getMessage();

        System.assert(
            message.contains(
                'Cross-company relationship is not allowed'
            ),
            message
        );
    }

    private static Fixture makeFixture() {
        Fixture f = new Fixture();

        f.companyA = makeCompany('A1');
        f.companyB = makeCompany('B1');

        f.periodA =
            makePeriod(f.companyA.Id, 'A1');
        f.periodB =
            makePeriod(f.companyB.Id, 'B1');

        f.assetA =
            makeAccount(
                f.companyA.Id,
                '1001',
                'Asset',
                'Debit',
                false,
                'None'
            );
        f.assetB =
            makeAccount(
                f.companyB.Id,
                '1001',
                'Asset',
                'Debit',
                false,
                'None'
            );

        f.arA =
            makeAccount(
                f.companyA.Id,
                '1100',
                'Asset',
                'Debit',
                true,
                'AR'
            );
        f.arB =
            makeAccount(
                f.companyB.Id,
                '1100',
                'Asset',
                'Debit',
                true,
                'AR'
            );

        f.apA =
            makeAccount(
                f.companyA.Id,
                '2100',
                'Liability',
                'Credit',
                true,
                'AP'
            );
        f.apB =
            makeAccount(
                f.companyB.Id,
                '2100',
                'Liability',
                'Credit',
                true,
                'AP'
            );

        Account accountA =
            new Account(Name = 'Party A');
        Account accountB =
            new Account(Name = 'Party B');
        insert new List<Account>{
            accountA,
            accountB
        };

        f.customerA =
            makeCustomerProfile(
                f.companyA.Id,
                accountA.Id,
                f.arA.Id,
                'PA-C'
            );
        f.customerB =
            makeCustomerProfile(
                f.companyB.Id,
                accountB.Id,
                f.arB.Id,
                'PB-C'
            );

        f.supplierA =
            makeSupplierProfile(
                f.companyA.Id,
                accountA.Id,
                f.apA.Id,
                'PA-S'
            );
        f.supplierB =
            makeSupplierProfile(
                f.companyB.Id,
                accountB.Id,
                f.apB.Id,
                'PB-S'
            );

        f.bankA =
            makeBank(
                f.companyA.Id,
                f.assetA.Id
            );
        f.bankB =
            makeBank(
                f.companyB.Id,
                f.assetB.Id
            );

        return f;
    }

    private static Accounting_Company__c makeCompany(
        String keyValue
    ) {
        Accounting_Company__c company =
            new Accounting_Company__c(
                Name__c = 'Company ' + keyValue,
                Company_Key__c = keyValue,
                Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT',
                Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active',
                Is_Active__c = true
            );
        insert company;
        return company;
    }

    private static Accounting_Period__c makePeriod(
        Id companyId,
        String suffixValue
    ) {
        Accounting_Period__c period =
            new Accounting_Period__c(
                Name = 'Period ' + suffixValue,
                Company__c = companyId,
                Company_Period_Key__c =
                    'CP-' + suffixValue,
                Period_Key__c =
                    'P-' + suffixValue,
                Start_Date__c =
                    Date.newInstance(2026, 9, 1),
                End_Date__c =
                    Date.newInstance(2026, 9, 30),
                Fiscal_Year__c = 2026,
                Fiscal_Quarter__c = 3,
                Period_Number__c = 9,
                Status__c = 'Open'
            );
        insert period;
        return period;
    }

    private static GL_Account__c makeAccount(
        Id companyId,
        String code,
        String accountType,
        String normalBalance,
        Boolean isControl,
        String controlType
    ) {
        GL_Account__c account =
            new GL_Account__c(
                Name = 'Account ' + code,
                Company__c = companyId,
                Company_Account_Key__c =
                    String.valueOf(companyId)
                    + '-'
                    + code,
                Account_Code__c = code,
                Account_Type__c = accountType,
                Normal_Balance__c = normalBalance,
                Is_Active__c = true,
                Is_Control_Account__c = isControl,
                Control_Type__c = controlType,
                Manual_Posting_Allowed__c =
                    !isControl
            );
        insert account;
        return account;
    }

    private static Party_Accounting_Profile__c
        makeCustomerProfile(
            Id companyId,
            Id accountId,
            Id arAccountId,
            String keyValue
        ) {
        Party_Accounting_Profile__c profile =
            new Party_Accounting_Profile__c(
                Company__c = companyId,
                Account__c = accountId,
                Profile_Key__c = keyValue,
                Is_Customer__c = true,
                Is_Supplier__c = false,
                AR_Control_Account__c =
                    arAccountId,
                Is_Active__c = true
            );
        insert profile;
        return profile;
    }

    private static Party_Accounting_Profile__c
        makeSupplierProfile(
            Id companyId,
            Id accountId,
            Id apAccountId,
            String keyValue
        ) {
        Party_Accounting_Profile__c profile =
            new Party_Accounting_Profile__c(
                Company__c = companyId,
                Account__c = accountId,
                Profile_Key__c = keyValue,
                Is_Customer__c = false,
                Is_Supplier__c = true,
                AP_Control_Account__c =
                    apAccountId,
                Is_Active__c = true
            );
        insert profile;
        return profile;
    }

    private static Bank_Account__c makeBank(
        Id companyId,
        Id glAccountId
    ) {
        Bank_Account__c bank =
            new Bank_Account__c(
                Company__c = companyId,
                GL_Account__c = glAccountId,
                Currency__c = 'BDT',
                Is_Active__c = true
            );
        insert bank;
        return bank;
    }

    private static Journal_Entry__c makeJournal(
        Id companyId,
        Id periodId
    ) {
        return new Journal_Entry__c(
            Company__c = companyId,
            Accounting_Period__c = periodId,
            Accounting_Date__c =
                Date.newInstance(2026, 9, 24),
            Entry_Type__c = 'Manual',
            Status__c = 'Draft',
            Description__c =
                'Step 7B relationship test',
            Version__c = 1
        );
    }

    private static Accounting_Event__c makeEvent(
        Id companyId,
        String eventKey
    ) {
        return new Accounting_Event__c(
            Company__c = companyId,
            Event_Key__c = eventKey,
            Adapter_Key__c = 'MANUAL_JOURNAL',
            Event_Type__c = 'Manual Journal',
            Source_Type__c = 'Journal_Entry__c',
            Source_Version__c = 1,
            State__c = 'Reserved'
        );
    }
}
