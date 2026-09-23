/**
 * Simple Accounting Books - Period Service.
 *
 * Sequential core-ledger service after Posting and Reversal.
 *
 * Exact current metadata used:
 *
 * Accounting_Period__c
 * - Company__c
 * - Status__c
 * - Closed_By__c
 * - Closed_At__c
 * - Close_Request_Key__c
 * - Start_Date__c
 * - End_Date__c
 *
 * Accounting_Period_Action__c
 * - Period__c
 * - Previous_Status__c
 * - New_Status__c
 * - Performed_By__c
 * - Performed_At__c
 * - Reason__c
 * - Request_Key__c
 *
 * Security:
 * - SAB_Close_Period
 * - SAB_Reopen_Period
 * - SABCompanyAccessService
 *
 * Design:
 * - Period row is locked before changing state.
 * - Close/Reopen create immutable action-history records.
 * - Request_Key__c provides idempotency.
 * - A closed period blocks posting because SABJournalValidationService requires
 *   Accounting_Period__c.Status__c = Open while SABPostingService locks the
 *   same period before posting.
 */
public without sharing class SABPeriodService {

    public class PeriodServiceException extends Exception {}

    private static final String STATUS_OPEN = 'Open';
    private static final String STATUS_CLOSED = 'Closed';

    private static final String CLOSE_PERMISSION =
        'SAB_Close_Period';

    private static final String REOPEN_PERMISSION =
        'SAB_Reopen_Period';

    public class PeriodActionRequest {
        public Id periodId { get; set; }
        public String requestKey { get; set; }
        public String reason { get; set; }
    }

    public class PeriodActionResult {
        public Id periodId { get; private set; }
        public Id actionId { get; private set; }
        public String previousStatus { get; private set; }
        public String newStatus { get; private set; }
        public String currentPeriodStatus { get; private set; }
        public Datetime performedAt { get; private set; }
        public Boolean replay { get; private set; }

        private PeriodActionResult(
            Accounting_Period__c periodRecord,
            Accounting_Period_Action__c actionRecord,
            Boolean wasReplay
        ) {
            periodId = periodRecord.Id;
            actionId = actionRecord.Id;
            previousStatus =
                actionRecord.Previous_Status__c;
            newStatus =
                actionRecord.New_Status__c;
            currentPeriodStatus =
                periodRecord.Status__c;
            performedAt =
                actionRecord.Performed_At__c;
            replay = wasReplay;
        }
    }

    public static PeriodActionResult closePeriod(
        PeriodActionRequest request
    ) {
        SABPermissionService.assertPermission(
            CLOSE_PERMISSION,
            'You do not have permission to close Accounting Periods.'
        );

        validateRequest(request, true);
        assertCloseAccess();

        return transitionPeriod(
            request,
            STATUS_OPEN,
            STATUS_CLOSED
        );
    }

    public static PeriodActionResult reopenPeriod(
        PeriodActionRequest request
    ) {
        SABPermissionService.assertPermission(
            REOPEN_PERMISSION,
            'You do not have permission to reopen Accounting Periods.'
        );

        validateRequest(request, false);
        assertReopenAccess();

        return transitionPeriod(
            request,
            STATUS_CLOSED,
            STATUS_OPEN
        );
    }

    private static PeriodActionResult transitionPeriod(
        PeriodActionRequest request,
        String expectedStatus,
        String targetStatus
    ) {
        Savepoint sp = Database.setSavepoint();

        try {
            Accounting_Period__c periodRecord = [
                SELECT Id,
                       Company__c,
                       Status__c,
                       Closed_By__c,
                       Closed_At__c,
                       Close_Request_Key__c,
                       Start_Date__c,
                       End_Date__c
                FROM Accounting_Period__c
                WHERE Id = :request.periodId
                LIMIT 1
                FOR UPDATE
            ];

            SABCompanyAccessService.assertCompanyAccess(
                periodRecord.Company__c
            );

            Accounting_Period_Action__c existingAction =
                findActionByRequestKey(
                    request.requestKey
                );

            if (existingAction != null) {
                assertReplayCompatible(
                    existingAction,
                    periodRecord.Id,
                    expectedStatus,
                    targetStatus
                );

                return new PeriodActionResult(
                    periodRecord,
                    existingAction,
                    true
                );
            }

            if (periodRecord.Status__c != expectedStatus) {
                throw new PeriodServiceException(
                    targetStatus == STATUS_CLOSED
                        ? 'Only an Open Accounting Period can be closed.'
                        : 'Only a Closed Accounting Period can be reopened.'
                );
            }

            Datetime performedAt = System.now();

            if (targetStatus == STATUS_CLOSED) {
                periodRecord.Status__c =
                    STATUS_CLOSED;
                periodRecord.Closed_By__c =
                    UserInfo.getUserId();
                periodRecord.Closed_At__c =
                    performedAt;
                periodRecord.Close_Request_Key__c =
                    request.requestKey.trim();
            } else {
                periodRecord.Status__c =
                    STATUS_OPEN;

                // Current-state fields describe whether the period is
                // presently closed. Historical close/reopen details remain
                // preserved in Accounting_Period_Action__c.
                periodRecord.Closed_By__c = null;
                periodRecord.Closed_At__c = null;
                periodRecord.Close_Request_Key__c = null;
            }

            update periodRecord;

            Accounting_Period_Action__c actionRecord =
                new Accounting_Period_Action__c(
                    Period__c =
                        periodRecord.Id,
                    Previous_Status__c =
                        expectedStatus,
                    New_Status__c =
                        targetStatus,
                    Performed_By__c =
                        UserInfo.getUserId(),
                    Performed_At__c =
                        performedAt,
                    Reason__c =
                        request.reason.trim(),
                    Request_Key__c =
                        request.requestKey.trim()
                );

            insert actionRecord;

            return new PeriodActionResult(
                periodRecord,
                actionRecord,
                false
            );
        } catch (DmlException ex) {
            Database.rollback(sp);

            if (containsDuplicateValue(ex)) {
                Accounting_Period_Action__c existingAction =
                    findActionByRequestKey(
                        request.requestKey
                    );

                if (existingAction != null) {
                    Accounting_Period__c currentPeriod = [
                        SELECT Id,
                               Status__c
                        FROM Accounting_Period__c
                        WHERE Id = :request.periodId
                        LIMIT 1
                    ];

                    assertReplayCompatible(
                        existingAction,
                        request.periodId,
                        expectedStatus,
                        targetStatus
                    );

                    return new PeriodActionResult(
                        currentPeriod,
                        existingAction,
                        true
                    );
                }
            }

            throw ex;
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
    }

    private static Accounting_Period_Action__c
        findActionByRequestKey(
            String requestKey
        ) {

        List<Accounting_Period_Action__c> actions = [
            SELECT Id,
                   Period__c,
                   Previous_Status__c,
                   New_Status__c,
                   Performed_By__c,
                   Performed_At__c,
                   Reason__c,
                   Request_Key__c
            FROM Accounting_Period_Action__c
            WHERE Request_Key__c = :requestKey
            LIMIT 1
        ];

        return actions.isEmpty()
            ? null
            : actions[0];
    }

    private static void assertReplayCompatible(
        Accounting_Period_Action__c existingAction,
        Id periodId,
        String expectedStatus,
        String targetStatus
    ) {
        if (
            existingAction.Period__c != periodId
            || existingAction.Previous_Status__c
                != expectedStatus
            || existingAction.New_Status__c
                != targetStatus
        ) {
            throw new PeriodServiceException(
                'Request Key already exists for a different period action.'
            );
        }
    }

    private static void validateRequest(
        PeriodActionRequest request,
        Boolean closing
    ) {
        if (request == null) {
            throw new PeriodServiceException(
                'Period action request is required.'
            );
        }

        if (request.periodId == null) {
            throw new PeriodServiceException(
                'Accounting Period Id is required.'
            );
        }

        if (String.isBlank(request.requestKey)) {
            throw new PeriodServiceException(
                'Request Key is required.'
            );
        }

        if (String.isBlank(request.reason)) {
            throw new PeriodServiceException(
                closing
                    ? 'A reason is required to close an Accounting Period.'
                    : 'A reason is required to reopen an Accounting Period.'
            );
        }

        assertLength(
            request.requestKey,
            Accounting_Period_Action__c.Request_Key__c,
            'Request Key'
        );

        assertLength(
            request.reason,
            Accounting_Period_Action__c.Reason__c,
            'Reason'
        );

        if (closing) {
            assertLength(
                request.requestKey,
                Accounting_Period__c.Close_Request_Key__c,
                'Close Request Key'
            );
        }
    }

    private static void assertCloseAccess() {
        assertPeriodObjectAccess();
        assertActionCreateAccess();

        assertReadableUpdateable(
            Accounting_Period__c.Status__c,
            'Accounting Period Status'
        );
        assertReadableUpdateable(
            Accounting_Period__c.Closed_By__c,
            'Accounting Period Closed By'
        );
        assertReadableUpdateable(
            Accounting_Period__c.Closed_At__c,
            'Accounting Period Closed At'
        );
        assertReadableUpdateable(
            Accounting_Period__c.Close_Request_Key__c,
            'Accounting Period Close Request Key'
        );
    }

    private static void assertReopenAccess() {
        assertCloseAccess();
    }

    private static void assertPeriodObjectAccess() {
        Schema.DescribeSObjectResult periodDescribe =
            Accounting_Period__c.SObjectType
                .getDescribe();

        if (
            !periodDescribe.isAccessible()
            || !periodDescribe.isUpdateable()
        ) {
            throw new PeriodServiceException(
                'You do not have required access to Accounting Periods.'
            );
        }
    }

    /**
     * Accounting_Period_Action__c is service-created immutable audit history.
     *
     * Business users are intentionally not required to have Create/Edit FLS
     * on service-controlled audit fields such as Performed_By__c and
     * Performed_At__c. Requiring those permissions would weaken the audit
     * model by encouraging direct user creation/editing of history records.
     *
     * Authorization is instead enforced by:
     * - SAB_Close_Period / SAB_Reopen_Period custom permissions
     * - SABCompanyAccessService
     * - narrow system-mode DML inside this service
     * - SABAccountingPeriodActionGuardTrigger preventing update/delete
     *
     * We only require read access so the resulting audit history can be
     * inspected by the authorized user.
     */
    private static void assertActionCreateAccess() {
        Schema.DescribeSObjectResult actionDescribe =
            Accounting_Period_Action__c.SObjectType
                .getDescribe();

        if (!actionDescribe.isAccessible()) {
            throw new PeriodServiceException(
                'You do not have read access to Accounting Period Actions.'
            );
        }

        assertReadable(
            Accounting_Period_Action__c.Period__c,
            'Period Action Period'
        );
        assertReadable(
            Accounting_Period_Action__c.Previous_Status__c,
            'Period Action Previous Status'
        );
        assertReadable(
            Accounting_Period_Action__c.New_Status__c,
            'Period Action New Status'
        );
        assertReadable(
            Accounting_Period_Action__c.Performed_By__c,
            'Period Action Performed By'
        );
        assertReadable(
            Accounting_Period_Action__c.Performed_At__c,
            'Period Action Performed At'
        );
        assertReadable(
            Accounting_Period_Action__c.Reason__c,
            'Period Action Reason'
        );
        assertReadable(
            Accounting_Period_Action__c.Request_Key__c,
            'Period Action Request Key'
        );
    }

    private static void assertReadableUpdateable(
        Schema.SObjectField fieldToken,
        String fieldLabel
    ) {
        Schema.DescribeFieldResult describeResult =
            fieldToken.getDescribe();

        if (
            !describeResult.isAccessible()
            || !describeResult.isUpdateable()
        ) {
            throw new PeriodServiceException(
                'You do not have required field access to '
                + fieldLabel
                + '.'
            );
        }
    }

    private static void assertReadable(
        Schema.SObjectField fieldToken,
        String fieldLabel
    ) {
        Schema.DescribeFieldResult describeResult =
            fieldToken.getDescribe();

        if (!describeResult.isAccessible()) {
            throw new PeriodServiceException(
                'You do not have read access to '
                + fieldLabel
                + '.'
            );
        }
    }

    private static void assertLength(
        String value,
        Schema.SObjectField fieldToken,
        String fieldLabel
    ) {
        if (value == null) {
            return;
        }

        Integer maxLength =
            fieldToken.getDescribe().getLength();

        if (
            maxLength > 0
            && value.length() > maxLength
        ) {
            throw new PeriodServiceException(
                fieldLabel
                + ' cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static Boolean containsDuplicateValue(
        DmlException ex
    ) {
        for (Integer i = 0; i < ex.getNumDml(); i++) {
            if (
                ex.getDmlStatusCode(i)
                == 'DUPLICATE_VALUE'
            ) {
                return true;
            }
        }

        return false;
    }
}
