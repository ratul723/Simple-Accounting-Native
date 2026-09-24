public class SABAccountingConfigurationMutationContext {

    private static Integer periodTransitionDepth = 0;

    public static void beginPeriodTransition() {
        periodTransitionDepth++;
    }

    public static void endPeriodTransition() {
        if (periodTransitionDepth > 0) {
            periodTransitionDepth--;
        }
    }

    public static Boolean isPeriodTransition() {
        return periodTransitionDepth > 0;
    }

    @TestVisible
    private static void resetForTest() {
        periodTransitionDepth = 0;
    }
}
