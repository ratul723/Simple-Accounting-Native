/**
 * G7C - Realized FX Settlement Foundation.
 *
 * Processes a foreign-currency Payment_Allocation__c after settlement:
 *
 * Historical carrying base:
 *     allocated document amount x document historical rate
 *
 * Settlement base:
 *     allocated payment amount x settlement/payment rate
 *
 * Realized FX sign convention:
 *     positive = realized gain
 *     negative = realized loss
 *
 * For both AR and AP, a positive realized amount debits the source control
 * account and credits Realized FX Gain. A negative amount debits Realized FX
 * Loss and credits the source control account.
 *
 * Scope boundary:
 * - same foreign transaction currency on document, payment and allocation
 * - company functional currency is the same on document/payment/company
 * - source document is Posted
 * - payment is Succeeded
 * - allocation is active Allocated
 *
 * Existing G3C/G4B lifecycle services still intentionally block creating
 * foreign-currency payments through their normal public flows. This service
 * establishes the calculation/posting contract first; a later integration
 * slice can safely enable those lifecycles without weakening existing controls.
 */
public without sharing class SABRealizedFXSettlementService {

    public class RealizedFXException extends Exception {}

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    private static final Decimal RATE_TOLERANCE =
        Decimal.valueOf('0.000001');

    private static final Decimal AMOUNT_TOLERANCE =
        Decimal.valueOf('0.0001');

    private static final String PERMISSION =
        'SAB_Post_Realized_FX';

    private static final String SOURCE_TYPE =
        'Payment_Allocation__c';

    private static final String ACTION_NAME =
        'Realized FX Settlement Processed';

    private static final String EVENT_TYPE =
        'Realized FX Settlement';

    @TestVisible
    private static Boolean mutationInProgress =
        false;

    public class SettlementResult {
        @AuraEnabled public Id allocationId { get; private set; }
        @AuraEnabled public String state { get; private set; }
        @AuraEnabled public String sourceType { get; private set; }
        @AuraEnabled public Id sourceRecordId { get; private set; }
        @AuraEnabled public Id sourceGLAccountId { get; private set; }
        @AuraEnabled public Decimal historicalCarryingBase { get; private set; }
        @AuraEnabled public Decimal settlementBaseAmount { get; private set; }
        @AuraEnabled public Decimal realizedFXAmount { get; private set; }
        @AuraEnabled public Id journalEntryId { get; private set; }
        @AuraEnabled public Id accountingEventId { get; private set; }
        @AuraEnabled public Id reversalJournalEntryId { get; private set; }
        @AuraEnabled public Id reversalAccountingEventId { get; private set; }
        @AuraEnabled public Datetime reversedAt { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private SettlementResult() {}
    }

    private class SettlementContext {
        Payment_Allocation__c allocation;
        Accounting_Company__c company;
        Accounting_Period__c period;
        String sourceType;
        Id sourceRecordId;
        Id sourceGLAccountId;
        String transactionCurrency;
        String functionalCurrency;
        Decimal documentAmount;
        Decimal paymentAmount;
        Decimal historicalRate;
        Decimal settlementRate;
        Decimal historicalBase;
        Decimal settlementBase;
        Decimal realizedAmount;
    }

    public static Boolean isMutationInProgress() {
        return mutationInProgress;
    }

    @AuraEnabled
    public static SettlementResult processAllocation(
        Id allocationId,
        String requestKey,
        String reason
    ) {
        SABPermissionService.assertPermission(
            PERMISSION,
            'You do not have permission to post Realized FX settlement adjustments.'
        );

        validateRequestKey(
            requestKey
        );

        SettlementResult replay =
            findReplay(
                allocationId,
                requestKey
            );

        if (replay != null) {
            return replay;
        }

        Savepoint sp =
            Database.setSavepoint();

        try {
            Payment_Allocation__c allocation =
                lockAllocation(
                    allocationId
                );

            Id companyId =
                allocation.Company__c != null
                    ? allocation.Company__c
                    : allocation.Payment__r.Company__c;

            SABCompanyAccessService.assertCompanyAccess(
                companyId
            );

            if (
                !String.isBlank(
                    allocation.Realized_FX_State__c
                )
                && allocation.Realized_FX_State__c
                    != 'None'
            ) {
                throw new RealizedFXException(
                    'Payment Allocation already has a realized FX processing result.'
                );
            }

            SettlementContext context =
                buildContext(
                    allocation,
                    companyId
                );

            mutationInProgress =
                true;

            try {
                allocation.Historical_Carrying_Base__c =
                    context.historicalBase;
                allocation.Settlement_Base_Amount__c =
                    context.settlementBase;
                allocation.Realized_FX_Amount__c =
                    context.realizedAmount;
                allocation.Realized_FX_Source_GL_Account__c =
                    context.sourceGLAccountId;
            } finally {
                mutationInProgress =
                    false;
            }

            if (context.realizedAmount == ZERO) {
                mutationInProgress =
                    true;

                try {
                    allocation.Realized_FX_State__c =
                        'Calculated';
                    update allocation;
                } finally {
                    mutationInProgress =
                        false;
                }

                logAction(
                    context,
                    requestKey,
                    reason
                );

                return buildResult(
                    allocation.Id,
                    false
                );
            }

            validateRealizedFXAccounts(
                context.company
            );

            Journal_Entry__c journal =
                new Journal_Entry__c(
                    Company__c =
                        context.company.Id,
                    Accounting_Period__c =
                        context.period.Id,
                    Accounting_Date__c =
                        context.allocation.Effective_Date__c,
                    Entry_Type__c =
                        'Subledger',
                    Status__c =
                        'Draft',
                    Description__c =
                        truncate(
                            'Realized FX settlement - '
                            + context.sourceType
                            + ' '
                            + String.valueOf(
                                context.sourceRecordId
                            ),
                            Journal_Entry__c.Description__c
                                .getDescribe()
                                .getLength()
                        ),
                    Version__c =
                        1
                );

            insert journal;

            insert buildJournalLines(
                journal.Id,
                context
            );

            String identity =
                digest(
                    String.valueOf(
                        allocation.Id
                    )
                    + '|'
                    + decimalText(
                        context.historicalBase
                    )
                    + '|'
                    + decimalText(
                        context.settlementBase
                    )
                    + '|'
                    + decimalText(
                        context.realizedAmount
                    )
                );

            SABAccountingEventService.ReservationRequest eventRequest =
                new SABAccountingEventService.ReservationRequest();

            eventRequest.companyId =
                context.company.Id;
            eventRequest.adapterKey =
                'REALIZED_FX';
            eventRequest.requestKey =
                requestKey.trim();
            eventRequest.eventKey =
                'RFX-EVENT-'
                + identity;
            eventRequest.eventType =
                EVENT_TYPE;
            eventRequest.sourceBusinessKey =
                truncate(
                    String.isBlank(
                        allocation.Allocation_Key__c
                    )
                        ? String.valueOf(
                            allocation.Id
                        )
                        : allocation.Allocation_Key__c,
                    Accounting_Event__c.Source_Business_Key__c
                        .getDescribe()
                        .getLength()
                );
            eventRequest.sourceRecordId =
                String.valueOf(
                    allocation.Id
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
                'RFX-POST-'
                + identity;
            postingRequest.eventRequest =
                eventRequest;

            SABPostingService.PostingResult postingResult =
                SABPostingService.postDraftJournal(
                    postingRequest
                );

            mutationInProgress =
                true;

            try {
                allocation.Realized_FX_State__c =
                    'Posted';
                allocation.Realized_FX_Journal__c =
                    postingResult.journalEntryId;
                allocation.Realized_FX_Accounting_Event__c =
                    postingResult.accountingEventId;

                update allocation;
            } finally {
                mutationInProgress =
                    false;
            }

            logAction(
                context,
                requestKey,
                reason
            );

            return buildResult(
                allocation.Id,
                false
            );
        } catch (Exception ex) {
            Database.rollback(
                sp
            );
            throw ex;
        }
    }

    private static SettlementContext buildContext(
        Payment_Allocation__c allocation,
        Id companyId
    ) {
        if (allocation.Status__c != 'Allocated') {
            throw new RealizedFXException(
                'Only an active Allocated Payment Allocation can be processed for realized FX.'
            );
        }

        if (
            allocation.Payment__c == null
            || allocation.Payment__r == null
        ) {
            throw new RealizedFXException(
                'Payment Allocation must reference a Payment.'
            );
        }

        if (
            allocation.Payment__r.Company__c
                != companyId
            || (
                allocation.Company__c != null
                && allocation.Company__c
                    != companyId
            )
        ) {
            throw new RealizedFXException(
                'Payment Allocation and Payment must belong to the same Accounting Company.'
            );
        }

        if (
            allocation.Payment__r.Processing_State__c
                != 'Succeeded'
        ) {
            throw new RealizedFXException(
                'Realized FX requires a Succeeded Payment.'
            );
        }

        Boolean isInvoice =
            allocation.Invoice__c != null;

        Boolean isBill =
            allocation.Supplier_Bill__c != null;

        if (isInvoice == isBill) {
            throw new RealizedFXException(
                'Realized FX requires exactly one settlement target: Invoice or Supplier Bill.'
            );
        }

        Accounting_Company__c company = [
            SELECT Id,
                   Functional_Currency__c,
                   Realized_FX_Gain_Account__c,
                   Realized_FX_Loss_Account__c
            FROM Accounting_Company__c
            WHERE Id = :companyId
            LIMIT 1
        ];

        String companyCurrency =
            SABMoneyService.normalizeCurrencyCode(
                company.Functional_Currency__c
            );

        String paymentCurrency =
            SABMoneyService.normalizeCurrencyCode(
                allocation.Payment__r.Transaction_Currency__c
            );

        String paymentFunctionalCurrency =
            SABMoneyService.normalizeCurrencyCode(
                allocation.Payment__r.Functional_Currency__c
            );

        String allocationCurrency =
            SABMoneyService.normalizeCurrencyCode(
                allocation.Transaction_Currency__c
            );

        if (
            paymentFunctionalCurrency
                != companyCurrency
        ) {
            throw new RealizedFXException(
                'Payment Functional Currency must match the Accounting Company Functional Currency.'
            );
        }

        if (
            paymentCurrency
                != allocationCurrency
        ) {
            throw new RealizedFXException(
                'G7C settlement foundation requires Payment and Allocation to use the same transaction currency.'
            );
        }

        if (paymentCurrency == companyCurrency) {
            throw new RealizedFXException(
                'Realized FX settlement applies only to foreign-currency allocations.'
            );
        }

        Decimal paymentAmount =
            positiveAmount(
                allocation.Payment_Amount__c != null
                    ? allocation.Payment_Amount__c
                    : allocation.Allocated_Amount__c,
                'Payment Amount'
            );

        Decimal documentAmount =
            positiveAmount(
                allocation.Document_Amount__c != null
                    ? allocation.Document_Amount__c
                    : allocation.Allocated_Amount__c,
                'Document Amount'
            );

        if (
            (
                paymentAmount
                - documentAmount
            ).abs()
                > AMOUNT_TOLERANCE
        ) {
            throw new RealizedFXException(
                'G7C settlement foundation requires Payment Amount and Document Amount to be equal in the same foreign currency. Cross-currency settlement is deferred.'
            );
        }

        Decimal paymentRate =
            positiveRate(
                allocation.Payment__r.Exchange_Rate__c,
                'Payment Exchange Rate'
            );

        Decimal settlementRate =
            allocation.Exchange_Rate__c == null
                ? paymentRate
                : positiveRate(
                    allocation.Exchange_Rate__c,
                    'Allocation Exchange Rate'
                );

        if (
            (
                settlementRate
                - paymentRate
            ).abs()
                > RATE_TOLERANCE
        ) {
            throw new RealizedFXException(
                'Allocation Exchange Rate must match the Payment settlement Exchange Rate in G7C.'
            );
        }

        Date effectiveDate =
            allocation.Effective_Date__c != null
                ? allocation.Effective_Date__c
                : allocation.Payment__r.Effective_Date__c;

        if (effectiveDate == null) {
            throw new RealizedFXException(
                'Settlement Effective Date is required.'
            );
        }

        SettlementContext context =
            new SettlementContext();

        context.allocation =
            allocation;
        context.company =
            company;
        context.transactionCurrency =
            paymentCurrency;
        context.functionalCurrency =
            companyCurrency;
        context.documentAmount =
            documentAmount;
        context.paymentAmount =
            paymentAmount;
        context.settlementRate =
            settlementRate;

        if (isInvoice) {
            validateInvoiceContext(
                context,
                allocation,
                companyId
            );
        } else {
            validateBillContext(
                context,
                allocation,
                companyId
            );
        }

        SABMoneyService.ConversionResult historical =
            SABMoneyService.convertToFunctional(
                documentAmount,
                context.transactionCurrency,
                context.functionalCurrency,
                context.historicalRate,
                RoundingMode.HALF_UP
            );

        SABMoneyService.ConversionResult settlement =
            SABMoneyService.convertToFunctional(
                paymentAmount,
                context.transactionCurrency,
                context.functionalCurrency,
                context.settlementRate,
                RoundingMode.HALF_UP
            );

        context.historicalBase =
            SABMoneyService.normalizeLedgerAmount(
                historical.functionalAmount,
                RoundingMode.HALF_UP
            );

        context.settlementBase =
            SABMoneyService.normalizeLedgerAmount(
                settlement.functionalAmount,
                RoundingMode.HALF_UP
            );

        if (
            allocation.Base_Amount__c != null
        ) {
            Decimal existingBase =
                SABMoneyService.normalizeLedgerAmount(
                    allocation.Base_Amount__c,
                    RoundingMode.HALF_UP
                );

            if (
                (
                    existingBase
                    - context.settlementBase
                ).abs()
                    > AMOUNT_TOLERANCE
            ) {
                throw new RealizedFXException(
                    'Payment Allocation Base Amount does not match the settlement-rate functional amount.'
                );
            }
        }

        if (context.sourceType == 'Invoice__c') {
            // AR: cash/settlement base - historical AR carrying base.
            context.realizedAmount =
                SABMoneyService.normalizeLedgerAmount(
                    context.settlementBase
                    - context.historicalBase,
                    RoundingMode.HALF_UP
                );
        } else {
            // AP: historical AP carrying base - cash/settlement base.
            context.realizedAmount =
                SABMoneyService.normalizeLedgerAmount(
                    context.historicalBase
                    - context.settlementBase,
                    RoundingMode.HALF_UP
                );
        }

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
                    :effectiveDate
              AND End_Date__c >=
                    :effectiveDate
            LIMIT 2
        ];

        if (periods.size() != 1) {
            throw new RealizedFXException(
                'Realized FX settlement requires exactly one Accounting Period containing the settlement Effective Date.'
            );
        }

        context.period =
            periods[0];

        if (context.period.Status__c != 'Open') {
            throw new RealizedFXException(
                'Realized FX settlement requires an Open Accounting Period.'
            );
        }

        // Normalize the date used by the posting journal.
        context.allocation.Effective_Date__c =
            effectiveDate;

        return context;
    }

    private static void validateInvoiceContext(
        SettlementContext context,
        Payment_Allocation__c allocation,
        Id companyId
    ) {
        Invoice__c invoice =
            allocation.Invoice__r;

        if (
            invoice == null
            || invoice.Company__c
                != companyId
            || invoice.Document_Type__c
                != 'Invoice'
            || invoice.Status__c
                != 'Posted'
        ) {
            throw new RealizedFXException(
                'Realized FX Invoice target must be a Posted Invoice in the same Accounting Company.'
            );
        }

        if (
            allocation.Payment__r.Direction__c
                != 'Receipt'
        ) {
            throw new RealizedFXException(
                'Invoice realized FX settlement requires a Receipt Payment.'
            );
        }

        if (
            allocation.Payment__r.Party_Profile__c
                != invoice.Party_Profile__c
        ) {
            throw new RealizedFXException(
                'Receipt Party Accounting Profile must match the Invoice Party Accounting Profile.'
            );
        }

        String documentCurrency =
            SABMoneyService.normalizeCurrencyCode(
                invoice.Transaction_Currency__c
            );

        String documentFunctional =
            SABMoneyService.normalizeCurrencyCode(
                invoice.Functional_Currency__c
            );

        if (
            documentCurrency
                != context.transactionCurrency
            || documentFunctional
                != context.functionalCurrency
        ) {
            throw new RealizedFXException(
                'Invoice currency snapshot must match the Payment Allocation currency scope.'
            );
        }

        context.historicalRate =
            positiveRate(
                invoice.Exchange_Rate__c,
                'Invoice Historical Exchange Rate'
            );

        if (
            invoice.Party_Profile__r == null
            || invoice.Party_Profile__r.AR_Control_Account__c
                == null
            || invoice.Party_Profile__r.AR_Control_Account__r
                == null
            || invoice.Party_Profile__r.AR_Control_Account__r.Company__c
                != companyId
            || invoice.Party_Profile__r.AR_Control_Account__r.Is_Active__c
                != true
            || invoice.Party_Profile__r.AR_Control_Account__r.Is_Control_Account__c
                != true
            || invoice.Party_Profile__r.AR_Control_Account__r.Control_Type__c
                != 'AR'
        ) {
            throw new RealizedFXException(
                'Invoice requires an active AR control account in the same Accounting Company.'
            );
        }

        context.sourceType =
            'Invoice__c';
        context.sourceRecordId =
            invoice.Id;
        context.sourceGLAccountId =
            invoice.Party_Profile__r.AR_Control_Account__c;
    }

    private static void validateBillContext(
        SettlementContext context,
        Payment_Allocation__c allocation,
        Id companyId
    ) {
        Supplier_Bill__c bill =
            allocation.Supplier_Bill__r;

        if (
            bill == null
            || bill.Company__c
                != companyId
            || bill.Document_Type__c
                != 'Bill'
            || bill.Status__c
                != 'Posted'
        ) {
            throw new RealizedFXException(
                'Realized FX Supplier Bill target must be a Posted Bill in the same Accounting Company.'
            );
        }

        if (
            allocation.Payment__r.Direction__c
                != 'Disbursement'
        ) {
            throw new RealizedFXException(
                'Supplier Bill realized FX settlement requires a Disbursement Payment.'
            );
        }

        if (
            allocation.Payment__r.Party_Profile__c
                != bill.Supplier_Profile__c
        ) {
            throw new RealizedFXException(
                'Disbursement Party Accounting Profile must match the Supplier Bill profile.'
            );
        }

        String documentCurrency =
            SABMoneyService.normalizeCurrencyCode(
                bill.Transaction_Currency__c
            );

        String documentFunctional =
            SABMoneyService.normalizeCurrencyCode(
                bill.Functional_Currency__c
            );

        if (
            documentCurrency
                != context.transactionCurrency
            || documentFunctional
                != context.functionalCurrency
        ) {
            throw new RealizedFXException(
                'Supplier Bill currency snapshot must match the Payment Allocation currency scope.'
            );
        }

        context.historicalRate =
            positiveRate(
                bill.Exchange_Rate__c,
                'Supplier Bill Historical Exchange Rate'
            );

        if (
            bill.Supplier_Profile__r == null
            || bill.Supplier_Profile__r.AP_Control_Account__c
                == null
            || bill.Supplier_Profile__r.AP_Control_Account__r
                == null
            || bill.Supplier_Profile__r.AP_Control_Account__r.Company__c
                != companyId
            || bill.Supplier_Profile__r.AP_Control_Account__r.Is_Active__c
                != true
            || bill.Supplier_Profile__r.AP_Control_Account__r.Is_Control_Account__c
                != true
            || bill.Supplier_Profile__r.AP_Control_Account__r.Control_Type__c
                != 'AP'
        ) {
            throw new RealizedFXException(
                'Supplier Bill requires an active AP control account in the same Accounting Company.'
            );
        }

        context.sourceType =
            'Supplier_Bill__c';
        context.sourceRecordId =
            bill.Id;
        context.sourceGLAccountId =
            bill.Supplier_Profile__r.AP_Control_Account__c;
    }

    private static void validateRealizedFXAccounts(
        Accounting_Company__c company
    ) {
        if (
            company.Realized_FX_Gain_Account__c
                == null
            || company.Realized_FX_Loss_Account__c
                == null
        ) {
            throw new RealizedFXException(
                'Accounting Company requires both Realized FX Gain and Realized FX Loss accounts before posting.'
            );
        }

        if (
            company.Realized_FX_Gain_Account__c
                == company.Realized_FX_Loss_Account__c
        ) {
            throw new RealizedFXException(
                'Realized FX Gain and Realized FX Loss accounts must be different GL Accounts.'
            );
        }

        Map<Id, GL_Account__c> accounts =
            new Map<Id, GL_Account__c>([
                SELECT Id,
                       Company__c,
                       Account_Type__c,
                       Is_Active__c,
                       Is_Control_Account__c
                FROM GL_Account__c
                WHERE Id IN :new Set<Id>{
                    company.Realized_FX_Gain_Account__c,
                    company.Realized_FX_Loss_Account__c
                }
            ]);

        GL_Account__c gain =
            accounts.get(
                company.Realized_FX_Gain_Account__c
            );

        GL_Account__c loss =
            accounts.get(
                company.Realized_FX_Loss_Account__c
            );

        if (
            gain == null
            || gain.Company__c
                != company.Id
            || gain.Is_Active__c
                != true
            || gain.Is_Control_Account__c
                == true
            || gain.Account_Type__c
                != 'Revenue'
        ) {
            throw new RealizedFXException(
                'Realized FX Gain Account must be an active non-control Revenue account in the Accounting Company.'
            );
        }

        if (
            loss == null
            || loss.Company__c
                != company.Id
            || loss.Is_Active__c
                != true
            || loss.Is_Control_Account__c
                == true
            || loss.Account_Type__c
                != 'Expense'
        ) {
            throw new RealizedFXException(
                'Realized FX Loss Account must be an active non-control Expense account in the Accounting Company.'
            );
        }
    }

    private static List<Journal_Entry_Line__c>
        buildJournalLines(
            Id journalId,
            SettlementContext context
        )
    {
        Decimal magnitude =
            context.realizedAmount.abs();

        Boolean isGain =
            context.realizedAmount > ZERO;

        Journal_Entry_Line__c controlLine =
            new Journal_Entry_Line__c(
                Journal_Entry__c =
                    journalId,
                Line_Number__c =
                    1,
                GL_Account__c =
                    context.sourceGLAccountId,
                Debit_Base__c =
                    isGain
                        ? magnitude
                        : ZERO,
                Credit_Base__c =
                    isGain
                        ? ZERO
                        : magnitude,
                Functional_Currency__c =
                    context.functionalCurrency,
                Explanation__c =
                    truncate(
                        'Realized FX settlement adjustment - '
                        + context.sourceType
                        + ' '
                        + String.valueOf(
                            context.sourceRecordId
                        ),
                        Journal_Entry_Line__c.Explanation__c
                            .getDescribe()
                            .getLength()
                    ),
                Source_Line_Key__c =
                    truncate(
                        'RFX:CONTROL:'
                        + String.valueOf(
                            context.allocation.Id
                        ),
                        Journal_Entry_Line__c.Source_Line_Key__c
                            .getDescribe()
                            .getLength()
                    )
            );

        Id counterpartAccountId =
            isGain
                ? context.company.Realized_FX_Gain_Account__c
                : context.company.Realized_FX_Loss_Account__c;

        Journal_Entry_Line__c counterpartLine =
            new Journal_Entry_Line__c(
                Journal_Entry__c =
                    journalId,
                Line_Number__c =
                    2,
                GL_Account__c =
                    counterpartAccountId,
                Debit_Base__c =
                    isGain
                        ? ZERO
                        : magnitude,
                Credit_Base__c =
                    isGain
                        ? magnitude
                        : ZERO,
                Functional_Currency__c =
                    context.functionalCurrency,
                Explanation__c =
                    isGain
                        ? 'Realized FX gain'
                        : 'Realized FX loss',
                Source_Line_Key__c =
                    isGain
                        ? 'RFX:GAIN'
                        : 'RFX:LOSS'
            );

        return new List<Journal_Entry_Line__c>{
            controlLine,
            counterpartLine
        };
    }

    private static Payment_Allocation__c lockAllocation(
        Id allocationId
    ) {
        if (allocationId == null) {
            throw new RealizedFXException(
                'Payment Allocation Id is required.'
            );
        }

        return [
            SELECT Id,
                   Allocation_Key__c,
                   Company__c,
                   Payment__c,
                   Payment__r.Company__c,
                   Payment__r.Party_Profile__c,
                   Payment__r.Direction__c,
                   Payment__r.Processing_State__c,
                   Payment__r.Transaction_Currency__c,
                   Payment__r.Functional_Currency__c,
                   Payment__r.Exchange_Rate__c,
                   Payment__r.Effective_Date__c,
                   Invoice__c,
                   Invoice__r.Company__c,
                   Invoice__r.Party_Profile__c,
                   Invoice__r.Document_Type__c,
                   Invoice__r.Status__c,
                   Invoice__r.Transaction_Currency__c,
                   Invoice__r.Functional_Currency__c,
                   Invoice__r.Exchange_Rate__c,
                   Invoice__r.Party_Profile__r.AR_Control_Account__c,
                   Invoice__r.Party_Profile__r.AR_Control_Account__r.Company__c,
                   Invoice__r.Party_Profile__r.AR_Control_Account__r.Is_Active__c,
                   Invoice__r.Party_Profile__r.AR_Control_Account__r.Is_Control_Account__c,
                   Invoice__r.Party_Profile__r.AR_Control_Account__r.Control_Type__c,
                   Supplier_Bill__c,
                   Supplier_Bill__r.Company__c,
                   Supplier_Bill__r.Supplier_Profile__c,
                   Supplier_Bill__r.Document_Type__c,
                   Supplier_Bill__r.Status__c,
                   Supplier_Bill__r.Transaction_Currency__c,
                   Supplier_Bill__r.Functional_Currency__c,
                   Supplier_Bill__r.Exchange_Rate__c,
                   Supplier_Bill__r.Supplier_Profile__r.AP_Control_Account__c,
                   Supplier_Bill__r.Supplier_Profile__r.AP_Control_Account__r.Company__c,
                   Supplier_Bill__r.Supplier_Profile__r.AP_Control_Account__r.Is_Active__c,
                   Supplier_Bill__r.Supplier_Profile__r.AP_Control_Account__r.Is_Control_Account__c,
                   Supplier_Bill__r.Supplier_Profile__r.AP_Control_Account__r.Control_Type__c,
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
            WHERE Id = :allocationId
            LIMIT 1
            FOR UPDATE
        ];
    }

    private static SettlementResult findReplay(
        Id allocationId,
        String requestKey
    ) {
        if (
            allocationId == null
            || String.isBlank(
                requestKey
            )
        ) {
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
                != ACTION_NAME
            || action.Source_Type__c
                != SOURCE_TYPE
            || action.Source_Record_Id__c
                != String.valueOf(
                    allocationId
                )
        ) {
            throw new RealizedFXException(
                'Request Key was already used for a different financial action.'
            );
        }

        SettlementResult result =
            buildResult(
                allocationId,
                true
            );

        if (
            result.state != 'Posted'
            && result.state != 'Calculated'
        ) {
            throw new RealizedFXException(
                'Realized FX request was previously processed, but the Payment Allocation is not in the expected state.'
            );
        }

        return result;
    }

    private static void logAction(
        SettlementContext context,
        String requestKey,
        String reason
    ) {
        insert new Business_Action__c(
            Company__c =
                context.company.Id,
            Action__c =
                ACTION_NAME,
            Actor__c =
                UserInfo.getUserId(),
            Action_At__c =
                System.now(),
            Reason__c =
                reason,
            Request_Key__c =
                requestKey.trim(),
            Source_Type__c =
                SOURCE_TYPE,
            Source_Record_Id__c =
                String.valueOf(
                    context.allocation.Id
                ),
            Source_Version__c =
                1
        );
    }

    private static SettlementResult buildResult(
        Id allocationId,
        Boolean replay
    ) {
        Payment_Allocation__c allocation = [
            SELECT Id,
                   Invoice__c,
                   Supplier_Bill__c,
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
            WHERE Id = :allocationId
            LIMIT 1
        ];

        SettlementResult result =
            new SettlementResult();

        result.allocationId =
            allocation.Id;
        result.state =
            allocation.Realized_FX_State__c;
        result.sourceType =
            allocation.Invoice__c != null
                ? 'Invoice__c'
                : 'Supplier_Bill__c';
        result.sourceRecordId =
            allocation.Invoice__c != null
                ? allocation.Invoice__c
                : allocation.Supplier_Bill__c;
        result.sourceGLAccountId =
            allocation.Realized_FX_Source_GL_Account__c;
        result.historicalCarryingBase =
            allocation.Historical_Carrying_Base__c;
        result.settlementBaseAmount =
            allocation.Settlement_Base_Amount__c;
        result.realizedFXAmount =
            allocation.Realized_FX_Amount__c;
        result.journalEntryId =
            allocation.Realized_FX_Journal__c;
        result.accountingEventId =
            allocation.Realized_FX_Accounting_Event__c;
        result.reversalJournalEntryId =
            allocation.Realized_FX_Reversal_Journal__c;
        result.reversalAccountingEventId =
            allocation.Realized_FX_Reversal_Event__c;
        result.reversedAt =
            allocation.Realized_FX_Reversed_At__c;
        result.replay =
            replay;

        return result;
    }

    /**
     * G7D integration hook.
     *
     * Reverses a previously posted realized-FX settlement journal before the
     * owning Payment Allocation itself is reversed.
     *
     * Calculated zero-difference allocations have no journal; they are simply
     * moved to Realized_FX_State__c = Reversed.
     */
    @AuraEnabled
    public static SettlementResult reverseSettlement(
        Id allocationId,
        Date reversalDate,
        String requestKey,
        String reason
    ) {
        SABPermissionService.assertPermission(
            'SAB_Reverse_Realized_FX',
            'You do not have permission to reverse Realized FX settlements.'
        );

        validateRequestKey(
            requestKey
        );

        if (reversalDate == null) {
            throw new RealizedFXException(
                'Realized FX reversal date is required.'
            );
        }

        if (String.isBlank(reason)) {
            throw new RealizedFXException(
                'Realized FX reversal reason is required.'
            );
        }

        SettlementResult replay =
            findReversalReplay(
                allocationId,
                requestKey
            );

        if (replay != null) {
            return replay;
        }

        Savepoint sp =
            Database.setSavepoint();

        try {
            Payment_Allocation__c allocation =
                lockAllocation(
                    allocationId
                );

            Id companyId =
                allocation.Company__c != null
                    ? allocation.Company__c
                    : allocation.Payment__r.Company__c;

            SABCompanyAccessService.assertCompanyAccess(
                companyId
            );

            if (
                allocation.Realized_FX_State__c
                    == 'Calculated'
            ) {
                if (
                    allocation.Realized_FX_Amount__c == null
                    || allocation.Realized_FX_Amount__c != ZERO
                    || allocation.Realized_FX_Journal__c != null
                    || allocation.Realized_FX_Accounting_Event__c != null
                ) {
                    throw new RealizedFXException(
                        'Calculated realized FX allocation has an inconsistent zero-difference snapshot.'
                    );
                }

                mutationInProgress =
                    true;

                try {
                    allocation.Realized_FX_State__c =
                        'Reversed';
                    allocation.Realized_FX_Reversed_At__c =
                        System.now();
                    update allocation;
                } finally {
                    mutationInProgress =
                        false;
                }

                logReversalAction(
                    allocation,
                    companyId,
                    requestKey,
                    reason
                );

                return buildResult(
                    allocation.Id,
                    false
                );
            }

            if (
                allocation.Realized_FX_State__c
                    != 'Posted'
            ) {
                throw new RealizedFXException(
                    'Only Posted or zero-difference Calculated realized FX results can be reversed.'
                );
            }

            if (
                allocation.Realized_FX_Journal__c
                    == null
                || allocation.Realized_FX_Accounting_Event__c
                    == null
            ) {
                throw new RealizedFXException(
                    'Posted realized FX settlement is missing its Journal or Accounting Event reference.'
                );
            }

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
                        :reversalDate
                  AND End_Date__c >=
                        :reversalDate
                LIMIT 2
            ];

            if (periods.size() != 1) {
                throw new RealizedFXException(
                    'Realized FX reversal requires exactly one Accounting Period containing the reversal date.'
                );
            }

            Accounting_Period__c period =
                periods[0];

            if (period.Status__c != 'Open') {
                throw new RealizedFXException(
                    'Realized FX reversal Accounting Period must be Open.'
                );
            }

            String identity =
                digest(
                    String.valueOf(
                        allocation.Id
                    )
                    + '|'
                    + String.valueOf(
                        allocation.Realized_FX_Journal__c
                    )
                    + '|'
                    + String.valueOf(
                        reversalDate
                    )
                );

            SABReversalService.ReversalRequest reversalRequest =
                new SABReversalService.ReversalRequest();

            reversalRequest.originalJournalEntryId =
                allocation.Realized_FX_Journal__c;
            reversalRequest.reversalAccountingPeriodId =
                period.Id;
            reversalRequest.reversalAccountingDate =
                reversalDate;
            reversalRequest.postingKey =
                'RFX-RV-POST-'
                + identity;
            reversalRequest.eventKey =
                'RFX-RV-EVENT-'
                + identity;
            reversalRequest.requestKey =
                'RFX-RV-REQ-'
                + identity;
            reversalRequest.reason =
                reason.trim();

            SABReversalService.ReversalResult reversalResult =
                SABReversalService.reversePostedJournal(
                    reversalRequest
                );

            mutationInProgress =
                true;

            try {
                allocation.Realized_FX_State__c =
                    'Reversed';
                allocation.Realized_FX_Reversal_Journal__c =
                    reversalResult.reversalJournalEntryId;
                allocation.Realized_FX_Reversal_Event__c =
                    reversalResult.reversalAccountingEventId;
                allocation.Realized_FX_Reversed_At__c =
                    System.now();
                update allocation;
            } finally {
                mutationInProgress =
                    false;
            }

            logReversalAction(
                allocation,
                companyId,
                requestKey,
                reason
            );

            return buildResult(
                allocation.Id,
                false
            );
        } catch (Exception ex) {
            Database.rollback(
                sp
            );
            throw ex;
        }
    }

    private static SettlementResult findReversalReplay(
        Id allocationId,
        String requestKey
    ) {
        if (
            allocationId == null
            || String.isBlank(
                requestKey
            )
        ) {
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
                != 'Realized FX Settlement Reversed'
            || action.Source_Type__c
                != SOURCE_TYPE
            || action.Source_Record_Id__c
                != String.valueOf(
                    allocationId
                )
        ) {
            throw new RealizedFXException(
                'Request Key was already used for a different financial action.'
            );
        }

        SettlementResult result =
            buildResult(
                allocationId,
                true
            );

        if (result.state != 'Reversed') {
            throw new RealizedFXException(
                'Realized FX reversal request was previously processed, but the allocation is not in the expected Reversed FX state.'
            );
        }

        return result;
    }

    private static void logReversalAction(
        Payment_Allocation__c allocation,
        Id companyId,
        String requestKey,
        String reason
    ) {
        insert new Business_Action__c(
            Company__c =
                companyId,
            Action__c =
                'Realized FX Settlement Reversed',
            Actor__c =
                UserInfo.getUserId(),
            Action_At__c =
                System.now(),
            Reason__c =
                reason.trim(),
            Request_Key__c =
                requestKey.trim(),
            Source_Type__c =
                SOURCE_TYPE,
            Source_Record_Id__c =
                String.valueOf(
                    allocation.Id
                ),
            Source_Version__c =
                1
        );
    }

    private static Decimal positiveAmount(
        Decimal value,
        String label
    ) {
        if (
            value == null
            || value <= ZERO
        ) {
            throw new RealizedFXException(
                label
                + ' must be greater than zero.'
            );
        }

        Decimal normalized =
            SABMoneyService.normalizeTransactionAmount(
                value,
                RoundingMode.HALF_UP
            );

        if (normalized <= ZERO) {
            throw new RealizedFXException(
                label
                + ' rounds to zero.'
            );
        }

        return normalized;
    }

    private static Decimal positiveRate(
        Decimal value,
        String label
    ) {
        if (
            value == null
            || value <= ZERO
        ) {
            throw new RealizedFXException(
                label
                + ' must be greater than zero.'
            );
        }

        return value;
    }

    private static void validateRequestKey(
        String requestKey
    ) {
        if (String.isBlank(requestKey)) {
            throw new RealizedFXException(
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
            throw new RealizedFXException(
                'Request Key cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static String decimalText(
        Decimal value
    ) {
        Decimal normalized =
            (value == null
                ? ZERO
                : value)
            .setScale(
                4,
                RoundingMode.HALF_UP
            );

        return String.valueOf(
            normalized
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
