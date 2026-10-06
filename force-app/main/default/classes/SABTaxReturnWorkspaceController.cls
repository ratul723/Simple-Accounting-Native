/**
 * G11: Tax Return Workspace controller.
 *
 * Read layer for the sabTaxReturnWorkspace LWC plus thin @AuraEnabled entry points for the two G6C
 * preparation methods (SABTaxReturnService.prepareReturn / setAdjustment are not @AuraEnabled).
 * Every read runs in user mode after SAB_View_Tax_Returns, the company grant and the CRUD/FLS policy.
 * All changes stay in the G6C/G6D services, which enforce their own permissions and lifecycle rules:
 *   prepare/adjust  SAB_Prepare_Tax_Return            (SABTaxReturnService)
 *   review          SAB_Review_Tax_Return              (SABTaxReturnLifecycleService, locks the source hash)
 *   submit          SAB_Submit_Tax_Return
 *   outcome         SAB_Record_Tax_Authority_Outcome
 *   amend           SAB_Amend_Tax_Return
 */
public with sharing class SABTaxReturnWorkspaceController {
    public class TaxReturnWorkspaceException extends Exception {}

    private static final String VIEW = 'SAB_View_Tax_Returns';
    private static final String NET_BOX = 'NET_TAX_DUE';
    private static final Integer RETURN_LIMIT = 100;
    private static final Integer ROW_LIMIT = 200;
    private static final List<String> STATES = new List<String>{'Draft', 'Prepared', 'Reviewed', 'Submitted', 'Accepted',
        'Rejected', 'Amended'};

    // ------------------------------------------------------------------ DTOs

    public class Capabilities {
        @AuraEnabled public Boolean prepare;
        @AuraEnabled public Boolean review;
        @AuraEnabled public Boolean submit;
        @AuraEnabled public Boolean recordOutcome;
        @AuraEnabled public Boolean amend;
        @AuraEnabled public Boolean viewAudit;
    }

    public class OptionDTO {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public String filingFrequency;
        @AuraEnabled public Date effectiveFrom;
        @AuraEnabled public Date effectiveTo;
    }

    public class StateCount {
        @AuraEnabled public String state;
        @AuraEnabled public Integer count;
    }

    public class ReturnDTO {
        @AuraEnabled public Id taxReturnId;
        @AuraEnabled public String name;
        @AuraEnabled public Id registrationId;
        @AuraEnabled public String registrationName;
        @AuraEnabled public String jurisdiction;
        @AuraEnabled public Date periodStart;
        @AuraEnabled public Date periodEnd;
        @AuraEnabled public Decimal returnVersion;
        @AuraEnabled public String status;
        @AuraEnabled public String countryPackVersion;
        @AuraEnabled public Decimal netTaxDue;
        @AuraEnabled public String filingReference;
        @AuraEnabled public String acknowledgementReference;
        @AuraEnabled public Boolean sourceLocked;
        @AuraEnabled public Id amendsTaxReturnId;
        @AuraEnabled public String amendsTaxReturnName;
    }

    public class WorkspaceDTO {
        @AuraEnabled public Id companyId;
        @AuraEnabled public String companyName;
        @AuraEnabled public String functionalCurrency;
        @AuraEnabled public Capabilities capabilities;
        @AuraEnabled public List<OptionDTO> registrations;
        @AuraEnabled public List<ReturnDTO> returns;
        @AuraEnabled public List<StateCount> stateCounts;
        @AuraEnabled public Decimal openNetTaxDue;
        @AuraEnabled public Integer filingReferenceMaxLength;
        @AuraEnabled public Integer acknowledgementMaxLength;
    }

    public class LineDTO {
        @AuraEnabled public Id lineId;
        @AuraEnabled public String boxKey;
        @AuraEnabled public String label;
        @AuraEnabled public Decimal calculatedAmount;
        @AuraEnabled public Decimal adjustmentAmount;
        @AuraEnabled public Decimal finalAmount;
    }

    public class HistoryDTO {
        @AuraEnabled public String action;
        @AuraEnabled public String actorName;
        @AuraEnabled public Datetime actionAt;
        @AuraEnabled public String reason;
    }

    public class ReturnDetailDTO {
        @AuraEnabled public ReturnDTO taxReturn;
        @AuraEnabled public List<LineDTO> lines;
        @AuraEnabled public List<HistoryDTO> history;
        @AuraEnabled public List<ReturnDTO> versions;
    }

    public class PrepareResultDTO {
        @AuraEnabled public Id taxReturnId;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal returnVersion;
        @AuraEnabled public Integer outputSourceCount;
        @AuraEnabled public Integer inputSourceCount;
        @AuraEnabled public Decimal netTaxDue;
        @AuraEnabled public Boolean rebuiltExistingReturn;
    }

    // --------------------------------------------------------------- queries

    @AuraEnabled
    public static WorkspaceDTO getWorkspace(Id companyId) {
        if (companyId == null) {
            throw new TaxReturnWorkspaceException('Select an Accounting Company first.');
        }
        authorizeCompany(companyId);
        List<Accounting_Company__c> companies = [SELECT Id, Name__c, Functional_Currency__c FROM Accounting_Company__c
            WHERE Id = :companyId WITH USER_MODE];
        if (companies.isEmpty()) {
            throw new TaxReturnWorkspaceException('Accounting Company not found or not accessible.');
        }
        WorkspaceDTO result = new WorkspaceDTO();
        result.companyId = companyId;
        result.companyName = companies[0].Name__c;
        result.functionalCurrency = companies[0].Functional_Currency__c;
        result.capabilities = capabilities();
        result.filingReferenceMaxLength = Tax_Return__c.Filing_Reference__c.getDescribe().getLength();
        result.acknowledgementMaxLength = Tax_Return__c.Acknowledgement_Reference__c.getDescribe().getLength();
        result.registrations = new List<OptionDTO>();
        for (Tax_Registration__c r : [SELECT Id, Name, Jurisdiction__c, Registration_Identifier__c, Filing_Frequency__c,
                Effective_From__c, Effective_To__c FROM Tax_Registration__c WHERE Company__c = :companyId AND Is_Active__c = true
                WITH USER_MODE ORDER BY Name LIMIT :ROW_LIMIT]) {
            OptionDTO o = new OptionDTO();
            o.label = r.Name + ' (' + r.Jurisdiction__c + ' ' + r.Registration_Identifier__c + ')';
            o.value = r.Id;
            o.filingFrequency = r.Filing_Frequency__c;
            o.effectiveFrom = r.Effective_From__c;
            o.effectiveTo = r.Effective_To__c;
            result.registrations.add(o);
        }
        List<Tax_Return__c> rows = [SELECT Id, Name, Tax_Registration__c, Tax_Registration__r.Name, Tax_Registration__r.Jurisdiction__c,
            Period_Start__c, Period_End__c, Return_Version__c, Status__c, Country_Pack_Version__c, Filing_Reference__c,
            Acknowledgement_Reference__c, Locked_Source_Hash__c, Amends_Tax_Return__c, Amends_Tax_Return__r.Name
            FROM Tax_Return__c WHERE Company__c = :companyId WITH USER_MODE
            ORDER BY Period_End__c DESC, Return_Version__c DESC, Name DESC LIMIT :RETURN_LIMIT];
        Map<Id, Decimal> netByReturn = netTaxDue(new Map<Id, Tax_Return__c>(rows).keySet());
        Map<String, Integer> counts = new Map<String, Integer>();
        for (String state : STATES) {
            counts.put(state, 0);
        }
        result.returns = new List<ReturnDTO>();
        result.openNetTaxDue = 0;
        for (Tax_Return__c row : rows) {
            ReturnDTO dto = toReturn(row, netByReturn.get(row.Id));
            result.returns.add(dto);
            if (counts.containsKey(dto.status)) {
                counts.put(dto.status, counts.get(dto.status) + 1);
            }
            if ((dto.status == 'Reviewed' || dto.status == 'Submitted') && dto.netTaxDue != null) {
                result.openNetTaxDue += dto.netTaxDue;
            }
        }
        result.stateCounts = new List<StateCount>();
        for (String state : STATES) {
            StateCount c = new StateCount();
            c.state = state;
            c.count = counts.get(state);
            result.stateCounts.add(c);
        }
        return result;
    }

    @AuraEnabled
    public static ReturnDetailDTO getReturnDetail(Id taxReturnId) {
        if (taxReturnId == null) {
            throw new TaxReturnWorkspaceException('Select a Tax Return first.');
        }
        SABPermissionService.assertPermission(VIEW, 'Tax return workspace permission is required.');
        SABTaxReturnWorkspaceSecurityPolicy.assertReadAccess();
        List<Tax_Return__c> rows = [SELECT Id, Name, Company__c, Tax_Registration__c, Tax_Registration__r.Name,
            Tax_Registration__r.Jurisdiction__c, Period_Start__c, Period_End__c, Return_Version__c, Status__c, Country_Pack_Version__c,
            Filing_Reference__c, Acknowledgement_Reference__c, Locked_Source_Hash__c, Amends_Tax_Return__c, Amends_Tax_Return__r.Name
            FROM Tax_Return__c WHERE Id = :taxReturnId WITH USER_MODE];
        if (rows.isEmpty()) {
            throw new TaxReturnWorkspaceException('Tax Return not found or not accessible.');
        }
        Tax_Return__c row = rows[0];
        SABCompanyAccessService.assertCompanyAccess(row.Company__c);
        SABAccessControlService.assertRecordReadAccess(taxReturnId);
        ReturnDetailDTO detail = new ReturnDetailDTO();
        detail.lines = new List<LineDTO>();
        Decimal net;
        for (Tax_Return_Line__c line : [SELECT Id, Box_Key__c, Label__c, Calculated_Amount__c, Adjustment_Amount__c, Final_Amount__c
                FROM Tax_Return_Line__c WHERE Tax_Return__c = :taxReturnId WITH USER_MODE ORDER BY Box_Key__c LIMIT :ROW_LIMIT]) {
            LineDTO dto = new LineDTO();
            dto.lineId = line.Id;
            dto.boxKey = line.Box_Key__c;
            dto.label = line.Label__c;
            dto.calculatedAmount = line.Calculated_Amount__c;
            dto.adjustmentAmount = line.Adjustment_Amount__c;
            dto.finalAmount = line.Final_Amount__c;
            detail.lines.add(dto);
            if (line.Box_Key__c == NET_BOX) {
                net = line.Final_Amount__c;
            }
        }
        detail.taxReturn = toReturn(row, net);
        detail.versions = new List<ReturnDTO>();
        Id registrationId = row.Tax_Registration__c;
        Date periodStart = row.Period_Start__c;
        Date periodEnd = row.Period_End__c;
        for (Tax_Return__c version : [SELECT Id, Name, Tax_Registration__c, Tax_Registration__r.Name, Tax_Registration__r.Jurisdiction__c,
                Period_Start__c, Period_End__c, Return_Version__c, Status__c, Country_Pack_Version__c, Filing_Reference__c,
                Acknowledgement_Reference__c, Locked_Source_Hash__c, Amends_Tax_Return__c, Amends_Tax_Return__r.Name
                FROM Tax_Return__c WHERE Tax_Registration__c = :registrationId AND Period_Start__c = :periodStart
                AND Period_End__c = :periodEnd WITH USER_MODE ORDER BY Return_Version__c DESC LIMIT :ROW_LIMIT]) {
            detail.versions.add(toReturn(version, null));
        }
        detail.history = history(taxReturnId);
        return detail;
    }

    // ------------------------------------------------------ G6C entry points

    /** Prepares or rebuilds the Draft/Prepared return for a registration and period (SABTaxReturnService). */
    @AuraEnabled
    public static PrepareResultDTO prepareReturn(Id taxRegistrationId, Date periodStart, Date periodEnd) {
        SABTaxReturnService.PreparedReturnResult prepared = SABTaxReturnService.prepareReturn(taxRegistrationId, periodStart, periodEnd);
        PrepareResultDTO dto = new PrepareResultDTO();
        dto.taxReturnId = prepared.taxReturnId;
        dto.status = prepared.status;
        dto.returnVersion = prepared.returnVersion;
        dto.outputSourceCount = prepared.outputSourceCount;
        dto.inputSourceCount = prepared.inputSourceCount;
        dto.netTaxDue = prepared.netTaxDue;
        dto.rebuiltExistingReturn = prepared.rebuiltExistingReturn;
        return dto;
    }

    /** Sets the manual adjustment on one box of a Draft/Prepared return (SABTaxReturnService). */
    @AuraEnabled
    public static LineDTO setAdjustment(Id taxReturnId, String boxKey, Decimal adjustmentAmount) {
        Tax_Return_Line__c line = SABTaxReturnService.setAdjustment(taxReturnId, boxKey, adjustmentAmount);
        LineDTO dto = new LineDTO();
        dto.lineId = line.Id;
        dto.boxKey = line.Box_Key__c;
        dto.calculatedAmount = line.Calculated_Amount__c;
        dto.adjustmentAmount = line.Adjustment_Amount__c;
        dto.finalAmount = line.Final_Amount__c;
        return dto;
    }

    // --------------------------------------------------------------- helpers

    private static void authorizeCompany(Id companyId) {
        SABPermissionService.assertPermission(VIEW, 'Tax return workspace permission is required.');
        SABCompanyAccessService.assertCompanyAccess(companyId);
        SABTaxReturnWorkspaceSecurityPolicy.assertReadAccess();
    }

    @TestVisible
    private static Capabilities capabilities() {
        Capabilities c = new Capabilities();
        c.prepare = SABPermissionService.hasPermission('SAB_Prepare_Tax_Return');
        c.review = SABPermissionService.hasPermission('SAB_Review_Tax_Return');
        c.submit = SABPermissionService.hasPermission('SAB_Submit_Tax_Return');
        c.recordOutcome = SABPermissionService.hasPermission('SAB_Record_Tax_Authority_Outcome');
        c.amend = SABPermissionService.hasPermission('SAB_Amend_Tax_Return');
        c.viewAudit = SABPermissionService.hasPermission('SAB_View_Audit_Detail');
        return c;
    }

    private static Map<Id, Decimal> netTaxDue(Set<Id> returnIds) {
        Map<Id, Decimal> result = new Map<Id, Decimal>();
        if (returnIds.isEmpty()) {
            return result;
        }
        for (Tax_Return_Line__c line : [SELECT Tax_Return__c, Final_Amount__c FROM Tax_Return_Line__c
                WHERE Tax_Return__c IN :returnIds AND Box_Key__c = :NET_BOX WITH USER_MODE LIMIT 1000]) {
            result.put(line.Tax_Return__c, line.Final_Amount__c);
        }
        return result;
    }

    // Lifecycle audit rows are shown only to users who may see audit detail (SAB_View_Audit_Detail).
    // The required audit fields must be readable; actor and reason are added when the user can read them.
    private static List<HistoryDTO> history(Id taxReturnId) {
        List<HistoryDTO> rows = new List<HistoryDTO>();
        if (!SABPermissionService.hasPermission('SAB_View_Audit_Detail') || !historyReadable()) {
            return rows;
        }
        Boolean showActor = Business_Action__c.Actor__c.getDescribe().isAccessible();
        Boolean showReason = Business_Action__c.Reason__c.getDescribe().isAccessible();
        String soql = 'SELECT Action__c, Action_At__c' + (showActor ? ', Actor__r.Name' : '') + (showReason ? ', Reason__c' : '')
            + ' FROM Business_Action__c WHERE Source_Type__c = \'Tax_Return__c\' AND Source_Record_Id__c = :sourceId'
            + ' ORDER BY Action_At__c DESC LIMIT 200';
        for (Business_Action__c action : (List<Business_Action__c>) Database.queryWithBinds(soql,
                new Map<String, Object>{'sourceId' => String.valueOf(taxReturnId)}, AccessLevel.USER_MODE)) {
            HistoryDTO h = new HistoryDTO();
            h.action = action.Action__c;
            h.actionAt = action.Action_At__c;
            h.actorName = showActor && action.Actor__r != null ? action.Actor__r.Name : null;
            h.reason = showReason ? action.Reason__c : null;
            rows.add(h);
        }
        return rows;
    }

    // Object read plus the required audit fields; without them the history panel is simply empty.
    private static Boolean historyReadable() {
        if (!Business_Action__c.SObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).isAccessible()) {
            return false;
        }
        for (Schema.SObjectField field : new List<Schema.SObjectField>{Business_Action__c.Action__c, Business_Action__c.Action_At__c,
                Business_Action__c.Source_Type__c, Business_Action__c.Source_Record_Id__c}) {
            if (!field.getDescribe().isAccessible()) {
                return false;
            }
        }
        return true;
    }

    private static ReturnDTO toReturn(Tax_Return__c row, Decimal net) {
        ReturnDTO dto = new ReturnDTO();
        dto.taxReturnId = row.Id;
        dto.name = row.Name;
        dto.registrationId = row.Tax_Registration__c;
        dto.registrationName = row.Tax_Registration__r == null ? null : row.Tax_Registration__r.Name;
        dto.jurisdiction = row.Tax_Registration__r == null ? null : row.Tax_Registration__r.Jurisdiction__c;
        dto.periodStart = row.Period_Start__c;
        dto.periodEnd = row.Period_End__c;
        dto.returnVersion = row.Return_Version__c;
        dto.status = row.Status__c;
        dto.countryPackVersion = row.Country_Pack_Version__c;
        dto.netTaxDue = net;
        dto.filingReference = row.Filing_Reference__c;
        dto.acknowledgementReference = row.Acknowledgement_Reference__c;
        dto.sourceLocked = !String.isBlank(row.Locked_Source_Hash__c);
        dto.amendsTaxReturnId = row.Amends_Tax_Return__c;
        dto.amendsTaxReturnName = row.Amends_Tax_Return__r == null ? null : row.Amends_Tax_Return__r.Name;
        return dto;
    }
}
