/**
 * G8D - Expense Operations Workspace read/query controller.
 *
 * Accounting mutations remain in the established G8A-G8C domain services.
 * This controller exposes company-scoped operational read models for the LWC.
 */
public with sharing class SABExpenseOperationsWorkspaceController {

    private static final String VIEW_PERMISSION =
        'SAB_View_Expense_Operations';
    private static final Decimal ZERO =
        Decimal.valueOf('0');

    public class ExpenseWorkspaceException extends Exception {}

    public class ClaimDTO {
        @AuraEnabled public Id claimId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String claimantName { get; set; }
        @AuraEnabled public Date claimDate { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Decimal totalAmount { get; set; }
        @AuraEnabled public Decimal paidAmount { get; set; }
        @AuraEnabled public Decimal remainingAmount { get; set; }
        @AuraEnabled public Integer lineCount { get; set; }
        @AuraEnabled public Integer settlementCount { get; set; }
        @AuraEnabled public Id approvalRequestId { get; set; }
        @AuraEnabled public Id accountingEventId { get; set; }
        @AuraEnabled public Id journalEntryId { get; set; }
    }

    public class ClaimLineDTO {
        @AuraEnabled public Id lineId { get; set; }
        @AuraEnabled public Date expenseDate { get; set; }
        @AuraEnabled public String category { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public Id expenseAccountId { get; set; }
        @AuraEnabled public String expenseAccountCode { get; set; }
        @AuraEnabled public String expenseAccountName { get; set; }
        @AuraEnabled public Id taxCodeId { get; set; }
        @AuraEnabled public String taxCode { get; set; }
        @AuraEnabled public Decimal taxRatePercent { get; set; }
        @AuraEnabled public Decimal taxableBase { get; set; }
        @AuraEnabled public Decimal taxAmount { get; set; }
        @AuraEnabled public Decimal recoverableTax { get; set; }
        @AuraEnabled public Decimal nonrecoverableTax { get; set; }
        @AuraEnabled public String taxTreatment { get; set; }
        @AuraEnabled public String taxJurisdiction { get; set; }
        @AuraEnabled public Id departmentId { get; set; }
        @AuraEnabled public Id projectId { get; set; }
    }

    public class SettlementDTO {
        @AuraEnabled public Id settlementId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public Id expenseClaimId { get; set; }
        @AuraEnabled public Id paymentId { get; set; }
        @AuraEnabled public String paymentName { get; set; }
        @AuraEnabled public String paymentReference { get; set; }
        @AuraEnabled public Decimal allocatedAmount { get; set; }
        @AuraEnabled public Date effectiveDate { get; set; }
        @AuraEnabled public String settlementKey { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Id reversalOfId { get; set; }
    }

    public class PaymentDTO {
        @AuraEnabled public Id paymentId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String reference { get; set; }
        @AuraEnabled public String processingState { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Date effectiveDate { get; set; }
        @AuraEnabled public Id bankAccountId { get; set; }
        @AuraEnabled public String bankAccountName { get; set; }
        @AuraEnabled public String providerRequestKey { get; set; }
        @AuraEnabled public Id accountingEventId { get; set; }
        @AuraEnabled public Id journalEntryId { get; set; }
        @AuraEnabled public Decimal allocatedAmount { get; set; }
        @AuraEnabled public Decimal remainingAmount { get; set; }
    }

    public class ClaimDetailDTO {
        @AuraEnabled public Id claimId { get; set; }
        @AuraEnabled public List<ClaimLineDTO> lines { get; set; }
        @AuraEnabled public List<SettlementDTO> settlements { get; set; }
    }

    public class DashboardDTO {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String companyName { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }

        @AuraEnabled public Boolean canSubmitClaim { get; set; }
        @AuraEnabled public Boolean canReviewClaim { get; set; }
        @AuraEnabled public Boolean canPostClaim { get; set; }
        @AuraEnabled public Boolean canProcessReimbursement { get; set; }

        @AuraEnabled public Integer draftCount { get; set; }
        @AuraEnabled public Integer submittedCount { get; set; }
        @AuraEnabled public Integer approvedCount { get; set; }
        @AuraEnabled public Integer postedCount { get; set; }
        @AuraEnabled public Integer partPaidCount { get; set; }
        @AuraEnabled public Integer paidCount { get; set; }
        @AuraEnabled public Integer rejectedCount { get; set; }

        @AuraEnabled public Decimal reimbursementOutstanding { get; set; }

        @AuraEnabled public List<ClaimDTO> claims { get; set; }
        @AuraEnabled public List<PaymentDTO> reimbursementPayments { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static DashboardDTO getDashboard(Id companyId) {
        assertViewPermission();

        if (companyId == null) {
            throw new AuraHandledException(
                'Accounting Company is required.'
            );
        }

        try {
            SABExpenseSecurityPolicy.assertWorkspaceReadAccess();
            SABCompanyAccessService.assertCompanyAccess(companyId);

            Accounting_Company__c company = [
                SELECT Id,
                       Name__c,
                       Functional_Currency__c
                FROM Accounting_Company__c
                WHERE Id = :companyId
                LIMIT 1
            ];

            DashboardDTO out = new DashboardDTO();
            out.companyId = company.Id;
            out.companyName = company.Name__c;
            out.functionalCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    company.Functional_Currency__c
                );

            out.canSubmitClaim =
                SABPermissionService.hasPermission(
                    'SAB_Submit_Expense_Claim'
                );
            out.canReviewClaim =
                SABPermissionService.hasPermission(
                    'SAB_Review_Expense_Claim'
                );
            out.canPostClaim =
                SABPermissionService.hasPermission(
                    'SAB_Post_Expense_Claim'
                );
            out.canProcessReimbursement =
                SABPermissionService.hasPermission(
                    'SAB_Process_Expense_Reimbursement'
                );

            out.draftCount = 0;
            out.submittedCount = 0;
            out.approvedCount = 0;
            out.postedCount = 0;
            out.partPaidCount = 0;
            out.paidCount = 0;
            out.rejectedCount = 0;
            out.reimbursementOutstanding = ZERO;

            out.claims = loadClaims(companyId, out);
            out.reimbursementPayments =
                loadReimbursementPayments(companyId);

            return out;
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static ClaimDetailDTO getClaimDetail(Id claimId) {
        assertViewPermission();

        if (claimId == null) {
            throw new AuraHandledException(
                'Expense Claim is required.'
            );
        }

        try {
            SABExpenseSecurityPolicy.assertWorkspaceReadAccess();

            Expense_Claim__c claim = [
                SELECT Id,
                       Company__c
                FROM Expense_Claim__c
                WHERE Id = :claimId
                LIMIT 1
            ];

            SABCompanyAccessService.assertCompanyAccess(
                claim.Company__c
            );

            ClaimDetailDTO out = new ClaimDetailDTO();
            out.claimId = claim.Id;
            out.lines = loadClaimLines(claim.Id);
            out.settlements =
                loadClaimSettlements(claim.Id);
            return out;
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    private static List<ClaimDTO> loadClaims(
        Id companyId,
        DashboardDTO dashboard
    ) {
        List<Expense_Claim__c> claims = [
            SELECT Id,
                   Name,
                   Claimant_Employment__r.Employee__r.Name,
                   Claim_Date__c,
                   Accounting_Date__c,
                   Currency__c,
                   Status__c,
                   Total__c,
                   Approval_Request__c,
                   Accounting_Event__c,
                   Accounting_Event__r.Journal_Entry__c
            FROM Expense_Claim__c
            WHERE Company__c = :companyId
            ORDER BY Claim_Date__c DESC,
                     CreatedDate DESC
            LIMIT 200
        ];

        Set<Id> claimIds = new Set<Id>();
        for (Expense_Claim__c claim : claims) {
            claimIds.add(claim.Id);
        }

        Map<Id, Decimal> paidByClaim =
            new Map<Id, Decimal>();
        Map<Id, Integer> settlementCountByClaim =
            new Map<Id, Integer>();
        Map<Id, Integer> lineCountByClaim =
            new Map<Id, Integer>();

        if (!claimIds.isEmpty()) {
            for (AggregateResult row : [
                SELECT Expense_Claim__c claimId,
                       SUM(Allocated_Amount__c) paid,
                       COUNT(Id) settlementCount
                FROM Claim_Settlement__c
                WHERE Expense_Claim__c IN :claimIds
                GROUP BY Expense_Claim__c
            ]) {
                Id claimId =
                    (Id) row.get('claimId');
                Decimal paid =
                    (Decimal) row.get('paid');
                paidByClaim.put(
                    claimId,
                    paid == null ? ZERO : paid
                );
                settlementCountByClaim.put(
                    claimId,
                    (Integer) row.get('settlementCount')
                );
            }

            for (AggregateResult row : [
                SELECT Expense_Claim__c claimId,
                       COUNT(Id) lineCount
                FROM Expense_Claim_Line__c
                WHERE Expense_Claim__c IN :claimIds
                GROUP BY Expense_Claim__c
            ]) {
                lineCountByClaim.put(
                    (Id) row.get('claimId'),
                    (Integer) row.get('lineCount')
                );
            }
        }

        List<ClaimDTO> result =
            new List<ClaimDTO>();

        for (Expense_Claim__c claim : claims) {
            Decimal total =
                claim.Total__c == null
                    ? ZERO
                    : claim.Total__c;

            Decimal paid =
                paidByClaim.containsKey(claim.Id)
                    ? paidByClaim.get(claim.Id)
                    : ZERO;

            Decimal remaining =
                total - paid;

            if (remaining < ZERO) {
                remaining = ZERO;
            }

            ClaimDTO dto = new ClaimDTO();
            dto.claimId = claim.Id;
            dto.name = claim.Name;
            dto.claimantName =
                claim.Claimant_Employment__r == null
                    || claim.Claimant_Employment__r.Employee__r == null
                    ? null
                    : claim.Claimant_Employment__r.Employee__r.Name;
            dto.claimDate = claim.Claim_Date__c;
            dto.accountingDate =
                claim.Accounting_Date__c;
            dto.currencyCode = claim.Currency__c;
            dto.status = claim.Status__c;
            dto.totalAmount = total;
            dto.paidAmount = paid;
            dto.remainingAmount = remaining;
            dto.lineCount =
                lineCountByClaim.containsKey(claim.Id)
                    ? lineCountByClaim.get(claim.Id)
                    : 0;
            dto.settlementCount =
                settlementCountByClaim.containsKey(
                    claim.Id
                )
                    ? settlementCountByClaim.get(
                        claim.Id
                    )
                    : 0;
            dto.approvalRequestId =
                claim.Approval_Request__c;
            dto.accountingEventId =
                claim.Accounting_Event__c;
            dto.journalEntryId =
                claim.Accounting_Event__r == null
                    ? null
                    : claim.Accounting_Event__r.Journal_Entry__c;

            incrementStatusCount(
                dashboard,
                claim.Status__c
            );

            if (
                claim.Status__c == 'Posted'
                || claim.Status__c == 'Part Paid'
            ) {
                dashboard.reimbursementOutstanding +=
                    remaining;
            }

            result.add(dto);
        }

        dashboard.reimbursementOutstanding =
            SABMoneyService.normalizeTransactionAmount(
                dashboard.reimbursementOutstanding,
                RoundingMode.HALF_UP
            );

        return result;
    }

    private static List<PaymentDTO> loadReimbursementPayments(
        Id companyId
    ) {
        List<Accounting_Payment__c> payments = [
            SELECT Id,
                   Name,
                   Reference__c,
                   Processing_State__c,
                   Amount__c,
                   Transaction_Currency__c,
                   Effective_Date__c,
                   Bank_Account__c,
                   Bank_Account__r.Name,
                   Provider_Request_Key__c,
                   Accounting_Event__c,
                   Accounting_Event__r.Journal_Entry__c
            FROM Accounting_Payment__c
            WHERE Company__c = :companyId
              AND Direction__c = 'Disbursement'
              AND Party_Profile__c = null
            ORDER BY Effective_Date__c DESC,
                     CreatedDate DESC
            LIMIT 200
        ];

        Set<Id> paymentIds = new Set<Id>();
        for (Accounting_Payment__c payment : payments) {
            paymentIds.add(payment.Id);
        }

        Map<Id, Decimal> allocatedByPayment =
            new Map<Id, Decimal>();

        if (!paymentIds.isEmpty()) {
            for (AggregateResult row : [
                SELECT Payment__c paymentId,
                       SUM(Allocated_Amount__c) allocated
                FROM Claim_Settlement__c
                WHERE Payment__c IN :paymentIds
                GROUP BY Payment__c
            ]) {
                Decimal allocated =
                    (Decimal) row.get('allocated');

                allocatedByPayment.put(
                    (Id) row.get('paymentId'),
                    allocated == null ? ZERO : allocated
                );
            }
        }

        List<PaymentDTO> result =
            new List<PaymentDTO>();

        for (Accounting_Payment__c payment : payments) {
            Decimal amount =
                payment.Amount__c == null
                    ? ZERO
                    : payment.Amount__c;
            Decimal allocated =
                allocatedByPayment.containsKey(payment.Id)
                    ? allocatedByPayment.get(payment.Id)
                    : ZERO;

            PaymentDTO dto = new PaymentDTO();
            dto.paymentId = payment.Id;
            dto.name = payment.Name;
            dto.reference = payment.Reference__c;
            dto.processingState =
                payment.Processing_State__c;
            dto.amount = amount;
            dto.currencyCode =
                payment.Transaction_Currency__c;
            dto.effectiveDate =
                payment.Effective_Date__c;
            dto.bankAccountId =
                payment.Bank_Account__c;
            dto.bankAccountName =
                payment.Bank_Account__r == null
                    ? null
                    : payment.Bank_Account__r.Name;
            dto.providerRequestKey =
                payment.Provider_Request_Key__c;
            dto.accountingEventId =
                payment.Accounting_Event__c;
            dto.journalEntryId =
                payment.Accounting_Event__r == null
                    ? null
                    : payment.Accounting_Event__r.Journal_Entry__c;
            dto.allocatedAmount = allocated;
            dto.remainingAmount =
                amount - allocated;

            result.add(dto);
        }

        return result;
    }

    private static List<ClaimLineDTO> loadClaimLines(
        Id claimId
    ) {
        List<ClaimLineDTO> result =
            new List<ClaimLineDTO>();

        for (Expense_Claim_Line__c line : [
            SELECT Id,
                   Expense_Date__c,
                   Category__c,
                   Description__c,
                   Amount__c,
                   Expense_Account__c,
                   Expense_Account__r.Account_Code__c,
                   Expense_Account__r.Name,
                   Tax_Code__c,
                   Tax_Code__r.Code__c,
                   Tax_Rate_Percent__c,
                   Taxable_Base__c,
                   Tax_Amount__c,
                   Recoverable_Tax_Amount__c,
                   Nonrecoverable_Tax_Amount__c,
                   Tax_Treatment__c,
                   Tax_Jurisdiction__c,
                   Department__c,
                   Project__c
            FROM Expense_Claim_Line__c
            WHERE Expense_Claim__c = :claimId
            ORDER BY Expense_Date__c,
                     CreatedDate
            LIMIT 500
        ]) {
            ClaimLineDTO dto =
                new ClaimLineDTO();
            dto.lineId = line.Id;
            dto.expenseDate =
                line.Expense_Date__c;
            dto.category = line.Category__c;
            dto.description =
                line.Description__c;
            dto.amount = line.Amount__c;
            dto.expenseAccountId =
                line.Expense_Account__c;
            dto.expenseAccountCode =
                line.Expense_Account__r == null
                    ? null
                    : line.Expense_Account__r.Account_Code__c;
            dto.expenseAccountName =
                line.Expense_Account__r == null
                    ? null
                    : line.Expense_Account__r.Name;
            dto.taxCodeId = line.Tax_Code__c;
            dto.taxCode =
                line.Tax_Code__r == null
                    ? null
                    : line.Tax_Code__r.Code__c;
            dto.taxRatePercent =
                line.Tax_Rate_Percent__c;
            dto.taxableBase =
                line.Taxable_Base__c;
            dto.taxAmount =
                line.Tax_Amount__c;
            dto.recoverableTax =
                line.Recoverable_Tax_Amount__c;
            dto.nonrecoverableTax =
                line.Nonrecoverable_Tax_Amount__c;
            dto.taxTreatment =
                line.Tax_Treatment__c;
            dto.taxJurisdiction =
                line.Tax_Jurisdiction__c;
            dto.departmentId =
                line.Department__c;
            dto.projectId = line.Project__c;
            result.add(dto);
        }

        return result;
    }

    private static List<SettlementDTO> loadClaimSettlements(
        Id claimId
    ) {
        List<SettlementDTO> result =
            new List<SettlementDTO>();

        for (Claim_Settlement__c settlement : [
            SELECT Id,
                   Name,
                   Expense_Claim__c,
                   Payment__c,
                   Payment__r.Name,
                   Payment__r.Reference__c,
                   Allocated_Amount__c,
                   Effective_Date__c,
                   Settlement_Key__c,
                   Status__c,
                   Reversal_Of__c
            FROM Claim_Settlement__c
            WHERE Expense_Claim__c = :claimId
            ORDER BY Effective_Date__c DESC,
                     CreatedDate DESC
            LIMIT 500
        ]) {
            SettlementDTO dto =
                new SettlementDTO();
            dto.settlementId = settlement.Id;
            dto.name = settlement.Name;
            dto.expenseClaimId =
                settlement.Expense_Claim__c;
            dto.paymentId =
                settlement.Payment__c;
            dto.paymentName =
                settlement.Payment__r == null
                    ? null
                    : settlement.Payment__r.Name;
            dto.paymentReference =
                settlement.Payment__r == null
                    ? null
                    : settlement.Payment__r.Reference__c;
            dto.allocatedAmount =
                settlement.Allocated_Amount__c;
            dto.effectiveDate =
                settlement.Effective_Date__c;
            dto.settlementKey =
                settlement.Settlement_Key__c;
            dto.status = settlement.Status__c;
            dto.reversalOfId =
                settlement.Reversal_Of__c;
            result.add(dto);
        }

        return result;
    }

    private static void incrementStatusCount(
        DashboardDTO dashboard,
        String status
    ) {
        if (status == 'Draft') {
            dashboard.draftCount++;
        } else if (status == 'Submitted') {
            dashboard.submittedCount++;
        } else if (status == 'Approved') {
            dashboard.approvedCount++;
        } else if (status == 'Posted') {
            dashboard.postedCount++;
        } else if (status == 'Part Paid') {
            dashboard.partPaidCount++;
        } else if (status == 'Paid') {
            dashboard.paidCount++;
        } else if (status == 'Rejected') {
            dashboard.rejectedCount++;
        }
    }

    private static void assertViewPermission() {
        SABPermissionService.assertPermission(
            VIEW_PERMISSION,
            'You do not have permission to view the Expense Operations Workspace.'
        );
    }
}
