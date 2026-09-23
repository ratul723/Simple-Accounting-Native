/**
 * Simple Accounting Books - Journal Validation Service.
 *
 * Validates a persisted Draft Journal_Entry__c before posting.
 *
 * Exact fields used from the current SAB metadata:
 *
 * Journal_Entry__c
 * - Company__c
 * - Accounting_Period__c
 * - Accounting_Date__c
 * - Entry_Type__c
 * - Status__c
 *
 * Journal_Entry_Line__c
 * - Journal_Entry__c
 * - Line_Number__c
 * - GL_Account__c
 * - Debit_Base__c
 * - Credit_Base__c
 * - Functional_Currency__c
 * - Department__c
 * - Cost_Center__c
 * - Project__c
 *
 * GL_Account__c
 * - Company__c
 * - Is_Active__c
 * - Manual_Posting_Allowed__c
 * - Is_Control_Account__c
 * - Control_Type__c
 *
 * Accounting_Period__c
 * - Company__c
 * - Start_Date__c
 * - End_Date__c
 * - Status__c
 *
 * This class validates accounting invariants only. It performs no posting DML.
 * SABPostingService will call this service in the next build step.
 */
public without sharing class SABJournalValidationService {

    public class JournalValidationException extends Exception {}

    @TestVisible
    private static final Integer MAX_JOURNAL_LINES = 200;

    private static final String STATUS_DRAFT = 'Draft';
    private static final String PERIOD_OPEN = 'Open';

    public class ValidationResult {
        public Boolean isValid { get; private set; }
        public List<String> errors { get; private set; }
        public Integer lineCount { get; private set; }
        public Decimal totalDebit { get; private set; }
        public Decimal totalCredit { get; private set; }

        private ValidationResult() {
            errors = new List<String>();
            lineCount = 0;
            totalDebit = 0;
            totalCredit = 0;
            isValid = true;
        }

        private void addError(String message) {
            errors.add(message);
            isValid = false;
        }
    }

    /**
     * Returns every validation error found for a persisted journal.
     * This is useful for a future LWC posting preview.
     */
    public static ValidationResult validateForPosting(
        Id journalEntryId
    ) {
        if (journalEntryId == null) {
            throw new JournalValidationException(
                'Journal Entry Id is required.'
            );
        }

        Journal_Entry__c journal = [
            SELECT Id,
                   Company__c,
                   Company__r.Is_Active__c,
                   Company__r.Functional_Currency__c,
                   Accounting_Period__c,
                   Accounting_Period__r.Company__c,
                   Accounting_Period__r.Start_Date__c,
                   Accounting_Period__r.End_Date__c,
                   Accounting_Period__r.Status__c,
                   Accounting_Date__c,
                   Entry_Type__c,
                   Status__c
            FROM Journal_Entry__c
            WHERE Id = :journalEntryId
            LIMIT 1
        ];

        // Record sharing is intentionally not the only authorization boundary.
        SABCompanyAccessService.assertCompanyAccess(
            journal.Company__c
        );

        List<Journal_Entry_Line__c> lines = [
            SELECT Id,
                   Line_Number__c,
                   GL_Account__c,
                   GL_Account__r.Company__c,
                   GL_Account__r.Is_Active__c,
                   GL_Account__r.Is_Control_Account__c,
                   GL_Account__r.Control_Type__c,
                   GL_Account__r.Manual_Posting_Allowed__c,
                   Debit_Base__c,
                   Credit_Base__c,
                   Functional_Currency__c,
                   Department__c,
                   Department__r.Company__c,
                   Department__r.Is_Active__c,
                   Cost_Center__c,
                   Cost_Center__r.Company__c,
                   Cost_Center__r.Is_Active__c,
                   Project__c,
                   Project__r.Company__c
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__c = :journalEntryId
            ORDER BY Line_Number__c ASC, Id ASC
        ];

        return validateLoadedJournal(journal, lines);
    }

    /**
     * Throws one exception containing all validation errors.
     * SABPostingService should call this before changing Status__c to Posted.
     */
    public static void assertValidForPosting(
        Id journalEntryId
    ) {
        ValidationResult result =
            validateForPosting(journalEntryId);

        if (!result.isValid) {
            throw new JournalValidationException(
                String.join(result.errors, ' | ')
            );
        }
    }

    @TestVisible
    private static ValidationResult validateLoadedJournal(
        Journal_Entry__c journal,
        List<Journal_Entry_Line__c> lines
    ) {
        ValidationResult result = new ValidationResult();

        validateHeader(journal, result);
        validateLines(journal, lines, result);

        result.totalDebit =
            normalizeAmount(result.totalDebit);
        result.totalCredit =
            normalizeAmount(result.totalCredit);

        if (
            result.lineCount >= 2
            && result.totalDebit != result.totalCredit
        ) {
            result.addError(
                'Journal Entry is not balanced. Total Debit is '
                + String.valueOf(result.totalDebit)
                + ' and Total Credit is '
                + String.valueOf(result.totalCredit)
                + '.'
            );
        }

        return result;
    }

    private static void validateHeader(
        Journal_Entry__c journal,
        ValidationResult result
    ) {
        if (journal == null) {
            result.addError(
                'Journal Entry is required.'
            );
            return;
        }

        if (journal.Company__c == null) {
            result.addError(
                'Accounting Company is required.'
            );
        } else if (
            journal.Company__r != null
            && journal.Company__r.Is_Active__c != true
        ) {
            result.addError(
                'Accounting Company must be active.'
            );
        }

        if (journal.Status__c != STATUS_DRAFT) {
            result.addError(
                'Only a Draft Journal Entry can be posted.'
            );
        }

        if (journal.Accounting_Date__c == null) {
            result.addError(
                'Accounting Date is required.'
            );
        }

        if (journal.Accounting_Period__c == null) {
            result.addError(
                'Accounting Period is required.'
            );
            return;
        }

        if (
            journal.Accounting_Period__r.Company__c
            != journal.Company__c
        ) {
            result.addError(
                'Accounting Period must belong to the same Accounting Company as the Journal Entry.'
            );
        }

        if (
            journal.Accounting_Period__r.Status__c
            != PERIOD_OPEN
        ) {
            result.addError(
                'Accounting Period must be Open.'
            );
        }

        if (
            journal.Accounting_Date__c != null
            && (
                journal.Accounting_Date__c
                    < journal.Accounting_Period__r.Start_Date__c
                || journal.Accounting_Date__c
                    > journal.Accounting_Period__r.End_Date__c
            )
        ) {
            result.addError(
                'Accounting Date must fall within the selected Accounting Period.'
            );
        }

        if (
            journal.Company__r != null
            && String.isBlank(
                journal.Company__r.Functional_Currency__c
            )
        ) {
            result.addError(
                'Accounting Company Functional Currency is required.'
            );
        }
    }

    private static void validateLines(
        Journal_Entry__c journal,
        List<Journal_Entry_Line__c> lines,
        ValidationResult result
    ) {
        result.lineCount =
            lines == null ? 0 : lines.size();

        if (result.lineCount < 2) {
            result.addError(
                'A Journal Entry must contain at least 2 lines.'
            );
        }

        if (result.lineCount > MAX_JOURNAL_LINES) {
            result.addError(
                'A Journal Entry cannot contain more than '
                + MAX_JOURNAL_LINES
                + ' lines.'
            );
        }

        if (lines == null || lines.isEmpty()) {
            return;
        }

        Set<Decimal> usedLineNumbers =
            new Set<Decimal>();

        Boolean manualLikeEntry =
            journal.Entry_Type__c == 'Manual'
            || journal.Entry_Type__c == 'Opening';

        Boolean reversalEntry =
            journal.Entry_Type__c == 'Reversal';

        for (Journal_Entry_Line__c line : lines) {
            String lineLabel =
                line.Line_Number__c == null
                    ? 'Journal line'
                    : 'Journal line '
                        + String.valueOf(
                            line.Line_Number__c
                        );

            if (
                line.Line_Number__c == null
                || line.Line_Number__c <= 0
            ) {
                result.addError(
                    lineLabel
                    + ': Line Number must be greater than zero.'
                );
            } else if (
                usedLineNumbers.contains(
                    line.Line_Number__c
                )
            ) {
                result.addError(
                    lineLabel
                    + ': Line Number must be unique within the Journal Entry.'
                );
            } else {
                usedLineNumbers.add(
                    line.Line_Number__c
                );
            }

            Decimal debit =
                normalizeAmount(line.Debit_Base__c);

            Decimal credit =
                normalizeAmount(line.Credit_Base__c);

            if (debit < 0 || credit < 0) {
                result.addError(
                    lineLabel
                    + ': Debit and Credit cannot be negative.'
                );
            }

            Boolean hasDebit = debit > 0;
            Boolean hasCredit = credit > 0;

            if (hasDebit == hasCredit) {
                result.addError(
                    lineLabel
                    + ': exactly one of Debit Base or Credit Base must be greater than zero.'
                );
            }

            result.totalDebit += debit;
            result.totalCredit += credit;

            if (line.GL_Account__c == null) {
                result.addError(
                    lineLabel
                    + ': GL Account is required.'
                );
            } else {
                if (
                    line.GL_Account__r.Company__c
                    != journal.Company__c
                ) {
                    result.addError(
                        lineLabel
                        + ': GL Account must belong to the same Accounting Company as the Journal Entry.'
                    );
                }

                if (
                    !reversalEntry
                    && line.GL_Account__r.Is_Active__c
                        != true
                ) {
                    result.addError(
                        lineLabel
                        + ': GL Account must be active.'
                    );
                }

                if (
                    manualLikeEntry
                    && line.GL_Account__r.Manual_Posting_Allowed__c
                        != true
                ) {
                    result.addError(
                        lineLabel
                        + ': the selected GL Account does not allow manual/opening posting.'
                    );
                }
            }

            String companyCurrency =
                journal.Company__r == null
                    ? null
                    : journal.Company__r.Functional_Currency__c;

            if (
                !String.isBlank(companyCurrency)
                && line.Functional_Currency__c
                    != companyCurrency
            ) {
                result.addError(
                    lineLabel
                    + ': Functional Currency must match the Accounting Company functional currency.'
                );
            }

            if (line.Department__c != null) {
                if (
                    line.Department__r.Company__c
                    != journal.Company__c
                ) {
                    result.addError(
                        lineLabel
                        + ': Department must belong to the same Accounting Company.'
                    );
                }

                if (
                    !reversalEntry
                    && line.Department__r.Is_Active__c
                        != true
                ) {
                    result.addError(
                        lineLabel
                        + ': Department must be active.'
                    );
                }
            }

            if (line.Cost_Center__c != null) {
                if (
                    line.Cost_Center__r.Company__c
                    != journal.Company__c
                ) {
                    result.addError(
                        lineLabel
                        + ': Cost Center must belong to the same Accounting Company.'
                    );
                }

                if (
                    !reversalEntry
                    && line.Cost_Center__r.Is_Active__c
                        != true
                ) {
                    result.addError(
                        lineLabel
                        + ': Cost Center must be active.'
                    );
                }
            }

            if (
                line.Project__c != null
                && line.Project__r.Company__c
                    != journal.Company__c
            ) {
                result.addError(
                    lineLabel
                    + ': Project must belong to the same Accounting Company.'
                );
            }
        }
    }

    private static Decimal normalizeAmount(
        Decimal value
    ) {
        Decimal safeValue =
            value == null ? 0 : value;

        return safeValue.setScale(4);
    }
}
