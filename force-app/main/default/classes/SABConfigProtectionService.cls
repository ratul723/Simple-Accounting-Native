/**
 * Protects accounting configuration that has already participated in
 * Posted/Reversed ledger history.
 *
 * Company protected after use:
 * Company_Key__c, Country_Code__c, Functional_Currency__c,
 * Fiscal_Calendar_Type__c, Fiscal_Year_Start_Month__c.
 *
 * GL Account protected after use:
 * Company__c, Company_Account_Key__c, Account_Code__c, Account_Type__c,
 * Normal_Balance__c, Is_Control_Account__c, Control_Type__c.
 *
 * Period protected after use:
 * Company__c, Period_Key__c, Company_Period_Key__c, Start_Date__c,
 * End_Date__c, Fiscal_Year__c, Fiscal_Quarter__c, Period_Number__c.
 *
 * Period state/audit fields are always service-controlled:
 * Status__c, Closed_By__c, Closed_At__c, Close_Request_Key__c.
 */
public without sharing class SABConfigProtectionService {

    private static final Set<String> LEDGER_STATUSES =
        new Set<String>{ 'Posted', 'Reversed' };

    public static void beforeCompanyUpdate(
        List<Accounting_Company__c> newRecords,
        Map<Id, Accounting_Company__c> oldMap
    ) {
        Set<Id> changedIds = new Set<Id>();

        for (Accounting_Company__c newRecord : newRecords) {
            Accounting_Company__c oldRecord = oldMap.get(newRecord.Id);

            if (
                oldRecord != null
                && companyMeaningChanged(oldRecord, newRecord)
            ) {
                changedIds.add(newRecord.Id);
            }
        }

        Set<Id> usedIds = usedCompanyIds(changedIds);

        for (Accounting_Company__c newRecord : newRecords) {
            if (usedIds.contains(newRecord.Id)) {
                newRecord.addError(
                    'This Accounting Company has posted accounting history. Company identity, functional currency and fiscal-calendar fields can no longer be changed.'
                );
            }
        }
    }

    public static void beforeCompanyDelete(
        List<Accounting_Company__c> oldRecords
    ) {
        Set<Id> ids = new Set<Id>();

        for (Accounting_Company__c recordValue : oldRecords) {
            ids.add(recordValue.Id);
        }

        Set<Id> usedIds = usedCompanyIds(ids);

        for (Accounting_Company__c recordValue : oldRecords) {
            if (usedIds.contains(recordValue.Id)) {
                recordValue.addError(
                    'An Accounting Company with posted accounting history cannot be deleted.'
                );
            }
        }
    }

    public static void beforeGLAccountUpdate(
        List<GL_Account__c> newRecords,
        Map<Id, GL_Account__c> oldMap
    ) {
        Set<Id> changedIds = new Set<Id>();

        for (GL_Account__c newRecord : newRecords) {
            GL_Account__c oldRecord = oldMap.get(newRecord.Id);

            if (
                oldRecord != null
                && glMeaningChanged(oldRecord, newRecord)
            ) {
                changedIds.add(newRecord.Id);
            }
        }

        Set<Id> usedIds = usedGLAccountIds(changedIds);

        for (GL_Account__c newRecord : newRecords) {
            if (usedIds.contains(newRecord.Id)) {
                newRecord.addError(
                    'This GL Account has been used in posted accounting. Company, code, account type, normal balance and control-account classification can no longer be changed.'
                );
            }
        }
    }

    public static void beforeGLAccountDelete(
        List<GL_Account__c> oldRecords
    ) {
        Set<Id> ids = new Set<Id>();

        for (GL_Account__c recordValue : oldRecords) {
            ids.add(recordValue.Id);
        }

        Set<Id> usedIds = usedGLAccountIds(ids);

        for (GL_Account__c recordValue : oldRecords) {
            if (usedIds.contains(recordValue.Id)) {
                recordValue.addError(
                    'A GL Account used in posted accounting cannot be deleted.'
                );
            }
        }
    }

    public static void beforePeriodUpdate(
        List<Accounting_Period__c> newRecords,
        Map<Id, Accounting_Period__c> oldMap
    ) {
        Set<Id> changedHistoricalIds = new Set<Id>();

        for (Accounting_Period__c newRecord : newRecords) {
            Accounting_Period__c oldRecord = oldMap.get(newRecord.Id);

            if (oldRecord == null) {
                continue;
            }

            if (
                periodStateChanged(oldRecord, newRecord)
                && !SABConfigMutationContext.isPeriodTransition()
            ) {
                newRecord.addError(
                    'Accounting Period status and close audit fields can only be changed through SABPeriodService.'
                );
            }

            if (periodMeaningChanged(oldRecord, newRecord)) {
                changedHistoricalIds.add(newRecord.Id);
            }
        }

        Set<Id> usedIds = usedPeriodIds(changedHistoricalIds);

        for (Accounting_Period__c newRecord : newRecords) {
            if (usedIds.contains(newRecord.Id)) {
                newRecord.addError(
                    'This Accounting Period has posted accounting history. Company, period keys, dates and fiscal mapping can no longer be changed.'
                );
            }
        }
    }

    public static void beforePeriodDelete(
        List<Accounting_Period__c> oldRecords
    ) {
        Set<Id> ids = new Set<Id>();

        for (Accounting_Period__c recordValue : oldRecords) {
            ids.add(recordValue.Id);
        }

        Set<Id> usedIds = usedPeriodIds(ids);

        for (Accounting_Period__c recordValue : oldRecords) {
            if (usedIds.contains(recordValue.Id)) {
                recordValue.addError(
                    'An Accounting Period with posted accounting history cannot be deleted.'
                );
            }
        }
    }

    @TestVisible
    private static Boolean companyMeaningChanged(
        Accounting_Company__c oldRecord,
        Accounting_Company__c newRecord
    ) {
        return oldRecord.Company_Key__c != newRecord.Company_Key__c
            || oldRecord.Country_Code__c != newRecord.Country_Code__c
            || oldRecord.Functional_Currency__c != newRecord.Functional_Currency__c
            || oldRecord.Fiscal_Calendar_Type__c != newRecord.Fiscal_Calendar_Type__c
            || oldRecord.Fiscal_Year_Start_Month__c != newRecord.Fiscal_Year_Start_Month__c;
    }

    @TestVisible
    private static Boolean glMeaningChanged(
        GL_Account__c oldRecord,
        GL_Account__c newRecord
    ) {
        return oldRecord.Company__c != newRecord.Company__c
            || oldRecord.Company_Account_Key__c != newRecord.Company_Account_Key__c
            || oldRecord.Account_Code__c != newRecord.Account_Code__c
            || oldRecord.Account_Type__c != newRecord.Account_Type__c
            || oldRecord.Normal_Balance__c != newRecord.Normal_Balance__c
            || oldRecord.Is_Control_Account__c != newRecord.Is_Control_Account__c
            || oldRecord.Control_Type__c != newRecord.Control_Type__c;
    }

    @TestVisible
    private static Boolean periodMeaningChanged(
        Accounting_Period__c oldRecord,
        Accounting_Period__c newRecord
    ) {
        return oldRecord.Company__c != newRecord.Company__c
            || oldRecord.Period_Key__c != newRecord.Period_Key__c
            || oldRecord.Company_Period_Key__c != newRecord.Company_Period_Key__c
            || oldRecord.Start_Date__c != newRecord.Start_Date__c
            || oldRecord.End_Date__c != newRecord.End_Date__c
            || oldRecord.Fiscal_Year__c != newRecord.Fiscal_Year__c
            || oldRecord.Fiscal_Quarter__c != newRecord.Fiscal_Quarter__c
            || oldRecord.Period_Number__c != newRecord.Period_Number__c;
    }

    @TestVisible
    private static Boolean periodStateChanged(
        Accounting_Period__c oldRecord,
        Accounting_Period__c newRecord
    ) {
        return oldRecord.Status__c != newRecord.Status__c
            || oldRecord.Closed_By__c != newRecord.Closed_By__c
            || oldRecord.Closed_At__c != newRecord.Closed_At__c
            || oldRecord.Close_Request_Key__c != newRecord.Close_Request_Key__c;
    }

    private static Set<Id> usedCompanyIds(Set<Id> companyIds) {
        Set<Id> result = new Set<Id>();

        if (companyIds == null || companyIds.isEmpty()) {
            return result;
        }

        for (AggregateResult rowValue : [
            SELECT Company__c companyId
            FROM Journal_Entry__c
            WHERE Company__c IN :companyIds
              AND Status__c IN :LEDGER_STATUSES
            GROUP BY Company__c
        ]) {
            result.add((Id) rowValue.get('companyId'));
        }

        return result;
    }

    private static Set<Id> usedPeriodIds(Set<Id> periodIds) {
        Set<Id> result = new Set<Id>();

        if (periodIds == null || periodIds.isEmpty()) {
            return result;
        }

        for (AggregateResult rowValue : [
            SELECT Accounting_Period__c periodId
            FROM Journal_Entry__c
            WHERE Accounting_Period__c IN :periodIds
              AND Status__c IN :LEDGER_STATUSES
            GROUP BY Accounting_Period__c
        ]) {
            result.add((Id) rowValue.get('periodId'));
        }

        return result;
    }

    private static Set<Id> usedGLAccountIds(Set<Id> glAccountIds) {
        Set<Id> result = new Set<Id>();

        if (glAccountIds == null || glAccountIds.isEmpty()) {
            return result;
        }

        for (AggregateResult rowValue : [
            SELECT GL_Account__c glAccountId
            FROM Journal_Entry_Line__c
            WHERE GL_Account__c IN :glAccountIds
              AND Journal_Entry__r.Status__c IN :LEDGER_STATUSES
            GROUP BY GL_Account__c
        ]) {
            result.add((Id) rowValue.get('glAccountId'));
        }

        return result;
    }
}
