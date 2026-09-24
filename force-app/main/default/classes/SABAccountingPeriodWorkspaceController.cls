/**
 * Stage 8E - Accounting Period Workspace Controller
 *
 * Thin Lightning wrapper around SABPeriodService.
 *
 * Responsibilities:
 * - list Accounting Periods for the selected authorized company;
 * - show one Period and its immutable Accounting_Period_Action__c history;
 * - expose permission-aware Close / Reopen actions;
 * - preserve SABPeriodService as the authoritative transition service.
 *
 * Security:
 * - `with sharing`
 * - SABCompanyAccessService
 * - SABAccessControlService CRUD/FLS + selected-record access
 * - SABPeriodService custom permissions + service-side FLS
 */
public with sharing class SABAccountingPeriodWorkspaceController {

    public class PeriodSummaryDTO {
        @AuraEnabled public Id periodId { get; set; }
        @AuraEnabled public String periodName { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date endDate { get; set; }
        @AuraEnabled public Decimal fiscalYear { get; set; }
        @AuraEnabled public Decimal fiscalQuarter { get; set; }
        @AuraEnabled public Decimal periodNumber { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Datetime closedAt { get; set; }
        @AuraEnabled public String closedByName { get; set; }
    }

    public class ActionDTO {
        @AuraEnabled public Id actionId { get; set; }
        @AuraEnabled public String previousStatus { get; set; }
        @AuraEnabled public String newStatus { get; set; }
        @AuraEnabled public String performedByName { get; set; }
        @AuraEnabled public Datetime performedAt { get; set; }
        @AuraEnabled public String reason { get; set; }
        @AuraEnabled public String requestKey { get; set; }
    }

    public class WorkspaceDTO {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public Boolean canClosePeriod { get; set; }
        @AuraEnabled public Boolean canReopenPeriod { get; set; }
        @AuraEnabled public List<PeriodSummaryDTO> periods { get; set; }
    }

    public class PeriodDetailDTO {
        @AuraEnabled public PeriodSummaryDTO period { get; set; }
        @AuraEnabled public List<ActionDTO> actions { get; set; }
        @AuraEnabled public Id latestActionId { get; set; }
    }

    public class PeriodActionDTO {
        @AuraEnabled public Id periodId { get; set; }
        @AuraEnabled public Id actionId { get; set; }
        @AuraEnabled public String previousStatus { get; set; }
        @AuraEnabled public String newStatus { get; set; }
        @AuraEnabled public String currentPeriodStatus { get; set; }
        @AuraEnabled public Datetime performedAt { get; set; }
        @AuraEnabled public Boolean replay { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static WorkspaceDTO getWorkspace(
        Id companyId
    ) {
        assertCompanyId(companyId);
        SABCompanyAccessService.assertCompanyAccess(
            companyId
        );
        assertReadAccess();

        WorkspaceDTO dto =
            new WorkspaceDTO();

        dto.companyId =
            companyId;
        dto.canClosePeriod =
            SABPermissionService.hasPermission(
                'SAB_Close_Period'
            );
        dto.canReopenPeriod =
            SABPermissionService.hasPermission(
                'SAB_Reopen_Period'
            );
        dto.periods =
            new List<PeriodSummaryDTO>();

        for (Accounting_Period__c period : [
            SELECT Id,
                   Name,
                   Start_Date__c,
                   End_Date__c,
                   Fiscal_Year__c,
                   Fiscal_Quarter__c,
                   Period_Number__c,
                   Status__c,
                   Closed_At__c,
                   Closed_By__r.Name
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
            ORDER BY Start_Date__c DESC,
                     Period_Number__c DESC
            LIMIT 250
        ]) {
            dto.periods.add(
                toSummary(period)
            );
        }

        return dto;
    }

    @AuraEnabled(cacheable=true)
    public static PeriodDetailDTO getPeriodDetail(
        Id periodId
    ) {
        if (periodId == null) {
            throw new AuraHandledException(
                'Accounting Period is required.'
            );
        }

        assertReadAccess();

        Accounting_Period__c period = [
            SELECT Id,
                   Name,
                   Company__c,
                   Start_Date__c,
                   End_Date__c,
                   Fiscal_Year__c,
                   Fiscal_Quarter__c,
                   Period_Number__c,
                   Status__c,
                   Closed_At__c,
                   Closed_By__r.Name
            FROM Accounting_Period__c
            WHERE Id = :periodId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(
            period.Company__c
        );

        SABAccessControlService.assertRecordReadAccess(
            period.Id
        );

        List<Accounting_Period_Action__c> history = [
            SELECT Id,
                   Previous_Status__c,
                   New_Status__c,
                   Performed_By__r.Name,
                   Performed_At__c,
                   Reason__c,
                   Request_Key__c
            FROM Accounting_Period_Action__c
            WHERE Period__c = :period.Id
            ORDER BY Performed_At__c DESC,
                     CreatedDate DESC,
                     Id DESC
            LIMIT 200
        ];

        PeriodDetailDTO dto =
            new PeriodDetailDTO();

        dto.period =
            toSummary(period);
        dto.actions =
            new List<ActionDTO>();

        for (
            Accounting_Period_Action__c actionRecord
            : history
        ) {
            ActionDTO action =
                new ActionDTO();

            action.actionId =
                actionRecord.Id;
            action.previousStatus =
                actionRecord.Previous_Status__c;
            action.newStatus =
                actionRecord.New_Status__c;
            action.performedByName =
                actionRecord.Performed_By__r == null
                    ? null
                    : actionRecord.Performed_By__r.Name;
            action.performedAt =
                actionRecord.Performed_At__c;
            action.reason =
                actionRecord.Reason__c;
            action.requestKey =
                actionRecord.Request_Key__c;

            dto.actions.add(
                action
            );
        }

        dto.latestActionId =
            history.isEmpty()
                ? null
                : history[0].Id;

        return dto;
    }

    @AuraEnabled
    public static PeriodActionDTO closePeriod(
        Id periodId,
        String requestKey,
        String reason
    ) {
        assertPeriodActionRecordAccess(
            periodId
        );

        SABPeriodService.PeriodActionRequest request =
            new SABPeriodService.PeriodActionRequest();

        request.periodId =
            periodId;
        request.requestKey =
            requestKey;
        request.reason =
            reason;

        try {
            return toActionDTO(
                SABPeriodService.closePeriod(
                    request
                )
            );
        } catch (Exception ex) {
            throw new AuraHandledException(
                ex.getMessage()
            );
        }
    }

    @AuraEnabled
    public static PeriodActionDTO reopenPeriod(
        Id periodId,
        String requestKey,
        String reason
    ) {
        assertPeriodActionRecordAccess(
            periodId
        );

        SABPeriodService.PeriodActionRequest request =
            new SABPeriodService.PeriodActionRequest();

        request.periodId =
            periodId;
        request.requestKey =
            requestKey;
        request.reason =
            reason;

        try {
            return toActionDTO(
                SABPeriodService.reopenPeriod(
                    request
                )
            );
        } catch (Exception ex) {
            throw new AuraHandledException(
                ex.getMessage()
            );
        }
    }

    private static void assertPeriodActionRecordAccess(
        Id periodId
    ) {
        if (periodId == null) {
            throw new AuraHandledException(
                'Accounting Period is required.'
            );
        }

        Accounting_Period__c period = [
            SELECT Id,
                   Company__c
            FROM Accounting_Period__c
            WHERE Id = :periodId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(
            period.Company__c
        );

        SABAccessControlService.assertRecordReadAccess(
            period.Id
        );
    }

    private static void assertCompanyId(
        Id companyId
    ) {
        if (companyId == null) {
            throw new AuraHandledException(
                'Select an Accounting Company before using the Period Workspace.'
            );
        }
    }

    private static void assertReadAccess() {
        SABAccessControlService.assertReadable(
            Accounting_Period__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Period__c.Company__c,
                Accounting_Period__c.Start_Date__c,
                Accounting_Period__c.End_Date__c,
                Accounting_Period__c.Fiscal_Year__c,
                Accounting_Period__c.Fiscal_Quarter__c,
                Accounting_Period__c.Period_Number__c,
                Accounting_Period__c.Status__c,
                Accounting_Period__c.Closed_At__c,
                Accounting_Period__c.Closed_By__c
            }
        );

        SABAccessControlService.assertReadable(
            Accounting_Period_Action__c.SObjectType,
            new List<Schema.SObjectField>{
                Accounting_Period_Action__c.Period__c,
                Accounting_Period_Action__c.Previous_Status__c,
                Accounting_Period_Action__c.New_Status__c,
                Accounting_Period_Action__c.Performed_By__c,
                Accounting_Period_Action__c.Performed_At__c,
                Accounting_Period_Action__c.Reason__c,
                Accounting_Period_Action__c.Request_Key__c
            }
        );
    }

    private static PeriodSummaryDTO toSummary(
        Accounting_Period__c period
    ) {
        PeriodSummaryDTO dto =
            new PeriodSummaryDTO();

        dto.periodId =
            period.Id;
        dto.periodName =
            period.Name;
        dto.startDate =
            period.Start_Date__c;
        dto.endDate =
            period.End_Date__c;
        dto.fiscalYear =
            period.Fiscal_Year__c;
        dto.fiscalQuarter =
            period.Fiscal_Quarter__c;
        dto.periodNumber =
            period.Period_Number__c;
        dto.status =
            period.Status__c;
        dto.closedAt =
            period.Closed_At__c;
        dto.closedByName =
            period.Closed_By__r == null
                ? null
                : period.Closed_By__r.Name;

        return dto;
    }

    private static PeriodActionDTO toActionDTO(
        SABPeriodService.PeriodActionResult result
    ) {
        PeriodActionDTO dto =
            new PeriodActionDTO();

        dto.periodId =
            result.periodId;
        dto.actionId =
            result.actionId;
        dto.previousStatus =
            result.previousStatus;
        dto.newStatus =
            result.newStatus;
        dto.currentPeriodStatus =
            result.currentPeriodStatus;
        dto.performedAt =
            result.performedAt;
        dto.replay =
            result.replay;

        return dto;
    }
}
