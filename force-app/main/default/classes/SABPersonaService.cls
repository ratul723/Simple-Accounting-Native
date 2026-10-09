/**
 * G22A: derives the Simple Accounting Books persona of the running user.
 *
 * There is no role switcher in production. The persona is inferred from SAB custom permissions,
 * in priority order, matching the Harbourline demo roles and the SAB_<Verb>_<Noun>_Action sets:
 *   SAB_Close_Period                                              -> Finance Manager
 *   SAB_Post_Journal                                              -> Bookkeeper
 *   SAB_Approve_Financial_Document                                -> Director
 *   SAB_Release_Payment / SAB_Authorize_Payroll_Payment /
 *   SAB_Process_Payroll_Payment                                   -> Treasury
 *   SAB_Manage_Employee_Compensation / SAB_Calculate_Payroll /
 *   SAB_Submit_Payroll                                            -> HR
 *   none of the above                                             -> Auditor (read only)
 *
 * The persona only shapes presentation (home cards, attention list). Every action is still
 * authorised by the service it calls.
 */
public with sharing class SABPersonaService {

    public static final String FINANCE_MANAGER = 'FINANCE_MANAGER';
    public static final String BOOKKEEPER = 'BOOKKEEPER';
    public static final String DIRECTOR = 'DIRECTOR';
    public static final String TREASURY = 'TREASURY';
    public static final String HR = 'HR';
    public static final String AUDITOR = 'AUDITOR';

    private static final Map<String, String> LABEL_BY_KEY = new Map<String, String>{
        FINANCE_MANAGER => 'Finance Manager',
        BOOKKEEPER => 'Bookkeeper',
        DIRECTOR => 'Director',
        TREASURY => 'Treasury',
        HR => 'HR',
        AUDITOR => 'Auditor'
    };

    private static final List<String> TREASURY_PERMISSIONS = new List<String>{
        'SAB_Release_Payment', 'SAB_Authorize_Payroll_Payment', 'SAB_Process_Payroll_Payment'
    };

    private static final List<String> HR_PERMISSIONS = new List<String>{
        'SAB_Manage_Employee_Compensation', 'SAB_Calculate_Payroll', 'SAB_Submit_Payroll'
    };

    public class Persona {
        @AuraEnabled public String key { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String userName { get; set; }
        @AuraEnabled public String firstName { get; set; }
        @AuraEnabled public String initials { get; set; }
        @AuraEnabled public Boolean canViewPayrollDetail { get; set; }
        @AuraEnabled public Boolean canViewBankDetail { get; set; }
        @AuraEnabled public Boolean canApprove { get; set; }
    }

    public static Persona current() {
        Persona persona = new Persona();
        persona.key = resolveKey();
        persona.label = LABEL_BY_KEY.get(persona.key);
        persona.userName = UserInfo.getName();
        persona.firstName = String.isBlank(UserInfo.getFirstName()) ? UserInfo.getLastName() : UserInfo.getFirstName();
        persona.initials = initialsOf(persona.userName);
        persona.canViewPayrollDetail = SABPermissionService.hasPermission('SAB_View_Payroll_Detail');
        persona.canViewBankDetail = SABPermissionService.hasPermission('SAB_View_Bank_Detail');
        persona.canApprove = SABPermissionService.hasPermission('SAB_Approve_Financial_Document');
        return persona;
    }

    public static String labelOf(String key) {
        return LABEL_BY_KEY.containsKey(key) ? LABEL_BY_KEY.get(key) : LABEL_BY_KEY.get(AUDITOR);
    }

    @TestVisible
    private static String resolveKey() {
        if (SABPermissionService.hasPermission('SAB_Close_Period')) {
            return FINANCE_MANAGER;
        }
        if (SABPermissionService.hasPermission('SAB_Post_Journal')) {
            return BOOKKEEPER;
        }
        if (SABPermissionService.hasPermission('SAB_Approve_Financial_Document')) {
            return DIRECTOR;
        }
        if (hasAny(TREASURY_PERMISSIONS)) {
            return TREASURY;
        }
        if (hasAny(HR_PERMISSIONS)) {
            return HR;
        }
        return AUDITOR;
    }

    @TestVisible
    private static String initialsOf(String name) {
        String result = '';
        if (String.isBlank(name)) {
            return result;
        }
        for (String part : name.trim().split('\\s+')) {
            if (result.length() < 2 && String.isNotBlank(part)) {
                result += part.substring(0, 1).toUpperCase();
            }
        }
        return result;
    }

    private static Boolean hasAny(List<String> permissionNames) {
        for (String permissionName : permissionNames) {
            if (SABPermissionService.hasPermission(permissionName)) {
                return true;
            }
        }
        return false;
    }
}
