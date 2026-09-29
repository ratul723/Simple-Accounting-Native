/**
 * G7E - FX Operations Workspace read/query controller.
 *
 * This class intentionally keeps accounting mutations in the established
 * G7A-G7D domain services. The LWC calls those services directly for:
 * - FX preview / approval / posting / reversal
 * - foreign-currency payment lifecycle
 * - foreign-currency allocation / allocation reversal
 *
 * This controller only provides company-scoped operational read models and
 * eligible settlement targets for the workspace.
 */
public with sharing class SABFXOperationsWorkspaceController {

    public class FXWorkspaceException extends Exception {}

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    private static final String VIEW_PERMISSION =
        'SAB_View_FX_Operations';

    public class PeriodDTO {
        @AuraEnabled public Id periodId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date endDate { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String label { get; set; }
    }

    public class RevaluationLineDTO {
        @AuraEnabled public Id lineId { get; set; }
        @AuraEnabled public Id runId { get; set; }
        @AuraEnabled public String sourceType { get; set; }
        @AuraEnabled public String sourceRecordId { get; set; }
        @AuraEnabled public Id sourceGLAccountId { get; set; }
        @AuraEnabled public String sourceGLAccountCode { get; set; }
        @AuraEnabled public String sourceGLAccountName { get; set; }
        @AuraEnabled public String transactionCurrency { get; set; }
        @AuraEnabled public Decimal outstandingAmount { get; set; }
        @AuraEnabled public Decimal carryingAmount { get; set; }
        @AuraEnabled public Decimal appliedRate { get; set; }
        @AuraEnabled public Decimal revaluedAmount { get; set; }
        @AuraEnabled public Decimal adjustmentAmount { get; set; }
    }

    public class RevaluationRunDTO {
        @AuraEnabled public Id runId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String runKey { get; set; }
        @AuraEnabled public Id accountingPeriodId { get; set; }
        @AuraEnabled public String accountingPeriodName { get; set; }
        @AuraEnabled public Date periodEndDate { get; set; }
        @AuraEnabled public String rateSetKey { get; set; }
        @AuraEnabled public String reversalPolicy { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Id journalEntryId { get; set; }
        @AuraEnabled public Id approvedById { get; set; }
        @AuraEnabled public String approvedByName { get; set; }
        @AuraEnabled public Datetime approvedAt { get; set; }
        @AuraEnabled public Datetime postedAt { get; set; }
        @AuraEnabled public Id reversalJournalEntryId { get; set; }
        @AuraEnabled public Id reversalAccountingEventId { get; set; }
        @AuraEnabled public Datetime reversedAt { get; set; }
        @AuraEnabled public Integer lineCount { get; set; }
        @AuraEnabled public Integer arLineCount { get; set; }
        @AuraEnabled public Integer apLineCount { get; set; }
        @AuraEnabled public Decimal signedAdjustmentTotal { get; set; }
        @AuraEnabled public Decimal absoluteAdjustmentTotal { get; set; }
        @AuraEnabled public List<RevaluationLineDTO> lines { get; set; }
    }

    public class ForeignPaymentDTO {
        @AuraEnabled public Id paymentId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String reference { get; set; }
        @AuraEnabled public String direction { get; set; }
        @AuraEnabled public String processingState { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String transactionCurrency { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public Decimal exchangeRate { get; set; }
        @AuraEnabled public Id exchangeRateRecordId { get; set; }
        @AuraEnabled public Date effectiveDate { get; set; }
        @AuraEnabled public Id bankAccountId { get; set; }
        @AuraEnabled public String bankAccountName { get; set; }
        @AuraEnabled public Id partyProfileId { get; set; }
        @AuraEnabled public String partyProfileName { get; set; }
        @AuraEnabled public String providerRequestKey { get; set; }
        @AuraEnabled public Id accountingEventId { get; set; }
        @AuraEnabled public Id journalEntryId { get; set; }
        @AuraEnabled public Decimal activeAllocatedAmount { get; set; }
        @AuraEnabled public Decimal unallocatedAmount { get; set; }
    }

    public class AllocationDTO {
        @AuraEnabled public Id allocationId { get; set; }
        @AuraEnabled public Id paymentId { get; set; }
        @AuraEnabled public String paymentReference { get; set; }
        @AuraEnabled public String paymentDirection { get; set; }
        @AuraEnabled public Id targetId { get; set; }
        @AuraEnabled public String targetType { get; set; }
        @AuraEnabled public String targetName { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Decimal paymentAmount { get; set; }
        @AuraEnabled public Decimal documentAmount { get; set; }
        @AuraEnabled public Decimal baseAmount { get; set; }
        @AuraEnabled public String transactionCurrency { get; set; }
        @AuraEnabled public Decimal exchangeRate { get; set; }
        @AuraEnabled public Date allocationDate { get; set; }
        @AuraEnabled public Date effectiveDate { get; set; }
        @AuraEnabled public Decimal historicalCarryingBase { get; set; }
        @AuraEnabled public Decimal settlementBaseAmount { get; set; }
        @AuraEnabled public Decimal realizedFXAmount { get; set; }
        @AuraEnabled public String realizedFXState { get; set; }
        @AuraEnabled public Id realizedFXJournalId { get; set; }
        @AuraEnabled public Id realizedFXAccountingEventId { get; set; }
        @AuraEnabled public Id realizedFXReversalJournalId { get; set; }
        @AuraEnabled public Id realizedFXReversalEventId { get; set; }
        @AuraEnabled public Datetime realizedFXReversedAt { get; set; }
        @AuraEnabled public Id reversalOfId { get; set; }
    }

    public class SettlementTargetDTO {
        @AuraEnabled public Id targetId { get; set; }
        @AuraEnabled public String targetType { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String documentNumber { get; set; }
        @AuraEnabled public Date documentDate { get; set; }
        @AuraEnabled public Date dueDate { get; set; }
        @AuraEnabled public String transactionCurrency { get; set; }
        @AuraEnabled public Decimal historicalRate { get; set; }
        @AuraEnabled public Decimal totalAmount { get; set; }
        @AuraEnabled public Decimal outstandingAmount { get; set; }
        @AuraEnabled public String label { get; set; }
    }

    public class DashboardDTO {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String companyName { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }

        @AuraEnabled public Boolean canRunRevaluation { get; set; }
        @AuraEnabled public Boolean canApproveRevaluation { get; set; }
        @AuraEnabled public Boolean canPostRevaluation { get; set; }
        @AuraEnabled public Boolean canReverseRevaluation { get; set; }
        @AuraEnabled public Boolean canProcessForeignSettlement { get; set; }
        @AuraEnabled public Boolean canPostRealizedFX { get; set; }
        @AuraEnabled public Boolean canReverseRealizedFX { get; set; }

        @AuraEnabled public Boolean unrealizedAccountsConfigured { get; set; }
        @AuraEnabled public Boolean realizedAccountsConfigured { get; set; }

        @AuraEnabled public Integer previewRunCount { get; set; }
        @AuraEnabled public Integer approvedRunCount { get; set; }
        @AuraEnabled public Integer postedRunCount { get; set; }
        @AuraEnabled public Integer reversedRunCount { get; set; }

        @AuraEnabled public Integer draftForeignPaymentCount { get; set; }
        @AuraEnabled public Integer authorizedForeignPaymentCount { get; set; }
        @AuraEnabled public Integer submittedForeignPaymentCount { get; set; }
        @AuraEnabled public Integer succeededForeignPaymentCount { get; set; }

        @AuraEnabled public Decimal postedRealizedGainTotal { get; set; }
        @AuraEnabled public Decimal postedRealizedLossTotal { get; set; }

        @AuraEnabled public List<PeriodDTO> periods { get; set; }
        @AuraEnabled public List<RevaluationRunDTO> revaluationRuns { get; set; }
        @AuraEnabled public List<ForeignPaymentDTO> foreignPayments { get; set; }
        @AuraEnabled public List<AllocationDTO> allocations { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static DashboardDTO getDashboard(
        Id companyId
    ) {
        assertViewPermission();

        if (companyId == null) {
            throw new AuraHandledException(
                'Accounting Company is required.'
            );
        }

        try {
            SABCompanyAccessService.assertCompanyAccess(
                companyId
            );

            SABFXSecurityPolicy.assertWorkspaceReadAccess();

            Accounting_Company__c company = [
                SELECT Id,
                       Name__c,
                       Functional_Currency__c,
                       Unrealized_FX_Gain_Account__c,
                       Unrealized_FX_Loss_Account__c,
                       Realized_FX_Gain_Account__c,
                       Realized_FX_Loss_Account__c
                FROM Accounting_Company__c
                WHERE Id =
                        :companyId
                LIMIT 1
            ];

            String functionalCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    company.Functional_Currency__c
                );

            DashboardDTO out =
                new DashboardDTO();

            out.companyId =
                company.Id;
            out.companyName =
                company.Name__c;
            out.functionalCurrency =
                functionalCurrency;

            out.canRunRevaluation =
                SABPermissionService.hasPermission(
                    'SAB_Run_FX_Revaluation'
                );
            out.canApproveRevaluation =
                SABPermissionService.hasPermission(
                    'SAB_Approve_FX_Revaluation'
                );
            out.canPostRevaluation =
                SABPermissionService.hasPermission(
                    'SAB_Post_FX_Revaluation'
                );
            out.canReverseRevaluation =
                SABPermissionService.hasPermission(
                    'SAB_Reverse_FX_Revaluation'
                );
            out.canProcessForeignSettlement =
                SABPermissionService.hasPermission(
                    'SAB_Process_Foreign_Currency_Settlement'
                );
            out.canPostRealizedFX =
                SABPermissionService.hasPermission(
                    'SAB_Post_Realized_FX'
                );
            out.canReverseRealizedFX =
                SABPermissionService.hasPermission(
                    'SAB_Reverse_Realized_FX'
                );

            out.unrealizedAccountsConfigured =
                company.Unrealized_FX_Gain_Account__c
                    != null
                && company.Unrealized_FX_Loss_Account__c
                    != null;

            out.realizedAccountsConfigured =
                company.Realized_FX_Gain_Account__c
                    != null
                && company.Realized_FX_Loss_Account__c
                    != null;

            out.previewRunCount = 0;
            out.approvedRunCount = 0;
            out.postedRunCount = 0;
            out.reversedRunCount = 0;
            out.draftForeignPaymentCount = 0;
            out.authorizedForeignPaymentCount = 0;
            out.submittedForeignPaymentCount = 0;
            out.succeededForeignPaymentCount = 0;
            out.postedRealizedGainTotal = ZERO;
            out.postedRealizedLossTotal = ZERO;

            out.periods =
                loadPeriods(
                    companyId
                );

            out.revaluationRuns =
                loadRevaluationRuns(
                    companyId,
                    out
                );

            out.foreignPayments =
                loadForeignPayments(
                    companyId,
                    functionalCurrency,
                    out
                );

            out.allocations =
                loadAllocations(
                    companyId,
                    functionalCurrency,
                    out
                );

            return out;
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw new AuraHandledException(
                ex.getMessage()
            );
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<SettlementTargetDTO> getEligibleSettlementTargets(
        Id paymentId
    ) {
        assertViewPermission();

        if (paymentId == null) {
            throw new AuraHandledException(
                'Payment Id is required.'
            );
        }

        try {
            SABFXSecurityPolicy.assertWorkspaceReadAccess();

            Accounting_Payment__c payment = [
                SELECT Id,
                       Company__c,
                       Party_Profile__c,
                       Direction__c,
                       Processing_State__c,
                       Amount__c,
                       Transaction_Currency__c,
                       Functional_Currency__c
                FROM Accounting_Payment__c
                WHERE Id =
                        :paymentId
                LIMIT 1
            ];

            SABCompanyAccessService.assertCompanyAccess(
                payment.Company__c
            );

            if (
                payment.Processing_State__c
                    != 'Succeeded'
            ) {
                throw new FXWorkspaceException(
                    'Only a Succeeded foreign-currency Payment can load allocation targets.'
                );
            }

            String transactionCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    payment.Transaction_Currency__c
                );

            String functionalCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    payment.Functional_Currency__c
                );

            if (
                transactionCurrency
                    == functionalCurrency
            ) {
                throw new FXWorkspaceException(
                    'The selected Payment is not a foreign-currency Payment.'
                );
            }

            if (payment.Direction__c == 'Receipt') {
                return loadInvoiceTargets(
                    payment,
                    transactionCurrency,
                    functionalCurrency
                );
            }

            if (
                payment.Direction__c
                    == 'Disbursement'
            ) {
                return loadSupplierBillTargets(
                    payment,
                    transactionCurrency,
                    functionalCurrency
                );
            }

            throw new FXWorkspaceException(
                'Payment Direction must be Receipt or Disbursement.'
            );
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw new AuraHandledException(
                ex.getMessage()
            );
        }
    }

    private static List<PeriodDTO> loadPeriods(
        Id companyId
    ) {
        List<PeriodDTO> result =
            new List<PeriodDTO>();

        for (Accounting_Period__c period : [
            SELECT Id,
                   Name,
                   Start_Date__c,
                   End_Date__c,
                   Status__c
            FROM Accounting_Period__c
            WHERE Company__c =
                    :companyId
            ORDER BY Start_Date__c DESC
            LIMIT 60
        ]) {
            PeriodDTO dto =
                new PeriodDTO();

            dto.periodId =
                period.Id;
            dto.name =
                period.Name;
            dto.startDate =
                period.Start_Date__c;
            dto.endDate =
                period.End_Date__c;
            dto.status =
                period.Status__c;
            dto.label =
                period.Name
                + ' · '
                + String.valueOf(
                    period.Start_Date__c
                )
                + ' to '
                + String.valueOf(
                    period.End_Date__c
                )
                + ' · '
                + period.Status__c;

            result.add(
                dto
            );
        }

        return result;
    }

    private static List<RevaluationRunDTO>
        loadRevaluationRuns(
            Id companyId,
            DashboardDTO dashboard
        )
    {
        List<FX_Revaluation_Run__c> runs = [
            SELECT Id,
                   Name,
                   Run_Key__c,
                   Accounting_Period__c,
                   Accounting_Period__r.Name,
                   Accounting_Period__r.End_Date__c,
                   Rate_Set_Key__c,
                   Reversal_Policy__c,
                   Status__c,
                   Journal_Entry__c,
                   Approved_By__c,
                   Approved_By__r.Name,
                   Approved_At__c,
                   Posted_At__c,
                   Reversal_Journal_Entry__c,
                   Reversal_Accounting_Event__c,
                   Reversed_At__c
            FROM FX_Revaluation_Run__c
            WHERE Company__c =
                    :companyId
            ORDER BY CreatedDate DESC
            LIMIT 100
        ];

        Set<Id> runIds =
            new Set<Id>();

        for (FX_Revaluation_Run__c run : runs) {
            runIds.add(
                run.Id
            );
        }

        Map<Id, List<RevaluationLineDTO>>
            linesByRun =
                new Map<Id, List<RevaluationLineDTO>>();

        if (!runIds.isEmpty()) {
            for (FX_Revaluation_Line__c line : [
                SELECT Id,
                       FX_Revaluation_Run__c,
                       Source_Type__c,
                       Source_Record_Id__c,
                       Source_GL_Account__c,
                       Source_GL_Account__r.Account_Code__c,
                       Source_GL_Account__r.Name,
                       Transaction_Currency__c,
                       Outstanding_Amount__c,
                       Carrying_Amount__c,
                       Applied_Rate__c,
                       Revalued_Amount__c,
                       Adjustment_Amount__c
                FROM FX_Revaluation_Line__c
                WHERE FX_Revaluation_Run__c
                    IN :runIds
                ORDER BY CreatedDate ASC
                LIMIT 5000
            ]) {
                RevaluationLineDTO dto =
                    new RevaluationLineDTO();

                dto.lineId =
                    line.Id;
                dto.runId =
                    line.FX_Revaluation_Run__c;
                dto.sourceType =
                    line.Source_Type__c;
                dto.sourceRecordId =
                    line.Source_Record_Id__c;
                dto.sourceGLAccountId =
                    line.Source_GL_Account__c;
                dto.sourceGLAccountCode =
                    line.Source_GL_Account__r == null
                        ? null
                        : line.Source_GL_Account__r.Account_Code__c;
                dto.sourceGLAccountName =
                    line.Source_GL_Account__r == null
                        ? null
                        : line.Source_GL_Account__r.Name;
                dto.transactionCurrency =
                    line.Transaction_Currency__c;
                dto.outstandingAmount =
                    line.Outstanding_Amount__c;
                dto.carryingAmount =
                    line.Carrying_Amount__c;
                dto.appliedRate =
                    line.Applied_Rate__c;
                dto.revaluedAmount =
                    line.Revalued_Amount__c;
                dto.adjustmentAmount =
                    line.Adjustment_Amount__c;

                if (
                    !linesByRun.containsKey(
                        line.FX_Revaluation_Run__c
                    )
                ) {
                    linesByRun.put(
                        line.FX_Revaluation_Run__c,
                        new List<RevaluationLineDTO>()
                    );
                }

                linesByRun.get(
                    line.FX_Revaluation_Run__c
                ).add(
                    dto
                );
            }
        }

        List<RevaluationRunDTO> result =
            new List<RevaluationRunDTO>();

        for (FX_Revaluation_Run__c run : runs) {
            RevaluationRunDTO dto =
                new RevaluationRunDTO();

            dto.runId =
                run.Id;
            dto.name =
                run.Name;
            dto.runKey =
                run.Run_Key__c;
            dto.accountingPeriodId =
                run.Accounting_Period__c;
            dto.accountingPeriodName =
                run.Accounting_Period__r == null
                    ? null
                    : run.Accounting_Period__r.Name;
            dto.periodEndDate =
                run.Accounting_Period__r == null
                    ? null
                    : run.Accounting_Period__r.End_Date__c;
            dto.rateSetKey =
                run.Rate_Set_Key__c;
            dto.reversalPolicy =
                run.Reversal_Policy__c;
            dto.status =
                run.Status__c;
            dto.journalEntryId =
                run.Journal_Entry__c;
            dto.approvedById =
                run.Approved_By__c;
            dto.approvedByName =
                run.Approved_By__r == null
                    ? null
                    : run.Approved_By__r.Name;
            dto.approvedAt =
                run.Approved_At__c;
            dto.postedAt =
                run.Posted_At__c;
            dto.reversalJournalEntryId =
                run.Reversal_Journal_Entry__c;
            dto.reversalAccountingEventId =
                run.Reversal_Accounting_Event__c;
            dto.reversedAt =
                run.Reversed_At__c;

            dto.lines =
                linesByRun.containsKey(
                    run.Id
                )
                    ? linesByRun.get(
                        run.Id
                    )
                    : new List<RevaluationLineDTO>();

            dto.lineCount =
                dto.lines.size();
            dto.arLineCount = 0;
            dto.apLineCount = 0;
            dto.signedAdjustmentTotal = ZERO;
            dto.absoluteAdjustmentTotal = ZERO;

            for (RevaluationLineDTO line : dto.lines) {
                if (line.sourceType == 'Invoice__c') {
                    dto.arLineCount++;
                } else if (
                    line.sourceType
                        == 'Supplier_Bill__c'
                ) {
                    dto.apLineCount++;
                }

                Decimal adjustment =
                    line.adjustmentAmount == null
                        ? ZERO
                        : line.adjustmentAmount;

                dto.signedAdjustmentTotal +=
                    adjustment;
                dto.absoluteAdjustmentTotal +=
                    adjustment.abs();
            }

            if (run.Status__c == 'Preview') {
                dashboard.previewRunCount++;
            } else if (
                run.Status__c == 'Approved'
            ) {
                dashboard.approvedRunCount++;
            } else if (
                run.Status__c == 'Posted'
            ) {
                dashboard.postedRunCount++;
            } else if (
                run.Status__c == 'Reversed'
            ) {
                dashboard.reversedRunCount++;
            }

            result.add(
                dto
            );
        }

        return result;
    }

    private static List<ForeignPaymentDTO>
        loadForeignPayments(
            Id companyId,
            String functionalCurrency,
            DashboardDTO dashboard
        )
    {
        List<Accounting_Payment__c> candidates = [
            SELECT Id,
                   Name,
                   Reference__c,
                   Direction__c,
                   Processing_State__c,
                   Amount__c,
                   Transaction_Currency__c,
                   Functional_Currency__c,
                   Exchange_Rate__c,
                   Exchange_Rate_Record__c,
                   Effective_Date__c,
                   Bank_Account__c,
                   Bank_Account__r.Name,
                   Party_Profile__c,
                   Party_Profile__r.Name,
                   Provider_Request_Key__c,
                   Accounting_Event__c,
                   Accounting_Event__r.Journal_Entry__c
            FROM Accounting_Payment__c
            WHERE Company__c =
                    :companyId
            ORDER BY Effective_Date__c DESC,
                     CreatedDate DESC
            LIMIT 500
        ];

        Set<Id> paymentIds =
            new Set<Id>();

        Map<Id, ForeignPaymentDTO> byId =
            new Map<Id, ForeignPaymentDTO>();

        for (Accounting_Payment__c payment : candidates) {
            String transactionCurrency;

            try {
                transactionCurrency =
                    SABMoneyService.normalizeCurrencyCode(
                        payment.Transaction_Currency__c
                    );
            } catch (Exception ex) {
                continue;
            }

            if (
                transactionCurrency
                    == functionalCurrency
            ) {
                continue;
            }

            ForeignPaymentDTO dto =
                new ForeignPaymentDTO();

            dto.paymentId =
                payment.Id;
            dto.name =
                payment.Name;
            dto.reference =
                payment.Reference__c;
            dto.direction =
                payment.Direction__c;
            dto.processingState =
                payment.Processing_State__c;
            dto.amount =
                payment.Amount__c;
            dto.transactionCurrency =
                transactionCurrency;
            dto.functionalCurrency =
                payment.Functional_Currency__c;
            dto.exchangeRate =
                payment.Exchange_Rate__c;
            dto.exchangeRateRecordId =
                payment.Exchange_Rate_Record__c;
            dto.effectiveDate =
                payment.Effective_Date__c;
            dto.bankAccountId =
                payment.Bank_Account__c;
            dto.bankAccountName =
                payment.Bank_Account__r == null
                    ? null
                    : payment.Bank_Account__r.Name;
            dto.partyProfileId =
                payment.Party_Profile__c;
            dto.partyProfileName =
                payment.Party_Profile__r == null
                    ? null
                    : payment.Party_Profile__r.Name;
            dto.providerRequestKey =
                payment.Provider_Request_Key__c;
            dto.accountingEventId =
                payment.Accounting_Event__c;
            dto.journalEntryId =
                payment.Accounting_Event__r == null
                    ? null
                    : payment.Accounting_Event__r.Journal_Entry__c;
            dto.activeAllocatedAmount =
                ZERO;
            dto.unallocatedAmount =
                SABMoneyService.normalizeTransactionAmount(
                    payment.Amount__c == null
                        ? ZERO
                        : payment.Amount__c,
                    RoundingMode.HALF_UP
                );

            byId.put(
                payment.Id,
                dto
            );
            paymentIds.add(
                payment.Id
            );

            if (
                payment.Processing_State__c
                    == 'Draft'
            ) {
                dashboard.draftForeignPaymentCount++;
            } else if (
                payment.Processing_State__c
                    == 'Authorized'
            ) {
                dashboard.authorizedForeignPaymentCount++;
            } else if (
                payment.Processing_State__c
                    == 'Submitted'
            ) {
                dashboard.submittedForeignPaymentCount++;
            } else if (
                payment.Processing_State__c
                    == 'Succeeded'
            ) {
                dashboard.succeededForeignPaymentCount++;
            }
        }

        if (!paymentIds.isEmpty()) {
            for (AggregateResult aggregateRow : [
                SELECT Payment__c paymentId,
                       SUM(Payment_Amount__c) amount
                FROM Payment_Allocation__c
                WHERE Payment__c
                    IN :paymentIds
                  AND Status__c =
                        'Allocated'
                GROUP BY Payment__c
            ]) {
                Id paymentId =
                    (Id) aggregateRow.get(
                        'paymentId'
                    );

                Decimal allocated =
                    (Decimal) aggregateRow.get(
                        'amount'
                    );

                ForeignPaymentDTO dto =
                    byId.get(
                        paymentId
                    );

                if (dto == null) {
                    continue;
                }

                dto.activeAllocatedAmount =
                    allocated == null
                        ? ZERO
                        : SABMoneyService.normalizeTransactionAmount(
                                allocated,
                                RoundingMode.HALF_UP
                            );

                dto.unallocatedAmount =
                    SABMoneyService.normalizeTransactionAmount(
                            (
                                dto.amount == null
                                    ? ZERO
                                    : dto.amount
                            )
                            - dto.activeAllocatedAmount,
                            RoundingMode.HALF_UP
                        );
            }
        }

        List<ForeignPaymentDTO> result =
            new List<ForeignPaymentDTO>();

        for (Accounting_Payment__c payment : candidates) {
            if (byId.containsKey(payment.Id)) {
                result.add(
                    byId.get(
                        payment.Id
                    )
                );
            }
        }

        return result;
    }

    private static List<AllocationDTO>
        loadAllocations(
            Id companyId,
            String functionalCurrency,
            DashboardDTO dashboard
        )
    {
        List<AllocationDTO> result =
            new List<AllocationDTO>();

        for (Payment_Allocation__c allocation : [
            SELECT Id,
                   Payment__c,
                   Payment__r.Reference__c,
                   Payment__r.Direction__c,
                   Invoice__c,
                   Invoice__r.Name,
                   Supplier_Bill__c,
                   Supplier_Bill__r.Name,
                   Status__c,
                   Payment_Amount__c,
                   Document_Amount__c,
                   Base_Amount__c,
                   Transaction_Currency__c,
                   Exchange_Rate__c,
                   Allocation_Date__c,
                   Effective_Date__c,
                   Historical_Carrying_Base__c,
                   Settlement_Base_Amount__c,
                   Realized_FX_Amount__c,
                   Realized_FX_State__c,
                   Realized_FX_Journal__c,
                   Realized_FX_Accounting_Event__c,
                   Realized_FX_Reversal_Journal__c,
                   Realized_FX_Reversal_Event__c,
                   Realized_FX_Reversed_At__c,
                   Reversal_Of__c
            FROM Payment_Allocation__c
            WHERE Company__c =
                    :companyId
            ORDER BY CreatedDate DESC
            LIMIT 1000
        ]) {
            String transactionCurrency;

            try {
                transactionCurrency =
                    SABMoneyService.normalizeCurrencyCode(
                        allocation.Transaction_Currency__c
                    );
            } catch (Exception ex) {
                continue;
            }

            if (
                transactionCurrency
                    == functionalCurrency
            ) {
                continue;
            }

            AllocationDTO dto =
                new AllocationDTO();

            dto.allocationId =
                allocation.Id;
            dto.paymentId =
                allocation.Payment__c;
            dto.paymentReference =
                allocation.Payment__r == null
                    ? null
                    : allocation.Payment__r.Reference__c;
            dto.paymentDirection =
                allocation.Payment__r == null
                    ? null
                    : allocation.Payment__r.Direction__c;
            dto.targetId =
                allocation.Invoice__c != null
                    ? allocation.Invoice__c
                    : allocation.Supplier_Bill__c;
            dto.targetType =
                allocation.Invoice__c != null
                    ? 'Invoice'
                    : 'Supplier Bill';
            dto.targetName =
                allocation.Invoice__c != null
                    ? (
                        allocation.Invoice__r == null
                            ? null
                            : allocation.Invoice__r.Name
                    )
                    : (
                        allocation.Supplier_Bill__r
                            == null
                            ? null
                            : allocation.Supplier_Bill__r.Name
                    );
            dto.status =
                allocation.Status__c;
            dto.paymentAmount =
                allocation.Payment_Amount__c;
            dto.documentAmount =
                allocation.Document_Amount__c;
            dto.baseAmount =
                allocation.Base_Amount__c;
            dto.transactionCurrency =
                transactionCurrency;
            dto.exchangeRate =
                allocation.Exchange_Rate__c;
            dto.allocationDate =
                allocation.Allocation_Date__c;
            dto.effectiveDate =
                allocation.Effective_Date__c;
            dto.historicalCarryingBase =
                allocation.Historical_Carrying_Base__c;
            dto.settlementBaseAmount =
                allocation.Settlement_Base_Amount__c;
            dto.realizedFXAmount =
                allocation.Realized_FX_Amount__c;
            dto.realizedFXState =
                allocation.Realized_FX_State__c;
            dto.realizedFXJournalId =
                allocation.Realized_FX_Journal__c;
            dto.realizedFXAccountingEventId =
                allocation.Realized_FX_Accounting_Event__c;
            dto.realizedFXReversalJournalId =
                allocation.Realized_FX_Reversal_Journal__c;
            dto.realizedFXReversalEventId =
                allocation.Realized_FX_Reversal_Event__c;
            dto.realizedFXReversedAt =
                allocation.Realized_FX_Reversed_At__c;
            dto.reversalOfId =
                allocation.Reversal_Of__c;

            if (
                allocation.Realized_FX_State__c
                    == 'Posted'
                && allocation.Realized_FX_Amount__c
                    != null
            ) {
                if (
                    allocation.Realized_FX_Amount__c
                        > ZERO
                ) {
                    dashboard.postedRealizedGainTotal +=
                        allocation.Realized_FX_Amount__c;
                } else if (
                    allocation.Realized_FX_Amount__c
                        < ZERO
                ) {
                    dashboard.postedRealizedLossTotal +=
                        allocation.Realized_FX_Amount__c.abs();
                }
            }

            result.add(
                dto
            );
        }

        dashboard.postedRealizedGainTotal =
            SABMoneyService.normalizeLedgerAmount(
                dashboard.postedRealizedGainTotal,
                RoundingMode.HALF_UP
            );

        dashboard.postedRealizedLossTotal =
            SABMoneyService.normalizeLedgerAmount(
                dashboard.postedRealizedLossTotal,
                RoundingMode.HALF_UP
            );

        return result;
    }

    private static List<SettlementTargetDTO>
        loadInvoiceTargets(
            Accounting_Payment__c payment,
            String transactionCurrency,
            String functionalCurrency
        )
    {
        List<Invoice__c> invoices = [
            SELECT Id,
                   Name,
                   Legal_Number__c,
                   Document_Date__c,
                   Due_Date__c,
                   Total__c,
                   Transaction_Currency__c,
                   Exchange_Rate__c
            FROM Invoice__c
            WHERE Company__c =
                    :payment.Company__c
              AND Party_Profile__c =
                    :payment.Party_Profile__c
              AND Document_Type__c =
                    'Invoice'
              AND Status__c =
                    'Posted'
              AND Transaction_Currency__c =
                    :transactionCurrency
              AND Functional_Currency__c =
                    :functionalCurrency
            ORDER BY Due_Date__c ASC,
                     Document_Date__c ASC
            LIMIT 500
        ];

        Set<Id> ids =
            new Set<Id>();

        for (Invoice__c invoice : invoices) {
            ids.add(
                invoice.Id
            );
        }

        Map<Id, Decimal> allocated =
            activeAllocatedByInvoice(
                ids
            );

        List<SettlementTargetDTO> result =
            new List<SettlementTargetDTO>();

        for (Invoice__c invoice : invoices) {
            Decimal total =
                SABMoneyService.normalizeTransactionAmount(
                    invoice.Total__c == null
                        ? ZERO
                        : invoice.Total__c,
                    RoundingMode.HALF_UP
                );

            Decimal used =
                allocated.containsKey(
                    invoice.Id
                )
                    ? allocated.get(
                        invoice.Id
                    )
                    : ZERO;

            Decimal outstanding =
                SABMoneyService.normalizeTransactionAmount(
                    total - used,
                    RoundingMode.HALF_UP
                );

            if (outstanding <= ZERO) {
                continue;
            }

            SettlementTargetDTO dto =
                new SettlementTargetDTO();

            dto.targetId =
                invoice.Id;
            dto.targetType =
                'Invoice';
            dto.name =
                invoice.Name;
            dto.documentNumber =
                invoice.Legal_Number__c;
            dto.documentDate =
                invoice.Document_Date__c;
            dto.dueDate =
                invoice.Due_Date__c;
            dto.transactionCurrency =
                transactionCurrency;
            dto.historicalRate =
                invoice.Exchange_Rate__c;
            dto.totalAmount =
                total;
            dto.outstandingAmount =
                outstanding;
            dto.label =
                (
                    String.isBlank(
                        invoice.Legal_Number__c
                    )
                        ? invoice.Name
                        : invoice.Legal_Number__c
                )
                + ' · '
                + String.valueOf(
                    outstanding
                )
                + ' '
                + transactionCurrency;

            result.add(
                dto
            );
        }

        return result;
    }

    private static List<SettlementTargetDTO>
        loadSupplierBillTargets(
            Accounting_Payment__c payment,
            String transactionCurrency,
            String functionalCurrency
        )
    {
        List<Supplier_Bill__c> bills = [
            SELECT Id,
                   Name,
                   Vendor_Reference__c,
                   Document_Date__c,
                   Due_Date__c,
                   Total__c,
                   Transaction_Currency__c,
                   Exchange_Rate__c
            FROM Supplier_Bill__c
            WHERE Company__c =
                    :payment.Company__c
              AND Supplier_Profile__c =
                    :payment.Party_Profile__c
              AND Document_Type__c =
                    'Bill'
              AND Status__c =
                    'Posted'
              AND Transaction_Currency__c =
                    :transactionCurrency
              AND Functional_Currency__c =
                    :functionalCurrency
            ORDER BY Due_Date__c ASC,
                     Document_Date__c ASC
            LIMIT 500
        ];

        Set<Id> ids =
            new Set<Id>();

        for (Supplier_Bill__c bill : bills) {
            ids.add(
                bill.Id
            );
        }

        Map<Id, Decimal> allocated =
            activeAllocatedByBill(
                ids
            );

        List<SettlementTargetDTO> result =
            new List<SettlementTargetDTO>();

        for (Supplier_Bill__c bill : bills) {
            Decimal total =
                SABMoneyService.normalizeTransactionAmount(
                    bill.Total__c == null
                        ? ZERO
                        : bill.Total__c,
                    RoundingMode.HALF_UP
                );

            Decimal used =
                allocated.containsKey(
                    bill.Id
                )
                    ? allocated.get(
                        bill.Id
                    )
                    : ZERO;

            Decimal outstanding =
                SABMoneyService.normalizeTransactionAmount(
                    total - used,
                    RoundingMode.HALF_UP
                );

            if (outstanding <= ZERO) {
                continue;
            }

            SettlementTargetDTO dto =
                new SettlementTargetDTO();

            dto.targetId =
                bill.Id;
            dto.targetType =
                'Supplier Bill';
            dto.name =
                bill.Name;
            dto.documentNumber =
                bill.Vendor_Reference__c;
            dto.documentDate =
                bill.Document_Date__c;
            dto.dueDate =
                bill.Due_Date__c;
            dto.transactionCurrency =
                transactionCurrency;
            dto.historicalRate =
                bill.Exchange_Rate__c;
            dto.totalAmount =
                total;
            dto.outstandingAmount =
                outstanding;
            dto.label =
                (
                    String.isBlank(
                        bill.Vendor_Reference__c
                    )
                        ? bill.Name
                        : bill.Vendor_Reference__c
                )
                + ' · '
                + String.valueOf(
                    outstanding
                )
                + ' '
                + transactionCurrency;

            result.add(
                dto
            );
        }

        return result;
    }

    private static Map<Id, Decimal> activeAllocatedByInvoice(
        Set<Id> ids
    ) {
        Map<Id, Decimal> result =
            new Map<Id, Decimal>();

        if (ids.isEmpty()) {
            return result;
        }

        for (AggregateResult row : [
            SELECT Invoice__c targetId,
                   SUM(Document_Amount__c) amount
            FROM Payment_Allocation__c
            WHERE Invoice__c
                IN :ids
              AND Status__c =
                    'Allocated'
            GROUP BY Invoice__c
        ]) {
            result.put(
                (Id) row.get(
                    'targetId'
                ),
                (Decimal) row.get(
                    'amount'
                )
            );
        }

        return result;
    }

    private static Map<Id, Decimal> activeAllocatedByBill(
        Set<Id> ids
    ) {
        Map<Id, Decimal> result =
            new Map<Id, Decimal>();

        if (ids.isEmpty()) {
            return result;
        }

        for (AggregateResult row : [
            SELECT Supplier_Bill__c targetId,
                   SUM(Document_Amount__c) amount
            FROM Payment_Allocation__c
            WHERE Supplier_Bill__c
                IN :ids
              AND Status__c =
                    'Allocated'
            GROUP BY Supplier_Bill__c
        ]) {
            result.put(
                (Id) row.get(
                    'targetId'
                ),
                (Decimal) row.get(
                    'amount'
                )
            );
        }

        return result;
    }

    private static void assertViewPermission() {
        SABPermissionService.assertPermission(
            VIEW_PERMISSION,
            'You do not have permission to view the FX Operations Workspace.'
        );
    }
}
