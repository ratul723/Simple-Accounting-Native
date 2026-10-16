@IsTest
private class SABPaymentActionServiceTest {

    @TestSetup
    static void setupData() {
        SABAppShellTestFixture.seed();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert as system new PermissionSetAssignment(AssigneeId = SABAppShellTestFixture.fixtureUser().Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'SAB_Manage_Company_Setup_Action' WITH SYSTEM_MODE LIMIT 1].Id);
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static Id companyId() {
        return SABAppShellTestFixture.companyId(SABAppShellTestFixture.ACTIVE_KEY);
    }

    private static Id draftPayment(Id companyId, String direction, String currencyCode) {
        Accounting_Payment__c payment;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            GL_Account__c ap = new GL_Account__c(Company__c = companyId, Account_Code__c = '2000', Name = 'Payables', Account_Type__c = 'Liability',
                Normal_Balance__c = 'Credit', Control_Type__c = 'AP', Is_Control_Account__c = true, Manual_Posting_Allowed__c = false, Is_Active__c = true,
                Company_Account_Key__c = SABAppShellTestFixture.ACTIVE_KEY + '-2000');
            insert as system ap;
            Account supplier = new Account(Name = 'Fuel Co');
            insert as system supplier;
            Id arId;
            if (direction == 'Receipt') {
                GL_Account__c ar = new GL_Account__c(Company__c = companyId, Account_Code__c = '1100', Name = 'Receivables', Account_Type__c = 'Asset',
                    Normal_Balance__c = 'Debit', Control_Type__c = 'AR', Is_Control_Account__c = true, Manual_Posting_Allowed__c = false, Is_Active__c = true,
                    Company_Account_Key__c = SABAppShellTestFixture.ACTIVE_KEY + '-1100');
                insert as system ar;
                arId = ar.Id;
            }
            // A customer profile needs an AR control account; the receipt case uses a profile that is both customer and supplier.
            Party_Accounting_Profile__c profile = new Party_Accounting_Profile__c(Company__c = companyId, Account__c = supplier.Id, Profile_Key__c = 'PAS-S1',
                Is_Supplier__c = true, Is_Customer__c = direction == 'Receipt', Is_Active__c = true, AP_Control_Account__c = ap.Id, AR_Control_Account__c = arId);
            insert as system profile;
            payment = new Accounting_Payment__c(Company__c = companyId, Direction__c = direction, Party_Profile__c = profile.Id,
                Bank_Account__c = [SELECT Id FROM Bank_Account__c WHERE Company__c = :companyId WITH SYSTEM_MODE LIMIT 1].Id, Amount__c = 100,
                Effective_Date__c = Date.today(), Transaction_Currency__c = currencyCode, Functional_Currency__c = 'AUD', Exchange_Rate__c = 1,
                Processing_State__c = 'Draft');
            insert as system payment;
        }
        return payment.Id;
    }

    private static List<SABPaymentActionService.BillAllocation> oneLine() {
        SABPaymentActionService.BillAllocation line = new SABPaymentActionService.BillAllocation();
        line.supplierBillId = companyId();
        line.amount = 10;
        return new List<SABPaymentActionService.BillAllocation>{ line };
    }

    @IsTest
    static void allocationRefusesForeignReceiptsAndEmptyRequests() {
        Id foreignId = draftPayment(companyId(), 'Disbursement', 'USD');
        List<String> messages = new List<String>();
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            for (List<Object> attempt : new List<List<Object>>{ new List<Object>{ foreignId, oneLine(), 'PAS-1' },
                    new List<Object>{ null, oneLine(), 'PAS-2' }, new List<Object>{ foreignId, oneLine(), '' } }) {
                try {
                    SABPaymentActionService.allocateDisbursement((Id) attempt[0], (List<SABPaymentActionService.BillAllocation>) attempt[1], (String) attempt[2]);
                } catch (SABPaymentActionService.PaymentActionException ex) {
                    messages.add(ex.getMessage());
                }
            }
            Test.stopTest();
        }
        System.assert(messages[0].startsWith('This is a foreign-currency payment.'), messages[0]);
        System.assertEquals('Payment is required.', messages[1], 'Payment required.');
        System.assertEquals('A request key of up to 160 characters is required.', messages[2], 'Key required.');
    }

    @IsTest
    static void allocationRefusesReceiptsAndRunsTheAllocationService() {
        Id receiptId = draftPayment(companyId(), 'Receipt', 'AUD');
        Id disbursementId;
        List<String> messages = new List<String>();
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Accounting_Payment__c p = [SELECT Company__c, Party_Profile__c, Bank_Account__c FROM Accounting_Payment__c WHERE Id = :receiptId WITH SYSTEM_MODE];
            Accounting_Payment__c d = new Accounting_Payment__c(Company__c = p.Company__c, Direction__c = 'Disbursement', Party_Profile__c = p.Party_Profile__c,
                Bank_Account__c = p.Bank_Account__c, Amount__c = 50, Effective_Date__c = Date.today(), Transaction_Currency__c = 'AUD',
                Functional_Currency__c = 'AUD', Exchange_Rate__c = 1, Processing_State__c = 'Draft');
            insert as system d;
            disbursementId = d.Id;
        }
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            try {
                SABPaymentActionService.allocateDisbursement(receiptId, oneLine(), 'PAS-R');
            } catch (SABPaymentActionService.PaymentActionException ex) {
                messages.add(ex.getMessage());
            }
            try {
                SABPaymentActionService.allocateDisbursement(disbursementId, new List<SABPaymentActionService.BillAllocation>(), 'PAS-E');
            } catch (SABPaymentActionService.PaymentActionException ex) {
                messages.add(ex.getMessage());
            }
            try {
                SABPaymentActionService.allocateDisbursement(disbursementId, oneLine(), 'PAS-D');
            } catch (SABPaymentActionService.PaymentActionException ex) {
                messages.add(ex.getMessage());
            }
            Test.stopTest();
        }
        System.assert(messages[0].startsWith('Only supplier payments are allocated to bills here.'), messages[0]);
        System.assertEquals('Enter an amount for at least one bill.', messages[1], 'Lines required.');
        System.assertEquals('Only a succeeded payment can be allocated.', messages[2], 'The allocation service still applies its rules.');
    }

    @IsTest
    static void ratesAreSavedOnceAndListed() {
        Id companyId = companyId();
        SABPaymentActionService.RatesView view;
        List<String> messages = new List<String>();
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            SABPaymentActionService.RateRequest request = new SABPaymentActionService.RateRequest();
            request.fromCurrency = 'usd';
            request.rate = 1.52;
            request.effectiveDate = Date.today();
            Id rateId = SABPaymentActionService.saveRate(companyId, request, 'PAS-RATE-1');
            System.assertEquals(rateId, SABPaymentActionService.saveRate(companyId, request, 'PAS-RATE-1'), 'Replay returns the same rate.');
            try {
                SABPaymentActionService.saveRate(companyId, request, 'PAS-RATE-2');
            } catch (SABPaymentActionService.PaymentActionException ex) {
                messages.add(ex.getMessage());
            }
            request.fromCurrency = 'AUD';
            try {
                SABPaymentActionService.saveRate(companyId, request, 'PAS-RATE-3');
            } catch (SABPaymentActionService.PaymentActionException ex) {
                messages.add(ex.getMessage());
            }
            request.fromCurrency = 'EUR';
            request.rate = 0;
            try {
                SABPaymentActionService.saveRate(companyId, request, 'PAS-RATE-4');
            } catch (SABPaymentActionService.PaymentActionException ex) {
                messages.add(ex.getMessage());
            }
            view = SABPaymentActionService.getRates(companyId);
            Test.stopTest();
        }
        System.assert(messages[0].contains('already exists'), messages[0]);
        System.assertEquals('Choose two different currencies.', messages[1], 'Different currencies.');
        System.assertEquals('The rate must be greater than zero.', messages[2], 'Positive rate.');
        System.assert(view.canManage, 'Setup permission manages rates.');
        System.assertEquals('AUD', view.functionalCurrency, 'Functional currency.');
        System.assertEquals(1, view.rates.size(), 'One rate.');
        System.assertEquals('USD', view.rates[0].fromCurrency, 'Upper-cased currency.');
        System.assert(view.rates[0].approved, 'Manual rates are approved.');
    }

    @IsTest
    static void inactiveCompaniesAreLocked() {
        Id companyId = companyId();
        String message;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            update as system new Accounting_Company__c(Id = companyId, Is_Active__c = false);
        }
        System.runAs(SABAppShellTestFixture.fixtureUser()) {
            Test.startTest();
            try {
                SABCompanyAccessService.assertCompanyActive(companyId);
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                message = ex.getMessage();
            }
            SABAppShellController.ShellContext shell = SABAppShellController.getShellContext(companyId);
            Test.stopTest();
            System.assert(shell.companyInactive, 'The shell knows the company is inactive.');
            for (String id : shell.visibleWorkspaces) {
                System.assert(new Set<String>{ 'home', 'setup', 'config' }.contains(id), 'Only home, setup and configuration stay open: ' + id);
            }
        }
        System.assertEquals('This company is inactive. Reactivate it in Company setup to continue.', message, 'Locked message.');
    }
}