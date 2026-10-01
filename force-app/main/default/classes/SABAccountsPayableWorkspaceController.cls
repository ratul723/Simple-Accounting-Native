/**
 * Accounts Payable operational workspace.
 *
 * Read-only UI facade over the completed G3A-G3D AP domain services:
 * Supplier Bill lifecycle, AP posting, Supplier Payment settlement and
 * Payment Allocation.
 *
 * The controller never mutates financial records. All mutation remains in the
 * existing domain services and their controlled actions.
 */
public with sharing class SABAccountsPayableWorkspaceController {

    public class AccountsPayableWorkspaceException extends Exception {}

    private static final String VIEW_PERMISSION =
        'SAB_View_Accounts_Payable_Workspace';

    private static final Decimal ZERO = Decimal.valueOf('0');
    private static final Integer MAX_BILLS = 2000;
    private static final Integer MAX_PAYMENTS = 1000;

    public class WorkspaceDTO {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String companyName { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public Date asOfDate { get; set; }
        @AuraEnabled public Datetime generatedAt { get; set; }

        @AuraEnabled public Integer totalBills { get; set; }
        @AuraEnabled public Integer pendingBills { get; set; }
        @AuraEnabled public Integer postedBills { get; set; }
        @AuraEnabled public Integer openBills { get; set; }
        @AuraEnabled public Integer overdueBills { get; set; }
        @AuraEnabled public Integer cancelledBills { get; set; }

        @AuraEnabled public Decimal totalOutstanding { get; set; }
        @AuraEnabled public Decimal currentAmount { get; set; }
        @AuraEnabled public Decimal days1To30Amount { get; set; }
        @AuraEnabled public Decimal days31To60Amount { get; set; }
        @AuraEnabled public Decimal days61To90Amount { get; set; }
        @AuraEnabled public Decimal days91PlusAmount { get; set; }

        @AuraEnabled public Integer totalPayments { get; set; }
        @AuraEnabled public Integer pendingPayments { get; set; }
        @AuraEnabled public Integer succeededPayments { get; set; }
        @AuraEnabled public Decimal pendingPaymentAmount { get; set; }
        @AuraEnabled public Decimal succeededPaymentAmount { get; set; }

        @AuraEnabled public List<SupplierOptionDTO> suppliers { get; set; }
        @AuraEnabled public List<BillRowDTO> bills { get; set; }
        @AuraEnabled public List<PaymentRowDTO> payments { get; set; }
    }

    public class SupplierOptionDTO {
        @AuraEnabled public Id value { get; set; }
        @AuraEnabled public String label { get; set; }
    }

    public class BillRowDTO {
        @AuraEnabled public Id billId { get; set; }
        @AuraEnabled public String billNumber { get; set; }
        @AuraEnabled public String vendorReference { get; set; }
        @AuraEnabled public String supplierName { get; set; }
        @AuraEnabled public Id supplierProfileId { get; set; }
        @AuraEnabled public String documentType { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Date documentDate { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public Date dueDate { get; set; }
        @AuraEnabled public Integer daysPastDue { get; set; }
        @AuraEnabled public String agingBucket { get; set; }
        @AuraEnabled public String transactionCurrency { get; set; }
        @AuraEnabled public Decimal totalAmount { get; set; }
        @AuraEnabled public Decimal allocatedAmount { get; set; }
        @AuraEnabled public Decimal outstandingAmount { get; set; }
        @AuraEnabled public Boolean isOverdue { get; set; }
    }

    public class PaymentRowDTO {
        @AuraEnabled public Id paymentId { get; set; }
        @AuraEnabled public String paymentNumber { get; set; }
        @AuraEnabled public String supplierName { get; set; }
        @AuraEnabled public String processingState { get; set; }
        @AuraEnabled public String method { get; set; }
        @AuraEnabled public String reference { get; set; }
        @AuraEnabled public Date effectiveDate { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String transactionCurrency { get; set; }
        @AuraEnabled public String bankAccountName { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static WorkspaceDTO getWorkspace(
        Id companyId,
        Date asOfDate,
        String statusFilter,
        Id supplierProfileId,
        Boolean includeSettled
    ) {
        assertViewPermission();

        if (companyId == null) {
            throw new AuraHandledException(
                'Accounting Company is required.'
            );
        }

        Date reportDate =
            asOfDate == null
                ? Date.today()
                : asOfDate;

        String normalizedFilter =
            String.isBlank(statusFilter)
                ? 'All'
                : statusFilter;

        try {
            SABCompanyAccessService.assertCompanyAccess(companyId);
            assertReadable();

            Accounting_Company__c company = [
                SELECT Id, Name__c, Functional_Currency__c
                FROM Accounting_Company__c
                WHERE Id = :companyId
                  AND Is_Active__c = true
                LIMIT 1
            ];

            List<Party_Accounting_Profile__c> supplierProfiles = [
                SELECT Id,
                       Account__c,
                       Account__r.Name,
                       Is_Active__c
                FROM Party_Accounting_Profile__c
                WHERE Company__c = :companyId
                  AND Is_Supplier__c = true
                ORDER BY Account__r.Name ASC
                LIMIT 2000
            ];

            supplierProfiles = stripSupplierProfiles(supplierProfiles);

            List<Supplier_Bill__c> billRecords = [
                SELECT Id,
                       Name,
                       Company__c,
                       Supplier_Profile__c,
                       Supplier_Profile__r.Account__r.Name,
                       Document_Type__c,
                       Status__c,
                       Document_Date__c,
                       Accounting_Date__c,
                       Due_Date__c,
                       Vendor_Reference__c,
                       Transaction_Currency__c,
                       Total__c
                FROM Supplier_Bill__c
                WHERE Company__c = :companyId
                  AND (
                        Accounting_Date__c = null
                        OR Accounting_Date__c <= :reportDate
                  )
                ORDER BY Due_Date__c ASC NULLS LAST,
                         CreatedDate DESC
                LIMIT :MAX_BILLS
            ];

            billRecords = stripBills(billRecords);

            Set<Id> billIds = new Set<Id>();
            for (Supplier_Bill__c bill : billRecords) {
                billIds.add(bill.Id);
            }

            Map<Id, Decimal> allocationsByBill =
                loadSupplierAllocations(
                    billIds,
                    reportDate
                );

            List<Accounting_Payment__c> paymentRecords = [
                SELECT Id,
                       Name,
                       Company__c,
                       Party_Profile__c,
                       Party_Profile__r.Account__r.Name,
                       Direction__c,
                       Method__c,
                       Reference__c,
                       Amount__c,
                       Transaction_Currency__c,
                       Effective_Date__c,
                       Processing_State__c,
                       Bank_Account__c,
                       Bank_Account__r.Name
                FROM Accounting_Payment__c
                WHERE Company__c = :companyId
                  AND Direction__c = 'Disbursement'
                  AND (
                        Effective_Date__c = null
                        OR Effective_Date__c <= :reportDate
                  )
                ORDER BY Effective_Date__c DESC NULLS LAST,
                         CreatedDate DESC
                LIMIT :MAX_PAYMENTS
            ];

            paymentRecords = stripPayments(paymentRecords);

            WorkspaceDTO dto = initializeWorkspace(
                company,
                reportDate
            );

            dto.suppliers = buildSupplierOptions(
                supplierProfiles
            );

            for (Supplier_Bill__c bill : billRecords) {
                if (
                    supplierProfileId != null
                    && bill.Supplier_Profile__c != supplierProfileId
                ) {
                    continue;
                }

                Decimal rawTotal =
                    bill.Total__c == null
                        ? ZERO
                        : bill.Total__c;

                Boolean isSupplierCredit =
                    bill.Document_Type__c == 'Supplier Credit';

                Decimal signedTotal =
                    isSupplierCredit
                        ? -rawTotal
                        : rawTotal;

                Decimal allocated =
                    allocationsByBill.containsKey(bill.Id)
                        ? allocationsByBill.get(bill.Id)
                        : ZERO;

                Decimal outstanding =
                    bill.Status__c == 'Posted'
                        ? signedTotal - (isSupplierCredit ? -allocated : allocated)
                        : ZERO;

                if (!isSupplierCredit && outstanding < ZERO) {
                    outstanding = ZERO;
                }

                BillRowDTO row = toBillRow(
                    bill,
                    allocated,
                    outstanding,
                    reportDate
                );

                if (!matchesStatusFilter(row, normalizedFilter, includeSettled == true)) {
                    continue;
                }

                dto.bills.add(row);
                dto.totalBills++;

                if (bill.Status__c == 'Cancelled') {
                    dto.cancelledBills++;
                } else if (bill.Status__c == 'Posted') {
                    dto.postedBills++;
                } else if (
                    bill.Status__c == 'Draft'
                    || bill.Status__c == 'Submitted'
                    || bill.Status__c == 'Approved'
                ) {
                    dto.pendingBills++;
                }

                if (bill.Status__c == 'Posted' && outstanding != ZERO) {
                    if (outstanding > ZERO) {
                        dto.openBills++;

                        if (row.isOverdue == true) {
                            dto.overdueBills++;
                        }
                    }

                    dto.totalOutstanding += outstanding;

                    addAgingAmount(
                        dto,
                        row.agingBucket,
                        outstanding
                    );
                }
            }

            for (Accounting_Payment__c payment : paymentRecords) {
                PaymentRowDTO row = toPaymentRow(payment);
                dto.payments.add(row);
                dto.totalPayments++;

                if (payment.Processing_State__c == 'Succeeded') {
                    dto.succeededPayments++;
                    dto.succeededPaymentAmount += safe(payment.Amount__c);
                } else if (
                    payment.Processing_State__c == 'Draft'
                    || payment.Processing_State__c == 'Authorized'
                    || payment.Processing_State__c == 'Submitted'
                    || payment.Processing_State__c == 'Failed'
                ) {
                    dto.pendingPayments++;
                    dto.pendingPaymentAmount += safe(payment.Amount__c);
                }
            }

            return dto;
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    private static WorkspaceDTO initializeWorkspace(
        Accounting_Company__c company,
        Date asOfDate
    ) {
        WorkspaceDTO dto = new WorkspaceDTO();
        dto.companyId = company.Id;
        dto.companyName = company.Name__c;
        dto.functionalCurrency = company.Functional_Currency__c;
        dto.asOfDate = asOfDate;
        dto.generatedAt = Datetime.now();
        dto.totalBills = 0;
        dto.pendingBills = 0;
        dto.postedBills = 0;
        dto.openBills = 0;
        dto.overdueBills = 0;
        dto.cancelledBills = 0;
        dto.totalOutstanding = ZERO;
        dto.currentAmount = ZERO;
        dto.days1To30Amount = ZERO;
        dto.days31To60Amount = ZERO;
        dto.days61To90Amount = ZERO;
        dto.days91PlusAmount = ZERO;
        dto.totalPayments = 0;
        dto.pendingPayments = 0;
        dto.succeededPayments = 0;
        dto.pendingPaymentAmount = ZERO;
        dto.succeededPaymentAmount = ZERO;
        dto.suppliers = new List<SupplierOptionDTO>();
        dto.bills = new List<BillRowDTO>();
        dto.payments = new List<PaymentRowDTO>();
        return dto;
    }

    private static List<SupplierOptionDTO> buildSupplierOptions(
        List<Party_Accounting_Profile__c> profiles
    ) {
        List<SupplierOptionDTO> result =
            new List<SupplierOptionDTO>();

        for (Party_Accounting_Profile__c profile : profiles) {
            SupplierOptionDTO option = new SupplierOptionDTO();
            option.value = profile.Id;
            option.label =
                profile.Account__r == null
                    ? String.valueOf(profile.Id)
                    : profile.Account__r.Name
                        + (
                            profile.Is_Active__c == true
                                ? ''
                                : ' · Inactive'
                        );
            result.add(option);
        }

        return result;
    }

    private static Map<Id, Decimal> loadSupplierAllocations(
        Set<Id> billIds,
        Date asOfDate
    ) {
        Map<Id, Decimal> result = new Map<Id, Decimal>();

        if (billIds.isEmpty()) {
            return result;
        }

        List<Payment_Allocation__c> allocations = [
            SELECT Supplier_Bill__c,
                   Document_Amount__c,
                   Effective_Date__c,
                   Allocation_Date__c,
                   Status__c
            FROM Payment_Allocation__c
            WHERE Supplier_Bill__c IN :billIds
              AND Status__c IN ('Allocated', 'Reversed')
              AND (
                    Effective_Date__c <= :asOfDate
                    OR (
                        Effective_Date__c = null
                        AND Allocation_Date__c <= :asOfDate
                    )
                  )
        ];

        allocations = stripAllocations(allocations);

        for (Payment_Allocation__c allocation : allocations) {
            if (allocation.Supplier_Bill__c == null) {
                continue;
            }

            Decimal amount = safe(
                allocation.Document_Amount__c
            );

            result.put(
                allocation.Supplier_Bill__c,
                (result.containsKey(allocation.Supplier_Bill__c)
                    ? result.get(allocation.Supplier_Bill__c)
                    : ZERO) + amount
            );
        }

        return result;
    }

    private static BillRowDTO toBillRow(
        Supplier_Bill__c bill,
        Decimal allocated,
        Decimal outstanding,
        Date asOfDate
    ) {
        BillRowDTO row = new BillRowDTO();
        row.billId = bill.Id;
        row.billNumber = bill.Name;
        row.vendorReference = bill.Vendor_Reference__c;
        row.supplierProfileId = bill.Supplier_Profile__c;
        row.supplierName =
            bill.Supplier_Profile__r == null
                || bill.Supplier_Profile__r.Account__r == null
                ? null
                : bill.Supplier_Profile__r.Account__r.Name;
        row.documentType = bill.Document_Type__c;
        row.status = bill.Status__c;
        row.documentDate = bill.Document_Date__c;
        row.accountingDate = bill.Accounting_Date__c;
        row.dueDate = bill.Due_Date__c;
        row.daysPastDue = calculateDaysPastDue(
            bill.Due_Date__c,
            asOfDate
        );
        row.agingBucket = agingBucket(row.daysPastDue);
        row.transactionCurrency = bill.Transaction_Currency__c;
        Decimal rawTotal = safe(bill.Total__c);
        Boolean isSupplierCredit =
            bill.Document_Type__c == 'Supplier Credit';
        row.totalAmount = isSupplierCredit ? -rawTotal : rawTotal;
        row.allocatedAmount = isSupplierCredit ? -allocated : allocated;
        row.outstandingAmount = outstanding;
        row.isOverdue =
            bill.Status__c == 'Posted'
            && outstanding > ZERO
            && bill.Due_Date__c != null
            && bill.Due_Date__c < asOfDate;
        return row;
    }

    private static PaymentRowDTO toPaymentRow(
        Accounting_Payment__c payment
    ) {
        PaymentRowDTO row = new PaymentRowDTO();
        row.paymentId = payment.Id;
        row.paymentNumber = payment.Name;
        row.supplierName =
            payment.Party_Profile__r == null
                || payment.Party_Profile__r.Account__r == null
                ? null
                : payment.Party_Profile__r.Account__r.Name;
        row.processingState = payment.Processing_State__c;
        row.method = payment.Method__c;
        row.reference = payment.Reference__c;
        row.effectiveDate = payment.Effective_Date__c;
        row.amount = safe(payment.Amount__c);
        row.transactionCurrency = payment.Transaction_Currency__c;
        row.bankAccountName =
            payment.Bank_Account__r == null
                ? null
                : payment.Bank_Account__r.Name;
        return row;
    }

    private static Boolean matchesStatusFilter(
        BillRowDTO row,
        String statusFilter,
        Boolean includeSettled
    ) {
        if (statusFilter == 'All') {
            return includeSettled || row.status != 'Cancelled';
        }

        if (statusFilter == 'Open') {
            return row.status == 'Posted'
                && row.outstandingAmount > ZERO;
        }

        if (statusFilter == 'Pending') {
            return row.status == 'Draft'
                || row.status == 'Submitted'
                || row.status == 'Approved';
        }

        if (statusFilter == 'Posted') {
            return row.status == 'Posted'
                && (
                    includeSettled
                    || row.outstandingAmount > ZERO
                );
        }

        if (statusFilter == 'Cancelled') {
            return row.status == 'Cancelled';
        }

        return true;
    }

    private static void addAgingAmount(
        WorkspaceDTO dto,
        String bucket,
        Decimal amount
    ) {
        if (bucket == 'Current') {
            dto.currentAmount += amount;
        } else if (bucket == '1–30') {
            dto.days1To30Amount += amount;
        } else if (bucket == '31–60') {
            dto.days31To60Amount += amount;
        } else if (bucket == '61–90') {
            dto.days61To90Amount += amount;
        } else {
            dto.days91PlusAmount += amount;
        }
    }

    private static Integer calculateDaysPastDue(
        Date dueDate,
        Date asOfDate
    ) {
        if (dueDate == null || asOfDate == null) {
            return 0;
        }
        Integer days = dueDate.daysBetween(asOfDate);
        return days < 0 ? 0 : days;
    }

    private static String agingBucket(Integer daysPastDue) {
        if (daysPastDue == null || daysPastDue <= 0) {
            return 'Current';
        }
        if (daysPastDue <= 30) {
            return '1–30';
        }
        if (daysPastDue <= 60) {
            return '31–60';
        }
        if (daysPastDue <= 90) {
            return '61–90';
        }
        return '91+';
    }

    private static Decimal safe(Decimal value) {
        return value == null ? ZERO : value;
    }


    private static List<Party_Accounting_Profile__c> stripSupplierProfiles(
        List<Party_Accounting_Profile__c> rows
    ) {
        List<SObject> stripped = Security.stripInaccessible(
            AccessType.READABLE,
            rows
        ).getRecords();
        List<Party_Accounting_Profile__c> result =
            new List<Party_Accounting_Profile__c>();
        for (SObject row : stripped) {
            result.add((Party_Accounting_Profile__c) row);
        }
        return result;
    }

    private static List<Supplier_Bill__c> stripBills(
        List<Supplier_Bill__c> rows
    ) {
        List<SObject> stripped = Security.stripInaccessible(
            AccessType.READABLE,
            rows
        ).getRecords();
        List<Supplier_Bill__c> result =
            new List<Supplier_Bill__c>();
        for (SObject row : stripped) {
            result.add((Supplier_Bill__c) row);
        }
        return result;
    }

    private static List<Accounting_Payment__c> stripPayments(
        List<Accounting_Payment__c> rows
    ) {
        List<SObject> stripped = Security.stripInaccessible(
            AccessType.READABLE,
            rows
        ).getRecords();
        List<Accounting_Payment__c> result =
            new List<Accounting_Payment__c>();
        for (SObject row : stripped) {
            result.add((Accounting_Payment__c) row);
        }
        return result;
    }

    private static List<Payment_Allocation__c> stripAllocations(
        List<Payment_Allocation__c> rows
    ) {
        List<SObject> stripped = Security.stripInaccessible(
            AccessType.READABLE,
            rows
        ).getRecords();
        List<Payment_Allocation__c> result =
            new List<Payment_Allocation__c>();
        for (SObject row : stripped) {
            result.add((Payment_Allocation__c) row);
        }
        return result;
    }

    private static void assertViewPermission() {
        if (!FeatureManagement.checkPermission(VIEW_PERMISSION)) {
            throw new AuraHandledException(
                'You do not have permission to view the Accounts Payable Workspace.'
            );
        }
    }

    private static void assertReadable() {
        SABAccessControlService.assertReadable(
            Accounting_Company__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Company__c.Name__c,
                Accounting_Company__c.Functional_Currency__c,
                Accounting_Company__c.Is_Active__c
            }
        );

        SABAccessControlService.assertReadable(
            Supplier_Bill__c.SObjectType,
            new List<Schema.SObjectField>{
                Supplier_Bill__c.Name,
                Supplier_Bill__c.Company__c,
                Supplier_Bill__c.Supplier_Profile__c,
                Supplier_Bill__c.Document_Type__c,
                Supplier_Bill__c.Status__c,
                Supplier_Bill__c.Document_Date__c,
                Supplier_Bill__c.Accounting_Date__c,
                Supplier_Bill__c.Due_Date__c,
                Supplier_Bill__c.Vendor_Reference__c,
                Supplier_Bill__c.Transaction_Currency__c,
                Supplier_Bill__c.Total__c
            }
        );

        SABAccessControlService.assertReadable(
            Party_Accounting_Profile__c.SObjectType,
            new List<Schema.SObjectField>{
                Party_Accounting_Profile__c.Company__c,
                Party_Accounting_Profile__c.Account__c,
                Party_Accounting_Profile__c.Is_Supplier__c,
                Party_Accounting_Profile__c.Is_Active__c
            }
        );

        SABAccessControlService.assertReadable(
            Account.SObjectType,
            new List<Schema.SObjectField>{
                Account.Name
            }
        );

        SABAccessControlService.assertReadable(
            Payment_Allocation__c.SObjectType,
            new List<Schema.SObjectField>{
                Payment_Allocation__c.Supplier_Bill__c,
                Payment_Allocation__c.Document_Amount__c,
                Payment_Allocation__c.Effective_Date__c,
                Payment_Allocation__c.Allocation_Date__c,
                Payment_Allocation__c.Status__c
            }
        );

        SABAccessControlService.assertReadable(
            Accounting_Payment__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Payment__c.Name,
                Accounting_Payment__c.Company__c,
                Accounting_Payment__c.Party_Profile__c,
                Accounting_Payment__c.Direction__c,
                Accounting_Payment__c.Method__c,
                Accounting_Payment__c.Reference__c,
                Accounting_Payment__c.Amount__c,
                Accounting_Payment__c.Transaction_Currency__c,
                Accounting_Payment__c.Effective_Date__c,
                Accounting_Payment__c.Processing_State__c,
                Accounting_Payment__c.Bank_Account__c
            }
        );

        SABAccessControlService.assertReadable(
            Bank_Account__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Account__c.Name
            }
        );
    }
}
