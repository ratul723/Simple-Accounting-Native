/**
 * G6D - Tax Return Review, Submission, Locking & Amendment Lifecycle.
 *
 * Lifecycle:
 * Prepared -> Reviewed -> Submitted -> Accepted / Rejected -> Amended
 *
 * A new amendment is created as a fresh Draft Tax_Return__c with version + 1.
 * The prior Accepted/Rejected return is marked Amended. G6C can then prepare
 * the new Draft version from current posted Document_Tax_Line__c snapshots.
 *
 * All lifecycle actions are company-scoped, custom-permission protected,
 * request-key idempotent, and logged to Business_Action__c.
 */
public without sharing class SABTaxReturnLifecycleService {

    public class TaxReturnLifecycleException extends Exception {}

    private static final String SOURCE_TYPE =
        'Tax_Return__c';

    private static final String STATUS_DRAFT =
        'Draft';
    private static final String STATUS_PREPARED =
        'Prepared';
    private static final String STATUS_REVIEWED =
        'Reviewed';
    private static final String STATUS_SUBMITTED =
        'Submitted';
    private static final String STATUS_ACCEPTED =
        'Accepted';
    private static final String STATUS_REJECTED =
        'Rejected';
    private static final String STATUS_AMENDED =
        'Amended';

    private static final String PERM_REVIEW =
        'SAB_Review_Tax_Return';
    private static final String PERM_SUBMIT =
        'SAB_Submit_Tax_Return';
    private static final String PERM_OUTCOME =
        'SAB_Record_Tax_Authority_Outcome';
    private static final String PERM_AMEND =
        'SAB_Amend_Tax_Return';

    private static final Set<String> REQUIRED_BOXES =
        new Set<String>{
            'OUTPUT_TAXABLE_BASE',
            'OUTPUT_TAX',
            'INPUT_TAXABLE_BASE',
            'INPUT_TAX_RECOVERABLE',
            'NET_TAX_DUE'
        };

    @TestVisible
    private static Boolean lifecycleMutationInProgress =
        false;

    public class LifecycleResult {
        @AuraEnabled public Id taxReturnId { get; private set; }
        @AuraEnabled public String status { get; private set; }
        @AuraEnabled public Decimal returnVersion { get; private set; }
        @AuraEnabled public String lockedSourceHash { get; private set; }
        @AuraEnabled public String filingReference { get; private set; }
        @AuraEnabled public String acknowledgementReference { get; private set; }
        @AuraEnabled public Id amendmentTaxReturnId { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }

        private LifecycleResult() {}
    }

    public static Boolean isLifecycleMutationInProgress() {
        return lifecycleMutationInProgress;
    }

    @AuraEnabled
    public static LifecycleResult reviewReturn(
        Id taxReturnId,
        String requestKey,
        String reason
    ) {
        SABPermissionService.assertPermission(
            PERM_REVIEW,
            'You do not have permission to review Tax Returns.'
        );

        validateRequestKey(requestKey);

        LifecycleResult replay =
            findReplay(
                taxReturnId,
                requestKey,
                'Tax Return Reviewed'
            );

        if (replay != null) {
            return replay;
        }

        Tax_Return__c taxReturn =
            lockReturn(
                taxReturnId
            );

        SABCompanyAccessService.assertCompanyAccess(
            taxReturn.Company__c
        );

        if (taxReturn.Status__c != STATUS_PREPARED) {
            throw new TaxReturnLifecycleException(
                'Only a Prepared Tax Return can be reviewed.'
            );
        }

        List<Tax_Return_Line__c> lines =
            loadAndValidateReviewLines(
                taxReturn.Id
            );

        String snapshotHash =
            calculateReturnSnapshotHash(
                taxReturn,
                lines
            );

        beginMutation();

        try {
            taxReturn.Locked_Source_Hash__c =
                snapshotHash;
            taxReturn.Status__c =
                STATUS_REVIEWED;
            update taxReturn;
        } finally {
            endMutation();
        }

        logAction(
            taxReturn,
            'Tax Return Reviewed',
            requestKey,
            reason
        );

        return buildResult(
            taxReturn.Id,
            false,
            null
        );
    }

    @AuraEnabled
    public static LifecycleResult submitReturn(
        Id taxReturnId,
        String filingReference,
        String requestKey,
        String reason
    ) {
        SABPermissionService.assertPermission(
            PERM_SUBMIT,
            'You do not have permission to submit Tax Returns.'
        );

        validateRequestKey(requestKey);
        validateTextLength(
            filingReference,
            'Filing Reference',
            Tax_Return__c.Filing_Reference__c.getDescribe().getLength(),
            true
        );

        LifecycleResult replay =
            findReplay(
                taxReturnId,
                requestKey,
                'Tax Return Submitted'
            );

        if (replay != null) {
            return replay;
        }

        Tax_Return__c taxReturn =
            lockReturn(
                taxReturnId
            );

        SABCompanyAccessService.assertCompanyAccess(
            taxReturn.Company__c
        );

        if (taxReturn.Status__c != STATUS_REVIEWED) {
            throw new TaxReturnLifecycleException(
                'Only a Reviewed Tax Return can be submitted.'
            );
        }

        assertReviewedSnapshotStillMatches(
            taxReturn
        );

        beginMutation();

        try {
            taxReturn.Filing_Reference__c =
                filingReference.trim();
            taxReturn.Status__c =
                STATUS_SUBMITTED;
            update taxReturn;
        } finally {
            endMutation();
        }

        logAction(
            taxReturn,
            'Tax Return Submitted',
            requestKey,
            reason
        );

        return buildResult(
            taxReturn.Id,
            false,
            null
        );
    }

    @AuraEnabled
    public static LifecycleResult recordAuthorityOutcome(
        Id taxReturnId,
        String outcome,
        String acknowledgementReference,
        String requestKey,
        String reason
    ) {
        SABPermissionService.assertPermission(
            PERM_OUTCOME,
            'You do not have permission to record Tax Authority outcomes.'
        );

        validateRequestKey(requestKey);
        validateTextLength(
            acknowledgementReference,
            'Acknowledgement Reference',
            Tax_Return__c.Acknowledgement_Reference__c.getDescribe().getLength(),
            true
        );

        String normalizedOutcome =
            normalizeOutcome(
                outcome
            );

        String actionName =
            normalizedOutcome == STATUS_ACCEPTED
                ? 'Tax Return Accepted'
                : 'Tax Return Rejected';

        LifecycleResult replay =
            findReplay(
                taxReturnId,
                requestKey,
                actionName
            );

        if (replay != null) {
            return replay;
        }

        Tax_Return__c taxReturn =
            lockReturn(
                taxReturnId
            );

        SABCompanyAccessService.assertCompanyAccess(
            taxReturn.Company__c
        );

        if (taxReturn.Status__c != STATUS_SUBMITTED) {
            throw new TaxReturnLifecycleException(
                'Only a Submitted Tax Return can receive an authority outcome.'
            );
        }

        assertReviewedSnapshotStillMatches(
            taxReturn
        );

        beginMutation();

        try {
            taxReturn.Acknowledgement_Reference__c =
                acknowledgementReference.trim();
            taxReturn.Status__c =
                normalizedOutcome;
            update taxReturn;
        } finally {
            endMutation();
        }

        logAction(
            taxReturn,
            actionName,
            requestKey,
            reason
        );

        return buildResult(
            taxReturn.Id,
            false,
            null
        );
    }

    @AuraEnabled
    public static LifecycleResult createAmendment(
        Id taxReturnId,
        String requestKey,
        String reason
    ) {
        SABPermissionService.assertPermission(
            PERM_AMEND,
            'You do not have permission to amend Tax Returns.'
        );

        validateRequestKey(requestKey);

        if (String.isBlank(reason)) {
            throw new TaxReturnLifecycleException(
                'Amendment Reason is required.'
            );
        }

        LifecycleResult replay =
            findReplay(
                taxReturnId,
                requestKey,
                'Tax Return Amendment Created'
            );

        if (replay != null) {
            List<Tax_Return__c> existingAmendments = [
                SELECT Id
                FROM Tax_Return__c
                WHERE Amends_Tax_Return__c =
                        :taxReturnId
                ORDER BY Return_Version__c DESC
                LIMIT 1
            ];

            if (!existingAmendments.isEmpty()) {
                replay.amendmentTaxReturnId =
                    existingAmendments[0].Id;
            }

            return replay;
        }

        Tax_Return__c original =
            lockReturn(
                taxReturnId
            );

        SABCompanyAccessService.assertCompanyAccess(
            original.Company__c
        );

        if (
            original.Status__c != STATUS_ACCEPTED
            && original.Status__c != STATUS_REJECTED
        ) {
            throw new TaxReturnLifecycleException(
                'Only an Accepted or Rejected Tax Return can be amended.'
            );
        }

        if (
            String.isBlank(
                original.Locked_Source_Hash__c
            )
        ) {
            throw new TaxReturnLifecycleException(
                'The filed Tax Return is missing its reviewed source lock hash.'
            );
        }

        Integer existingAmendmentCount = [
            SELECT COUNT()
            FROM Tax_Return__c
            WHERE Amends_Tax_Return__c =
                    :original.Id
        ];

        if (existingAmendmentCount > 0) {
            throw new TaxReturnLifecycleException(
                'An amendment version already exists for this Tax Return.'
            );
        }

        Decimal nextVersion =
            (original.Return_Version__c == null
                ? Decimal.valueOf('0')
                : original.Return_Version__c)
            + Decimal.valueOf('1');

        Tax_Return__c amendment =
            new Tax_Return__c(
                Company__c =
                    original.Company__c,
                Tax_Registration__c =
                    original.Tax_Registration__c,
                Period_Start__c =
                    original.Period_Start__c,
                Period_End__c =
                    original.Period_End__c,
                Country_Pack_Version__c =
                    original.Country_Pack_Version__c,
                Return_Version__c =
                    nextVersion,
                Status__c =
                    STATUS_DRAFT,
                Amends_Tax_Return__c =
                    original.Id
            );

        beginMutation();

        try {
            original.Status__c =
                STATUS_AMENDED;
            update original;

            insert amendment;
        } finally {
            endMutation();
        }

        logAction(
            original,
            'Tax Return Amendment Created',
            requestKey,
            reason
                + ' · Amendment Return Id: '
                + String.valueOf(
                    amendment.Id
                )
        );

        LifecycleResult result =
            buildResult(
                original.Id,
                false,
                amendment.Id
            );

        return result;
    }

    private static Tax_Return__c lockReturn(
        Id taxReturnId
    ) {
        if (taxReturnId == null) {
            throw new TaxReturnLifecycleException(
                'Tax Return Id is required.'
            );
        }

        return [
            SELECT Id,
                   Name,
                   Company__c,
                   Tax_Registration__c,
                   Period_Start__c,
                   Period_End__c,
                   Country_Pack_Version__c,
                   Return_Version__c,
                   Status__c,
                   Filing_Reference__c,
                   Acknowledgement_Reference__c,
                   Locked_Source_Hash__c,
                   Amends_Tax_Return__c
            FROM Tax_Return__c
            WHERE Id = :taxReturnId
            LIMIT 1
            FOR UPDATE
        ];
    }

    private static List<Tax_Return_Line__c>
        loadAndValidateReviewLines(
            Id taxReturnId
        )
    {
        List<Tax_Return_Line__c> lines = [
            SELECT Id,
                   Box_Key__c,
                   Label__c,
                   Calculated_Amount__c,
                   Adjustment_Amount__c,
                   Final_Amount__c,
                   Source_Inclusion_Hash__c
            FROM Tax_Return_Line__c
            WHERE Tax_Return__c =
                    :taxReturnId
            ORDER BY Box_Key__c ASC,
                     Id ASC
        ];

        if (lines.isEmpty()) {
            throw new TaxReturnLifecycleException(
                'Prepared Tax Return must contain return lines before review.'
            );
        }

        Set<String> seenBoxes =
            new Set<String>();

        for (Tax_Return_Line__c line : lines) {
            if (String.isBlank(line.Box_Key__c)) {
                throw new TaxReturnLifecycleException(
                    'Tax Return Line Box Key is required.'
                );
            }

            if (seenBoxes.contains(line.Box_Key__c)) {
                throw new TaxReturnLifecycleException(
                    'Duplicate Tax Return Box Key found: '
                    + line.Box_Key__c
                );
            }

            seenBoxes.add(
                line.Box_Key__c
            );

            if (
                String.isBlank(
                    line.Source_Inclusion_Hash__c
                )
            ) {
                throw new TaxReturnLifecycleException(
                    'Tax Return Line '
                    + line.Box_Key__c
                    + ' is missing its Source Inclusion Hash.'
                );
            }

            if (line.Final_Amount__c == null) {
                throw new TaxReturnLifecycleException(
                    'Tax Return Line '
                    + line.Box_Key__c
                    + ' is missing its Final Amount.'
                );
            }
        }

        if (!seenBoxes.containsAll(REQUIRED_BOXES)) {
            Set<String> missing =
                new Set<String>();

            missing.addAll(
                REQUIRED_BOXES
            );

            missing.removeAll(
                seenBoxes
            );

            List<String> missingList =
                new List<String>(
                    missing
                );

            missingList.sort();

            throw new TaxReturnLifecycleException(
                'Prepared Tax Return is missing required generic boxes: '
                + String.join(
                    missingList,
                    ', '
                )
            );
        }

        return lines;
    }

    private static void assertReviewedSnapshotStillMatches(
        Tax_Return__c taxReturn
    ) {
        if (
            String.isBlank(
                taxReturn.Locked_Source_Hash__c
            )
        ) {
            throw new TaxReturnLifecycleException(
                'Reviewed Tax Return is missing its Locked Source Hash.'
            );
        }

        List<Tax_Return_Line__c> lines =
            loadAndValidateReviewLines(
                taxReturn.Id
            );

        String currentHash =
            calculateReturnSnapshotHash(
                taxReturn,
                lines
            );

        if (
            currentHash
            != taxReturn.Locked_Source_Hash__c
        ) {
            throw new TaxReturnLifecycleException(
                'Tax Return changed after review. Re-prepare and review a controlled version before submission.'
            );
        }
    }

    private static String calculateReturnSnapshotHash(
        Tax_Return__c taxReturn,
        List<Tax_Return_Line__c> lines
    ) {
        List<String> canonical =
            new List<String>();

        canonical.add(
            'COMPANY='
            + String.valueOf(
                taxReturn.Company__c
            )
        );

        canonical.add(
            'REGISTRATION='
            + String.valueOf(
                taxReturn.Tax_Registration__c
            )
        );

        canonical.add(
            'PERIOD='
            + String.valueOf(
                taxReturn.Period_Start__c
            )
            + ':'
            + String.valueOf(
                taxReturn.Period_End__c
            )
        );

        canonical.add(
            'COUNTRY_PACK='
            + String.valueOf(
                taxReturn.Country_Pack_Version__c
            )
        );

        canonical.add(
            'VERSION='
            + String.valueOf(
                taxReturn.Return_Version__c
            )
        );

        for (Tax_Return_Line__c line : lines) {
            canonical.add(
                String.valueOf(
                    line.Box_Key__c
                )
                + '|'
                + normalizeDecimalText(
                    line.Calculated_Amount__c
                )
                + '|'
                + normalizeDecimalText(
                    line.Adjustment_Amount__c
                )
                + '|'
                + normalizeDecimalText(
                    line.Final_Amount__c
                )
                + '|'
                + String.valueOf(
                    line.Source_Inclusion_Hash__c
                )
            );
        }

        return EncodingUtil.convertToHex(
            Crypto.generateDigest(
                'SHA-256',
                Blob.valueOf(
                    String.join(
                        canonical,
                        '\n'
                    )
                )
            )
        );
    }

    private static String normalizeDecimalText(
        Decimal value
    ) {
        Decimal baseValue =
            value == null
                ? Decimal.valueOf('0')
                : value;

        Decimal normalized = baseValue.setScale(
            4,
            RoundingMode.HALF_UP
        );

        return String.valueOf(
            normalized
        );
    }

    private static void logAction(
        Tax_Return__c taxReturn,
        String actionName,
        String requestKey,
        String reason
    ) {
        insert new Business_Action__c(
            Company__c =
                taxReturn.Company__c,
            Action__c =
                actionName,
            Actor__c =
                UserInfo.getUserId(),
            Action_At__c =
                System.now(),
            Reason__c =
                reason,
            Request_Key__c =
                requestKey.trim(),
            Source_Type__c =
                SOURCE_TYPE,
            Source_Record_Id__c =
                String.valueOf(
                    taxReturn.Id
                ),
            Source_Version__c =
                taxReturn.Return_Version__c
        );
    }

    private static LifecycleResult findReplay(
        Id taxReturnId,
        String requestKey,
        String expectedAction
    ) {
        if (
            taxReturnId == null
            || String.isBlank(requestKey)
        ) {
            return null;
        }

        List<Business_Action__c> matches = [
            SELECT Id,
                   Action__c,
                   Source_Type__c,
                   Source_Record_Id__c
            FROM Business_Action__c
            WHERE Request_Key__c =
                    :requestKey.trim()
            LIMIT 1
        ];

        if (matches.isEmpty()) {
            return null;
        }

        Business_Action__c actionRecord =
            matches[0];

        if (
            actionRecord.Action__c != expectedAction
            || actionRecord.Source_Type__c != SOURCE_TYPE
            || actionRecord.Source_Record_Id__c
                != String.valueOf(
                    taxReturnId
                )
        ) {
            throw new TaxReturnLifecycleException(
                'Request Key was already used for a different Tax Return lifecycle action.'
            );
        }

        return buildResult(
            taxReturnId,
            true,
            null
        );
    }

    private static LifecycleResult buildResult(
        Id taxReturnId,
        Boolean replay,
        Id amendmentTaxReturnId
    ) {
        Tax_Return__c taxReturn = [
            SELECT Id,
                   Status__c,
                   Return_Version__c,
                   Locked_Source_Hash__c,
                   Filing_Reference__c,
                   Acknowledgement_Reference__c
            FROM Tax_Return__c
            WHERE Id = :taxReturnId
            LIMIT 1
        ];

        LifecycleResult result =
            new LifecycleResult();

        result.taxReturnId =
            taxReturn.Id;
        result.status =
            taxReturn.Status__c;
        result.returnVersion =
            taxReturn.Return_Version__c;
        result.lockedSourceHash =
            taxReturn.Locked_Source_Hash__c;
        result.filingReference =
            taxReturn.Filing_Reference__c;
        result.acknowledgementReference =
            taxReturn.Acknowledgement_Reference__c;
        result.amendmentTaxReturnId =
            amendmentTaxReturnId;
        result.replay =
            replay;

        return result;
    }

    private static String normalizeOutcome(
        String outcome
    ) {
        if (String.isBlank(outcome)) {
            throw new TaxReturnLifecycleException(
                'Tax Authority Outcome is required.'
            );
        }

        String normalized =
            outcome.trim();

        if (
            normalized.equalsIgnoreCase(
                STATUS_ACCEPTED
            )
        ) {
            return STATUS_ACCEPTED;
        }

        if (
            normalized.equalsIgnoreCase(
                STATUS_REJECTED
            )
        ) {
            return STATUS_REJECTED;
        }

        throw new TaxReturnLifecycleException(
            'Tax Authority Outcome must be Accepted or Rejected.'
        );
    }

    private static void validateRequestKey(
        String requestKey
    ) {
        if (String.isBlank(requestKey)) {
            throw new TaxReturnLifecycleException(
                'Request Key is required.'
            );
        }

        Integer maxLength =
            Business_Action__c.Request_Key__c.getDescribe().getLength();

        if (
            requestKey.trim().length()
                > maxLength
        ) {
            throw new TaxReturnLifecycleException(
                'Request Key cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static void validateTextLength(
        String value,
        String label,
        Integer maxLength,
        Boolean required
    ) {
        if (
            required
            && String.isBlank(value)
        ) {
            throw new TaxReturnLifecycleException(
                label
                + ' is required.'
            );
        }

        if (
            !String.isBlank(value)
            && value.trim().length()
                > maxLength
        ) {
            throw new TaxReturnLifecycleException(
                label
                + ' cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static void beginMutation() {
        lifecycleMutationInProgress =
            true;
    }

    private static void endMutation() {
        lifecycleMutationInProgress =
            false;
    }
}
