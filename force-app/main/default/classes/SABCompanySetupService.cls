/**
 * Simple Accounting Books - Company Setup Readiness Service.
 *
 * This is the server-side setup contract for the currently deployed core
 * metadata. It validates what the current schema can actually prove.
 *
 * It does NOT invent missing localization/opening-balance metadata. The global
 * plan says the future setup wizard must also validate localization support and
 * opening balances before enabling posting. Those checks belong here when the
 * corresponding authoritative configuration/source objects are implemented.
 */
public without sharing class SABCompanySetupService {

    public class SetupException extends Exception {}

    public class SetupResult {
        public Id companyId { get; private set; }
        public Boolean readyForCoreAccounting { get; private set; }
        public List<String> errors { get; private set; }
        public List<String> warnings { get; private set; }
        public Integer periodCount { get; private set; }
        public Integer openPeriodCount { get; private set; }
        public Integer activeGLAccountCount { get; private set; }
        public Integer activeSequenceCount { get; private set; }
        public Integer enabledFeatureCount { get; private set; }

        private SetupResult(Id targetCompanyId) {
            companyId = targetCompanyId;
            readyForCoreAccounting = true;
            errors = new List<String>();
            warnings = new List<String>();
            periodCount = 0;
            openPeriodCount = 0;
            activeGLAccountCount = 0;
            activeSequenceCount = 0;
            enabledFeatureCount = 0;
        }

        private void addError(String message) {
            readyForCoreAccounting = false;
            errors.add(message);
        }

        private void addWarning(String message) {
            warnings.add(message);
        }
    }

    public static SetupResult validateCoreSetup(
        Id companyId
    ) {
        if (companyId == null) {
            throw new SetupException(
                'Accounting Company Id is required.'
            );
        }

        SABCompanyAccessService.assertCompanyAccess(
            companyId
        );

        Accounting_Company__c company = [
            SELECT Id,
                   Company_Key__c,
                   Country_Code__c,
                   Functional_Currency__c,
                   Fiscal_Calendar_Type__c,
                   Fiscal_Year_Start_Month__c,
                   Default_Rounding_Account__c,
                   Setup_Status__c,
                   Is_Active__c,
                   Created_Setup_Version__c,
                   Country_Pack_Version__c
            FROM Accounting_Company__c
            WHERE Id = :companyId
            LIMIT 1
        ];

        SetupResult result =
            new SetupResult(companyId);

        validateCompany(company, result);
        validatePeriods(companyId, result);
        validateChartOfAccounts(companyId, result);
        validateDocumentSequences(companyId, result);
        validateEnabledFeatures(companyId, result);

        return result;
    }

    private static void validateCompany(
        Accounting_Company__c company,
        SetupResult result
    ) {
        if (company.Is_Active__c != true) {
            result.addError(
                'Accounting Company must be active.'
            );
        }

        if (company.Setup_Status__c == 'Suspended') {
            result.addError(
                'Accounting Company setup is suspended.'
            );
        }

        try {
            String normalizedCurrency =
                SABMoneyService.normalizeCurrencyCode(
                    company.Functional_Currency__c
                );

            if (
                company.Functional_Currency__c
                    != normalizedCurrency
            ) {
                result.addError(
                    'Functional Currency must be stored as an uppercase 3-letter code.'
                );
            }
        } catch (
            SABMoneyService.MoneyException ex
        ) {
            result.addError(
                'Functional Currency is invalid.'
            );
        }

        if (
            company.Fiscal_Year_Start_Month__c == null
            || company.Fiscal_Year_Start_Month__c < 1
            || company.Fiscal_Year_Start_Month__c > 12
        ) {
            result.addError(
                'Fiscal Year Start Month must be between 1 and 12.'
            );
        }

        if (company.Default_Rounding_Account__c != null) {
            try {
                SABMoneyService.assertRoundingAccountBelongsToCompany(
                    company
                );
            } catch (
                SABMoneyService.MoneyException ex
            ) {
                result.addError(
                    ex.getMessage()
                );
            }
        }

        if (
            company.Setup_Status__c == 'Not Started'
            || company.Setup_Status__c == 'In Progress'
        ) {
            result.addWarning(
                'Setup Status has not yet been marked Validated or Active.'
            );
        }

        if (String.isBlank(company.Created_Setup_Version__c)) {
            result.addWarning(
                'Created Setup Version has not been recorded.'
            );
        }
    }

    private static void validatePeriods(
        Id companyId,
        SetupResult result
    ) {
        List<Accounting_Period__c> periods = [
            SELECT Id,
                   Start_Date__c,
                   End_Date__c,
                   Status__c,
                   Fiscal_Year__c,
                   Fiscal_Quarter__c,
                   Period_Number__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId
            ORDER BY Start_Date__c ASC,
                     End_Date__c ASC
        ];

        result.periodCount =
            periods.size();

        if (periods.isEmpty()) {
            result.addError(
                'At least one Accounting Period is required.'
            );
            return;
        }

        Date previousEndDate;

        for (Accounting_Period__c period : periods) {
            if (period.Status__c == 'Open') {
                result.openPeriodCount++;
            }

            if (
                previousEndDate != null
                && period.Start_Date__c
                    <= previousEndDate
            ) {
                result.addError(
                    'Accounting Period dates overlap.'
                );
            }

            previousEndDate =
                period.End_Date__c;
        }

        if (result.openPeriodCount == 0) {
            result.addError(
                'At least one open Accounting Period is required for posting.'
            );
        }
    }

    private static void validateChartOfAccounts(
        Id companyId,
        SetupResult result
    ) {
        List<GL_Account__c> accounts = [
            SELECT Id,
                   Is_Active__c,
                   Is_Control_Account__c,
                   Control_Type__c,
                   Manual_Posting_Allowed__c
            FROM GL_Account__c
            WHERE Company__c = :companyId
        ];

        for (GL_Account__c account : accounts) {
            if (account.Is_Active__c == true) {
                result.activeGLAccountCount++;
            }

            if (
                account.Is_Control_Account__c == true
                && (
                    String.isBlank(account.Control_Type__c)
                    || account.Control_Type__c == 'None'
                )
            ) {
                result.addError(
                    'A control GL Account must have a non-None Control Type.'
                );
            }

            if (
                account.Is_Control_Account__c == true
                && account.Manual_Posting_Allowed__c == true
            ) {
                result.addError(
                    'A control GL Account cannot allow manual posting.'
                );
            }
        }

        if (result.activeGLAccountCount == 0) {
            result.addError(
                'At least one active GL Account is required.'
            );
        }
    }

    private static void validateDocumentSequences(
        Id companyId,
        SetupResult result
    ) {
        List<Document_Sequence__c> sequences = [
            SELECT Id,
                   Company__c,
                   Document_Type__c,
                   Fiscal_Series__c,
                   Prefix__c,
                   Minimum_Digits__c,
                   Next_Number__c,
                   Sequence_Key__c,
                   Is_Active__c
            FROM Document_Sequence__c
            WHERE Company__c = :companyId
        ];

        Set<String> activeScopes =
            new Set<String>();

        for (Document_Sequence__c sequenceRecord : sequences) {
            if (sequenceRecord.Is_Active__c != true) {
                continue;
            }

            result.activeSequenceCount++;

            try {
                SABSequenceService.validateSequence(
                    sequenceRecord
                );
            } catch (
                SABSequenceService.SequenceException ex
            ) {
                result.addError(
                    ex.getMessage()
                );
            }

            String scopeKey =
                sequenceRecord.Document_Type__c
                + '|'
                + sequenceRecord.Fiscal_Series__c;

            if (activeScopes.contains(scopeKey)) {
                result.addError(
                    'Only one active Document Sequence is allowed for each document type and fiscal series.'
                );
            } else {
                activeScopes.add(scopeKey);
            }
        }

        if (result.activeSequenceCount == 0) {
            result.addWarning(
                'No active Document Sequence is configured. Manual ledger use can continue, but numbered business documents cannot be issued through the controlled sequence service.'
            );
        }
    }

    private static void validateEnabledFeatures(
        Id companyId,
        SetupResult result
    ) {
        List<Company_Feature__c> features = [
            SELECT Id,
                   Feature_Key__c,
                   Enabled__c,
                   Configuration_Status__c
            FROM Company_Feature__c
            WHERE Company__c = :companyId
              AND Enabled__c = true
        ];

        result.enabledFeatureCount =
            features.size();

        for (Company_Feature__c feature : features) {
            if (
                feature.Configuration_Status__c
                    != 'Valid'
            ) {
                result.addError(
                    'Enabled feature '
                    + feature.Feature_Key__c
                    + ' must have Configuration Status = Valid.'
                );
            }
        }
    }
}
