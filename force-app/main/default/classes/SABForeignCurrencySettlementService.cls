/**
 * G7D - Foreign-Currency Customer Receipt / Supplier Payment & Allocation Integration.
 *
 * This service is the controlled foreign-currency path. The earlier G3C/G4B
 * same-currency services remain unchanged for functional-currency cash flows.
 *
 * Supported G7D scope:
 * - Receipt or Disbursement
 * - Payment transaction currency = selected Bank Account currency
 * - Payment transaction currency != Accounting Company functional currency
 * - approved Spot rate selected at authorization and snapshotted on Payment
 * - cash/payment journal posted at settlement rate
 * - allocation only to a same-currency Posted Invoice or Supplier Bill
 * - Payment Amount = Document Amount in that foreign currency
 * - Base Amount = allocated amount x Payment settlement rate
 * - G7C realized FX is invoked automatically after allocation
 * - allocation reversal first reverses G7C realized FX, then reverses allocation
 *
 * Cross-currency settlement (e.g. USD Invoice paid from EUR cash) remains
 * intentionally deferred.
 */
public with sharing class SABForeignCurrencySettlementService {

    public class ForeignCurrencySettlementException extends Exception {}

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    private static final String PERMISSION =
        'SAB_Process_Foreign_Currency_Settlement';

    private static final String STATE_DRAFT =
        'Draft';

    private static final String STATE_AUTHORIZED =
        'Authorized';

    private static final String STATE_SUBMITTED =
        'Submitted';

    private static final String STATE_SUCCEEDED =
        'Succeeded';

    private static final String STATE_REVERSED =
        'Reversed';

    private static final String DIRECTION_RECEIPT =
        'Receipt';

    private static final String DIRECTION_DISBURSEMENT =
        'Disbursement';

    private static final String SOURCE_TYPE =
        'Accounting_Payment__c';

    @TestVisible
    private static Boolean lifecycleMutationInProgress =
        false;

    public static Boolean isLifecycleMutationInProgress() {
        return lifecycleMutationInProgress;
    }

    public class PaymentLifecycleResult {
        @AuraEnabled public Id paymentId { get; private set; }
        @AuraEnabled public String previousState { get; private set; }
        @AuraEnabled public String newState { get; private set; }
        @AuraEnabled public Decimal exchangeRate { get; private set; }
        @AuraEnabled public Id exchangeRateRecordId { get; private set; }
        @AuraEnabled public Id journalEntryId { get; private set; }
        @AuraEnabled public Id accountingEventId { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private PaymentLifecycleResult() {}
    }

    public class ForeignAllocationRequest {
        @AuraEnabled public Id invoiceId { get; set; }
        @AuraEnabled public Id supplierBillId { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public Date effectiveDate { get; set; }
        @AuraEnabled public String notes { get; set; }
    }

    public class ForeignAllocationResult {
        @AuraEnabled public Id allocationId { get; private set; }
        @AuraEnabled public Id targetId { get; private set; }
        @AuraEnabled public String targetType { get; private set; }
        @AuraEnabled public Decimal paymentAmount { get; private set; }
        @AuraEnabled public Decimal documentAmount { get; private set; }
        @AuraEnabled public Decimal baseAmount { get; private set; }
        @AuraEnabled public Decimal realizedFXAmount { get; private set; }
        @AuraEnabled public String realizedFXState { get; private set; }
        @AuraEnabled public Id realizedFXJournalId { get; private set; }
        @AuraEnabled public Id realizedFXAccountingEventId { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private ForeignAllocationResult() {}
    }

    public class ForeignAllocationReversalResult {
        @AuraEnabled public Id originalAllocationId { get; private set; }
        @AuraEnabled public Id reversalAllocationId { get; private set; }
        @AuraEnabled public String originalStatus { get; private set; }
        @AuraEnabled public String realizedFXState { get; private set; }
        @AuraEnabled public Id realizedFXReversalJournalId { get; private set; }
        @AuraEnabled public Id realizedFXReversalEventId { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private ForeignAllocationReversalResult() {}
    }

    private class PaymentContext {
        Accounting_Payment__c payment;
        String companyCurrency;
        String transactionCurrency;
        Id bankGLAccountId;
        Id controlGLAccountId;
        String eventType;
        String adapterKey;
        String postingPrefix;
    }

    @AuraEnabled
    public static PaymentLifecycleResult authorizeForeignPayment(
        Id paymentId,
        String requestKey
    ) {
        assertForeignPermission();
        validateRequestKey(requestKey);

        Business_Action__c prior =
            findPriorAction(
                requestKey
            );

        if (prior != null) {
            return replayLifecycle(
                paymentId,
                expectedAuthorizeAction(
                    paymentId
                ),
                STATE_AUTHORIZED,
                prior
            );
        }

        Accounting_Payment__c payment =
            loadPayment(
                paymentId,
                true
            );

        SABCompanyAccessService.assertCompanyAccess(
            payment.Company__c
        );

        if (payment.Processing_State__c != STATE_DRAFT) {
            throw new ForeignCurrencySettlementException(
                'Foreign-currency Payment must be Draft before authorization.'
            );
        }

        PaymentContext context =
            validateForeignPayment(
                payment,
                false
            );

        SABExchangeRateService.RateRequest rateRequest =
            new SABExchangeRateService.RateRequest();

        rateRequest.fromCurrency =
            context.transactionCurrency;
        rateRequest.toCurrency =
            context.companyCurrency;
        rateRequest.rateType =
            'Spot';
        rateRequest.effectiveAt =
            Datetime.newInstance(
                payment.Effective_Date__c,
                Time.newInstance(
                    23,
                    59,
                    59,
                    999
                )
            );

        SABExchangeRateService.RateSnapshot snapshot =
            SABExchangeRateService.selectApprovedRate(
                rateRequest
            );

        String previousState =
            payment.Processing_State__c;

        payment.Functional_Currency__c =
            context.companyCurrency;
        payment.Exchange_Rate__c =
            snapshot.rate;
        payment.Exchange_Rate_Record__c =
            snapshot.exchangeRateId;
        payment.Processing_State__c =
            STATE_AUTHORIZED;

        controlledPaymentUpdate(
            payment
        );

        createAction(
            payment.Company__c,
            SOURCE_TYPE,
            payment.Id,
            expectedAuthorizeAction(
                payment.Id
            ),
            requestKey,
            'Foreign-currency Payment authorized with approved Spot exchange-rate snapshot.'
        );

        PaymentLifecycleResult result =
            lifecycleResult(
                payment.Id,
                previousState,
                STATE_AUTHORIZED,
                false
            );

        result.exchangeRate =
            snapshot.rate;
        result.exchangeRateRecordId =
            snapshot.exchangeRateId;

        return result;
    }

    @AuraEnabled
    public static PaymentLifecycleResult submitForeignPayment(
        Id paymentId,
        String providerRequestKey,
        String requestKey
    ) {
        assertForeignPermission();
        validateRequestKey(requestKey);

        if (String.isBlank(providerRequestKey)) {
            throw new ForeignCurrencySettlementException(
                'Provider Request Key is required.'
            );
        }

        if (
            providerRequestKey.trim().length()
                > Accounting_Payment__c.Provider_Request_Key__c
                    .getDescribe()
                    .getLength()
        ) {
            throw new ForeignCurrencySettlementException(
                'Provider Request Key is too long.'
            );
        }

        Business_Action__c prior =
            findPriorAction(
                requestKey
            );

        if (prior != null) {
            return replayLifecycle(
                paymentId,
                expectedSubmitAction(
                    paymentId
                ),
                STATE_SUBMITTED,
                prior
            );
        }

        Accounting_Payment__c payment =
            loadPayment(
                paymentId,
                true
            );

        SABCompanyAccessService.assertCompanyAccess(
            payment.Company__c
        );

        if (
            payment.Processing_State__c
                != STATE_AUTHORIZED
        ) {
            throw new ForeignCurrencySettlementException(
                'Foreign-currency Payment must be Authorized before submission.'
            );
        }

        validateForeignPayment(
            payment,
            true
        );

        List<Accounting_Payment__c> duplicates = [
            SELECT Id
            FROM Accounting_Payment__c
            WHERE Company__c =
                    :payment.Company__c
              AND Provider_Request_Key__c =
                    :providerRequestKey.trim()
              AND Id !=
                    :payment.Id
            LIMIT 1
        ];

        if (!duplicates.isEmpty()) {
            throw new ForeignCurrencySettlementException(
                'Provider Request Key is already used by another Payment in this Accounting Company.'
            );
        }

        String previousState =
            payment.Processing_State__c;

        payment.Provider_Request_Key__c =
            providerRequestKey.trim();
        payment.Processing_State__c =
            STATE_SUBMITTED;

        controlledPaymentUpdate(
            payment
        );

        createAction(
            payment.Company__c,
            SOURCE_TYPE,
            payment.Id,
            expectedSubmitAction(
                payment.Id
            ),
            requestKey,
            'Foreign-currency Payment submitted for settlement processing.'
        );

        return lifecycleResult(
            payment.Id,
            previousState,
            STATE_SUBMITTED,
            false
        );
    }

    @AuraEnabled
    public static PaymentLifecycleResult postForeignPayment(
        Id paymentId,
        String requestKey
    ) {
        assertForeignPermission();
        validateRequestKey(requestKey);

        Accounting_Payment__c payment =
            loadPayment(
                paymentId,
                true
            );

        SABCompanyAccessService.assertCompanyAccess(
            payment.Company__c
        );

        if (payment.Processing_State__c == STATE_SUCCEEDED) {
            return resolveSucceededPaymentReplay(
                payment
            );
        }

        if (
            payment.Processing_State__c
                != STATE_SUBMITTED
        ) {
            throw new ForeignCurrencySettlementException(
                'Foreign-currency Payment must be Submitted before posting.'
            );
        }

        if (String.isBlank(payment.Provider_Request_Key__c)) {
            throw new ForeignCurrencySettlementException(
                'Submitted foreign-currency Payment requires a Provider Request Key.'
            );
        }

        PaymentContext context =
            validateForeignPayment(
                payment,
                true
            );

        Accounting_Period__c period =
            resolveOpenPeriod(
                payment.Company__c,
                payment.Effective_Date__c
            );

        SABMoneyService.ConversionResult conversion =
            SABMoneyService.convertToFunctional(
                payment.Amount__c,
                context.transactionCurrency,
                context.companyCurrency,
                payment.Exchange_Rate__c,
                RoundingMode.HALF_UP
            );

        Decimal baseAmount =
            SABMoneyService.normalizeLedgerAmount(
                conversion.functionalAmount,
                RoundingMode.HALF_UP
            );

        if (baseAmount <= ZERO) {
            throw new ForeignCurrencySettlementException(
                'Foreign-currency Payment functional amount must be greater than zero.'
            );
        }

        Savepoint sp =
            Database.setSavepoint();

        try {
            Journal_Entry__c journal =
                new Journal_Entry__c(
                    Company__c =
                        payment.Company__c,
                    Accounting_Period__c =
                        period.Id,
                    Accounting_Date__c =
                        payment.Effective_Date__c,
                    Entry_Type__c =
                        'Subledger',
                    Status__c =
                        'Draft',
                    Description__c =
                        truncate(
                            buildDescription(
                                payment
                            ),
                            Journal_Entry__c.Description__c
                                .getDescribe()
                                .getLength()
                        ),
                    Version__c =
                        1
                );

            insert journal;

            insert buildPaymentJournalLines(
                journal.Id,
                context,
                baseAmount
            );

            SABAccountingEventService.ReservationRequest eventRequest =
                new SABAccountingEventService.ReservationRequest();

            eventRequest.companyId =
                payment.Company__c;
            eventRequest.adapterKey =
                context.adapterKey;
            eventRequest.requestKey =
                requestKey.trim();
            eventRequest.eventKey =
                context.postingPrefix
                + '-EVENT-'
                + String.valueOf(
                    payment.Id
                )
                + '-V1';
            eventRequest.eventType =
                context.eventType;
            eventRequest.sourceBusinessKey =
                sourceBusinessKey(
                    payment
                );
            eventRequest.sourceRecordId =
                String.valueOf(
                    payment.Id
                );
            eventRequest.sourceType =
                SOURCE_TYPE;
            eventRequest.sourceVersion =
                1;

            SABPostingService.PostingRequest postingRequest =
                new SABPostingService.PostingRequest();

            postingRequest.journalEntryId =
                journal.Id;
            postingRequest.postingKey =
                context.postingPrefix
                + '-POST-'
                + String.valueOf(
                    payment.Id
                )
                + '-V1';
            postingRequest.eventRequest =
                eventRequest;

            SABPostingService.PostingResult posted =
                SABPostingService.postDraftJournal(
                    postingRequest
                );

            if (
                payment.Direction__c
                    == DIRECTION_RECEIPT
            ) {
                SABCustomerReceiptService.completeSucceededPosting(
                    payment.Id,
                    posted.accountingEventId,
                    posted.journalEntryId,
                    'G7D-RCPT-COMPLETE-'
                    + String.valueOf(
                        payment.Id
                    )
                );
            } else {
                SABSupplierPaymentService.completeSucceededPosting(
                    payment.Id,
                    posted.accountingEventId,
                    posted.journalEntryId,
                    'G7D-PAY-COMPLETE-'
                    + String.valueOf(
                        payment.Id
                    )
                );
            }

            PaymentLifecycleResult result =
                lifecycleResult(
                    payment.Id,
                    STATE_SUBMITTED,
                    STATE_SUCCEEDED,
                    posted.replay
                );

            result.exchangeRate =
                payment.Exchange_Rate__c;
            result.exchangeRateRecordId =
                payment.Exchange_Rate_Record__c;
            result.journalEntryId =
                posted.journalEntryId;
            result.accountingEventId =
                posted.accountingEventId;

            return result;
        } catch (Exception ex) {
            Database.rollback(
                sp
            );
            throw ex;
        }
    }

    @AuraEnabled
    public static List<ForeignAllocationResult>
        allocateForeignPayment(
            Id paymentId,
            List<ForeignAllocationRequest> requests,
            String requestKey,
            String reason
        )
    {
        assertForeignPermission();
        validateRequestKey(requestKey);

        if (
            requests == null
            || requests.isEmpty()
        ) {
            throw new ForeignCurrencySettlementException(
                'At least one foreign-currency allocation is required.'
            );
        }

        Accounting_Payment__c payment =
            loadPayment(
                paymentId,
                true
            );

        SABCompanyAccessService.assertCompanyAccess(
            payment.Company__c
        );

        if (
            payment.Processing_State__c
                != STATE_SUCCEEDED
            || payment.Accounting_Event__c
                == null
        ) {
            throw new ForeignCurrencySettlementException(
                'Only a Succeeded posted foreign-currency Payment can be allocated.'
            );
        }

        PaymentContext paymentContext =
            validateForeignPayment(
                payment,
                true
            );

        Business_Action__c prior =
            findPriorAction(
                requestKey
            );

        if (prior != null) {
            if (
                prior.Action__c
                    != 'FOREIGN_CURRENCY_PAYMENT_ALLOCATED'
                || prior.Source_Type__c
                    != SOURCE_TYPE
                || prior.Source_Record_Id__c
                    != String.valueOf(
                        payment.Id
                    )
            ) {
                throw new ForeignCurrencySettlementException(
                    'Request Key was already used for another financial action.'
                );
            }

            return replayAllocationResults(
                payment,
                requests,
                requestKey
            );
        }

        Decimal alreadyAllocated =
            ZERO;

        Set<String> activeTargets =
            new Set<String>();

        for (Payment_Allocation__c existing : [
            SELECT Id,
                   Invoice__c,
                   Supplier_Bill__c,
                   Payment_Amount__c,
                   Allocated_Amount__c
            FROM Payment_Allocation__c
            WHERE Payment__c =
                    :payment.Id
              AND Status__c =
                    'Allocated'
            FOR UPDATE
        ]) {
            alreadyAllocated +=
                effectivePaymentAmount(
                    existing
                );

            if (existing.Invoice__c != null) {
                activeTargets.add(
                    'I:'
                    + String.valueOf(
                        existing.Invoice__c
                    )
                );
            }

            if (existing.Supplier_Bill__c != null) {
                activeTargets.add(
                    'B:'
                    + String.valueOf(
                        existing.Supplier_Bill__c
                    )
                );
            }
        }

        Decimal requestedTotal =
            ZERO;

        Set<Id> invoiceIds =
            new Set<Id>();

        Set<Id> billIds =
            new Set<Id>();

        Set<String> requestTargets =
            new Set<String>();

        for (ForeignAllocationRequest request : requests) {
            validateAllocationRequest(
                request,
                payment
            );

            Decimal amount =
                normalizePositiveAmount(
                    request.amount
                );

            requestedTotal +=
                amount;

            if (request.invoiceId != null) {
                String key =
                    'I:'
                    + String.valueOf(
                        request.invoiceId
                    );

                if (
                    requestTargets.contains(
                        key
                    )
                ) {
                    throw new ForeignCurrencySettlementException(
                        'The same Invoice cannot appear twice in one allocation request.'
                    );
                }

                requestTargets.add(
                    key
                );
                invoiceIds.add(
                    request.invoiceId
                );
            } else {
                String key =
                    'B:'
                    + String.valueOf(
                        request.supplierBillId
                    );

                if (
                    requestTargets.contains(
                        key
                    )
                ) {
                    throw new ForeignCurrencySettlementException(
                        'The same Supplier Bill cannot appear twice in one allocation request.'
                    );
                }

                requestTargets.add(
                    key
                );
                billIds.add(
                    request.supplierBillId
                );
            }
        }

        requestedTotal =
            SABMoneyService.normalizeTransactionAmount(
                requestedTotal,
                RoundingMode.HALF_UP
            );

        Decimal paymentAmount =
            SABMoneyService.normalizeTransactionAmount(
                payment.Amount__c,
                RoundingMode.HALF_UP
            );

        if (
            alreadyAllocated
            + requestedTotal
            > paymentAmount
        ) {
            throw new ForeignCurrencySettlementException(
                'Foreign-currency allocation exceeds the remaining Payment amount.'
            );
        }

        for (String key : requestTargets) {
            if (activeTargets.contains(key)) {
                throw new ForeignCurrencySettlementException(
                    'This Payment already has an active allocation to one of the selected documents.'
                );
            }
        }

        Map<Id, Invoice__c> invoices =
            invoiceIds.isEmpty()
                ? new Map<Id, Invoice__c>()
                : new Map<Id, Invoice__c>([
                    SELECT Id,
                           Company__c,
                           Party_Profile__c,
                           Document_Type__c,
                           Status__c,
                           Total__c,
                           Transaction_Currency__c,
                           Functional_Currency__c,
                           Exchange_Rate__c
                    FROM Invoice__c
                    WHERE Id IN :invoiceIds
                    FOR UPDATE
                ]);

        Map<Id, Supplier_Bill__c> bills =
            billIds.isEmpty()
                ? new Map<Id, Supplier_Bill__c>()
                : new Map<Id, Supplier_Bill__c>([
                    SELECT Id,
                           Company__c,
                           Supplier_Profile__c,
                           Document_Type__c,
                           Status__c,
                           Total__c,
                           Transaction_Currency__c,
                           Functional_Currency__c,
                           Exchange_Rate__c
                    FROM Supplier_Bill__c
                    WHERE Id IN :billIds
                    FOR UPDATE
                ]);

        if (
            invoices.size()
                != invoiceIds.size()
            || bills.size()
                != billIds.size()
        ) {
            throw new ForeignCurrencySettlementException(
                'One or more allocation target documents were not found or are not accessible.'
            );
        }

        Map<Id, Decimal> invoiceAllocated =
            activeDocumentAmountsForInvoices(
                invoiceIds
            );

        Map<Id, Decimal> billAllocated =
            activeDocumentAmountsForBills(
                billIds
            );

        List<Payment_Allocation__c> rows =
            new List<Payment_Allocation__c>();

        for (ForeignAllocationRequest request : requests) {
            Decimal amount =
                normalizePositiveAmount(
                    request.amount
                );

            Date effectiveDate =
                request.effectiveDate == null
                    ? payment.Effective_Date__c
                    : request.effectiveDate;

            if (
                effectiveDate
                    < payment.Effective_Date__c
            ) {
                throw new ForeignCurrencySettlementException(
                    'Allocation Effective Date cannot be before the Payment Effective Date.'
                );
            }

            resolveOpenPeriod(
                payment.Company__c,
                effectiveDate
            );

            Id targetId;
            String targetType;
            Decimal targetTotal;
            Decimal existingTargetAmount;
            String targetCurrency;
            String targetFunctionalCurrency;
            Id targetProfileId;

            if (request.invoiceId != null) {
                if (
                    payment.Direction__c
                        != DIRECTION_RECEIPT
                ) {
                    throw new ForeignCurrencySettlementException(
                        'Only Receipt Payments may be allocated to Invoices.'
                    );
                }

                Invoice__c invoice =
                    invoices.get(
                        request.invoiceId
                    );

                if (
                    invoice.Company__c
                        != payment.Company__c
                    || invoice.Document_Type__c
                        != 'Invoice'
                    || invoice.Status__c
                        != 'Posted'
                ) {
                    throw new ForeignCurrencySettlementException(
                        'Foreign-currency allocation target must be a Posted Invoice in the same Accounting Company.'
                    );
                }

                targetId =
                    invoice.Id;
                targetType =
                    'Invoice__c';
                targetTotal =
                    invoice.Total__c;
                existingTargetAmount =
                    invoiceAllocated.containsKey(
                        invoice.Id
                    )
                        ? invoiceAllocated.get(
                            invoice.Id
                        )
                        : ZERO;
                targetCurrency =
                    SABMoneyService.normalizeCurrencyCode(
                        invoice.Transaction_Currency__c
                    );
                targetFunctionalCurrency =
                    SABMoneyService.normalizeCurrencyCode(
                        invoice.Functional_Currency__c
                    );
                targetProfileId =
                    invoice.Party_Profile__c;
            } else {
                if (
                    payment.Direction__c
                        != DIRECTION_DISBURSEMENT
                ) {
                    throw new ForeignCurrencySettlementException(
                        'Only Disbursement Payments may be allocated to Supplier Bills.'
                    );
                }

                Supplier_Bill__c bill =
                    bills.get(
                        request.supplierBillId
                    );

                if (
                    bill.Company__c
                        != payment.Company__c
                    || bill.Document_Type__c
                        != 'Bill'
                    || bill.Status__c
                        != 'Posted'
                ) {
                    throw new ForeignCurrencySettlementException(
                        'Foreign-currency allocation target must be a Posted Supplier Bill in the same Accounting Company.'
                    );
                }

                targetId =
                    bill.Id;
                targetType =
                    'Supplier_Bill__c';
                targetTotal =
                    bill.Total__c;
                existingTargetAmount =
                    billAllocated.containsKey(
                        bill.Id
                    )
                        ? billAllocated.get(
                            bill.Id
                        )
                        : ZERO;
                targetCurrency =
                    SABMoneyService.normalizeCurrencyCode(
                        bill.Transaction_Currency__c
                    );
                targetFunctionalCurrency =
                    SABMoneyService.normalizeCurrencyCode(
                        bill.Functional_Currency__c
                    );
                targetProfileId =
                    bill.Supplier_Profile__c;
            }

            if (
                targetProfileId
                    != payment.Party_Profile__c
            ) {
                throw new ForeignCurrencySettlementException(
                    'Payment Party Accounting Profile must match the allocation target document.'
                );
            }

            if (
                targetCurrency
                    != paymentContext.transactionCurrency
                || targetFunctionalCurrency
                    != paymentContext.companyCurrency
            ) {
                throw new ForeignCurrencySettlementException(
                    'G7D requires Payment and source document to use the same foreign transaction currency and company functional currency.'
                );
            }

            Decimal outstanding =
                SABMoneyService.normalizeTransactionAmount(
                    targetTotal
                    - existingTargetAmount,
                    RoundingMode.HALF_UP
                );

            if (amount > outstanding) {
                throw new ForeignCurrencySettlementException(
                    'Allocation exceeds the outstanding amount of the selected '
                    + targetType
                    + '.'
                );
            }

            SABMoneyService.ConversionResult settlement =
                SABMoneyService.convertToFunctional(
                    amount,
                    paymentContext.transactionCurrency,
                    paymentContext.companyCurrency,
                    payment.Exchange_Rate__c,
                    RoundingMode.HALF_UP
                );

            Decimal baseAmount =
                SABMoneyService.normalizeLedgerAmount(
                    settlement.functionalAmount,
                    RoundingMode.HALF_UP
                );

            String allocationKey =
                buildAllocationKey(
                    payment.Id,
                    targetId,
                    requestKey
                );

            rows.add(
                new Payment_Allocation__c(
                    Allocation_Key__c =
                        allocationKey,
                    Payment__c =
                        payment.Id,
                    Company__c =
                        payment.Company__c,
                    Invoice__c =
                        request.invoiceId,
                    Supplier_Bill__c =
                        request.supplierBillId,
                    Allocated_Amount__c =
                        amount,
                    Payment_Amount__c =
                        amount,
                    Document_Amount__c =
                        amount,
                    Base_Amount__c =
                        baseAmount,
                    Transaction_Currency__c =
                        paymentContext.transactionCurrency,
                    Exchange_Rate__c =
                        payment.Exchange_Rate__c,
                    Allocation_Date__c =
                        Date.today(),
                    Effective_Date__c =
                        effectiveDate,
                    Status__c =
                        'Allocated',
                    Notes__c =
                        truncate(
                            request.notes,
                            Payment_Allocation__c.Notes__c
                                .getDescribe()
                                .getLength()
                        )
                )
            );
        }

        Savepoint sp =
            Database.setSavepoint();

        try {
            insert rows;

            List<ForeignAllocationResult> results =
                new List<ForeignAllocationResult>();

            for (Payment_Allocation__c row : rows) {
                SABRealizedFXSettlementService.SettlementResult fx =
                    SABRealizedFXSettlementService.processAllocation(
                        row.Id,
                        'G7D-RFX-'
                        + digest(
                            requestKey
                            + '|'
                            + String.valueOf(
                                row.Id
                            )
                        ).substring(
                            0,
                            32
                        ),
                        reason
                    );

                results.add(
                    buildAllocationResult(
                        row.Id,
                        false
                    )
                );
            }

            createAction(
                payment.Company__c,
                SOURCE_TYPE,
                payment.Id,
                'FOREIGN_CURRENCY_PAYMENT_ALLOCATED',
                requestKey,
                String.isBlank(reason)
                    ? 'Foreign-currency Payment allocated and realized FX processed.'
                    : reason.trim()
            );

            return results;
        } catch (Exception ex) {
            Database.rollback(
                sp
            );
            throw ex;
        }
    }

    @AuraEnabled
    public static ForeignAllocationReversalResult reverseForeignAllocation(
        Id allocationId,
        Date reversalDate,
        String requestKey,
        String reason
    ) {
        assertForeignPermission();
        validateRequestKey(requestKey);

        if (allocationId == null) {
            throw new ForeignCurrencySettlementException(
                'Payment Allocation Id is required.'
            );
        }

        if (reversalDate == null) {
            throw new ForeignCurrencySettlementException(
                'Allocation reversal date is required.'
            );
        }

        if (String.isBlank(reason)) {
            throw new ForeignCurrencySettlementException(
                'Allocation reversal reason is required.'
            );
        }

        Business_Action__c prior =
            findPriorAction(
                requestKey
            );

        if (prior != null) {
            if (
                prior.Action__c
                    != 'FOREIGN_CURRENCY_ALLOCATION_REVERSED'
                || prior.Source_Type__c
                    != 'Payment_Allocation__c'
                || prior.Source_Record_Id__c
                    != String.valueOf(
                        allocationId
                    )
            ) {
                throw new ForeignCurrencySettlementException(
                    'Request Key was already used for another financial action.'
                );
            }

            return buildReversalReplay(
                allocationId
            );
        }

        Payment_Allocation__c original = [
            SELECT Id,
                   Allocation_Key__c,
                   Payment__c,
                   Payment__r.Company__c,
                   Payment__r.Transaction_Currency__c,
                   Payment__r.Functional_Currency__c,
                   Company__c,
                   Invoice__c,
                   Supplier_Bill__c,
                   Allocated_Amount__c,
                   Payment_Amount__c,
                   Document_Amount__c,
                   Base_Amount__c,
                   Transaction_Currency__c,
                   Exchange_Rate__c,
                   Allocation_Date__c,
                   Effective_Date__c,
                   Status__c,
                   Historical_Carrying_Base__c,
                   Settlement_Base_Amount__c,
                   Realized_FX_Amount__c,
                   Realized_FX_State__c,
                   Realized_FX_Source_GL_Account__c,
                   Realized_FX_Journal__c,
                   Realized_FX_Accounting_Event__c,
                   Realized_FX_Reversal_Journal__c,
                   Realized_FX_Reversal_Event__c,
                   Realized_FX_Reversed_At__c
            FROM Payment_Allocation__c
            WHERE Id =
                    :allocationId
            LIMIT 1
            FOR UPDATE
        ];

        Id companyId =
            original.Company__c != null
                ? original.Company__c
                : original.Payment__r.Company__c;

        SABCompanyAccessService.assertCompanyAccess(
            companyId
        );

        if (original.Status__c != 'Allocated') {
            throw new ForeignCurrencySettlementException(
                'Only an active foreign-currency allocation can be reversed.'
            );
        }

        String txCurrency =
            SABMoneyService.normalizeCurrencyCode(
                original.Transaction_Currency__c
            );

        String functionalCurrency =
            SABMoneyService.normalizeCurrencyCode(
                original.Payment__r.Functional_Currency__c
            );

        if (txCurrency == functionalCurrency) {
            throw new ForeignCurrencySettlementException(
                'G7D reversal is only for foreign-currency allocations.'
            );
        }

        Savepoint sp =
            Database.setSavepoint();

        try {
            SABRealizedFXSettlementService.SettlementResult fxReversal =
                SABRealizedFXSettlementService.reverseSettlement(
                    original.Id,
                    reversalDate,
                    'G7D-RFXREV-'
                    + digest(
                        requestKey
                        + '|'
                        + String.valueOf(
                            original.Id
                        )
                    ).substring(
                        0,
                        32
                    ),
                    reason
                );

            Payment_Allocation__c refreshed = [
                SELECT Id,
                       Realized_FX_State__c,
                       Realized_FX_Reversal_Journal__c,
                       Realized_FX_Reversal_Event__c,
                       Realized_FX_Reversed_At__c
                FROM Payment_Allocation__c
                WHERE Id =
                        :original.Id
                LIMIT 1
                FOR UPDATE
            ];

            update new Payment_Allocation__c(
                Id =
                    original.Id,
                Status__c =
                    STATE_REVERSED
            );

            Payment_Allocation__c reversal =
                new Payment_Allocation__c(
                    Allocation_Key__c =
                        'FCYREV|'
                        + digest(
                            requestKey
                            + '|'
                            + String.valueOf(
                                original.Id
                            )
                        ),
                    Payment__c =
                        original.Payment__c,
                    Company__c =
                        companyId,
                    Invoice__c =
                        original.Invoice__c,
                    Supplier_Bill__c =
                        original.Supplier_Bill__c,
                    Allocated_Amount__c =
                        -safeAmount(
                            original.Allocated_Amount__c
                        ),
                    Payment_Amount__c =
                        -safeAmount(
                            original.Payment_Amount__c
                        ),
                    Document_Amount__c =
                        -safeAmount(
                            original.Document_Amount__c
                        ),
                    Base_Amount__c =
                        -safeAmount(
                            original.Base_Amount__c
                        ),
                    Transaction_Currency__c =
                        original.Transaction_Currency__c,
                    Exchange_Rate__c =
                        original.Exchange_Rate__c,
                    Allocation_Date__c =
                        Date.today(),
                    Effective_Date__c =
                        reversalDate,
                    Status__c =
                        STATE_REVERSED,
                    Reversal_Of__c =
                        original.Id,
                    Notes__c =
                        truncate(
                            reason.trim(),
                            Payment_Allocation__c.Notes__c
                                .getDescribe()
                                .getLength()
                        ),
                    Historical_Carrying_Base__c =
                        -safeAmount(
                            original.Historical_Carrying_Base__c
                        ),
                    Settlement_Base_Amount__c =
                        -safeAmount(
                            original.Settlement_Base_Amount__c
                        ),
                    Realized_FX_Amount__c =
                        -safeAmount(
                            original.Realized_FX_Amount__c
                        ),
                    Realized_FX_State__c =
                        'Reversed',
                    Realized_FX_Source_GL_Account__c =
                        original.Realized_FX_Source_GL_Account__c,
                    Realized_FX_Journal__c =
                        original.Realized_FX_Journal__c,
                    Realized_FX_Accounting_Event__c =
                        original.Realized_FX_Accounting_Event__c,
                    Realized_FX_Reversal_Journal__c =
                        refreshed.Realized_FX_Reversal_Journal__c,
                    Realized_FX_Reversal_Event__c =
                        refreshed.Realized_FX_Reversal_Event__c,
                    Realized_FX_Reversed_At__c =
                        refreshed.Realized_FX_Reversed_At__c
                );

            lifecycleMutationInProgress =
                true;

            try {
                insert reversal;
            } finally {
                lifecycleMutationInProgress =
                    false;
            }

            createAction(
                companyId,
                'Payment_Allocation__c',
                original.Id,
                'FOREIGN_CURRENCY_ALLOCATION_REVERSED',
                requestKey,
                reason.trim()
            );

            ForeignAllocationReversalResult result =
                new ForeignAllocationReversalResult();

            result.originalAllocationId =
                original.Id;
            result.reversalAllocationId =
                reversal.Id;
            result.originalStatus =
                STATE_REVERSED;
            result.realizedFXState =
                refreshed.Realized_FX_State__c;
            result.realizedFXReversalJournalId =
                refreshed.Realized_FX_Reversal_Journal__c;
            result.realizedFXReversalEventId =
                refreshed.Realized_FX_Reversal_Event__c;
            result.replay =
                false;

            return result;
        } catch (Exception ex) {
            Database.rollback(
                sp
            );
            throw ex;
        }
    }

    private static PaymentContext validateForeignPayment(
        Accounting_Payment__c payment,
        Boolean requireRateSnapshot
    ) {
        if (payment.Company__c == null) {
            throw new ForeignCurrencySettlementException(
                'Accounting Company is required.'
            );
        }

        if (
            payment.Company__r == null
            || payment.Company__r.Is_Active__c
                != true
        ) {
            throw new ForeignCurrencySettlementException(
                'Accounting Company must be active.'
            );
        }

        if (
            payment.Direction__c
                != DIRECTION_RECEIPT
            && payment.Direction__c
                != DIRECTION_DISBURSEMENT
        ) {
            throw new ForeignCurrencySettlementException(
                'Payment Direction must be Receipt or Disbursement.'
            );
        }

        if (
            payment.Amount__c == null
            || payment.Amount__c <= ZERO
        ) {
            throw new ForeignCurrencySettlementException(
                'Payment Amount must be greater than zero.'
            );
        }

        if (payment.Effective_Date__c == null) {
            throw new ForeignCurrencySettlementException(
                'Payment Effective Date is required.'
            );
        }

        resolveOpenPeriod(
            payment.Company__c,
            payment.Effective_Date__c
        );

        if (
            payment.Party_Profile__c == null
            || payment.Party_Profile__r == null
            || payment.Party_Profile__r.Company__c
                != payment.Company__c
            || payment.Party_Profile__r.Is_Active__c
                != true
        ) {
            throw new ForeignCurrencySettlementException(
                'Payment requires an active Party Accounting Profile in the same Accounting Company.'
            );
        }

        Id controlAccountId;

        if (
            payment.Direction__c
                == DIRECTION_RECEIPT
        ) {
            if (
                payment.Party_Profile__r.Is_Customer__c
                    != true
                || payment.Party_Profile__r.AR_Control_Account__c
                    == null
                || payment.Party_Profile__r.AR_Control_Account__r
                    == null
                || payment.Party_Profile__r.AR_Control_Account__r.Company__c
                    != payment.Company__c
                || payment.Party_Profile__r.AR_Control_Account__r.Is_Active__c
                    != true
                || payment.Party_Profile__r.AR_Control_Account__r.Is_Control_Account__c
                    != true
                || payment.Party_Profile__r.AR_Control_Account__r.Control_Type__c
                    != 'AR'
            ) {
                throw new ForeignCurrencySettlementException(
                    'Foreign-currency Receipt requires an active Customer profile with an AR control account.'
                );
            }

            controlAccountId =
                payment.Party_Profile__r.AR_Control_Account__c;
        } else {
            if (
                payment.Party_Profile__r.Is_Supplier__c
                    != true
                || payment.Party_Profile__r.AP_Control_Account__c
                    == null
                || payment.Party_Profile__r.AP_Control_Account__r
                    == null
                || payment.Party_Profile__r.AP_Control_Account__r.Company__c
                    != payment.Company__c
                || payment.Party_Profile__r.AP_Control_Account__r.Is_Active__c
                    != true
                || payment.Party_Profile__r.AP_Control_Account__r.Is_Control_Account__c
                    != true
                || payment.Party_Profile__r.AP_Control_Account__r.Control_Type__c
                    != 'AP'
            ) {
                throw new ForeignCurrencySettlementException(
                    'Foreign-currency Disbursement requires an active Supplier profile with an AP control account.'
                );
            }

            controlAccountId =
                payment.Party_Profile__r.AP_Control_Account__c;
        }

        if (
            payment.Bank_Account__c == null
            || payment.Bank_Account__r == null
            || payment.Bank_Account__r.Company__c
                != payment.Company__c
            || payment.Bank_Account__r.Is_Active__c
                != true
            || payment.Bank_Account__r.GL_Account__c
                == null
            || payment.Bank_Account__r.GL_Account__r
                == null
            || payment.Bank_Account__r.GL_Account__r.Company__c
                != payment.Company__c
            || payment.Bank_Account__r.GL_Account__r.Is_Active__c
                != true
            || payment.Bank_Account__r.GL_Account__r.Account_Type__c
                != 'Asset'
        ) {
            throw new ForeignCurrencySettlementException(
                'Payment requires an active same-company Bank Account mapped to an active Asset GL Account.'
            );
        }

        String companyCurrency =
            SABMoneyService.normalizeCurrencyCode(
                payment.Company__r.Functional_Currency__c
            );

        String transactionCurrency =
            SABMoneyService.normalizeCurrencyCode(
                payment.Transaction_Currency__c
            );

        String bankCurrency =
            SABMoneyService.normalizeCurrencyCode(
                payment.Bank_Account__r.Currency__c
            );

        if (
            payment.Transaction_Currency__c
                != transactionCurrency
            || payment.Bank_Account__r.Currency__c
                != bankCurrency
        ) {
            throw new ForeignCurrencySettlementException(
                'Payment and Bank Account currency codes must use normalized 3-letter uppercase codes.'
            );
        }

        if (transactionCurrency != bankCurrency) {
            throw new ForeignCurrencySettlementException(
                'Foreign-currency Payment Transaction Currency must match the selected Bank Account Currency.'
            );
        }

        if (transactionCurrency == companyCurrency) {
            throw new ForeignCurrencySettlementException(
                'G7D foreign-currency path requires Transaction Currency to differ from the Accounting Company Functional Currency. Use the existing same-currency Receipt/Payment services instead.'
            );
        }

        if (
            !String.isBlank(
                payment.Functional_Currency__c
            )
            && SABMoneyService.normalizeCurrencyCode(
                payment.Functional_Currency__c
            ) != companyCurrency
        ) {
            throw new ForeignCurrencySettlementException(
                'Payment Functional Currency must match the Accounting Company Functional Currency.'
            );
        }

        if (requireRateSnapshot) {
            if (
                payment.Exchange_Rate__c == null
                || payment.Exchange_Rate__c <= ZERO
                || payment.Exchange_Rate_Record__c == null
                || payment.Exchange_Rate_Record__r == null
            ) {
                throw new ForeignCurrencySettlementException(
                    'Authorized foreign-currency Payment requires an approved exchange-rate snapshot.'
                );
            }

            if (
                payment.Exchange_Rate_Record__r.Approved__c
                    != true
                || SABMoneyService.normalizeCurrencyCode(
                    payment.Exchange_Rate_Record__r.From_Currency__c
                ) != transactionCurrency
                || SABMoneyService.normalizeCurrencyCode(
                    payment.Exchange_Rate_Record__r.To_Currency__c
                ) != companyCurrency
                || payment.Exchange_Rate_Record__r.Rate_Type__c
                    != 'Spot'
                || payment.Exchange_Rate_Record__r.Rate__c
                    != payment.Exchange_Rate__c
            ) {
                throw new ForeignCurrencySettlementException(
                    'Payment exchange-rate snapshot no longer matches its approved Spot Exchange Rate record.'
                );
            }
        }

        PaymentContext context =
            new PaymentContext();

        context.payment =
            payment;
        context.companyCurrency =
            companyCurrency;
        context.transactionCurrency =
            transactionCurrency;
        context.bankGLAccountId =
            payment.Bank_Account__r.GL_Account__c;
        context.controlGLAccountId =
            controlAccountId;

        if (
            payment.Direction__c
                == DIRECTION_RECEIPT
        ) {
            context.eventType =
                'Payment Receipt';
            context.adapterKey =
                'FOREIGN_RECEIPT';
            context.postingPrefix =
                'FCY-RCPT';
        } else {
            context.eventType =
                'Payment Disbursement';
            context.adapterKey =
                'FOREIGN_DISBURSEMENT';
            context.postingPrefix =
                'FCY-PAY';
        }

        return context;
    }

    private static List<Journal_Entry_Line__c>
        buildPaymentJournalLines(
            Id journalId,
            PaymentContext context,
            Decimal baseAmount
        )
    {
        Accounting_Payment__c payment =
            context.payment;

        Decimal transactionAmount =
            SABMoneyService.normalizeTransactionAmount(
                payment.Amount__c,
                RoundingMode.HALF_UP
            );

        String rateSource =
            payment.Exchange_Rate_Record__r == null
                ? 'Approved Spot rate'
                : truncate(
                    'Approved Spot rate: '
                    + payment.Exchange_Rate_Record__r.Source__c,
                    Journal_Entry_Line__c.Rate_Source__c
                        .getDescribe()
                        .getLength()
                );

        if (
            payment.Direction__c
                == DIRECTION_RECEIPT
        ) {
            return new List<Journal_Entry_Line__c>{
                journalLine(
                    journalId,
                    1,
                    context.bankGLAccountId,
                    baseAmount,
                    ZERO,
                    transactionAmount,
                    context,
                    rateSource,
                    'Foreign-currency customer receipt - bank settlement',
                    'FCYRCPT|BANK'
                ),
                journalLine(
                    journalId,
                    2,
                    context.controlGLAccountId,
                    ZERO,
                    baseAmount,
                    transactionAmount,
                    context,
                    rateSource,
                    'Foreign-currency customer receipt - AR settlement at payment rate',
                    'FCYRCPT|AR'
                )
            };
        }

        return new List<Journal_Entry_Line__c>{
            journalLine(
                journalId,
                1,
                context.controlGLAccountId,
                baseAmount,
                ZERO,
                transactionAmount,
                context,
                rateSource,
                'Foreign-currency supplier payment - AP settlement at payment rate',
                'FCYPAY|AP'
            ),
            journalLine(
                journalId,
                2,
                context.bankGLAccountId,
                ZERO,
                baseAmount,
                transactionAmount,
                context,
                rateSource,
                'Foreign-currency supplier payment - bank settlement',
                'FCYPAY|BANK'
            )
        };
    }

    private static Journal_Entry_Line__c journalLine(
        Id journalId,
        Integer lineNumber,
        Id glAccountId,
        Decimal debit,
        Decimal credit,
        Decimal transactionAmount,
        PaymentContext context,
        String rateSource,
        String explanation,
        String keySuffix
    ) {
        return new Journal_Entry_Line__c(
            Journal_Entry__c =
                journalId,
            Line_Number__c =
                lineNumber,
            GL_Account__c =
                glAccountId,
            Debit_Base__c =
                debit,
            Credit_Base__c =
                credit,
            Transaction_Amount__c =
                transactionAmount,
            Transaction_Currency__c =
                context.transactionCurrency,
            Functional_Currency__c =
                context.companyCurrency,
            Applied_Exchange_Rate__c =
                context.payment.Exchange_Rate__c,
            Rate_Date__c =
                context.payment.Effective_Date__c,
            Rate_Source__c =
                rateSource,
            Explanation__c =
                truncate(
                    explanation,
                    Journal_Entry_Line__c.Explanation__c
                        .getDescribe()
                        .getLength()
                ),
            Source_Line_Key__c =
                truncate(
                    keySuffix
                    + '|'
                    + String.valueOf(
                        context.payment.Id
                    ),
                    Journal_Entry_Line__c.Source_Line_Key__c
                        .getDescribe()
                        .getLength()
                )
        );
    }

    private static Accounting_Payment__c loadPayment(
        Id paymentId,
        Boolean lockRecord
    ) {
        if (paymentId == null) {
            throw new ForeignCurrencySettlementException(
                'Payment Id is required.'
            );
        }

        List<Accounting_Payment__c> payments;

        if (lockRecord) {
            payments = [
                SELECT Id,
                       Name,
                       Company__c,
                       Company__r.Functional_Currency__c,
                       Company__r.Is_Active__c,
                       Party_Profile__c,
                       Party_Profile__r.Company__c,
                       Party_Profile__r.Is_Active__c,
                       Party_Profile__r.Is_Customer__c,
                       Party_Profile__r.Is_Supplier__c,
                       Party_Profile__r.AR_Control_Account__c,
                       Party_Profile__r.AR_Control_Account__r.Company__c,
                       Party_Profile__r.AR_Control_Account__r.Is_Active__c,
                       Party_Profile__r.AR_Control_Account__r.Is_Control_Account__c,
                       Party_Profile__r.AR_Control_Account__r.Control_Type__c,
                       Party_Profile__r.AP_Control_Account__c,
                       Party_Profile__r.AP_Control_Account__r.Company__c,
                       Party_Profile__r.AP_Control_Account__r.Is_Active__c,
                       Party_Profile__r.AP_Control_Account__r.Is_Control_Account__c,
                       Party_Profile__r.AP_Control_Account__r.Control_Type__c,
                       Bank_Account__c,
                       Bank_Account__r.Company__c,
                       Bank_Account__r.Currency__c,
                       Bank_Account__r.Is_Active__c,
                       Bank_Account__r.GL_Account__c,
                       Bank_Account__r.GL_Account__r.Company__c,
                       Bank_Account__r.GL_Account__r.Account_Type__c,
                       Bank_Account__r.GL_Account__r.Is_Active__c,
                       Direction__c,
                       Method__c,
                       Reference__c,
                       Amount__c,
                       Transaction_Currency__c,
                       Functional_Currency__c,
                       Exchange_Rate__c,
                       Exchange_Rate_Record__c,
                       Exchange_Rate_Record__r.From_Currency__c,
                       Exchange_Rate_Record__r.To_Currency__c,
                       Exchange_Rate_Record__r.Rate_Type__c,
                       Exchange_Rate_Record__r.Rate__c,
                       Exchange_Rate_Record__r.Approved__c,
                       Exchange_Rate_Record__r.Source__c,
                       Effective_Date__c,
                       Processing_State__c,
                       Provider_Request_Key__c,
                       Accounting_Event__c
                FROM Accounting_Payment__c
                WHERE Id =
                        :paymentId
                LIMIT 1
                FOR UPDATE
            ];
        } else {
            payments = [
                SELECT Id,
                       Name,
                       Company__c,
                       Company__r.Functional_Currency__c,
                       Company__r.Is_Active__c,
                       Party_Profile__c,
                       Party_Profile__r.Company__c,
                       Party_Profile__r.Is_Active__c,
                       Party_Profile__r.Is_Customer__c,
                       Party_Profile__r.Is_Supplier__c,
                       Party_Profile__r.AR_Control_Account__c,
                       Party_Profile__r.AR_Control_Account__r.Company__c,
                       Party_Profile__r.AR_Control_Account__r.Is_Active__c,
                       Party_Profile__r.AR_Control_Account__r.Is_Control_Account__c,
                       Party_Profile__r.AR_Control_Account__r.Control_Type__c,
                       Party_Profile__r.AP_Control_Account__c,
                       Party_Profile__r.AP_Control_Account__r.Company__c,
                       Party_Profile__r.AP_Control_Account__r.Is_Active__c,
                       Party_Profile__r.AP_Control_Account__r.Is_Control_Account__c,
                       Party_Profile__r.AP_Control_Account__r.Control_Type__c,
                       Bank_Account__c,
                       Bank_Account__r.Company__c,
                       Bank_Account__r.Currency__c,
                       Bank_Account__r.Is_Active__c,
                       Bank_Account__r.GL_Account__c,
                       Bank_Account__r.GL_Account__r.Company__c,
                       Bank_Account__r.GL_Account__r.Account_Type__c,
                       Bank_Account__r.GL_Account__r.Is_Active__c,
                       Direction__c,
                       Method__c,
                       Reference__c,
                       Amount__c,
                       Transaction_Currency__c,
                       Functional_Currency__c,
                       Exchange_Rate__c,
                       Exchange_Rate_Record__c,
                       Exchange_Rate_Record__r.From_Currency__c,
                       Exchange_Rate_Record__r.To_Currency__c,
                       Exchange_Rate_Record__r.Rate_Type__c,
                       Exchange_Rate_Record__r.Rate__c,
                       Exchange_Rate_Record__r.Approved__c,
                       Exchange_Rate_Record__r.Source__c,
                       Effective_Date__c,
                       Processing_State__c,
                       Provider_Request_Key__c,
                       Accounting_Event__c
                FROM Accounting_Payment__c
                WHERE Id =
                        :paymentId
                LIMIT 1
            ];
        }

        if (payments.isEmpty()) {
            throw new ForeignCurrencySettlementException(
                'Payment was not found or is not accessible.'
            );
        }

        return payments[0];
    }

    private static Accounting_Period__c resolveOpenPeriod(
        Id companyId,
        Date accountingDate
    ) {
        List<Accounting_Period__c> periods = [
            SELECT Id,
                   Company__c,
                   Start_Date__c,
                   End_Date__c,
                   Status__c
            FROM Accounting_Period__c
            WHERE Company__c =
                    :companyId
              AND Start_Date__c <=
                    :accountingDate
              AND End_Date__c >=
                    :accountingDate
            LIMIT 2
        ];

        if (periods.size() != 1) {
            throw new ForeignCurrencySettlementException(
                'Exactly one Accounting Period must contain the Payment/Allocation Effective Date.'
            );
        }

        if (periods[0].Status__c != 'Open') {
            throw new ForeignCurrencySettlementException(
                'Foreign-currency settlement requires an Open Accounting Period.'
            );
        }

        return periods[0];
    }

    private static Map<Id, Decimal> activeDocumentAmountsForInvoices(
        Set<Id> invoiceIds
    ) {
        Map<Id, Decimal> result =
            new Map<Id, Decimal>();

        if (invoiceIds.isEmpty()) {
            return result;
        }

        for (Payment_Allocation__c row : [
            SELECT Invoice__c,
                   Document_Amount__c,
                   Allocated_Amount__c
            FROM Payment_Allocation__c
            WHERE Invoice__c IN :invoiceIds
              AND Status__c =
                    'Allocated'
            FOR UPDATE
        ]) {
            Decimal amount =
                row.Document_Amount__c != null
                    ? row.Document_Amount__c
                    : row.Allocated_Amount__c;

            result.put(
                row.Invoice__c,
                (
                    result.containsKey(
                        row.Invoice__c
                    )
                        ? result.get(
                            row.Invoice__c
                        )
                        : ZERO
                )
                + (
                    amount == null
                        ? ZERO
                        : amount
                )
            );
        }

        return result;
    }

    private static Map<Id, Decimal> activeDocumentAmountsForBills(
        Set<Id> billIds
    ) {
        Map<Id, Decimal> result =
            new Map<Id, Decimal>();

        if (billIds.isEmpty()) {
            return result;
        }

        for (Payment_Allocation__c row : [
            SELECT Supplier_Bill__c,
                   Document_Amount__c,
                   Allocated_Amount__c
            FROM Payment_Allocation__c
            WHERE Supplier_Bill__c IN :billIds
              AND Status__c =
                    'Allocated'
            FOR UPDATE
        ]) {
            Decimal amount =
                row.Document_Amount__c != null
                    ? row.Document_Amount__c
                    : row.Allocated_Amount__c;

            result.put(
                row.Supplier_Bill__c,
                (
                    result.containsKey(
                        row.Supplier_Bill__c
                    )
                        ? result.get(
                            row.Supplier_Bill__c
                        )
                        : ZERO
                )
                + (
                    amount == null
                        ? ZERO
                        : amount
                )
            );
        }

        return result;
    }

    private static List<ForeignAllocationResult>
        replayAllocationResults(
            Accounting_Payment__c payment,
            List<ForeignAllocationRequest> requests,
            String requestKey
        )
    {
        List<ForeignAllocationResult> results =
            new List<ForeignAllocationResult>();

        for (ForeignAllocationRequest request : requests) {
            Id targetId =
                request.invoiceId != null
                    ? request.invoiceId
                    : request.supplierBillId;

            String allocationKey =
                buildAllocationKey(
                    payment.Id,
                    targetId,
                    requestKey
                );

            List<Payment_Allocation__c> rows = [
                SELECT Id
                FROM Payment_Allocation__c
                WHERE Allocation_Key__c =
                        :allocationKey
                LIMIT 1
            ];

            if (rows.isEmpty()) {
                throw new ForeignCurrencySettlementException(
                    'Allocation replay could not find the original deterministic Payment Allocation.'
                );
            }

            ForeignAllocationResult result =
                buildAllocationResult(
                    rows[0].Id,
                    true
                );

            results.add(
                result
            );
        }

        return results;
    }

    private static ForeignAllocationResult buildAllocationResult(
        Id allocationId,
        Boolean replay
    ) {
        Payment_Allocation__c row = [
            SELECT Id,
                   Invoice__c,
                   Supplier_Bill__c,
                   Payment_Amount__c,
                   Document_Amount__c,
                   Base_Amount__c,
                   Realized_FX_Amount__c,
                   Realized_FX_State__c,
                   Realized_FX_Journal__c,
                   Realized_FX_Accounting_Event__c
            FROM Payment_Allocation__c
            WHERE Id =
                    :allocationId
            LIMIT 1
        ];

        ForeignAllocationResult result =
            new ForeignAllocationResult();

        result.allocationId =
            row.Id;
        result.targetId =
            row.Invoice__c != null
                ? row.Invoice__c
                : row.Supplier_Bill__c;
        result.targetType =
            row.Invoice__c != null
                ? 'Invoice__c'
                : 'Supplier_Bill__c';
        result.paymentAmount =
            row.Payment_Amount__c;
        result.documentAmount =
            row.Document_Amount__c;
        result.baseAmount =
            row.Base_Amount__c;
        result.realizedFXAmount =
            row.Realized_FX_Amount__c;
        result.realizedFXState =
            row.Realized_FX_State__c;
        result.realizedFXJournalId =
            row.Realized_FX_Journal__c;
        result.realizedFXAccountingEventId =
            row.Realized_FX_Accounting_Event__c;
        result.replay =
            replay;

        return result;
    }

    private static ForeignAllocationReversalResult buildReversalReplay(
        Id originalAllocationId
    ) {
        Payment_Allocation__c original = [
            SELECT Id,
                   Status__c,
                   Realized_FX_State__c,
                   Realized_FX_Reversal_Journal__c,
                   Realized_FX_Reversal_Event__c
            FROM Payment_Allocation__c
            WHERE Id =
                    :originalAllocationId
            LIMIT 1
        ];

        List<Payment_Allocation__c> reversalRows = [
            SELECT Id
            FROM Payment_Allocation__c
            WHERE Reversal_Of__c =
                    :originalAllocationId
              AND Status__c =
                    'Reversed'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        if (
            original.Status__c
                != STATE_REVERSED
            || reversalRows.isEmpty()
        ) {
            throw new ForeignCurrencySettlementException(
                'Allocation reversal request was previously processed, but the expected reversal records are missing.'
            );
        }

        ForeignAllocationReversalResult result =
            new ForeignAllocationReversalResult();

        result.originalAllocationId =
            original.Id;
        result.reversalAllocationId =
            reversalRows[0].Id;
        result.originalStatus =
            original.Status__c;
        result.realizedFXState =
            original.Realized_FX_State__c;
        result.realizedFXReversalJournalId =
            original.Realized_FX_Reversal_Journal__c;
        result.realizedFXReversalEventId =
            original.Realized_FX_Reversal_Event__c;
        result.replay =
            true;

        return result;
    }

    private static void validateAllocationRequest(
        ForeignAllocationRequest request,
        Accounting_Payment__c payment
    ) {
        if (request == null) {
            throw new ForeignCurrencySettlementException(
                'Allocation request is required.'
            );
        }

        if (
            (
                request.invoiceId == null
            )
            == (
                request.supplierBillId == null
            )
        ) {
            throw new ForeignCurrencySettlementException(
                'Exactly one allocation target, Invoice or Supplier Bill, is required.'
            );
        }

        normalizePositiveAmount(
            request.amount
        );

        if (
            payment.Direction__c
                == DIRECTION_RECEIPT
            && request.invoiceId == null
        ) {
            throw new ForeignCurrencySettlementException(
                'Foreign-currency Receipt allocations may target Invoices only.'
            );
        }

        if (
            payment.Direction__c
                == DIRECTION_DISBURSEMENT
            && request.supplierBillId == null
        ) {
            throw new ForeignCurrencySettlementException(
                'Foreign-currency Disbursement allocations may target Supplier Bills only.'
            );
        }
    }

    private static Decimal effectivePaymentAmount(
        Payment_Allocation__c row
    ) {
        Decimal amount =
            row.Payment_Amount__c != null
                ? row.Payment_Amount__c
                : row.Allocated_Amount__c;

        return amount == null
            ? ZERO
            : amount;
    }

    private static String buildAllocationKey(
        Id paymentId,
        Id targetId,
        String requestKey
    ) {
        return 'FCY|'
            + digest(
                String.valueOf(
                    paymentId
                )
                + '|'
                + String.valueOf(
                    targetId
                )
                + '|'
                + requestKey.trim()
            );
    }

    private static PaymentLifecycleResult resolveSucceededPaymentReplay(
        Accounting_Payment__c payment
    ) {
        if (payment.Accounting_Event__c == null) {
            throw new ForeignCurrencySettlementException(
                'Succeeded foreign-currency Payment is missing its Accounting Event.'
            );
        }

        Accounting_Event__c eventRecord = [
            SELECT Id,
                   Company__c,
                   Event_Type__c,
                   Source_Type__c,
                   Source_Record_Id__c,
                   State__c,
                   Journal_Entry__c,
                   Journal_Entry__r.Status__c,
                   Journal_Entry__r.Entry_Type__c
            FROM Accounting_Event__c
            WHERE Id =
                    :payment.Accounting_Event__c
            LIMIT 1
        ];

        String expectedEvent =
            payment.Direction__c
                == DIRECTION_RECEIPT
                ? 'Payment Receipt'
                : 'Payment Disbursement';

        if (
            eventRecord.Company__c
                != payment.Company__c
            || eventRecord.Event_Type__c
                != expectedEvent
            || eventRecord.Source_Type__c
                != SOURCE_TYPE
            || eventRecord.Source_Record_Id__c
                != String.valueOf(
                    payment.Id
                )
            || eventRecord.State__c
                != 'Posted'
            || eventRecord.Journal_Entry__c
                == null
            || eventRecord.Journal_Entry__r.Status__c
                != 'Posted'
            || eventRecord.Journal_Entry__r.Entry_Type__c
                != 'Subledger'
        ) {
            throw new ForeignCurrencySettlementException(
                'Succeeded foreign-currency Payment Accounting Event is inconsistent.'
            );
        }

        PaymentLifecycleResult result =
            lifecycleResult(
                payment.Id,
                null,
                STATE_SUCCEEDED,
                true
            );

        result.exchangeRate =
            payment.Exchange_Rate__c;
        result.exchangeRateRecordId =
            payment.Exchange_Rate_Record__c;
        result.accountingEventId =
            eventRecord.Id;
        result.journalEntryId =
            eventRecord.Journal_Entry__c;

        return result;
    }

    private static PaymentLifecycleResult replayLifecycle(
        Id paymentId,
        String expectedAction,
        String expectedState,
        Business_Action__c prior
    ) {
        if (
            prior.Action__c
                != expectedAction
            || prior.Source_Type__c
                != SOURCE_TYPE
            || prior.Source_Record_Id__c
                != String.valueOf(
                    paymentId
                )
        ) {
            throw new ForeignCurrencySettlementException(
                'Request Key was already used for another financial action.'
            );
        }

        Accounting_Payment__c payment =
            loadPayment(
                paymentId,
                false
            );

        if (
            payment.Processing_State__c
                != expectedState
        ) {
            throw new ForeignCurrencySettlementException(
                'Request Key was already processed, but the Payment is no longer in the expected state.'
            );
        }

        PaymentLifecycleResult result =
            lifecycleResult(
                payment.Id,
                null,
                expectedState,
                true
            );

        result.exchangeRate =
            payment.Exchange_Rate__c;
        result.exchangeRateRecordId =
            payment.Exchange_Rate_Record__c;

        return result;
    }

    private static String expectedAuthorizeAction(
        Id paymentId
    ) {
        return 'FOREIGN_CURRENCY_PAYMENT_AUTHORIZED';
    }

    private static String expectedSubmitAction(
        Id paymentId
    ) {
        return 'FOREIGN_CURRENCY_PAYMENT_SUBMITTED';
    }

    private static PaymentLifecycleResult lifecycleResult(
        Id paymentId,
        String previousState,
        String newState,
        Boolean replay
    ) {
        PaymentLifecycleResult result =
            new PaymentLifecycleResult();

        result.paymentId =
            paymentId;
        result.previousState =
            previousState;
        result.newState =
            newState;
        result.replay =
            replay;

        return result;
    }

    private static Business_Action__c findPriorAction(
        String requestKey
    ) {
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

        return actions.isEmpty()
            ? null
            : actions[0];
    }

    private static void createAction(
        Id companyId,
        String sourceType,
        Id sourceRecordId,
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
                requestKey.trim(),
            Source_Type__c =
                sourceType,
            Source_Record_Id__c =
                String.valueOf(
                    sourceRecordId
                ),
            Source_Version__c =
                1
        );
    }

    private static void controlledPaymentUpdate(
        Accounting_Payment__c payment
    ) {
        SABAccountingPaymentMutationContext.beginMutation();

        try {
            update payment;
        } finally {
            SABAccountingPaymentMutationContext.endMutation();
        }
    }

    private static void assertForeignPermission() {
        SABPermissionService.assertPermission(
            PERMISSION,
            'You do not have permission to process foreign-currency settlements.'
        );
    }

    private static void validateRequestKey(
        String requestKey
    ) {
        if (String.isBlank(requestKey)) {
            throw new ForeignCurrencySettlementException(
                'Request Key is required.'
            );
        }

        Integer maxLength =
            Business_Action__c.Request_Key__c
                .getDescribe()
                .getLength();

        if (
            requestKey.trim().length()
                > maxLength
        ) {
            throw new ForeignCurrencySettlementException(
                'Request Key cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static Decimal normalizePositiveAmount(
        Decimal amount
    ) {
        if (
            amount == null
            || amount <= ZERO
        ) {
            throw new ForeignCurrencySettlementException(
                'Allocation Amount must be greater than zero.'
            );
        }

        Decimal normalized =
            SABMoneyService.normalizeTransactionAmount(
                amount,
                RoundingMode.HALF_UP
            );

        if (normalized <= ZERO) {
            throw new ForeignCurrencySettlementException(
                'Allocation Amount rounds to zero.'
            );
        }

        return normalized;
    }

    private static Decimal safeAmount(
        Decimal value
    ) {
        return value == null
            ? ZERO
            : value;
    }

    private static String sourceBusinessKey(
        Accounting_Payment__c payment
    ) {
        if (!String.isBlank(payment.Provider_Request_Key__c)) {
            return truncate(
                payment.Provider_Request_Key__c.trim(),
                Accounting_Event__c.Source_Business_Key__c
                    .getDescribe()
                    .getLength()
            );
        }

        if (!String.isBlank(payment.Reference__c)) {
            return truncate(
                payment.Reference__c.trim(),
                Accounting_Event__c.Source_Business_Key__c
                    .getDescribe()
                    .getLength()
            );
        }

        return String.valueOf(
            payment.Id
        );
    }

    private static String buildDescription(
        Accounting_Payment__c payment
    ) {
        String prefix =
            payment.Direction__c
                == DIRECTION_RECEIPT
                ? 'Foreign Currency Customer Receipt - '
                : 'Foreign Currency Supplier Payment - ';

        return prefix
            + (
                String.isBlank(
                    payment.Reference__c
                )
                    ? payment.Name
                    : payment.Reference__c.trim()
            );
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

    private static String truncate(
        String value,
        Integer maxLength
    ) {
        if (
            value == null
            || maxLength <= 0
            || value.length()
                <= maxLength
        ) {
            return value;
        }

        return value.substring(
            0,
            maxLength
        );
    }
}
