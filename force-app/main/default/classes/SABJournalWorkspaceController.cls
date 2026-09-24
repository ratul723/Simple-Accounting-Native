/**
 * Stage 8B - Journal Workspace Controller
 *
 * Thin Lightning controller for creating and editing Draft manual journals.
 *
 * Accounting logic remains in the domain services:
 * - SABJournalValidationService (Stage 8C will expose validation UX)
 * - SABPostingService (Stage 8C)
 * - SABReversalService (Stage 8D)
 *
 * This controller only:
 * - loads company-scoped reference data,
 * - lists accessible Draft journals,
 * - loads one Draft journal,
 * - creates/updates a Draft header and Draft lines.
 *
 * Security:
 * - `with sharing`
 * - SABCompanyAccessService
 * - SABAccessControlService CRUD/FLS + record access
 * - Step 7B cross-company triggers remain authoritative
 */
public with sharing class SABJournalWorkspaceController {

    public class OptionDTO {
        @AuraEnabled public Id value { get; set; }
        @AuraEnabled public String label { get; set; }

        public OptionDTO(Id optionValue, String optionLabel) {
            value = optionValue;
            label = optionLabel;
        }
    }

    public class DraftSummaryDTO {
        @AuraEnabled public Id journalId { get; set; }
        @AuraEnabled public String journalName { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Id periodId { get; set; }
    }

    public class PostedSummaryDTO {
        @AuraEnabled public Id journalId { get; set; }
        @AuraEnabled public String journalName { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public String postingKey { get; set; }
    }

    public class LineDTO {
        @AuraEnabled public Id lineId { get; set; }
        @AuraEnabled public Integer lineNumber { get; set; }
        @AuraEnabled public Id glAccountId { get; set; }
        @AuraEnabled public Decimal debit { get; set; }
        @AuraEnabled public Decimal credit { get; set; }
        @AuraEnabled public String explanation { get; set; }
        @AuraEnabled public Id departmentId { get; set; }
        @AuraEnabled public Id costCenterId { get; set; }
        @AuraEnabled public Id projectId { get; set; }
    }

    public class JournalDTO {
        @AuraEnabled public Id journalId { get; set; }
        @AuraEnabled public String journalName { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public Id periodId { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String entryType { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Decimal totalDebit { get; set; }
        @AuraEnabled public Decimal totalCredit { get; set; }
        @AuraEnabled public String postingKey { get; set; }
        @AuraEnabled public Datetime postedAt { get; set; }
        @AuraEnabled public Id accountingEventId { get; set; }
        @AuraEnabled public Id reversalJournalId { get; set; }
        @AuraEnabled public Id reversalOfId { get; set; }
        @AuraEnabled public List<LineDTO> lines { get; set; }
    }

    public class WorkspaceDTO {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public List<OptionDTO> periods { get; set; }
        @AuraEnabled public List<OptionDTO> glAccounts { get; set; }
        @AuraEnabled public List<OptionDTO> departments { get; set; }
        @AuraEnabled public List<OptionDTO> costCenters { get; set; }
        @AuraEnabled public List<OptionDTO> projects { get; set; }
        @AuraEnabled public List<DraftSummaryDTO> drafts { get; set; }
        @AuraEnabled public List<PostedSummaryDTO> postedJournals { get; set; }
        @AuraEnabled public Boolean canPostJournal { get; set; }
        @AuraEnabled public Boolean canReverseJournal { get; set; }
    }

    public class ValidationDTO {
        @AuraEnabled public Boolean isValid { get; set; }
        @AuraEnabled public List<String> errors { get; set; }
        @AuraEnabled public Integer lineCount { get; set; }
        @AuraEnabled public Decimal totalDebit { get; set; }
        @AuraEnabled public Decimal totalCredit { get; set; }
    }

    public class PostingDTO {
        @AuraEnabled public Id journalId { get; set; }
        @AuraEnabled public Id accountingEventId { get; set; }
        @AuraEnabled public String postingKey { get; set; }
        @AuraEnabled public Datetime postedAt { get; set; }
        @AuraEnabled public Boolean replay { get; set; }
        @AuraEnabled public String status { get; set; }
    }

    public class ReversalDTO {
        @AuraEnabled public Id originalJournalId { get; set; }
        @AuraEnabled public Id reversalJournalId { get; set; }
        @AuraEnabled public String reversalJournalName { get; set; }
        @AuraEnabled public Id reversalAccountingEventId { get; set; }
        @AuraEnabled public String reversalPostingKey { get; set; }
        @AuraEnabled public Date reversalAccountingDate { get; set; }
        @AuraEnabled public Boolean replay { get; set; }
        @AuraEnabled public String originalStatus { get; set; }
    }

    public class DraftLineInput {
        @AuraEnabled public Id glAccountId { get; set; }
        @AuraEnabled public Decimal debit { get; set; }
        @AuraEnabled public Decimal credit { get; set; }
        @AuraEnabled public String explanation { get; set; }
        @AuraEnabled public Id departmentId { get; set; }
        @AuraEnabled public Id costCenterId { get; set; }
        @AuraEnabled public Id projectId { get; set; }
    }

    public class DraftSaveRequest {
        @AuraEnabled public Id journalId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public Id periodId { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public List<DraftLineInput> lines { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static WorkspaceDTO getWorkspace(Id companyId) {
        assertCompanyId(companyId);
        SABCompanyAccessService.assertCompanyAccess(companyId);
        assertReadAccess();

        Accounting_Company__c company = [
            SELECT Id, Functional_Currency__c
            FROM Accounting_Company__c
            WHERE Id = :companyId
              AND Is_Active__c = true
            LIMIT 1
        ];

        WorkspaceDTO dto = new WorkspaceDTO();
        dto.companyId = company.Id;
        dto.functionalCurrency = company.Functional_Currency__c;
        dto.periods = new List<OptionDTO>();
        dto.glAccounts = new List<OptionDTO>();
        dto.departments = new List<OptionDTO>();
        dto.costCenters = new List<OptionDTO>();
        dto.projects = new List<OptionDTO>();
        dto.drafts = new List<DraftSummaryDTO>();
        dto.postedJournals = new List<PostedSummaryDTO>();
        dto.canPostJournal =
            SABPermissionService.hasPermission(
                'SAB_Post_Journal'
            );
        dto.canReverseJournal =
            SABPermissionService.hasPermission(
                'SAB_Reverse_Journal'
            );

        for (Accounting_Period__c period : [
            SELECT Id, Name, Start_Date__c, End_Date__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
              AND Status__c = 'Open'
            ORDER BY Start_Date__c ASC
        ]) {
            dto.periods.add(
                new OptionDTO(
                    period.Id,
                    period.Name
                    + ' · '
                    + String.valueOf(period.Start_Date__c)
                    + ' to '
                    + String.valueOf(period.End_Date__c)
                )
            );
        }

        for (GL_Account__c account : [
            SELECT Id, Name, Account_Code__c
            FROM GL_Account__c
            WHERE Company__c = :companyId
              AND Is_Active__c = true
              AND Manual_Posting_Allowed__c = true
              AND Is_Control_Account__c = false
            ORDER BY Account_Code__c ASC
        ]) {
            dto.glAccounts.add(
                new OptionDTO(
                    account.Id,
                    account.Account_Code__c
                    + ' · '
                    + account.Name
                )
            );
        }

        for (Department__c department : [
            SELECT Id, Name, Code__c
            FROM Department__c
            WHERE Company__c = :companyId
              AND Is_Active__c = true
            ORDER BY Code__c ASC
        ]) {
            dto.departments.add(
                new OptionDTO(
                    department.Id,
                    department.Code__c
                    + ' · '
                    + department.Name
                )
            );
        }

        for (Cost_Center__c costCenter : [
            SELECT Id, Name, Code__c
            FROM Cost_Center__c
            WHERE Company__c = :companyId
              AND Is_Active__c = true
            ORDER BY Code__c ASC
        ]) {
            dto.costCenters.add(
                new OptionDTO(
                    costCenter.Id,
                    costCenter.Code__c
                    + ' · '
                    + costCenter.Name
                )
            );
        }

        for (Project__c project : [
            SELECT Id, Name, Project_Code__c
            FROM Project__c
            WHERE Company__c = :companyId
              AND Status__c = 'Active'
            ORDER BY Project_Code__c ASC
        ]) {
            dto.projects.add(
                new OptionDTO(
                    project.Id,
                    project.Project_Code__c
                    + ' · '
                    + project.Name
                )
            );
        }

        for (Journal_Entry__c journal : [
            SELECT Id,
                   Name,
                   Accounting_Date__c,
                   Description__c,
                   Accounting_Period__c
            FROM Journal_Entry__c
            WHERE Company__c = :companyId
              AND Status__c = 'Draft'
            ORDER BY Accounting_Date__c DESC,
                     CreatedDate DESC
            LIMIT 100
        ]) {
            DraftSummaryDTO draft = new DraftSummaryDTO();
            draft.journalId = journal.Id;
            draft.journalName = journal.Name;
            draft.accountingDate = journal.Accounting_Date__c;
            draft.description = journal.Description__c;
            draft.periodId = journal.Accounting_Period__c;
            dto.drafts.add(draft);
        }

        for (Journal_Entry__c journal : [
            SELECT Id,
                   Name,
                   Accounting_Date__c,
                   Description__c,
                   Posting_Key__c
            FROM Journal_Entry__c
            WHERE Company__c = :companyId
              AND Status__c = 'Posted'
              AND Reversal_Of__c = null
            ORDER BY Accounting_Date__c DESC,
                     Posted_At__c DESC
            LIMIT 100
        ]) {
            PostedSummaryDTO posted =
                new PostedSummaryDTO();

            posted.journalId =
                journal.Id;
            posted.journalName =
                journal.Name;
            posted.accountingDate =
                journal.Accounting_Date__c;
            posted.description =
                journal.Description__c;
            posted.postingKey =
                journal.Posting_Key__c;

            dto.postedJournals.add(
                posted
            );
        }

        return dto;
    }

    @AuraEnabled(cacheable=true)
    public static JournalDTO getJournal(Id journalId) {
        if (journalId == null) {
            throw new AuraHandledException('Journal Entry is required.');
        }

        assertReadAccess();

        Journal_Entry__c journal = [
            SELECT Id,
                   Name,
                   Company__c,
                   Accounting_Period__c,
                   Accounting_Date__c,
                   Entry_Type__c,
                   Status__c,
                   Description__c,
                   Posting_Key__c,
                   Posted_At__c,
                   Accounting_Event__c,
                   Reversal_Journal__c,
                   Reversal_Of__c
            FROM Journal_Entry__c
            WHERE Id = :journalId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(journal.Company__c);
        SABAccessControlService.assertRecordReadAccess(journal.Id);

        List<Journal_Entry_Line__c> lines = [
            SELECT Id,
                   Line_Number__c,
                   GL_Account__c,
                   Debit_Base__c,
                   Credit_Base__c,
                   Explanation__c,
                   Department__c,
                   Cost_Center__c,
                   Project__c
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__c = :journal.Id
            ORDER BY Line_Number__c ASC
        ];

        return toJournalDTO(journal, lines);
    }

    @AuraEnabled
    public static ValidationDTO validateJournal(
        Id journalId
    ) {
        assertReadAccess();

        if (journalId == null) {
            throw new AuraHandledException(
                'Save the Draft Journal before validating it.'
            );
        }

        try {
            Journal_Entry__c journal = [
                SELECT Id, Company__c
                FROM Journal_Entry__c
                WHERE Id = :journalId
                LIMIT 1
            ];

            SABCompanyAccessService.assertCompanyAccess(
                journal.Company__c
            );
            SABAccessControlService.assertRecordReadAccess(
                journal.Id
            );

            SABJournalValidationService.ValidationResult result =
                SABJournalValidationService.validateForPosting(
                    journalId
                );

            ValidationDTO dto = new ValidationDTO();
            dto.isValid = result.isValid;
            dto.errors = result.errors;
            dto.lineCount = result.lineCount;
            dto.totalDebit = result.totalDebit;
            dto.totalCredit = result.totalCredit;

            return dto;
        } catch (Exception ex) {
            throw new AuraHandledException(
                ex.getMessage()
            );
        }
    }

    @AuraEnabled
    public static PostingDTO postJournal(
        Id journalId
    ) {
        assertReadAccess();

        if (journalId == null) {
            throw new AuraHandledException(
                'Save the Draft Journal before posting it.'
            );
        }

        try {
            Journal_Entry__c journal = [
                SELECT Id,
                       Company__c,
                       Status__c,
                       Version__c
                FROM Journal_Entry__c
                WHERE Id = :journalId
                LIMIT 1
            ];

            SABCompanyAccessService.assertCompanyAccess(
                journal.Company__c
            );
            SABAccessControlService.assertRecordReadAccess(
                journal.Id
            );

            Integer sourceVersion =
                journal.Version__c == null
                    ? 1
                    : journal.Version__c.intValue();

            String versionText =
                String.valueOf(sourceVersion);

            // Stable per persisted journal version. Repeated clicks for the
            // same saved version reach the Posting Service with the same keys,
            // so its existing idempotent replay contract remains authoritative.
            String postingKey =
                'MJ-'
                + String.valueOf(journal.Id)
                + '-V'
                + versionText;

            String eventKey =
                'EVT-MJ-'
                + String.valueOf(journal.Id)
                + '-V'
                + versionText;

            SABAccountingEventService.ReservationRequest eventRequest =
                new SABAccountingEventService.ReservationRequest();

            eventRequest.companyId =
                journal.Company__c;
            eventRequest.adapterKey =
                'MANUAL_JOURNAL';
            eventRequest.requestKey =
                'REQ-' + eventKey;
            eventRequest.eventKey =
                eventKey;
            eventRequest.eventType =
                'Manual Journal';
            eventRequest.sourceBusinessKey =
                postingKey;
            eventRequest.sourceRecordId =
                String.valueOf(journal.Id);
            eventRequest.sourceType =
                'Journal_Entry__c';
            eventRequest.sourceVersion =
                sourceVersion;

            SABPostingService.PostingRequest request =
                new SABPostingService.PostingRequest();

            request.journalEntryId =
                journal.Id;
            request.postingKey =
                postingKey;
            request.eventRequest =
                eventRequest;

            SABPostingService.PostingResult result =
                SABPostingService.postDraftJournal(
                    request
                );

            PostingDTO dto = new PostingDTO();
            dto.journalId =
                result.journalEntryId;
            dto.accountingEventId =
                result.accountingEventId;
            dto.postingKey =
                result.postingKey;
            dto.postedAt =
                result.postedAt;
            dto.replay =
                result.replay;
            dto.status =
                'Posted';

            return dto;
        } catch (Exception ex) {
            throw new AuraHandledException(
                ex.getMessage()
            );
        }
    }

    @AuraEnabled
    public static ReversalDTO reverseJournal(
        Id originalJournalId,
        Id reversalPeriodId,
        Date reversalDate,
        String reason
    ) {
        assertReadAccess();

        if (originalJournalId == null) {
            throw new AuraHandledException(
                'Select a Posted Journal Entry to reverse.'
            );
        }

        if (reversalPeriodId == null) {
            throw new AuraHandledException(
                'Reversal Accounting Period is required.'
            );
        }

        if (reversalDate == null) {
            throw new AuraHandledException(
                'Reversal Accounting Date is required.'
            );
        }

        if (String.isBlank(reason)) {
            throw new AuraHandledException(
                'Reversal reason is required.'
            );
        }

        try {
            Journal_Entry__c original = [
                SELECT Id,
                       Company__c,
                       Status__c,
                       Version__c
                FROM Journal_Entry__c
                WHERE Id = :originalJournalId
                LIMIT 1
            ];

            SABCompanyAccessService.assertCompanyAccess(
                original.Company__c
            );

            SABAccessControlService.assertRecordReadAccess(
                original.Id
            );

            Integer sourceVersion =
                original.Version__c == null
                    ? 1
                    : original.Version__c.intValue();

            String versionText =
                String.valueOf(sourceVersion);

            String stableSuffix =
                String.valueOf(original.Id)
                + '-V'
                + versionText;

            SABReversalService.ReversalRequest request =
                new SABReversalService.ReversalRequest();

            request.originalJournalEntryId =
                original.Id;
            request.reversalAccountingPeriodId =
                reversalPeriodId;
            request.reversalAccountingDate =
                reversalDate;
            request.postingKey =
                'REV-' + stableSuffix;
            request.eventKey =
                'EVT-REV-' + stableSuffix;
            request.requestKey =
                'REQ-REV-' + stableSuffix;
            request.reason =
                reason.trim();

            SABReversalService.ReversalResult result =
                SABReversalService.reversePostedJournal(
                    request
                );

            Journal_Entry__c reversal = [
                SELECT Id,
                       Name,
                       Posting_Key__c,
                       Accounting_Date__c
                FROM Journal_Entry__c
                WHERE Id = :result.reversalJournalEntryId
                LIMIT 1
            ];

            Journal_Entry__c refreshedOriginal = [
                SELECT Id,
                       Status__c
                FROM Journal_Entry__c
                WHERE Id = :original.Id
                LIMIT 1
            ];

            ReversalDTO dto =
                new ReversalDTO();

            dto.originalJournalId =
                result.originalJournalEntryId;
            dto.reversalJournalId =
                result.reversalJournalEntryId;
            dto.reversalJournalName =
                reversal.Name;
            dto.reversalAccountingEventId =
                result.reversalAccountingEventId;
            dto.reversalPostingKey =
                reversal.Posting_Key__c;
            dto.reversalAccountingDate =
                reversal.Accounting_Date__c;
            dto.replay =
                result.replay;
            dto.originalStatus =
                refreshedOriginal.Status__c;

            return dto;
        } catch (Exception ex) {
            throw new AuraHandledException(
                ex.getMessage()
            );
        }
    }

    @AuraEnabled
    public static JournalDTO saveDraft(DraftSaveRequest request) {
        validateSaveRequest(request);
        SABCompanyAccessService.assertCompanyAccess(request.companyId);

        Accounting_Company__c company = [
            SELECT Id, Functional_Currency__c
            FROM Accounting_Company__c
            WHERE Id = :request.companyId
              AND Is_Active__c = true
            LIMIT 1
        ];

        assertRelatedRecordsBelongToCompany(request);

        Journal_Entry__c journal;

        if (request.journalId == null) {
            assertJournalCreateAccess();

            journal = new Journal_Entry__c(
                Company__c = request.companyId,
                Accounting_Period__c = request.periodId,
                Accounting_Date__c = request.accountingDate,
                Entry_Type__c = 'Manual',
                Status__c = 'Draft',
                Description__c = request.description,
                Version__c = 1
            );

            insert journal;
        } else {
            assertJournalUpdateAccess();

            journal = [
                SELECT Id,
                       Company__c,
                       Status__c,
                       Version__c
                FROM Journal_Entry__c
                WHERE Id = :request.journalId
                LIMIT 1
                FOR UPDATE
            ];

            SABAccessControlService.assertRecordEditAccess(journal.Id);

            if (journal.Company__c != request.companyId) {
                throw new AuraHandledException(
                    'The Journal Entry belongs to a different Accounting Company.'
                );
            }

            if (journal.Status__c != 'Draft') {
                throw new AuraHandledException(
                    'Only Draft Journal Entries can be edited.'
                );
            }

            journal.Accounting_Period__c = request.periodId;
            journal.Accounting_Date__c = request.accountingDate;
            journal.Description__c = request.description;
            journal.Version__c =
                journal.Version__c == null
                    ? 1
                    : journal.Version__c + 1;

            update journal;

            assertLineDeleteAccess();

            List<Journal_Entry_Line__c> existingLines = [
                SELECT Id
                FROM Journal_Entry_Line__c
                WHERE Journal_Entry__c = :journal.Id
            ];

            if (!existingLines.isEmpty()) {
                delete existingLines;
            }
        }

        assertLineCreateAccess();

        List<Journal_Entry_Line__c> linesToInsert =
            new List<Journal_Entry_Line__c>();

        Integer lineNumber = 1;

        for (DraftLineInput inputLine : request.lines) {
            Decimal debit =
                inputLine.debit == null
                    ? 0
                    : inputLine.debit;

            Decimal credit =
                inputLine.credit == null
                    ? 0
                    : inputLine.credit;

            if (debit < 0 || credit < 0) {
                throw new AuraHandledException(
                    'Debit and Credit amounts cannot be negative.'
                );
            }

            if (
                (debit == 0 && credit == 0)
                || (debit > 0 && credit > 0)
            ) {
                throw new AuraHandledException(
                    'Each Journal line must contain either a Debit or a Credit amount.'
                );
            }

            linesToInsert.add(
                new Journal_Entry_Line__c(
                    Journal_Entry__c = journal.Id,
                    GL_Account__c = inputLine.glAccountId,
                    Line_Number__c = lineNumber,
                    Debit_Base__c = debit,
                    Credit_Base__c = credit,
                    Functional_Currency__c =
                        company.Functional_Currency__c,
                    Explanation__c = inputLine.explanation,
                    Department__c = inputLine.departmentId,
                    Cost_Center__c = inputLine.costCenterId,
                    Project__c = inputLine.projectId
                )
            );

            lineNumber++;
        }

        if (!linesToInsert.isEmpty()) {
            insert linesToInsert;
        }

        Journal_Entry__c storedJournal = [
            SELECT Id,
                   Name,
                   Company__c,
                   Accounting_Period__c,
                   Accounting_Date__c,
                   Entry_Type__c,
                   Status__c,
                   Description__c,
                   Posting_Key__c,
                   Posted_At__c,
                   Accounting_Event__c,
                   Reversal_Journal__c,
                   Reversal_Of__c
            FROM Journal_Entry__c
            WHERE Id = :journal.Id
            LIMIT 1
        ];

        List<Journal_Entry_Line__c> storedLines = [
            SELECT Id,
                   Line_Number__c,
                   GL_Account__c,
                   Debit_Base__c,
                   Credit_Base__c,
                   Explanation__c,
                   Department__c,
                   Cost_Center__c,
                   Project__c
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__c = :journal.Id
            ORDER BY Line_Number__c ASC
        ];

        return toJournalDTO(storedJournal, storedLines);
    }

    private static void validateSaveRequest(DraftSaveRequest request) {
        if (request == null) {
            throw new AuraHandledException('Journal request is required.');
        }

        assertCompanyId(request.companyId);

        if (request.periodId == null) {
            throw new AuraHandledException('Accounting Period is required.');
        }

        if (request.accountingDate == null) {
            throw new AuraHandledException('Accounting Date is required.');
        }

        if (request.lines == null || request.lines.isEmpty()) {
            throw new AuraHandledException(
                'Add at least one Journal line before saving the Draft.'
            );
        }

        for (DraftLineInput inputLine : request.lines) {
            if (inputLine == null || inputLine.glAccountId == null) {
                throw new AuraHandledException(
                    'Every Journal line requires a GL Account.'
                );
            }
        }
    }

    private static void assertRelatedRecordsBelongToCompany(
        DraftSaveRequest request
    ) {
        Accounting_Period__c period = [
            SELECT Id, Company__c, Status__c
            FROM Accounting_Period__c
            WHERE Id = :request.periodId
            LIMIT 1
        ];

        if (
            period.Company__c != request.companyId
            || period.Status__c != 'Open'
        ) {
            throw new AuraHandledException(
                'Select an open Accounting Period belonging to the current Accounting Company.'
            );
        }

        Set<Id> glAccountIds = new Set<Id>();
        Set<Id> departmentIds = new Set<Id>();
        Set<Id> costCenterIds = new Set<Id>();
        Set<Id> projectIds = new Set<Id>();

        for (DraftLineInput inputLine : request.lines) {
            glAccountIds.add(inputLine.glAccountId);

            if (inputLine.departmentId != null) {
                departmentIds.add(inputLine.departmentId);
            }

            if (inputLine.costCenterId != null) {
                costCenterIds.add(inputLine.costCenterId);
            }

            if (inputLine.projectId != null) {
                projectIds.add(inputLine.projectId);
            }
        }

        Integer validGLCount = [
            SELECT COUNT()
            FROM GL_Account__c
            WHERE Id IN :glAccountIds
              AND Company__c = :request.companyId
              AND Is_Active__c = true
              AND Manual_Posting_Allowed__c = true
              AND Is_Control_Account__c = false
        ];

        if (validGLCount != glAccountIds.size()) {
            throw new AuraHandledException(
                'One or more GL Accounts are invalid for manual posting in the current Accounting Company.'
            );
        }

        if (!departmentIds.isEmpty()) {
            Integer validDepartmentCount = [
                SELECT COUNT()
                FROM Department__c
                WHERE Id IN :departmentIds
                  AND Company__c = :request.companyId
                  AND Is_Active__c = true
            ];

            if (validDepartmentCount != departmentIds.size()) {
                throw new AuraHandledException(
                    'One or more Departments are invalid for the current Accounting Company.'
                );
            }
        }

        if (!costCenterIds.isEmpty()) {
            Integer validCostCenterCount = [
                SELECT COUNT()
                FROM Cost_Center__c
                WHERE Id IN :costCenterIds
                  AND Company__c = :request.companyId
                  AND Is_Active__c = true
            ];

            if (validCostCenterCount != costCenterIds.size()) {
                throw new AuraHandledException(
                    'One or more Cost Centers are invalid for the current Accounting Company.'
                );
            }
        }

        if (!projectIds.isEmpty()) {
            Integer validProjectCount = [
                SELECT COUNT()
                FROM Project__c
                WHERE Id IN :projectIds
                  AND Company__c = :request.companyId
                  AND Status__c = 'Active'
            ];

            if (validProjectCount != projectIds.size()) {
                throw new AuraHandledException(
                    'One or more Projects are invalid for the current Accounting Company.'
                );
            }
        }
    }

    private static void assertCompanyId(Id companyId) {
        if (companyId == null) {
            throw new AuraHandledException(
                'Select an Accounting Company before using the Journal Workspace.'
            );
        }
    }

    private static void assertReadAccess() {
        SABAccessControlService.assertReadable(
            Journal_Entry__c.SObjectType,
            new List<Schema.SObjectField>{
                Journal_Entry__c.Company__c,
                Journal_Entry__c.Accounting_Period__c,
                Journal_Entry__c.Accounting_Date__c,
                Journal_Entry__c.Entry_Type__c,
                Journal_Entry__c.Status__c,
                Journal_Entry__c.Description__c,
                Journal_Entry__c.Posting_Key__c,
                Journal_Entry__c.Posted_At__c,
                Journal_Entry__c.Accounting_Event__c,
                Journal_Entry__c.Reversal_Journal__c,
                Journal_Entry__c.Reversal_Of__c
            }
        );

        SABAccessControlService.assertReadable(
            Journal_Entry_Line__c.SObjectType,
            new List<Schema.SObjectField>{
                Journal_Entry_Line__c.Journal_Entry__c,
                Journal_Entry_Line__c.GL_Account__c,
                Journal_Entry_Line__c.Line_Number__c,
                Journal_Entry_Line__c.Debit_Base__c,
                Journal_Entry_Line__c.Credit_Base__c,
                Journal_Entry_Line__c.Functional_Currency__c,
                Journal_Entry_Line__c.Explanation__c,
                Journal_Entry_Line__c.Department__c,
                Journal_Entry_Line__c.Cost_Center__c,
                Journal_Entry_Line__c.Project__c
            }
        );
    }

    private static void assertJournalCreateAccess() {
        SABAccessControlService.assertCreateable(
            Journal_Entry__c.SObjectType,
            new List<Schema.SObjectField>{
                Journal_Entry__c.Company__c,
                Journal_Entry__c.Accounting_Period__c,
                Journal_Entry__c.Accounting_Date__c,
                Journal_Entry__c.Entry_Type__c,
                Journal_Entry__c.Status__c,
                Journal_Entry__c.Description__c,
                Journal_Entry__c.Version__c
            }
        );
    }

    private static void assertJournalUpdateAccess() {
        SABAccessControlService.assertUpdateable(
            Journal_Entry__c.SObjectType,
            new List<Schema.SObjectField>{
                Journal_Entry__c.Accounting_Period__c,
                Journal_Entry__c.Accounting_Date__c,
                Journal_Entry__c.Description__c,
                Journal_Entry__c.Version__c
            }
        );
    }

    private static void assertLineCreateAccess() {
        SABAccessControlService.assertCreateable(
            Journal_Entry_Line__c.SObjectType,
            new List<Schema.SObjectField>{
                Journal_Entry_Line__c.Journal_Entry__c,
                Journal_Entry_Line__c.GL_Account__c,
                Journal_Entry_Line__c.Line_Number__c,
                Journal_Entry_Line__c.Debit_Base__c,
                Journal_Entry_Line__c.Credit_Base__c,
                Journal_Entry_Line__c.Functional_Currency__c,
                Journal_Entry_Line__c.Explanation__c,
                Journal_Entry_Line__c.Department__c,
                Journal_Entry_Line__c.Cost_Center__c,
                Journal_Entry_Line__c.Project__c
            }
        );
    }

    private static void assertLineDeleteAccess() {
        SABAccessControlService.assertDeletable(
            Journal_Entry_Line__c.SObjectType
        );
    }

    private static JournalDTO toJournalDTO(
        Journal_Entry__c journal,
        List<Journal_Entry_Line__c> lines
    ) {
        JournalDTO dto = new JournalDTO();
        dto.journalId = journal.Id;
        dto.journalName = journal.Name;
        dto.companyId = journal.Company__c;
        dto.periodId = journal.Accounting_Period__c;
        dto.accountingDate = journal.Accounting_Date__c;
        dto.entryType = journal.Entry_Type__c;
        dto.status = journal.Status__c;
        dto.description = journal.Description__c;
        dto.postingKey = journal.Posting_Key__c;
        dto.postedAt = journal.Posted_At__c;
        dto.accountingEventId = journal.Accounting_Event__c;
        dto.reversalJournalId = journal.Reversal_Journal__c;
        dto.reversalOfId = journal.Reversal_Of__c;
        dto.totalDebit = 0;
        dto.totalCredit = 0;
        dto.lines = new List<LineDTO>();

        for (Journal_Entry_Line__c line : lines) {
            LineDTO lineDTO = new LineDTO();
            lineDTO.lineId = line.Id;
            lineDTO.lineNumber =
                line.Line_Number__c == null
                    ? null
                    : line.Line_Number__c.intValue();
            lineDTO.glAccountId = line.GL_Account__c;
            lineDTO.debit =
                line.Debit_Base__c == null
                    ? 0
                    : line.Debit_Base__c;
            lineDTO.credit =
                line.Credit_Base__c == null
                    ? 0
                    : line.Credit_Base__c;
            lineDTO.explanation = line.Explanation__c;
            lineDTO.departmentId = line.Department__c;
            lineDTO.costCenterId = line.Cost_Center__c;
            lineDTO.projectId = line.Project__c;

            dto.totalDebit += lineDTO.debit;
            dto.totalCredit += lineDTO.credit;
            dto.lines.add(lineDTO);
        }

        return dto;
    }
}
