/**
 * Not-fixed-yet batch: payment actions the Payments and Foreign exchange workspaces were missing.
 *
 *   allocateDisbursement  apply a cleared same-currency supplier payment to posted bills (SABPaymentAllocationService)
 *   getRates / saveRate   maintain the approved exchange rates that foreign-currency payments and revaluation use
 *
 * Foreign-currency payments are authorised, released, posted and allocated by SABForeignCurrencySettlementService;
 * this class only refuses them here with a pointer to Foreign exchange. Every write checks the company grant and the
 * caller's access, is idempotent by request key and is audited in Business_Action__c.
 */
public with sharing class SABPaymentActionService {
    public class PaymentActionException extends Exception {}

    private static final String FX_PERMISSION = 'SAB_Process_Foreign_Currency_Settlement';
    private static final String SETUP_PERMISSION = 'SAB_Manage_Company_Setup';
    private static final List<String> RATE_TYPES = new List<String>{ 'Spot', 'Closing', 'Average', 'Custom' };

    public class BillAllocation {
        @AuraEnabled public Id supplierBillId { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
    }

    public class RateRequest {
        @AuraEnabled public String fromCurrency { get; set; }
        @AuraEnabled public String toCurrency { get; set; }
        @AuraEnabled public String rateType { get; set; }
        @AuraEnabled public Decimal rate { get; set; }
        @AuraEnabled public Date effectiveDate { get; set; }
    }

    public class RateRow {
        @AuraEnabled public Id rateId { get; set; }
        @AuraEnabled public String fromCurrency { get; set; }
        @AuraEnabled public String toCurrency { get; set; }
        @AuraEnabled public String rateType { get; set; }
        @AuraEnabled public Decimal rate { get; set; }
        @AuraEnabled public Datetime effectiveAt { get; set; }
        @AuraEnabled public Boolean approved { get; set; }
        @AuraEnabled public String source { get; set; }
    }

    public class RatesView {
        @AuraEnabled public Boolean canManage { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public List<RateRow> rates { get; set; }
    }

    // ------------------------------------------------------------ allocation

    @AuraEnabled
    public static Integer allocateDisbursement(Id paymentId, List<BillAllocation> lines, String requestKey) {
        String key = requireKey(requestKey);
        if (paymentId == null) {
            throw new PaymentActionException('Payment is required.');
        }
        Accounting_Payment__c payment = new Store().payment(paymentId);
        assertCompany(payment.Company__c);
        if (!Schema.SObjectType.Payment_Allocation__c.isCreateable()) {
            throw new PaymentActionException('You do not have permission to allocate payments.');
        }
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return lines == null ? 0 : lines.size();
        }
        if (payment.Direction__c != 'Disbursement') {
            throw new PaymentActionException('Only supplier payments are allocated to bills here. Allocate receipts to invoices.');
        }
        if (payment.Transaction_Currency__c != payment.Company__r.Functional_Currency__c) {
            throw new PaymentActionException('This is a foreign-currency payment. Allocate it in Foreign exchange, which also posts the realized gain or loss.');
        }
        if (lines == null || lines.isEmpty()) {
            throw new PaymentActionException('Enter an amount for at least one bill.');
        }
        List<SABPaymentAllocationService.PaymentAllocationRequest> requests = new List<SABPaymentAllocationService.PaymentAllocationRequest>();
        for (BillAllocation line : lines) {
            if (line == null || line.supplierBillId == null || line.amount == null || line.amount <= 0) {
                throw new PaymentActionException('Each bill needs an amount greater than zero.');
            }
            SABPaymentAllocationService.PaymentAllocationRequest request = new SABPaymentAllocationService.PaymentAllocationRequest();
            request.supplierBillId = line.supplierBillId;
            request.allocatedAmount = line.amount;
            request.allocationDate = Date.today();
            request.effectiveDate = Date.today();
            request.transactionCurrency = payment.Transaction_Currency__c;
            request.exchangeRate = 1;
            requests.add(request);
        }
        Savepoint sp = Database.setSavepoint();
        try {
            SABPaymentAllocationService.allocatePayment(paymentId, requests);
            new Writer().audit(new Business_Action__c(Company__c = payment.Company__c, Action__c = 'PAYMENT_ALLOCATED', Actor__c = UserInfo.getUserId(),
                Action_At__c = System.now(), Request_Key__c = key, Source_Type__c = 'Accounting_Payment__c', Source_Record_Id__c = String.valueOf(paymentId),
                Source_Version__c = 1, Reason__c = ('Allocated to ' + lines.size() + ' bill(s)').left(255)));
        } catch (SABPaymentAllocationService.PaymentAllocationException ex) {
            Database.rollback(sp);
            throw new PaymentActionException(ex.getMessage());
        }
        return requests.size();
    }

    // ------------------------------------------------------------------ rates

    @AuraEnabled
    public static RatesView getRates(Id companyId) {
        assertCompany(companyId);
        RatesView view = new RatesView();
        view.canManage = canManageRates();
        view.functionalCurrency = new Store().functionalCurrency(companyId);
        view.rates = new List<RateRow>();
        if (!Schema.SObjectType.Exchange_Rate__c.isAccessible()) {
            return view;
        }
        for (Exchange_Rate__c r : [SELECT Id, From_Currency__c, To_Currency__c, Rate_Type__c, Rate__c, Effective_Date_Time__c, Approved__c, Source__c
                FROM Exchange_Rate__c WHERE To_Currency__c = :view.functionalCurrency OR From_Currency__c = :view.functionalCurrency
                WITH USER_MODE ORDER BY Effective_Date_Time__c DESC LIMIT 100]) {
            RateRow row = new RateRow();
            row.rateId = r.Id;
            row.fromCurrency = r.From_Currency__c;
            row.toCurrency = r.To_Currency__c;
            row.rateType = r.Rate_Type__c;
            row.rate = r.Rate__c;
            row.effectiveAt = r.Effective_Date_Time__c;
            row.approved = r.Approved__c == true;
            row.source = r.Source__c;
            view.rates.add(row);
        }
        return view;
    }

    /** Adds an approved rate. Rates are global; the company only supplies the default target currency. */
    @AuraEnabled
    public static Id saveRate(Id companyId, RateRequest request, String requestKey) {
        String key = requireKey(requestKey);
        assertCompany(companyId);
        if (!canManageRates()) {
            throw new PaymentActionException('You do not have permission to maintain exchange rates.');
        }
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return Id.valueOf(prior.Source_Record_Id__c);
        }
        if (request == null) {
            throw new PaymentActionException('Exchange rate details are required.');
        }
        String fromCode = code(request.fromCurrency, 'From currency');
        String toCode = String.isBlank(request.toCurrency) ? store.functionalCurrency(companyId) : code(request.toCurrency, 'To currency');
        if (fromCode == toCode) {
            throw new PaymentActionException('Choose two different currencies.');
        }
        if (request.rate == null || request.rate <= 0) {
            throw new PaymentActionException('The rate must be greater than zero.');
        }
        String type = String.isBlank(request.rateType) ? 'Spot' : request.rateType;
        if (!RATE_TYPES.contains(type)) {
            throw new PaymentActionException('Rate type must be Spot, Closing, Average or Custom.');
        }
        Date onDate = request.effectiveDate == null ? Date.today() : request.effectiveDate;
        Datetime effectiveAt = Datetime.newInstance(onDate, Time.newInstance(0, 0, 0, 0));
        Exchange_Rate__c rate = new Exchange_Rate__c(From_Currency__c = fromCode, To_Currency__c = toCode, Rate_Type__c = type, Rate__c = request.rate,
            Effective_Date_Time__c = effectiveAt, Approved__c = true, Approved_By__c = UserInfo.getUserId(), Source__c = 'Manual entry',
            Rate_Key__c = (fromCode + '-' + toCode + '-' + type + '-' + String.valueOf(onDate)).left(180));
        if (store.rateExists(rate.Rate_Key__c)) {
            throw new PaymentActionException('A ' + type + ' rate for ' + fromCode + ' to ' + toCode + ' on ' + onDate.format() + ' already exists.');
        }
        new Writer().saveRate(rate, new Business_Action__c(Company__c = companyId, Action__c = 'EXCHANGE_RATE_SAVED', Actor__c = UserInfo.getUserId(),
            Action_At__c = System.now(), Request_Key__c = key, Source_Type__c = 'Exchange_Rate__c', Source_Version__c = 1,
            Reason__c = (type + ' ' + fromCode + '/' + toCode + ' ' + request.rate + ' from ' + onDate.format()).left(255)));
        return rate.Id;
    }

    // ---------------------------------------------------------------- helpers

    private static Boolean canManageRates() {
        return SABPermissionService.hasPermission(FX_PERMISSION) || SABPermissionService.hasPermission(SETUP_PERMISSION);
    }

    private static String code(String value, String label) {
        String trimmed = value == null ? '' : value.trim().toUpperCase();
        if (!Pattern.matches('[A-Z]{3}', trimmed)) {
            throw new PaymentActionException(label + ' must be a three-letter code.');
        }
        return trimmed;
    }

    private static void assertCompany(Id companyId) {
        if (companyId == null || !SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw new PaymentActionException('You do not have active access to this Accounting Company.');
        }
    }

    private static String requireKey(String requestKey) {
        if (String.isBlank(requestKey) || requestKey.trim().length() > 160) {
            throw new PaymentActionException('A request key of up to 160 characters is required.');
        }
        return requestKey.trim();
    }

    // System reads after the access checks above.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c FROM Business_Action__c WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }

        Accounting_Payment__c payment(Id paymentId) {
            List<Accounting_Payment__c> rows = [SELECT Id, Company__c, Company__r.Functional_Currency__c, Direction__c, Transaction_Currency__c
                FROM Accounting_Payment__c WHERE Id = :paymentId WITH SYSTEM_MODE LIMIT 1];
            if (rows.isEmpty()) {
                throw new PaymentActionException('The payment was not found.');
            }
            return rows[0];
        }

        String functionalCurrency(Id companyId) {
            return [SELECT Functional_Currency__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE LIMIT 1].Functional_Currency__c;
        }

        Boolean rateExists(String rateKey) {
            return [SELECT COUNT() FROM Exchange_Rate__c WHERE Rate_Key__c = :rateKey WITH SYSTEM_MODE] > 0;
        }
    }

    // System writes after the access and permission checks above.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void audit(Business_Action__c row) {
            insert as system row;
        }

        void saveRate(Exchange_Rate__c rate, Business_Action__c entry) {
            insert as system rate;
            entry.Source_Record_Id__c = String.valueOf(rate.Id);
            insert as system entry;
        }
    }
}