/**
 * Runs SAB company-sharing reconciliation on a schedule.
 *
 * Recommended production cadence:
 * once daily shortly after midnight in the scheduling user's timezone,
 * because Effective_From__c and Effective_To__c are Date fields.
 */
global without sharing class SABCompanySharingScheduler
    implements Schedulable {

    global void execute(SchedulableContext context) {
        Database.executeBatch(
            new SABCompanySharingReconciliationBatch(),
            50
        );
    }

    /**
     * Optional helper for admins/setup automation.
     * Schedules daily at 12:10 AM in the scheduling user's timezone.
     */
    public static String scheduleDaily() {
        String jobName = 'SAB Daily Company Sharing Reconciliation';
        String cronExpression = '0 10 0 * * ?';

        return System.schedule(
            jobName,
            cronExpression,
            new SABCompanySharingScheduler()
        );
    }
}
