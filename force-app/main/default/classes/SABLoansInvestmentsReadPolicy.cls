/**
 * G22B: read policy for the Investments & loans workspace.
 *
 * Order: SAB_View_Loans_Investments, then an active company grant. Record reads that follow run in
 * user mode, so object and field access still come from SAB_Loan_User and SAB_Investment_User.
 */
public with sharing class SABLoansInvestmentsReadPolicy {

    public static final String VIEW_PERMISSION = 'SAB_View_Loans_Investments';

    public class LoansInvestmentsAccessException extends Exception {}

    public static void assertCanView(Id companyId) {
        if (!SABPermissionService.hasPermission(VIEW_PERMISSION)) {
            throw new LoansInvestmentsAccessException('You do not have permission to view Investments & loans.');
        }
        if (companyId == null) {
            throw new LoansInvestmentsAccessException('Accounting Company is required.');
        }
        if (!SABCompanyAccessService.hasCompanyAccess(companyId)) {
            throw new LoansInvestmentsAccessException('You do not have active access to this Accounting Company.');
        }
    }

    public static Boolean canReadLoans() {
        return Schema.SObjectType.Loan__c.isAccessible() && Schema.SObjectType.Loan_Schedule_Line__c.isAccessible();
    }

    public static Boolean canReadInvestments() {
        return Schema.SObjectType.Investment__c.isAccessible() && Schema.SObjectType.Investment_Transaction__c.isAccessible();
    }
}
