/**
 * G8A direct-DML lifecycle protection for Expense Claims and Claim Lines.
 */
public without sharing class SABExpenseClaimLifecycleGuard {

    private static Boolean isTrustedMutation() {
        return (
            SABExpenseClaimLifecycleService.isLifecycleMutationInProgress()
            || SABExpenseClaimPostingService.isSnapshotMutationInProgress()
        );
    }

    public static void beforeClaimInsert(
        List<Expense_Claim__c> newRows
    ) {
        if (isTrustedMutation()) {
            return;
        }

        for (Expense_Claim__c row : newRows) {
            if (String.isBlank(row.Status__c)) {
                row.Status__c =
                    'Draft';
            }

            if (row.Status__c != 'Draft') {
                row.Status__c.addError(
                    'Expense Claims must be created in Draft status. Submit and review through the Expense Claim lifecycle actions.'
                );
            }

            if (
                row.Approval_Request__c != null
                || row.Accounting_Event__c != null
            ) {
                row.addError(
                    'Expense Claim approval and accounting references are system-managed.'
                );
            }

            if (
                row.Total__c != null
                && row.Total__c != 0
            ) {
                row.Total__c.addError(
                    'Expense Claim Total is system-managed from Expense Claim Lines.'
                );
            }
        }
    }

    public static void beforeClaimUpdate(
        List<Expense_Claim__c> newRows,
        Map<Id, Expense_Claim__c> oldMap
    ) {
        if (isTrustedMutation()) {
            return;
        }

        for (Expense_Claim__c current : newRows) {
            Expense_Claim__c prior =
                oldMap.get(
                    current.Id
                );

            if (current.Status__c != prior.Status__c) {
                current.Status__c.addError(
                    'Expense Claim Status is lifecycle-managed. Use the Submit, Approve or Reject actions.'
                );
            }

            if (
                current.Total__c != prior.Total__c
                || current.Approval_Request__c
                    != prior.Approval_Request__c
                || current.Accounting_Event__c
                    != prior.Accounting_Event__c
            ) {
                current.addError(
                    'Expense Claim total, approval and accounting references are system-managed.'
                );
                continue;
            }

            if (
                prior.Status__c != 'Draft'
                && (
                    current.Company__c
                        != prior.Company__c
                    || current.Claimant_Employment__c
                        != prior.Claimant_Employment__c
                    || current.Claim_Date__c
                        != prior.Claim_Date__c
                    || current.Accounting_Date__c
                        != prior.Accounting_Date__c
                    || current.Currency__c
                        != prior.Currency__c
                )
            ) {
                current.addError(
                    'Submitted Expense Claim financial header fields are locked.'
                );
            }
        }
    }

    public static void beforeClaimDelete(
        List<Expense_Claim__c> oldRows
    ) {
        if (isTrustedMutation()) {
            return;
        }

        for (Expense_Claim__c row : oldRows) {
            if (row.Status__c != 'Draft') {
                row.addError(
                    'Only Draft Expense Claims may be deleted.'
                );
            }
        }
    }

    public static void beforeLineInsert(
        List<Expense_Claim_Line__c> newRows
    ) {
        if (isTrustedMutation()) {
            return;
        }

        for (Expense_Claim_Line__c row : newRows) {
            assertNoDirectTaxSnapshot(
                row
            );
        }

        validateLineParents(
            newRows
        );
    }

    public static void beforeLineUpdate(
        List<Expense_Claim_Line__c> newRows,
        Map<Id, Expense_Claim_Line__c> oldMap
    ) {
        if (isTrustedMutation()) {
            return;
        }

        Set<Id> parentIds =
            new Set<Id>();

        for (Expense_Claim_Line__c row : newRows) {
            parentIds.add(
                row.Expense_Claim__c
            );

            Expense_Claim_Line__c prior =
                oldMap.get(
                    row.Id
                );

            if (taxSnapshotChanged(row, prior)) {
                row.addError(
                    'Expense Claim tax snapshot fields are system-managed by the posting service.'
                );
            }

            if (
                row.Expense_Claim__c
                    != prior.Expense_Claim__c
            ) {
                parentIds.add(
                    prior.Expense_Claim__c
                );
            }
        }

        Map<Id, Expense_Claim__c> claims =
            loadClaims(
                parentIds
            );

        for (Expense_Claim_Line__c row : newRows) {
            Expense_Claim_Line__c prior =
                oldMap.get(
                    row.Id
                );

            assertDraft(
                claims.get(
                    prior.Expense_Claim__c
                ),
                row
            );

            assertDraft(
                claims.get(
                    row.Expense_Claim__c
                ),
                row
            );
        }
    }

    public static void beforeLineDelete(
        List<Expense_Claim_Line__c> oldRows
    ) {
        if (isTrustedMutation()) {
            return;
        }

        Set<Id> parentIds =
            new Set<Id>();

        for (Expense_Claim_Line__c row : oldRows) {
            parentIds.add(
                row.Expense_Claim__c
            );
        }

        Map<Id, Expense_Claim__c> claims =
            loadClaims(
                parentIds
            );

        for (Expense_Claim_Line__c row : oldRows) {
            assertDraft(
                claims.get(
                    row.Expense_Claim__c
                ),
                row
            );
        }
    }

    private static void assertNoDirectTaxSnapshot(
        Expense_Claim_Line__c row
    ) {
        if (
            row.Tax_Rate__c != null
            || row.Tax_Rate_Percent__c != null
            || row.Taxable_Base__c != null
            || row.Tax_Amount__c != null
            || row.Recoverable_Tax_Amount__c != null
            || row.Nonrecoverable_Tax_Amount__c != null
            || !String.isBlank(row.Tax_Code_Key__c)
            || !String.isBlank(row.Tax_Jurisdiction__c)
            || !String.isBlank(row.Tax_Treatment__c)
            || !String.isBlank(row.Tax_Country_Pack_Version__c)
        ) {
            row.addError(
                'Expense Claim tax snapshot fields are system-managed by the posting service.'
            );
        }
    }

    private static Boolean taxSnapshotChanged(
        Expense_Claim_Line__c current,
        Expense_Claim_Line__c prior
    ) {
        return (
            current.Tax_Rate__c
                != prior.Tax_Rate__c
            || current.Tax_Rate_Percent__c
                != prior.Tax_Rate_Percent__c
            || current.Taxable_Base__c
                != prior.Taxable_Base__c
            || current.Tax_Amount__c
                != prior.Tax_Amount__c
            || current.Recoverable_Tax_Amount__c
                != prior.Recoverable_Tax_Amount__c
            || current.Nonrecoverable_Tax_Amount__c
                != prior.Nonrecoverable_Tax_Amount__c
            || current.Tax_Code_Key__c
                != prior.Tax_Code_Key__c
            || current.Tax_Jurisdiction__c
                != prior.Tax_Jurisdiction__c
            || current.Tax_Treatment__c
                != prior.Tax_Treatment__c
            || current.Tax_Country_Pack_Version__c
                != prior.Tax_Country_Pack_Version__c
        );
    }

    private static void validateLineParents(
        List<Expense_Claim_Line__c> rows
    ) {
        Set<Id> parentIds =
            new Set<Id>();

        for (Expense_Claim_Line__c row : rows) {
            if (row.Expense_Claim__c != null) {
                parentIds.add(
                    row.Expense_Claim__c
                );
            }
        }

        Map<Id, Expense_Claim__c> claims =
            loadClaims(
                parentIds
            );

        for (Expense_Claim_Line__c row : rows) {
            assertDraft(
                claims.get(
                    row.Expense_Claim__c
                ),
                row
            );
        }
    }

    private static Map<Id, Expense_Claim__c> loadClaims(
        Set<Id> parentIds
    ) {
        if (parentIds.isEmpty()) {
            return new Map<Id, Expense_Claim__c>();
        }

        return new Map<Id, Expense_Claim__c>([
            SELECT Id,
                   Status__c
            FROM Expense_Claim__c
            WHERE Id IN :parentIds
        ]);
    }

    private static void assertDraft(
        Expense_Claim__c claim,
        SObject row
    ) {
        if (claim == null) {
            row.addError(
                'Expense Claim parent is required.'
            );
            return;
        }

        if (claim.Status__c != 'Draft') {
            row.addError(
                'Expense Claim Lines are locked after the claim leaves Draft status.'
            );
        }
    }
}
