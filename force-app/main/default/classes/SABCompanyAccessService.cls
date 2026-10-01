/**
 * Central company-authorization service for Simple Accounting Books.
 *
 * Security design:
 * - The access-grant object itself is not exposed to callers.
 * - Callers can ask only whether the CURRENT USER has an active grant.
 * - This class uses system context narrowly so a user's inability to read the
 *   grant record does not prevent the grant from acting as an authorization source.
 * - This service does NOT replace CRUD/FLS checks on business objects.
 *
 * G9D governor-limit hardening:
 * - The effective company set for the CURRENT USER is loaded once per Apex
 *   transaction and then reused.
 * - Cache is keyed by User Id so runAs() cannot leak one user's authorization
 *   result into another user's execution context.
 * - A depreciation posting can invoke authorization repeatedly through the
 *   accounting-event/posting chain without issuing one SOQL query per call.
 */
public without sharing class SABCompanyAccessService {
    public class CompanyAccessDeniedException extends Exception {}

    @TestVisible
    private static Map<Id, Set<Id>> accessibleCompaniesByUser =
        new Map<Id, Set<Id>>();

    @TestVisible
    private static Set<Id> loadedUsers =
        new Set<Id>();

    public static Boolean hasCompanyAccess(Id companyId) {
        if (companyId == null) {
            return false;
        }

        Id currentUserId = UserInfo.getUserId();
        Set<Id> accessibleCompanyIds =
            loadAccessibleCompanyIds(currentUserId);

        return accessibleCompanyIds.contains(companyId);
    }

    public static void assertCompanyAccess(Id companyId) {
        if (!hasCompanyAccess(companyId)) {
            throw new CompanyAccessDeniedException(
                'You do not have active access to this Accounting Company.'
            );
        }
    }

    public static Set<Id> getAccessibleCompanyIds() {
        return new Set<Id>(
            loadAccessibleCompanyIds(UserInfo.getUserId())
        );
    }

    public static String getCompanyRole(Id companyId) {
        if (companyId == null) {
            return null;
        }

        Date today = Date.today();
        Id currentUserId = UserInfo.getUserId();

        List<Company_User_Access__c> grants = [
            SELECT Role__c
            FROM Company_User_Access__c
            WHERE User__c = :currentUserId
              AND Company__c = :companyId
              AND Is_Active__c = true
              AND Effective_From__c <= :today
              AND (
                  Effective_To__c = null
                  OR Effective_To__c >= :today
              )
            ORDER BY Effective_From__c DESC
            LIMIT 1
        ];

        return grants.isEmpty()
            ? null
            : grants[0].Role__c;
    }

    private static Set<Id> loadAccessibleCompanyIds(
        Id currentUserId
    ) {
        if (currentUserId == null) {
            return new Set<Id>();
        }

        if (loadedUsers.contains(currentUserId)) {
            Set<Id> cached =
                accessibleCompaniesByUser.get(currentUserId);

            return cached == null
                ? new Set<Id>()
                : cached;
        }

        Date today = Date.today();
        Set<Id> companyIds = new Set<Id>();

        for (Company_User_Access__c grant : [
            SELECT Company__c
            FROM Company_User_Access__c
            WHERE User__c = :currentUserId
              AND Is_Active__c = true
              AND Effective_From__c <= :today
              AND (
                  Effective_To__c = null
                  OR Effective_To__c >= :today
              )
        ]) {
            if (grant.Company__c != null) {
                companyIds.add(grant.Company__c);
            }
        }

        accessibleCompaniesByUser.put(
            currentUserId,
            companyIds
        );
        loadedUsers.add(currentUserId);

        return companyIds;
    }
}
