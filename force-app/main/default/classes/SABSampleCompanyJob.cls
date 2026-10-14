/**
 * G22H: one step of the sample company load per queueable, so each posting runs with its own governor limits.
 * The job runs as the user who started the load; see SABSampleCompanyService for the steps.
 */
public with sharing class SABSampleCompanyJob implements Queueable {
    private final Id runId;
    private final Integer step;

    public SABSampleCompanyJob(Id runId, Integer step) {
        this.runId = runId;
        this.step = step;
    }

    public void execute(QueueableContext context) {
        Boolean more = SABSampleCompanyService.runStep(runId, step);
        if (more && !Test.isRunningTest()) {
            System.enqueueJob(new SABSampleCompanyJob(runId, step + 1));
        }
    }
}
