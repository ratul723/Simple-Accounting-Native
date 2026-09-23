/**
 * Simple Accounting Books
 * Step 3B-2C: automatically share NEW/UPDATED company-owned records.
 *
 * This complements SABCompanySharingService:
 * - SABCompanySharingService reacts when Company_User_Access__c changes.
 * - SABCompanyRecordSharingService reacts when a company-owned record is
 *   inserted, moved to another company, or undeleted.
 *
 * No custom Apex Sharing Reason is used. RowCause = Manual.
 *
 * Important limitation of using Manual:
 * Salesforce cannot distinguish a SAB-created Manual share from another
 * Manual share for the same record/user. For a company change, this service
 * only removes Manual shares for users who currently have an effective grant
 * to the OLD company and do not have an effective grant to the NEW company.
 */
public without sharing class SABCompanyRecordSharingService {
    // Owner-share guard:
    // Salesforce already gives the owner implicit record access. Attempting
    // to insert a Manual __Share row for that same owner can fail with
    // INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY.

    private static final String ACCESS_LEVEL_READ = 'Read';

    public class RecordSharingException extends Exception {}

    public static void afterInsert(List<SObject> newRecords) {
        reconcile(newRecords, null);
    }

    public static void afterUpdate(
        List<SObject> newRecords,
        Map<Id, SObject> oldMap
    ) {
        reconcile(newRecords, oldMap);
    }

    public static void afterUndelete(List<SObject> newRecords) {
        reconcile(newRecords, null);
    }

    @TestVisible
    private static void reconcile(
        List<SObject> newRecords,
        Map<Id, SObject> oldMap
    ) {
        if (newRecords == null || newRecords.isEmpty()) {
            return;
        }

        String objectApiName =
            newRecords[0].getSObjectType().getDescribe().getName();

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
            toShareObjectApiName(objectApiName);

        if (
            String.isBlank(shareObjectApiName)
            || !globalDescribe.containsKey(shareObjectApiName)
        ) {
            // Controlled-by-parent objects do not have their own share table.
            return;
        }

        Set<Id> recordIds = new Set<Id>();
        Set<Id> allCompanyIds = new Set<Id>();
        Map<Id, Id> newCompanyByRecord = new Map<Id, Id>();
        Map<Id, Id> oldCompanyByRecord = new Map<Id, Id>();
        Map<Id, Id> ownerByRecord = new Map<Id, Id>();

        Boolean hasOwnerField =
            objectDescribe.fields.getMap().containsKey('OwnerId');

        for (SObject recordValue : newRecords) {
            Id recordId = (Id) recordValue.get('Id');
            Id newCompanyId = (Id) recordValue.get('Company__c');

            if (recordId == null || newCompanyId == null) {
                continue;
            }

            recordIds.add(recordId);
            newCompanyByRecord.put(recordId, newCompanyId);
            allCompanyIds.add(newCompanyId);

            if (hasOwnerField) {
                Id ownerId = (Id) recordValue.get('OwnerId');
                if (ownerId != null) {
                    ownerByRecord.put(recordId, ownerId);
                }
            }

            if (oldMap != null && oldMap.containsKey(recordId)) {
                SObject oldRecord = oldMap.get(recordId);
                Id oldCompanyId = (Id) oldRecord.get('Company__c');

                if (oldCompanyId != null) {
                    oldCompanyByRecord.put(recordId, oldCompanyId);
                    allCompanyIds.add(oldCompanyId);
                }
            }
        }

        if (recordIds.isEmpty() || allCompanyIds.isEmpty()) {
            return;
        }

        Map<Id, Set<Id>> effectiveUsersByCompany =
            loadEffectiveUsersByCompany(allCompanyIds);

        Set<Id> relevantUserIds = new Set<Id>();

        for (Set<Id> userIds : effectiveUsersByCompany.values()) {
            relevantUserIds.addAll(userIds);
        }

        if (relevantUserIds.isEmpty()) {
            return;
        }

        List<SObject> existingShares = Database.query(
            'SELECT Id, ParentId, UserOrGroupId, AccessLevel, RowCause '
            + 'FROM ' + shareObjectApiName + ' '
            + 'WHERE ParentId IN :recordIds '
            + 'AND UserOrGroupId IN :relevantUserIds '
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

        Schema.SObjectType shareType =
            globalDescribe.get(shareObjectApiName);

        List<SObject> sharesToInsert = new List<SObject>();
        List<SObject> sharesToUpdate = new List<SObject>();
        List<SObject> sharesToDelete = new List<SObject>();

        for (Id recordId : recordIds) {
            Id newCompanyId = newCompanyByRecord.get(recordId);

            Set<Id> expectedUsers =
                effectiveUsersByCompany.containsKey(newCompanyId)
                    ? effectiveUsersByCompany.get(newCompanyId)
                    : new Set<Id>();

            for (Id userId : expectedUsers) {
                // The record owner already has implicit access. Salesforce
                // rejects an explicit Manual share back to the owner with
                // INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY.
                if (
                    ownerByRecord.containsKey(recordId)
                    && ownerByRecord.get(recordId) == userId
                ) {
                    continue;
                }

                String shareKey =
                    recordUserKey(recordId, userId);

                List<SObject> currentShares =
                    sharesByRecordAndUser.containsKey(shareKey)
                        ? sharesByRecordAndUser.get(shareKey)
                        : new List<SObject>();

                if (currentShares.isEmpty()) {
                    SObject newShare = shareType.newSObject();
                    newShare.put('ParentId', recordId);
                    newShare.put('UserOrGroupId', userId);
                    newShare.put('AccessLevel', ACCESS_LEVEL_READ);
                    newShare.put('RowCause', 'Manual');
                    sharesToInsert.add(newShare);
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
                        sharesToUpdate.add(primaryShare);
                    }
                }
            }

            // If Company__c changed, remove the old-company access that SAB
            // would otherwise leave behind.
            Id oldCompanyId = oldCompanyByRecord.get(recordId);

            if (
                oldCompanyId != null
                && oldCompanyId != newCompanyId
                && effectiveUsersByCompany.containsKey(oldCompanyId)
            ) {
                for (
                    Id oldCompanyUserId :
                    effectiveUsersByCompany.get(oldCompanyId)
                ) {
                    if (expectedUsers.contains(oldCompanyUserId)) {
                        continue;
                    }

                    String oldShareKey =
                        recordUserKey(recordId, oldCompanyUserId);

                    if (
                        sharesByRecordAndUser.containsKey(oldShareKey)
                    ) {
                        sharesToDelete.addAll(
                            sharesByRecordAndUser.get(oldShareKey)
                        );
                    }
                }
            }
        }

        if (!sharesToDelete.isEmpty()) {
            Database.delete(sharesToDelete, false);
        }

        if (!sharesToUpdate.isEmpty()) {
            Database.update(sharesToUpdate, false);
        }

        if (!sharesToInsert.isEmpty()) {
            Database.SaveResult[] results =
                Database.insert(sharesToInsert, false);

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

                    throw new RecordSharingException(
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
    }

    private static Map<Id, Set<Id>> loadEffectiveUsersByCompany(
        Set<Id> companyIds
    ) {
        Map<Id, Set<Id>> usersByCompany =
            new Map<Id, Set<Id>>();

        if (companyIds == null || companyIds.isEmpty()) {
            return usersByCompany;
        }

        Date today = Date.today();

        for (Company_User_Access__c grant : [
            SELECT Company__c,
                   User__c,
                   Is_Active__c,
                   Effective_From__c,
                   Effective_To__c
            FROM Company_User_Access__c
            WHERE Company__c IN :companyIds
              AND User__c != null
              AND Is_Active__c = true
              AND Effective_From__c <= :today
              AND (
                  Effective_To__c = null
                  OR Effective_To__c >= :today
              )
        ]) {
            if (!usersByCompany.containsKey(grant.Company__c)) {
                usersByCompany.put(
                    grant.Company__c,
                    new Set<Id>()
                );
            }

            usersByCompany.get(grant.Company__c).add(grant.User__c);
        }

        return usersByCompany;
    }

    private static String toShareObjectApiName(
        String objectApiName
    ) {
        if (
            String.isBlank(objectApiName)
            || !objectApiName.endsWith('__c')
        ) {
            return null;
        }

        return objectApiName.substring(
            0,
            objectApiName.length() - 3
        ) + '__Share';
    }

    private static String recordUserKey(
        Id recordId,
        Id userId
    ) {
        return String.valueOf(recordId)
            + ':'
            + String.valueOf(userId);
    }
}
