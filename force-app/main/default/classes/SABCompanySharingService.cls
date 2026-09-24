/**
 * Simple Accounting Books
 * Step 3B-2B: company sharing for Accounting Company + core company-owned records.
 *
 * Uses existing Company_User_Access__c fields:
 * - Company__c
 * - User__c
 * - Is_Active__c
 * - Effective_From__c
 * - Effective_To__c
 *
 * No custom Apex Sharing Reason is required.
 * Share rows use RowCause = Manual.
 *
 * IMPORTANT:
 * This service remains complementary to SABCompanyAccessService. Record sharing
 * controls visibility; application services must still assert company access.
 */
public without sharing class SABCompanySharingService {
    // Owner-share guard:
    // Salesforce already gives the owner implicit record access. Attempting
    // to insert a Manual __Share row for that same owner can fail with
    // INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY.

    @TestVisible
    private static final String ACCESS_LEVEL_READ = 'Read';

    /**
     * Core company-owned objects implemented in the current SAB build.
     *
     * The service checks metadata at runtime:
     * - object must exist,
     * - it must have Company__c,
     * - and a corresponding __Share object must exist.
     *
     * Objects controlled by parent do not expose a standalone __Share object
     * and are therefore intentionally skipped.
     */
    @TestVisible
    private static final List<String> COMPANY_SCOPED_OBJECTS =
        new List<String>{
            'Accounting_Period__c',
            'GL_Account__c',
            'Journal_Entry__c',
            'Invoice__c',
            'Supplier_Bill__c',
            'Accounting_Payment__c',
            'Bank_Account__c',
            'Bank_Statement__c',
            'Bank_Reconciliation__c',
            'Goods_Receipt__c',
            'Expense_Claim__c',
            'Payroll_Run__c',
            'Fixed_Asset__c',
            'Project__c',
            'Budget__c',
            'Tax_Code__c',
            'Tax_Return__c',
            'Allocation_Rule__c',
            'Stakeholder__c',
            'Equity_Transaction__c',
            'Loan__c',
            'Investment__c'
        };

    public class CompanySharingException extends Exception {}

    public static void afterInsert(List<Company_User_Access__c> newRecords) {
        reconcile(buildPairs(newRecords));
    }

    public static void afterUpdate(
        List<Company_User_Access__c> newRecords,
        Map<Id, Company_User_Access__c> oldMap
    ) {
        Set<String> pairKeys = buildPairs(newRecords);

        if (oldMap != null) {
            pairKeys.addAll(buildPairs(oldMap.values()));
        }

        reconcile(pairKeys);
    }

    public static void afterDelete(List<Company_User_Access__c> oldRecords) {
        reconcile(buildPairs(oldRecords));
    }

    public static void afterUndelete(List<Company_User_Access__c> newRecords) {
        reconcile(buildPairs(newRecords));
    }

    /**
     * Reconciles the Accounting Company itself and all currently-existing
     * supported company-owned records for each affected User + Company pair.
     */
    @TestVisible
    private static void reconcile(Set<String> pairKeys) {
        if (pairKeys == null || pairKeys.isEmpty()) {
            return;
        }

        Set<Id> companyIds = new Set<Id>();
        Set<Id> userIds = new Set<Id>();

        for (String keyValue : pairKeys) {
            List<String> parts = keyValue.split(':');

            if (parts.size() == 2) {
                companyIds.add((Id) parts[0]);
                userIds.add((Id) parts[1]);
            }
        }

        if (companyIds.isEmpty() || userIds.isEmpty()) {
            return;
        }

        Set<String> effectivePairs =
            getEffectivePairs(pairKeys, companyIds, userIds);

        // 1. Parent Accounting Company.
        reconcileAccountingCompanyShares(
            pairKeys,
            effectivePairs,
            companyIds,
            userIds
        );

        // 2. Existing company-owned records.
        for (String objectApiName : COMPANY_SCOPED_OBJECTS) {
            reconcileCompanyScopedObjectShares(
                objectApiName,
                pairKeys,
                effectivePairs,
                companyIds,
                userIds
            );
        }
    }

    private static Set<String> getEffectivePairs(
        Set<String> requestedPairKeys,
        Set<Id> companyIds,
        Set<Id> userIds
    ) {
        Set<String> effectivePairs = new Set<String>();
        Date today = Date.today();

        for (Company_User_Access__c grant : [
            SELECT Company__c,
                   User__c,
                   Is_Active__c,
                   Effective_From__c,
                   Effective_To__c
            FROM Company_User_Access__c
            WHERE Company__c IN :companyIds
              AND User__c IN :userIds
        ]) {
            String keyValue =
                pairKey(grant.Company__c, grant.User__c);

            if (
                requestedPairKeys.contains(keyValue)
                && isCurrentlyEffective(grant, today)
            ) {
                effectivePairs.add(keyValue);
            }
        }

        return effectivePairs;
    }

    private static void reconcileAccountingCompanyShares(
        Set<String> pairKeys,
        Set<String> effectivePairs,
        Set<Id> companyIds,
        Set<Id> userIds
    ) {
        // The Accounting Company owner already has implicit full access.
        // Salesforce can reject an explicit Manual __Share row to that same
        // owner with INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY.
        Map<Id, Id> ownerByCompanyId =
            new Map<Id, Id>();

        for (Accounting_Company__c companyRecord : [
            SELECT Id,
                   OwnerId
            FROM Accounting_Company__c
            WHERE Id IN :companyIds
        ]) {
            ownerByCompanyId.put(
                companyRecord.Id,
                companyRecord.OwnerId
            );
        }

        Map<String, List<Accounting_Company__Share>> sharesByPair =
            new Map<String, List<Accounting_Company__Share>>();

        for (Accounting_Company__Share shareRecord : [
            SELECT Id,
                   ParentId,
                   UserOrGroupId,
                   AccessLevel,
                   RowCause
            FROM Accounting_Company__Share
            WHERE ParentId IN :companyIds
              AND UserOrGroupId IN :userIds
              AND RowCause = 'Manual'
        ]) {
            String keyValue =
                pairKey(shareRecord.ParentId, shareRecord.UserOrGroupId);

            if (!pairKeys.contains(keyValue)) {
                continue;
            }

            if (!sharesByPair.containsKey(keyValue)) {
                sharesByPair.put(
                    keyValue,
                    new List<Accounting_Company__Share>()
                );
            }

            sharesByPair.get(keyValue).add(shareRecord);
        }

        List<Accounting_Company__Share> toInsert =
            new List<Accounting_Company__Share>();
        List<Accounting_Company__Share> toUpdate =
            new List<Accounting_Company__Share>();
        List<Accounting_Company__Share> toDelete =
            new List<Accounting_Company__Share>();

        for (String keyValue : pairKeys) {
            List<String> parts = keyValue.split(':');

            if (parts.size() != 2) {
                continue;
            }

            Id companyId = (Id) parts[0];
            Id userId = (Id) parts[1];

            List<Accounting_Company__Share> existingShares =
                sharesByPair.containsKey(keyValue)
                    ? sharesByPair.get(keyValue)
                    : new List<Accounting_Company__Share>();

            // Never create or retain an explicit Manual share for the owner.
            // The owner already has implicit access to the company.
            if (
                ownerByCompanyId.containsKey(companyId)
                && ownerByCompanyId.get(companyId) == userId
            ) {
                toDelete.addAll(existingShares);
                continue;
            }

            if (effectivePairs.contains(keyValue)) {
                if (existingShares.isEmpty()) {
                    toInsert.add(
                        new Accounting_Company__Share(
                            ParentId = companyId,
                            UserOrGroupId = userId,
                            AccessLevel = ACCESS_LEVEL_READ,
                            RowCause =
                                Schema.Accounting_Company__Share.RowCause.Manual
                        )
                    );
                } else {
                    Accounting_Company__Share primaryShare =
                        existingShares[0];

                    if (primaryShare.AccessLevel != ACCESS_LEVEL_READ) {
                        primaryShare.AccessLevel = ACCESS_LEVEL_READ;
                        toUpdate.add(primaryShare);
                    }

                    for (Integer i = 1; i < existingShares.size(); i++) {
                        toDelete.add(existingShares[i]);
                    }
                }
            } else {
                toDelete.addAll(existingShares);
            }
        }

        if (!toDelete.isEmpty()) {
            delete toDelete;
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }

        insertShares(toInsert);
    }

    /**
     * Generic sharing for a custom object that owns Company__c and has a
     * standalone __Share object.
     */
    @TestVisible
    private static void reconcileCompanyScopedObjectShares(
        String objectApiName,
        Set<String> pairKeys,
        Set<String> effectivePairs,
        Set<Id> companyIds,
        Set<Id> userIds
    ) {
        Map<String, Schema.SObjectType> globalDescribe =
            Schema.getGlobalDescribe();

        if (!globalDescribe.containsKey(objectApiName)) {
            return;
        }

        Schema.DescribeSObjectResult objectDescribe =
            globalDescribe.get(objectApiName).getDescribe();

        if (!objectDescribe.fields.getMap().containsKey('Company__c')) {
            return;
        }

        String shareObjectApiName =
            objectApiName.endsWith('__c')
                ? objectApiName.substring(
                    0,
                    objectApiName.length() - 3
                ) + '__Share'
                : null;

        if (
            String.isBlank(shareObjectApiName)
            || !globalDescribe.containsKey(shareObjectApiName)
        ) {
            // Controlled-by-parent / non-shareable objects are intentionally
            // not directly shared here.
            return;
        }

        Boolean hasOwnerField =
            objectDescribe.fields.getMap().containsKey('OwnerId');

        String companyRecordQuery =
            'SELECT Id, Company__c'
            + (hasOwnerField ? ', OwnerId' : '')
            + ' FROM ' + objectApiName
            + ' WHERE Company__c IN :companyIds';

        List<SObject> companyRecords =
            Database.query(companyRecordQuery);

        if (companyRecords.isEmpty()) {
            return;
        }

        Set<Id> recordIds = new Set<Id>();
        Map<Id, Id> companyByRecordId = new Map<Id, Id>();
        Map<Id, Id> ownerByRecordId = new Map<Id, Id>();

        for (SObject recordValue : companyRecords) {
            Id recordId = (Id) recordValue.get('Id');
            Id companyId = (Id) recordValue.get('Company__c');

            recordIds.add(recordId);
            companyByRecordId.put(recordId, companyId);

            if (hasOwnerField) {
                Id ownerId = (Id) recordValue.get('OwnerId');
                if (ownerId != null) {
                    ownerByRecordId.put(recordId, ownerId);
                }
            }
        }

        List<SObject> existingShares = Database.query(
            'SELECT Id, ParentId, UserOrGroupId, AccessLevel, RowCause '
            + 'FROM ' + shareObjectApiName + ' '
            + 'WHERE ParentId IN :recordIds '
            + 'AND UserOrGroupId IN :userIds '
            + 'AND RowCause = \'Manual\''
        );

        Map<String, List<SObject>> sharesByRecordAndUser =
            new Map<String, List<SObject>>();

        for (SObject shareRecord : existingShares) {
            Id parentId = (Id) shareRecord.get('ParentId');
            Id userId = (Id) shareRecord.get('UserOrGroupId');

            String keyValue = recordUserKey(parentId, userId);

            if (!sharesByRecordAndUser.containsKey(keyValue)) {
                sharesByRecordAndUser.put(
                    keyValue,
                    new List<SObject>()
                );
            }

            sharesByRecordAndUser.get(keyValue).add(shareRecord);
        }

        List<SObject> toInsert = new List<SObject>();
        List<SObject> toUpdate = new List<SObject>();
        List<SObject> toDelete = new List<SObject>();

        Schema.SObjectType shareType =
            globalDescribe.get(shareObjectApiName);

        for (Id recordId : companyByRecordId.keySet()) {
            Id companyId = companyByRecordId.get(recordId);

            for (Id userId : userIds) {
                // Owners already have implicit access. Do not create a
                // redundant Manual share to the owner.
                if (
                    ownerByRecordId.containsKey(recordId)
                    && ownerByRecordId.get(recordId) == userId
                ) {
                    continue;
                }

                String accessPairKey = pairKey(companyId, userId);

                if (!pairKeys.contains(accessPairKey)) {
                    continue;
                }

                String shareKey = recordUserKey(recordId, userId);

                List<SObject> currentShares =
                    sharesByRecordAndUser.containsKey(shareKey)
                        ? sharesByRecordAndUser.get(shareKey)
                        : new List<SObject>();

                if (effectivePairs.contains(accessPairKey)) {
                    if (currentShares.isEmpty()) {
                        SObject newShare = shareType.newSObject();
                        newShare.put('ParentId', recordId);
                        newShare.put('UserOrGroupId', userId);
                        newShare.put('AccessLevel', ACCESS_LEVEL_READ);
                        newShare.put('RowCause', 'Manual');
                        toInsert.add(newShare);
                    } else {
                        SObject primaryShare = currentShares[0];

                        if (
                            String.valueOf(
                                primaryShare.get('AccessLevel')
                            ) != ACCESS_LEVEL_READ
                        ) {
                            primaryShare.put(
                                'AccessLevel',
                                ACCESS_LEVEL_READ
                            );
                            toUpdate.add(primaryShare);
                        }

                        for (
                            Integer i = 1;
                            i < currentShares.size();
                            i++
                        ) {
                            toDelete.add(currentShares[i]);
                        }
                    }
                } else {
                    toDelete.addAll(currentShares);
                }
            }
        }

        if (!toDelete.isEmpty()) {
            Database.delete(toDelete, false);
        }

        if (!toUpdate.isEmpty()) {
            Database.update(toUpdate, false);
        }

        insertDynamicShares(toInsert, objectApiName);
    }

    private static void insertShares(
        List<Accounting_Company__Share> sharesToInsert
    ) {
        if (sharesToInsert == null || sharesToInsert.isEmpty()) {
            return;
        }

        Database.SaveResult[] results =
            Database.insert(sharesToInsert, false);

        throwForUnexpectedShareErrors(
            results,
            'Accounting_Company__c'
        );
    }

    private static void insertDynamicShares(
        List<SObject> sharesToInsert,
        String objectApiName
    ) {
        if (sharesToInsert == null || sharesToInsert.isEmpty()) {
            return;
        }

        Database.SaveResult[] results =
            Database.insert(sharesToInsert, false);

        throwForUnexpectedShareErrors(results, objectApiName);
    }

    /**
     * A concurrent reconciliation may create the same Manual share between
     * our query and insert. Duplicate share errors are therefore harmless.
     */
    private static void throwForUnexpectedShareErrors(
        Database.SaveResult[] results,
        String objectApiName
    ) {
        for (Database.SaveResult result : results) {
            if (result.isSuccess()) {
                continue;
            }

            for (Database.Error errorValue : result.getErrors()) {
                if (
                    errorValue.getStatusCode()
                    == StatusCode.DUPLICATE_VALUE
                ) {
                    continue;
                }

                throw new CompanySharingException(
                    'Unable to maintain sharing for '
                    + objectApiName
                    + '. '
                    + errorValue.getStatusCode()
                    + ': '
                    + errorValue.getMessage()
                );
            }
        }
    }

    @TestVisible
    private static Boolean isCurrentlyEffective(
        Company_User_Access__c grant,
        Date today
    ) {
        if (
            grant == null
            || grant.Company__c == null
            || grant.User__c == null
            || grant.Is_Active__c != true
            || grant.Effective_From__c == null
        ) {
            return false;
        }

        if (grant.Effective_From__c > today) {
            return false;
        }

        return grant.Effective_To__c == null
            || grant.Effective_To__c >= today;
    }

    @TestVisible
    private static List<String> getShareableSupportedObjects() {
        List<String> shareableObjects = new List<String>();
        Map<String, Schema.SObjectType> globalDescribe =
            Schema.getGlobalDescribe();

        for (String objectApiName : COMPANY_SCOPED_OBJECTS) {
            if (!globalDescribe.containsKey(objectApiName)) {
                continue;
            }

            Schema.DescribeSObjectResult objectDescribe =
                globalDescribe.get(objectApiName).getDescribe();

            if (!objectDescribe.fields.getMap().containsKey('Company__c')) {
                continue;
            }

            String shareObjectApiName =
                objectApiName.substring(
                    0,
                    objectApiName.length() - 3
                ) + '__Share';

            if (globalDescribe.containsKey(shareObjectApiName)) {
                shareableObjects.add(objectApiName);
            }
        }

        return shareableObjects;
    }

    private static Set<String> buildPairs(
        List<Company_User_Access__c> records
    ) {
        Set<String> pairKeys = new Set<String>();

        if (records == null) {
            return pairKeys;
        }

        for (Company_User_Access__c grant : records) {
            if (grant.Company__c != null && grant.User__c != null) {
                pairKeys.add(
                    pairKey(grant.Company__c, grant.User__c)
                );
            }
        }

        return pairKeys;
    }

    private static String pairKey(Id companyId, Id userId) {
        return String.valueOf(companyId)
            + ':'
            + String.valueOf(userId);
    }

    private static String recordUserKey(Id recordId, Id userId) {
        return String.valueOf(recordId)
            + ':'
            + String.valueOf(userId);
    }
}
