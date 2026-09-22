/**
 * Central company-authorization service for Simple Accounting Books.
 *
 * Security design:
 * - The access-grant object itself is not exposed to callers.
 * - Callers can ask only whether the CURRENT USER has an active grant.
 * - This class uses system context narrowly so a user's inability to read the
 *   grant record does not prevent the grant from acting as an authorization source.
 * - This service does NOT replace CRUD/FLS checks on business objects.
 */
public without sharing class SABCompanyAccessService {
    public class CompanyAccessDeniedException extends Exception {}

    public static Boolean hasCompanyAccess(Id companyId) {
        if (companyId == null) {
            return false;
        }

        Date today = Date.today();
        Integer grantCount = [
            SELECT COUNT()
            FROM Company_User_Access__c
            WHERE User__c = :UserInfo.getUserId()
              AND Company__c = :companyId
              AND Is_Active__c = true
              AND Effective_From__c <= :today
              AND (Effective_To__c = null OR Effective_To__c >= :today)
        ];

        return grantCount > 0;
    }

    public static void assertCompanyAccess(Id companyId) {
        if (!hasCompanyAccess(companyId)) {
            throw new CompanyAccessDeniedException(
                'You do not have active access to this Accounting Company.'
            );
        }
    }

    public static Set<Id> getAccessibleCompanyIds() {
        Date today = Date.today();
        Set<Id> companyIds = new Set<Id>();

        for (Company_User_Access__c grant : [
            SELECT Company__c
            FROM Company_User_Access__c
            WHERE User__c = :UserInfo.getUserId()
              AND Is_Active__c = true
              AND Effective_From__c <= :today
              AND (Effective_To__c = null OR Effective_To__c >= :today)
        ]) {
            if (grant.Company__c != null) {
                companyIds.add(grant.Company__c);
            }
        }

        return companyIds;
    }

    public static String getCompanyRole(Id companyId) {
        if (companyId == null) {
            return null;
        }

        Date today = Date.today();
        List<Company_User_Access__c> grants = [
            SELECT Role__c
            FROM Company_User_Access__c
            WHERE User__c = :UserInfo.getUserId()
              AND Company__c = :companyId
              AND Is_Active__c = true
              AND Effective_From__c <= :today
              AND (Effective_To__c = null OR Effective_To__c >= :today)
            ORDER BY Effective_From__c DESC
            LIMIT 1
        ];

        return grants.isEmpty() ? null : grants[0].Role__c;
    }
}