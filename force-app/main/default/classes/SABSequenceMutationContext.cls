/**
 * Narrow context used only while SABSequenceService increments the controlled
 * Document_Sequence__c.Next_Number__c counter.
 */
public class SABSequenceMutationContext {

    private static Integer reservationDepth = 0;

    public static void beginReservation() {
        reservationDepth++;
    }

    public static void endReservation() {
        if (reservationDepth > 0) {
            reservationDepth--;
        }
    }

    public static Boolean isReservation() {
        return reservationDepth > 0;
    }

    @TestVisible
    private static void resetForTest() {
        reservationDepth = 0;
    }
}
