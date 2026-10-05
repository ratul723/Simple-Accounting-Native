/**
 * Test-only SOQL budget guard for SAB test classes.
 *
 * System.LimitException cannot be caught, so a test that runs out of queries reports only
 * "Too many SOQL queries: 101" with no hint of which step was expensive. This utility records
 * queries per step and fails with a readable report while headroom remains.
 *
 * Measured in devscratchorg (G10E): queries used in @TestSetup are still counted in every test
 * method's outer window, before Test.startTest(). One SAB ledger posting costs about 30-35 queries.
 *
 * Rules every SAB test class should follow:
 *   1. Keep @TestSetup lean and end it with SABTestGovernor.assertSetupWithin(50). Seed workflow
 *      state through @TestVisible service scopes instead of replaying earlier stages.
 *   2. Before Test.startTest(): cheap seeding only. Never a posting chain or a full workflow.
 *   3. At most two ledger postings per startTest() .. stopTest() window.
 *   4. After stopTest(): only assertions and cheap calls; the outer window still holds the setup cost.
 *   5. Call requireHeadroom() before each expensive step so a failure names the step.
 *
 * Usage:
 *   @TestSetup static void setupData() { ...; SABTestGovernor.assertSetupWithin(50); }
 *   SABTestGovernor.startTest();   // wraps Test.startTest()
 *   SABTestGovernor.requireHeadroom(35, 'record payment success');
 *   SABTestGovernor.stopTest();    // wraps Test.stopTest()
 */
@IsTest
public class SABTestGovernor {
    private static List<String> steps = new List<String>();
    private static Integer mark = 0;
    private static String window = 'outer';

    /** Records queries used since the previous step in the current limits window. */
    public static void step(String label) {
        Integer used = Limits.getQueries();
        steps.add(window + ':' + label + '=' + (used - mark) + ' (window total ' + used + ')');
        mark = used;
    }

    /** Fails with the step report unless at least {@code reserve} queries remain. */
    public static void requireHeadroom(Integer reserve, String nextStep) {
        Integer remaining = Limits.getLimitQueries() - Limits.getQueries();
        System.assert(remaining >= reserve, 'SOQL budget too low before "' + nextStep + '": ' + remaining
            + ' of ' + Limits.getLimitQueries() + ' left, ' + reserve + ' reserved. Steps: ' + report());
    }

    /** Call at the end of @TestSetup: its usage is inherited by every test method's outer window. */
    public static void assertSetupWithin(Integer maxQueries) {
        step('test setup');
        System.assert(Limits.getQueries() <= maxQueries, '@TestSetup used ' + Limits.getQueries() + ' queries; the cap is '
            + maxQueries + ' because every test method inherits this cost. Seed instead of replaying workflows. Steps: ' + report());
    }

    /** Test.startTest() with a checkpoint; the new window starts from zero queries. */
    public static void startTest() {
        step('before startTest');
        Test.startTest();
        window = 'test';
        mark = Limits.getQueries();
    }

    /** Test.stopTest() with a checkpoint; resumes the outer window's counter. */
    public static void stopTest() {
        step('before stopTest');
        Test.stopTest();
        window = 'after';
        mark = Limits.getQueries();
    }

    /** Readable per-step query usage for assertion messages. */
    public static String report() {
        return steps.isEmpty() ? '(no steps recorded)' : String.join(steps, '; ');
    }
}
