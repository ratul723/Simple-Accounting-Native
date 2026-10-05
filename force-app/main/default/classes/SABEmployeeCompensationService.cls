/**
 * G10A - Employee & Compensation Foundation.
 *
 * Scope:
 * - Employee master records remain separate from Salesforce Users.
 * - Employment is the company boundary and is effective-dated.
 * - Pay components may be company-specific or reusable/global.
 * - Employee pay assignments are versioned by effective dates.
 * - Benefit awards are proposed/approved/consumed/cancelled and can be
 *   consumed exactly once by a later payroll stage.
 *
 * This class intentionally does NOT calculate statutory payroll or post GL.
 * Those responsibilities belong to later G10 stages.
 */
public with sharing class SABEmployeeCompensationService {
    public class EmployeeCompensationException extends Exception {}

    private static final String EMPLOYEE_ACTIVE = 'Active';
    private static final String EMPLOYEE_INACTIVE = 'Inactive';
    private static final String EMPLOYMENT_ACTIVE = 'Active';
    private static final String EMPLOYMENT_LEAVE = 'Leave';
    private static final String EMPLOYMENT_ENDED = 'Ended';

    private static final String COMP_DRAFT = 'Draft';
    private static final String COMP_APPROVED = 'Approved';
    private static final String COMP_EXPIRED = 'Expired';

    private static final String AWARD_PROPOSED = 'Proposed';
    private static final String AWARD_APPROVED = 'Approved';
    private static final String AWARD_CONSUMED = 'Consumed';
    private static final String AWARD_CANCELLED = 'Cancelled';

    private static final String MANAGE_PERMISSION =
        'SAB_Manage_Employee_Compensation';
    private static final String APPROVE_PERMISSION =
        'SAB_Approve_Employee_Compensation';

    public class EmploymentDTO {
        @AuraEnabled public Id employmentId { get; set; }
        @AuraEnabled public Id employeeId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String employeeReference { get; set; }
        @AuraEnabled public Id userId { get; set; }
        @AuraEnabled public String employmentStatus { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date endDate { get; set; }
        @AuraEnabled public Id departmentId { get; set; }
        @AuraEnabled public String departmentName { get; set; }
        @AuraEnabled public Id costCenterId { get; set; }
        @AuraEnabled public String costCenterName { get; set; }
    }

    public class CompensationDTO {
        @AuraEnabled public Id assignmentId { get; set; }
        @AuraEnabled public Id employmentId { get; set; }
        @AuraEnabled public Id employeeId { get; set; }
        @AuraEnabled public String employeeReference { get; set; }
        @AuraEnabled public Id payComponentId { get; set; }
        @AuraEnabled public String payComponentName { get; set; }
        @AuraEnabled public String category { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Date effectiveFrom { get; set; }
        @AuraEnabled public Date effectiveTo { get; set; }
        @AuraEnabled public Boolean formulaBased { get; set; }
    }

    public class EmployeeRequest {
        @AuraEnabled public String employeeReference { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Id userId { get; set; }
    }

    public class EmploymentRequest {
        @AuraEnabled public Id employmentId { get; set; }
        @AuraEnabled public Id employeeId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public Id departmentId { get; set; }
        @AuraEnabled public Id costCenterId { get; set; }
        @AuraEnabled public String employmentStatus { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date endDate { get; set; }
    }

    public class PayComponentRequest {
        @AuraEnabled public Id payComponentId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String componentKey { get; set; }
        @AuraEnabled public String category { get; set; }
        @AuraEnabled public String countryRuleKey { get; set; }
        @AuraEnabled public Id expenseAccountId { get; set; }
        @AuraEnabled public Id liabilityAccountId { get; set; }
        @AuraEnabled public Boolean isActive { get; set; }
    }

    public class AssignmentRequest {
        @AuraEnabled public Id assignmentId { get; set; }
        @AuraEnabled public Id employmentId { get; set; }
        @AuraEnabled public Id payComponentId { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Date effectiveFrom { get; set; }
        @AuraEnabled public Date effectiveTo { get; set; }
        @AuraEnabled public String formulaParameterJson { get; set; }
    }

    public class BenefitAwardRequest {
        @AuraEnabled public Id awardId { get; set; }
        @AuraEnabled public Id employmentId { get; set; }
        @AuraEnabled public Id payComponentId { get; set; }
        @AuraEnabled public String awardKey { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Date servicePeriodStart { get; set; }
        @AuraEnabled public Date servicePeriodEnd { get; set; }
        @AuraEnabled public String reason { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<EmploymentDTO> getEmployments(
        Id companyId,
        Boolean includeEnded
    ) {
        requireCompany(companyId);
        assertReadableEmployment();

        List<EmploymentDTO> result = new List<EmploymentDTO>();
        List<Employment__c> rows;
        if (includeEnded == true) {
            rows = [
                SELECT Id,
                       Employee__c,
                       Employee__r.Employee_Reference__c,
                       Employee__r.User__c,
                       Company__c,
                       Department__c,
                       Department__r.Name,
                       Cost_Center__c,
                       Cost_Center__r.Name,
                       Employment_Status__c,
                       Start_Date__c,
                       End_Date__c
                FROM Employment__c
                WHERE Company__c = :companyId
                WITH USER_MODE
                ORDER BY Start_Date__c DESC, Id DESC
                LIMIT 2000
            ];
        } else {
            rows = [
                SELECT Id,
                       Employee__c,
                       Employee__r.Employee_Reference__c,
                       Employee__r.User__c,
                       Company__c,
                       Department__c,
                       Department__r.Name,
                       Cost_Center__c,
                       Cost_Center__r.Name,
                       Employment_Status__c,
                       Start_Date__c,
                       End_Date__c
                FROM Employment__c
                WHERE Company__c = :companyId
                  AND Employment_Status__c != :EMPLOYMENT_ENDED
                WITH USER_MODE
                ORDER BY Start_Date__c DESC, Id DESC
                LIMIT 2000
            ];
        }

        for (Employment__c employment : rows) {
            EmploymentDTO dto = new EmploymentDTO();
            dto.employmentId = employment.Id;
            dto.employeeId = employment.Employee__c;
            dto.companyId = employment.Company__c;
            dto.employeeReference = employment.Employee__r.Employee_Reference__c;
            dto.userId = employment.Employee__r.User__c;
            dto.employmentStatus = employment.Employment_Status__c;
            dto.startDate = employment.Start_Date__c;
            dto.endDate = employment.End_Date__c;
            dto.departmentId = employment.Department__c;
            dto.departmentName = employment.Department__r == null
                ? null
                : employment.Department__r.Name;
            dto.costCenterId = employment.Cost_Center__c;
            dto.costCenterName = employment.Cost_Center__r == null
                ? null
                : employment.Cost_Center__r.Name;
            result.add(dto);
        }
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<CompensationDTO> getCurrentCompensation(
        Id companyId,
        Date asOfDate
    ) {
        requireCompany(companyId);
        assertReadableAssignment();

        Date effectiveDate = asOfDate == null ? Date.today() : asOfDate;
        List<CompensationDTO> result = new List<CompensationDTO>();

        for (Employee_Pay_Component__c assignment : [
            SELECT Id,
                   Employment__c,
                   Employment__r.Employee__c,
                   Employment__r.Employee__r.Employee_Reference__c,
                   Pay_Component__c,
                   Pay_Component__r.Name,
                   Pay_Component__r.Category__c,
                   Amount__c,
                   Currency__c,
                   Effective_From__c,
                   Effective_To__c,
                   Formula_Parameter_JSON__c,
                   Status__c
            FROM Employee_Pay_Component__c
            WHERE Employment__r.Company__c = :companyId
              AND Status__c = :COMP_APPROVED
              AND Effective_From__c <= :effectiveDate
              AND (
                  Effective_To__c = null
                  OR Effective_To__c >= :effectiveDate
              )
            WITH USER_MODE
            ORDER BY Employment__r.Employee__r.Employee_Reference__c,
                     Pay_Component__r.Category__c,
                     Effective_From__c DESC
            LIMIT 5000
        ]) {
            result.add(toCompensationDTO(assignment));
        }
        return result;
    }

    @AuraEnabled
    public static Id createEmployee(EmployeeRequest request) {
        assertManagePermission();
        validateEmployeeRequest(request);
        assertEmployeeCreateable();

        Employee__c employee = new Employee__c(
            Employee_Reference__c = request.employeeReference.trim(),
            Status__c = String.isBlank(request.status)
                ? EMPLOYEE_ACTIVE
                : request.status,
            User__c = request.userId
        );

        WRITER.insertRow(employee);
        return employee.Id;
    }

    @AuraEnabled
    public static Id createOrUpdateEmployment(EmploymentRequest request) {
        assertManagePermission();
        validateEmploymentRequest(request);
        SABCompanyAccessService.assertCompanyAccess(request.companyId);

        if (request.employmentId == null) {
            assertEmploymentCreateable();
            Employee__c employee = loadEmployee(request.employeeId);
            assertEmployeeActiveForEmployment(employee);

            validateEmploymentDates(request.startDate, request.endDate);
            assertNoOverlappingEmployment(
                request.employeeId,
                request.companyId,
                request.startDate,
                request.endDate,
                null
            );

            Employment__c employment = new Employment__c(
                Employee__c = request.employeeId,
                Company__c = request.companyId,
                Department__c = request.departmentId,
                Cost_Center__c = request.costCenterId,
                Employment_Status__c = String.isBlank(request.employmentStatus)
                    ? EMPLOYMENT_ACTIVE
                    : request.employmentStatus,
                Start_Date__c = request.startDate,
                End_Date__c = request.endDate
            );
            WRITER.insertRow(employment);
            return employment.Id;
        }

        assertEmploymentUpdateable();
        Employment__c existing = loadEmployment(request.employmentId, true);
        if (existing.Company__c != request.companyId) {
            throw new EmployeeCompensationException(
                'Employment Company cannot be changed through G10A. Create a new effective-dated employment record for a company transfer.'
            );
        }

        validateEmploymentDates(request.startDate, request.endDate);
        assertNoOverlappingEmployment(
            existing.Employee__c,
            request.companyId,
            request.startDate,
            request.endDate,
            existing.Id
        );

        existing.Department__c = request.departmentId;
        existing.Cost_Center__c = request.costCenterId;
        existing.Employment_Status__c = String.isBlank(request.employmentStatus)
            ? existing.Employment_Status__c
            : request.employmentStatus;
        existing.Start_Date__c = request.startDate;
        existing.End_Date__c = request.endDate;
        WRITER.updateRow(existing);
        return existing.Id;
    }

    @AuraEnabled
    public static Id createOrUpdatePayComponent(PayComponentRequest request) {
        assertManagePermission();
        validatePayComponentRequest(request);

        if (request.companyId != null) {
            SABCompanyAccessService.assertCompanyAccess(request.companyId);
        }

        validateMappedAccounts(
            request.companyId,
            request.expenseAccountId,
            request.liabilityAccountId
        );

        if (request.payComponentId == null) {
            assertPayComponentCreateable();
            Pay_Component__c component = new Pay_Component__c(
                Name = request.name.trim(),
                Company__c = request.companyId,
                Component_Key__c = request.componentKey.trim(),
                Category__c = request.category,
                Country_Rule_Key__c = blankToNull(request.countryRuleKey),
                Expense_Account__c = request.expenseAccountId,
                Liability_Account__c = request.liabilityAccountId,
                Is_Active__c = request.isActive == null ? true : request.isActive
            );
            WRITER.insertRow(component);
            return component.Id;
        }

        assertPayComponentUpdateable();
        Pay_Component__c existing = [
            SELECT Id, Name, Company__c, Component_Key__c, Category__c,
                   Country_Rule_Key__c, Expense_Account__c,
                   Liability_Account__c, Is_Active__c
            FROM Pay_Component__c
            WHERE Id = :request.payComponentId
            WITH USER_MODE
            LIMIT 1
            FOR UPDATE
        ];

        if (existing.Company__c != request.companyId) {
            throw new EmployeeCompensationException(
                'Pay Component Company cannot be changed after creation.'
            );
        }

        existing.Name = request.name.trim();
        existing.Component_Key__c = request.componentKey.trim();
        existing.Category__c = request.category;
        existing.Country_Rule_Key__c = blankToNull(request.countryRuleKey);
        existing.Expense_Account__c = request.expenseAccountId;
        existing.Liability_Account__c = request.liabilityAccountId;
        if (request.isActive != null) {
            existing.Is_Active__c = request.isActive;
        }
        WRITER.updateRow(existing);
        return existing.Id;
    }

    @AuraEnabled
    public static Id createOrUpdateAssignment(AssignmentRequest request) {
        assertManagePermission();
        validateAssignmentRequest(request);

        Employee_Pay_Component__c existing;
        Employment__c employment = loadEmployment(request.employmentId, false);
        SABCompanyAccessService.assertCompanyAccess(employment.Company__c);
        Pay_Component__c component = loadPayComponent(request.payComponentId);

        if (component.Company__c != null && component.Company__c != employment.Company__c) {
            throw new EmployeeCompensationException(
                'Pay Component belongs to a different Accounting Company.'
            );
        }

        if (request.assignmentId == null) {
            assertAssignmentCreateable();
            assertNoOverlappingAssignment(
                request.employmentId,
                request.payComponentId,
                request.effectiveFrom,
                request.effectiveTo,
                null
            );

            existing = new Employee_Pay_Component__c(
                Employment__c = request.employmentId,
                Pay_Component__c = request.payComponentId,
                Amount__c = request.amount,
                Currency__c = normalizeCurrency(request.currencyCode),
                Effective_From__c = request.effectiveFrom,
                Effective_To__c = request.effectiveTo,
                Formula_Parameter_JSON__c = blankToNull(request.formulaParameterJson),
                Status__c = COMP_DRAFT
            );
            WRITER.insertRow(existing);
            return existing.Id;
        }

        assertAssignmentUpdateable();
        existing = [
            SELECT Id, Employment__c, Pay_Component__c, Amount__c,
                   Currency__c, Effective_From__c, Effective_To__c,
                   Formula_Parameter_JSON__c, Status__c,
                   Employment__r.Company__c
            FROM Employee_Pay_Component__c
            WHERE Id = :request.assignmentId
            WITH USER_MODE
            LIMIT 1
            FOR UPDATE
        ];

        if (existing.Status__c != COMP_DRAFT) {
            throw new EmployeeCompensationException(
                'Only Draft compensation assignments can be edited. Approved assignments are historical snapshots.'
            );
        }

        assertNoOverlappingAssignment(
            existing.Employment__c,
            existing.Pay_Component__c,
            request.effectiveFrom,
            request.effectiveTo,
            existing.Id
        );

        existing.Amount__c = request.amount;
        existing.Currency__c = normalizeCurrency(request.currencyCode);
        existing.Effective_From__c = request.effectiveFrom;
        existing.Effective_To__c = request.effectiveTo;
        existing.Formula_Parameter_JSON__c = blankToNull(request.formulaParameterJson);
        WRITER.updateRow(existing);
        return existing.Id;
    }

    @AuraEnabled
    public static Id approveAssignment(Id assignmentId) {
        assertApprovePermission();
        // G10H: field-level update check for exactly the fields this action sets.
        SABAccessControlService.assertUpdateable(Employee_Pay_Component__c.SObjectType,
            new List<Schema.SObjectField>{Employee_Pay_Component__c.Status__c});
        Employee_Pay_Component__c assignment = loadAssignment(assignmentId, true);
        SABCompanyAccessService.assertCompanyAccess(assignment.Employment__r.Company__c);

        if (assignment.Status__c != COMP_DRAFT) {
            throw new EmployeeCompensationException(
                'Only Draft compensation assignments can be approved.'
            );
        }

        assertNoOverlappingAssignment(
            assignment.Employment__c,
            assignment.Pay_Component__c,
            assignment.Effective_From__c,
            assignment.Effective_To__c,
            assignment.Id
        );

        if (assignment.Amount__c == null && String.isBlank(assignment.Formula_Parameter_JSON__c)) {
            throw new EmployeeCompensationException(
                'Compensation assignment requires an amount or formula parameters before approval.'
            );
        }

        assignment.Status__c = COMP_APPROVED;
        WRITER.updateRow(assignment);
        return assignment.Id;
    }

    @AuraEnabled
    public static Id expireAssignment(Id assignmentId, Date effectiveTo) {
        assertManagePermission();
        SABAccessControlService.assertUpdateable(Employee_Pay_Component__c.SObjectType,
            new List<Schema.SObjectField>{Employee_Pay_Component__c.Status__c, Employee_Pay_Component__c.Effective_To__c});
        Employee_Pay_Component__c assignment = loadAssignment(assignmentId, true);
        SABCompanyAccessService.assertCompanyAccess(assignment.Employment__r.Company__c);

        if (assignment.Status__c != COMP_APPROVED) {
            throw new EmployeeCompensationException(
                'Only Approved compensation assignments can be expired.'
            );
        }

        if (effectiveTo == null || effectiveTo < assignment.Effective_From__c) {
            throw new EmployeeCompensationException(
                'Expiration date must be on or after the assignment effective-from date.'
            );
        }

        assignment.Effective_To__c = effectiveTo;
        assignment.Status__c = COMP_EXPIRED;
        WRITER.updateRow(assignment);
        return assignment.Id;
    }

    @AuraEnabled
    public static Id createBenefitAward(BenefitAwardRequest request) {
        assertManagePermission();
        validateBenefitAwardRequest(request);

        Employment__c employment = loadEmployment(request.employmentId, false);
        SABCompanyAccessService.assertCompanyAccess(employment.Company__c);
        Pay_Component__c component = loadPayComponent(request.payComponentId);

        if (component.Company__c != null && component.Company__c != employment.Company__c) {
            throw new EmployeeCompensationException(
                'Benefit Pay Component belongs to a different Accounting Company.'
            );
        }

        assertBenefitAwardCreateable();

        if (new Store().awardKeyExists(request.awardKey.trim())) {
            throw new EmployeeCompensationException(
                'Benefit Award Key already exists. Use a unique award key.'
            );
        }

        Benefit_Award__c award = new Benefit_Award__c(
            Employment__c = request.employmentId,
            Pay_Component__c = request.payComponentId,
            Award_Key__c = request.awardKey.trim(),
            Amount__c = request.amount,
            Quantity__c = request.quantity,
            Currency__c = normalizeCurrency(request.currencyCode),
            Service_Period_Start__c = request.servicePeriodStart,
            Service_Period_End__c = request.servicePeriodEnd,
            Reason__c = blankToNull(request.reason),
            Status__c = AWARD_PROPOSED
        );
        WRITER.insertRow(award);
        return award.Id;
    }

    @AuraEnabled
    public static Id approveBenefitAward(Id awardId) {
        assertApprovePermission();
        SABAccessControlService.assertUpdateable(Benefit_Award__c.SObjectType, new List<Schema.SObjectField>{
            Benefit_Award__c.Status__c, Benefit_Award__c.Approved_At__c, Benefit_Award__c.Approved_By__c});
        Benefit_Award__c award = loadBenefitAward(awardId, true);
        SABCompanyAccessService.assertCompanyAccess(award.Employment__r.Company__c);

        if (award.Status__c != AWARD_PROPOSED) {
            throw new EmployeeCompensationException(
                'Only Proposed Benefit Awards can be approved.'
            );
        }

        if (award.Amount__c <= 0) {
            throw new EmployeeCompensationException(
                'Benefit Award amount must be greater than zero.'
            );
        }

        award.Status__c = AWARD_APPROVED;
        award.Approved_At__c = System.now();
        award.Approved_By__c = UserInfo.getUserId();
        WRITER.updateRow(award);
        return award.Id;
    }

    @AuraEnabled
    public static Id cancelBenefitAward(Id awardId) {
        assertManagePermission();
        SABAccessControlService.assertUpdateable(Benefit_Award__c.SObjectType,
            new List<Schema.SObjectField>{Benefit_Award__c.Status__c});
        Benefit_Award__c award = loadBenefitAward(awardId, true);
        SABCompanyAccessService.assertCompanyAccess(award.Employment__r.Company__c);

        if (award.Status__c == AWARD_CONSUMED) {
            throw new EmployeeCompensationException(
                'Consumed Benefit Awards cannot be cancelled.'
            );
        }
        if (award.Status__c == AWARD_CANCELLED) {
            return award.Id;
        }

        award.Status__c = AWARD_CANCELLED;
        WRITER.updateRow(award);
        return award.Id;
    }

    private static void requireCompany(Id companyId) {
        if (companyId == null) {
            throw new EmployeeCompensationException(
                'Accounting Company is required.'
            );
        }
        SABCompanyAccessService.assertCompanyAccess(companyId);
    }

    private static void assertManagePermission() {
        SABPermissionService.assertPermission(
            MANAGE_PERMISSION,
            'You do not have permission to manage employee compensation.'
        );
    }

    private static void assertApprovePermission() {
        SABPermissionService.assertPermission(
            APPROVE_PERMISSION,
            'You do not have permission to approve employee compensation.'
        );
    }

    private static void assertReadableEmployment() {
        SABAccessControlService.assertReadable(
            Employment__c.SObjectType,
            new List<Schema.SObjectField>{
                Employment__c.Employee__c,
                Employment__c.Company__c,
                Employment__c.Department__c,
                Employment__c.Cost_Center__c,
                Employment__c.Employment_Status__c,
                Employment__c.Start_Date__c,
                Employment__c.End_Date__c
            }
        );
        SABAccessControlService.assertReadable(
            Employee__c.SObjectType,
            new List<Schema.SObjectField>{
                Employee__c.Employee_Reference__c,
                Employee__c.User__c
            }
        );
    }

    private static void assertReadableAssignment() {
        SABAccessControlService.assertReadable(
            Employee_Pay_Component__c.SObjectType,
            new List<Schema.SObjectField>{
                Employee_Pay_Component__c.Employment__c,
                Employee_Pay_Component__c.Pay_Component__c,
                Employee_Pay_Component__c.Amount__c,
                Employee_Pay_Component__c.Currency__c,
                Employee_Pay_Component__c.Effective_From__c,
                Employee_Pay_Component__c.Effective_To__c,
                Employee_Pay_Component__c.Formula_Parameter_JSON__c,
                Employee_Pay_Component__c.Status__c
            }
        );
    }

    private static void assertEmployeeCreateable() {
        SABAccessControlService.assertCreateable(
            Employee__c.SObjectType,
            new List<Schema.SObjectField>{
                Employee__c.Employee_Reference__c,
                Employee__c.Status__c,
                Employee__c.User__c
            }
        );
    }

    private static void assertEmploymentCreateable() {
        SABAccessControlService.assertCreateable(
            Employment__c.SObjectType,
            new List<Schema.SObjectField>{
                Employment__c.Employee__c,
                Employment__c.Company__c,
                Employment__c.Department__c,
                Employment__c.Cost_Center__c,
                Employment__c.Employment_Status__c,
                Employment__c.Start_Date__c,
                Employment__c.End_Date__c
            }
        );
    }

    private static void assertEmploymentUpdateable() {
        SABAccessControlService.assertUpdateable(
            Employment__c.SObjectType,
            new List<Schema.SObjectField>{
                Employment__c.Department__c,
                Employment__c.Cost_Center__c,
                Employment__c.Employment_Status__c,
                Employment__c.Start_Date__c,
                Employment__c.End_Date__c
            }
        );
    }

    private static void assertPayComponentCreateable() {
        SABAccessControlService.assertCreateable(
            Pay_Component__c.SObjectType,
            new List<Schema.SObjectField>{
                Pay_Component__c.Name,
                Pay_Component__c.Company__c,
                Pay_Component__c.Component_Key__c,
                Pay_Component__c.Category__c,
                Pay_Component__c.Country_Rule_Key__c,
                Pay_Component__c.Expense_Account__c,
                Pay_Component__c.Liability_Account__c,
                Pay_Component__c.Is_Active__c
            }
        );
    }

    private static void assertPayComponentUpdateable() {
        SABAccessControlService.assertUpdateable(
            Pay_Component__c.SObjectType,
            new List<Schema.SObjectField>{
                Pay_Component__c.Name,
                Pay_Component__c.Component_Key__c,
                Pay_Component__c.Category__c,
                Pay_Component__c.Country_Rule_Key__c,
                Pay_Component__c.Expense_Account__c,
                Pay_Component__c.Liability_Account__c,
                Pay_Component__c.Is_Active__c
            }
        );
    }

    private static void assertAssignmentCreateable() {
        SABAccessControlService.assertCreateable(
            Employee_Pay_Component__c.SObjectType,
            new List<Schema.SObjectField>{
                Employee_Pay_Component__c.Employment__c,
                Employee_Pay_Component__c.Pay_Component__c,
                Employee_Pay_Component__c.Amount__c,
                Employee_Pay_Component__c.Currency__c,
                Employee_Pay_Component__c.Effective_From__c,
                Employee_Pay_Component__c.Effective_To__c,
                Employee_Pay_Component__c.Formula_Parameter_JSON__c,
                Employee_Pay_Component__c.Status__c
            }
        );
    }

    private static void assertAssignmentUpdateable() {
        SABAccessControlService.assertUpdateable(
            Employee_Pay_Component__c.SObjectType,
            new List<Schema.SObjectField>{
                Employee_Pay_Component__c.Amount__c,
                Employee_Pay_Component__c.Currency__c,
                Employee_Pay_Component__c.Effective_From__c,
                Employee_Pay_Component__c.Effective_To__c,
                Employee_Pay_Component__c.Formula_Parameter_JSON__c
            }
        );
    }

    private static void assertBenefitAwardCreateable() {
        SABAccessControlService.assertCreateable(
            Benefit_Award__c.SObjectType,
            new List<Schema.SObjectField>{
                Benefit_Award__c.Employment__c,
                Benefit_Award__c.Pay_Component__c,
                Benefit_Award__c.Award_Key__c,
                Benefit_Award__c.Amount__c,
                Benefit_Award__c.Quantity__c,
                Benefit_Award__c.Currency__c,
                Benefit_Award__c.Service_Period_Start__c,
                Benefit_Award__c.Service_Period_End__c,
                Benefit_Award__c.Reason__c,
                Benefit_Award__c.Status__c
            }
        );
    }

    private static void validateEmployeeRequest(EmployeeRequest request) {
        if (request == null || String.isBlank(request.employeeReference)) {
            throw new EmployeeCompensationException('Employee Reference is required.');
        }
        if (!String.isBlank(request.status)
            && request.status != EMPLOYEE_ACTIVE
            && request.status != EMPLOYEE_INACTIVE) {
            throw new EmployeeCompensationException('Employee Status must be Active or Inactive.');
        }
    }

    private static void validateEmploymentRequest(EmploymentRequest request) {
        if (request == null) {
            throw new EmployeeCompensationException('Employment request is required.');
        }
        if (request.employeeId == null) {
            throw new EmployeeCompensationException('Employee is required.');
        }
        if (request.companyId == null) {
            throw new EmployeeCompensationException('Accounting Company is required.');
        }
        if (request.startDate == null) {
            throw new EmployeeCompensationException('Employment Start Date is required.');
        }
        if (!String.isBlank(request.employmentStatus)
            && request.employmentStatus != EMPLOYMENT_ACTIVE
            && request.employmentStatus != EMPLOYMENT_LEAVE
            && request.employmentStatus != EMPLOYMENT_ENDED) {
            throw new EmployeeCompensationException('Employment Status must be Active, Leave, or Ended.');
        }
    }

    private static void validatePayComponentRequest(PayComponentRequest request) {
        if (request == null) {
            throw new EmployeeCompensationException('Pay Component request is required.');
        }
        if (String.isBlank(request.name)) {
            throw new EmployeeCompensationException('Pay Component Name is required.');
        }
        if (String.isBlank(request.componentKey)) {
            throw new EmployeeCompensationException('Component Key is required.');
        }
        if (String.isBlank(request.category)) {
            throw new EmployeeCompensationException('Pay Component Category is required.');
        }
        Set<String> allowed = new Set<String>{
            'Basic Salary', 'Incentive', 'Food Allowance',
            'Deduction', 'Employer Contribution', 'Other'
        };
        if (!allowed.contains(request.category)) {
            throw new EmployeeCompensationException('Unsupported Pay Component Category.');
        }
    }

    private static void validateAssignmentRequest(AssignmentRequest request) {
        if (request == null) {
            throw new EmployeeCompensationException('Compensation assignment request is required.');
        }
        if (request.employmentId == null) {
            throw new EmployeeCompensationException('Employment is required.');
        }
        if (request.payComponentId == null) {
            throw new EmployeeCompensationException('Pay Component is required.');
        }
        if (request.effectiveFrom == null) {
            throw new EmployeeCompensationException('Effective From is required.');
        }
        validateEffectiveDates(request.effectiveFrom, request.effectiveTo);
        if (request.amount != null && request.amount < 0) {
            throw new EmployeeCompensationException('Compensation amount cannot be negative.');
        }
        if (request.amount == null && String.isBlank(request.formulaParameterJson)) {
            throw new EmployeeCompensationException('Provide an amount or supported formula parameters.');
        }
        if (String.isBlank(request.currencyCode)) {
            throw new EmployeeCompensationException('Currency is required.');
        }
    }

    private static void validateBenefitAwardRequest(BenefitAwardRequest request) {
        if (request == null) {
            throw new EmployeeCompensationException('Benefit Award request is required.');
        }
        if (request.employmentId == null) {
            throw new EmployeeCompensationException('Employment is required.');
        }
        if (request.payComponentId == null) {
            throw new EmployeeCompensationException('Pay Component is required.');
        }
        if (String.isBlank(request.awardKey)) {
            throw new EmployeeCompensationException('Award Key is required.');
        }
        if (request.amount == null || request.amount <= 0) {
            throw new EmployeeCompensationException('Benefit Award amount must be greater than zero.');
        }
        if (String.isBlank(request.currencyCode)) {
            throw new EmployeeCompensationException('Currency is required.');
        }
        if (request.servicePeriodStart == null) {
            throw new EmployeeCompensationException('Service Period Start is required.');
        }
        if (request.servicePeriodEnd != null
            && request.servicePeriodEnd < request.servicePeriodStart) {
            throw new EmployeeCompensationException('Service Period End cannot be before Service Period Start.');
        }
    }

    private static void validateEmploymentDates(Date startDate, Date endDate) {
        if (startDate == null) {
            throw new EmployeeCompensationException('Employment Start Date is required.');
        }
        if (endDate != null && endDate < startDate) {
            throw new EmployeeCompensationException('Employment End Date cannot be before Start Date.');
        }
    }

    private static void validateEffectiveDates(Date startDate, Date endDate) {
        if (startDate == null) {
            throw new EmployeeCompensationException('Effective From is required.');
        }
        if (endDate != null && endDate < startDate) {
            throw new EmployeeCompensationException('Effective To cannot be before Effective From.');
        }
    }

    private static void assertEmployeeActiveForEmployment(Employee__c employee) {
        if (employee.Status__c == EMPLOYEE_INACTIVE) {
            throw new EmployeeCompensationException(
                'An Inactive Employee cannot receive a new Employment record.'
            );
        }
    }

    private static void assertNoOverlappingEmployment(
        Id employeeId,
        Id companyId,
        Date startDate,
        Date endDate,
        Id excludeId
    ) {
        List<Employment__c> existing = new Store().employmentsFor(employeeId, companyId);

        for (Employment__c row : existing) {
            if (excludeId != null && row.Id == excludeId) {
                continue;
            }
            if (datesOverlap(
                startDate,
                endDate,
                row.Start_Date__c,
                row.End_Date__c
            )) {
                throw new EmployeeCompensationException(
                    'Employment dates overlap an existing employment record for this employee and company.'
                );
            }
        }
    }

    private static void assertNoOverlappingAssignment(
        Id employmentId,
        Id payComponentId,
        Date startDate,
        Date endDate,
        Id excludeId
    ) {
        List<Employee_Pay_Component__c> existing = new Store().openAssignmentsFor(employmentId, payComponentId);

        for (Employee_Pay_Component__c row : existing) {
            if (excludeId != null && row.Id == excludeId) {
                continue;
            }
            if (datesOverlap(
                startDate,
                endDate,
                row.Effective_From__c,
                row.Effective_To__c
            )) {
                throw new EmployeeCompensationException(
                    'Compensation effective dates overlap an existing assignment for the same employee and pay component.'
                );
            }
        }
    }

    private static Boolean datesOverlap(
        Date startA,
        Date endA,
        Date startB,
        Date endB
    ) {
        Date openEnd = Date.newInstance(9999, 12, 31);
        Date effectiveEndA = endA == null ? openEnd : endA;
        Date effectiveEndB = endB == null ? openEnd : endB;
        return startA <= effectiveEndB && startB <= effectiveEndA;
    }

    private static void validateMappedAccounts(
        Id companyId,
        Id expenseAccountId,
        Id liabilityAccountId
    ) {
        Set<Id> accountIds = new Set<Id>();
        if (expenseAccountId != null) accountIds.add(expenseAccountId);
        if (liabilityAccountId != null) accountIds.add(liabilityAccountId);
        if (accountIds.isEmpty()) return;

        List<GL_Account__c> accounts = new Store().accounts(accountIds);

        if (accounts.size() != accountIds.size()) {
            throw new EmployeeCompensationException('One or more mapped GL Accounts could not be found.');
        }

        for (GL_Account__c account : accounts) {
            if (!account.Is_Active__c) {
                throw new EmployeeCompensationException('Mapped Pay Component GL Account must be active.');
            }
            if (companyId != null && account.Company__c != companyId) {
                throw new EmployeeCompensationException('Mapped Pay Component GL Account must belong to the same Accounting Company.');
            }
        }
    }

    private static Employee__c loadEmployee(Id employeeId) {
        List<Employee__c> rows = [
            SELECT Id, Employee_Reference__c, Status__c, User__c
            FROM Employee__c
            WHERE Id = :employeeId
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw new EmployeeCompensationException('Employee not found.');
        }
        return rows[0];
    }

    private static Employment__c loadEmployment(Id employmentId, Boolean forUpdate) {
        String query =
            'SELECT Id, Employee__c, Company__c, Department__c, Cost_Center__c, '
            + 'Employment_Status__c, Start_Date__c, End_Date__c '
            + 'FROM Employment__c WHERE Id = :employmentId LIMIT 1';
        if (forUpdate) query += ' FOR UPDATE';
        List<Employment__c> rows = Database.queryWithBinds(query,
            new Map<String, Object>{'employmentId' => employmentId}, AccessLevel.USER_MODE);
        if (rows.isEmpty()) {
            throw new EmployeeCompensationException('Employment not found.');
        }
        return rows[0];
    }

    private static Pay_Component__c loadPayComponent(Id payComponentId) {
        List<Pay_Component__c> rows = [
            SELECT Id, Name, Company__c, Category__c, Is_Active__c
            FROM Pay_Component__c
            WHERE Id = :payComponentId
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw new EmployeeCompensationException('Pay Component not found.');
        }
        if (!rows[0].Is_Active__c) {
            throw new EmployeeCompensationException('Inactive Pay Components cannot receive new compensation assignments or awards.');
        }
        return rows[0];
    }

    private static Employee_Pay_Component__c loadAssignment(Id assignmentId, Boolean forUpdate) {
        String query =
            'SELECT Id, Employment__c, Pay_Component__c, Amount__c, Currency__c, '
            + 'Effective_From__c, Effective_To__c, Formula_Parameter_JSON__c, Status__c, '
            + 'Employment__r.Company__c '
            + 'FROM Employee_Pay_Component__c WHERE Id = :assignmentId LIMIT 1';
        if (forUpdate) query += ' FOR UPDATE';
        List<Employee_Pay_Component__c> rows = Database.queryWithBinds(query,
            new Map<String, Object>{'assignmentId' => assignmentId}, AccessLevel.USER_MODE);
        if (rows.isEmpty()) {
            throw new EmployeeCompensationException('Employee Pay Component assignment not found.');
        }
        return rows[0];
    }

    private static Benefit_Award__c loadBenefitAward(Id awardId, Boolean forUpdate) {
        String query =
            'SELECT Id, Employment__c, Pay_Component__c, Award_Key__c, Amount__c, '
            + 'Quantity__c, Currency__c, Service_Period_Start__c, Service_Period_End__c, '
            + 'Reason__c, Status__c, Approved_At__c, Approved_By__c, Consumed_By_Payroll_Run__c, '
            + 'Employment__r.Company__c '
            + 'FROM Benefit_Award__c WHERE Id = :awardId LIMIT 1';
        if (forUpdate) query += ' FOR UPDATE';
        List<Benefit_Award__c> rows = Database.queryWithBinds(query,
            new Map<String, Object>{'awardId' => awardId}, AccessLevel.USER_MODE);
        if (rows.isEmpty()) {
            throw new EmployeeCompensationException('Benefit Award not found.');
        }
        return rows[0];
    }

    private static CompensationDTO toCompensationDTO(Employee_Pay_Component__c row) {
        CompensationDTO dto = new CompensationDTO();
        dto.assignmentId = row.Id;
        dto.employmentId = row.Employment__c;
        dto.employeeId = row.Employment__r.Employee__c;
        dto.employeeReference = row.Employment__r.Employee__r.Employee_Reference__c;
        dto.payComponentId = row.Pay_Component__c;
        dto.payComponentName = row.Pay_Component__r.Name;
        dto.category = row.Pay_Component__r.Category__c;
        dto.amount = row.Amount__c;
        dto.currencyCode = row.Currency__c;
        dto.status = row.Status__c;
        dto.effectiveFrom = row.Effective_From__c;
        dto.effectiveTo = row.Effective_To__c;
        dto.formulaBased = !String.isBlank(row.Formula_Parameter_JSON__c);
        return dto;
    }

    private static String normalizeCurrency(String currencyCode) {
        String value = String.isBlank(currencyCode) ? null : currencyCode.trim().toUpperCase();
        if (String.isBlank(value) || value.length() != 3) {
            throw new EmployeeCompensationException('Currency must be a three-letter ISO-style code.');
        }
        return value;
    }

    private static String blankToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    // G10H: every DML statement runs through this writer. Callers have already run the permission check,
    // the company grant check and SABAccessControlService create/update checks for the fields they set.
    // It stays 'with sharing' so record access is exactly what it was before the refactor.
    private static final Writer WRITER = new Writer();

    @SuppressWarnings('PMD.ApexCRUDViolation')
    private with sharing class Writer {
        void insertRow(SObject row) {
            insert row;
        }
        void updateRow(SObject row) {
            update row;
        }
    }

    /**
     * G10H: integrity reads that must see every row. A duplicate award key or an overlapping employment or
     * assignment hidden by sharing must still block the change, so these run in system mode after the
     * caller's permission and company checks. They return only Ids, dates and statuses.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Boolean awardKeyExists(String awardKey) {
            return [SELECT COUNT() FROM Benefit_Award__c WHERE Award_Key__c = :awardKey WITH SYSTEM_MODE] > 0;
        }
        List<Employment__c> employmentsFor(Id employeeId, Id companyId) {
            return [SELECT Id, Start_Date__c, End_Date__c, Employment_Status__c FROM Employment__c
                WHERE Employee__c = :employeeId AND Company__c = :companyId WITH SYSTEM_MODE];
        }
        List<Employee_Pay_Component__c> openAssignmentsFor(Id employmentId, Id payComponentId) {
            return [SELECT Id, Effective_From__c, Effective_To__c, Status__c FROM Employee_Pay_Component__c
                WHERE Employment__c = :employmentId AND Pay_Component__c = :payComponentId AND Status__c != :COMP_EXPIRED
                WITH SYSTEM_MODE];
        }
        List<GL_Account__c> accounts(Set<Id> accountIds) {
            return [SELECT Id, Company__c, Is_Active__c FROM GL_Account__c WHERE Id IN :accountIds WITH SYSTEM_MODE];
        }
    }
}
