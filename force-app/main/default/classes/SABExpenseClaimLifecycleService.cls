/**
 * G8A - Expense Claim Foundation & Approval Lifecycle.
 *
 * Scope:
 * - Draft -> Submitted -> Approved / Rejected
 * - Claim line validation and deterministic claim total
 * - Employment/company/currency controls
 * - Approval_Request__c creation and completion
 * - request-key replay protection
 *
 * Posting and reimbursement are intentionally deferred to G8B/G8C.
 */
public with sharing class SABExpenseClaimLifecycleService {

    public class ExpenseClaimLifecycleException extends Exception {}

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    private static final String SOURCE_TYPE =
        'Expense_Claim__c';

    private static final String POLICY_VERSION =
        'EXPENSE-CLAIM-V1';

    private static final String STATUS_DRAFT =
        'Draft';

    private static final String STATUS_SUBMITTED =
        'Submitted';

    private static final String STATUS_APPROVED =
        'Approved';

    private static final String STATUS_REJECTED =
        'Rejected';

    private static final String STATUS_POSTED =
        'Posted';

    private static final String APPROVAL_PENDING =
        'Pending';

    private static final String APPROVAL_APPROVED =
        'Approved';

    private static final String APPROVAL_REJECTED =
        'Rejected';

    @TestVisible
    private static Boolean lifecycleMutationInProgress =
        false;

    public static Boolean isLifecycleMutationInProgress() {
        return lifecycleMutationInProgress;
    }

    public class LifecycleResult {
        @AuraEnabled public Id claimId { get; private set; }
        @AuraEnabled public String status { get; private set; }
        @AuraEnabled public Decimal total { get; private set; }
        @AuraEnabled public Id approvalRequestId { get; private set; }
        @AuraEnabled public String approvalStatus { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private LifecycleResult() {}
    }

    @AuraEnabled
    public static LifecycleResult submitClaim(
        Id claimId,
        String requestKey
    ) {
        SABPermissionService.assertPermission(
            'SAB_Submit_Expense_Claim',
            'You do not have permission to submit Expense Claims.'
        );

        validateRequestKey(
            requestKey
        );

        LifecycleResult replay =
            findSubmitReplay(
                claimId,
                requestKey
            );

        if (replay != null) {
            return replay;
        }

        Savepoint sp =
            Database.setSavepoint();

        try {
            Expense_Claim__c claim =
                lockClaim(
                    claimId
                );

            SABCompanyAccessService.assertCompanyAccess(
                claim.Company__c
            );

            if (claim.Status__c != STATUS_DRAFT) {
                throw new ExpenseClaimLifecycleException(
                    'Only a Draft Expense Claim can be submitted.'
                );
            }

            validateClaimHeader(
                claim
            );

            List<Expense_Claim_Line__c> lines =
                loadLines(
                    claim.Id,
                    true
                );

            Decimal total =
                validateLinesAndCalculateTotal(
                    claim,
                    lines,
                    false
                );

            Approval_Request__c approvalRequest =
                new Approval_Request__c(
                    Company__c =
                        claim.Company__c,
                    Policy_Version__c =
                        POLICY_VERSION,
                    Request_Key__c =
                        requestKey.trim(),
                    Requested_At__c =
                        System.now(),
                    Requested_By__c =
                        UserInfo.getUserId(),
                    Source_Business_Key__c =
                        claim.Name,
                    Source_Record_Id__c =
                        String.valueOf(
                            claim.Id
                        ),
                    Source_Type__c =
                        SOURCE_TYPE,
                    Source_Version__c =
                        1,
                    Status__c =
                        APPROVAL_PENDING
                );

            insert approvalRequest;

            lifecycleMutationInProgress =
                true;

            try {
                claim.Total__c =
                    total;
                claim.Approval_Request__c =
                    approvalRequest.Id;
                claim.Status__c =
                    STATUS_SUBMITTED;
                update claim;
            } finally {
                lifecycleMutationInProgress =
                    false;
            }

            logAction(
                claim.Company__c,
                claim.Id,
                'EXPENSE_CLAIM_SUBMITTED',
                'EXP-SUBMIT-'
                    + digest(
                        requestKey
                    ).substring(
                        0,
                        40
                    ),
                'Expense Claim submitted for approval.'
            );

            return buildResult(
                claim.Id,
                false
            );
        } catch (Exception ex) {
            Database.rollback(
                sp
            );
            throw ex;
        }
    }

    @AuraEnabled
    public static LifecycleResult approveClaim(
        Id claimId,
        String requestKey,
        String reason
    ) {
        SABPermissionService.assertPermission(
            'SAB_Review_Expense_Claim',
            'You do not have permission to review Expense Claims.'
        );

        validateRequestKey(
            requestKey
        );

        LifecycleResult replay =
            findReviewReplay(
                claimId,
                requestKey,
                'EXPENSE_CLAIM_APPROVED',
                STATUS_APPROVED
            );

        if (replay != null) {
            return replay;
        }

        Savepoint sp =
            Database.setSavepoint();

        try {
            Expense_Claim__c claim =
                lockClaim(
                    claimId
                );

            SABCompanyAccessService.assertCompanyAccess(
                claim.Company__c
            );

            if (claim.Status__c != STATUS_SUBMITTED) {
                throw new ExpenseClaimLifecycleException(
                    'Only a Submitted Expense Claim can be approved.'
                );
            }

            Approval_Request__c approvalRequest =
                lockApprovalRequest(
                    claim
                );

            if (
                approvalRequest.Status__c
                    != APPROVAL_PENDING
            ) {
                throw new ExpenseClaimLifecycleException(
                    'Expense Claim Approval Request must be Pending before approval.'
                );
            }

            validateClaimHeader(
                claim
            );

            List<Expense_Claim_Line__c> lines =
                loadLines(
                    claim.Id,
                    true
                );

            Decimal total =
                validateLinesAndCalculateTotal(
                    claim,
                    lines,
                    true
                );

            if (
                claim.Total__c == null
                || SABMoneyService.normalizeTransactionAmount(
                    claim.Total__c,
                    RoundingMode.HALF_UP
                ) != total
            ) {
                throw new ExpenseClaimLifecycleException(
                    'Expense Claim Total no longer matches its submitted line snapshot. Return the claim to Draft and resubmit.'
                );
            }

            lifecycleMutationInProgress =
                true;

            try {
                approvalRequest.Status__c =
                    APPROVAL_APPROVED;
                approvalRequest.Completed_At__c =
                    System.now();
                update approvalRequest;

                claim.Status__c =
                    STATUS_APPROVED;
                update claim;
            } finally {
                lifecycleMutationInProgress =
                    false;
            }

            logAction(
                claim.Company__c,
                claim.Id,
                'EXPENSE_CLAIM_APPROVED',
                requestKey,
                String.isBlank(reason)
                    ? 'Expense Claim approved.'
                    : reason.trim()
            );

            return buildResult(
                claim.Id,
                false
            );
        } catch (Exception ex) {
            Database.rollback(
                sp
            );
            throw ex;
        }
    }

    @AuraEnabled
    public static LifecycleResult rejectClaim(
        Id claimId,
        String requestKey,
        String reason
    ) {
        SABPermissionService.assertPermission(
            'SAB_Review_Expense_Claim',
            'You do not have permission to review Expense Claims.'
        );

        validateRequestKey(
            requestKey
        );

        if (String.isBlank(reason)) {
            throw new ExpenseClaimLifecycleException(
                'Rejection reason is required.'
            );
        }

        LifecycleResult replay =
            findReviewReplay(
                claimId,
                requestKey,
                'EXPENSE_CLAIM_REJECTED',
                STATUS_REJECTED
            );

        if (replay != null) {
            return replay;
        }

        Savepoint sp =
            Database.setSavepoint();

        try {
            Expense_Claim__c claim =
                lockClaim(
                    claimId
                );

            SABCompanyAccessService.assertCompanyAccess(
                claim.Company__c
            );

            if (claim.Status__c != STATUS_SUBMITTED) {
                throw new ExpenseClaimLifecycleException(
                    'Only a Submitted Expense Claim can be rejected.'
                );
            }

            Approval_Request__c approvalRequest =
                lockApprovalRequest(
                    claim
                );

            if (
                approvalRequest.Status__c
                    != APPROVAL_PENDING
            ) {
                throw new ExpenseClaimLifecycleException(
                    'Expense Claim Approval Request must be Pending before rejection.'
                );
            }

            lifecycleMutationInProgress =
                true;

            try {
                approvalRequest.Status__c =
                    APPROVAL_REJECTED;
                approvalRequest.Completed_At__c =
                    System.now();
                update approvalRequest;

                claim.Status__c =
                    STATUS_REJECTED;
                update claim;
            } finally {
                lifecycleMutationInProgress =
                    false;
            }

            logAction(
                claim.Company__c,
                claim.Id,
                'EXPENSE_CLAIM_REJECTED',
                requestKey,
                reason.trim()
            );

            return buildResult(
                claim.Id,
                false
            );
        } catch (Exception ex) {
            Database.rollback(
                sp
            );
            throw ex;
        }
    }

    /**
     * G8B completion hook.
     *
     * This is the supported path for moving an Approved Expense Claim to
     * Posted after SABPostingService has successfully posted the subledger
     * journal and completed its Accounting Event.
     */
    public static LifecycleResult completePosting(
        Id claimId,
        Id accountingEventId,
        Id journalEntryId,
        String requestKey
    ) {
        SABPermissionService.assertPermission(
            'SAB_Post_Expense_Claim',
            'You do not have permission to post Expense Claims.'
        );

        validateRequestKey(
            requestKey
        );

        if (claimId == null) {
            throw new ExpenseClaimLifecycleException(
                'Expense Claim Id is required.'
            );
        }

        if (accountingEventId == null) {
            throw new ExpenseClaimLifecycleException(
                'Accounting Event Id is required to complete Expense Claim posting.'
            );
        }

        if (journalEntryId == null) {
            throw new ExpenseClaimLifecycleException(
                'Journal Entry Id is required to complete Expense Claim posting.'
            );
        }

        Expense_Claim__c claim = [
            SELECT Id,
                   Company__c,
                   Status__c,
                   Accounting_Event__c
            FROM Expense_Claim__c
            WHERE Id =
                    :claimId
            LIMIT 1
            FOR UPDATE
        ];

        SABCompanyAccessService.assertCompanyAccess(
            claim.Company__c
        );

        if (claim.Status__c == STATUS_POSTED) {
            if (claim.Accounting_Event__c != accountingEventId) {
                throw new ExpenseClaimLifecycleException(
                    'Posted Expense Claim is linked to a different Accounting Event.'
                );
            }

            return buildResult(
                claim.Id,
                true
            );
        }

        if (claim.Status__c != STATUS_APPROVED) {
            throw new ExpenseClaimLifecycleException(
                'Expense Claim must be Approved before posting can be completed.'
            );
        }

        Accounting_Event__c eventRecord = [
            SELECT Id,
                   Company__c,
                   Source_Type__c,
                   Source_Record_Id__c,
                   State__c,
                   Journal_Entry__c
            FROM Accounting_Event__c
            WHERE Id =
                    :accountingEventId
            LIMIT 1
        ];

        if (
            eventRecord.Company__c != claim.Company__c
            || eventRecord.Source_Type__c != SOURCE_TYPE
            || eventRecord.Source_Record_Id__c
                != String.valueOf(
                    claim.Id
                )
            || eventRecord.State__c != 'Posted'
            || eventRecord.Journal_Entry__c != journalEntryId
        ) {
            throw new ExpenseClaimLifecycleException(
                'Accounting Event does not represent this posted Expense Claim.'
            );
        }

        Journal_Entry__c journal = [
            SELECT Id,
                   Company__c,
                   Entry_Type__c,
                   Status__c,
                   Accounting_Event__c
            FROM Journal_Entry__c
            WHERE Id =
                    :journalEntryId
            LIMIT 1
        ];

        if (
            journal.Company__c != claim.Company__c
            || journal.Entry_Type__c != 'Subledger'
            || journal.Status__c != 'Posted'
            || journal.Accounting_Event__c != accountingEventId
        ) {
            throw new ExpenseClaimLifecycleException(
                'Journal Entry does not represent a completed Expense Claim subledger posting.'
            );
        }

        lifecycleMutationInProgress =
            true;

        try {
            claim.Accounting_Event__c =
                accountingEventId;
            claim.Status__c =
                STATUS_POSTED;
            update claim;
        } finally {
            lifecycleMutationInProgress =
                false;
        }

        logAction(
            claim.Company__c,
            claim.Id,
            'EXPENSE_CLAIM_POSTED',
            requestKey,
            'Expense Claim posted to employee reimbursement liability.'
        );

        return buildResult(
            claim.Id,
            false
        );
    }

    private static void validateClaimHeader(
        Expense_Claim__c claim
    ) {
        if (claim.Company__c == null) {
            throw new ExpenseClaimLifecycleException(
                'Accounting Company is required.'
            );
        }

        if (claim.Claimant_Employment__c == null) {
            throw new ExpenseClaimLifecycleException(
                'Claimant Employment is required.'
            );
        }

        if (claim.Claim_Date__c == null) {
            throw new ExpenseClaimLifecycleException(
                'Claim Date is required.'
            );
        }

        if (
            claim.Claimant_Employment__r == null
            || claim.Claimant_Employment__r.Company__c
                != claim.Company__c
        ) {
            throw new ExpenseClaimLifecycleException(
                'Claimant Employment must belong to the same Accounting Company as the Expense Claim.'
            );
        }

        Employment__c employment =
            claim.Claimant_Employment__r;

        if (
            employment.Employment_Status__c
                != 'Active'
        ) {
            throw new ExpenseClaimLifecycleException(
                'Claimant Employment must be Active when the Expense Claim is submitted.'
            );
        }

        if (
            employment.Start_Date__c != null
            && claim.Claim_Date__c
                < employment.Start_Date__c
        ) {
            throw new ExpenseClaimLifecycleException(
                'Claim Date cannot be before the claimant Employment start date.'
            );
        }

        if (
            employment.End_Date__c != null
            && claim.Claim_Date__c
                > employment.End_Date__c
        ) {
            throw new ExpenseClaimLifecycleException(
                'Claim Date cannot be after the claimant Employment end date.'
            );
        }

        if (
            employment.Employee__r == null
            || employment.Employee__r.Status__c
                != 'Active'
        ) {
            throw new ExpenseClaimLifecycleException(
                'Expense Claim requires an Active Employee.'
            );
        }

        String companyCurrency =
            SABMoneyService.normalizeCurrencyCode(
                claim.Company__r.Functional_Currency__c
            );

        String claimCurrency =
            SABMoneyService.normalizeCurrencyCode(
                claim.Currency__c
            );

        if (claim.Currency__c != claimCurrency) {
            throw new ExpenseClaimLifecycleException(
                'Expense Claim Currency must use a normalized 3-letter uppercase currency code.'
            );
        }

        if (claimCurrency != companyCurrency) {
            throw new ExpenseClaimLifecycleException(
                'G8A supports functional-currency Expense Claims only. Foreign-currency employee expenses are deferred to a later expense FX slice.'
            );
        }
    }

    private static Decimal validateLinesAndCalculateTotal(
        Expense_Claim__c claim,
        List<Expense_Claim_Line__c> lines,
        Boolean requirePostingAccount
    ) {
        if (lines.isEmpty()) {
            throw new ExpenseClaimLifecycleException(
                'Expense Claim must contain at least one Expense Claim Line.'
            );
        }

        Decimal total =
            ZERO;

        for (Expense_Claim_Line__c line : lines) {
            if (
                line.Amount__c == null
                || line.Amount__c <= ZERO
            ) {
                throw new ExpenseClaimLifecycleException(
                    'Every Expense Claim Line Amount must be greater than zero.'
                );
            }

            if (line.Expense_Date__c == null) {
                throw new ExpenseClaimLifecycleException(
                    'Every Expense Claim Line requires an Expense Date.'
                );
            }

            if (
                line.Expense_Date__c
                    > claim.Claim_Date__c
            ) {
                throw new ExpenseClaimLifecycleException(
                    'Expense Claim Line Expense Date cannot be after the Claim Date.'
                );
            }

            if (String.isBlank(line.Category__c)) {
                throw new ExpenseClaimLifecycleException(
                    'Every Expense Claim Line requires a Category.'
                );
            }

            if (String.isBlank(line.Description__c)) {
                throw new ExpenseClaimLifecycleException(
                    'Every Expense Claim Line requires a Description.'
                );
            }

            if (
                line.Expense_Account__c != null
            ) {
                if (
                    line.Expense_Account__r == null
                    || line.Expense_Account__r.Company__c
                        != claim.Company__c
                    || line.Expense_Account__r.Is_Active__c
                        != true
                    || line.Expense_Account__r.Is_Control_Account__c
                        == true
                    || line.Expense_Account__r.Account_Type__c
                        != 'Expense'
                ) {
                    throw new ExpenseClaimLifecycleException(
                        'Expense Claim Line Expense Account must be an active, non-control Expense account in the same Accounting Company.'
                    );
                }
            } else if (requirePostingAccount) {
                throw new ExpenseClaimLifecycleException(
                    'Every Expense Claim Line requires an Expense Account before approval.'
                );
            }

            total +=
                SABMoneyService.normalizeTransactionAmount(
                    line.Amount__c,
                    RoundingMode.HALF_UP
                );
        }

        return SABMoneyService.normalizeTransactionAmount(
            total,
            RoundingMode.HALF_UP
        );
    }

    private static Expense_Claim__c lockClaim(
        Id claimId
    ) {
        if (claimId == null) {
            throw new ExpenseClaimLifecycleException(
                'Expense Claim Id is required.'
            );
        }

        List<Expense_Claim__c> claims = [
            SELECT Id,
                   Name,
                   Company__c,
                   Company__r.Functional_Currency__c,
                   Claimant_Employment__c,
                   Claimant_Employment__r.Company__c,
                   Claimant_Employment__r.Employment_Status__c,
                   Claimant_Employment__r.Start_Date__c,
                   Claimant_Employment__r.End_Date__c,
                   Claimant_Employment__r.Employee__c,
                   Claimant_Employment__r.Employee__r.Status__c,
                   Claimant_Employment__r.Employee__r.User__c,
                   Claim_Date__c,
                   Accounting_Date__c,
                   Currency__c,
                   Status__c,
                   Total__c,
                   Approval_Request__c,
                   Accounting_Event__c
            FROM Expense_Claim__c
            WHERE Id =
                    :claimId
            LIMIT 1
            FOR UPDATE
        ];

        if (claims.isEmpty()) {
            throw new ExpenseClaimLifecycleException(
                'Expense Claim was not found or is not accessible.'
            );
        }

        return claims[0];
    }

    private static List<Expense_Claim_Line__c> loadLines(
        Id claimId,
        Boolean lockRows
    ) {
        if (lockRows) {
            return [
                SELECT Id,
                       Expense_Claim__c,
                       Expense_Date__c,
                       Category__c,
                       Description__c,
                       Amount__c,
                       Expense_Account__c,
                       Expense_Account__r.Company__c,
                       Expense_Account__r.Is_Active__c,
                       Expense_Account__r.Is_Control_Account__c,
                       Expense_Account__r.Account_Type__c,
                       Tax_Code__c,
                       Department__c,
                       Project__c
                FROM Expense_Claim_Line__c
                WHERE Expense_Claim__c =
                        :claimId
                FOR UPDATE
            ];
        }

        return [
            SELECT Id,
                   Expense_Claim__c,
                   Expense_Date__c,
                   Category__c,
                   Description__c,
                   Amount__c,
                   Expense_Account__c,
                   Expense_Account__r.Company__c,
                   Expense_Account__r.Is_Active__c,
                   Expense_Account__r.Is_Control_Account__c,
                   Expense_Account__r.Account_Type__c,
                   Tax_Code__c,
                   Department__c,
                   Project__c
            FROM Expense_Claim_Line__c
            WHERE Expense_Claim__c =
                    :claimId
        ];
    }

    private static Approval_Request__c lockApprovalRequest(
        Expense_Claim__c claim
    ) {
        if (claim.Approval_Request__c == null) {
            throw new ExpenseClaimLifecycleException(
                'Submitted Expense Claim is missing its Approval Request.'
            );
        }

        List<Approval_Request__c> requests = [
            SELECT Id,
                   Company__c,
                   Policy_Version__c,
                   Request_Key__c,
                   Requested_At__c,
                   Requested_By__c,
                   Source_Business_Key__c,
                   Source_Record_Id__c,
                   Source_Type__c,
                   Source_Version__c,
                   Status__c,
                   Completed_At__c
            FROM Approval_Request__c
            WHERE Id =
                    :claim.Approval_Request__c
            LIMIT 1
            FOR UPDATE
        ];

        if (requests.isEmpty()) {
            throw new ExpenseClaimLifecycleException(
                'Expense Claim Approval Request was not found.'
            );
        }

        Approval_Request__c request =
            requests[0];

        if (
            request.Company__c
                != claim.Company__c
            || request.Source_Type__c
                != SOURCE_TYPE
            || request.Source_Record_Id__c
                != String.valueOf(
                    claim.Id
                )
            || request.Source_Version__c
                != 1
        ) {
            throw new ExpenseClaimLifecycleException(
                'Expense Claim Approval Request identity is inconsistent.'
            );
        }

        return request;
    }

    private static LifecycleResult findSubmitReplay(
        Id claimId,
        String requestKey
    ) {
        if (claimId == null) {
            return null;
        }

        List<Approval_Request__c> requests = [
            SELECT Id,
                   Company__c,
                   Source_Record_Id__c,
                   Source_Type__c,
                   Status__c
            FROM Approval_Request__c
            WHERE Request_Key__c =
                    :requestKey.trim()
            LIMIT 1
        ];

        if (requests.isEmpty()) {
            return null;
        }

        Approval_Request__c request =
            requests[0];

        if (
            request.Source_Type__c
                != SOURCE_TYPE
            || request.Source_Record_Id__c
                != String.valueOf(
                    claimId
                )
        ) {
            throw new ExpenseClaimLifecycleException(
                'Request Key was already used for a different approval request.'
            );
        }

        LifecycleResult result =
            buildResult(
                claimId,
                true
            );

        if (
            result.status
                != STATUS_SUBMITTED
            && result.status
                != STATUS_APPROVED
            && result.status
                != STATUS_REJECTED
        ) {
            throw new ExpenseClaimLifecycleException(
                'Expense Claim submit replay found an inconsistent lifecycle state.'
            );
        }

        return result;
    }

    private static LifecycleResult findReviewReplay(
        Id claimId,
        String requestKey,
        String expectedAction,
        String expectedStatus
    ) {
        if (claimId == null) {
            return null;
        }

        List<Business_Action__c> actions = [
            SELECT Id,
                   Action__c,
                   Source_Type__c,
                   Source_Record_Id__c
            FROM Business_Action__c
            WHERE Request_Key__c =
                    :requestKey.trim()
            LIMIT 1
        ];

        if (actions.isEmpty()) {
            return null;
        }

        Business_Action__c action =
            actions[0];

        if (
            action.Action__c
                != expectedAction
            || action.Source_Type__c
                != SOURCE_TYPE
            || action.Source_Record_Id__c
                != String.valueOf(
                    claimId
                )
        ) {
            throw new ExpenseClaimLifecycleException(
                'Request Key was already used for a different financial action.'
            );
        }

        LifecycleResult result =
            buildResult(
                claimId,
                true
            );

        if (result.status != expectedStatus) {
            throw new ExpenseClaimLifecycleException(
                'Expense Claim review replay found an inconsistent lifecycle state.'
            );
        }

        return result;
    }

    private static LifecycleResult buildResult(
        Id claimId,
        Boolean replay
    ) {
        Expense_Claim__c claim = [
            SELECT Id,
                   Status__c,
                   Total__c,
                   Approval_Request__c,
                   Approval_Request__r.Status__c
            FROM Expense_Claim__c
            WHERE Id =
                    :claimId
            LIMIT 1
        ];

        LifecycleResult result =
            new LifecycleResult();

        result.claimId =
            claim.Id;
        result.status =
            claim.Status__c;
        result.total =
            claim.Total__c;
        result.approvalRequestId =
            claim.Approval_Request__c;
        result.approvalStatus =
            claim.Approval_Request__r == null
                ? null
                : claim.Approval_Request__r.Status__c;
        result.replay =
            replay;

        return result;
    }

    private static void logAction(
        Id companyId,
        Id claimId,
        String actionName,
        String requestKey,
        String reason
    ) {
        insert new Business_Action__c(
            Company__c =
                companyId,
            Action__c =
                actionName,
            Actor__c =
                UserInfo.getUserId(),
            Action_At__c =
                System.now(),
            Reason__c =
                reason,
            Request_Key__c =
                requestKey,
            Source_Type__c =
                SOURCE_TYPE,
            Source_Record_Id__c =
                String.valueOf(
                    claimId
                ),
            Source_Version__c =
                1
        );
    }

    private static void validateRequestKey(
        String requestKey
    ) {
        if (String.isBlank(requestKey)) {
            throw new ExpenseClaimLifecycleException(
                'Request Key is required.'
            );
        }

        Integer maxLength =
            Approval_Request__c.Request_Key__c.getDescribe().getLength();

        Integer businessActionMaxLength =
            Business_Action__c.Request_Key__c.getDescribe().getLength();

        if (businessActionMaxLength < maxLength) {
            maxLength =
                businessActionMaxLength;
        }

        if (
            requestKey.trim().length()
                > maxLength
        ) {
            throw new ExpenseClaimLifecycleException(
                'Request Key cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static String digest(
        String value
    ) {
        return EncodingUtil.convertToHex(
            Crypto.generateDigest(
                'SHA-256',
                Blob.valueOf(
                    value == null
                        ? ''
                        : value
                )
            )
        );
    }
}
