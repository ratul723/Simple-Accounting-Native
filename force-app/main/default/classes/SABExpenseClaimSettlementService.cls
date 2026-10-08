/**
 * G8C - Expense Claim reimbursement allocation and settlement.
 *
 * Claim_Settlement__c is the auditable link between a Succeeded
 * employee reimbursement Payment and a Posted Expense Claim.
 *
 * Supports:
 * - partial reimbursement
 * - multiple settlements
 * - overpayment prevention
 * - stable settlement-key replay
 * - reversal by negative reversal settlement
 * - Posted -> Part Paid -> Paid claim lifecycle
 */
public without sharing class SABExpenseClaimSettlementService {

    public class ExpenseClaimSettlementException extends Exception {}

    private static final String PERMISSION =
        'SAB_Process_Expense_Reimbursement';
    private static final Decimal ZERO =
        Decimal.valueOf('0');

    @TestVisible
    private static Boolean settlementMutationInProgress = false;

    public static Boolean isSettlementMutationInProgress() {
        return settlementMutationInProgress;
    }

    public class SettlementRequest {
        @AuraEnabled public Id expenseClaimId { get; set; }
        @AuraEnabled public Id paymentId { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String settlementKey { get; set; }
    }

    public class SettlementResult {
        @AuraEnabled public Id settlementId { get; private set; }
        @AuraEnabled public Id expenseClaimId { get; private set; }
        @AuraEnabled public Id paymentId { get; private set; }
        @AuraEnabled public Decimal allocatedAmount { get; private set; }
        @AuraEnabled public Decimal claimPaidAmount { get; private set; }
        @AuraEnabled public Decimal claimRemainingAmount { get; private set; }
        @AuraEnabled public Decimal paymentRemainingAmount { get; private set; }
        @AuraEnabled public String claimStatus { get; private set; }
        @AuraEnabled public String settlementStatus { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private SettlementResult() {}
    }

    @AuraEnabled
    public static SettlementResult settleClaim(
        SettlementRequest request
    ) {
        assertPermission();
        validateRequest(request);

        Claim_Settlement__c existing =
            findBySettlementKey(
                request.settlementKey.trim()
            );

        if (existing != null) {
            assertReplayCompatible(
                existing,
                request
            );
            return buildResult(
                existing,
                true
            );
        }

        Expense_Claim__c claim =
            lockClaim(request.expenseClaimId);

        SABCompanyAccessService.assertCompanyAccess(
            claim.Company__c
        );

        if (
            claim.Status__c != 'Posted'
            && claim.Status__c != 'Part Paid'
        ) {
            throw new ExpenseClaimSettlementException(
                'Expense Claim must be Posted or Part Paid before reimbursement settlement.'
            );
        }

        Accounting_Payment__c payment =
            lockPayment(request.paymentId);

        validatePaymentForClaim(
            payment,
            claim
        );

        Decimal amount =
            SABMoneyService.normalizeTransactionAmount(
                request.amount,
                RoundingMode.HALF_UP
            );

        Decimal claimTotal =
            SABMoneyService.normalizeTransactionAmount(
                claim.Total__c == null
                    ? ZERO
                    : claim.Total__c,
                RoundingMode.HALF_UP
            );

        Decimal claimPaidBefore =
            calculateNetClaimPaid(claim.Id);

        Decimal paymentAllocatedBefore =
            calculateNetPaymentAllocated(payment.Id);

        Decimal paymentAmount =
            SABMoneyService.normalizeTransactionAmount(
                payment.Amount__c,
                RoundingMode.HALF_UP
            );

        if (claimPaidBefore + amount > claimTotal) {
            throw new ExpenseClaimSettlementException(
                'Settlement exceeds the remaining Expense Claim amount.'
            );
        }

        if (
            paymentAllocatedBefore + amount
                > paymentAmount
        ) {
            throw new ExpenseClaimSettlementException(
                'Settlement exceeds the remaining reimbursement Payment amount.'
            );
        }

        Claim_Settlement__c settlement =
            new Claim_Settlement__c(
                Expense_Claim__c = claim.Id,
                Payment__c = payment.Id,
                Allocated_Amount__c = amount,
                Effective_Date__c =
                    payment.Effective_Date__c,
                Settlement_Key__c =
                    request.settlementKey.trim(),
                Status__c = 'Effective'
            );

        controlledSettlementInsert(settlement);

        Decimal claimPaidAfter =
            SABMoneyService.normalizeTransactionAmount(
                claimPaidBefore + amount,
                RoundingMode.HALF_UP
            );

        String newStatus =
            claimPaidAfter == claimTotal
                ? 'Paid'
                : 'Part Paid';

        controlledClaimStatusUpdate(
            claim,
            newStatus
        );

        createAction(
            claim.Company__c,
            claim.Id,
            'EXPENSE_CLAIM_SETTLED',
            'ECSET|' + String.valueOf(settlement.Id),
            'Expense Claim reimbursement settlement recorded.'
        );

        return buildResult(
            settlement,
            false
        );
    }

    @AuraEnabled
    public static SettlementResult reverseSettlement(
        Id settlementId,
        String reversalSettlementKey
    ) {
        assertPermission();

        if (settlementId == null) {
            throw new ExpenseClaimSettlementException(
                'Settlement Id is required.'
            );
        }

        validateSettlementKey(
            reversalSettlementKey
        );

        Claim_Settlement__c replay =
            findBySettlementKey(
                reversalSettlementKey.trim()
            );

        if (replay != null) {
            if (replay.Reversal_Of__c != settlementId) {
                throw new ExpenseClaimSettlementException(
                    'Reversal Settlement Key has already been used for a different settlement.'
                );
            }
            return buildResult(replay, true);
        }

        Claim_Settlement__c original = [
            SELECT Id, Expense_Claim__c,
                   Payment__c,
                   Allocated_Amount__c,
                   Effective_Date__c,
                   Settlement_Key__c,
                   Status__c,
                   Reversal_Of__c
            FROM Claim_Settlement__c
            WHERE Id = :settlementId
            LIMIT 1
            FOR UPDATE
        ];

        if (
            original.Reversal_Of__c != null
            || original.Allocated_Amount__c == null
            || original.Allocated_Amount__c <= ZERO
        ) {
            throw new ExpenseClaimSettlementException(
                'Only an original positive Claim Settlement can be reversed.'
            );
        }

        if (original.Status__c != 'Effective') {
            throw new ExpenseClaimSettlementException(
                'Only an Effective Claim Settlement can be reversed.'
            );
        }

        Expense_Claim__c claim =
            lockClaim(original.Expense_Claim__c);

        SABCompanyAccessService.assertCompanyAccess(
            claim.Company__c
        );

        Accounting_Payment__c payment =
            lockPayment(original.Payment__c);

        if (payment.Company__c != claim.Company__c) {
            throw new ExpenseClaimSettlementException(
                'Cross-company settlement reversal is not allowed.'
            );
        }

        Claim_Settlement__c reversal =
            new Claim_Settlement__c(
                Expense_Claim__c =
                    original.Expense_Claim__c,
                Payment__c =
                    original.Payment__c,
                Allocated_Amount__c =
                    -original.Allocated_Amount__c,
                Effective_Date__c =
                    original.Effective_Date__c,
                Settlement_Key__c =
                    reversalSettlementKey.trim(),
                Status__c = 'Reversed',
                Reversal_Of__c =
                    original.Id
            );

        settlementMutationInProgress = true;
        try {
            original.Status__c = 'Reversed';
            update original;
            insert reversal;
        } finally {
            settlementMutationInProgress = false;
        }

        Decimal paidAfter =
            calculateNetClaimPaid(claim.Id);

        Decimal claimTotal =
            SABMoneyService.normalizeTransactionAmount(
                claim.Total__c == null
                    ? ZERO
                    : claim.Total__c,
                RoundingMode.HALF_UP
            );

        String newStatus;
        if (paidAfter <= ZERO) {
            newStatus = 'Posted';
        } else if (paidAfter < claimTotal) {
            newStatus = 'Part Paid';
        } else {
            newStatus = 'Paid';
        }

        controlledClaimStatusUpdate(
            claim,
            newStatus
        );

        createAction(
            claim.Company__c,
            claim.Id,
            'EXPENSE_CLAIM_SETTLEMENT_REVERSED',
            'ECREV|' + String.valueOf(reversal.Id),
            'Expense Claim reimbursement settlement reversed.'
        );

        return buildResult(
            reversal,
            false
        );
    }

    private static Expense_Claim__c lockClaim(
        Id claimId
    ) {
        if (claimId == null) {
            throw new ExpenseClaimSettlementException(
                'Expense Claim Id is required.'
            );
        }

        List<Expense_Claim__c> claims = [
            SELECT Id, Company__c,
                   Company__r.Functional_Currency__c,
                   Currency__c, Status__c,
                   Total__c, Accounting_Event__c
            FROM Expense_Claim__c
            WHERE Id = :claimId
            LIMIT 1
            FOR UPDATE
        ];

        if (claims.isEmpty()) {
            throw new ExpenseClaimSettlementException(
                'Expense Claim was not found.'
            );
        }

        return claims[0];
    }

    @TestVisible
    private static Accounting_Payment__c lockPayment(
        Id paymentId
    ) {
        if (paymentId == null) {
            throw new ExpenseClaimSettlementException(
                'Payment Id is required.'
            );
        }

        List<Accounting_Payment__c> payments = [
            SELECT Id, Company__c,
                   Direction__c,
                   Amount__c,
                   Transaction_Currency__c,
                   Functional_Currency__c,
                   Effective_Date__c,
                   Processing_State__c,
                   Accounting_Event__c,
                   Payroll_Run__c,
                   Distribution__c
            FROM Accounting_Payment__c
            WHERE Id = :paymentId
            LIMIT 1
            FOR UPDATE
        ];

        if (payments.isEmpty()) {
            throw new ExpenseClaimSettlementException(
                'Reimbursement Payment was not found.'
            );
        }

        // G10H: a payroll net-pay payment must never settle an employee expense claim.
        if (payments[0].Payroll_Run__c != null) {
            throw new ExpenseClaimSettlementException(
                'Payroll payments are processed only through payroll settlement.'
            );
        }
        // G17: distribution (dividend) payments are settled only by SABDistributionService.
        if (payments[0].Distribution__c != null) {
            throw new ExpenseClaimSettlementException(
                'Distribution payments are processed only through distribution settlement.'
            );
        }

        return payments[0];
    }

    private static void validatePaymentForClaim(
        Accounting_Payment__c payment,
        Expense_Claim__c claim
    ) {
        if (payment.Company__c != claim.Company__c) {
            throw new ExpenseClaimSettlementException(
                'Cross-company Expense Claim settlement is not allowed.'
            );
        }

        if (payment.Direction__c != 'Disbursement') {
            throw new ExpenseClaimSettlementException(
                'Expense Claim reimbursement requires a Disbursement Payment.'
            );
        }

        if (payment.Processing_State__c != 'Succeeded') {
            throw new ExpenseClaimSettlementException(
                'Only a Succeeded reimbursement Payment can settle an Expense Claim.'
            );
        }

        if (
            payment.Amount__c == null
            || payment.Amount__c <= ZERO
        ) {
            throw new ExpenseClaimSettlementException(
                'Reimbursement Payment amount must be greater than zero.'
            );
        }

        if (payment.Effective_Date__c == null) {
            throw new ExpenseClaimSettlementException(
                'Reimbursement Payment Effective Date is required.'
            );
        }

        String claimCurrency =
            SABMoneyService.normalizeCurrencyCode(
                claim.Currency__c
            );
        String paymentCurrency =
            SABMoneyService.normalizeCurrencyCode(
                payment.Transaction_Currency__c
            );
        String functionalCurrency =
            SABMoneyService.normalizeCurrencyCode(
                claim.Company__r.Functional_Currency__c
            );

        if (
            claimCurrency != functionalCurrency
            || paymentCurrency != functionalCurrency
        ) {
            throw new ExpenseClaimSettlementException(
                'G8C supports functional-currency Expense Claim settlement only.'
            );
        }

        if (
            !String.isBlank(
                payment.Functional_Currency__c
            )
            && SABMoneyService.normalizeCurrencyCode(
                payment.Functional_Currency__c
            ) != functionalCurrency
        ) {
            throw new ExpenseClaimSettlementException(
                'Payment Functional Currency must match the Expense Claim Accounting Company.'
            );
        }
    }

    private static Decimal calculateNetClaimPaid(
        Id claimId
    ) {
        AggregateResult row = [
            SELECT SUM(Allocated_Amount__c) total
            FROM Claim_Settlement__c
            WHERE Expense_Claim__c = :claimId
        ];

        Decimal amount =
            (Decimal) row.get('total');

        return SABMoneyService.normalizeTransactionAmount(
            amount == null ? ZERO : amount,
            RoundingMode.HALF_UP
        );
    }

    private static Decimal calculateNetPaymentAllocated(
        Id paymentId
    ) {
        AggregateResult row = [
            SELECT SUM(Allocated_Amount__c) total
            FROM Claim_Settlement__c
            WHERE Payment__c = :paymentId
        ];

        Decimal amount =
            (Decimal) row.get('total');

        return SABMoneyService.normalizeTransactionAmount(
            amount == null ? ZERO : amount,
            RoundingMode.HALF_UP
        );
    }

    private static Claim_Settlement__c findBySettlementKey(
        String key
    ) {
        List<Claim_Settlement__c> rows = [
            SELECT Id, Expense_Claim__c,
                   Payment__c,
                   Allocated_Amount__c,
                   Effective_Date__c,
                   Settlement_Key__c,
                   Status__c,
                   Reversal_Of__c
            FROM Claim_Settlement__c
            WHERE Settlement_Key__c = :key
            LIMIT 1
        ];

        return rows.isEmpty() ? null : rows[0];
    }

    private static void assertReplayCompatible(
        Claim_Settlement__c existing,
        SettlementRequest request
    ) {
        Decimal requested =
            SABMoneyService.normalizeTransactionAmount(
                request.amount,
                RoundingMode.HALF_UP
            );

        if (
            existing.Expense_Claim__c
                != request.expenseClaimId
            || existing.Payment__c
                != request.paymentId
            || existing.Allocated_Amount__c
                != requested
            || existing.Reversal_Of__c != null
        ) {
            throw new ExpenseClaimSettlementException(
                'Settlement Key has already been used for a different settlement.'
            );
        }
    }

    private static SettlementResult buildResult(
        Claim_Settlement__c settlement,
        Boolean replay
    ) {
        Expense_Claim__c claim = [
            SELECT Id, Status__c, Total__c
            FROM Expense_Claim__c
            WHERE Id = :settlement.Expense_Claim__c
            LIMIT 1
        ];

        Accounting_Payment__c payment = [
            SELECT Id, Amount__c
            FROM Accounting_Payment__c
            WHERE Id = :settlement.Payment__c
            LIMIT 1
        ];

        Decimal paid =
            calculateNetClaimPaid(claim.Id);
        Decimal paymentAllocated =
            calculateNetPaymentAllocated(payment.Id);

        Decimal claimTotal =
            SABMoneyService.normalizeTransactionAmount(
                claim.Total__c == null
                    ? ZERO
                    : claim.Total__c,
                RoundingMode.HALF_UP
            );

        Decimal paymentTotal =
            SABMoneyService.normalizeTransactionAmount(
                payment.Amount__c == null
                    ? ZERO
                    : payment.Amount__c,
                RoundingMode.HALF_UP
            );

        SettlementResult result =
            new SettlementResult();
        result.settlementId = settlement.Id;
        result.expenseClaimId =
            settlement.Expense_Claim__c;
        result.paymentId =
            settlement.Payment__c;
        result.allocatedAmount =
            settlement.Allocated_Amount__c;
        result.claimPaidAmount = paid;
        result.claimRemainingAmount =
            claimTotal - paid;
        result.paymentRemainingAmount =
            paymentTotal - paymentAllocated;
        result.claimStatus = claim.Status__c;
        result.settlementStatus =
            settlement.Status__c;
        result.replay = replay;
        return result;
    }

    private static void controlledSettlementInsert(
        Claim_Settlement__c row
    ) {
        settlementMutationInProgress = true;
        try {
            insert row;
        } finally {
            settlementMutationInProgress = false;
        }
    }

    private static void controlledClaimStatusUpdate(
        Expense_Claim__c claim,
        String status
    ) {
        settlementMutationInProgress = true;
        try {
            claim.Status__c = status;
            update claim;
        } finally {
            settlementMutationInProgress = false;
        }
    }

    private static void createAction(
        Id companyId,
        Id claimId,
        String actionName,
        String requestKey,
        String reason
    ) {
        insert new Business_Action__c(
            Company__c = companyId,
            Action__c = actionName,
            Actor__c = UserInfo.getUserId(),
            Action_At__c = System.now(),
            Reason__c = reason,
            Request_Key__c = requestKey,
            Source_Type__c = 'Expense_Claim__c',
            Source_Record_Id__c =
                String.valueOf(claimId),
            Source_Version__c = 1
        );
    }

    private static void validateRequest(
        SettlementRequest request
    ) {
        if (request == null) {
            throw new ExpenseClaimSettlementException(
                'Settlement request is required.'
            );
        }

        if (request.expenseClaimId == null) {
            throw new ExpenseClaimSettlementException(
                'Expense Claim Id is required.'
            );
        }

        if (request.paymentId == null) {
            throw new ExpenseClaimSettlementException(
                'Payment Id is required.'
            );
        }

        if (
            request.amount == null
            || request.amount <= ZERO
        ) {
            throw new ExpenseClaimSettlementException(
                'Settlement amount must be greater than zero.'
            );
        }

        validateSettlementKey(
            request.settlementKey
        );
    }

    private static void validateSettlementKey(
        String key
    ) {
        if (String.isBlank(key)) {
            throw new ExpenseClaimSettlementException(
                'Settlement Key is required.'
            );
        }

        Integer maxLength =
            Claim_Settlement__c.Settlement_Key__c.getDescribe().getLength();

        if (
            maxLength > 0
            && key.trim().length() > maxLength
        ) {
            throw new ExpenseClaimSettlementException(
                'Settlement Key cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static void assertPermission() {
        SABPermissionService.assertPermission(
            PERMISSION,
            'You do not have permission to process employee expense reimbursements.'
        );
    }
}
