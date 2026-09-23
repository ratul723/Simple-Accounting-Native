/**
 * Narrow in-transaction mutation context for protected ledger transitions.
 *
 * Public is package-namespace scoped in a managed package. It is intentionally
 * not global.
 */
public class SABLedgerMutationContext {

    private static Integer postingDepth = 0;
    private static Integer reversalDepth = 0;

    public static void beginPosting() {
        postingDepth++;
    }

    public static void endPosting() {
        if (postingDepth > 0) {
            postingDepth--;
        }
    }

    public static Boolean isPosting() {
        return postingDepth > 0;
    }

    public static void beginReversal() {
        reversalDepth++;
    }

    public static void endReversal() {
        if (reversalDepth > 0) {
            reversalDepth--;
        }
    }

    public static Boolean isReversal() {
        return reversalDepth > 0;
    }

    @TestVisible
    private static void resetForTest() {
        postingDepth = 0;
        reversalDepth = 0;
    }
}
