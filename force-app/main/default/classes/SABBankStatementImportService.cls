/**
 * G5A - Bank Statement Import Foundation.
 *
 * Imports a bank statement and raw bank statement lines without creating any
 * accounting journal. Reconciliation/matching belongs to G5B/G5C.
 *
 * Design rules:
 * - Bank Statement is company-scoped.
 * - Bank Account must be active and belong to the same company.
 * - Statement currency must match the Bank Account currency.
 * - Import fingerprint provides statement-level idempotency.
 * - Line fingerprints prevent duplicate rows inside one import request.
 * - Signed line convention: positive = money into the bank, negative = money out.
 * - Opening + sum(lines) must equal Closing before a statement may be Validated.
 * - Re-importing the same compatible fingerprint returns the existing statement.
 */
public with sharing class SABBankStatementImportService {

    public class BankStatementImportException extends Exception {}

    private static final String IMPORT_PERMISSION =
        'SAB_Import_Bank_Statement';

    private static final String STATUS_IMPORTED =
        'Imported';

    private static final String STATUS_VALIDATED =
        'Validated';

    private static final String STATUS_RECONCILED =
        'Reconciled';

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    public class LineRequest {
        @AuraEnabled public Decimal lineNumber { get; set; }
        @AuraEnabled public Date transactionDate { get; set; }
        @AuraEnabled public Date valueDate { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String providerLineId { get; set; }
        @AuraEnabled public String reference { get; set; }
        @AuraEnabled public String sourceRawText { get; set; }
        @AuraEnabled public String lineFingerprint { get; set; }
    }

    public class ImportRequest {
        @AuraEnabled public Id bankAccountId { get; set; }
        @AuraEnabled public Date statementStartDate { get; set; }
        @AuraEnabled public Date statementEndDate { get; set; }
        @AuraEnabled public Decimal openingAmount { get; set; }
        @AuraEnabled public Decimal closingAmount { get; set; }
        @AuraEnabled public String transactionCurrency { get; set; }
        @AuraEnabled public String importFingerprint { get; set; }
        @AuraEnabled public List<LineRequest> lines { get; set; }
    }

    public class ImportResult {
        @AuraEnabled public Id bankStatementId { get; private set; }
        @AuraEnabled public String bankStatementName { get; private set; }
        @AuraEnabled public String status { get; private set; }
        @AuraEnabled public Integer lineCount { get; private set; }
        @AuraEnabled public Decimal openingAmount { get; private set; }
        @AuraEnabled public Decimal lineNetAmount { get; private set; }
        @AuraEnabled public Decimal calculatedClosingAmount { get; private set; }
        @AuraEnabled public Decimal statementClosingAmount { get; private set; }
        @AuraEnabled public Boolean balanced { get; private set; }
        @AuraEnabled public Boolean replay { get; private set; }
        @AuraEnabled public String importFingerprint { get; private set; }
    }

    @AuraEnabled
    public static ImportResult importStatement(
        ImportRequest request
    ) {
        SABPermissionService.assertPermission(
            IMPORT_PERMISSION,
            'You do not have permission to import Bank Statements.'
        );

        validateRequestShape(request);
        assertImportAccess();

        Bank_Account__c bankAccount = [
            SELECT Id,
                   Company__c,
                   Currency__c,
                   GL_Account__c,
                   GL_Account__r.Company__c,
                   Is_Active__c
            FROM Bank_Account__c
            WHERE Id = :request.bankAccountId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(
            bankAccount.Company__c
        );

        SABAccessControlService.assertRecordReadAccess(
            bankAccount.Id
        );

        validateBankAccount(
            bankAccount,
            request.transactionCurrency
        );

        String normalizedCurrency =
            SABMoneyService.normalizeCurrencyCode(
                request.transactionCurrency
            );

        List<NormalizedLine> normalizedLines =
            normalizeLines(
                request.lines,
                request.statementStartDate,
                request.statementEndDate
            );

        String fingerprint =
            String.isBlank(request.importFingerprint)
                ? buildImportFingerprint(
                    request,
                    normalizedCurrency,
                    normalizedLines
                )
                : request.importFingerprint.trim();

        assertTextLength(
            fingerprint,
            Bank_Statement__c.Import_Fingerprint__c,
            'Import Fingerprint'
        );

        List<Bank_Statement__c> existingRows = [
            SELECT Id,
                   Name,
                   Company__c,
                   Bank_Account__c,
                   Statement_Start_Date__c,
                   Statement_End_Date__c,
                   Opening_Amount__c,
                   Closing_Amount__c,
                   Currency__c,
                   Import_Fingerprint__c,
                   Status__c
            FROM Bank_Statement__c
            WHERE Import_Fingerprint__c = :fingerprint
            LIMIT 1
        ];

        if (!existingRows.isEmpty()) {
            Bank_Statement__c existing =
                existingRows[0];

            assertReplayCompatible(
                existing,
                bankAccount.Company__c,
                request,
                normalizedCurrency
            );

            return buildResult(
                existing,
                true
            );
        }

        Bank_Statement__c statement =
            new Bank_Statement__c(
                Company__c =
                    bankAccount.Company__c,
                Bank_Account__c =
                    bankAccount.Id,
                Statement_Start_Date__c =
                    request.statementStartDate,
                Statement_End_Date__c =
                    request.statementEndDate,
                Opening_Amount__c =
                    normalizeAmount(
                        request.openingAmount
                    ),
                Closing_Amount__c =
                    normalizeAmount(
                        request.closingAmount
                    ),
                Currency__c =
                    normalizedCurrency,
                Import_Fingerprint__c =
                    fingerprint,
                Status__c =
                    STATUS_IMPORTED
            );

        insert statement;

        List<Bank_Statement_Line__c> lines =
            new List<Bank_Statement_Line__c>();

        for (NormalizedLine normalized : normalizedLines) {
            lines.add(
                new Bank_Statement_Line__c(
                    Bank_Statement__c =
                        statement.Id,
                    Line_Number__c =
                        normalized.lineNumber,
                    Transaction_Date__c =
                        normalized.transactionDate,
                    Value_Date__c =
                        normalized.valueDate,
                    Amount__c =
                        normalized.amount,
                    Provider_Line_Id__c =
                        normalized.providerLineId,
                    Reference__c =
                        normalized.reference,
                    Source_Raw_Text__c =
                        normalized.sourceRawText,
                    Line_Fingerprint__c =
                        normalized.lineFingerprint
                )
            );
        }

        insert lines;

        return buildResult(
            statement,
            false
        );
    }

    @AuraEnabled
    public static ImportResult validateStatement(
        Id bankStatementId
    ) {
        SABPermissionService.assertPermission(
            IMPORT_PERMISSION,
            'You do not have permission to validate Bank Statements.'
        );

        if (bankStatementId == null) {
            throw new BankStatementImportException(
                'Bank Statement Id is required.'
            );
        }

        assertValidationAccess();

        Bank_Statement__c statement = [
            SELECT Id,
                   Name,
                   Company__c,
                   Bank_Account__c,
                   Bank_Account__r.Company__c,
                   Bank_Account__r.Currency__c,
                   Bank_Account__r.GL_Account__c,
                   Bank_Account__r.GL_Account__r.Company__c,
                   Bank_Account__r.Is_Active__c,
                   Statement_Start_Date__c,
                   Statement_End_Date__c,
                   Opening_Amount__c,
                   Closing_Amount__c,
                   Currency__c,
                   Import_Fingerprint__c,
                   Status__c
            FROM Bank_Statement__c
            WHERE Id = :bankStatementId
            LIMIT 1
            FOR UPDATE
        ];

        SABCompanyAccessService.assertCompanyAccess(
            statement.Company__c
        );

        SABAccessControlService.assertRecordEditAccess(
            statement.Id
        );

        if (statement.Status__c == STATUS_RECONCILED) {
            throw new BankStatementImportException(
                'A Reconciled Bank Statement cannot be revalidated.'
            );
        }

        if (
            statement.Bank_Account__r == null
            || statement.Bank_Account__r.Company__c
                != statement.Company__c
        ) {
            throw new BankStatementImportException(
                'Bank Statement and Bank Account must belong to the same Accounting Company.'
            );
        }

        validateBankAccount(
            statement.Bank_Account__r,
            statement.Currency__c
        );

        validateStatementDates(
            statement.Statement_Start_Date__c,
            statement.Statement_End_Date__c
        );

        List<Bank_Statement_Line__c> lines = [
            SELECT Id,
                   Line_Number__c,
                   Transaction_Date__c,
                   Value_Date__c,
                   Amount__c,
                   Line_Fingerprint__c
            FROM Bank_Statement_Line__c
            WHERE Bank_Statement__c = :statement.Id
            ORDER BY Line_Number__c ASC,
                     CreatedDate ASC
        ];

        if (lines.isEmpty()) {
            throw new BankStatementImportException(
                'Bank Statement must contain at least one line before validation.'
            );
        }

        Set<Decimal> lineNumbers =
            new Set<Decimal>();
        Set<String> fingerprints =
            new Set<String>();
        Decimal netAmount =
            ZERO;

        for (Bank_Statement_Line__c line : lines) {
            if (
                line.Line_Number__c == null
                || line.Line_Number__c <= 0
                || lineNumbers.contains(
                    line.Line_Number__c
                )
            ) {
                throw new BankStatementImportException(
                    'Bank Statement line numbers must be positive and unique.'
                );
            }

            lineNumbers.add(
                line.Line_Number__c
            );

            if (
                String.isBlank(
                    line.Line_Fingerprint__c
                )
                || fingerprints.contains(
                    line.Line_Fingerprint__c
                )
            ) {
                throw new BankStatementImportException(
                    'Bank Statement line fingerprints must be populated and unique within the statement.'
                );
            }

            fingerprints.add(
                line.Line_Fingerprint__c
            );

            if (
                line.Transaction_Date__c
                    < statement.Statement_Start_Date__c
                || line.Transaction_Date__c
                    > statement.Statement_End_Date__c
            ) {
                throw new BankStatementImportException(
                    'Every Bank Statement transaction date must fall inside the statement date range.'
                );
            }

            netAmount +=
                line.Amount__c == null
                    ? ZERO
                    : line.Amount__c;
        }

        Decimal calculatedClosing =
            normalizeAmount(
                statement.Opening_Amount__c
                + netAmount
            );

        Decimal statedClosing =
            normalizeAmount(
                statement.Closing_Amount__c
            );

        if (calculatedClosing != statedClosing) {
            throw new BankStatementImportException(
                'Bank Statement does not balance: Opening Amount plus signed statement lines must equal Closing Amount.'
            );
        }

        statement.Status__c =
            STATUS_VALIDATED;

        update statement;

        return buildResult(
            statement,
            false
        );
    }

    @AuraEnabled(cacheable=true)
    public static ImportResult getStatementSummary(
        Id bankStatementId
    ) {
        if (bankStatementId == null) {
            throw new BankStatementImportException(
                'Bank Statement Id is required.'
            );
        }

        assertSummaryReadAccess();

        Bank_Statement__c statement = [
            SELECT Id,
                   Name,
                   Company__c,
                   Opening_Amount__c,
                   Closing_Amount__c,
                   Import_Fingerprint__c,
                   Status__c
            FROM Bank_Statement__c
            WHERE Id = :bankStatementId
            LIMIT 1
        ];

        SABCompanyAccessService.assertCompanyAccess(
            statement.Company__c
        );

        SABAccessControlService.assertRecordReadAccess(
            statement.Id
        );

        return buildResult(
            statement,
            false
        );
    }

    private static List<NormalizedLine> normalizeLines(
        List<LineRequest> requests,
        Date statementStart,
        Date statementEnd
    ) {
        if (
            requests == null
            || requests.isEmpty()
        ) {
            throw new BankStatementImportException(
                'At least one Bank Statement line is required.'
            );
        }

        Set<Decimal> lineNumbers =
            new Set<Decimal>();
        Set<String> fingerprints =
            new Set<String>();

        List<NormalizedLine> result =
            new List<NormalizedLine>();

        for (LineRequest request : requests) {
            if (request == null) {
                throw new BankStatementImportException(
                    'Bank Statement contains an invalid line.'
                );
            }

            if (
                request.lineNumber == null
                || request.lineNumber <= 0
                || request.lineNumber.scale() != 0
            ) {
                throw new BankStatementImportException(
                    'Each Bank Statement line requires a positive whole-number Line Number.'
                );
            }

            if (
                lineNumbers.contains(
                    request.lineNumber
                )
            ) {
                throw new BankStatementImportException(
                    'Duplicate Bank Statement line numbers are not allowed.'
                );
            }

            lineNumbers.add(
                request.lineNumber
            );

            if (request.transactionDate == null) {
                throw new BankStatementImportException(
                    'Transaction Date is required on every Bank Statement line.'
                );
            }

            if (
                request.transactionDate < statementStart
                || request.transactionDate > statementEnd
            ) {
                throw new BankStatementImportException(
                    'Every Bank Statement transaction date must fall inside the statement date range.'
                );
            }

            if (request.amount == null) {
                throw new BankStatementImportException(
                    'Amount is required on every Bank Statement line.'
                );
            }

            NormalizedLine normalized =
                new NormalizedLine();

            normalized.lineNumber =
                request.lineNumber;
            normalized.transactionDate =
                request.transactionDate;
            normalized.valueDate =
                request.valueDate;
            normalized.amount =
                normalizeAmount(
                    request.amount
                );
            normalized.providerLineId =
                trimToFieldLength(
                    request.providerLineId,
                    Bank_Statement_Line__c.Provider_Line_Id__c
                );
            normalized.reference =
                trimToFieldLength(
                    request.reference,
                    Bank_Statement_Line__c.Reference__c
                );
            normalized.sourceRawText =
                trimToFieldLength(
                    request.sourceRawText,
                    Bank_Statement_Line__c.Source_Raw_Text__c
                );

            normalized.lineFingerprint =
                String.isBlank(
                    request.lineFingerprint
                )
                    ? buildLineFingerprint(
                        normalized
                    )
                    : request.lineFingerprint.trim();

            assertTextLength(
                normalized.lineFingerprint,
                Bank_Statement_Line__c.Line_Fingerprint__c,
                'Line Fingerprint'
            );

            if (
                fingerprints.contains(
                    normalized.lineFingerprint
                )
            ) {
                throw new BankStatementImportException(
                    'Duplicate Bank Statement line fingerprints are not allowed.'
                );
            }

            fingerprints.add(
                normalized.lineFingerprint
            );

            result.add(
                normalized
            );
        }

        result.sort(
            new NormalizedLineComparator()
        );

        return result;
    }

    private static String buildImportFingerprint(
        ImportRequest request,
        String normalizedCurrency,
        List<NormalizedLine> lines
    ) {
        List<String> parts =
            new List<String>{
                String.valueOf(
                    request.bankAccountId
                ),
                String.valueOf(
                    request.statementStartDate
                ),
                String.valueOf(
                    request.statementEndDate
                ),
                String.valueOf(
                    normalizeAmount(
                        request.openingAmount
                    )
                ),
                String.valueOf(
                    normalizeAmount(
                        request.closingAmount
                    )
                ),
                normalizedCurrency
            };

        for (NormalizedLine line : lines) {
            parts.add(
                line.lineFingerprint
            );
        }

        return sha256(
            String.join(
                parts,
                '|'
            )
        );
    }

    private static String buildLineFingerprint(
        NormalizedLine line
    ) {
        return sha256(
            String.join(
                new List<String>{
                    String.valueOf(
                        line.lineNumber
                    ),
                    String.valueOf(
                        line.transactionDate
                    ),
                    String.valueOf(
                        line.valueDate
                    ),
                    String.valueOf(
                        line.amount
                    ),
                    line.providerLineId == null
                        ? ''
                        : line.providerLineId,
                    line.reference == null
                        ? ''
                        : line.reference,
                    line.sourceRawText == null
                        ? ''
                        : line.sourceRawText
                },
                '|'
            )
        );
    }

    private static String sha256(
        String value
    ) {
        return EncodingUtil.convertToHex(
            Crypto.generateDigest(
                'SHA-256',
                Blob.valueOf(
                    value == null
                        ? ''
                        : value
                )
            )
        );
    }

    private static void validateRequestShape(
        ImportRequest request
    ) {
        if (request == null) {
            throw new BankStatementImportException(
                'Bank Statement import request is required.'
            );
        }

        if (request.bankAccountId == null) {
            throw new BankStatementImportException(
                'Bank Account is required.'
            );
        }

        validateStatementDates(
            request.statementStartDate,
            request.statementEndDate
        );

        if (request.openingAmount == null) {
            throw new BankStatementImportException(
                'Opening Amount is required.'
            );
        }

        if (request.closingAmount == null) {
            throw new BankStatementImportException(
                'Closing Amount is required.'
            );
        }

        SABMoneyService.normalizeCurrencyCode(
            request.transactionCurrency
        );
    }

    private static void validateStatementDates(
        Date startDate,
        Date endDate
    ) {
        if (startDate == null) {
            throw new BankStatementImportException(
                'Statement Start Date is required.'
            );
        }

        if (endDate == null) {
            throw new BankStatementImportException(
                'Statement End Date is required.'
            );
        }

        if (startDate > endDate) {
            throw new BankStatementImportException(
                'Statement Start Date cannot be after Statement End Date.'
            );
        }
    }

    private static void validateBankAccount(
        Bank_Account__c bankAccount,
        String requestedCurrency
    ) {
        if (bankAccount == null) {
            throw new BankStatementImportException(
                'Bank Account was not found.'
            );
        }

        if (bankAccount.Is_Active__c != true) {
            throw new BankStatementImportException(
                'Bank Account must be active before importing a statement.'
            );
        }

        if (
            bankAccount.GL_Account__c == null
            || bankAccount.GL_Account__r == null
            || bankAccount.GL_Account__r.Company__c
                != bankAccount.Company__c
        ) {
            throw new BankStatementImportException(
                'Bank Account GL Account must belong to the same Accounting Company.'
            );
        }

        String bankCurrency =
            SABMoneyService.normalizeCurrencyCode(
                bankAccount.Currency__c
            );

        String statementCurrency =
            SABMoneyService.normalizeCurrencyCode(
                requestedCurrency
            );

        if (
            bankCurrency
            != statementCurrency
        ) {
            throw new BankStatementImportException(
                'Bank Statement currency must match the Bank Account currency.'
            );
        }
    }

    private static void assertReplayCompatible(
        Bank_Statement__c existing,
        Id companyId,
        ImportRequest request,
        String normalizedCurrency
    ) {
        Boolean compatible =
            existing.Company__c == companyId
            && existing.Bank_Account__c
                == request.bankAccountId
            && existing.Statement_Start_Date__c
                == request.statementStartDate
            && existing.Statement_End_Date__c
                == request.statementEndDate
            && normalizeAmount(
                existing.Opening_Amount__c
            )
                == normalizeAmount(
                    request.openingAmount
                )
            && normalizeAmount(
                existing.Closing_Amount__c
            )
                == normalizeAmount(
                    request.closingAmount
                )
            && SABMoneyService.normalizeCurrencyCode(
                existing.Currency__c
            )
                == normalizedCurrency;

        if (!compatible) {
            throw new BankStatementImportException(
                'Import Fingerprint already exists for a different Bank Statement identity.'
            );
        }
    }

    private static ImportResult buildResult(
        Bank_Statement__c statement,
        Boolean replay
    ) {
        AggregateResult aggregateRow = [
            SELECT COUNT(Id) lineCount,
                   SUM(Amount__c) netAmount
            FROM Bank_Statement_Line__c
            WHERE Bank_Statement__c =
                :statement.Id
        ];

        Integer lineCount =
            Integer.valueOf(
                String.valueOf(
                    aggregateRow.get(
                        'lineCount'
                    )
                )
            );

        Decimal netAmount =
            (Decimal) aggregateRow.get(
                'netAmount'
            );

        if (netAmount == null) {
            netAmount = ZERO;
        }

        Decimal openingAmount =
            normalizeAmount(
                statement.Opening_Amount__c
            );

        Decimal closingAmount =
            normalizeAmount(
                statement.Closing_Amount__c
            );

        Decimal calculatedClosing =
            normalizeAmount(
                openingAmount
                + netAmount
            );

        ImportResult result =
            new ImportResult();

        result.bankStatementId =
            statement.Id;
        result.bankStatementName =
            statement.Name;
        result.status =
            statement.Status__c;
        result.lineCount =
            lineCount;
        result.openingAmount =
            openingAmount;
        result.lineNetAmount =
            normalizeAmount(
                netAmount
            );
        result.calculatedClosingAmount =
            calculatedClosing;
        result.statementClosingAmount =
            closingAmount;
        result.balanced =
            calculatedClosing
                == closingAmount;
        result.replay =
            replay;
        result.importFingerprint =
            statement.Import_Fingerprint__c;

        return result;
    }

    private static Decimal normalizeAmount(
        Decimal value
    ) {
        if (value == null) {
            return ZERO;
        }

        return value.setScale(
            4,
            RoundingMode.HALF_UP
        );
    }

    private static void assertTextLength(
        String value,
        Schema.SObjectField fieldToken,
        String fieldLabel
    ) {
        if (value == null) {
            return;
        }

        Integer maxLength =
            fieldToken.getDescribe()
                .getLength();

        if (
            maxLength > 0
            && value.length() > maxLength
        ) {
            throw new BankStatementImportException(
                fieldLabel
                + ' cannot exceed '
                + maxLength
                + ' characters.'
            );
        }
    }

    private static String trimToFieldLength(
        String value,
        Schema.SObjectField fieldToken
    ) {
        if (String.isBlank(value)) {
            return null;
        }

        String trimmed =
            value.trim();

        Integer maxLength =
            fieldToken.getDescribe()
                .getLength();

        if (
            maxLength > 0
            && trimmed.length() > maxLength
        ) {
            return trimmed.substring(
                0,
                maxLength
            );
        }

        return trimmed;
    }

    private static void assertImportAccess() {
        SABAccessControlService.assertReadable(
            Bank_Account__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Account__c.Company__c,
                Bank_Account__c.Currency__c,
                Bank_Account__c.GL_Account__c,
                Bank_Account__c.Is_Active__c
            }
        );

        SABAccessControlService.assertCreateable(
            Bank_Statement__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Statement__c.Status__c
            }
        );

        SABAccessControlService.assertCreateable(
            Bank_Statement_Line__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Statement_Line__c.Provider_Line_Id__c,
                Bank_Statement_Line__c.Reference__c,
                Bank_Statement_Line__c.Source_Raw_Text__c,
                Bank_Statement_Line__c.Value_Date__c
            }
        );
    }

    private static void assertValidationAccess() {
        assertSummaryReadAccess();

        SABAccessControlService.assertUpdateable(
            Bank_Statement__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Statement__c.Status__c
            }
        );
    }

    private static void assertSummaryReadAccess() {
        SABAccessControlService.assertReadable(
            Bank_Statement__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Statement__c.Status__c
            }
        );

        SABAccessControlService.assertReadable(
            Bank_Statement_Line__c.SObjectType,
            new List<Schema.SObjectField>{
                Bank_Statement_Line__c.Provider_Line_Id__c,
                Bank_Statement_Line__c.Reference__c,
                Bank_Statement_Line__c.Value_Date__c
            }
        );
    }

    private class NormalizedLine {
        Decimal lineNumber;
        Date transactionDate;
        Date valueDate;
        Decimal amount;
        String providerLineId;
        String reference;
        String sourceRawText;
        String lineFingerprint;
    }

    private class NormalizedLineComparator
        implements Comparator<NormalizedLine>
    {
        public Integer compare(
            NormalizedLine leftValue,
            NormalizedLine rightValue
        ) {
            if (
                leftValue.lineNumber
                == rightValue.lineNumber
            ) {
                return 0;
            }

            return leftValue.lineNumber
                < rightValue.lineNumber
                    ? -1
                    : 1;
        }
    }
}
