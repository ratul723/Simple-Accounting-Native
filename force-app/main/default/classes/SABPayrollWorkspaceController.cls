/**
 * G10G: Payroll & HR Workspace read controller.
 *
 * Thin, company-scoped read layer for the sabPayrollWorkspace LWC. Every query runs in user mode after
 * the payroll detail permission, the company grant and the CRUD/FLS read policy. All changes stay in the
 * G10A-G10F domain services, which the LWC calls directly:
 *   SABEmployeeCompensationService, SABPayrollCalculationService, SABPayrollReviewService,
 *   SABPayrollPostingService and SABPayrollSettlementService.
 * The capability flags only decide which buttons the UI offers; the services stay authoritative.
 */
public with sharing class SABPayrollWorkspaceController {
    public class PayrollWorkspaceException extends Exception {}

    private static final String VIEW_DETAIL = 'SAB_View_Payroll_Detail';
    private static final Integer RUN_LIMIT = 100;
    private static final Integer ROW_LIMIT = 200;
    private static final Set<String> SETTLEMENT_STATES = new Set<String>{'Posted', 'Settled'};

    // ------------------------------------------------------------------ DTOs

    public class Capabilities {
        @AuraEnabled public Boolean calculate;
        @AuraEnabled public Boolean submit;
        @AuraEnabled public Boolean approve;
        @AuraEnabled public Boolean cancel;
        @AuraEnabled public Boolean postPayroll;
        @AuraEnabled public Boolean postJournal;
        @AuraEnabled public Boolean processPayment;
        @AuraEnabled public Boolean authorizePayment;
        @AuraEnabled public Boolean manageCompensation;
        @AuraEnabled public Boolean approveCompensation;
    }

    public class OptionDTO {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public Date startDate;
        @AuraEnabled public Date endDate;
    }

    public class StateCount {
        @AuraEnabled public String state;
        @AuraEnabled public Integer count;
    }

    public class RunDTO {
        @AuraEnabled public Id runId;
        @AuraEnabled public String name;
        @AuraEnabled public String runKey;
        @AuraEnabled public Date periodStart;
        @AuraEnabled public Date periodEnd;
        @AuraEnabled public String state;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public Decimal grossTotal;
        @AuraEnabled public Decimal deductionTotal;
        @AuraEnabled public Decimal employerTotal;
        @AuraEnabled public Decimal netTotal;
        @AuraEnabled public Decimal settledAmount;
        @AuraEnabled public Decimal outstandingAmount;
        @AuraEnabled public Date accountingDate;
        @AuraEnabled public Id paymentId;
        @AuraEnabled public String paymentState;
    }

    public class EmploymentDTO {
        @AuraEnabled public Id employmentId;
        @AuraEnabled public String employeeReference;
        @AuraEnabled public String departmentName;
        @AuraEnabled public String status;
    }

    public class WorkspaceDTO {
        @AuraEnabled public Id companyId;
        @AuraEnabled public String companyName;
        @AuraEnabled public String functionalCurrency;
        @AuraEnabled public Capabilities capabilities;
        @AuraEnabled public List<RunDTO> runs;
        @AuraEnabled public List<StateCount> stateCounts;
        @AuraEnabled public Decimal outstandingNetPay;
        @AuraEnabled public List<EmploymentDTO> employments;
        @AuraEnabled public List<OptionDTO> openPeriods;
        @AuraEnabled public List<OptionDTO> payableAccounts;
        @AuraEnabled public List<OptionDTO> bankAccounts;
        @AuraEnabled public List<OptionDTO> paymentMethods;
    }

    public class LineDTO {
        @AuraEnabled public Id lineId;
        @AuraEnabled public Id employmentId;
        @AuraEnabled public String employeeReference;
        @AuraEnabled public Decimal grossAmount;
        @AuraEnabled public Decimal deductionAmount;
        @AuraEnabled public Decimal employerContribution;
        @AuraEnabled public Decimal netAmount;
        @AuraEnabled public Decimal settledAmount;
        @AuraEnabled public Decimal outstandingAmount;
        @AuraEnabled public Id effectiveSettlementId;
    }

    public class AwardLineDTO {
        @AuraEnabled public Id componentLineId;
        @AuraEnabled public Id awardId;
        @AuraEnabled public String awardKey;
        @AuraEnabled public String employeeReference;
        @AuraEnabled public String category;
        @AuraEnabled public Decimal amount;
    }

    public class PaymentDTO {
        @AuraEnabled public Id paymentId;
        @AuraEnabled public String name;
        @AuraEnabled public String state;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Date effectiveDate;
        @AuraEnabled public String method;
        @AuraEnabled public String reference;
        @AuraEnabled public String providerRequestKey;
        @AuraEnabled public String bankAccountName;
    }

    public class RunDetailDTO {
        @AuraEnabled public RunDTO run;
        @AuraEnabled public List<LineDTO> lines;
        @AuraEnabled public List<AwardLineDTO> awards;
        @AuraEnabled public PaymentDTO payment;
    }

    public class AssignmentDTO {
        @AuraEnabled public Id assignmentId;
        @AuraEnabled public String employeeReference;
        @AuraEnabled public String componentName;
        @AuraEnabled public String category;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public Date effectiveFrom;
        @AuraEnabled public Date effectiveTo;
        @AuraEnabled public String status;
    }

    public class AwardDTO {
        @AuraEnabled public Id awardId;
        @AuraEnabled public String awardKey;
        @AuraEnabled public String employeeReference;
        @AuraEnabled public String componentName;
        @AuraEnabled public String category;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public Date serviceStart;
        @AuraEnabled public Date serviceEnd;
        @AuraEnabled public String status;
        @AuraEnabled public Id consumedByRunId;
    }

    public class HrQueueDTO {
        @AuraEnabled public List<AssignmentDTO> pendingAssignments;
        @AuraEnabled public List<AwardDTO> awards;
    }

    // --------------------------------------------------------------- queries

    @AuraEnabled
    public static WorkspaceDTO getWorkspace(Id companyId) {
        if (companyId == null) {
            throw new PayrollWorkspaceException('Select an Accounting Company first.');
        }
        SABPermissionService.assertPermission(VIEW_DETAIL, 'Payroll detail permission is required.');
        SABCompanyAccessService.assertCompanyAccess(companyId);
        SABPayrollWorkspaceSecurityPolicy.assertWorkspaceReadAccess();
        List<Accounting_Company__c> companies = [SELECT Id, Name__c, Functional_Currency__c FROM Accounting_Company__c
            WHERE Id = :companyId WITH USER_MODE];
        if (companies.isEmpty()) {
            throw new PayrollWorkspaceException('Accounting Company not found or not accessible.');
        }
        WorkspaceDTO result = new WorkspaceDTO();
        result.companyId = companyId;
        result.companyName = companies[0].Name__c;
        result.functionalCurrency = companies[0].Functional_Currency__c;
        result.capabilities = capabilities();
        result.runs = new List<RunDTO>();
        result.outstandingNetPay = 0;
        Map<String, Integer> counts = new Map<String, Integer>();
        for (String state : new List<String>{'Draft', 'Calculated', 'Submitted', 'Approved', 'Posted', 'Settled', 'Cancelled'}) {
            counts.put(state, 0);
        }
        for (Payroll_Run__c run : [SELECT Id, Name, Run_Key__c, Pay_Period_Start__c, Pay_Period_End__c, Workflow_State__c,
                Currency__c, Gross_Total__c, Deduction_Total__c, Employer_Total__c, Net_Total__c, Settled_Amount__c,
                Accounting_Date__c, Settlement_Payment__c, Settlement_Payment__r.Processing_State__c
                FROM Payroll_Run__c WHERE Company__c = :companyId WITH USER_MODE
                ORDER BY Pay_Period_Start__c DESC, Name DESC LIMIT :RUN_LIMIT]) {
            RunDTO row = toRun(run);
            result.runs.add(row);
            counts.put(row.state, (counts.containsKey(row.state) ? counts.get(row.state) : 0) + 1);
            result.outstandingNetPay += row.outstandingAmount;
        }
        result.stateCounts = new List<StateCount>();
        for (String state : counts.keySet()) {
            StateCount c = new StateCount();
            c.state = state;
            c.count = counts.get(state);
            result.stateCounts.add(c);
        }
        result.employments = new List<EmploymentDTO>();
        for (Employment__c e : [SELECT Id, Employment_Status__c, Employee__r.Employee_Reference__c, Department__r.Name
                FROM Employment__c WHERE Company__c = :companyId AND Employment_Status__c = 'Active' WITH USER_MODE
                ORDER BY Employee__r.Employee_Reference__c LIMIT :ROW_LIMIT]) {
            EmploymentDTO row = new EmploymentDTO();
            row.employmentId = e.Id;
            row.employeeReference = e.Employee__r == null ? null : e.Employee__r.Employee_Reference__c;
            row.departmentName = e.Department__r == null ? null : e.Department__r.Name;
            row.status = e.Employment_Status__c;
            result.employments.add(row);
        }
        result.openPeriods = new List<OptionDTO>();
        for (Accounting_Period__c p : [SELECT Id, Name, Period_Key__c, Start_Date__c, End_Date__c FROM Accounting_Period__c
                WHERE Company__c = :companyId AND Status__c = 'Open' WITH USER_MODE ORDER BY Start_Date__c LIMIT :ROW_LIMIT]) {
            OptionDTO o = option(p.Period_Key__c + ' (' + p.Name + ')', p.Id);
            o.startDate = p.Start_Date__c;
            o.endDate = p.End_Date__c;
            result.openPeriods.add(o);
        }
        result.payableAccounts = new List<OptionDTO>();
        for (GL_Account__c a : [SELECT Id, Name, Account_Code__c FROM GL_Account__c WHERE Company__c = :companyId
                AND Account_Type__c = 'Liability' AND Is_Active__c = true WITH USER_MODE ORDER BY Account_Code__c LIMIT :ROW_LIMIT]) {
            result.payableAccounts.add(option(a.Account_Code__c + ' ' + a.Name, a.Id));
        }
        result.bankAccounts = new List<OptionDTO>();
        String functionalCurrency = companies[0].Functional_Currency__c;
        for (Bank_Account__c b : [SELECT Id, Name, Currency__c FROM Bank_Account__c WHERE Company__c = :companyId
                AND Is_Active__c = true AND Currency__c = :functionalCurrency WITH USER_MODE ORDER BY Name LIMIT :ROW_LIMIT]) {
            result.bankAccounts.add(option(b.Name + ' (' + b.Currency__c + ')', b.Id));
        }
        result.paymentMethods = new List<OptionDTO>();
        for (Schema.PicklistEntry entry : Accounting_Payment__c.Method__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                result.paymentMethods.add(option(entry.getLabel(), entry.getValue()));
            }
        }
        return result;
    }

    @AuraEnabled
    public static RunDetailDTO getRunDetail(Id runId) {
        if (runId == null) {
            throw new PayrollWorkspaceException('Select a payroll run first.');
        }
        SABPermissionService.assertPermission(VIEW_DETAIL, 'Payroll detail permission is required.');
        SABPayrollWorkspaceSecurityPolicy.assertWorkspaceReadAccess();
        List<Payroll_Run__c> runs = [SELECT Id, Name, Company__c, Run_Key__c, Pay_Period_Start__c, Pay_Period_End__c,
            Workflow_State__c, Currency__c, Gross_Total__c, Deduction_Total__c, Employer_Total__c, Net_Total__c, Settled_Amount__c,
            Accounting_Date__c, Settlement_Payment__c, Settlement_Payment__r.Processing_State__c
            FROM Payroll_Run__c WHERE Id = :runId WITH USER_MODE];
        if (runs.isEmpty()) {
            throw new PayrollWorkspaceException('Payroll Run not found or not accessible.');
        }
        SABCompanyAccessService.assertCompanyAccess(runs[0].Company__c);
        SABAccessControlService.assertRecordReadAccess(runId);
        RunDetailDTO detail = new RunDetailDTO();
        detail.run = toRun(runs[0]);
        Map<Id, SABPayrollSettlementService.LineSummary> settled = new Map<Id, SABPayrollSettlementService.LineSummary>();
        if (SETTLEMENT_STATES.contains(runs[0].Workflow_State__c)) {
            for (SABPayrollSettlementService.LineSummary s : SABPayrollSettlementService.getSettlementSummary(runId).lines) {
                settled.put(s.payrollLineId, s);
            }
        }
        detail.lines = new List<LineDTO>();
        for (Payroll_Line__c line : [SELECT Id, Employment__c, Employment__r.Employee__r.Employee_Reference__c, Gross_Amount__c,
                Deduction_Amount__c, Employer_Contribution__c, Net_Amount__c FROM Payroll_Line__c WHERE Payroll_Run__c = :runId
                WITH USER_MODE ORDER BY Employment__r.Employee__r.Employee_Reference__c LIMIT 201]) {
            detail.lines.add(toLine(line, settled.get(line.Id)));
        }
        detail.awards = new List<AwardLineDTO>();
        for (Payroll_Component_Line__c c : [SELECT Id, Benefit_Award__c, Benefit_Award__r.Award_Key__c, Component_Category__c,
                Amount__c, Payroll_Line__r.Employment__r.Employee__r.Employee_Reference__c FROM Payroll_Component_Line__c
                WHERE Payroll_Line__r.Payroll_Run__c = :runId AND Benefit_Award__c != null WITH USER_MODE
                ORDER BY Benefit_Award__r.Award_Key__c LIMIT :ROW_LIMIT]) {
            AwardLineDTO a = new AwardLineDTO();
            a.componentLineId = c.Id;
            a.awardId = c.Benefit_Award__c;
            a.awardKey = c.Benefit_Award__r == null ? null : c.Benefit_Award__r.Award_Key__c;
            a.employeeReference = c.Payroll_Line__r.Employment__r.Employee__r.Employee_Reference__c;
            a.category = c.Component_Category__c;
            a.amount = c.Amount__c;
            detail.awards.add(a);
        }
        detail.payment = runs[0].Settlement_Payment__c == null ? null : payment(runs[0].Settlement_Payment__c);
        return detail;
    }

    @AuraEnabled
    public static HrQueueDTO getHrQueue(Id companyId) {
        if (companyId == null) {
            throw new PayrollWorkspaceException('Select an Accounting Company first.');
        }
        if (!SABPermissionService.hasPermission(VIEW_DETAIL) && !SABPermissionService.hasPermission('SAB_Manage_Employee_Compensation')
            && !SABPermissionService.hasPermission('SAB_Approve_Employee_Compensation')) {
            throw new SABPermissionService.PermissionDeniedException('Payroll detail or compensation permission is required.');
        }
        SABCompanyAccessService.assertCompanyAccess(companyId);
        SABPayrollWorkspaceSecurityPolicy.assertHrReadAccess();
        HrQueueDTO queue = new HrQueueDTO();
        queue.pendingAssignments = new List<AssignmentDTO>();
        for (Employee_Pay_Component__c a : [SELECT Id, Amount__c, Currency__c, Effective_From__c, Effective_To__c, Status__c,
                Pay_Component__r.Name, Pay_Component__r.Category__c, Employment__r.Employee__r.Employee_Reference__c
                FROM Employee_Pay_Component__c WHERE Employment__r.Company__c = :companyId AND Status__c = 'Draft' WITH USER_MODE
                ORDER BY Employment__r.Employee__r.Employee_Reference__c, Effective_From__c LIMIT :ROW_LIMIT]) {
            AssignmentDTO row = new AssignmentDTO();
            row.assignmentId = a.Id;
            row.employeeReference = a.Employment__r.Employee__r.Employee_Reference__c;
            row.componentName = a.Pay_Component__r.Name;
            row.category = a.Pay_Component__r.Category__c;
            row.amount = a.Amount__c;
            row.currencyCode = a.Currency__c;
            row.effectiveFrom = a.Effective_From__c;
            row.effectiveTo = a.Effective_To__c;
            row.status = a.Status__c;
            queue.pendingAssignments.add(row);
        }
        queue.awards = new List<AwardDTO>();
        for (Benefit_Award__c b : [SELECT Id, Award_Key__c, Amount__c, Currency__c, Service_Period_Start__c, Service_Period_End__c,
                Status__c, Consumed_By_Payroll_Run__c, Pay_Component__r.Name, Pay_Component__r.Category__c,
                Employment__r.Employee__r.Employee_Reference__c FROM Benefit_Award__c WHERE Employment__r.Company__c = :companyId
                AND Status__c IN ('Proposed', 'Approved', 'Consumed') WITH USER_MODE
                ORDER BY Status__c DESC, Award_Key__c LIMIT :ROW_LIMIT]) {
            AwardDTO row = new AwardDTO();
            row.awardId = b.Id;
            row.awardKey = b.Award_Key__c;
            row.employeeReference = b.Employment__r.Employee__r.Employee_Reference__c;
            row.componentName = b.Pay_Component__r.Name;
            row.category = b.Pay_Component__r.Category__c;
            row.amount = b.Amount__c;
            row.currencyCode = b.Currency__c;
            row.serviceStart = b.Service_Period_Start__c;
            row.serviceEnd = b.Service_Period_End__c;
            row.status = b.Status__c;
            row.consumedByRunId = b.Consumed_By_Payroll_Run__c;
            queue.awards.add(row);
        }
        return queue;
    }

    // --------------------------------------------------------------- helpers

    @TestVisible
    private static Capabilities capabilities() {
        Capabilities c = new Capabilities();
        c.calculate = SABPermissionService.hasPermission('SAB_Calculate_Payroll');
        c.submit = SABPermissionService.hasPermission('SAB_Submit_Payroll');
        c.approve = SABPermissionService.hasPermission('SAB_Approve_Payroll');
        c.cancel = SABPermissionService.hasPermission('SAB_Cancel_Payroll');
        c.postPayroll = SABPermissionService.hasPermission('SAB_Post_Payroll');
        c.postJournal = SABPermissionService.hasPermission('SAB_Post_Journal');
        c.processPayment = SABPermissionService.hasPermission('SAB_Process_Payroll_Payment');
        c.authorizePayment = SABPermissionService.hasPermission('SAB_Authorize_Payroll_Payment');
        c.manageCompensation = SABPermissionService.hasPermission('SAB_Manage_Employee_Compensation');
        c.approveCompensation = SABPermissionService.hasPermission('SAB_Approve_Employee_Compensation');
        return c;
    }

    private static OptionDTO option(String label, String value) {
        OptionDTO o = new OptionDTO();
        o.label = label;
        o.value = value;
        return o;
    }

    private static Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }

    private static RunDTO toRun(Payroll_Run__c run) {
        RunDTO row = new RunDTO();
        row.runId = run.Id;
        row.name = run.Name;
        row.runKey = run.Run_Key__c;
        row.periodStart = run.Pay_Period_Start__c;
        row.periodEnd = run.Pay_Period_End__c;
        row.state = run.Workflow_State__c;
        row.currencyCode = run.Currency__c;
        row.grossTotal = zeroIfNull(run.Gross_Total__c);
        row.deductionTotal = zeroIfNull(run.Deduction_Total__c);
        row.employerTotal = zeroIfNull(run.Employer_Total__c);
        row.netTotal = zeroIfNull(run.Net_Total__c);
        row.settledAmount = zeroIfNull(run.Settled_Amount__c);
        row.outstandingAmount = SETTLEMENT_STATES.contains(run.Workflow_State__c) ? row.netTotal - row.settledAmount : 0;
        row.accountingDate = run.Accounting_Date__c;
        row.paymentId = run.Settlement_Payment__c;
        row.paymentState = run.Settlement_Payment__r == null ? null : run.Settlement_Payment__r.Processing_State__c;
        return row;
    }

    private static LineDTO toLine(Payroll_Line__c line, SABPayrollSettlementService.LineSummary settled) {
        LineDTO row = new LineDTO();
        row.lineId = line.Id;
        row.employmentId = line.Employment__c;
        row.employeeReference = line.Employment__r == null || line.Employment__r.Employee__r == null
            ? null : line.Employment__r.Employee__r.Employee_Reference__c;
        row.grossAmount = zeroIfNull(line.Gross_Amount__c);
        row.deductionAmount = zeroIfNull(line.Deduction_Amount__c);
        row.employerContribution = zeroIfNull(line.Employer_Contribution__c);
        row.netAmount = zeroIfNull(line.Net_Amount__c);
        row.settledAmount = settled == null ? 0 : settled.settledAmount;
        row.outstandingAmount = settled == null ? 0 : settled.outstandingAmount;
        row.effectiveSettlementId = settled == null ? null : settled.effectiveSettlementId;
        return row;
    }

    private static PaymentDTO payment(Id paymentId) {
        List<Accounting_Payment__c> rows = [SELECT Id, Name, Processing_State__c, Amount__c, Effective_Date__c, Method__c,
            Reference__c, Provider_Request_Key__c, Bank_Account__r.Name FROM Accounting_Payment__c WHERE Id = :paymentId
            WITH USER_MODE];
        if (rows.isEmpty()) {
            return null;
        }
        PaymentDTO p = new PaymentDTO();
        p.paymentId = rows[0].Id;
        p.name = rows[0].Name;
        p.state = rows[0].Processing_State__c;
        p.amount = rows[0].Amount__c;
        p.effectiveDate = rows[0].Effective_Date__c;
        p.method = rows[0].Method__c;
        p.reference = rows[0].Reference__c;
        p.providerRequestKey = rows[0].Provider_Request_Key__c;
        p.bankAccountName = rows[0].Bank_Account__r == null ? null : rows[0].Bank_Account__r.Name;
        return p;
    }
}
