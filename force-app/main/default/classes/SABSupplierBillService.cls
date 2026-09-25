/**
 * G3A - Supplier Bill Validation & Lifecycle.
 *
 * Responsibilities:
 * - company authorization + CRUD/FLS enforcement
 * - supplier/profile/AP-control-account validation
 * - accounting-date/open-period validation
 * - currency snapshot validation
 * - supplier bill line validation
 * - duplicate vendor-reference protection
 * - server-calculated Subtotal / Tax Total / Total
 * - controlled Draft -> Submitted -> Approved lifecycle
 * - controlled Submitted -> Draft return
 * - controlled cancellation before posting
 * - immutable header/lines outside Draft
 * - Business_Action__c audit for lifecycle transitions
 *
 * G3A intentionally DOES NOT post journals.
 * G3B will own Supplier Bill -> AP posting.
 */
public with sharing class SABSupplierBillService {

    public class SupplierBillException extends Exception {}

    private static final String STATUS_DRAFT = 'Draft';
    private static final String STATUS_SUBMITTED = 'Submitted';
    private static final String STATUS_APPROVED = 'Approved';
    private static final String STATUS_POSTED = 'Posted';
    private static final String STATUS_CANCELLED = 'Cancelled';

    private static final String DOCUMENT_BILL = 'Bill';
    private static final String DOCUMENT_CREDIT = 'Supplier Credit';

    private static final String APPROVE_PERMISSION =
        'SAB_Approve_Financial_Document';

    private static final Decimal ZERO = Decimal.valueOf('0');

    @TestVisible
    private static Boolean lifecycleMutationInProgress = false;

    public class ValidationResult {
        @AuraEnabled public Boolean isValid { get; private set; }
        @AuraEnabled public List<String> errors { get; private set; }
        @AuraEnabled public Decimal calculatedSubtotal { get; private set; }
        @AuraEnabled public Decimal calculatedTaxTotal { get; private set; }
        @AuraEnabled public Decimal calculatedTotal { get; private set; }

        private ValidationResult() {
            isValid = true;
            errors = new List<String>();
            calculatedSubtotal = ZERO;
            calculatedTaxTotal = ZERO;
            calculatedTotal = ZERO;
        }

        private void addError(String message) {
            isValid = false;
            errors.add(message);
        }
    }

    public class TransitionResult {
        @AuraEnabled public Id billId { get; private set; }
        @AuraEnabled public String previousStatus { get; private set; }
        @AuraEnabled public String newStatus { get; private set; }
        @AuraEnabled public Id businessActionId { get; private set; }
        @AuraEnabled public Boolean idempotentReplay { get; private set; }
    }

    private class BillContext {
        Supplier_Bill__c bill;
        List<Bill_Line__c> lines;
    }

    /**
     * Read-only validation that can be used by UI before Submit.
     */
    @AuraEnabled
    public static ValidationResult validateForSubmission(Id billId) {
        BillContext context = loadContext(
            billId,
            false
        );

        assertCanReadBill(context.bill);

        return validateContext(
            context,
            false
        );
    }

    /**
     * Stronger validation used before approval and by G3B before posting.
     * Requires supplier AP control-account configuration.
     */
    @AuraEnabled
    public static ValidationResult validateForPostingReadiness(Id billId) {
        BillContext context = loadContext(
            billId,
            false
        );

        assertCanReadBill(context.bill);

        return validateContext(
            context,
            true
        );
    }

    @AuraEnabled
    public static TransitionResult submit(
        Id billId,
        String requestKey
    ) {
        return transition(
            billId,
            STATUS_DRAFT,
            STATUS_SUBMITTED,
            requestKey,
            null,
            false,
            false
        );
    }

    /**
     * Return a Submitted bill to Draft so material data can be corrected.
     * An Approved bill is not reopened by G3A; cancel/replacement is required.
     */
    @AuraEnabled
    public static TransitionResult returnToDraft(
        Id billId,
        String requestKey,
        String reason
    ) {
        requireReason(
            reason,
            'A reason is required when returning a Supplier Bill to Draft.'
        );

        return transition(
            billId,
            STATUS_SUBMITTED,
            STATUS_DRAFT,
            requestKey,
            reason,
            false,
            false
        );
    }

    @AuraEnabled
    public static TransitionResult approve(
        Id billId,
        String requestKey,
        String reason
    ) {
        SABPermissionService.assertPermission(
            APPROVE_PERMISSION,
            'You do not have permission to approve financial documents.'
        );

        return transition(
            billId,
            STATUS_SUBMITTED,
            STATUS_APPROVED,
            requestKey,
            reason,
            true,
            false
        );
    }

    /**
     * Cancel a bill before posting.
     * Cancelling an Approved bill requires the financial-document approval
     * permission because it invalidates an approved financial document.
     */
    @AuraEnabled
    public static TransitionResult cancel(
        Id billId,
        String requestKey,
        String reason
    ) {
        requireReason(
            reason,
            'A reason is required when cancelling a Supplier Bill.'
        );

        Supplier_Bill__c currentBill = [
            SELECT Id, Status__c
            FROM Supplier_Bill__c
            WHERE Id = :billId
            LIMIT 1
        ];

        if (currentBill.Status__c == STATUS_APPROVED) {
            SABPermissionService.assertPermission(
                APPROVE_PERMISSION,
                'You do not have permission to cancel an approved financial document.'
            );
        }

        if (
            currentBill.Status__c == STATUS_POSTED
            || currentBill.Status__c == STATUS_CANCELLED
        ) {
            throw new SupplierBillException(
                'Only Draft, Submitted or Approved Supplier Bills can be cancelled.'
            );
        }

        return transition(
            billId,
            null,
            STATUS_CANCELLED,
            requestKey,
            reason,
            false,
            true
        );
    }

    /**
     * G3B should call this before creating the AP accounting event/journal.
     * This method does not change the Supplier Bill.
     */
    public static void assertApprovedForPosting(Id billId) {
        BillContext context = loadContext(
            billId,
            true
        );

        assertCanEditBill(context.bill);

        if (context.bill.Status__c != STATUS_APPROVED) {
            throw new SupplierBillException(
                'Supplier Bill must be Approved before posting.'
            );
        }

        ValidationResult validation =
            validateContext(
                context,
                true
            );

        throwIfInvalid(validation);
    }

    /**
     * G3B completion hook.
     *
     * This is the only supported way for the Supplier Bill posting service to
     * transition an Approved bill to Posted and attach Accounting_Event__c.
     * It independently verifies the posted Accounting Event and Journal before
     * allowing the lifecycle mutation.
     */
    public static TransitionResult completePosting(
        Id billId,
        Id accountingEventId,
        Id journalEntryId,
        String requestKey
    ) {
        requireRequestKey(requestKey);

        SABPermissionService.assertPermission(
            'SAB_Post_Journal',
            'You do not have permission to post accounting transactions.'
        );

        if (accountingEventId == null) {
            throw new SupplierBillException(
                'Accounting Event Id is required to complete Supplier Bill posting.'
            );
        }

        if (journalEntryId == null) {
            throw new SupplierBillException(
                'Journal Entry Id is required to complete Supplier Bill posting.'
            );
        }

        Supplier_Bill__c bill = [
            SELECT Id, Company__c, Status__c, Accounting_Event__c
            FROM Supplier_Bill__c
            WHERE Id = :billId
            LIMIT 1
            FOR UPDATE
        ];

        if (bill.Status__c == STATUS_POSTED) {
            assertCanReadBill(bill);
            if (bill.Accounting_Event__c != accountingEventId) {
                throw new SupplierBillException(
                    'Posted Supplier Bill is linked to a different Accounting Event.'
                );
            }

            Business_Action__c priorAction =
                findPriorAction(requestKey);

            TransitionResult replay =
                new TransitionResult();

            replay.billId = bill.Id;
            replay.previousStatus = null;
            replay.newStatus = STATUS_POSTED;
            replay.businessActionId =
                priorAction == null
                    ? null
                    : priorAction.Id;
            replay.idempotentReplay = true;

            return replay;
        }

        assertCanEditBill(bill);

        if (bill.Status__c != STATUS_APPROVED) {
            throw new SupplierBillException(
                'Supplier Bill must be Approved before posting can be completed.'
            );
        }

        Accounting_Event__c eventRecord = [
            SELECT Id, Company__c, Source_Type__c,
                   Source_Record_Id__c, State__c,
                   Journal_Entry__c
            FROM Accounting_Event__c
            WHERE Id = :accountingEventId
            LIMIT 1
        ];

        if (
            eventRecord.Company__c != bill.Company__c
            || eventRecord.Source_Type__c != 'Supplier_Bill__c'
            || eventRecord.Source_Record_Id__c != String.valueOf(bill.Id)
            || eventRecord.State__c != 'Posted'
            || eventRecord.Journal_Entry__c != journalEntryId
        ) {
            throw new SupplierBillException(
                'Accounting Event does not represent this posted Supplier Bill.'
            );
        }

        Journal_Entry__c journal = [
            SELECT Id, Company__c, Entry_Type__c,
                   Status__c, Accounting_Event__c
            FROM Journal_Entry__c
            WHERE Id = :journalEntryId
            LIMIT 1
        ];

        if (
            journal.Company__c != bill.Company__c
            || journal.Entry_Type__c != 'Subledger'
            || journal.Status__c != 'Posted'
            || journal.Accounting_Event__c != accountingEventId
        ) {
            throw new SupplierBillException(
                'Journal Entry does not represent a completed Supplier Bill subledger posting.'
            );
        }

        bill.Accounting_Event__c = accountingEventId;
        bill.Status__c = STATUS_POSTED;

        lifecycleMutationInProgress = true;

        try {
            update bill;
        } finally {
            lifecycleMutationInProgress = false;
        }

        Business_Action__c action =
            createBusinessAction(
                bill,
                STATUS_APPROVED,
                STATUS_POSTED,
                requestKey,
                'Supplier Bill posted to Accounts Payable.'
            );

        TransitionResult result =
            new TransitionResult();

        result.billId = bill.Id;
        result.previousStatus = STATUS_APPROVED;
        result.newStatus = STATUS_POSTED;
        result.businessActionId = action.Id;
        result.idempotentReplay = false;

        return result;
    }

    /**
     * Trigger guard: every newly-created Supplier Bill starts as Draft and
     * has no accounting event. Posting linkage belongs to G3B.
     */
    public static void guardBeforeSupplierBillInsert(
        List<Supplier_Bill__c> newRecords
    ) {
        if (newRecords == null) {
            return;
        }

        for (Supplier_Bill__c newRecord : newRecords) {
            if (newRecord.Status__c != STATUS_DRAFT) {
                newRecord.addError(
                    'New Supplier Bills must start in Draft status.'
                );
            }

            if (newRecord.Accounting_Event__c != null) {
                newRecord.addError(
                    'Accounting Event cannot be assigned when a Supplier Bill is created.'
                );
            }
        }
    }

    /**
     * Draft deletion is allowed. Once submitted, the business document is
     * retained and lifecycle actions must be used instead.
     */
    public static void guardBeforeSupplierBillDelete(
        List<Supplier_Bill__c> oldRecords
    ) {
        if (oldRecords == null) {
            return;
        }

        for (Supplier_Bill__c oldRecord : oldRecords) {
            if (oldRecord.Status__c != STATUS_DRAFT) {
                oldRecord.addError(
                    'Only Draft Supplier Bills can be deleted.'
                );
            }
        }
    }

    /**
     * Trigger guard: status cannot be changed by direct DML.
     * Header accounting data is immutable outside Draft.
     * Accounting_Event__c is reserved for the G3B posting service.
     */
    public static void guardBeforeSupplierBillUpdate(
        Map<Id, Supplier_Bill__c> oldMap,
        List<Supplier_Bill__c> newRecords
    ) {
        if (
            oldMap == null
            || newRecords == null
        ) {
            return;
        }

        for (Supplier_Bill__c newRecord : newRecords) {
            Supplier_Bill__c oldRecord =
                oldMap.get(newRecord.Id);

            if (oldRecord == null) {
                continue;
            }

            if (
                oldRecord.Status__c != newRecord.Status__c
                && !lifecycleMutationInProgress
            ) {
                newRecord.addError(
                    'Supplier Bill status must be changed through the controlled lifecycle service.'
                );
                continue;
            }

            if (
                oldRecord.Accounting_Event__c
                != newRecord.Accounting_Event__c
                && !lifecycleMutationInProgress
            ) {
                newRecord.addError(
                    'Accounting Event is system-managed and can only be assigned by the Supplier Bill posting service.'
                );
                continue;
            }

            if (
                oldRecord.Status__c == STATUS_POSTED
                || oldRecord.Status__c == STATUS_CANCELLED
            ) {
                if (hasMaterialHeaderChange(oldRecord, newRecord)) {
                    newRecord.addError(
                        'Posted or Cancelled Supplier Bills are immutable.'
                    );
                }

                continue;
            }

            if (
                oldRecord.Status__c != STATUS_DRAFT
                && hasMaterialHeaderChange(
                    oldRecord,
                    newRecord
                )
            ) {
                newRecord.addError(
                    'Supplier Bill financial fields are locked outside Draft. Return a Submitted bill to Draft before editing.'
                );
            }
        }
    }

    public static void guardBillLinesBeforeInsert(
        List<Bill_Line__c> newRecords
    ) {
        guardBillLineParents(
            newRecords,
            null,
            'added'
        );
    }

    public static void guardBillLinesBeforeUpdate(
        List<Bill_Line__c> newRecords,
        Map<Id, Bill_Line__c> oldMap
    ) {
        guardBillLineParents(
            newRecords,
            oldMap,
            'changed'
        );
    }

    public static void guardBillLinesBeforeDelete(
        List<Bill_Line__c> oldRecords
    ) {
        guardBillLineParents(
            oldRecords,
            null,
            'deleted'
        );
    }

    private static TransitionResult transition(
        Id billId,
        String requiredOldStatus,
        String newStatus,
        String requestKey,
        String reason,
        Boolean postingReadyValidation,
        Boolean allowMultipleSourceStatuses
    ) {
        requireRequestKey(requestKey);

        Business_Action__c priorAction =
            findPriorAction(
                requestKey
            );

        if (priorAction != null) {
            return replayTransition(
                billId,
                newStatus,
                priorAction
            );
        }

        BillContext context =
            loadContext(
                billId,
                true
            );

        assertCanEditBill(context.bill);

        if (
            !allowMultipleSourceStatuses
            && context.bill.Status__c != requiredOldStatus
        ) {
            throw new SupplierBillException(
                'Supplier Bill must be '
                + requiredOldStatus
                + ' before it can move to '
                + newStatus
                + '. Current status: '
                + context.bill.Status__c
                + '.'
            );
        }

        if (
            allowMultipleSourceStatuses
            && (
                context.bill.Status__c != STATUS_DRAFT
                && context.bill.Status__c != STATUS_SUBMITTED
                && context.bill.Status__c != STATUS_APPROVED
            )
        ) {
            throw new SupplierBillException(
                'Supplier Bill cannot be cancelled from status '
                + context.bill.Status__c
                + '.'
            );
        }

        ValidationResult validation =
            new ValidationResult();

        if (newStatus == STATUS_SUBMITTED) {
            validation =
                validateContext(
                    context,
                    false
                );
        } else if (newStatus == STATUS_APPROVED) {
            validation =
                validateContext(
                    context,
                    postingReadyValidation
                );
        }

        throwIfInvalid(validation);

        String previousStatus =
            context.bill.Status__c;

        if (
            newStatus == STATUS_SUBMITTED
            || newStatus == STATUS_APPROVED
        ) {
            applyCalculatedHeaderValues(
                context,
                validation
            );
        }

        context.bill.Status__c =
            newStatus;

        lifecycleMutationInProgress =
            true;

        try {
            update context.bill;
        } finally {
            lifecycleMutationInProgress =
                false;
        }

        Business_Action__c action =
            createBusinessAction(
                context.bill,
                previousStatus,
                newStatus,
                requestKey,
                reason
            );

        TransitionResult result =
            new TransitionResult();

        result.billId =
            context.bill.Id;
        result.previousStatus =
            previousStatus;
        result.newStatus =
            newStatus;
        result.businessActionId =
            action.Id;
        result.idempotentReplay =
            false;

        return result;
    }

    private static TransitionResult replayTransition(
        Id billId,
        String expectedNewStatus,
        Business_Action__c priorAction
    ) {
        String expectedSourceId =
            String.valueOf(billId);

        if (
            priorAction.Source_Type__c != 'Supplier_Bill__c'
            || priorAction.Source_Record_Id__c != expectedSourceId
            || priorAction.Action__c != lifecycleAction(expectedNewStatus)
        ) {
            throw new SupplierBillException(
                'The request key has already been used for a different financial action.'
            );
        }

        Supplier_Bill__c bill = [
            SELECT Id, Status__c
            FROM Supplier_Bill__c
            WHERE Id = :billId
            LIMIT 1
        ];

        if (bill.Status__c != expectedNewStatus) {
            throw new SupplierBillException(
                'The request key was already processed, but the Supplier Bill is no longer in the expected status.'
            );
        }

        TransitionResult result =
            new TransitionResult();

        result.billId =
            bill.Id;
        result.previousStatus =
            null;
        result.newStatus =
            bill.Status__c;
        result.businessActionId =
            priorAction.Id;
        result.idempotentReplay =
            true;

        return result;
    }

    private static BillContext loadContext(
        Id billId,
        Boolean lockBill
    ) {
        if (billId == null) {
            throw new SupplierBillException(
                'Supplier Bill Id is required.'
            );
        }

        String billQuery =
            'SELECT Id, Name, Company__c, '
            + 'Company__r.Functional_Currency__c, '
            + 'Company__r.Is_Active__c, '
            + 'Supplier_Profile__c, '
            + 'Supplier_Profile__r.Company__c, '
            + 'Supplier_Profile__r.Is_Active__c, '
            + 'Supplier_Profile__r.Is_Supplier__c, '
            + 'Supplier_Profile__r.AP_Control_Account__c, '
            + 'Supplier_Profile__r.AP_Control_Account__r.Company__c, '
            + 'Supplier_Profile__r.AP_Control_Account__r.Account_Type__c, '
            + 'Supplier_Profile__r.AP_Control_Account__r.Is_Active__c, '
            + 'Supplier_Profile__r.AP_Control_Account__r.Is_Control_Account__c, '
            + 'Supplier_Profile__r.AP_Control_Account__r.Control_Type__c, '
            + 'Document_Type__c, Document_Date__c, Accounting_Date__c, '
            + 'Due_Date__c, Vendor_Reference__c, '
            + 'Transaction_Currency__c, Functional_Currency__c, '
            + 'Exchange_Rate__c, Status__c, '
            + 'Subtotal__c, Tax_Total__c, Total__c, '
            + 'Duplicate_Exception__c, Duplicate_Exception_Reason__c, '
            + 'Accounting_Event__c '
            + 'FROM Supplier_Bill__c '
            + 'WHERE Id = \'' + String.escapeSingleQuotes(String.valueOf(billId)) + '\' '
            + 'LIMIT 1';

        if (lockBill) {
            billQuery += ' FOR UPDATE';
        }

        List<Supplier_Bill__c> bills =
            Database.query(
                billQuery
            );

        if (bills.isEmpty()) {
            throw new SupplierBillException(
                'Supplier Bill was not found or is not accessible.'
            );
        }

        BillContext context =
            new BillContext();

        context.bill =
            bills[0];

        context.lines = [
            SELECT Id, Supplier_Bill__c,
                   Line_Number__c, Description__c,
                   Quantity__c, Unit_Price__c, Net_Amount__c,
                   Recoverable_Tax_Amount__c,
                   Nonrecoverable_Tax_Amount__c,
                   Expense_or_Asset_Account__c,
                   Expense_or_Asset_Account__r.Company__c,
                   Expense_or_Asset_Account__r.Account_Type__c,
                   Expense_or_Asset_Account__r.Is_Active__c,
                   Expense_or_Asset_Account__r.Is_Control_Account__c,
                   Department__c,
                   Department__r.Company__c,
                   Department__r.Is_Active__c,
                   Department__r.Active_From__c,
                   Department__r.Active_To__c,
                   Cost_Center__c,
                   Cost_Center__r.Company__c,
                   Cost_Center__r.Is_Active__c,
                   Cost_Center__r.Active_From__c,
                   Cost_Center__r.Active_To__c,
                   Project__c,
                   Project__r.Company__c,
                   Project__r.Status__c,
                   Project__r.Start_Date__c,
                   Project__r.End_Date__c,
                   Tax_Code__c,
                   Tax_Code__r.Company__c,
                   Tax_Code__r.Is_Active__c,
                   Purchase_Order_Line__c,
                   Purchase_Order_Line__r.Purchase_Order__r.Company__c,
                   Goods_Receipt_Line__c,
                   Goods_Receipt_Line__r.Goods_Receipt__r.Company__c
            FROM Bill_Line__c
            WHERE Supplier_Bill__c =
                :billId
            ORDER BY Line_Number__c ASC, Id ASC
        ];

        return context;
    }

    private static ValidationResult validateContext(
        BillContext context,
        Boolean requirePostingConfiguration
    ) {
        ValidationResult result =
            new ValidationResult();

        Supplier_Bill__c bill =
            context.bill;

        validateHeader(
            bill,
            result,
            requirePostingConfiguration
        );

        validateLines(
            bill,
            context.lines,
            result
        );

        validateDuplicateReference(
            bill,
            result
        );

        return result;
    }

    private static void validateHeader(
        Supplier_Bill__c bill,
        ValidationResult result,
        Boolean requirePostingConfiguration
    ) {
        if (bill.Company__c == null) {
            result.addError(
                'Accounting Company is required.'
            );
            return;
        }

        try {
            SABCompanyAccessService.assertCompanyAccess(
                bill.Company__c
            );
        } catch (Exception ex) {
            result.addError(
                'You do not have active access to the Supplier Bill Accounting Company.'
            );
        }

        if (
            bill.Company__r == null
            || bill.Company__r.Is_Active__c != true
        ) {
            result.addError(
                'Accounting Company must be active.'
            );
        }

        if (bill.Supplier_Profile__c == null) {
            result.addError(
                'Supplier Accounting Profile is required.'
            );
        } else if (bill.Supplier_Profile__r != null) {
            if (
                bill.Supplier_Profile__r.Company__c
                != bill.Company__c
            ) {
                result.addError(
                    'Supplier Accounting Profile must belong to the same Accounting Company.'
                );
            }

            if (
                bill.Supplier_Profile__r.Is_Active__c
                != true
            ) {
                result.addError(
                    'Supplier Accounting Profile must be active.'
                );
            }

            if (
                bill.Supplier_Profile__r.Is_Supplier__c
                != true
            ) {
                result.addError(
                    'The selected Party Accounting Profile is not enabled as a supplier.'
                );
            }

            if (requirePostingConfiguration) {
                validateAPControlAccount(
                    bill,
                    result
                );
            }
        }

        if (
            bill.Document_Type__c != DOCUMENT_BILL
            && bill.Document_Type__c != DOCUMENT_CREDIT
        ) {
            result.addError(
                'Document Type must be Bill or Supplier Credit.'
            );
        }

        if (bill.Document_Date__c == null) {
            result.addError(
                'Document Date is required.'
            );
        }

        if (bill.Accounting_Date__c == null) {
            result.addError(
                'Accounting Date is required before submission.'
            );
        } else {
            validateOpenAccountingPeriod(
                bill,
                result
            );
        }

        if (
            bill.Due_Date__c != null
            && bill.Document_Date__c != null
            && bill.Due_Date__c
                < bill.Document_Date__c
        ) {
            result.addError(
                'Due Date cannot be before Document Date.'
            );
        }

        validateCurrency(
            bill,
            result
        );

        if (
            bill.Duplicate_Exception__c == true
            && String.isBlank(
                bill.Duplicate_Exception_Reason__c
            )
        ) {
            result.addError(
                'Duplicate Exception Reason is required when Duplicate Exception is selected.'
            );
        }
    }

    private static void validateAPControlAccount(
        Supplier_Bill__c bill,
        ValidationResult result
    ) {
        Id controlAccountId =
            bill.Supplier_Profile__r.AP_Control_Account__c;

        if (controlAccountId == null) {
            result.addError(
                'Supplier Accounting Profile requires an AP Control Account before approval/posting.'
            );
            return;
        }

        GL_Account__c controlAccount =
            bill.Supplier_Profile__r.AP_Control_Account__r;

        if (
            controlAccount == null
            || controlAccount.Company__c
                != bill.Company__c
        ) {
            result.addError(
                'AP Control Account must belong to the Supplier Bill Accounting Company.'
            );
            return;
        }

        if (
            controlAccount.Is_Active__c
            != true
        ) {
            result.addError(
                'AP Control Account must be active.'
            );
        }

        if (
            controlAccount.Account_Type__c
            != 'Liability'
        ) {
            result.addError(
                'AP Control Account must be a Liability account.'
            );
        }

        if (
            controlAccount.Is_Control_Account__c
            != true
            || controlAccount.Control_Type__c
                != 'AP'
        ) {
            result.addError(
                'AP Control Account must be configured as an AP control account.'
            );
        }
    }

    private static void validateOpenAccountingPeriod(
        Supplier_Bill__c bill,
        ValidationResult result
    ) {
        List<Accounting_Period__c> periods = [
            SELECT Id, Status__c
            FROM Accounting_Period__c
            WHERE Company__c =
                :bill.Company__c
              AND Start_Date__c
                <= :bill.Accounting_Date__c
              AND End_Date__c
                >= :bill.Accounting_Date__c
            LIMIT 2
        ];

        if (periods.isEmpty()) {
            result.addError(
                'No Accounting Period contains the Supplier Bill Accounting Date.'
            );
            return;
        }

        if (periods.size() > 1) {
            result.addError(
                'More than one Accounting Period contains the Supplier Bill Accounting Date.'
            );
            return;
        }

        if (
            periods[0].Status__c
            != 'Open'
        ) {
            result.addError(
                'Supplier Bill Accounting Date must be in an Open Accounting Period.'
            );
        }
    }

    private static void validateCurrency(
        Supplier_Bill__c bill,
        ValidationResult result
    ) {
        String companyCurrency;

        try {
            companyCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    bill.Company__r.Functional_Currency__c
                );
        } catch (Exception ex) {
            result.addError(
                'Accounting Company Functional Currency is invalid.'
            );
            return;
        }

        String transactionCurrency;

        try {
            transactionCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    bill.Transaction_Currency__c
                );
        } catch (Exception ex) {
            result.addError(
                'Transaction Currency must be a valid 3-letter currency code.'
            );
            return;
        }

        if (
            bill.Transaction_Currency__c
            != transactionCurrency
        ) {
            result.addError(
                'Transaction Currency must be stored as a 3-letter uppercase code.'
            );
        }

        if (
            String.isBlank(
                bill.Functional_Currency__c
            )
        ) {
            // The controlled transition writes the company functional currency.
        } else {
            String billFunctionalCurrency;

            try {
                billFunctionalCurrency =
                    SABMoneyService.normalizeCurrencyCode(
                        bill.Functional_Currency__c
                    );
            } catch (Exception ex) {
                result.addError(
                    'Functional Currency must be a valid 3-letter currency code.'
                );
                return;
            }

            if (
                bill.Functional_Currency__c
                != billFunctionalCurrency
            ) {
                result.addError(
                    'Functional Currency must be stored as a 3-letter uppercase code.'
                );
            }

            if (
                billFunctionalCurrency
                != companyCurrency
            ) {
                result.addError(
                    'Supplier Bill Functional Currency must match the Accounting Company Functional Currency.'
                );
            }
        }

        if (
            transactionCurrency
            == companyCurrency
        ) {
            if (
                bill.Exchange_Rate__c != null
                && bill.Exchange_Rate__c
                    != Decimal.valueOf('1')
            ) {
                result.addError(
                    'Same-currency Supplier Bills must use an Exchange Rate of 1 when a rate is stored.'
                );
            }
        } else {
            if (
                bill.Exchange_Rate__c == null
                || bill.Exchange_Rate__c <= 0
            ) {
                result.addError(
                    'A positive Exchange Rate is required for a foreign-currency Supplier Bill.'
                );
            }
        }
    }

    private static void validateLines(
        Supplier_Bill__c bill,
        List<Bill_Line__c> lines,
        ValidationResult result
    ) {
        if (
            lines == null
            || lines.isEmpty()
        ) {
            result.addError(
                'Supplier Bill must contain at least one Bill Line.'
            );
            return;
        }

        Set<Decimal> lineNumbers =
            new Set<Decimal>();

        Decimal subtotal = ZERO;
        Decimal recoverableTax = ZERO;
        Decimal nonrecoverableTax = ZERO;

        for (Bill_Line__c line : lines) {
            validateLine(
                bill,
                line,
                result,
                lineNumbers
            );

            subtotal +=
                nullToZero(
                    line.Net_Amount__c
                );

            recoverableTax +=
                nullToZero(
                    line.Recoverable_Tax_Amount__c
                );

            nonrecoverableTax +=
                nullToZero(
                    line.Nonrecoverable_Tax_Amount__c
                );
        }

        result.calculatedSubtotal =
            normalizeAmount(subtotal);

        result.calculatedTaxTotal =
            normalizeAmount(
                recoverableTax
                + nonrecoverableTax
            );

        result.calculatedTotal =
            normalizeAmount(
                result.calculatedSubtotal
                + result.calculatedTaxTotal
            );
    }

    private static void validateLine(
        Supplier_Bill__c bill,
        Bill_Line__c line,
        ValidationResult result,
        Set<Decimal> lineNumbers
    ) {
        if (
            line.Line_Number__c == null
            || line.Line_Number__c <= 0
        ) {
            result.addError(
                'Every Bill Line requires a positive Line Number.'
            );
        } else if (
            lineNumbers.contains(
                line.Line_Number__c
            )
        ) {
            result.addError(
                'Bill Line Number '
                + String.valueOf(
                    line.Line_Number__c
                )
                + ' is duplicated.'
            );
        } else {
            lineNumbers.add(
                line.Line_Number__c
            );
        }

        if (
            String.isBlank(
                line.Description__c
            )
        ) {
            result.addError(
                'Every Bill Line requires a Description.'
            );
        }

        Decimal quantity =
            line.Quantity__c == null
                ? Decimal.valueOf('1')
                : line.Quantity__c;

        if (quantity <= 0) {
            result.addError(
                'Bill Line Quantity must be greater than zero.'
            );
        }

        if (
            line.Unit_Price__c == null
            || line.Unit_Price__c < 0
        ) {
            result.addError(
                'Bill Line Unit Price is required and cannot be negative.'
            );
        }

        if (
            line.Net_Amount__c == null
            || line.Net_Amount__c < 0
        ) {
            result.addError(
                'Bill Line Net Amount is required and cannot be negative.'
            );
        }

        if (
            line.Unit_Price__c != null
            && line.Net_Amount__c != null
            && quantity > 0
        ) {
            Decimal expectedNet =
                normalizeAmount(
                    quantity
                    * line.Unit_Price__c
                );

            Decimal storedNet =
                normalizeAmount(
                    line.Net_Amount__c
                );

            if (
                !SABMoneyService.ledgerAmountsEqual(
                    expectedNet,
                    storedNet,
                    RoundingMode.HALF_UP
                )
            ) {
                result.addError(
                    'Bill Line '
                    + String.valueOf(
                        line.Line_Number__c
                    )
                    + ' Net Amount must equal Quantity × Unit Price.'
                );
            }
        }

        if (
            nullToZero(
                line.Recoverable_Tax_Amount__c
            ) < 0
        ) {
            result.addError(
                'Recoverable Tax Amount cannot be negative.'
            );
        }

        if (
            nullToZero(
                line.Nonrecoverable_Tax_Amount__c
            ) < 0
        ) {
            result.addError(
                'Nonrecoverable Tax Amount cannot be negative.'
            );
        }

        if (
            line.Expense_or_Asset_Account__c
            == null
        ) {
            result.addError(
                'Every Bill Line requires an Expense or Asset GL Account.'
            );
        } else if (
            line.Expense_or_Asset_Account__r
            != null
        ) {
            GL_Account__c account =
                line.Expense_or_Asset_Account__r;

            if (
                account.Company__c
                != bill.Company__c
            ) {
                result.addError(
                    'Bill Line GL Account must belong to the Supplier Bill Accounting Company.'
                );
            }

            if (
                account.Is_Active__c
                != true
            ) {
                result.addError(
                    'Bill Line GL Account must be active.'
                );
            }

            if (
                account.Account_Type__c
                    != 'Expense'
                && account.Account_Type__c
                    != 'Asset'
            ) {
                result.addError(
                    'Bill Line GL Account must be an Expense or Asset account.'
                );
            }

            if (
                account.Is_Control_Account__c
                == true
            ) {
                result.addError(
                    'Bill Lines cannot post directly to a control account.'
                );
            }
        }

        validateDimension(
            'Department',
            line.Department__c,
            line.Department__r == null
                ? null
                : line.Department__r.Company__c,
            line.Department__r == null
                ? null
                : line.Department__r.Is_Active__c,
            line.Department__r == null
                ? null
                : line.Department__r.Active_From__c,
            line.Department__r == null
                ? null
                : line.Department__r.Active_To__c,
            bill,
            result
        );

        validateDimension(
            'Cost Center',
            line.Cost_Center__c,
            line.Cost_Center__r == null
                ? null
                : line.Cost_Center__r.Company__c,
            line.Cost_Center__r == null
                ? null
                : line.Cost_Center__r.Is_Active__c,
            line.Cost_Center__r == null
                ? null
                : line.Cost_Center__r.Active_From__c,
            line.Cost_Center__r == null
                ? null
                : line.Cost_Center__r.Active_To__c,
            bill,
            result
        );

        if (
            line.Project__c != null
            && line.Project__r != null
        ) {
            if (
                line.Project__r.Company__c
                != bill.Company__c
            ) {
                result.addError(
                    'Project must belong to the Supplier Bill Accounting Company.'
                );
            }

            if (
                line.Project__r.Status__c
                != 'Active'
            ) {
                result.addError(
                    'Project must be Active when used on a Supplier Bill.'
                );
            }

            if (
                bill.Accounting_Date__c != null
                && line.Project__r.Start_Date__c != null
                && bill.Accounting_Date__c
                    < line.Project__r.Start_Date__c
            ) {
                result.addError(
                    'Supplier Bill Accounting Date cannot be before the Project Start Date.'
                );
            }

            if (
                bill.Accounting_Date__c != null
                && line.Project__r.End_Date__c != null
                && bill.Accounting_Date__c
                    > line.Project__r.End_Date__c
            ) {
                result.addError(
                    'Supplier Bill Accounting Date cannot be after the Project End Date.'
                );
            }
        }

        if (
            line.Tax_Code__c != null
            && line.Tax_Code__r != null
        ) {
            if (
                line.Tax_Code__r.Company__c
                != bill.Company__c
            ) {
                result.addError(
                    'Tax Code must belong to the Supplier Bill Accounting Company.'
                );
            }

            if (
                line.Tax_Code__r.Is_Active__c
                != true
            ) {
                result.addError(
                    'Tax Code must be active.'
                );
            }
        }

        if (
            line.Purchase_Order_Line__c != null
            && line.Purchase_Order_Line__r != null
            && line.Purchase_Order_Line__r.Purchase_Order__r != null
            && line.Purchase_Order_Line__r.Purchase_Order__r.Company__c
                != bill.Company__c
        ) {
            result.addError(
                'Purchase Order Line must belong to the Supplier Bill Accounting Company.'
            );
        }

        if (
            line.Goods_Receipt_Line__c != null
            && line.Goods_Receipt_Line__r != null
            && line.Goods_Receipt_Line__r.Goods_Receipt__r != null
            && line.Goods_Receipt_Line__r.Goods_Receipt__r.Company__c
                != bill.Company__c
        ) {
            result.addError(
                'Goods Receipt Line must belong to the Supplier Bill Accounting Company.'
            );
        }
    }

    private static void validateDimension(
        String label,
        Id dimensionId,
        Id dimensionCompanyId,
        Boolean isActive,
        Date activeFrom,
        Date activeTo,
        Supplier_Bill__c bill,
        ValidationResult result
    ) {
        if (dimensionId == null) {
            return;
        }

        if (
            dimensionCompanyId
            != bill.Company__c
        ) {
            result.addError(
                label
                + ' must belong to the Supplier Bill Accounting Company.'
            );
        }

        if (isActive != true) {
            result.addError(
                label
                + ' must be active.'
            );
        }

        if (
            bill.Accounting_Date__c != null
            && activeFrom != null
            && bill.Accounting_Date__c
                < activeFrom
        ) {
            result.addError(
                label
                + ' is not active on the Supplier Bill Accounting Date.'
            );
        }

        if (
            bill.Accounting_Date__c != null
            && activeTo != null
            && bill.Accounting_Date__c
                > activeTo
        ) {
            result.addError(
                label
                + ' is not active on the Supplier Bill Accounting Date.'
            );
        }
    }

    private static void validateDuplicateReference(
        Supplier_Bill__c bill,
        ValidationResult result
    ) {
        if (
            String.isBlank(
                bill.Vendor_Reference__c
            )
        ) {
            return;
        }

        List<Supplier_Bill__c> duplicates = [
            SELECT Id, Name, Status__c
            FROM Supplier_Bill__c
            WHERE Company__c =
                :bill.Company__c
              AND Supplier_Profile__c =
                :bill.Supplier_Profile__c
              AND Vendor_Reference__c =
                :bill.Vendor_Reference__c
              AND Status__c !=
                :STATUS_CANCELLED
              AND Id !=
                :bill.Id
            LIMIT 2
        ];

        if (
            !duplicates.isEmpty()
            && bill.Duplicate_Exception__c
                != true
        ) {
            result.addError(
                'A Supplier Bill with this Company, Supplier and Vendor Reference already exists. Use the controlled duplicate exception only when there is a documented business reason.'
            );
        }
    }

    private static void applyCalculatedHeaderValues(
        BillContext context,
        ValidationResult validation
    ) {
        Supplier_Bill__c bill =
            context.bill;

        String companyCurrency =
            SABMoneyService.normalizeCurrencyCode(
                bill.Company__r.Functional_Currency__c
            );

        String transactionCurrency =
            SABMoneyService.normalizeCurrencyCode(
                bill.Transaction_Currency__c
            );

        bill.Functional_Currency__c =
            companyCurrency;

        if (
            transactionCurrency
            == companyCurrency
        ) {
            bill.Exchange_Rate__c =
                Decimal.valueOf('1');
        }

        bill.Subtotal__c =
            validation.calculatedSubtotal;
        bill.Tax_Total__c =
            validation.calculatedTaxTotal;
        bill.Total__c =
            validation.calculatedTotal;
    }

    private static void assertCanReadBill(
        Supplier_Bill__c bill
    ) {
        SABAccessControlService.assertReadable(
            Supplier_Bill__c.SObjectType,
            supplierBillReadFields()
        );

        SABAccessControlService.assertReadable(
            Bill_Line__c.SObjectType,
            billLineReadFields()
        );

        SABCompanyAccessService.assertCompanyAccess(
            bill.Company__c
        );

        SABAccessControlService.assertRecordReadAccess(
            bill.Id
        );
    }

    private static void assertCanEditBill(
        Supplier_Bill__c bill
    ) {
        assertCanReadBill(bill);

        SABAccessControlService.assertUpdateable(
            Supplier_Bill__c.SObjectType,
            new List<Schema.SObjectField>{
                Supplier_Bill__c.Status__c,
                Supplier_Bill__c.Functional_Currency__c,
                Supplier_Bill__c.Exchange_Rate__c,
                Supplier_Bill__c.Subtotal__c,
                Supplier_Bill__c.Tax_Total__c,
                Supplier_Bill__c.Total__c,
                Supplier_Bill__c.Accounting_Event__c
            }
        );

        SABAccessControlService.assertRecordEditAccess(
            bill.Id
        );
    }

    private static List<Schema.SObjectField>
        supplierBillReadFields()
    {
        return new List<Schema.SObjectField>{
            Supplier_Bill__c.Company__c,
            Supplier_Bill__c.Supplier_Profile__c,
            Supplier_Bill__c.Document_Type__c,
            Supplier_Bill__c.Document_Date__c,
            Supplier_Bill__c.Accounting_Date__c,
            Supplier_Bill__c.Due_Date__c,
            Supplier_Bill__c.Vendor_Reference__c,
            Supplier_Bill__c.Transaction_Currency__c,
            Supplier_Bill__c.Functional_Currency__c,
            Supplier_Bill__c.Exchange_Rate__c,
            Supplier_Bill__c.Status__c,
            Supplier_Bill__c.Subtotal__c,
            Supplier_Bill__c.Tax_Total__c,
            Supplier_Bill__c.Total__c,
            Supplier_Bill__c.Duplicate_Exception__c,
            Supplier_Bill__c.Duplicate_Exception_Reason__c,
            Supplier_Bill__c.Accounting_Event__c
        };
    }

    private static List<Schema.SObjectField>
        billLineReadFields()
    {
        return new List<Schema.SObjectField>{
            Bill_Line__c.Supplier_Bill__c,
            Bill_Line__c.Line_Number__c,
            Bill_Line__c.Description__c,
            Bill_Line__c.Quantity__c,
            Bill_Line__c.Unit_Price__c,
            Bill_Line__c.Net_Amount__c,
            Bill_Line__c.Recoverable_Tax_Amount__c,
            Bill_Line__c.Nonrecoverable_Tax_Amount__c,
            Bill_Line__c.Expense_or_Asset_Account__c,
            Bill_Line__c.Department__c,
            Bill_Line__c.Cost_Center__c,
            Bill_Line__c.Project__c,
            Bill_Line__c.Tax_Code__c,
            Bill_Line__c.Purchase_Order_Line__c,
            Bill_Line__c.Goods_Receipt_Line__c
        };
    }

    private static Business_Action__c findPriorAction(
        String requestKey
    ) {
        List<Business_Action__c> actions = [
            SELECT Id, Action__c,
                   Source_Type__c,
                   Source_Record_Id__c,
                   Request_Key__c
            FROM Business_Action__c
            WHERE Request_Key__c =
                :requestKey
            LIMIT 1
        ];

        return actions.isEmpty()
            ? null
            : actions[0];
    }

    private static Business_Action__c createBusinessAction(
        Supplier_Bill__c bill,
        String previousStatus,
        String newStatus,
        String requestKey,
        String reason
    ) {
        String auditReason =
            reason;

        if (String.isBlank(auditReason)) {
            auditReason =
                previousStatus
                + ' → '
                + newStatus;
        }

        Business_Action__c action =
            new Business_Action__c(
                Company__c =
                    bill.Company__c,
                Source_Type__c =
                    'Supplier_Bill__c',
                Source_Record_Id__c =
                    String.valueOf(
                        bill.Id
                    ),
                Action__c =
                    lifecycleAction(
                        newStatus
                    ),
                Actor__c =
                    UserInfo.getUserId(),
                Action_At__c =
                    System.now(),
                Reason__c =
                    auditReason,
                Request_Key__c =
                    requestKey
            );

        insert action;
        return action;
    }

    private static String lifecycleAction(
        String newStatus
    ) {
        if (newStatus == STATUS_SUBMITTED) {
            return 'SUPPLIER_BILL_SUBMITTED';
        }

        if (newStatus == STATUS_APPROVED) {
            return 'SUPPLIER_BILL_APPROVED';
        }

        if (newStatus == STATUS_DRAFT) {
            return 'SUPPLIER_BILL_RETURNED_TO_DRAFT';
        }

        if (newStatus == STATUS_CANCELLED) {
            return 'SUPPLIER_BILL_CANCELLED';
        }

        if (newStatus == STATUS_POSTED) {
            return 'SUPPLIER_BILL_POSTED';
        }

        return 'SUPPLIER_BILL_STATUS_CHANGED';
    }

    private static void guardBillLineParents(
        List<Bill_Line__c> records,
        Map<Id, Bill_Line__c> oldMap,
        String operationLabel
    ) {
        if (
            records == null
            || records.isEmpty()
        ) {
            return;
        }

        Set<Id> billIds =
            new Set<Id>();

        for (Bill_Line__c line : records) {
            if (line.Supplier_Bill__c != null) {
                billIds.add(
                    line.Supplier_Bill__c
                );
            }

            if (
                oldMap != null
                && oldMap.containsKey(line.Id)
                && oldMap.get(line.Id).Supplier_Bill__c != null
            ) {
                billIds.add(
                    oldMap.get(line.Id).Supplier_Bill__c
                );
            }
        }

        Map<Id, Supplier_Bill__c> bills =
            billIds.isEmpty()
                ? new Map<Id, Supplier_Bill__c>()
                : new Map<Id, Supplier_Bill__c>([
                    SELECT Id, Status__c
                    FROM Supplier_Bill__c
                    WHERE Id IN :billIds
                ]);

        for (Bill_Line__c line : records) {
            Id currentBillId =
                line.Supplier_Bill__c;

            if (
                currentBillId == null
                || !bills.containsKey(
                    currentBillId
                )
            ) {
                continue;
            }

            if (
                bills.get(
                    currentBillId
                ).Status__c != STATUS_DRAFT
            ) {
                line.addError(
                    'Bill Lines can only be '
                    + operationLabel
                    + ' while the Supplier Bill is Draft.'
                );
            }

            if (
                oldMap != null
                && oldMap.containsKey(line.Id)
                && oldMap.get(line.Id).Supplier_Bill__c
                    != line.Supplier_Bill__c
            ) {
                line.addError(
                    'Bill Lines cannot be reparented to another Supplier Bill.'
                );
            }
        }
    }

    private static Boolean hasMaterialHeaderChange(
        Supplier_Bill__c oldRecord,
        Supplier_Bill__c newRecord
    ) {
        return
            oldRecord.Company__c
                != newRecord.Company__c
            || oldRecord.Supplier_Profile__c
                != newRecord.Supplier_Profile__c
            || oldRecord.Document_Type__c
                != newRecord.Document_Type__c
            || oldRecord.Document_Date__c
                != newRecord.Document_Date__c
            || oldRecord.Accounting_Date__c
                != newRecord.Accounting_Date__c
            || oldRecord.Due_Date__c
                != newRecord.Due_Date__c
            || oldRecord.Vendor_Reference__c
                != newRecord.Vendor_Reference__c
            || oldRecord.Transaction_Currency__c
                != newRecord.Transaction_Currency__c
            || oldRecord.Functional_Currency__c
                != newRecord.Functional_Currency__c
            || oldRecord.Exchange_Rate__c
                != newRecord.Exchange_Rate__c
            || oldRecord.Subtotal__c
                != newRecord.Subtotal__c
            || oldRecord.Tax_Total__c
                != newRecord.Tax_Total__c
            || oldRecord.Total__c
                != newRecord.Total__c
            || oldRecord.Duplicate_Exception__c
                != newRecord.Duplicate_Exception__c
            || oldRecord.Duplicate_Exception_Reason__c
                != newRecord.Duplicate_Exception_Reason__c;
    }

    private static Decimal normalizeAmount(
        Decimal value
    ) {
        return SABMoneyService.normalizeLedgerAmount(
            value == null
                ? ZERO
                : value,
            RoundingMode.HALF_UP
        );
    }

    private static Decimal nullToZero(
        Decimal value
    ) {
        return value == null
            ? ZERO
            : value;
    }

    private static void throwIfInvalid(
        ValidationResult validation
    ) {
        if (
            validation != null
            && validation.isValid != true
        ) {
            throw new SupplierBillException(
                String.join(
                    validation.errors,
                    ' | '
                )
            );
        }
    }

    private static void requireRequestKey(
        String requestKey
    ) {
        if (String.isBlank(requestKey)) {
            throw new SupplierBillException(
                'Request Key is required for a Supplier Bill lifecycle action.'
            );
        }

        if (requestKey.length() > 160) {
            throw new SupplierBillException(
                'Request Key cannot exceed 160 characters.'
            );
        }
    }

    private static void requireReason(
        String reason,
        String message
    ) {
        if (String.isBlank(reason)) {
            throw new SupplierBillException(
                message
            );
        }
    }
}
