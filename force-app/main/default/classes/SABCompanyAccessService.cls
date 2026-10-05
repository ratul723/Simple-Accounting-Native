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

    /** Trigger entry point: cover both sides of reassignment and all grant lifecycle events. */
    public static void invalidateGrants(List<Company_User_Access__c> oldRows, List<Company_User_Access__c> newRows) {
        Set<Id> users = new Set<Id>();
        if (oldRows != null) {
            for (Company_User_Access__c grant : oldRows) { users.add(grant.User__c); }
        }
        if (newRows != null) {
            for (Company_User_Access__c grant : newRows) { users.add(grant.User__c); }
        }
        invalidateUsers(users);
    }

    /** Invalidate only affected users after grant DML. This never grants access or accepts cached values. */
    public static void invalidateUsers(Set<Id> userIds) {
        if (userIds == null) {
            return;
        }
        for (Id userId : userIds) {
            loadedUsers.remove(userId);
            accessibleCompaniesByUser.remove(userId);
        }
    }

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

        // Authorization reads intentionally ignore grant CRUD/FLS: callers may hold
        // a grant without permission to inspect the authorization records themselves.
        // Explicit map binding avoids generated inline bind-variable scope issues.
        List<Company_User_Access__c> grants = Database.queryWithBinds(
            'SELECT Role__c FROM Company_User_Access__c'
            + ' WHERE User__c = :actorId AND Company__c = :requestedCompanyId'
            + ' AND Is_Active__c = true AND Effective_From__c <= :asOfDate'
            + ' AND (Effective_To__c = null OR Effective_To__c >= :asOfDate)'
            + ' ORDER BY Effective_From__c DESC LIMIT 1',
            new Map<String, Object>{
                'actorId' => currentUserId,
                'requestedCompanyId' => companyId,
                'asOfDate' => today
            },
            AccessLevel.SYSTEM_MODE
        );

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

        // API 67 defaults must not change the grant service's existing system-read contract.
        List<Company_User_Access__c> grants = Database.queryWithBinds(
            'SELECT Company__c FROM Company_User_Access__c'
            + ' WHERE User__c = :actorId AND Is_Active__c = true'
            + ' AND Effective_From__c <= :asOfDate'
            + ' AND (Effective_To__c = null OR Effective_To__c >= :asOfDate)',
            new Map<String, Object>{'actorId' => currentUserId, 'asOfDate' => today},
            AccessLevel.SYSTEM_MODE
        );
        for (Company_User_Access__c grant : grants) {
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
